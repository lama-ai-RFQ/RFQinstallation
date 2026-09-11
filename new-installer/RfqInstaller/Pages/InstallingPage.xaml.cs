using System.IO;
using System.Windows;
using System.Windows.Controls;
using RfqInstaller.Core.Licensing;
using RfqInstaller.Core.Models;
using RfqInstaller.Core.Orchestration;
using RfqInstaller.Dialogs;
using RfqInstaller.Logging;
using RfqInstaller.Models;
using CoreServiceAccountKind = RfqInstaller.Core.Models.ServiceAccountKind;
using CoreInstallMode = RfqInstaller.Core.Models.InstallMode;

namespace RfqInstaller.Pages;

/// <summary>
/// Purely the real install work — the Windows-account credential (when needed) is obtained
/// earlier by ServiceAccountConfirmPage, a real wizard step of its own, so this page can assume it
/// already has everything it needs and never has to distinguish "need different input" from
/// "something actually broke."
/// </summary>
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
        ErrorPanel.Visibility = Visibility.Collapsed;
        Progress.Value = 0;
        PercentText.Text = "0%";
        CurrentStepText.Text = "Starting...";
        DetailText.Text = string.Empty;

        _cts = new CancellationTokenSource();

        var plan = BuildInstallPlan();
        var baseDirectory = AppContext.BaseDirectory;
        var orchestrator = new InstallOrchestrator(
            Path.Combine(baseDirectory, "Bundled", "nssm.exe"),
            interaction: new WpfInstallInteraction());

        var progress = new Progress<InstallStepProgress>(p =>
        {
            var reportedPercent = Math.Clamp(p.FractionComplete * 100, 0, 100);
            // Progress<T> callbacks are posted asynchronously. A callback from an earlier stage
            // can therefore arrive after a later one; discard it instead of moving the UI back.
            if (reportedPercent < Progress.Value)
            {
                return;
            }

            Progress.Value = reportedPercent;
            PercentText.Text = $"{(int)Math.Round(reportedPercent)}%";
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
            FailInstall(
                result.ErrorMessage ?? "An unknown error occurred during installation.",
                result.Cause);
        }
    }

    private void FailInstall(string message, Exception? cause = null)
    {
        if (!message.Contains(InstallerLog.LogPath, StringComparison.OrdinalIgnoreCase))
        {
            InstallerLog.Write("installation stopped", cause, extra: message);
        }

        _state.InstallErrorMessage = message;
        ProgressPanel.Visibility = Visibility.Collapsed;
        ErrorText.Text = message;
        ErrorPanel.Visibility = Visibility.Visible;
        Dispatcher.BeginInvoke(() =>
        {
            RetryButton.Focus();
            RetryButton.BringIntoView();
        });
    }

    private InstallPlan BuildInstallPlan() => new()
    {
        LicenseKey = _state.LicenseKey,
        Mode = _state.Mode == Models.InstallMode.WindowsService ? CoreInstallMode.WindowsService : CoreInstallMode.Standalone,
        InstallPath = _state.InstallPath,
        CreateDesktopShortcut = _state.CreateDesktopShortcut,
        LaunchAfterFinish = _state.LaunchAfterFinish,
        CleanReinstall = _state.CleanReinstall,
        CleanupAfterInstall = _state.CleanupAfterInstall,
        SettingsPassword = _state.SettingsPassword,
        ServerUrl = _state.ServerUrl,
        AutoGenerateEncryptionKey = _state.AutoGenerateEncryptionKey,
        CustomEncryptionKey = string.IsNullOrWhiteSpace(_state.CustomEncryptionKey) ? null : _state.CustomEncryptionKey,
        AutoGeneratePostgresPasswords = _state.AutoGeneratePostgresPasswords,
        CustomSqlSuperUserPassword = string.IsNullOrWhiteSpace(_state.CustomSqlSuperUserPassword)
            ? null
            : _state.CustomSqlSuperUserPassword,
        CustomRfqUserPassword = string.IsNullOrWhiteSpace(_state.CustomRfqUserPassword)
            ? null
            : _state.CustomRfqUserPassword,
        UseCredentialManager = _state.UseCredentialManager,
        ServiceAccount = _state.ServiceAccount switch
        {
            Models.ServiceAccountKind.NetworkService => CoreServiceAccountKind.NetworkService,
            Models.ServiceAccountKind.CurrentUser => CoreServiceAccountKind.CurrentUser,
            _ => CoreServiceAccountKind.LocalSystem,
        },
        ServiceAccountName = string.IsNullOrEmpty(_state.ServiceAccountName) ? null : _state.ServiceAccountName,
        ServiceAccountPassword = string.IsNullOrEmpty(_state.ServiceAccountPassword) ? null : _state.ServiceAccountPassword,
    };

    private async void RetryButton_Click(object sender, RoutedEventArgs e)
    {
        var licenseCheck = LocalLicenseValidator.Validate(_state.LicenseKey);
        if (!licenseCheck.SignatureValid || licenseCheck.Expired)
        {
            _onNavigateTo(WizardStep.License);
            return;
        }

        await RunInstallAsync();
    }

    private void BackToReviewButton_Click(object sender, RoutedEventArgs e) => _onNavigateTo(WizardStep.ReadyToInstall);
}
