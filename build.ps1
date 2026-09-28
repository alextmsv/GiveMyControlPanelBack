$ErrorActionPreference = 'Stop'
$output = Join-Path $PSScriptRoot 'artifacts'
dotnet publish (Join-Path $PSScriptRoot 'GiveMyControlPanelBack.csproj') -c Release -o $output
if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }
$files = @(Get-ChildItem -LiteralPath $output -File)
if ($files.Count -ne 1 -or $files[0].Name -ne 'GiveMyControlPanelBack.exe') {
    throw 'Expected exactly one EXE in artifacts.'
}
Write-Host $files[0].FullName
