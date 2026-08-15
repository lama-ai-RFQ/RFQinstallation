using System.Windows;
using System.Windows.Controls;
using RfqInstaller.Demo.Debug;
using RfqInstaller.Demo.Models;

namespace RfqInstaller.Demo.Pages;

public partial class ReadyToInstallPage : UserControl, IWizardPage
{
    public ReadyToInstallPage(WizardState state)
    {
        InitializeComponent();

        LicenseKeySummary.Text = InstallerDebug.ShouldSkip(WizardStep.License)
            ? "Skipped (debug)"
            : MaskLicenseKey(state.LicenseKey);
        ModeSummary.Text = state.Mode == InstallMode.WindowsService
            ? "Windows Service (starts automatically)"
            : "Standalone application";
        PathSummary.Text = state.InstallPath;

        if (state.Mode == InstallMode.Standalone)
        {
            ShortcutRow.Visibility = Visibility.Visible;
            ShortcutSummary.Text = state.CreateDesktopShortcut ? "Yes" : "No";
        }
        else
        {
            ShortcutRow.Visibility = Visibility.Collapsed;
        }

        ModelSummary.Text = state.DownloadModelNow
            ? $"Download now (~30 GB) to {state.ModelPath}"
            : "Skip for now";

        ServiceAccountSummary.Text = state.ServiceAccount switch
        {
            ServiceAccountKind.NetworkService => "Network Service",
            ServiceAccountKind.CurrentUser => "Current User",
            _ => "Local System",
        };
    }

    private static string MaskLicenseKey(string key)
    {
        if (key.Length <= 4)
        {
            return key;
        }

        return new string('*', key.Length - 4) + key[^4..];
    }

    public bool Validate() => true;
}
