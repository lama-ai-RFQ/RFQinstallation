using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using RfqInstaller.Core.Models;
using RfqInstaller.Core.Orchestration;
using RfqInstaller.Core.Security;
using RfqInstaller.Demo.Logging;
using RfqInstaller.Demo.Models;
using CoreServiceAccountKind = RfqInstaller.Core.Models.ServiceAccountKind;
using CoreInstallMode = RfqInstaller.Core.Models.InstallMode;

namespace RfqInstaller.Demo.Pages;

public partial class InstallingPage : UserControl
{
    private readonly WizardState _state;
    private readonly Action _onSuccess;
    private readonly Action<WizardStep> _onNavigateTo;
    private CancellationTokenSource? _cts;
    private bool _started;

    public InstallingPage(WizardState state, Action onSuccess, Action<WizardStep> onNavigateTo)
    {
        InitializeComponent();
        _state = state;
        _onSuccess = onSuccess;
        _onNavigateTo = onNavigateTo;
    }

    private async void InstallingPage_Loaded(object sender, RoutedEventArgs e)
    {
        if (_started)
        {
            return;
        }

        _started = true;
        await RunInstallAsync();
    }

    private async Task RunInstallAsync()
    {
        ProgressPanel.Visibility = Visibility.Visible;
        CredentialNeededPanel.Visibility = Visibility.Collapsed;
        ErrorPanel.Visibility = Visibility.Collapsed;
        Progress.Value = 0;
        PercentText.Text = "0%";
        CurrentStepText.Text = "Starting...";
        DetailText.Text = string.Empty;

        _cts = new CancellationTokenSource();

        string? serviceAccountName = null;
        string? serviceAccountPassword = null;
        if (_state.Mode == Models.InstallMode.WindowsService
            && _state.ServiceAccount == Models.ServiceAccountKind.CurrentUser)
        {
            CurrentStepText.Text = "Waiting for Windows account...";
            var owner = Window.GetWindow(this);
            var hwnd = owner is not null ? new WindowInteropHelper(owner).Handle : IntPtr.Zero;
            WindowsAccountCredentials? credentials;
            try
            {
                credentials = Application.Current.Dispatcher.Invoke(
                    () => WindowsCredentialPrompt.Request(hwnd));
            }
            catch (Exception ex)
            {
                var logPath = InstallerLog.Write("asking Windows for the service account", ex);
                ShowCredentialNeeded(
                    "Windows couldn't show the account/password dialog "
                    + $"({InstallerLog.FormatUserDetail(ex)}). Details were saved to {logPath}.");
                return;
            }

            if (credentials is null)
            {
                ShowCredentialNeeded("Windows Security was closed without entering a password, so the service wasn't configured yet. Nothing has been installed — pick how you'd like to continue.");
                return;
            }

            serviceAccountName = credentials.AccountName;
            serviceAccountPassword = credentials.Password;
        }

        // Nothing above this point touches the system — only from here does the orchestrator
        // start downloading files, provisioning the database, and registering services. That's
        // the actual "installation," so only a failure at or after this point is treated as one.
        var plan = BuildInstallPlan(serviceAccountName, serviceAccountPassword);
        var baseDirectory = AppContext.BaseDirectory;
        var orchestrator = new InstallOrchestrator(
            Path.Combine(baseDirectory, "Bundled", "nssm.exe"),
            Path.Combine(baseDirectory, "Bundled", "windows_updater.exe"));

        var progress = new Progress<InstallStepProgress>(p =>
        {
            Progress.Value = p.FractionComplete * 100;
            PercentText.Text = $"{(int)(p.FractionComplete * 100)}%";
            CurrentStepText.Text = p.StepName;
            DetailText.Text = p.Detail ?? string.Empty;
        });

        InstallResult result;
        try
        {
            result = await orchestrator.RunAsync(plan, progress, _cts.Token);
        }
        catch (Exception ex)
        {
            var logPath = InstallerLog.Write("installing RFQ Application", ex);
            result = new InstallResult(
                false,
                $"{InstallerLog.FormatUserDetail(ex)}{Environment.NewLine}{Environment.NewLine}Details were saved to:{Environment.NewLine}{logPath}",
                null);
        }

        if (result.Success)
        {
            _state.ResolvedMainExecutablePath = result.MainExecutablePath;
            _state.InstallErrorMessage = null;
            _onSuccess();
        }
        else
        {
            FailInstall(result.ErrorMessage ?? "An unknown error occurred during installation.");
        }
    }

    /// <summary>
    /// The Windows account/password step happens before any real install work starts, so a
    /// cancellation or failure there isn't a broken install — it's a request for different input.
    /// Offers concrete next steps instead of the generic failure panel.
    /// </summary>
    private void ShowCredentialNeeded(string message)
    {
        ProgressPanel.Visibility = Visibility.Collapsed;
        CredentialNeededText.Text = message;
        CredentialNeededPanel.Visibility = Visibility.Visible;
    }

    private void FailInstall(string message)
    {
        if (!message.Contains(InstallerLog.LogPath, StringComparison.OrdinalIgnoreCase))
        {
            InstallerLog.Write("installation stopped", extra: message);
        }

        _state.InstallErrorMessage = message;
        ProgressPanel.Visibility = Visibility.Collapsed;
        ErrorText.Text = message;
        ErrorPanel.Visibility = Visibility.Visible;
    }

    private InstallPlan BuildInstallPlan(string? serviceAccountName, string? serviceAccountPassword) => new()
    {
        LicenseKey = _state.LicenseKey,
        Mode = _state.Mode == Models.InstallMode.WindowsService ? CoreInstallMode.WindowsService : CoreInstallMode.Standalone,
        InstallPath = _state.InstallPath,
        CreateDesktopShortcut = _state.CreateDesktopShortcut,
        LaunchAfterFinish = _state.LaunchAfterFinish,
        DownloadModelNow = _state.DownloadModelNow,
        ModelPath = _state.ModelPath,
        CleanReinstall = _state.CleanReinstall,
        CleanupAfterInstall = _state.CleanupAfterInstall,
        SettingsPassword = _state.SettingsPassword,
        ServerUrl = _state.ServerUrl,
        AutoGenerateEncryptionKey = _state.AutoGenerateEncryptionKey,
        CustomEncryptionKey = string.IsNullOrWhiteSpace(_state.CustomEncryptionKey) ? null : _state.CustomEncryptionKey,
        ServiceAccount = _state.ServiceAccount switch
        {
            Models.ServiceAccountKind.NetworkService => CoreServiceAccountKind.NetworkService,
            Models.ServiceAccountKind.CurrentUser => CoreServiceAccountKind.CurrentUser,
            _ => CoreServiceAccountKind.LocalSystem,
        },
        ServiceAccountName = serviceAccountName,
        ServiceAccountPassword = serviceAccountPassword,
    };

    private async void RetryButton_Click(object sender, RoutedEventArgs e) => await RunInstallAsync();

    private void BackToReviewButton_Click(object sender, RoutedEventArgs e) => _onNavigateTo(WizardStep.ReadyToInstall);

    private async void CredentialRetryButton_Click(object sender, RoutedEventArgs e) => await RunInstallAsync();

    private void ChangeServiceAccountButton_Click(object sender, RoutedEventArgs e) => _onNavigateTo(WizardStep.Advanced);

    private void SwitchToStandaloneButton_Click(object sender, RoutedEventArgs e)
    {
        _state.Mode = Models.InstallMode.Standalone;
        _onNavigateTo(WizardStep.InstallMode);
    }
}
