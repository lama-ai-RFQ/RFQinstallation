using System.Windows;
using System.Windows.Controls;
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
        if (ErrorText.Visibility == Visibility.Visible && !string.IsNullOrWhiteSpace(_state.LicenseKey))
        {
            ErrorText.Visibility = Visibility.Collapsed;
        }
    }

    private void NoKeyLink_Click(object sender, RoutedEventArgs e)
    {
        MessageBox.Show(
            "Contact your RFQ Application account representative to obtain a license key.",
            "License Key",
            MessageBoxButton.OK,
            MessageBoxImage.Information);
    }

    public bool Validate()
    {
        if (string.IsNullOrWhiteSpace(_state.LicenseKey))
        {
            ErrorText.Visibility = Visibility.Visible;
            LicenseKeyTextBox.Focus();
            return false;
        }

        return true;
    }
}
