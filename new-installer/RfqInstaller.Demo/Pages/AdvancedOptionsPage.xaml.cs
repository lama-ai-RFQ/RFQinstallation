using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using RfqInstaller.Demo.Models;

namespace RfqInstaller.Demo.Pages;

public partial class AdvancedOptionsPage : UserControl, IWizardPage
{
    private static readonly SolidColorBrush WarningBrush = new(Color.FromRgb(0x8A, 0x00, 0x00));

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

        if (_state.UseCredentialManager)
        {
            CredentialManagerRadio.IsChecked = true;
        }
        else
        {
            EnvFileRadio.IsChecked = true;
        }

        ServiceAccountCombo.SelectedIndex = _state.ServiceAccount switch
        {
            ServiceAccountKind.NetworkService => 1,
            ServiceAccountKind.LocalSystem => 2,
            _ => 0,
        };

        // Only a Windows Service has an account to run as; Standalone runs as whoever launches it.
        ServiceAccountSection.Visibility = _state.Mode == InstallMode.WindowsService
            ? Visibility.Visible
            : Visibility.Collapsed;

        CleanReinstallCheck.IsChecked = _state.CleanReinstall;
        CleanupAfterCheck.IsChecked = _state.CleanupAfterInstall;
        UpdateCredentialManagerAvailability();
        UpdateHelpText();
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

    private void CredentialManagerRadio_Checked(object sender, RoutedEventArgs e)
    {
        _state.UseCredentialManager = true;
        UpdateHelpText();
    }

    private void EnvFileRadio_Checked(object sender, RoutedEventArgs e)
    {
        _state.UseCredentialManager = false;
        UpdateHelpText();
    }

    private void ServiceAccountCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        _state.ServiceAccount = ServiceAccountCombo.SelectedIndex switch
        {
            1 => ServiceAccountKind.NetworkService,
            2 => ServiceAccountKind.LocalSystem,
            _ => ServiceAccountKind.CurrentUser,
        };
        UpdateCredentialManagerAvailability();
        UpdateHelpText();
    }

    /// <summary>
    /// Credential Manager only actually works when the service also runs as Current User — rather
    /// than allowing a combination that would silently fall back at install time, disable the
    /// option outright and force .env for as long as the combination doesn't work.
    /// </summary>
    private void UpdateCredentialManagerAvailability()
    {
        var credentialManagerViable = _state.Mode == InstallMode.Standalone || _state.ServiceAccount == ServiceAccountKind.CurrentUser;

        CredentialManagerRadio.IsEnabled = credentialManagerViable;
        // When Credential Manager isn't viable, .env isn't really a choice anymore — it's the only
        // option — so lock both radios (greyed) rather than leaving .env looking like an active pick.
        EnvFileRadio.IsEnabled = credentialManagerViable;
        if (!credentialManagerViable && CredentialManagerRadio.IsChecked == true)
        {
            EnvFileRadio.IsChecked = true; // fires EnvFileRadio_Checked, which updates _state and help text
        }
    }

    private void UpdateHelpText()
    {
        if (PasswordStorageHelp is null || ServiceAccountHelp is null)
        {
            return;
        }

        if (!_state.UseCredentialManager)
        {
            PasswordStorageHelp.Text = CredentialManagerRadio.IsEnabled
                ? "Passwords will be written in plain text to the app's .env file. Anyone with file access to the install folder can read them."
                : "Passwords will be written in plain text to the app's .env file — Windows Credential Manager doesn't work with the service account selected below.";
            PasswordStorageHelp.Foreground = WarningBrush;
        }
        else
        {
            PasswordStorageHelp.Text = "Passwords will be stored in Windows Credential Manager, not written anywhere in plain text.";
            PasswordStorageHelp.Foreground = (Brush)FindResource("TextSecondaryBrush");
        }

        ServiceAccountHelp.Text = _state.ServiceAccount switch
        {
            ServiceAccountKind.CurrentUser =>
                "Recommended. Windows will separately ask you to confirm this account's own password on the next page — a one-time step for the service to log on as this account, unrelated to administrator rights.",
            ServiceAccountKind.NetworkService =>
                "No password is needed for this account. It cannot use Windows Credential Manager — see the note above.",
            _ =>
                "No password is needed for this account. It cannot use Windows Credential Manager — see the note above.",
        };
    }

    private void CleanReinstallCheck_Changed(object sender, RoutedEventArgs e) => _state.CleanReinstall = CleanReinstallCheck.IsChecked == true;

    private void CleanupAfterCheck_Changed(object sender, RoutedEventArgs e) => _state.CleanupAfterInstall = CleanupAfterCheck.IsChecked == true;

    public bool Validate() => true;
}
