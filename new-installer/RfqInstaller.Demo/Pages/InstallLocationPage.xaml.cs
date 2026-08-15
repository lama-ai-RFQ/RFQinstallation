using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;
using RfqInstaller.Demo.Models;

namespace RfqInstaller.Demo.Pages;

public partial class InstallLocationPage : UserControl, IWizardPage
{
    private readonly WizardState _state;

    public InstallLocationPage(WizardState state)
    {
        InitializeComponent();
        _state = state;
        PathTextBox.Text = _state.InstallPath;
    }

    private void PathTextBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        _state.InstallPath = PathTextBox.Text;
        if (ErrorText.Visibility == Visibility.Visible && !string.IsNullOrWhiteSpace(_state.InstallPath))
        {
            ErrorText.Visibility = Visibility.Collapsed;
        }
    }

    private void Browse_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog
        {
            Title = "Choose install folder",
            Multiselect = false
        };

        if (System.IO.Directory.Exists(_state.InstallPath))
        {
            dialog.InitialDirectory = _state.InstallPath;
        }

        if (dialog.ShowDialog() == true)
        {
            PathTextBox.Text = dialog.FolderName;
        }
    }

    public bool Validate()
    {
        if (string.IsNullOrWhiteSpace(_state.InstallPath))
        {
            ErrorText.Visibility = Visibility.Visible;
            return false;
        }

        return true;
    }
}
