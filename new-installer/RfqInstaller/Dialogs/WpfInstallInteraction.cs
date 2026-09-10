using System.Windows;
using RfqInstaller.Core.Orchestration;
using RfqInstaller.Core.Processes;

namespace RfqInstaller.Dialogs;

public sealed class WpfInstallInteraction : IInstallInteraction
{
    public Task<bool> ConfirmStopRunningProcessesAsync(
        IReadOnlyList<RunningProcessInfo> processes,
        CancellationToken cancellationToken)
    {
        var app = Application.Current;
        if (app is null)
        {
            return Task.FromResult(true);
        }

        return app.Dispatcher.InvokeAsync(
            () =>
            {
                cancellationToken.ThrowIfCancellationRequested();
                var list = string.Join(
                    Environment.NewLine,
                    processes.Select(process => $"• {process.Name} (PID {process.Id})"));
                return AppDialog.Confirm(
                    app.MainWindow,
                    "Close running programs",
                    "These programs are using files that need to be updated:" +
                    Environment.NewLine + Environment.NewLine +
                    list +
                    Environment.NewLine + Environment.NewLine +
                    "Stop them so installation can continue?",
                    confirmText: "Stop Processes",
                    dismissText: "Cancel");
            }).Task;
    }
}
