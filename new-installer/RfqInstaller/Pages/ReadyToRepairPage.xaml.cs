using System.Windows;
using System.Windows.Controls;
using RfqInstaller.Core.Orchestration;
using RfqInstaller.Dialogs;
using RfqInstaller.Models;

namespace RfqInstaller.Pages;

/// <summary>
/// Review step for Repair. Runs the same read-only preflight the orchestrator runs, so a problem
/// that would stop the repair (unreadable Credential Manager entry, expired license, ...) shows up
/// here, before anything is downloaded or stopped. Re-runs it when the optional database check is
/// toggled, since only that check needs the stored database passwords.
/// </summary>
public partial class ReadyToRepairPage : UserControl, IWizardPage
{
    private readonly WizardState _state;
    private RepairReadiness _readiness;

    public ReadyToRepairPage(WizardState state)
    {
        InitializeComponent();
        _state = state;

        _readiness = RepairPreflight.Check(state.InstallPath, state.RepairDatabase);
        if (_readiness.LicenseKey is not null)
        {
            state.LicenseKey = _readiness.LicenseKey;
        }

        PathSummary.Text = state.InstallPath;
        VersionSummary.Text = state.ExistingVersion ?? "Unknown";
        ModeSummary.Text = state.Mode == InstallMode.WindowsService
            ? string.IsNullOrWhiteSpace(state.ExistingServiceAccountName)
                ? "Windows Service"
                : $"Windows Service (runs as {state.ExistingServiceAccountName})"
            : "Runs only while it is open";
        LicenseKeySummary.Text = _readiness.LicenseKey is null
            ? "Not found"
            : ReadyToInstallPage.MaskLicenseKey(_readiness.LicenseKey);

        if (_readiness.HasBundledDatabase)
        {
            RepairDatabasePanel.Visibility = Visibility.Visible;
            RepairDatabaseCheck.IsChecked = state.RepairDatabase;
        }
        else
        {
            // Nothing for the checkbox to do: repair never touches a separate PostgreSQL server.
            state.RepairDatabase = false;
        }

        ShowReadiness();
    }

    private void RepairDatabaseCheck_Changed(object sender, RoutedEventArgs e)
    {
        var repairDatabase = RepairDatabaseCheck.IsChecked == true;
        if (_state.RepairDatabase == repairDatabase)
        {
            return;
        }

        _state.RepairDatabase = repairDatabase;
        _readiness = RepairPreflight.Check(_state.InstallPath, repairDatabase);
        ShowReadiness();
    }

    private void ShowReadiness()
    {
        DatabaseSummary.Text = !_readiness.HasBundledDatabase
            ? "Kept. This install uses a separate PostgreSQL server, which repair doesn't touch."
            : _state.RepairDatabase
                ? "Kept. Its PostgreSQL service is restarted, then the database, rfq_user login and permissions are checked."
                : "Kept. Its PostgreSQL service is restarted as it is.";

        if (_readiness.CanRepair)
        {
            ProblemsPanel.Visibility = Visibility.Collapsed;
            return;
        }

        ProblemsText.Text = string.Join(Environment.NewLine + Environment.NewLine, _readiness.Problems);
        ProblemsPanel.Visibility = Visibility.Visible;
    }

    public bool Validate()
    {
        if (_readiness.CanRepair)
        {
            return true;
        }

        AppDialog.Inform(
            Window.GetWindow(this),
            "Repair can't start",
            string.Join(Environment.NewLine + Environment.NewLine, _readiness.Problems));
        return false;
    }
}
