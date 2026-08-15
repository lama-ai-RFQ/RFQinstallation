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
            ScheduleInstallFolderDeletion(installPath);
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

        // The running uninstaller's own files can't be deleted from within this process
        // (Windows keeps the .exe locked) — hand off to a short-lived, invisible helper that
        // waits for this process to exit, then removes the install folder, then deletes itself.
        Application.Current.Shutdown();
    }

    private static void ScheduleInstallFolderDeletion(string installPath)
    {
        var currentPid = Environment.ProcessId;
        var helperScript = Path.Combine(Path.GetTempPath(), $"rfq-uninstall-cleanup-{Guid.NewGuid():N}.cmd");
        File.WriteAllText(helperScript,
            $":wait\r\n" +
            $"tasklist /fi \"PID eq {currentPid}\" | find \"{currentPid}\" >nul\r\n" +
            $"if not errorlevel 1 (timeout /t 1 /nobreak >nul & goto wait)\r\n" +
            $"rmdir /s /q \"{installPath}\"\r\n" +
            $"del \"%~f0\"\r\n");

        var startInfo = new System.Diagnostics.ProcessStartInfo
        {
            FileName = "cmd.exe",
            ArgumentList = { "/c", helperScript },
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = System.Diagnostics.ProcessWindowStyle.Hidden,
        };
        System.Diagnostics.Process.Start(startInfo);
    }
}
