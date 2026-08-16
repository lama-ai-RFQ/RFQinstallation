using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using RfqInstaller.Core.Security;
using RfqInstaller.Demo.Logging;
using RfqInstaller.Demo.Models;

namespace RfqInstaller.Demo.Pages;

/// <summary>
/// Its own wizard step (only inserted when Mode == WindowsService and ServiceAccount ==
/// CurrentUser — see MainWindow's NextStep/PreviousStep) rather than something InstallingPage
/// triggers as a side effect. That way a cancelled/failed Windows Security prompt leaves the user
/// sitting right here, with Back/Try Again/switch-account all available, instead of jumping into
/// the "Installing" step before anything has actually been confirmed.
/// </summary>
public partial class ServiceAccountConfirmPage : UserControl, IWizardPage
{
    private readonly WizardState _state;
    private readonly Action<WizardStep> _onNavigateTo;

    public ServiceAccountConfirmPage(WizardState state, Action<WizardStep> onNavigateTo)
    {
        InitializeComponent();
        _state = state;
        _onNavigateTo = onNavigateTo;

        ExplanationText.Text = _state.UseCredentialManager
            ? "You chose to run the RFQ Application service as your own Windows account, so it can use passwords saved in your Windows Credential Manager. Windows needs your account's own password to set this up — asked once here, by Windows itself, never stored by the installer. This account does not need to be an administrator; that was a separate, already-completed step."
            : "You chose to run the RFQ Application service as your own Windows account. Windows still needs your account's own password to configure the service to log on as you — asked once here, by Windows itself, never stored by the installer. This account does not need to be an administrator; that was a separate, already-completed step.";
    }

    private void ServiceAccountConfirmPage_Loaded(object sender, RoutedEventArgs e)
    {
        if (_state.ServiceAccountConfirmed)
        {
            ShowConfirmed();
            return;
        }

        RequestCredential();
    }

    private void RequestCredential()
    {
        WaitingPanel.Visibility = Visibility.Visible;
        ConfirmedPanel.Visibility = Visibility.Collapsed;
        NeededPanel.Visibility = Visibility.Collapsed;

        var owner = Window.GetWindow(this);
        var hwnd = owner is not null ? new WindowInteropHelper(owner).Handle : IntPtr.Zero;

        WindowsAccountCredentials? credentials;
        try
        {
            credentials = Application.Current.Dispatcher.Invoke(() => WindowsCredentialPrompt.Request(hwnd));
        }
        catch (Exception ex)
        {
            var logPath = InstallerLog.Write("asking Windows for the service account", ex);
            ShowNeeded($"Windows couldn't show the account/password dialog ({InstallerLog.FormatUserDetail(ex)}). Details were saved to {logPath}.");
            return;
        }

        if (credentials is null)
        {
            ShowNeeded("Windows Security was closed without entering a password. Pick how you'd like to continue.");
            return;
        }

        _state.ServiceAccountName = credentials.AccountName;
        _state.ServiceAccountPassword = credentials.Password;
        _state.ServiceAccountConfirmed = true;
        ShowConfirmed();
    }

    private void ShowConfirmed()
    {
        WaitingPanel.Visibility = Visibility.Collapsed;
        NeededPanel.Visibility = Visibility.Collapsed;
        ConfirmedAccountText.Text = $"Confirmed: {_state.ServiceAccountName}";
        ConfirmedPanel.Visibility = Visibility.Visible;
    }

    private void ShowNeeded(string message)
    {
        _state.ServiceAccountConfirmed = false;
        WaitingPanel.Visibility = Visibility.Collapsed;
        ConfirmedPanel.Visibility = Visibility.Collapsed;
        NeededText.Text = message;
        NeededPanel.Visibility = Visibility.Visible;
    }

    private void CredentialRetryButton_Click(object sender, RoutedEventArgs e) => RequestCredential();

    private void ChangeServiceAccountButton_Click(object sender, RoutedEventArgs e) => _onNavigateTo(WizardStep.Advanced);

    private void SwitchToStandaloneButton_Click(object sender, RoutedEventArgs e)
    {
        _state.Mode = InstallMode.Standalone;
        _onNavigateTo(WizardStep.InstallMode);
    }

    public bool Validate() => _state.ServiceAccountConfirmed;
}
