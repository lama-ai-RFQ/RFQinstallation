using System.Diagnostics;

namespace RfqInstaller.Core.Processes;

public sealed record RunningProcessInfo(int Id, string Name, string Path);

/// <summary>
/// Finds and stops processes whose image lives under the install directory — the same set the
/// previous PowerShell installer closed before extraction.
/// </summary>
public static class InstallDirectoryProcesses
{
    public static bool IsUnderInstallDirectory(string processPath, string installPath)
    {
        if (string.IsNullOrWhiteSpace(processPath) || string.IsNullOrWhiteSpace(installPath))
        {
            return false;
        }

        var root = NormalizeDirectory(installPath);
        var full = Path.GetFullPath(processPath);
        return full.StartsWith(root, StringComparison.OrdinalIgnoreCase);
    }

    public static bool IsFileInUse(Exception exception)
    {
        for (var current = exception; current is not null; current = current.InnerException)
        {
            if (current is IOException io)
            {
                var code = io.HResult & 0xFFFF;
                if (code is 32 or 33)
                {
                    return true;
                }
            }
        }

        return false;
    }

    public static IReadOnlyList<RunningProcessInfo> Find(string installPath)
    {
        var self = Environment.ProcessId;
        var found = new List<RunningProcessInfo>();
        foreach (var process in Process.GetProcesses())
        {
            try
            {
                if (process.Id == self)
                {
                    continue;
                }

                string? path;
                try
                {
                    path = process.MainModule?.FileName;
                }
                catch (Exception)
                {
                    continue;
                }

                if (path is null || !IsUnderInstallDirectory(path, installPath))
                {
                    continue;
                }

                found.Add(new RunningProcessInfo(process.Id, process.ProcessName, path));
            }
            finally
            {
                process.Dispose();
            }
        }

        return found
            .GroupBy(item => item.Id)
            .Select(group => group.First())
            .OrderBy(item => item.Name, StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    public static void Stop(IEnumerable<RunningProcessInfo> processes)
    {
        foreach (var info in processes)
        {
            try
            {
                using var process = Process.GetProcessById(info.Id);
                if (!process.HasExited)
                {
                    process.Kill(entireProcessTree: true);
                }
            }
            catch (ArgumentException)
            {
                // Already gone.
            }
            catch (InvalidOperationException)
            {
                // Already gone.
            }
        }
    }

    private static string NormalizeDirectory(string path)
    {
        var full = Path.GetFullPath(path);
        return full.EndsWith(Path.DirectorySeparatorChar)
            ? full
            : full + Path.DirectorySeparatorChar;
    }
}
