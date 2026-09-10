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

    public NssmServiceManager(string nssmPath)
    {
        _nssmPath = nssmPath;
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
        await RunNssm(new[] { "stop", serviceName }, cancellationToken).ConfigureAwait(false);
        await RunNssm(new[] { "remove", serviceName, "confirm" }, cancellationToken).ConfigureAwait(false);
        await WaitForServiceGoneAsync(serviceName, cancellationToken).ConfigureAwait(false);
    }

    public async Task<bool> ExistsAsync(string serviceName, CancellationToken cancellationToken)
    {
        var result = await HiddenProcessRunner.RunAsync("sc.exe", new[] { "query", serviceName }, cancellationToken: cancellationToken)
            .ConfigureAwait(false);
        return result.ExitCode == 0;
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
    }

    private Task<ProcessResult> RunNssm(IReadOnlyList<string> args, CancellationToken cancellationToken) =>
        HiddenProcessRunner.RunAsync(_nssmPath, args, cancellationToken: cancellationToken);
}
