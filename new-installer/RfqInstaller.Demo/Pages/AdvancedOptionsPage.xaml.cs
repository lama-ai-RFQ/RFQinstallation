using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
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
            ServiceAccountKind.LocalSystem => 2,
            _ => 0,
        };

        CleanReinstallCheck.IsChecked = _state.CleanReinstall;
        CleanupAfterCheck.IsChecked = _state.CleanupAfterInstall;
        UpdateServiceAccountHelp();
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
            2 => ServiceAccountKind.LocalSystem,
            _ => ServiceAccountKind.CurrentUser,
        };
        UpdateServiceAccountHelp();
    }

    private void UpdateServiceAccountHelp()
    {
        if (ServiceAccountHelp is null)
        {
            return;
        }

        ServiceAccountHelp.Text = _state.ServiceAccount switch
        {
            ServiceAccountKind.CurrentUser =>
                "Recommended. The service can use passwords stored in your Windows Credential Manager. " +
                "Windows will separately ask you to confirm this account's own password on the next page — a one-time step for the service to log on as this account, unrelated to administrator rights.",
            ServiceAccountKind.NetworkService =>
                "Network Service cannot use your Windows Credential Manager. To use those credentials, change the service to a user account after installation. No password is needed for this account.",
            _ =>
                "Local System cannot use your Windows Credential Manager. To use those credentials, change the service to a user account after installation. No password is needed for this account.",
        };
        ServiceAccountHelp.Foreground = _state.ServiceAccount == ServiceAccountKind.CurrentUser
            ? (Brush)FindResource("TextSecondaryBrush")
            : new SolidColorBrush(Color.FromRgb(0x8A, 0x00, 0x00));
    }

    private void CleanReinstallCheck_Changed(object sender, RoutedEventArgs e) => _state.CleanReinstall = CleanReinstallCheck.IsChecked == true;

    private void CleanupAfterCheck_Changed(object sender, RoutedEventArgs e) => _state.CleanupAfterInstall = CleanupAfterCheck.IsChecked == true;

    public bool Validate() => true;
}
