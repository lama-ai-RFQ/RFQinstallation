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
    public InstallMode Mode { get; init; } = InstallMode.Standalone;
    public required string InstallPath { get; init; }
    public bool CreateDesktopShortcut { get; init; } = true;
    public bool LaunchAfterFinish { get; init; } = true;

    public bool DownloadModelNow { get; init; } = true;
    public required string ModelPath { get; init; }

    public bool CleanReinstall { get; init; }
    public bool CleanupAfterInstall { get; init; } = true;

    /// <summary>
    /// Chosen (or generated-and-shown) by the admin on the Settings Password wizard page. Unlike
    /// the DB passwords, this one gates a human-typed login form with no in-app reset, so it can't
    /// be silently auto-generated without the admin ever seeing it.
    /// </summary>
    public required string SettingsPassword { get; init; }

    public string ServerUrl { get; init; } = "https://localhost";
    public bool AutoGenerateEncryptionKey { get; init; } = true;
    public string? CustomEncryptionKey { get; init; }

    /// <summary>
    /// Explicit choice: Windows Credential Manager (recommended) or a plaintext .env file. Applies
    /// to all three generated passwords. Only actually usable with ServiceAccount == CurrentUser —
    /// InstallOrchestrator falls back to .env automatically (with a warning surfaced earlier in the
    /// wizard) for Network Service/Local System, since Credential Manager cannot be read by them.
    /// </summary>
    public bool UseCredentialManager { get; init; } = true;

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
