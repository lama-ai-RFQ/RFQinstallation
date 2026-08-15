using System.Diagnostics;
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
        var exePath = Process.GetCurrentProcess().MainModule?.FileName
            ?? throw new InvalidOperationException("Could not determine the current executable path.");

        var startInfo = new ProcessStartInfo
        {
            FileName = exePath,
            UseShellExecute = true,
            Verb = "runas",
        };

        foreach (var arg in args)
        {
            startInfo.ArgumentList.Add(arg);
        }

        try
        {
            return Process.Start(startInfo);
        }
        catch (System.ComponentModel.Win32Exception)
        {
            return null; // user declined the UAC prompt
        }
    }
}
