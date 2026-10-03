using System.Windows;
using System.Windows.Controls;
using RfqInstaller.Core.Orchestration;
using RfqInstaller.Models;

namespace RfqInstaller.Pages;

public partial class WelcomePage : UserControl
{
    private readonly WizardState _state;
    private readonly ExistingInstallation? _existing;
    private readonly Action _onChoiceChanged;

    public WelcomePage(WizardState state, ExistingInstallation? existing, Action onChoiceChanged)
    {
        InitializeComponent();
        _state = state;
        _existing = existing;
        _onChoiceChanged = onChoiceChanged;

        if (existing is null)
        {
            return;
        }

        FreshInstallPanel.Visibility = Visibility.Collapsed;
        ExistingInstallPanel.Visibility = Visibility.Visible;
        var version = existing.InstalledVersion is null ? string.Empty : $" (version {existing.InstalledVersion})";
        ExistingInstallText.Text = $"RFQ Application is already installed in {existing.InstallPath}{version}. What would you like to do?";

        if (_state.Repair)
        {
            RepairRadio.IsChecked = true;
        }
        else
        {
            InstallRadio.IsChecked = true;
        }
    }

    private void RepairRadio_Checked(object sender, RoutedEventArgs e) => Choose(repair: true);

    private void InstallRadio_Checked(object sender, RoutedEventArgs e) => Choose(repair: false);

    private void Choose(bool repair)
    {
        if (_existing is null || _state.Repair == repair)
        {
            return;
        }

        _state.UseExistingInstall(_existing, repair);
        _onChoiceChanged();
    }
}
