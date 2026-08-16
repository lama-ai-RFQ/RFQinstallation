using RfqInstaller.Core.Config;

namespace RfqInstaller.Demo.Models;

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
    ModelDownload,
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
    public string LicenseKey { get; set; } = string.Empty;

    public InstallMode Mode { get; set; } = InstallMode.WindowsService;

    public string InstallPath { get; set; } = @"C:\Program Files\RFQ Application";

    public bool CreateDesktopShortcut { get; set; } = true;

    public bool LaunchAfterFinish { get; set; } = true;

    public bool DownloadModelNow { get; set; } = true;

    public string ModelPath { get; set; } = DefaultPaths.DefaultModelPath();

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

    public string ServerUrl { get; set; } = "https://localhost";

    public bool AutoGenerateEncryptionKey { get; set; } = true;

    public string CustomEncryptionKey { get; set; } = string.Empty;

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

    /// <summary>Set by InstallingPage if the install failed, so FinishPage (or an error page) can show the real reason instead of always claiming success.</summary>
    public string? InstallErrorMessage { get; set; }

    public string FatalErrorHeading { get; set; } = "Setup couldn't continue";

    public string? FatalErrorContext { get; set; }

    public string? FatalErrorDetail { get; set; }

    public string? FatalErrorLogPath { get; set; }
}
