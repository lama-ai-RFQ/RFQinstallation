using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace RfqInstaller.Core.Processes;

public record ProcessResult(int ExitCode, string StdOut, string StdErr);

/// <summary>
/// Runs external tools (nssm.exe, pg_ctl.exe, initdb.exe, sc.exe) with no visible window and no
/// stdin — this is the mechanism that replaces every PowerShell/console popup the old Inno
/// installer used. Every call site captures output for logging instead of streaming to a console.
/// </summary>
public static class HiddenProcessRunner
{
    static HiddenProcessRunner()
    {
        // Windows otherwise opens a modal loader error in the child's session and never
        // returns its exit code (observed with PostgreSQL on a clean Windows install).
        // Child processes inherit this flag. Preserve every other process error setting.
        const uint failCriticalErrors = 0x0001;
        if (OperatingSystem.IsWindows()) SetErrorMode(GetErrorMode() | failCriticalErrors);
    }

    [DllImport("kernel32.dll")]
    private static extern uint GetErrorMode();

    [DllImport("kernel32.dll")]
    private static extern uint SetErrorMode(uint mode);

    public static async Task<ProcessResult> RunAsync(
        string fileName,
        IReadOnlyList<string> arguments,
        string? workingDirectory = null,
        IReadOnlyDictionary<string, string>? environment = null,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var startInfo = new ProcessStartInfo
        {
            FileName = fileName,
            WorkingDirectory = workingDirectory ?? Environment.CurrentDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
            WindowStyle = ProcessWindowStyle.Hidden,
        };

        foreach (var arg in arguments)
        {
            startInfo.ArgumentList.Add(arg);
        }

        if (environment is not null)
        {
            foreach (var (key, value) in environment)
            {
                startInfo.Environment[key] = value;
            }
        }

        using var process = new Process { StartInfo = startInfo };
        var stdOut = new StringBuilder();
        var stdErr = new StringBuilder();

        process.OutputDataReceived += (_, e) => { if (e.Data is not null) stdOut.AppendLine(e.Data); };
        process.ErrorDataReceived += (_, e) => { if (e.Data is not null) stdErr.AppendLine(e.Data); };

        process.Start();
        process.StandardInput.Close();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        try
        {
            await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            // Disposing Process only closes its handles. Stop the tool and its
            // children before the wizard allows Retry to change the same files.
            try
            {
                if (!process.HasExited)
                {
                    process.Kill(entireProcessTree: true);
                }
            }
            catch (InvalidOperationException) when (process.HasExited)
            {
                // The process exited between HasExited and Kill.
            }
            await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
            throw;
        }

        return new ProcessResult(process.ExitCode, stdOut.ToString(), stdErr.ToString());
    }
}
