using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Input;
using RfqInstaller.Core.Elevation;
using RfqInstaller.Demo.Debug;
using RfqInstaller.Demo.Dialogs;
using RfqInstaller.Demo.Logging;
using RfqInstaller.Demo.Models;
using RfqInstaller.Demo.Pages;

namespace RfqInstaller.Demo;

public partial class MainWindow : Window
{
    private static readonly string[] RailTitles =
    {
        "Welcome",
        "License Key",
        "Setup Options",
        "Security",
        "Model & Advanced",
        "Ready to Install",
        "Installing",
        "Finish"
    };

    private readonly WizardState _state = new();
    private WizardStep _current = WizardStep.Welcome;
    private bool _fatalReported;

    public MainWindow()
    {
        InitializeComponent();

        if (InstallerDebug.Enabled)
        {
            DebugBadge.Visibility = Visibility.Visible;
        }

        if (TryLoadResumeState(out var resumed, out var resumeStep))
        {
            _state = resumed!;
            GoTo(resumeStep);
        }
        else
        {
            GoTo(WizardStep.Welcome);
        }
    }

    /// <summary>Written to the temp hand-off file whenever this process relaunches itself elevated — carries its own resume target so it can never drift out of sync with wherever elevation was actually triggered from.</summary>
    private class ElevationHandoff
    {
        public WizardState State { get; set; } = new();
        public WizardStep ResumeStep { get; set; }
    }

    /// <summary>
    /// If this process was relaunched elevated (see <see cref="HandleElevationIfNeeded"/>), the
    /// wizard state — and exactly which step to resume at — was handed off via a temp JSON file
    /// whose path is the sole command-line argument.
    /// </summary>
    private static bool TryLoadResumeState(out WizardState? state, out WizardStep resumeStep)
    {
        state = null;
        resumeStep = WizardStep.Welcome;
        var args = Environment.GetCommandLineArgs();
        if (args.Length != 2 || !File.Exists(args[1]))
        {
            return false;
        }

        try
        {
            var json = File.ReadAllText(args[1]);
            var handoff = JsonSerializer.Deserialize<ElevationHandoff>(json);
            state = handoff?.State;
            resumeStep = handoff?.ResumeStep ?? WizardStep.Welcome;
            File.Delete(args[1]);
            return state is not null;
        }
        catch
        {
            return false;
        }
    }

    private void TitleBar_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ClickCount == 1)
        {
            DragMove();
        }
    }

    private void Minimize_Click(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;

    private void Close_Click(object sender, RoutedEventArgs e) => Close();

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        if (AppDialog.Confirm(
            this,
            "Cancel setup?",
            "Are you sure you want to cancel RFQ Application setup?",
            confirmText: "Cancel setup",
            dismissText: "Continue"))
        {
            Close();
        }
    }

    private void Back_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            GoTo(GetPrevious(_current));
        }
        catch (Exception ex)
        {
            ReportFatalError(ex, $"going back from the {PageName(_current)}");
        }
    }

    private void Next_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            if (_current is WizardStep.Finish or WizardStep.Failed)
            {
                HandleFinish();
                return;
            }

            if (PageHost.Content is IWizardPage page && !page.Validate())
            {
                return;
            }

            // Elevate as early as each mode actually determines it's needed — never assuming the
            // current account is already an administrator, and never collecting so much as one
            // page of data before knowing whether elevation will even succeed:
            //  - Windows Service always needs it, decided the moment that's chosen, so a decline
            //    leaves "Run as a standalone application" one click away on the very same page.
            //  - Standalone only needs it if the install path itself turns out to be privileged
            //    (e.g. Program Files), which isn't known until InstallLocation is chosen.
            // Both reuse the same check/relaunch logic; it's a no-op once already elevated.
            if (_current == WizardStep.InstallMode && _state.Mode == InstallMode.WindowsService)
            {
                switch (HandleElevationIfNeeded(WizardStep.InstallLocation))
                {
                    case ElevationOutcome.RelaunchedElevated:
                        Close();
                        return;
                    case ElevationOutcome.Declined:
                        // Stay on InstallMode — Standalone is right there to switch to, or Next tries again.
                        return;
                }
            }
            else if (_current == WizardStep.InstallLocation)
            {
                switch (HandleElevationIfNeeded(GetNext(_current)))
                {
                    case ElevationOutcome.RelaunchedElevated:
                        Close();
                        return;
                    case ElevationOutcome.Declined:
                        return;
                }
            }

            GoTo(GetNext(_current));
        }
        catch (Exception ex)
        {
            ReportFatalError(ex, $"continuing from the {PageName(_current)}");
        }
    }

    private enum ElevationOutcome
    {
        NotNeeded,
        RelaunchedElevated,
        Declined,
    }

    /// <summary>
    /// Service installs (and standalone installs into a machine-wide folder like Program Files)
    /// need admin rights. Rather than always demanding elevation at startup like the old Inno
    /// installer, we only ask for it right before it's actually needed, and only once — but we
    /// explain why first, in our own dialog, before Windows' own UAC prompt appears, so it never
    /// just pops up out of nowhere. Never assumes the current account is already an administrator:
    /// whether Windows' own approval step ends up being a one-click consent or a full credential
    /// prompt depends on the account and the machine's policy, neither of which we assume here.
    /// </summary>
    private ElevationOutcome HandleElevationIfNeeded(WizardStep resumeStep)
    {
        if (ElevationHelper.IsElevated() || !ElevationHelper.RequiresElevation(
                _state.Mode == InstallMode.WindowsService ? Core.Models.InstallMode.WindowsService : Core.Models.InstallMode.Standalone,
                _state.InstallPath))
        {
            return ElevationOutcome.NotNeeded;
        }

        // This is about the *installer process* being allowed to register a Windows service and
        // write to a system folder — a Windows OS restriction that applies no matter which account
        // the service will run as. It's unrelated to the Current User password step later (if
        // applicable): that step never needs an administrator account, just some account's
        // password, and only happens after this one, on a separate page.
        if (!AppDialog.Confirm(
            this,
            "Administrator approval needed",
            "Registering a Windows service (or installing into a system folder) requires administrator approval for this installer, regardless of which account the service will run as. Windows will ask you to approve this now.",
            confirmText: "Continue",
            dismissText: "Cancel"))
        {
            return ElevationOutcome.Declined;
        }

        var tempFile = Path.Combine(Path.GetTempPath(), $"rfq-installer-state-{Guid.NewGuid():N}.json");
        File.WriteAllText(tempFile, JsonSerializer.Serialize(new ElevationHandoff { State = _state, ResumeStep = resumeStep }));

        var process = ElevationHelper.RelaunchElevated(new[] { tempFile });
        if (process is null)
        {
            // Declined (or failed) the actual UAC prompt — stay put. If Windows Service is still
            // selected, Next tries again; Standalone is available on the same page as an
            // immediate alternative that needs no approval at all (unless its install path is
            // itself privileged).
            TryDeleteQuietly(tempFile);
            AppDialog.Inform(this, "Administrator approval required",
                "Administrator approval wasn't given, so this can't continue as a Windows service (or into that folder) right now. Click Next to try again, or choose \"Run as a standalone application\" instead.");
            return ElevationOutcome.Declined;
        }

        return ElevationOutcome.RelaunchedElevated;
    }

    private static void TryDeleteQuietly(string path)
    {
        try { File.Delete(path); } catch { /* best-effort */ }
    }

    private void HandleFinish()
    {
        if (_current != WizardStep.Failed
            && _state.LaunchAfterFinish && _state.Mode == InstallMode.Standalone && _state.ResolvedMainExecutablePath is { } exePath && File.Exists(exePath))
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(exePath) { UseShellExecute = true });
        }
        else if (_current != WizardStep.Failed
            && _state.LaunchAfterFinish && _state.Mode == InstallMode.WindowsService)
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(_state.ServerUrl) { UseShellExecute = true });
        }

        Close();
    }

    private WizardStep GetNext(WizardStep current)
    {
        var next = NextStep(current);
        while (InstallerDebug.ShouldSkip(next) && next != WizardStep.Finish)
        {
            next = NextStep(next);
        }

        return next;
    }

    private WizardStep GetPrevious(WizardStep current)
    {
        var prev = PreviousStep(current);
        while (InstallerDebug.ShouldSkip(prev) && prev != WizardStep.Welcome)
        {
            prev = PreviousStep(prev);
        }

        return prev;
    }

    private WizardStep NextStep(WizardStep current) => current switch
    {
        WizardStep.Welcome => WizardStep.License,
        WizardStep.License => WizardStep.InstallMode,
        WizardStep.InstallMode => WizardStep.InstallLocation,
        WizardStep.InstallLocation => _state.Mode == InstallMode.Standalone
            ? WizardStep.DesktopShortcut
            : WizardStep.SettingsPassword,
        WizardStep.DesktopShortcut => WizardStep.SettingsPassword,
        WizardStep.SettingsPassword => WizardStep.ModelDownload,
        WizardStep.ModelDownload => WizardStep.Advanced,
        // Only Current User needs Windows to confirm an account/password — Network Service and
        // Local System need no credential at all, so there's nothing to confirm for them.
        WizardStep.Advanced => NeedsServiceAccountConfirm()
            ? WizardStep.ServiceAccountConfirm
            : WizardStep.ReadyToInstall,
        WizardStep.ServiceAccountConfirm => WizardStep.ReadyToInstall,
        WizardStep.ReadyToInstall => WizardStep.Installing,
        WizardStep.Installing => WizardStep.Finish,
        _ => WizardStep.Finish
    };

    private WizardStep PreviousStep(WizardStep current) => current switch
    {
        WizardStep.License => WizardStep.Welcome,
        WizardStep.InstallMode => WizardStep.License,
        WizardStep.InstallLocation => WizardStep.InstallMode,
        WizardStep.DesktopShortcut => WizardStep.InstallLocation,
        WizardStep.SettingsPassword => _state.Mode == InstallMode.Standalone
            ? WizardStep.DesktopShortcut
            : WizardStep.InstallLocation,
        WizardStep.ModelDownload => WizardStep.SettingsPassword,
        WizardStep.Advanced => WizardStep.ModelDownload,
        WizardStep.ServiceAccountConfirm => WizardStep.Advanced,
        WizardStep.ReadyToInstall => NeedsServiceAccountConfirm()
            ? WizardStep.ServiceAccountConfirm
            : WizardStep.Advanced,
        _ => WizardStep.Welcome
    };

    private bool NeedsServiceAccountConfirm() =>
        _state.Mode == InstallMode.WindowsService && _state.ServiceAccount == ServiceAccountKind.CurrentUser;

    private void GoTo(WizardStep step)
    {
        object? content;
        try
        {
            content = CreatePage(step);
        }
        catch (Exception ex)
        {
            ReportFatalError(ex, $"opening the {PageName(step)}");
            return;
        }

        _current = step;
        PageHost.Content = content;
        UpdateFooter(step);
        UpdateRail(step);
    }

    private object CreatePage(WizardStep step) => step switch
    {
        WizardStep.Welcome => new WelcomePage(),
        WizardStep.License => new LicenseKeyPage(_state),
        WizardStep.InstallMode => new InstallModePage(_state),
        WizardStep.InstallLocation => new InstallLocationPage(_state),
        WizardStep.DesktopShortcut => new DesktopShortcutPage(_state),
        WizardStep.ModelDownload => new ModelDownloadPage(_state),
        WizardStep.SettingsPassword => new SettingsPasswordPage(_state),
        WizardStep.Advanced => new AdvancedOptionsPage(_state),
        WizardStep.ServiceAccountConfirm => new ServiceAccountConfirmPage(_state, GoTo),
        WizardStep.ReadyToInstall => new ReadyToInstallPage(_state),
        WizardStep.Installing => new InstallingPage(_state, () => GoTo(WizardStep.Finish), GoTo),
        WizardStep.Finish => new FinishPage(_state),
        WizardStep.Failed => new SetupFailedPage(_state),
        _ => throw new InvalidOperationException($"Unknown wizard step '{step}'.")
    };

    /// <summary>
    /// Logs the exception, replaces the wizard with a failure page, and stops further navigation.
    /// Safe to call from UI-thread exception handlers; ignored if a fatal error was already shown.
    /// </summary>
    public void ReportFatalError(Exception exception, string context)
    {
        if (_fatalReported)
        {
            InstallerLog.Write(context, exception);
            return;
        }

        _fatalReported = true;

        _state.FatalErrorHeading = _current == WizardStep.Installing
            ? "Installation failed"
            : "Setup couldn't continue";
        _state.FatalErrorContext = context;
        _state.FatalErrorDetail = InstallerLog.FormatUserDetail(exception);
        _state.FatalErrorLogPath = InstallerLog.Write(context, exception);

        try
        {
            _current = WizardStep.Failed;
            PageHost.Content = new SetupFailedPage(_state);
            UpdateFooter(WizardStep.Failed);
        }
        catch (Exception showEx)
        {
            InstallerLog.Write("showing the error page", showEx);
            try
            {
                AppDialog.Inform(
                    this,
                    _state.FatalErrorHeading,
                    $"RFQ Application Setup hit an unexpected error while {context} and had to stop."
                    + $"{Environment.NewLine}{Environment.NewLine}{_state.FatalErrorDetail}"
                    + $"{Environment.NewLine}{Environment.NewLine}A detailed log was saved to:{Environment.NewLine}{_state.FatalErrorLogPath}");
            }
            catch
            {
                // The log is the remaining record.
            }

            Close();
        }
    }

    private static string PageName(WizardStep step) => step switch
    {
        WizardStep.Welcome => "welcome page",
        WizardStep.License => "license key page",
        WizardStep.InstallMode => "setup options page",
        WizardStep.InstallLocation => "install location page",
        WizardStep.DesktopShortcut => "desktop shortcut page",
        WizardStep.ModelDownload => "AI model download page",
        WizardStep.SettingsPassword => "Settings password page",
        WizardStep.Advanced => "Advanced options page",
        WizardStep.ServiceAccountConfirm => "Windows account confirmation page",
        WizardStep.ReadyToInstall => "Ready to install page",
        WizardStep.Installing => "installation",
        WizardStep.Finish => "finish page",
        WizardStep.Failed => "error page",
        _ => "setup"
    };

    private void UpdateFooter(WizardStep step)
    {
        switch (step)
        {
            case WizardStep.Welcome:
                BackButton.Visibility = Visibility.Collapsed;
                CancelButton.Visibility = Visibility.Visible;
                NextButton.Visibility = Visibility.Visible;
                NextButton.Content = "Get Started";
                break;
            case WizardStep.ReadyToInstall:
                BackButton.Visibility = Visibility.Visible;
                CancelButton.Visibility = Visibility.Visible;
                NextButton.Visibility = Visibility.Visible;
                NextButton.Content = "Install";
                break;
            case WizardStep.Installing:
                BackButton.Visibility = Visibility.Collapsed;
                CancelButton.Visibility = Visibility.Collapsed;
                NextButton.Visibility = Visibility.Collapsed;
                break;
            case WizardStep.Finish:
                BackButton.Visibility = Visibility.Collapsed;
                CancelButton.Visibility = Visibility.Collapsed;
                NextButton.Visibility = Visibility.Visible;
                NextButton.Content = "Finish";
                break;
            case WizardStep.Failed:
                BackButton.Visibility = Visibility.Collapsed;
                CancelButton.Visibility = Visibility.Collapsed;
                NextButton.Visibility = Visibility.Visible;
                NextButton.Content = "Close";
                break;
            default:
                BackButton.Visibility = Visibility.Visible;
                CancelButton.Visibility = Visibility.Visible;
                NextButton.Visibility = Visibility.Visible;
                NextButton.Content = "Next";
                break;
        }
    }

    private static int RailIndexFor(WizardStep step) => step switch
    {
        WizardStep.Welcome => 0,
        WizardStep.License => 1,
        WizardStep.InstallMode => 2,
        WizardStep.InstallLocation => 2,
        WizardStep.DesktopShortcut => 2,
        WizardStep.SettingsPassword => 3,
        WizardStep.ModelDownload => 4,
        WizardStep.Advanced => 4,
        WizardStep.ServiceAccountConfirm => 5, // conditional step; shares Ready to Install's slot rather than its own label so the rail doesn't visually "skip" a step when it doesn't apply
        WizardStep.ReadyToInstall => 5,
        WizardStep.Installing => 6,
        WizardStep.Finish => 7,
        WizardStep.Failed => 6,
        _ => 0
    };

    private void UpdateRail(WizardStep step)
    {
        var activeIndex = RailIndexFor(step);
        var items = new List<RailStep>();

        for (var i = 0; i < RailTitles.Length; i++)
        {
            items.Add(new RailStep
            {
                Title = RailTitles[i],
                Index = i + 1,
                IsActive = i == activeIndex,
                IsCompleted = i < activeIndex
            });
        }

        RailItemsControl.ItemsSource = items;
    }
}
