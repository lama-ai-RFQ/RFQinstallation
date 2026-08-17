using System.Windows;
using System.Windows.Controls;
using RfqInstaller.Core.Licensing;
using RfqInstaller.Demo.Dialogs;
using RfqInstaller.Demo.Models;

namespace RfqInstaller.Demo.Pages;

public partial class LicenseKeyPage : UserControl, IWizardPage
{
    private readonly WizardState _state;

    public LicenseKeyPage(WizardState state)
    {
        InitializeComponent();
        _state = state;
        LicenseKeyTextBox.Text = _state.LicenseKey;
    }

    private void LicenseKeyTextBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        _state.LicenseKey = LicenseKeyTextBox.Text;
        if (ErrorText.Visibility == Visibility.Visible)
        {
            ErrorText.Visibility = Visibility.Collapsed;
        }
    }

    private void NoKeyLink_Click(object sender, RoutedEventArgs e)
    {
        AppDialog.Inform(
            Window.GetWindow(this),
            "Don't have a key?",
            "Contact your RFQ Application account representative to obtain a license key.");
    }

    public bool Validate()
    {
        if (string.IsNullOrWhiteSpace(_state.LicenseKey))
        {
            ShowError("Please enter a license key to continue.");
            return false;
        }

        // Offline signature/expiration check only — this is fast, instant feedback. The
        // authoritative check (and the credentials/config it unlocks) happens against the
        // license-broker during install (see InstallOrchestrator), since a network call here
        // would make every Back/Next navigation block on it.
        var check = LocalLicenseValidator.Validate(_state.LicenseKey);
        if (!check.SignatureValid || check.Expired)
        {
            ShowError(check.Message);
            return false;
        }

        return true;
    }

    private void ShowError(string message)
    {
        ErrorText.Text = message;
        ErrorText.Visibility = Visibility.Visible;
        LicenseKeyTextBox.Focus();
    }
}
