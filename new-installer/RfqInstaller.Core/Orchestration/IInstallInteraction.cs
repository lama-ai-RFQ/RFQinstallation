using RfqInstaller.Core.Processes;

namespace RfqInstaller.Core.Orchestration;

/// <summary>
/// UI hook so the orchestrator can ask the user to close programs that lock install files.
/// </summary>
public interface IInstallInteraction
{
    Task<bool> ConfirmStopRunningProcessesAsync(
        IReadOnlyList<RunningProcessInfo> processes,
        CancellationToken cancellationToken);
}
