using System.Windows.Controls;
using RfqInstaller.Core.Licensing;
using RfqInstaller.Models;

namespace RfqInstaller.Pages;

public partial class InstallModePage : UserControl, IWizardPage
{
    private readonly WizardState _state;

    public InstallModePage(WizardState state)
    {
        InitializeComponent();
        _state = state;

        // Individual keys (bought on scint.ai, one user) default to running only while the Scint
        // app is open. Team keys keep the background service: teammates open it from their browsers.
        if (LocalLicenseValidator.Validate(_state.LicenseKey).IndividualPlan)
        {
            ModeSubtitle.Text = "Recommended for the Individual plan: the Scint app starts RFQ Application "
                + "when you open it and stops it when you close it.";
            ServiceTitle.Text = "Runs in the background (Windows service)";
            StandaloneTitle.Text = "Runs only while it is open — recommended";
            if (!_state.ModeChosen)
            {
                _state.Mode = InstallMode.Standalone;
            }
        }

        if (_state.Mode == InstallMode.Standalone)
        {
            StandaloneRadio.IsChecked = true;
        }
        else
        {
            ServiceRadio.IsChecked = true;
        }
    }

    private void ServiceRadio_Checked(object sender, System.Windows.RoutedEventArgs e)
    {
        _state.Mode = InstallMode.WindowsService;
    }

    private void StandaloneRadio_Checked(object sender, System.Windows.RoutedEventArgs e)
    {
        _state.Mode = InstallMode.Standalone;
    }

    public bool Validate()
    {
        _state.ModeChosen = true;
        return true;
    }
}
