using System.Windows;
using System.Windows.Controls;
using RfqInstaller.Demo.Models;

namespace RfqInstaller.Demo.Pages;

public partial class AdvancedOptionsPage : UserControl, IWizardPage
{
    private readonly WizardState _state;

    public AdvancedOptionsPage(WizardState state)
    {
        InitializeComponent();
        _state = state;

        ServerUrlTextBox.Text = _state.ServerUrl;

        if (_state.AutoGenerateEncryptionKey)
        {
            AutoKeyRadio.IsChecked = true;
        }
        else
        {
            CustomKeyRadio.IsChecked = true;
            CustomKeyTextBox.Text = _state.CustomEncryptionKey;
        }

        ServiceAccountCombo.SelectedIndex = _state.ServiceAccount switch
        {
            ServiceAccountKind.NetworkService => 1,
            ServiceAccountKind.CurrentUser => 2,
            _ => 0,
        };

        CleanReinstallCheck.IsChecked = _state.CleanReinstall;
        CleanupAfterCheck.IsChecked = _state.CleanupAfterInstall;
    }

    private void ServerUrlTextBox_TextChanged(object sender, TextChangedEventArgs e) => _state.ServerUrl = ServerUrlTextBox.Text;

    private void AutoKeyRadio_Checked(object sender, RoutedEventArgs e)
    {
        _state.AutoGenerateEncryptionKey = true;
        if (CustomKeyTextBox is not null) CustomKeyTextBox.Visibility = Visibility.Collapsed;
    }

    private void CustomKeyRadio_Checked(object sender, RoutedEventArgs e)
    {
        _state.AutoGenerateEncryptionKey = false;
        if (CustomKeyTextBox is not null) CustomKeyTextBox.Visibility = Visibility.Visible;
    }

    private void CustomKeyTextBox_TextChanged(object sender, TextChangedEventArgs e) => _state.CustomEncryptionKey = CustomKeyTextBox.Text;

    private void ServiceAccountCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        _state.ServiceAccount = ServiceAccountCombo.SelectedIndex switch
        {
            1 => ServiceAccountKind.NetworkService,
            2 => ServiceAccountKind.CurrentUser,
            _ => ServiceAccountKind.LocalSystem,
        };

        if (ServiceAccountPasswordPanel is not null)
        {
            ServiceAccountPasswordPanel.Visibility = _state.ServiceAccount == ServiceAccountKind.CurrentUser
                ? Visibility.Visible
                : Visibility.Collapsed;
        }
    }

    private void ServiceAccountPasswordBox_PasswordChanged(object sender, RoutedEventArgs e) =>
        _state.ServiceAccountPassword = ServiceAccountPasswordBox.Password;

    private void CleanReinstallCheck_Changed(object sender, RoutedEventArgs e) => _state.CleanReinstall = CleanReinstallCheck.IsChecked == true;

    private void CleanupAfterCheck_Changed(object sender, RoutedEventArgs e) => _state.CleanupAfterInstall = CleanupAfterCheck.IsChecked == true;

    public bool Validate()
    {
        if (_state.ServiceAccount == ServiceAccountKind.CurrentUser && string.IsNullOrEmpty(_state.ServiceAccountPassword))
        {
            ServiceAccountPasswordBox.Focus();
            return false;
        }

        return true;
    }
}
