using System.Diagnostics;
using System.Reflection;
using System.Text;

Console.OutputEncoding = Encoding.UTF8;
Console.WriteLine("Give My Control Panel Back v1.0.0\n");

using var mutex = new Mutex(true, @"Local\GiveMyControlPanelBack", out var firstInstance);
if (!firstInstance)
{
    Console.WriteLine("Another instance is already running.");
    return 0;
}

var workDirectory = Path.Combine(Path.GetTempPath(), "GiveMyControlPanelBack-" + Guid.NewGuid().ToString("N"));
var exitCode = 1;
Process? child = null;
Console.CancelKeyPress += (_, e) =>
{
    e.Cancel = true;
    try
    {
        if (child is { HasExited: false })
            child.Kill(entireProcessTree: true);
    }
    catch (InvalidOperationException) { }
    catch (System.ComponentModel.Win32Exception) { }
};

try
{
    if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 17763) ||
        System.Runtime.InteropServices.RuntimeInformation.OSArchitecture != System.Runtime.InteropServices.Architecture.X64)
        throw new PlatformNotSupportedException("Windows 10 version 1809 or later (x64) is required.");

    Directory.CreateDirectory(workDirectory);
    var scriptPath = Path.Combine(workDirectory, "Restore.ps1");
    using (var resource = Assembly.GetExecutingAssembly().GetManifestResourceStream("Restore.ps1")
        ?? throw new InvalidOperationException("The embedded installer is missing."))
    using (var file = File.Create(scriptPath))
        resource.CopyTo(file);

    var powerShell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
        @"WindowsPowerShell\v1.0\powershell.exe");
    if (!File.Exists(powerShell))
        throw new FileNotFoundException("Windows PowerShell is missing. Restore it before running this tool.");

    var start = new ProcessStartInfo(powerShell) { UseShellExecute = false };
    start.Environment["PSModulePath"] = Path.Combine(Path.GetDirectoryName(powerShell)!, "Modules");
    foreach (var argument in new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
        "-File", scriptPath, "-WorkDirectory", workDirectory })
        start.ArgumentList.Add(argument);

    child = Process.Start(start) ?? throw new InvalidOperationException("Could not start Windows PowerShell.");
    child.WaitForExit();
    exitCode = child.ExitCode;
}
catch (Exception exception)
{
    Console.Error.WriteLine(exception.Message);
}
finally
{
    child?.Dispose();
    child = null;
    try
    {
        if (Directory.Exists(workDirectory))
            Directory.Delete(workDirectory, recursive: true);
    }
    catch (IOException) { Console.Error.WriteLine($"Temporary files remain at: {workDirectory}"); }
    catch (UnauthorizedAccessException) { Console.Error.WriteLine($"Temporary files remain at: {workDirectory}"); }
    mutex.ReleaseMutex();
}

if (!Console.IsInputRedirected)
{
    if (exitCode == 0)
        Thread.Sleep(3000);
    else
    {
        Console.WriteLine("\nPress any key to close.");
        Console.ReadKey(intercept: true);
    }
}

return exitCode;
