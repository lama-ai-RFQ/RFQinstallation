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

    public NssmServiceManager(string nssmPath) : this(
        nssmPath,
        (file, args, token) => HiddenProcessRunner.RunAsync(file, args, cancellationToken: token))
    {
    }

    internal NssmServiceManager(
        string nssmPath,
        Func<string, IReadOnlyList<string>, CancellationToken, Task<ProcessResult>> run)
    {
        _nssmPath = nssmPath;
        _run = run;
    }

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
        if (account == ServiceAccountKind.CurrentUser &&
            (string.IsNullOrWhiteSpace(currentUserDomainAndName) || string.IsNullOrEmpty(currentUserPassword)))
        {
            throw new ArgumentException("The selected service account requires a username and password.");
        }
        if (await ExistsAsync(serviceName, cancellationToken).ConfigureAwait(false))
        {
            await RemoveAsync(serviceName, cancellationToken).ConfigureAwait(false);
        }

        await RunNssm(new[] { "install", serviceName, exePath }, cancellationToken).ConfigureAwait(false);
        await RunNssm(new[] { "set", serviceName, "DisplayName", displayName }, cancellationToken).ConfigureAwait(false);
        await RunNssm(new[] { "set", serviceName, "Description", description }, cancellationToken).ConfigureAwait(false);
        await RunNssm(new[] { "set", serviceName, "AppDirectory", appDirectory }, cancellationToken).ConfigureAwait(false);
        await RunNssm(new[] { "set", serviceName, "Start", "SERVICE_AUTO_START" }, cancellationToken).ConfigureAwait(false);
        await RunNssm(new[] { "set", serviceName, "AppStdout", stdoutLogPath }, cancellationToken).ConfigureAwait(false);
        await RunNssm(new[] { "set", serviceName, "AppStderr", stderrLogPath }, cancellationToken).ConfigureAwait(false);

        if (!string.IsNullOrEmpty(appParameters))
        {
            await RunNssm(new[] { "set", serviceName, "AppParameters", appParameters }, cancellationToken).ConfigureAwait(false);
        }

        switch (account)
        {
            case ServiceAccountKind.NetworkService:
                await RunNssm(new[] { "set", serviceName, "ObjectName", "NT AUTHORITY\\NETWORK SERVICE" }, cancellationToken).ConfigureAwait(false);
                break;
            case ServiceAccountKind.CurrentUser when currentUserDomainAndName is not null && currentUserPassword is not null:
                await RunNssm(new[] { "set", serviceName, "ObjectName", currentUserDomainAndName, currentUserPassword }, cancellationToken)
                    .ConfigureAwait(false);
                break;
            case ServiceAccountKind.LocalSystem:
            default:
                // NSSM defaults new services to LocalSystem; nothing to set.
                break;
        }

        await RunNssm(new[] { "start", serviceName }, cancellationToken).ConfigureAwait(false);
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

    /// <summary>Starts an already-registered service, allowing "already running".</summary>
    public async Task StartAsync(string serviceName, CancellationToken cancellationToken)
    {
        var result = await _run("sc.exe", new[] { "start", serviceName }, cancellationToken).ConfigureAwait(false);
        if (result.ExitCode is not (0 or 1056))
        {
            throw new InvalidOperationException($"Could not start service '{serviceName}' (exit code {result.ExitCode}).");
        }
    }

    public async Task StopIfExistsAsync(string serviceName, CancellationToken cancellationToken)
    {
        if (!await ExistsAsync(serviceName, cancellationToken).ConfigureAwait(false))
        {
            return;
        }

        var stop = await _run("sc.exe", new[] { "stop", serviceName }, cancellationToken).ConfigureAwait(false);
        if (stop.ExitCode is not (0 or 1062))
        {
            throw new InvalidOperationException($"Could not stop service '{serviceName}' (exit code {stop.ExitCode}).");
        }

        for (var i = 0; i < 30; i++)
        {
            var query = await _run("sc.exe", new[] { "query", serviceName }, cancellationToken)
                .ConfigureAwait(false);
            if (query.ExitCode == 1060 ||
                (query.ExitCode == 0 && query.StdOut.Contains("STOPPED", StringComparison.OrdinalIgnoreCase)))
            {
                return;
            }
            if (query.ExitCode != 0)
            {
                throw new InvalidOperationException($"Could not query service '{serviceName}' while stopping (exit code {query.ExitCode}).");
            }

            await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken).ConfigureAwait(false);
        }
        throw new TimeoutException($"Service '{serviceName}' did not stop within 30 seconds.");
    }

    private async Task WaitForServiceGoneAsync(string serviceName, CancellationToken cancellationToken)
    {
        for (var i = 0; i < 30; i++)
        {
            if (!await ExistsAsync(serviceName, cancellationToken).ConfigureAwait(false))
            {
                return;
            }
            await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken).ConfigureAwait(false);
        }
        throw new TimeoutException($"Service '{serviceName}' was not removed within 30 seconds.");
    }

    private async Task<ProcessResult> RunNssm(IReadOnlyList<string> args, CancellationToken cancellationToken)
    {
        var result = await _run(_nssmPath, args, cancellationToken).ConfigureAwait(false);
        if (result.ExitCode != 0)
        {
            // NSSM arguments/output may include the service-account password.
            // Identify the failed operation without copying secrets into logs.
            var setting = args.Count > 2 && args[0] == "set" ? $" {args[2]}" : "";
            throw new InvalidOperationException(
                $"NSSM {args[0]}{setting} for service '{args[1]}' failed (exit code {result.ExitCode}).");
        }
        return result;
    }
}
