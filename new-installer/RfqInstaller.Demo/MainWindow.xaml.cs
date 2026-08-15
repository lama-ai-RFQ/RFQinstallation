using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Input;
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
        "Ready to Install",
        "Installing",
        "Finish"
    };

    private readonly WizardState _state = new();
    private WizardStep _current = WizardStep.Welcome;

    public MainWindow()
    {
        InitializeComponent();
        GoTo(WizardStep.Welcome);
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
        var result = MessageBox.Show(
            this,
            "Are you sure you want to cancel RFQ Application setup?",
            "Cancel Setup",
            MessageBoxButton.YesNo,
            MessageBoxImage.Question);

        if (result == MessageBoxResult.Yes)
        {
            Close();
        }
    }

    private void Back_Click(object sender, RoutedEventArgs e)
    {
        GoTo(GetPrevious(_current));
    }

    private void Next_Click(object sender, RoutedEventArgs e)
    {
        if (_current == WizardStep.Finish)
        {
            Close();
            return;
        }

        if (PageHost.Content is IWizardPage page && !page.Validate())
        {
            return;
        }

        GoTo(GetNext(_current));
    }

    private WizardStep GetNext(WizardStep current) => current switch
    {
        WizardStep.Welcome => WizardStep.License,
        WizardStep.License => WizardStep.InstallMode,
        WizardStep.InstallMode => WizardStep.InstallLocation,
        WizardStep.InstallLocation => _state.Mode == InstallMode.Standalone
            ? WizardStep.DesktopShortcut
            : WizardStep.ReadyToInstall,
        WizardStep.DesktopShortcut => WizardStep.ReadyToInstall,
        WizardStep.ReadyToInstall => WizardStep.Installing,
        WizardStep.Installing => WizardStep.Finish,
        _ => WizardStep.Finish
    };

    private WizardStep GetPrevious(WizardStep current) => current switch
    {
        WizardStep.License => WizardStep.Welcome,
        WizardStep.InstallMode => WizardStep.License,
        WizardStep.InstallLocation => WizardStep.InstallMode,
        WizardStep.DesktopShortcut => WizardStep.InstallLocation,
        WizardStep.ReadyToInstall => _state.Mode == InstallMode.Standalone
            ? WizardStep.DesktopShortcut
            : WizardStep.InstallLocation,
        _ => WizardStep.Welcome
    };

    private void GoTo(WizardStep step)
    {
        _current = step;

        PageHost.Content = step switch
        {
            WizardStep.Welcome => new WelcomePage(),
            WizardStep.License => new LicenseKeyPage(_state),
            WizardStep.InstallMode => new InstallModePage(_state),
            WizardStep.InstallLocation => new InstallLocationPage(_state),
            WizardStep.DesktopShortcut => new DesktopShortcutPage(_state),
            WizardStep.ReadyToInstall => new ReadyToInstallPage(_state),
            WizardStep.Installing => new InstallingPage(_state, () => GoTo(WizardStep.Finish)),
            WizardStep.Finish => new FinishPage(_state),
            _ => PageHost.Content
        };

        UpdateFooter(step);
        UpdateRail(step);
    }

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
        WizardStep.ReadyToInstall => 3,
        WizardStep.Installing => 4,
        WizardStep.Finish => 5,
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
