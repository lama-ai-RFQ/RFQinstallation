namespace RfqInstaller.Core.Models;

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

/// <summary>
/// Everything the wizard collected, handed to the orchestrator as one immutable snapshot.
/// </summary>
public class InstallPlan
{
    public required string LicenseKey { get; init; }
    public InstallMode Mode { get; init; } = InstallMode.WindowsService;
    public required string InstallPath { get; init; }
    public bool CreateDesktopShortcut { get; init; } = true;
    public bool LaunchAfterFinish { get; init; } = true;

    public bool DownloadModelNow { get; init; } = true;
    public required string ModelPath { get; init; }

    public bool CleanReinstall { get; init; }
    public bool CleanupAfterInstall { get; init; } = true;

    public string ServerUrl { get; init; } = "https://localhost";
    public bool AutoGenerateEncryptionKey { get; init; } = true;
    public string? CustomEncryptionKey { get; init; }

    public ServiceAccountKind ServiceAccount { get; init; } = ServiceAccountKind.CurrentUser;
    /// <summary>
    /// DOMAIN\user from the Windows credential dialog. Only used when ServiceAccount is CurrentUser.
    /// </summary>
    public string? ServiceAccountName { get; init; }
    /// <summary>
    /// Windows logon password from the native credential dialog. Held only for this install run
    /// and passed to NSSM (LSA). Never written to wizard state, logs, or files.
    /// </summary>
    public string? ServiceAccountPassword { get; init; }

    public string UpdateChannel { get; init; } = "customer";
}
