using RfqInstaller.Core.Models;
using RfqInstaller.Core.Processes;

namespace RfqInstaller.Core.Services;

/// <summary>
/// Installs/removes Windows services via the already-bundled, already-proven nssm.exe (same tool
/// and command shape the old download_and_install.ps1 used), but invoked directly from the WPF
/// process with a hidden window instead of spawning a visible console.
/// </summary>
public class NssmServiceManager
{
    private readonly string _nssmPath;
    private readonly Func<string, IReadOnlyList<string>, CancellationToken, Task<ProcessResult>> _run;
    private readonly ServiceControl _control;
    private readonly Func<string?> _getLogCapValue;

    public NssmServiceManager(string nssmPath) : this(
        nssmPath,
        (file, args, token) => HiddenProcessRunner.RunAsync(file, args, cancellationToken: token))
    {
    }

    internal NssmServiceManager(
        string nssmPath,
        Func<string, IReadOnlyList<string>, CancellationToken, Task<ProcessResult>> run,
        Func<TimeSpan, CancellationToken, Task>? delay = null,
        Func<string?>? getLogCapValue = null)
    {
        _nssmPath = nssmPath;
        _run = run;
        _control = new ServiceControl(run, delay);
        _getLogCapValue = getLogCapValue ?? (() => Environment.GetEnvironmentVariable("RFQ_LOG_CAP_MAX_BYTES"));
    }

    /// <summary>How long a start may take before it counts as failed; RFQ Application can take minutes on a slow disk.</summary>
    public TimeSpan StartTimeout { get; init; } = ServiceControl.DefaultStartTimeout;

    public async Task InstallOrReplaceAsync(
        string serviceName,
        string displayName,
        string description,
        string exePath,
        string appDirectory,
        string? appParameters,
        string stdoutLogPath,
        string stderrLogPath,
        ServiceAccountKind account,
        string? currentUserDomainAndName,
        string? currentUserPassword,
        CancellationToken cancellationToken)
    {
        // Validate before this method removes an existing service. The enclosing
        // installer may already have stopped services while replacing app files.
        var logCapMaxBytes = NssmLogRotation.ParseMaxBytes(_getLogCapValue());
        if (account == ServiceAccountKind.CurrentUser &&
            (string.IsNullOrWhiteSpace(currentUserDomainAndName) || string.IsNullOrEmpty(currentUserPassword)))
        {
            throw new ArgumentException("The selected service account requires a username and password.");
        }
        if (await ExistsAsync(serviceName, cancellationToken).ConfigureAwait(false))
        {
            await RemoveAsync(serviceName, cancellationToken).ConfigureAwait(false);
        }

        await RunNssm(new[] { "install", serviceName, exePath }, cancellationToken, currentUserPassword).ConfigureAwait(false);
        await RunNssm(new[] { "set", serviceName, "DisplayName", displayName }, cancellationToken, currentUserPassword).ConfigureAwait(false);
        await RunNssm(new[] { "set", serviceName, "Description", description }, cancellationToken, currentUserPassword).ConfigureAwait(false);
        await RunNssm(new[] { "set", serviceName, "AppDirectory", appDirectory }, cancellationToken, currentUserPassword).ConfigureAwait(false);
        await RunNssm(new[] { "set", serviceName, "Start", "SERVICE_AUTO_START" }, cancellationToken, currentUserPassword).ConfigureAwait(false);
        await RunNssm(new[] { "set", serviceName, "AppStdout", stdoutLogPath }, cancellationToken, currentUserPassword).ConfigureAwait(false);
        await RunNssm(new[] { "set", serviceName, "AppStderr", stderrLogPath }, cancellationToken, currentUserPassword).ConfigureAwait(false);
        await RunNssm(new[] { "set", serviceName, "AppRotateFiles", "1" }, cancellationToken, currentUserPassword).ConfigureAwait(false);
        await RunNssm(new[] { "set", serviceName, "AppRotateOnline", "1" }, cancellationToken, currentUserPassword).ConfigureAwait(false);
        await RunNssm(new[] { "set", serviceName, "AppRotateBytes", logCapMaxBytes }, cancellationToken, currentUserPassword).ConfigureAwait(false);

        if (!string.IsNullOrEmpty(appParameters))
        {
            await RunNssm(new[] { "set", serviceName, "AppParameters", appParameters }, cancellationToken, currentUserPassword).ConfigureAwait(false);
        }

        switch (account)
        {
            case ServiceAccountKind.NetworkService:
                await RunNssm(new[] { "set", serviceName, "ObjectName", "NT AUTHORITY\\NETWORK SERVICE" }, cancellationToken, currentUserPassword).ConfigureAwait(false);
                break;
            case ServiceAccountKind.CurrentUser when currentUserDomainAndName is not null && currentUserPassword is not null:
                await RunNssm(new[] { "set", serviceName, "ObjectName", currentUserDomainAndName, currentUserPassword }, cancellationToken, currentUserPassword)
                    .ConfigureAwait(false);
                break;
            case ServiceAccountKind.LocalSystem:
            default:
                // NSSM defaults new services to LocalSystem; nothing to set.
                break;
        }

        // Not `nssm start`: it gives up while the app is still starting and hides why a start failed.
        await _control.StartAndWaitAsync(serviceName, cancellationToken, StartTimeout, stderrLogPath).ConfigureAwait(false);
    }

    public async Task RemoveAsync(string serviceName, CancellationToken cancellationToken)
    {
        await StopIfExistsAsync(serviceName, cancellationToken).ConfigureAwait(false);
        await RunNssm(new[] { "remove", serviceName, "confirm" }, cancellationToken).ConfigureAwait(false);
        await WaitForServiceGoneAsync(serviceName, cancellationToken).ConfigureAwait(false);
    }

    public async Task<bool> ExistsAsync(string serviceName, CancellationToken cancellationToken)
    {
        var result = await _run("sc.exe", new[] { "query", serviceName }, cancellationToken)
            .ConfigureAwait(false);
        if (result.ExitCode is not (0 or 1060))
        {
            throw new InvalidOperationException($"Could not query service '{serviceName}' (exit code {result.ExitCode}).");
        }
        return result.ExitCode == 0;
    }

    /// <summary>Starts an already-registered service, allowing "already running", and waits until it runs.</summary>
    public Task StartAsync(string serviceName, CancellationToken cancellationToken) =>
        _control.StartAndWaitAsync(serviceName, cancellationToken, StartTimeout);

    public Task StopIfExistsAsync(string serviceName, CancellationToken cancellationToken) =>
        _control.StopIfExistsAsync(serviceName, cancellationToken);

    private Task WaitForServiceGoneAsync(string serviceName, CancellationToken cancellationToken) =>
        _control.WaitUntilRemovedAsync(serviceName, cancellationToken);

    private async Task<ProcessResult> RunNssm(
        IReadOnlyList<string> args,
        CancellationToken cancellationToken,
        string? secretToRedact = null)
    {
        var result = await _run(_nssmPath, args, cancellationToken).ConfigureAwait(false);
        if (result.ExitCode != 0)
        {
            var setting = args.Count > 2 && args[0] == "set" ? $" {args[2]}" : "";
            // Only `set ObjectName` carries the service account's password, in its arguments and
            // possibly echoed in NSSM's output. Every other command's output is the actual reason.
            var carriesPassword = args.Count > 2 && args[0] == "set" &&
                                  string.Equals(args[2], "ObjectName", StringComparison.OrdinalIgnoreCase);
            var output = carriesPassword ? "" : CleanOutput(result.StdOut + Environment.NewLine + result.StdErr);
            if (!string.IsNullOrEmpty(secretToRedact))
            {
                output = output.Replace(secretToRedact, "[password]", StringComparison.Ordinal);
            }
            throw new InvalidOperationException(
                $"NSSM {args[0]}{setting} for service '{args[1]}' failed (exit code {result.ExitCode})." +
                (output.Length > 0 ? $" NSSM said: {output}" : ""));
        }
        return result;
    }

    /// <summary>NSSM writes UTF-16 to its console; read as UTF-8 that shows up as NUL padding.</summary>
    internal static string CleanOutput(string output) =>
        string.Join(" ", output.Replace("\0", "", StringComparison.Ordinal)
            .Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
}
