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

        if (TryLoadResumeState(out var resumed))
        {
            _state = resumed!;
            GoTo(WizardStep.Installing);
        }
        else
        {
            GoTo(WizardStep.Welcome);
        }
    }

    /// <summary>
    /// If this process was relaunched elevated (see <see cref="TryElevateAndResume"/>), the wizard
    /// state was handed off via a temp JSON file whose path is the sole command-line argument.
    /// Loading it here lets the elevated instance jump straight to the Installing step instead of
    /// re-asking the user everything.
    /// </summary>
    private static bool TryLoadResumeState(out WizardState? state)
    {
        state = null;
        var args = Environment.GetCommandLineArgs();
        if (args.Length != 2 || !File.Exists(args[1]))
        {
            return false;
        }

        try
        {
            var json = File.ReadAllText(args[1]);
            state = JsonSerializer.Deserialize<WizardState>(json);
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

            // Elevate (if needed) as soon as Mode + InstallPath are both known, right before
            // SettingsPassword — not at ReadyToInstall. Every page from here on (SettingsPassword,
            // ModelDownload, Advanced, ReadyToInstall) collects real data, including a
            // human-chosen password, and none of it should have to survive a UAC-relaunch
            // temp-file hand-off. Safe to re-check on every forward navigation: a no-op once
            // already elevated.
            if (GetNext(_current) == WizardStep.SettingsPassword && TryElevateAndResume())
            {
                // A new elevated process has taken over; this instance exits without installing.
                Close();
                return;
            }

            GoTo(GetNext(_current));
        }
        catch (Exception ex)
        {
            ReportFatalError(ex, $"continuing from the {PageName(_current)}");
        }
    }

    /// <summary>
    /// Service installs (and standalone installs into a machine-wide folder like Program Files)
    /// need admin rights. Rather than always demanding elevation at startup like the old Inno
    /// installer, we only ask for it right before it's actually needed, and only once.
    /// </summary>
    private bool TryElevateAndResume()
    {
        if (ElevationHelper.IsElevated() || !ElevationHelper.RequiresElevation(
                _state.Mode == InstallMode.WindowsService ? Core.Models.InstallMode.WindowsService : Core.Models.InstallMode.Standalone,
                _state.InstallPath))
        {
            return false;
        }

        var tempFile = Path.Combine(Path.GetTempPath(), $"rfq-installer-state-{Guid.NewGuid():N}.json");
        File.WriteAllText(tempFile, JsonSerializer.Serialize(_state));

        var process = ElevationHelper.RelaunchElevated(new[] { tempFile });
        if (process is null)
        {
            // User declined the UAC prompt — stay on this page so they can try again or cancel.
            TryDeleteQuietly(tempFile);
            AppDialog.Inform(this, "Administrator rights required",
                "Installing as a Windows service (or into a system folder) requires administrator approval. Please try again and accept the prompt.");
            return false;
        }

        return true;
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
        WizardStep.Advanced => WizardStep.ReadyToInstall,
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
        WizardStep.ReadyToInstall => WizardStep.Advanced,
        _ => WizardStep.Welcome
    };

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
        WizardStep.ReadyToInstall => new ReadyToInstallPage(_state),
        WizardStep.Installing => new InstallingPage(_state, () => GoTo(WizardStep.Finish), () => GoTo(WizardStep.ReadyToInstall)),
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
