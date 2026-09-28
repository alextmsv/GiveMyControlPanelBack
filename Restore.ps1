param([Parameter(Mandatory)][string]$WorkDirectory)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest

function Get-PanelSource {
    param([string]$DriverVersion)
    $version = $null
    if (-not [version]::TryParse($DriverVersion, [ref]$version) -or $version.Build -lt 0 -or $version.Revision -lt 0) {
        throw 'Unrecognized NVIDIA driver version.'
    }
    $nvidiaVersion = ($version.Build % 10) * 10000 + $version.Revision
    if ($nvidiaVersion -ge 60000) {
        return [pscustomobject]@{
            Version = '8.1.969.0'
            Url = 'https://us.download.nvidia.com/Windows/610.62/610.62-desktop-win10-win11-64bit-international-dch-whql.exe'
        }
    }
    return [pscustomobject]@{
        Version = '8.1.968.0'
        Url = 'https://us.download.nvidia.com/Windows/582.66/582.66-desktop-win10-win11-64bit-international-dch-whql.exe'
    }
}

function Assert-FileHash {
    param([string]$Path, [string]$Expected)
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Expected) {
        throw 'Download checksum verification failed. No downloaded executable was started.'
    }
}

function Assert-PanelPackage {
    param([string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem, System.IO.Compression
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $archive.GetEntry('AppxManifest.xml')
        if ($null -eq $entry -or $entry.Length -gt 1MB) { throw 'Invalid panel package manifest.' }
        $stream = $entry.Open()
        $settings = New-Object Xml.XmlReaderSettings
        $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $reader = [Xml.XmlReader]::Create($stream, $settings)
        try {
            $manifest = New-Object Xml.XmlDocument
            $manifest.XmlResolver = $null
            $manifest.Load($reader)
        } finally {
            $reader.Dispose()
            $stream.Dispose()
        }
        $identity = $manifest.Package.Identity
        if ($identity.Name -ne 'NVIDIACorp.NVIDIAControlPanel' -or
            $identity.Publisher -ne 'CN=D6816951-877F-493B-B4EE-41AB9419C326' -or
            $identity.ProcessorArchitecture -ne 'x64') {
            throw 'Unexpected panel package identity.'
        }
    } finally { $archive.Dispose() }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -ne $identity.Publisher) {
        throw 'NVIDIA Control Panel signature verification failed.'
    }
    return $identity
}

function Save-Download {
    param([string]$Url, [string]$Path, [string]$Label)
    if (([uri]$Url).Scheme -ne 'https') { throw 'HTTPS is required.' }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $response = $null
        $source = $null
        $target = $null
        try {
            Write-Host "$Label (attempt $attempt/3)..."
            $request = [Net.HttpWebRequest]::Create($Url)
            $request.UserAgent = 'GiveMyControlPanelBack/1.0.0'
            $request.Timeout = 30000
            $request.ReadWriteTimeout = 30000
            $response = $request.GetResponse()
            if ($response.ResponseUri.Scheme -ne 'https') { throw 'Insecure download redirect rejected.' }
            $source = $response.GetResponseStream()
            $target = [IO.File]::Create($Path)
            $buffer = New-Object byte[] 1048576
            $received = 0L
            $timer = [Diagnostics.Stopwatch]::StartNew()
            $lastUpdate = -5.0
            while (($count = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $target.Write($buffer, 0, $count)
                $received += $count
                if ($received -gt 2GB -or $timer.Elapsed.TotalMinutes -gt 20) { throw 'Download limit exceeded.' }
                if ($timer.Elapsed.TotalSeconds - $lastUpdate -ge 5) {
                    $total = if ($response.ContentLength -gt 0) { ' / {0:N0} MB' -f ($response.ContentLength / 1MB) } else { '' }
                    Write-Host ('  {0:N0}{1} MB received' -f ($received / 1MB), $total.Replace(' MB', ''))
                    $lastUpdate = $timer.Elapsed.TotalSeconds
                }
            }
            if ($received -eq 0 -or ($response.ContentLength -gt 0 -and $received -ne $response.ContentLength)) {
                throw 'The download is incomplete.'
            }
            return
        } catch {
            if ($attempt -eq 3) { throw }
            Write-Host 'Download interrupted. Retrying...'
            Start-Sleep -Seconds 2
        } finally {
            if ($null -ne $target) { $target.Dispose() }
            if ($null -ne $source) { $source.Dispose() }
            if ($null -ne $response) { $response.Dispose() }
        }
    }
}

function Open-Panel {
    param($Package)
    Write-Host 'Opening NVIDIA Control Panel...'
    $appId = 'shell:AppsFolder\' + $Package.PackageFamilyName + '!NVIDIACorp.NVIDIAControlPanel'
    Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList $appId
    for ($i = 0; $i -lt 30; $i++) {
        $window = Get-Process -Name nvcplui -ErrorAction SilentlyContinue |
            Where-Object { $_.SessionId -eq (Get-Process -Id $PID).SessionId -and $_.Responding -and $_.MainWindowHandle -ne 0 } |
            Select-Object -First 1
        if ($null -ne $window) { return }
        Start-Sleep -Milliseconds 500
    }
    throw 'The panel is installed, but its window did not open. Try opening NVIDIA Control Panel from Start, or restart Windows.'
}

function Restore-Panel {
    param([string]$Directory, [string]$CacheDirectory)
    if (-not [Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
        throw 'This release requires Windows x64.'
    }
    foreach ($command in @('Get-AppxPackage', 'Add-AppxPackage')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw 'Windows AppX support is missing. Restore the Windows AppX components before running this tool.'
        }
    }
    Import-Module Microsoft.PowerShell.Security -ErrorAction Stop
    Write-Host 'Checking NVIDIA graphics driver...'
    $gpu = Get-CimInstance Win32_VideoController -OperationTimeoutSec 15 |
        Where-Object { $_.Name -match 'NVIDIA' -and $_.DriverVersion } | Select-Object -First 1
    if ($null -eq $gpu) { throw 'No installed NVIDIA graphics driver was found. Install the NVIDIA display driver first.' }
    Write-Host $gpu.Name
    $installed = Get-AppxPackage -Name NVIDIACorp.NVIDIAControlPanel | Select-Object -First 1
    if ($null -ne $installed -and $installed.Status -eq 'Ok') {
        Write-Host 'NVIDIA Control Panel is already installed.'
        Open-Panel $installed
        return
    }
    $service = Get-Service -Name AppXSvc -ErrorAction SilentlyContinue
    if ($null -eq $service -or $service.StartType -eq 'Disabled') {
        throw 'The Windows AppX Deployment Service is missing or disabled. Restore or enable AppXSvc, then run this tool again.'
    }
    $source = Get-PanelSource $gpu.DriverVersion
    $panel = Join-Path $CacheDirectory ('NVIDIA-Control-Panel-' + $source.Version + '.appx')
    $cached = $false
    if (Test-Path -LiteralPath $panel) {
        try {
            $identity = Assert-PanelPackage $panel
            if ([version]$identity.Version -lt [version]$source.Version) { throw 'The cached panel is outdated.' }
            $cached = $true
            Write-Host 'Using the verified cached panel installer.'
        } catch { Write-Host 'The cached installer could not be verified. Downloading a fresh copy.' }
    }
    if (-not $cached) {
        $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($Directory))
        if ($drive.AvailableFreeSpace -lt 2GB) { throw 'At least 2 GB of free space is required on the temporary drive.' }
        $driver = Join-Path $Directory 'nvidia-driver.exe'
        Save-Download $source.Url $driver 'Downloading the official NVIDIA package (about 1 GB)'
        Write-Host 'Verifying NVIDIA digital signature...'
        $signature = Get-AuthenticodeSignature -LiteralPath $driver
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|,\s*)CN=NVIDIA Corporation(,|$)') {
            throw 'NVIDIA driver signature verification failed. The package will not be used.'
        }
        $extractor = Join-Path $Directory '7zr.exe'
        Save-Download 'https://github.com/ip7z/7zip/releases/download/26.03/7zr.exe' $extractor 'Downloading the official 7-Zip extractor'
        Assert-FileHash $extractor 'AD4C82FADCBDF93C03B4FC440F300509C7D60C5C2F4D183E35D9D70D6957037D'
        Write-Host 'Extracting the panel installer...'
        $extracted = Join-Path $Directory 'panel'
        & $extractor e $driver 'Display.Driver\NVCPL\*.appx' "-o$extracted" -y -bso0 -bsp0
        if ($LASTEXITCODE -ne 0) { throw "Panel extraction failed (7-Zip exit code $LASTEXITCODE)." }
        $packages = @(Get-ChildItem -LiteralPath $extracted -Filter '*.appx' -File)
        if ($packages.Count -ne 1) { throw 'The official driver did not contain exactly one panel installer.' }
        Assert-PanelPackage $packages[0].FullName | Out-Null
        Copy-Item -LiteralPath $packages[0].FullName -Destination $panel -Force
    }
    Write-Host 'Installing NVIDIA Control Panel...'
    $staged = Join-Path $Directory 'NVIDIA-Control-Panel.appx'
    Copy-Item -LiteralPath $panel -Destination $staged -Force
    Assert-PanelPackage $staged | Out-Null
    Add-AppxPackage -Path $staged -ErrorAction Stop
    $installed = Get-AppxPackage -Name NVIDIACorp.NVIDIAControlPanel | Select-Object -First 1
    if ($null -eq $installed -or $installed.Status -ne 'Ok') { throw 'Windows did not confirm a healthy panel installation.' }
    Open-Panel $installed
}

$transcript = $false
$exitCode = 1
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $cache = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'GiveMyControlPanelBack'
    New-Item -ItemType Directory -Path $cache -Force | Out-Null
    Start-Transcript -LiteralPath (Join-Path $cache 'last-run.log') -Force | Out-Null
    $transcript = $true
    Restore-Panel $WorkDirectory $cache
    Write-Host ''
    Write-Host 'Done. Your NVIDIA Control Panel is back.' -ForegroundColor Green
    $exitCode = 0
} catch {
    Write-Host ''
    Write-Host ('Could not restore the panel: ' + $_.Exception.Message) -ForegroundColor Red
    if ($transcript) { Write-Host ('Log: ' + (Join-Path $cache 'last-run.log')) }
} finally {
    if ($transcript) { Stop-Transcript | Out-Null }
}
exit $exitCode
