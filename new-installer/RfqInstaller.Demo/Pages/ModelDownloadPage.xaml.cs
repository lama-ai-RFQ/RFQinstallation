using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;
using RfqInstaller.Demo.Models;

namespace RfqInstaller.Demo.Pages;

public partial class ModelDownloadPage : UserControl, IWizardPage
{
    private readonly WizardState _state;

    public ModelDownloadPage(WizardState state)
    {
        InitializeComponent();
        _state = state;

        PathTextBox.Text = _state.ModelPath;

        if (_state.DownloadModelNow)
        {
            NowRadio.IsChecked = true;
        }
        else
        {
            LaterRadio.IsChecked = true;
        }
    }

    private void NowRadio_Checked(object sender, RoutedEventArgs e)
    {
        _state.DownloadModelNow = true;
        if (FolderPanel is not null)
        {
            FolderPanel.Visibility = Visibility.Visible;
        }
    }

    private void LaterRadio_Checked(object sender, RoutedEventArgs e)
    {
        _state.DownloadModelNow = false;
        if (FolderPanel is not null)
        {
            FolderPanel.Visibility = Visibility.Collapsed;
        }
    }

    private void PathTextBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        _state.ModelPath = PathTextBox.Text;
    }

    private void Browse_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog { Title = "Choose model folder", Multiselect = false };
        if (System.IO.Directory.Exists(_state.ModelPath))
        {
            dialog.InitialDirectory = _state.ModelPath;
        }

        if (dialog.ShowDialog() == true)
        {
            PathTextBox.Text = dialog.FolderName;
        }
    }

    public bool Validate() => true;
}
