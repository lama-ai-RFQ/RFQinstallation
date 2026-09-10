using System.Windows;
using System.Windows.Controls;
using RfqInstaller.Core.Config;
using RfqInstaller.Debug;
using RfqInstaller.Models;

namespace RfqInstaller.Pages;

public partial class ReadyToInstallPage : UserControl, IWizardPage
{
    public ReadyToInstallPage(WizardState state)
    {
        InitializeComponent();

        LicenseKeySummary.Text = InstallerDebug.ShouldSkip(WizardStep.License)
            ? "Skipped (debug)"
            : MaskLicenseKey(state.LicenseKey);
        ModeSummary.Text = state.Mode == InstallMode.WindowsService
            ? "Windows Service (advanced, recommended)"
            : "Desktop app (.exe) — basic";
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

        EncryptionKeySummary.Text = state.AutoGenerateEncryptionKey
            ? EncryptionKeyResolver.ResolveFromInstallPath(state.InstallPath) is not null
                ? "Generate a new key (existing database secrets will be unreadable)"
                : "Generate automatically"
            : "Reuse existing key";

        PostgresPasswordsSummary.Text = state.AutoGeneratePostgresPasswords
            ? "Generate automatically"
            : "Set during setup";

        var credentialManagerWillActuallyWork = state.UseCredentialManager
            && (state.Mode == InstallMode.Standalone || state.ServiceAccount == ServiceAccountKind.CurrentUser);
        PasswordStorageSummary.Text = credentialManagerWillActuallyWork
            ? "Windows Credential Manager"
            : state.UseCredentialManager
                ? ".env file (Credential Manager doesn't work with the chosen service account)"
                : ".env file";

        if (state.Mode == InstallMode.WindowsService)
        {
            ServiceAccountRow.Visibility = Visibility.Visible;
            ServiceAccountSummary.Text = state.ServiceAccount switch
            {
                ServiceAccountKind.CurrentUser => state.ServiceAccountConfirmed
                    ? $"Current User (confirmed: {state.ServiceAccountName})"
                    : "Current User (recommended)",
                ServiceAccountKind.NetworkService => "Network Service",
                _ => "Local System",
            };
        }
        else
        {
            ServiceAccountRow.Visibility = Visibility.Collapsed;
        }
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
