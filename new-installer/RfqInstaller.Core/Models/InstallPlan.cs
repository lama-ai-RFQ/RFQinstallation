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

    public ServiceAccountKind ServiceAccount { get; init; } = ServiceAccountKind.LocalSystem;
    /// <summary>Only populated when ServiceAccount == CurrentUser; the Windows account's own login password, captured once via a styled (non-console) field.</summary>
    public string? ServiceAccountPassword { get; init; }

    public string UpdateChannel { get; init; } = "customer";
}
