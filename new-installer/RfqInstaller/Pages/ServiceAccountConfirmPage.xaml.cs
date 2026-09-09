using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Threading;
using RfqInstaller.Core.Security;
using RfqInstaller.Logging;
using RfqInstaller.Models;

namespace RfqInstaller.Pages;

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
        ShowUnconfirmedHeader();
        if (!_state.ServiceAccountConfirmed)
        {
            WaitingPanel.Visibility = Visibility.Visible;
        }
    }

    private bool _credentialPromptOpen;

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
        ShowUnconfirmedHeader();
        WaitingPanel.Visibility = Visibility.Visible;
        ConfirmedPanel.Visibility = Visibility.Collapsed;
        NeededPanel.Visibility = Visibility.Collapsed;

        // CredUI blocks the UI thread. Defer it until this page, the footer, and the rail have
        // actually painted — otherwise Next from Advanced opens the Windows dialog while the
        // wizard is still visually on Advanced options.
        Dispatcher.BeginInvoke(PromptWindows, DispatcherPriority.ApplicationIdle);
    }

    private void PromptWindows()
    {
        if (_credentialPromptOpen)
        {
            return;
        }

        _credentialPromptOpen = true;
        var owner = Window.GetWindow(this);
        var hwnd = owner is not null ? new WindowInteropHelper(owner).Handle : IntPtr.Zero;

        WindowsAccountCredentials? credentials;
        try
        {
            credentials = WindowsCredentialPrompt.Request(hwnd);
        }
        catch (Exception ex)
        {
            var logPath = InstallerLog.Write("asking Windows for the service account", ex);
            ShowNeeded($"Windows couldn't show the account/password dialog ({InstallerLog.FormatUserDetail(ex)}). Details were saved to {logPath}.");
            return;
        }
        finally
        {
            _credentialPromptOpen = false;
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
        TitleText.Text = "Windows account confirmed";
        ExplanationText.Visibility = Visibility.Collapsed;
        WaitingPanel.Visibility = Visibility.Collapsed;
        NeededPanel.Visibility = Visibility.Collapsed;
        ConfirmedAccountText.Text = $"Confirmed: {_state.ServiceAccountName}";
        ConfirmedPanel.Visibility = Visibility.Visible;
    }

    private void ShowNeeded(string message)
    {
        ShowUnconfirmedHeader();
        _state.ServiceAccountConfirmed = false;
        WaitingPanel.Visibility = Visibility.Collapsed;
        ConfirmedPanel.Visibility = Visibility.Collapsed;
        NeededText.Text = message;
        NeededPanel.Visibility = Visibility.Visible;
    }

    private void ShowUnconfirmedHeader()
    {
        TitleText.Text = "Confirm your Windows account";
        ExplanationText.Text = _state.UseCredentialManager
            ? "You chose to run the RFQ Application service as your own Windows account, so it can use passwords saved in your Windows Credential Manager. Windows will ask for this account's password once — a PIN or Windows Hello cannot be used for a service. This account does not need to be an administrator; that was a separate, already-completed step."
            : "You chose to run the RFQ Application service as your own Windows account. Windows will ask for this account's password once so the service can log on as you — a PIN or Windows Hello cannot be used for a service. This account does not need to be an administrator; that was a separate, already-completed step.";
        ExplanationText.Visibility = Visibility.Visible;
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
