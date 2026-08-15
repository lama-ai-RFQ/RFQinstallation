using System.Windows;
using System.Windows.Controls;
using RfqInstaller.Demo.Logging;
using RfqInstaller.Demo.Models;

namespace RfqInstaller.Demo.Pages;

public partial class SetupFailedPage : UserControl
{
    public SetupFailedPage(WizardState state)
    {
        InitializeComponent();

        HeadingText.Text = string.IsNullOrWhiteSpace(state.FatalErrorHeading)
            ? "Setup couldn't continue"
            : state.FatalErrorHeading;

        SummaryText.Text = string.IsNullOrWhiteSpace(state.FatalErrorContext)
            ? "RFQ Application Setup hit an unexpected error and had to stop. Nothing further was changed."
            : $"RFQ Application Setup hit an unexpected error while {state.FatalErrorContext} and had to stop. Nothing further was changed.";

        DetailText.Text = string.IsNullOrWhiteSpace(state.FatalErrorDetail)
            ? "No further detail was captured."
            : state.FatalErrorDetail;

        LogPathText.Text = string.IsNullOrWhiteSpace(state.FatalErrorLogPath)
            ? InstallerLog.LogPath
            : state.FatalErrorLogPath;
    }

    private void OpenLog_Click(object sender, RoutedEventArgs e) => InstallerLog.TryOpenLog();
}
