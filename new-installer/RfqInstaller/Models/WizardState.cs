using RfqInstaller.Core.Orchestration;

namespace RfqInstaller.Models;

public enum InstallMode
{
    WindowsService,
    Standalone
}

public enum ServiceAccountKind
{
    LocalSystem,
    NetworkService,
    CurrentUser
}

public enum WizardStep
{
    Welcome,
    License,
    InstallMode,
    InstallLocation,
    DesktopShortcut,
    SettingsPassword,
    Advanced,
    ServiceAccountConfirm,
    ReadyToInstall,
    Installing,
    Finish,
    Failed
}

public class WizardState
{
    /// <summary>
    /// True when the admin chose Repair on the Welcome page. The wizard then goes Welcome → Ready
    /// to Repair → Installing → Finish, and the license key, mode and path come from the existing
    /// install instead of being asked for.
    /// </summary>
    public bool Repair { get; set; }

    /// <summary>Shown on the Ready to Repair page; from <see cref="UseExistingInstall"/>.</summary>
    public string? ExistingVersion { get; set; }

    public string? ExistingServiceAccountName { get; set; }

    /// <summary>Optional on the Ready to Repair page; see <see cref="RfqInstaller.Core.Models.RepairPlan.RepairDatabase"/>.</summary>
    public bool RepairDatabase { get; set; }

    public string LicenseKey { get; set; } = string.Empty;

    public InstallMode Mode { get; set; } = InstallMode.WindowsService;

    /// <summary>
    /// True once the mode was picked on the Install Mode page or taken from an existing install;
    /// until then that page picks the one recommended for the license key.
    /// </summary>
    public bool ModeChosen { get; set; }

    public string InstallPath { get; set; } = @"C:\Program Files\RFQ Application";

    public bool CreateDesktopShortcut { get; set; } = true;

    public bool LaunchAfterFinish { get; set; } = true;

    public bool CleanReinstall { get; set; } = true;

    public bool CleanupAfterInstall { get; set; } = true;

    /// <summary>
    /// Chosen (or generated-and-shown) by the admin on SettingsPasswordPage. Never serialized: the
    /// wizard's elevation checkpoint was moved to right after InstallLocation specifically so this
    /// page — and every page after it — always runs in the process that will actually perform the
    /// install, and this value never needs to survive the UAC-relaunch temp-file hand-off.
    /// </summary>
    [System.Text.Json.Serialization.JsonIgnore]
    public string SettingsPassword { get; set; } = string.Empty;

    public const string DefaultServerUrl = "https://localhost";

    public string ServerUrl { get; set; } = DefaultServerUrl;

    public bool AutoGenerateEncryptionKey { get; set; } = true;

    public string CustomEncryptionKey { get; set; } = string.Empty;

    /// <summary>Default: generate the private Postgres superuser and rfq_user passwords.</summary>
    public bool AutoGeneratePostgresPasswords { get; set; } = true;

    [System.Text.Json.Serialization.JsonIgnore]
    public string CustomSqlSuperUserPassword { get; set; } = string.Empty;

    [System.Text.Json.Serialization.JsonIgnore]
    public string CustomRfqUserPassword { get; set; } = string.Empty;

    /// <summary>Explicit choice: Windows Credential Manager (recommended) or a plaintext .env file — applies to the database and Settings passwords.</summary>
    public bool UseCredentialManager { get; set; } = true;

    public ServiceAccountKind ServiceAccount { get; set; } = ServiceAccountKind.CurrentUser;

    /// <summary>
    /// Set by ServiceAccountConfirmPage once Windows Security succeeds — this is its own wizard
    /// step (not something InstallingPage triggers as a side effect), so a cancelled/failed
    /// attempt leaves the user sitting on that page with Back/Try Again/switch-account options,
    /// instead of jumping into the "Installing" step before anything has actually been confirmed.
    /// Neither field is ever serialized: both are only ever populated after the wizard's elevation
    /// checkpoint has already run.
    /// </summary>
    [System.Text.Json.Serialization.JsonIgnore]
    public string ServiceAccountName { get; set; } = string.Empty;

    [System.Text.Json.Serialization.JsonIgnore]
    public string ServiceAccountPassword { get; set; } = string.Empty;

    /// <summary>True once ServiceAccountConfirmPage has successfully obtained Windows credentials for this run.</summary>
    [System.Text.Json.Serialization.JsonIgnore]
    public bool ServiceAccountConfirmed { get; set; }

    /// <summary>Set by InstallingPage once the install finishes, so FinishPage knows the real executable path to launch.</summary>
    public string? ResolvedMainExecutablePath { get; set; }

    /// <summary>Scint.exe when this install opens Scint in the desktop app (Individual and Team plans).</summary>
    public string? DesktopAppPath { get; set; }

    /// <summary>Set by InstallingPage if the install failed, so FinishPage (or an error page) can show the real reason instead of always claiming success.</summary>
    public string? InstallErrorMessage { get; set; }

    public string FatalErrorHeading { get; set; } = "Setup couldn't continue";

    public string? FatalErrorContext { get; set; }

    public string? FatalErrorDetail { get; set; }

    public string? FatalErrorLogPath { get; set; }

    /// <summary>
    /// Points the wizard at an install found on this machine. Used for Repair, and also as the
    /// defaults for a normal install so "Install" over an existing copy starts from its folder and mode.
    /// </summary>
    public void UseExistingInstall(ExistingInstallation existing, bool repair)
    {
        Repair = repair;
        InstallPath = existing.InstallPath;
        Mode = existing.Mode == RfqInstaller.Core.Models.InstallMode.WindowsService
            ? InstallMode.WindowsService
            : InstallMode.Standalone;
        ModeChosen = true;
        ExistingVersion = existing.InstalledVersion;
        ExistingServiceAccountName = existing.ServiceAccountName;
    }
}
