using System.Diagnostics;
using System.Reflection;
using System.Runtime.Versioning;
using System.Security.Principal;

namespace RfqInstaller.Core.Elevation;

/// <summary>
/// Admin elevation is only requested when it's actually needed (installing a service, or writing
/// to a machine-wide folder like Program Files) — a standalone install into a user-writable folder
/// doesn't need it, matching least-privilege rather than always demanding admin like the old
/// Inno installer did.
/// </summary>
[SupportedOSPlatform("windows")]
public static class ElevationHelper
{
    public static bool IsElevated()
    {
        using var identity = WindowsIdentity.GetCurrent();
        var principal = new WindowsPrincipal(identity);
        return principal.IsInRole(WindowsBuiltInRole.Administrator);
    }

    public static bool RequiresElevation(Models.InstallMode mode, string installPath)
    {
        if (mode == Models.InstallMode.WindowsService)
        {
            return true; // service (de)registration always needs admin
        }

        // Writing under Program Files (or another machine-wide location) needs admin even for a standalone exe.
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        var programFilesX86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
        var fullInstallPath = Path.GetFullPath(installPath);

        return fullInstallPath.StartsWith(programFiles, StringComparison.OrdinalIgnoreCase)
            || fullInstallPath.StartsWith(programFilesX86, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>Relaunches the current executable elevated via the UAC "runas" verb, forwarding all args. Caller should exit immediately after calling this.</summary>
    public static Process? RelaunchElevated(string[] args)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = GetCurrentExecutablePath(),
            UseShellExecute = true,
            Verb = "runas",
            WorkingDirectory = AppContext.BaseDirectory,
            // ArgumentList is ignored when UseShellExecute is true.
            Arguments = string.Join(" ", args.Select(QuoteArgument)),
        };

        try
        {
            return Process.Start(startInfo);
        }
        catch (System.ComponentModel.Win32Exception)
        {
            return null; // user declined the UAC prompt
        }
    }

    /// <summary>
    /// The process path is often <c>dotnet.exe</c> when launched from an IDE. UAC must restart the
    /// actual WPF apphost, or the elevated process is not the installer and the original window
    /// just disappears.
    /// </summary>
    public static string GetCurrentExecutablePath()
    {
        var processPath = Environment.ProcessPath ?? Process.GetCurrentProcess().MainModule?.FileName;
        if (!string.IsNullOrEmpty(processPath) && File.Exists(processPath) && !IsDotnetHost(processPath))
        {
            return processPath;
        }

        var entry = Assembly.GetEntryAssembly()?.Location;
        if (!string.IsNullOrEmpty(entry))
        {
            var apphost = Path.ChangeExtension(entry, ".exe");
            if (File.Exists(apphost))
            {
                return apphost;
            }
        }

        return processPath
            ?? throw new InvalidOperationException("Could not determine the current executable path.");
    }

    private static bool IsDotnetHost(string path)
    {
        var name = Path.GetFileName(path);
        return name.Equals("dotnet.exe", StringComparison.OrdinalIgnoreCase)
            || name.Equals("dotnet", StringComparison.OrdinalIgnoreCase);
    }

    private static string QuoteArgument(string arg) =>
        $"\"{arg.Replace("\"", "\\\"", StringComparison.Ordinal)}\"";
}
