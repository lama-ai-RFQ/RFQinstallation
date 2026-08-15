using System.Windows.Controls;
using RfqInstaller.Demo.Models;

namespace RfqInstaller.Demo.Pages;

public partial class FinishPage : UserControl
{
    private readonly WizardState _state;

    public FinishPage(WizardState state)
    {
        InitializeComponent();
        _state = state;

        SummaryText.Text = state.Mode == InstallMode.WindowsService
            ? "RFQ Application has been installed and is running as a Windows service."
            : "RFQ Application has been installed and is ready to use.";

        LaunchCheckBox.Content = state.Mode == InstallMode.WindowsService
            ? "Open RFQ Application in my browser"
            : "Launch RFQ Application";

        LaunchCheckBox.IsChecked = _state.LaunchAfterFinish;
        LaunchCheckBox.Checked += (_, _) => _state.LaunchAfterFinish = true;
        LaunchCheckBox.Unchecked += (_, _) => _state.LaunchAfterFinish = false;
    }
}
