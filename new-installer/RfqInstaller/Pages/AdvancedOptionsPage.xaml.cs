using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using RfqInstaller.Core.Config;
using RfqInstaller.Core.Database;
using RfqInstaller.Dialogs;
using RfqInstaller.Models;

namespace RfqInstaller.Pages;

public partial class AdvancedOptionsPage : UserControl, IWizardPage
{
    private static readonly SolidColorBrush WarningBrush = new(Color.FromRgb(0x8A, 0x00, 0x00));

    private const int MinPostgresPasswordLength = 8;

    private readonly WizardState _state;
    private readonly string? _existingEncryptionKey;
    private readonly bool _existingPostgresCluster;
    private bool _suppressKeyEvents;
    private bool _suppressPostgresPasswordEvents;
    private bool _generateNewConfirmed;

    public AdvancedOptionsPage(WizardState state)
    {
        InitializeComponent();
        _state = state;
        _existingEncryptionKey = EncryptionKeyResolver.ResolveFromInstallPath(_state.InstallPath);
        _existingPostgresCluster = PostgresProvisioner.IsAlreadyInitialized(_state.InstallPath);

        ServerUrlTextBox.Text = _state.ServerUrl;

        ApplyEncryptionKeyUi();
        ApplyPostgresPasswordUi();

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

        // Same detection signal as the encryption-key section above (an .env at this install path
        // means something was already installed here) — old installer showed this page/its
        // checkboxes unconditionally, even on a totally fresh machine, which read as confusing
        // "reinstall" language with nothing to reinstall over. Only show it when it actually applies.
        ReinstallingSection.Visibility = File.Exists(Path.Combine(_state.InstallPath, ".env"))
            ? Visibility.Visible
            : Visibility.Collapsed;

        UpdateCredentialManagerAvailability();
        UpdateHelpText();
    }

    private void ServerUrlTextBox_TextChanged(object sender, TextChangedEventArgs e) => _state.ServerUrl = ServerUrlTextBox.Text;

    private void ApplyEncryptionKeyUi()
    {
        _suppressKeyEvents = true;
        try
        {
            if (_existingEncryptionKey is null)
            {
                // First install: generate only — no paste field.
                EncryptionKeyHelp.Text =
                    "This key encrypts secrets stored in the database. We'll create one and save it as AZURE_CONFIG_ENCRYPTION_KEY in the app's .env file. You don't need to enter it. If this key is lost, those secrets cannot be recovered — keep a backup of .env.";
                EncryptionKeyChoicePanel.Visibility = Visibility.Collapsed;
                _state.AutoGenerateEncryptionKey = true;
                _state.CustomEncryptionKey = string.Empty;
                return;
            }

            EncryptionKeyHelp.Text =
                "An encryption key was found in this folder's .env file. Keep it so the app can still read secrets already in the database.";
            EncryptionKeyChoicePanel.Visibility = Visibility.Visible;
            AutoKeyRadio.Content = "Generate a new key";
            CustomKeyRadio.Content = "Keep the existing key (recommended)";

            _state.AutoGenerateEncryptionKey = false;
            _state.CustomEncryptionKey = _existingEncryptionKey;
            CustomKeyTextBox.Text = _existingEncryptionKey;
            CustomKeyRadio.IsChecked = true;
            ShowCustomKeyRow(true);
            GenerateNewWarning.Visibility = Visibility.Collapsed;
        }
        finally
        {
            _suppressKeyEvents = false;
        }
    }

    private void AutoKeyRadio_Checked(object sender, RoutedEventArgs e)
    {
        if (_suppressKeyEvents || AutoKeyRadio is null)
        {
            return;
        }

        if (_existingEncryptionKey is not null && !_generateNewConfirmed)
        {
            var confirmed = AppDialog.Confirm(
                Window.GetWindow(this),
                "Generate a new encryption key?",
                "Secrets already stored in the database will become unreadable. This cannot be undone.",
                confirmText: "Generate new key",
                dismissText: "Keep existing key");
            if (!confirmed)
            {
                _suppressKeyEvents = true;
                CustomKeyRadio.IsChecked = true;
                _suppressKeyEvents = false;
                return;
            }

            _generateNewConfirmed = true;
        }

        _state.AutoGenerateEncryptionKey = true;
        ShowCustomKeyRow(false);
        if (GenerateNewWarning is not null)
        {
            GenerateNewWarning.Visibility = _existingEncryptionKey is not null ? Visibility.Visible : Visibility.Collapsed;
        }

        HideEncryptionKeyError();
    }

    private void CustomKeyRadio_Checked(object sender, RoutedEventArgs e)
    {
        if (_suppressKeyEvents || CustomKeyRadio is null)
        {
            return;
        }

        _generateNewConfirmed = false;
        _state.AutoGenerateEncryptionKey = false;
        if (string.IsNullOrWhiteSpace(_state.CustomEncryptionKey) && _existingEncryptionKey is not null)
        {
            _state.CustomEncryptionKey = _existingEncryptionKey;
            CustomKeyTextBox.Text = _existingEncryptionKey;
        }

        ShowCustomKeyRow(true);
        if (GenerateNewWarning is not null)
        {
            GenerateNewWarning.Visibility = Visibility.Collapsed;
        }

        HideEncryptionKeyError();
    }

    private void CustomKeyTextBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        _state.CustomEncryptionKey = CustomKeyTextBox.Text;
        HideEncryptionKeyError();
    }

    private void CopyKeyButton_Click(object sender, RoutedEventArgs e)
    {
        if (!string.IsNullOrEmpty(_state.CustomEncryptionKey))
        {
            Clipboard.SetText(_state.CustomEncryptionKey);
        }
    }

    private void ShowCustomKeyRow(bool visible)
    {
        if (CustomKeyRow is not null)
        {
            CustomKeyRow.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        }
    }

    private void HideEncryptionKeyError()
    {
        if (EncryptionKeyError is not null)
        {
            EncryptionKeyError.Visibility = Visibility.Collapsed;
        }
    }

    private void ApplyPostgresPasswordUi()
    {
        SuperuserReuseNote.Visibility = _existingPostgresCluster ? Visibility.Visible : Visibility.Collapsed;
        SuperuserPasswordRow.Visibility = _existingPostgresCluster ? Visibility.Collapsed : Visibility.Visible;

        if (_state.AutoGeneratePostgresPasswords)
        {
            AutoPostgresPasswordRadio.IsChecked = true;
            CustomPostgresPasswordPanel.Visibility = Visibility.Collapsed;
        }
        else
        {
            CustomPostgresPasswordRadio.IsChecked = true;
            CustomPostgresPasswordPanel.Visibility = Visibility.Visible;
            RestorePostgresPasswordBoxes();
        }
    }

    private void AutoPostgresPasswordRadio_Checked(object sender, RoutedEventArgs e)
    {
        if (AutoPostgresPasswordRadio is null)
        {
            return;
        }

        _state.AutoGeneratePostgresPasswords = true;
        if (CustomPostgresPasswordPanel is not null)
        {
            CustomPostgresPasswordPanel.Visibility = Visibility.Collapsed;
        }

        HidePostgresPasswordError();
    }

    private void CustomPostgresPasswordRadio_Checked(object sender, RoutedEventArgs e)
    {
        if (CustomPostgresPasswordRadio is null)
        {
            return;
        }

        _state.AutoGeneratePostgresPasswords = false;
        CustomPostgresPasswordPanel.Visibility = Visibility.Visible;
        RestorePostgresPasswordBoxes();
        HidePostgresPasswordError();
    }

    private void SuperuserMaskedBox_PasswordChanged(object sender, RoutedEventArgs e) =>
        OnSuperuserPasswordChanged(SuperuserMaskedBox.Password);

    private void SuperuserPlainBox_TextChanged(object sender, TextChangedEventArgs e) =>
        OnSuperuserPasswordChanged(SuperuserPlainBox.Text);

    private void OnSuperuserPasswordChanged(string value)
    {
        if (_suppressPostgresPasswordEvents)
        {
            return;
        }

        _state.CustomSqlSuperUserPassword = value;
        UpdatePasswordMask(SuperuserMaskedBox, value);
        HidePostgresPasswordError();
    }

    private void RfqUserMaskedBox_PasswordChanged(object sender, RoutedEventArgs e) =>
        OnRfqUserPasswordChanged(RfqUserMaskedBox.Password);

    private void RfqUserPlainBox_TextChanged(object sender, TextChangedEventArgs e) =>
        OnRfqUserPasswordChanged(RfqUserPlainBox.Text);

    private void OnRfqUserPasswordChanged(string value)
    {
        if (_suppressPostgresPasswordEvents)
        {
            return;
        }

        _state.CustomRfqUserPassword = value;
        UpdatePasswordMask(RfqUserMaskedBox, value);
        HidePostgresPasswordError();
    }

    private void ShowPostgresPasswordsCheck_Changed(object sender, RoutedEventArgs e)
    {
        var show = ShowPostgresPasswordsCheck.IsChecked == true;
        RestorePostgresPasswordBoxes();
        SuperuserMaskedBox.Visibility = show ? Visibility.Collapsed : Visibility.Visible;
        SuperuserPlainBox.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        RfqUserMaskedBox.Visibility = show ? Visibility.Collapsed : Visibility.Visible;
        RfqUserPlainBox.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
    }

    private void RestorePostgresPasswordBoxes()
    {
        _suppressPostgresPasswordEvents = true;
        try
        {
            SuperuserPlainBox.Text = _state.CustomSqlSuperUserPassword;
            SuperuserMaskedBox.Password = _state.CustomSqlSuperUserPassword;
            RfqUserPlainBox.Text = _state.CustomRfqUserPassword;
            RfqUserMaskedBox.Password = _state.CustomRfqUserPassword;
        }
        finally
        {
            _suppressPostgresPasswordEvents = false;
        }

        UpdatePasswordMask(SuperuserMaskedBox, _state.CustomSqlSuperUserPassword);
        UpdatePasswordMask(RfqUserMaskedBox, _state.CustomRfqUserPassword);
    }

    private static void UpdatePasswordMask(PasswordBox box, string password)
    {
        box.Tag = string.IsNullOrEmpty(password) ? string.Empty : new string('\u2022', password.Length);
    }

    private void HidePostgresPasswordError()
    {
        if (PostgresPasswordError is not null)
        {
            PostgresPasswordError.Visibility = Visibility.Collapsed;
        }
    }

    private bool ValidatePostgresPasswords()
    {
        if (_state.AutoGeneratePostgresPasswords)
        {
            return true;
        }

        if (!_existingPostgresCluster &&
            _state.CustomSqlSuperUserPassword.Trim().Length < MinPostgresPasswordLength)
        {
            PostgresPasswordError.Text = $"The postgres superuser password must be at least {MinPostgresPasswordLength} characters.";
            PostgresPasswordError.Visibility = Visibility.Visible;
            return false;
        }

        if (_state.CustomRfqUserPassword.Trim().Length < MinPostgresPasswordLength)
        {
            PostgresPasswordError.Text = $"The rfq_user password must be at least {MinPostgresPasswordLength} characters.";
            PostgresPasswordError.Visibility = Visibility.Visible;
            return false;
        }

        return true;
    }

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
                "Recommended. Windows will ask for this account's password on the next page (not a PIN) so the service can log on as you.",
            ServiceAccountKind.NetworkService =>
                "No password is needed for this account. It cannot use Windows Credential Manager — see the note above.",
            _ =>
                "No password is needed for this account. It cannot use Windows Credential Manager — see the note above.",
        };
        ServiceAccountHelp.Foreground = (Brush)FindResource("TextSecondaryBrush");
    }

    private void CleanReinstallCheck_Changed(object sender, RoutedEventArgs e) => _state.CleanReinstall = CleanReinstallCheck.IsChecked == true;

    private void CleanupAfterCheck_Changed(object sender, RoutedEventArgs e) => _state.CleanupAfterInstall = CleanupAfterCheck.IsChecked == true;

    public bool Validate()
    {
        if (!ValidatePostgresPasswords())
        {
            return false;
        }

        if (_existingEncryptionKey is null)
        {
            _state.AutoGenerateEncryptionKey = true;
            return true;
        }

        if (_state.AutoGenerateEncryptionKey)
        {
            if (_generateNewConfirmed)
            {
                return true;
            }

            var confirmed = AppDialog.Confirm(
                Window.GetWindow(this),
                "Generate a new encryption key?",
                "Secrets already stored in the database will become unreadable. This cannot be undone.",
                confirmText: "Generate new key",
                dismissText: "Keep existing key");
            if (!confirmed)
            {
                _suppressKeyEvents = true;
                CustomKeyRadio.IsChecked = true;
                _suppressKeyEvents = false;
                _state.AutoGenerateEncryptionKey = false;
                _state.CustomEncryptionKey = _existingEncryptionKey;
                ShowCustomKeyRow(true);
                GenerateNewWarning.Visibility = Visibility.Collapsed;
                return false;
            }

            _generateNewConfirmed = true;
            return true;
        }

        if (string.IsNullOrWhiteSpace(_state.CustomEncryptionKey))
        {
            EncryptionKeyError.Text = "An encryption key is required when keeping or entering a specific key.";
            EncryptionKeyError.Visibility = Visibility.Visible;
            return false;
        }

        return true;
    }
}
