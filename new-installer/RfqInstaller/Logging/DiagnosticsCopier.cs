using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using RfqInstaller.Core.Diagnostics;
using RfqInstaller.Models;

namespace RfqInstaller.Logging;

/// <summary>
/// The "Copy Diagnostics" buttons: collects <see cref="InstallDiagnostics"/>, saves it next to
/// the installer log and puts it on the clipboard, so a customer can paste it to support in one go.
/// </summary>
public static class DiagnosticsCopier
{
    public static async Task CopyAsync(WizardState state, TextBlock status, string? lastError)
    {
        status.Visibility = Visibility.Visible;
        status.Text = "Collecting diagnostics...";
        try
        {
            var input = new DiagnosticsInput(
                state.InstallPath,
                state.SignedInUserName,
                InstallerLog.LogPath,
                lastError);
            var report = await Task.Run(() => InstallDiagnostics.CollectAsync(input));
            var path = InstallDiagnostics.Save(report, InstallerLog.LogDirectory);
            Clipboard.SetText(report);
            status.Text = $"Copied to the clipboard. Paste it into your message to support. Also saved to {path}";
        }
        catch (Exception ex)
        {
            var logPath = InstallerLog.Write("collecting diagnostics", ex);
            status.Text = $"Couldn't collect diagnostics: {ex.Message} (details in {logPath})";
        }
    }
}
