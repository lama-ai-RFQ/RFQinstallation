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
    Advanced,
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

    public string ServerUrl { get; set; } = "https://localhost";

    public bool AutoGenerateEncryptionKey { get; set; } = true;

    public string CustomEncryptionKey { get; set; } = string.Empty;

    public ServiceAccountKind ServiceAccount { get; set; } = ServiceAccountKind.CurrentUser;

    /// <summary>Only ever populated in-memory during install from the Windows credential dialog. Never serialized.</summary>
    [System.Text.Json.Serialization.JsonIgnore]
    public string ServiceAccountPassword { get; set; } = string.Empty;

    /// <summary>Set by InstallingPage once the install finishes, so FinishPage knows the real executable path to launch.</summary>
    public string? ResolvedMainExecutablePath { get; set; }

    /// <summary>Set by InstallingPage if the install failed, so FinishPage (or an error page) can show the real reason instead of always claiming success.</summary>
    public string? InstallErrorMessage { get; set; }

    public string FatalErrorHeading { get; set; } = "Setup couldn't continue";

    public string? FatalErrorContext { get; set; }

    public string? FatalErrorDetail { get; set; }

    public string? FatalErrorLogPath { get; set; }
}
