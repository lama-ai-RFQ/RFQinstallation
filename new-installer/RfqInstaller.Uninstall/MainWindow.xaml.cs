using System.IO;
using System.Windows;
using RfqInstaller.Core.Orchestration;

namespace RfqInstaller.Uninstall;

public partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
    }

    private void CancelButton_Click(object sender, RoutedEventArgs e) => Close();

    private void ViewPasswordsButton_Click(object sender, RoutedEventArgs e)
    {
        var installPath = AppContext.BaseDirectory.TrimEnd('\\');
        new CredentialsViewerWindow(installPath) { Owner = this }.ShowDialog();
    }

    private async void UninstallButton_Click(object sender, RoutedEventArgs e)
    {
        OptionsPanel.IsEnabled = false;
        UninstallButton.IsEnabled = false;
        CancelButton.IsEnabled = false;
        StatusText.Visibility = Visibility.Visible;
        ProgressBar.Visibility = Visibility.Visible;

        var installPath = AppContext.BaseDirectory.TrimEnd('\\');
        var deleteDatabase = DeleteDatabaseCheck.IsChecked == true;

        var progress = new Progress<string>(msg => StatusText.Text = msg);
        var orchestrator = new UninstallOrchestrator();

        try
        {
            await orchestrator.RunAsync(installPath, deleteDatabase, progress, CancellationToken.None);
            StatusText.Text = "Uninstall complete. Finishing up...";
            using var cleanup = UninstallOrchestrator.ScheduleUninstallerDeletion(installPath, Environment.ProcessId);
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Uninstall finished with an error: {ex.Message}";
            UninstallButton.Content = "Close";
            UninstallButton.IsEnabled = true;
            UninstallButton.Click -= UninstallButton_Click;
            UninstallButton.Click += (_, _) => Close();
            CancelButton.Visibility = Visibility.Collapsed;
            ProgressBar.Visibility = Visibility.Collapsed;
            return;
        }

        Application.Current.Shutdown();
    }
}
