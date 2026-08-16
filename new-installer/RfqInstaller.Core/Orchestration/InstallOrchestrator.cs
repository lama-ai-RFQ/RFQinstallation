using RfqInstaller.Core.Archive;
using RfqInstaller.Core.Certificates;
using RfqInstaller.Core.Config;
using RfqInstaller.Core.Database;
using RfqInstaller.Core.Elevation;
using RfqInstaller.Core.Licensing;
using RfqInstaller.Core.Models;
using RfqInstaller.Core.Networking;
using RfqInstaller.Core.Security;
using RfqInstaller.Core.Services;
using RfqInstaller.Core.Shortcuts;

namespace RfqInstaller.Core.Orchestration;

public record InstallStepProgress(string StepName, double FractionComplete, string? Detail);

public record InstallResult(bool Success, string? ErrorMessage, string? MainExecutablePath);

/// <summary>
/// Drives the real install sequence end to end — this is what replaces InstallingPage's fake
/// Task.Delay animation. Every step reports real progress; a failure stops the sequence and
/// surfaces the actual error instead of always "succeeding" like the demo did.
/// </summary>
public class InstallOrchestrator
{
    private const string AppServiceName = "RFQapplication";
    private const string UpdaterServiceName = "RFQUpdaterService";

    private readonly LicenseBrokerClient _brokerClient;
    private readonly HttpDownloader _downloader;
    private readonly string _bundledNssmPath;
    private readonly string _bundledUpdaterPath;
    private readonly string? _bundledUninstallerPath;

    public InstallOrchestrator(
        string bundledNssmPath,
        string bundledUpdaterPath,
        string? bundledUninstallerPath = null,
        LicenseBrokerClient? brokerClient = null,
        HttpDownloader? downloader = null)
    {
        _bundledNssmPath = bundledNssmPath;
        _bundledUpdaterPath = bundledUpdaterPath;
        _bundledUninstallerPath = bundledUninstallerPath;
        _brokerClient = brokerClient ?? new LicenseBrokerClient();
        _downloader = downloader ?? new HttpDownloader();
    }

    public async Task<InstallResult> RunAsync(InstallPlan plan, IProgress<InstallStepProgress> progress, CancellationToken cancellationToken)
    {
        try
        {
            progress.Report(new InstallStepProgress("Validating license key", 0.0, null));
            var localCheck = LocalLicenseValidator.Validate(plan.LicenseKey);
            if (!localCheck.SignatureValid || localCheck.Expired)
            {
                return new InstallResult(false, localCheck.Message, null);
            }

            var broker = await _brokerClient.ValidateAndIssueAsync(plan.LicenseKey, cancellationToken).ConfigureAwait(false);
            if (!broker.Valid)
            {
                return new InstallResult(false, broker.Message, null);
            }

            var downloadCacheDir = Path.Combine(Path.GetTempPath(), "RfqInstallerDownloads");
            if (plan.CleanReinstall && Directory.Exists(downloadCacheDir))
            {
                Directory.Delete(downloadCacheDir, recursive: true);
            }
            Directory.CreateDirectory(downloadCacheDir);
            Directory.CreateDirectory(plan.InstallPath);

            progress.Report(new InstallStepProgress("Downloading application components", 0.1, null));
            await DownloadAndExtractComponentsAsync(broker.Components, downloadCacheDir, plan.InstallPath, progress, cancellationToken)
                .ConfigureAwait(false);

            progress.Report(new InstallStepProgress("Generating credentials", 0.4, null));
            var superUserPassword = PasswordGenerator.Generate();
            var appUserPassword = PasswordGenerator.Generate();
            var settingsPassword = plan.SettingsPassword;

            progress.Report(new InstallStepProgress("Setting up database", 0.45, null));
            var provisioner = new PostgresProvisioner(_downloader);
            var pgProgress = new Progress<string>(msg => progress.Report(new InstallStepProgress("Setting up database", 0.45, msg)));
            var instance = await provisioner.ProvisionAsync(plan.InstallPath, superUserPassword, pgProgress, cancellationToken)
                .ConfigureAwait(false);
            await DatabaseSetup.EnsureDatabaseAndUserAsync(instance.Port, superUserPassword, appUserPassword, pgProgress, cancellationToken)
                .ConfigureAwait(false);

            progress.Report(new InstallStepProgress("Configuring application", 0.65, null));
            ConfigureApplication(plan, broker, instance.Port, superUserPassword, appUserPassword, settingsPassword);

            progress.Report(new InstallStepProgress("Generating security certificate", 0.7, null));
            SelfSignedCertGenerator.GenerateIfMissing(plan.InstallPath);

            var mainExePath = Path.Combine(plan.InstallPath, "RFQ_Application.exe");

            if (plan.Mode == InstallMode.WindowsService)
            {
                progress.Report(new InstallStepProgress("Registering Windows service", 0.8, null));
                await RegisterServicesAsync(plan, mainExePath, cancellationToken).ConfigureAwait(false);
            }
            else
            {
                progress.Report(new InstallStepProgress("Finishing standalone install", 0.8, null));
            }

            if (plan.Mode == InstallMode.Standalone && plan.CreateDesktopShortcut)
            {
                progress.Report(new InstallStepProgress("Creating desktop shortcut", 0.9, null));
                CreateDesktopShortcut(mainExePath, plan.InstallPath);
            }

            if (plan.DownloadModelNow && broker.ModelFiles.Count > 0)
            {
                progress.Report(new InstallStepProgress("Downloading AI model", 0.92, null));
                await DownloadModelAsync(broker.ModelFiles, plan.ModelPath, progress, cancellationToken).ConfigureAwait(false);
            }

            if (plan.CleanupAfterInstall && Directory.Exists(downloadCacheDir))
            {
                Directory.Delete(downloadCacheDir, recursive: true);
            }

            if (_bundledUninstallerPath is not null && File.Exists(_bundledUninstallerPath))
            {
                File.Copy(_bundledUninstallerPath, Path.Combine(plan.InstallPath, "RfqInstaller.Uninstall.exe"), overwrite: true);
                var versionFile = Path.Combine(plan.InstallPath, "version.txt");
                var version = File.Exists(versionFile) ? File.ReadAllText(versionFile).Trim() : "1.0.0";
                UninstallRegistration.Register(plan.InstallPath, version);
            }

            progress.Report(new InstallStepProgress("Finishing up", 1.0, null));
            return new InstallResult(true, null, mainExePath);
        }
        catch (OperationCanceledException)
        {
            return new InstallResult(false, "Installation was cancelled.", null);
        }
        catch (Exception ex)
        {
            return new InstallResult(false, ex.Message, null);
        }
    }

    private async Task DownloadAndExtractComponentsAsync(
        IReadOnlyList<PackageComponent> components,
        string downloadCacheDir,
        string installPath,
        IProgress<InstallStepProgress> progress,
        CancellationToken cancellationToken)
    {
        for (var i = 0; i < components.Count; i++)
        {
            var component = components[i];
            var zipPath = Path.Combine(downloadCacheDir, $"{component.Name}.zip");

            var dlProgress = new Progress<DownloadProgress>(p =>
            {
                var fraction = 0.1 + 0.3 * (i + (p.TotalBytes is > 0 ? (double)p.BytesReceived / p.TotalBytes.Value : 0)) / Math.Max(1, components.Count);
                progress.Report(new InstallStepProgress("Downloading application components", fraction, component.Name));
            });

            await _downloader.DownloadAsync(component.Url, zipPath, component.SizeBytes, dlProgress, cancellationToken).ConfigureAwait(false);
            ZipExtractor.Extract(zipPath, installPath, progress: null, cancellationToken);
        }

        File.Copy(_bundledNssmPath, Path.Combine(installPath, "nssm.exe"), overwrite: true);
        File.Copy(_bundledUpdaterPath, Path.Combine(installPath, "windows_updater.exe"), overwrite: true);
    }

    private static void ConfigureApplication(
        InstallPlan plan,
        BrokerResponse broker,
        int dbPort,
        string superUserPassword,
        string appUserPassword,
        string settingsPassword)
    {
        var encryptionKey = plan.AutoGenerateEncryptionKey
            ? Convert.ToBase64String(System.Security.Cryptography.RandomNumberGenerator.GetBytes(32))
            : plan.CustomEncryptionKey ?? string.Empty;

        // Explicit customer choice, applies to all three passwords. Credential Manager only
        // actually works when the service runs as Current User — for Network Service/Local System
        // it silently can't be read back at runtime, so fall back to .env in that combination
        // rather than producing an install that looks configured but isn't (the wizard's Advanced
        // page already warns about this combination before install starts).
        var effectivelyUseCredentialManager = plan.UseCredentialManager && plan.ServiceAccount == ServiceAccountKind.CurrentUser;

        var envValues = new Dictionary<string, string>
        {
            ["RFQ_CONFIG_ENCRYPTION_KEY"] = encryptionKey,
            ["SERVER_URL"] = broker.DefaultServerUrl ?? plan.ServerUrl,
            ["RFQ_UPDATE_CHANNEL"] = broker.UpdateChannel ?? plan.UpdateChannel,
            ["WINDOWS"] = "true",
            ["LOCAL_DATABASE"] = "1",
            ["CONTAINER"] = "0",
        };

        if (effectivelyUseCredentialManager)
        {
            CredentialManagerWriter.TryWrite("RFQApplication_SQL_SUPER_USER", "postgres", superUserPassword);
            CredentialManagerWriter.TryWrite("RFQApplication_RFQ_USER_PASSWORD", DatabaseSetup.AppUserName, appUserPassword);
            CredentialManagerWriter.TryWrite("RFQApplication_SETTINGS_PASSWORD", "rfq_app", settingsPassword);

            envValues["SQL_SUPER_USER"] = CredentialManagerWriter.Sentinel;
            envValues["RFQ_USER_PASSWORD"] = CredentialManagerWriter.Sentinel;
            envValues["SETTINGS_PASSWORD"] = CredentialManagerWriter.Sentinel;
        }
        else
        {
            // Explicit, accepted tradeoff: real values in plaintext .env.
            envValues["SQL_SUPER_USER"] = superUserPassword;
            envValues["RFQ_USER_PASSWORD"] = appUserPassword;
            envValues["SETTINGS_PASSWORD"] = settingsPassword;
        }

        EnvFileWriter.Upsert(plan.InstallPath, envValues);

        UserConfigWriter.WriteLicense(plan.InstallPath, plan.LicenseKey, broker.CustomerId, broker.Features, broker.Limits);
    }

    private async Task RegisterServicesAsync(InstallPlan plan, string mainExePath, CancellationToken cancellationToken)
    {
        var nssm = new NssmServiceManager(Path.Combine(plan.InstallPath, "nssm.exe"));
        var logsDir = Path.Combine(plan.InstallPath, "logs");
        Directory.CreateDirectory(logsDir);

        string? currentUserAccount = null;
        if (plan.ServiceAccount == ServiceAccountKind.CurrentUser)
        {
            currentUserAccount = plan.ServiceAccountName
                ?? $"{Environment.UserDomainName}\\{Environment.UserName}";
            ServiceLogonRight.TryGrant(currentUserAccount);
        }

        await nssm.InstallOrReplaceAsync(
            AppServiceName,
            "RFQ Application Service",
            "Runs the RFQ Automation application.",
            mainExePath,
            plan.InstallPath,
            appParameters: null,
            Path.Combine(logsDir, "RFQapplication_stdout.log"),
            Path.Combine(logsDir, "RFQapplication_stderr.log"),
            plan.ServiceAccount,
            currentUserAccount,
            plan.ServiceAccountPassword,
            cancellationToken).ConfigureAwait(false);

        await nssm.InstallOrReplaceAsync(
            UpdaterServiceName,
            "RFQ Updater Service",
            "Checks for and applies RFQ Application updates.",
            Path.Combine(plan.InstallPath, "windows_updater.exe"),
            plan.InstallPath,
            appParameters: "--service",
            Path.Combine(logsDir, "RFQUpdaterService_stdout.log"),
            Path.Combine(logsDir, "RFQUpdaterService_stderr.log"),
            plan.ServiceAccount,
            currentUserAccount,
            plan.ServiceAccountPassword,
            cancellationToken).ConfigureAwait(false);
    }

    private static void CreateDesktopShortcut(string mainExePath, string installPath)
    {
        var desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
        var shortcutPath = Path.Combine(desktop, "RFQ Application.lnk");
        ShellShortcut.Create(shortcutPath, mainExePath, installPath, mainExePath, "RFQ Application");
    }

    private async Task DownloadModelAsync(
        IReadOnlyList<ModelFileEntry> modelFiles,
        string modelPath,
        IProgress<InstallStepProgress> progress,
        CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(modelPath);
        for (var i = 0; i < modelFiles.Count; i++)
        {
            var file = modelFiles[i];
            var destination = Path.Combine(modelPath, file.RelativePath);

            var dlProgress = new Progress<DownloadProgress>(p =>
            {
                var fraction = 0.92 + 0.08 * (i + (p.TotalBytes is > 0 ? (double)p.BytesReceived / p.TotalBytes.Value : 0)) / Math.Max(1, modelFiles.Count);
                progress.Report(new InstallStepProgress("Downloading AI model", fraction, file.RelativePath));
            });

            await _downloader.DownloadAsync(file.Url, destination, file.SizeBytes, dlProgress, cancellationToken).ConfigureAwait(false);
        }
    }
}
