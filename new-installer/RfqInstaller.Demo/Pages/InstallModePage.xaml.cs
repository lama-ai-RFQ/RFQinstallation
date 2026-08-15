using System.Windows.Controls;
using RfqInstaller.Demo.Models;

namespace RfqInstaller.Demo.Pages;

public partial class InstallModePage : UserControl, IWizardPage
{
    private readonly WizardState _state;

    public InstallModePage(WizardState state)
    {
        InitializeComponent();
        _state = state;

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

    public bool Validate() => true;
}
