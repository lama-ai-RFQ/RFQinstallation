using System.Windows;
using System.Windows.Controls;
using RfqInstaller.Core.Licensing;
using RfqInstaller.Models;
using RfqInstaller.Core.Orchestration;

namespace RfqInstaller.Pages;

public partial class FinishPage : UserControl
{
    private readonly WizardState _state;

    public FinishPage(WizardState state)
    {
        InitializeComponent();
        _state = state;

        if (state.Repair)
        {
            TitleText.Text = "Repair completed successfully";
            SummaryText.Text = state.Mode == InstallMode.WindowsService
                ? "RFQ Application has been repaired and is running as a Windows service again."
                : "RFQ Application has been repaired and is ready to use.";
        }
        else
        {
            SummaryText.Text = state.Mode == InstallMode.WindowsService
                ? "RFQ Application has been installed and is running as a Windows service."
                : "RFQ Application has been installed and is ready to use.";
        }

        if (!state.Repair && LocalLicenseValidator.Validate(state.LicenseKey).TeamPlan && state.AllowNetworkAccess)
        {
            TeammatesText.Text = $"Teammates open {InstallOrchestrator.BrowserAddress(state.ServerUrl, state.InstallPath)} in their browser and sign in "
                + "with their own accounts. Keep this computer on while they work.";
            TeammatesText.Visibility = Visibility.Visible;
        }
        else if (!state.Repair && LocalLicenseValidator.Validate(state.LicenseKey).TeamPlan)
        {
            TeammatesText.Text = "Other computers can't connect: network access was turned off in Advanced options. "
                + "Run Setup again to change it.";
            TeammatesText.Visibility = Visibility.Visible;
        }

        if (state.InstallWarning is not null)
        {
            TeammatesText.Text = string.IsNullOrEmpty(TeammatesText.Text)
                ? state.InstallWarning
                : TeammatesText.Text + Environment.NewLine + Environment.NewLine + state.InstallWarning;
            TeammatesText.Visibility = Visibility.Visible;
        }

        LaunchCheckBox.Content = state.DesktopAppPath is not null
            ? "Open Scint"
            : state.Mode == InstallMode.WindowsService
                ? "Open RFQ Application in my browser"
                : "Launch RFQ Application";

        LaunchCheckBox.IsChecked = _state.LaunchAfterFinish;
        LaunchCheckBox.Checked += (_, _) => _state.LaunchAfterFinish = true;
        LaunchCheckBox.Unchecked += (_, _) => _state.LaunchAfterFinish = false;
    }
}
