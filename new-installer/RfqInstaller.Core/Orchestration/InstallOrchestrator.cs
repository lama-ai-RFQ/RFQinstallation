using RfqInstaller.Core.Archive;
using RfqInstaller.Core.Certificates;
using RfqInstaller.Core.Config;
using RfqInstaller.Core.Database;
using RfqInstaller.Core.Elevation;
using RfqInstaller.Core.Licensing;
using RfqInstaller.Core.Models;
using RfqInstaller.Core.Networking;
using RfqInstaller.Core.Processes;
using RfqInstaller.Core.Security;
using RfqInstaller.Core.Services;
using RfqInstaller.Core.Shortcuts;

namespace RfqInstaller.Core.Orchestration;

public record InstallStepProgress(string StepName, double FractionComplete, string? Detail);

public record InstallResult(
    bool Success,
    string? ErrorMessage,
    string? MainExecutablePath,
    Exception? Cause = null);

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
    private readonly IInstallInteraction? _interaction;
    private readonly string _bundledNssmPath;
    private readonly string _bundledUpdaterPath;
    private readonly string? _bundledUninstallerPath;

    public InstallOrchestrator(
        string bundledNssmPath,
        string bundledUpdaterPath,
        string? bundledUninstallerPath = null,
        LicenseBrokerClient? brokerClient = null,
        HttpDownloader? downloader = null,
        IInstallInteraction? interaction = null)
    {
        _bundledNssmPath = bundledNssmPath;
        _bundledUpdaterPath = bundledUpdaterPath;
        _bundledUninstallerPath = bundledUninstallerPath;
        _brokerClient = brokerClient ?? new LicenseBrokerClient();
        _downloader = downloader ?? new HttpDownloader();
        _interaction = interaction;
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

            var release = await _brokerClient.ActivateAndGetSignedWindowsReleaseAsync(
                plan.LicenseKey,
                plan.UpdateChannel,
                cancellationToken).ConfigureAwait(false);

            var downloadCacheDir = Path.Combine(Path.GetTempPath(), "RfqInstallerDownloads");
            if (plan.CleanReinstall && Directory.Exists(downloadCacheDir))
            {
                Directory.Delete(downloadCacheDir, recursive: true);
            }
            Directory.CreateDirectory(downloadCacheDir);
            Directory.CreateDirectory(plan.InstallPath);

            progress.Report(new InstallStepProgress("Downloading application components", 0.1, null));
            await DownloadAndExtractComponentsAsync(release, downloadCacheDir, plan.InstallPath, progress, cancellationToken)
                .ConfigureAwait(false);

            progress.Report(new InstallStepProgress("Generating credentials", 0.4, null));
            // rfq_user's password is safe to regenerate every run — DatabaseSetup always ALTERs it
            // to match, so Credential Manager/.env and the real role stay in sync either way. The
            // postgres superuser is different: if a data directory from a prior install already
            // exists, its password was fixed once during that original initdb and can't be changed
            // by generating a new one here — reuse the real existing value instead, or the
            // maintenance connection below will fail to authenticate against the cluster that's
            // actually there.
            string superUserPassword;
            if (PostgresProvisioner.IsAlreadyInitialized(plan.InstallPath))
            {
                var existing = StoredCredentialsResolver.ResolveAll(plan.InstallPath)
                    .FirstOrDefault(c => c.EnvKey == "SQL_SUPER_USER");
                superUserPassword = existing?.Value
                    ?? throw new InvalidOperationException(
                        "Found an existing PostgreSQL data directory, but its superuser password could not be recovered " +
                        "from Credential Manager or .env. Delete the 'pgdata' folder under the install path to start a " +
                        "fresh database, or restore the missing credential before reinstalling.");
            }
            else if (!plan.AutoGeneratePostgresPasswords &&
                     !string.IsNullOrWhiteSpace(plan.CustomSqlSuperUserPassword))
            {
                superUserPassword = plan.CustomSqlSuperUserPassword;
            }
            else
            {
                superUserPassword = PasswordGenerator.Generate();
            }

            var appUserPassword = !plan.AutoGeneratePostgresPasswords &&
                                  !string.IsNullOrWhiteSpace(plan.CustomRfqUserPassword)
                ? plan.CustomRfqUserPassword
                : PasswordGenerator.Generate();
            var settingsPassword = plan.SettingsPassword;

            // initdb makes this password authoritative before the rest of database/application
            // setup runs. Persist it first so a failure after initdb cannot leave an initialized
            // pgdata directory whose generated password is lost on Retry.
            PersistSuperUserPasswordForRecovery(plan, superUserPassword);

            progress.Report(new InstallStepProgress("Setting up database", 0.45, null));
            var provisioner = new PostgresProvisioner(_downloader);
            var pgProgress = new Progress<string>(msg => progress.Report(new InstallStepProgress("Setting up database", 0.45, msg)));
            var postgresBinaries = await ResolvePostgresBinariesAsync(plan.InstallPath, cancellationToken)
                .ConfigureAwait(false);
            var instance = await provisioner.ProvisionAsync(
                    plan.InstallPath,
                    superUserPassword,
                    pgProgress,
                    cancellationToken,
                    postgresBinaries)
                .ConfigureAwait(false);
            await DatabaseSetup.EnsureDatabaseAndUserAsync(instance.Port, superUserPassword, appUserPassword, pgProgress, cancellationToken)
                .ConfigureAwait(false);

            progress.Report(new InstallStepProgress("Configuring application", 0.65, null));
            ConfigureApplication(
                plan,
                release.Release,
                localCheck,
                instance.Port,
                superUserPassword,
                appUserPassword,
                settingsPassword);

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
            return new InstallResult(false, FormatFailure(ex), null, ex);
        }
    }

    private static string FormatFailure(Exception exception)
    {
        if (exception is BrokerClientException broker)
        {
            return broker.Message;
        }

        var root = exception;
        while (root.InnerException is not null)
        {
            root = root.InnerException;
        }

        return root == exception
            ? $"{exception.GetType().Name}: {exception.Message}"
            : $"{exception.GetType().Name}: {exception.Message}{Environment.NewLine}{root.GetType().Name}: {root.Message}";
    }

    private async Task<SignedArtifact?> ResolvePostgresBinariesAsync(
        string installPath,
        CancellationToken cancellationToken)
    {
        if (File.Exists(Path.Combine(installPath, "pgsql", "bin", "postgres.exe")) ||
            !string.IsNullOrWhiteSpace(PostgresBinariesConfig.DownloadUrl))
        {
            return null;
        }

        var signed = await _brokerClient.SignRuntimeAssetsAsync(
            new[] { PostgresBinariesConfig.RuntimeAssetId },
            cancellationToken).ConfigureAwait(false);
        return signed.Artifacts[0];
    }

    private async Task DownloadAndExtractComponentsAsync(
        SignedWindowsRelease release,
        string downloadCacheDir,
        string installPath,
        IProgress<InstallStepProgress> progress,
        CancellationToken cancellationToken)
    {
        var metadataById = release.Release.Artifacts.ToDictionary(
            artifact => artifact.ArtifactId,
            StringComparer.Ordinal);
        var downloaded = new List<string>();
        for (var i = 0; i < release.Artifacts.Count; i++)
        {
            var signed = release.Artifacts[i];
            if (!metadataById.TryGetValue(signed.ArtifactId, out var metadata))
            {
                throw new InvalidDataException($"Signed artifact '{signed.ArtifactId}' is absent from the release catalog.");
            }
            if (signed.Size != metadata.Size ||
                !string.Equals(signed.Sha256, metadata.Sha256, StringComparison.Ordinal))
            {
                throw new InvalidDataException($"Signed artifact '{signed.ArtifactId}' does not match the release catalog.");
            }
            var fileName = Path.GetFileName(metadata.Name);
            if (!string.Equals(fileName, metadata.Name, StringComparison.Ordinal) ||
                string.IsNullOrWhiteSpace(fileName))
            {
                throw new InvalidDataException($"Release artifact '{signed.ArtifactId}' has an unsafe filename.");
            }
            var destination = Path.Combine(downloadCacheDir, fileName);

            var dlProgress = new Progress<DownloadProgress>(p =>
            {
                var fraction = 0.1 + 0.3 * (i + (p.TotalBytes is > 0 ? (double)p.BytesReceived / p.TotalBytes.Value : 0)) /
                    Math.Max(1, release.Artifacts.Count);
                progress.Report(new InstallStepProgress("Downloading application components", fraction, fileName));
            });

            await _downloader.DownloadAsync(
                    signed.Url,
                    destination,
                    signed.Size,
                    dlProgress,
                    cancellationToken,
                    expectedSha256: signed.Sha256)
                .ConfigureAwait(false);
            downloaded.Add(destination);
        }

        foreach (var firstPart in downloaded.Where(path => path.EndsWith(".zip.part1", StringComparison.OrdinalIgnoreCase)))
        {
            var archivePath = firstPart[..^".part1".Length];
            var partPrefix = Path.GetFileName(archivePath) + ".part";
            var partNumbers = downloaded
                .Select(Path.GetFileName)
                .Where(name => name is not null && name.StartsWith(partPrefix, StringComparison.OrdinalIgnoreCase))
                .Select(name => int.TryParse(name![partPrefix.Length..], out var number) ? number : 0)
                .Where(number => number > 0)
                .Order()
                .ToArray();
            if (partNumbers.Length == 0 ||
                !partNumbers.SequenceEqual(Enumerable.Range(1, partNumbers[^1])))
            {
                throw new InvalidDataException($"Archive '{Path.GetFileName(archivePath)}' has missing or malformed parts.");
            }
            await using (var output = new FileStream(
                             archivePath,
                             FileMode.Create,
                             FileAccess.Write,
                             FileShare.None,
                             1 << 20,
                             useAsync: true))
            {
                foreach (var partNumber in partNumbers)
                {
                    var partPath = $"{archivePath}.part{partNumber}";
                    await using var input = new FileStream(
                        partPath,
                        FileMode.Open,
                        FileAccess.Read,
                        FileShare.Read,
                        1 << 20,
                        useAsync: true);
                    await input.CopyToAsync(output, cancellationToken).ConfigureAwait(false);
                }
            }
            await ExtractReplacingLockedFilesAsync(
                    () => ZipExtractor.Extract(archivePath, installPath, progress: null, cancellationToken),
                    installPath,
                    progress,
                    cancellationToken)
                .ConfigureAwait(false);
        }

        foreach (var archive in downloaded.Where(path => path.EndsWith(".zip", StringComparison.OrdinalIgnoreCase)))
        {
            await ExtractReplacingLockedFilesAsync(
                    () => ZipExtractor.Extract(archive, installPath, progress: null, cancellationToken),
                    installPath,
                    progress,
                    cancellationToken)
                .ConfigureAwait(false);
        }

        var manifest = downloaded.FirstOrDefault(path =>
            string.Equals(Path.GetFileName(path), "manifest.json", StringComparison.OrdinalIgnoreCase));
        if (manifest is not null)
        {
            File.Copy(manifest, Path.Combine(installPath, "local_manifest.json"), overwrite: true);
        }

        File.Copy(_bundledNssmPath, Path.Combine(installPath, "nssm.exe"), overwrite: true);
        File.Copy(_bundledUpdaterPath, Path.Combine(installPath, "windows_updater.exe"), overwrite: true);
    }

    private async Task ExtractReplacingLockedFilesAsync(
        Action extract,
        string installPath,
        IProgress<InstallStepProgress> progress,
        CancellationToken cancellationToken)
    {
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            await EnsureInstallFilesUnlockedAsync(installPath, progress, cancellationToken).ConfigureAwait(false);
            try
            {
                extract();
                return;
            }
            catch (Exception ex) when (InstallDirectoryProcesses.IsFileInUse(ex))
            {
                progress.Report(new InstallStepProgress(
                    "Waiting for running programs to close",
                    0.38,
                    "A file in the install folder is still in use."));
            }
        }
    }

    private async Task EnsureInstallFilesUnlockedAsync(
        string installPath,
        IProgress<InstallStepProgress> progress,
        CancellationToken cancellationToken)
    {
        var nssm = File.Exists(_bundledNssmPath)
            ? new NssmServiceManager(_bundledNssmPath)
            : new NssmServiceManager("nssm.exe");
        progress.Report(new InstallStepProgress("Stopping existing RFQ services", 0.38, null));
        await nssm.StopIfExistsAsync(AppServiceName, cancellationToken).ConfigureAwait(false);
        await nssm.StopIfExistsAsync(UpdaterServiceName, cancellationToken).ConfigureAwait(false);

        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var running = InstallDirectoryProcesses.Find(installPath);
            if (running.Count == 0)
            {
                return;
            }

            progress.Report(new InstallStepProgress(
                "Waiting for running programs to close",
                0.38,
                string.Join(", ", running.Select(process => process.Name).Distinct(StringComparer.OrdinalIgnoreCase))));

            if (_interaction is null)
            {
                InstallDirectoryProcesses.Stop(running);
                await Task.Delay(TimeSpan.FromSeconds(2), cancellationToken).ConfigureAwait(false);
                running = InstallDirectoryProcesses.Find(installPath);
                if (running.Count > 0)
                {
                    throw new IOException(
                        "The install folder is still in use by: " +
                        string.Join(", ", running.Select(process => $"{process.Name} ({process.Id})")) +
                        ". Close RFQ Application and try again.");
                }

                return;
            }

            var confirmed = await _interaction.ConfirmStopRunningProcessesAsync(running, cancellationToken)
                .ConfigureAwait(false);
            if (!confirmed)
            {
                throw new OperationCanceledException("Installation was cancelled because running programs were not closed.");
            }

            InstallDirectoryProcesses.Stop(running);
            await Task.Delay(TimeSpan.FromSeconds(2), cancellationToken).ConfigureAwait(false);
        }
    }

    private static void ConfigureApplication(
        InstallPlan plan,
        WindowsRelease release,
        LocalLicenseCheck license,
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
        var envValues = new Dictionary<string, string>
        {
            ["LICENSE_KEY"] = plan.LicenseKey,
            ["RFQ_LICENSE_BROKER_URL"] = plan.BrokerUrl,
            ["RFQ_UPDATER_SOURCE"] = "aws",
            ["RFQ_RUNTIME_ASSET_MODE"] = "broker",
            // Older app builds only read AZURE_CONFIG_ENCRYPTION_KEY. Write both to the same
            // value so a leftover RFQ_ placeholder in env.template cannot shadow the real key.
            ["AZURE_CONFIG_ENCRYPTION_KEY"] = encryptionKey,
            ["RFQ_CONFIG_ENCRYPTION_KEY"] = encryptionKey,
            ["SERVER_URL"] = plan.ServerUrl,
            ["RFQ_UPDATE_CHANNEL"] = release.Channel,
            ["WINDOWS"] = "true",
            ["LOCAL_DATABASE"] = "1",
            ["CONTAINER"] = "0",
            // The private Postgres instance runs on its own port (PostgresBinariesConfig.DefaultPort),
            // deliberately not 5432 — the app's own default (backend/config/database.py) is 5432, so
            // this must always be written or the app connects to nothing.
            ["DB_PORT"] = dbPort.ToString(),
            ["MODEL_PATH"] = DefaultPaths.DefaultModelPath(),
        };

        envValues["SQL_SUPER_USER"] = StoreCredentialOrUsePlaintext(
            plan, "RFQApplication_SQL_SUPER_USER", "postgres", superUserPassword);
        envValues["RFQ_USER_PASSWORD"] = StoreCredentialOrUsePlaintext(
            plan, "RFQApplication_RFQ_USER_PASSWORD", DatabaseSetup.AppUserName, appUserPassword);
        envValues["SETTINGS_PASSWORD"] = StoreCredentialOrUsePlaintext(
            plan, "RFQApplication_SETTINGS_PASSWORD", "rfq_app", settingsPassword);

        EnvFileWriter.Upsert(plan.InstallPath, envValues);

        UserConfigWriter.WriteLicense(
            plan.InstallPath,
            plan.LicenseKey,
            license.CustomerId,
            license.Features,
            license.Limits);
    }

    private static void PersistSuperUserPasswordForRecovery(InstallPlan plan, string password)
    {
        var storedValue = StoreCredentialOrUsePlaintext(
            plan,
            "RFQApplication_SQL_SUPER_USER",
            "postgres",
            password);
        EnvFileWriter.Upsert(
            plan.InstallPath,
            new Dictionary<string, string> { ["SQL_SUPER_USER"] = storedValue });
    }

    private static string StoreCredentialOrUsePlaintext(
        InstallPlan plan,
        string targetName,
        string userName,
        string password)
    {
        var effectivelyUseCredentialManager =
            plan.UseCredentialManager && plan.ServiceAccount == ServiceAccountKind.CurrentUser;
        return effectivelyUseCredentialManager &&
               CredentialManagerWriter.TryWrite(targetName, userName, password)
            ? CredentialManagerWriter.Sentinel
            : password;
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
}
