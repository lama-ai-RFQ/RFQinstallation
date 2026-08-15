using System.Windows.Controls;
using RfqInstaller.Demo.Models;

namespace RfqInstaller.Demo.Pages;

public partial class DesktopShortcutPage : UserControl, IWizardPage
{
    private readonly WizardState _state;

    public DesktopShortcutPage(WizardState state)
    {
        InitializeComponent();
        _state = state;
        DesktopShortcutCheckBox.IsChecked = _state.CreateDesktopShortcut;
    }

    private void DesktopShortcutCheckBox_Changed(object sender, System.Windows.RoutedEventArgs e)
    {
        _state.CreateDesktopShortcut = DesktopShortcutCheckBox.IsChecked == true;
    }

    public bool Validate() => true;
}
