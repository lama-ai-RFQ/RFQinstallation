namespace RfqInstaller.Core.Models;

/// <summary>
/// A repair re-downloads the application and updater into an existing install and changes nothing
/// else: .env, Windows Credential Manager entries, the encryption key, and the database are kept.
/// The license key, update channel and broker URL are all read from the existing .env (see
/// <see cref="Orchestration.RepairPreflight"/>), so the wizard asks for none of them.
/// </summary>
public class RepairPlan
{
    public required string InstallPath { get; init; }

    /// <summary>Detected from the existing install. A service install must still have both of its
    /// services registered: repair restarts them but cannot recreate a Current User service without
    /// that account's Windows password.</summary>
    public InstallMode Mode { get; init; } = InstallMode.WindowsService;

    /// <summary>
    /// Off by default: the install's private Postgres is just restarted as it is. On, repair also
    /// re-creates the rfq_db database, rfq_user login and grants if any went missing, which needs
    /// the stored postgres and rfq_user passwords.
    /// </summary>
    public bool RepairDatabase { get; init; }

    public bool CleanupAfterInstall { get; init; } = true;
}
