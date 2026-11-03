using System.Security.AccessControl;
using System.Text.RegularExpressions;
using Microsoft.Win32;
using RfqInstaller.Core.Archive;
using RfqInstaller.Core.Models;
using RfqInstaller.Core.Networking;
using RfqInstaller.Core.Orchestration;
using RfqInstaller.Core.Processes;
using RfqInstaller.Core.Security;
using RfqInstaller.Core.Services;

namespace RfqInstaller.Core.Database;

public record PostgresInstance(string BinDir, string DataDir, int Port, string ServiceName, string SuperUserPassword);

/// <summary>
/// Provisions a private, app-owned PostgreSQL instance under the install directory — no system-wide
/// install, no PATH dependency, no interactive EDB installer. Binaries come from a portable "zip"
/// distribution (see PostgresBinariesConfig); the instance runs on its own dedicated port and its
/// own Windows service so it can never collide with a PostgreSQL the customer already has installed
/// for something else. Safe to re-run: skips steps whose result already exists on disk.
/// </summary>
public partial class PostgresProvisioner
{
    public const string ServiceName = "RFQPostgreSQL";

    /// <summary>
    /// True when a data directory from a prior install/provision already exists — its superuser
    /// password was fixed once, during that original <c>initdb</c>, and cannot be changed by
    /// supplying a different password here (see <see cref="ProvisionAsync"/>: initialization is
    /// skipped entirely when this is true). Callers must resolve and reuse the real existing
    /// password rather than generating a new one, or the maintenance connection will fail to
    /// authenticate against the cluster that's actually there.
    /// </summary>
    public static bool IsAlreadyInitialized(string installPath) =>
        File.Exists(Path.Combine(installPath, "pgdata", "PG_VERSION"));

    private readonly HttpDownloader _downloader;

    public PostgresProvisioner(HttpDownloader? downloader = null)
    {
        _downloader = downloader ?? new HttpDownloader();
    }

    public async Task<PostgresInstance> ProvisionAsync(
        string installPath,
        string generatedSuperUserPassword,
        IProgress<string>? progress,
        CancellationToken cancellationToken,
        SignedArtifact? binaries = null)
    {
        var binDir = Path.Combine(installPath, "pgsql");
        var dataDir = Path.Combine(installPath, "pgdata");

        if (!File.Exists(Path.Combine(binDir, "bin", "postgres.exe")))
        {
            var url = binaries?.Url ?? PostgresBinariesConfig.DownloadUrl;
            var sha256 = binaries?.Sha256 ?? PostgresBinariesConfig.Sha256;
            long? size = binaries is { Size: > 0 } ? binaries.Size : null;
            if (string.IsNullOrWhiteSpace(url))
            {
                throw new InvalidOperationException(
                    "PostgreSQL binaries are not available. Activate a license so the installer can " +
                    $"sign '{PostgresBinariesConfig.RuntimeAssetId}', or set RFQ_POSTGRES_BINARIES_URL.");
            }

            progress?.Report("Downloading PostgreSQL engine...");
            var zipPath = Path.Combine(Path.GetTempPath(), $"rfq-postgres-{PostgresBinariesConfig.Version}.zip");
            await _downloader.DownloadAsync(
                    url,
                    zipPath,
                    size,
                    progress: null,
                    cancellationToken,
                    expectedSha256: sha256)
                .ConfigureAwait(false);

            progress?.Report("Extracting PostgreSQL engine...");
            // EDB's portable zip has pgsql/ at the archive root. Extract into the install
            // folder so postgres.exe lands at {install}\pgsql\bin\postgres.exe.
            ZipExtractor.Extract(zipPath, installPath, progress: null, cancellationToken);
            if (!File.Exists(Path.Combine(binDir, "bin", "postgres.exe")))
            {
                throw new InvalidOperationException(
                    "The PostgreSQL zip did not contain pgsql/bin/postgres.exe.");
            }
        }

        var pgCtl = Path.Combine(binDir, "bin", "pg_ctl.exe");
        var initDb = Path.Combine(binDir, "bin", "initdb.exe");

        // initdb and the service read these files after dropping administrator rights (see
        // FolderAccess), so the accounts themselves need read access wherever the install lives.
        FolderAccess.Grant(binDir, FileSystemRights.ReadAndExecute, new[] { AccountIdentity.CurrentSid(), AccountIdentity.LocalSystem });

        var alreadyInitialized = File.Exists(Path.Combine(dataDir, "PG_VERSION"));
        if (!alreadyInitialized)
        {
            progress?.Report("Initializing database cluster...");
            PrepareDataDirectory(dataDir);
            await InitializeDataDirectoryAsync(initDb, dataDir, generatedSuperUserPassword, cancellationToken).ConfigureAwait(false);
            SetPort(dataDir, PostgresBinariesConfig.DefaultPort);
            RestrictToLocalhost(dataDir);
        }

        await EnsureServiceRegisteredAsync(pgCtl, dataDir, progress, cancellationToken).ConfigureAwait(false);

        progress?.Report("Starting PostgreSQL service...");
        await HiddenProcessRunner.RunAsync("sc.exe", new[] { "start", ServiceName }, cancellationToken: cancellationToken)
            .ConfigureAwait(false); // ignore exit code: "already running" is not an error here

        progress?.Report("Waiting for PostgreSQL to accept connections...");
        await WaitUntilAcceptingConnectionsAsync(binDir, progress, cancellationToken).ConfigureAwait(false);

        return new PostgresInstance(binDir, dataDir, PostgresBinariesConfig.DefaultPort, ServiceName, generatedSuperUserPassword);
    }

    /// <summary>
    /// Brings an already-initialized cluster back up (binaries, service registration, start, wait)
    /// without touching its data or passwords. initdb is skipped for an initialized cluster, which
    /// is the only step that uses the superuser password, so none is needed here.
    /// </summary>
    public Task<PostgresInstance> StartExistingAsync(
        string installPath,
        IProgress<string>? progress,
        CancellationToken cancellationToken,
        SignedArtifact? binaries = null)
    {
        if (!IsAlreadyInitialized(installPath))
        {
            throw new InvalidOperationException($"No PostgreSQL data directory was found in {Path.Combine(installPath, "pgdata")}.");
        }

        return ProvisionAsync(installPath, string.Empty, progress, cancellationToken, binaries);
    }

    /// <summary>
    /// Creates pgdata for initdb, readable only by the account running Setup (initdb runs as it,
    /// without its administrator rights), SYSTEM (the PostgreSQL service) and Administrators.
    /// Without this initdb can't create the folder under Program Files or in another user's
    /// profile, and would otherwise leave it readable by every user on the machine.
    /// </summary>
    internal static void PrepareDataDirectory(string dataDir)
    {
        if (Directory.Exists(dataDir) && Directory.EnumerateFileSystemEntries(dataDir).Any())
        {
            throw new InvalidOperationException(
                $"{dataDir} already exists but holds no database (it has no PG_VERSION file), so it is probably left " +
                "over from an install that failed. Delete that folder and try again.");
        }

        FolderAccess.CreatePrivateDirectory(
            dataDir,
            new[] { AccountIdentity.CurrentSid(), AccountIdentity.LocalSystem, AccountIdentity.Administrators });
    }

    /// <summary>
    /// Registers the RFQPostgreSQL service for this install's pgdata. A service left by another or
    /// a failed install that points at a different folder is replaced; reusing it would start
    /// PostgreSQL against the wrong (or a deleted) data directory.
    /// </summary>
    private static async Task EnsureServiceRegisteredAsync(
        string pgCtl,
        string dataDir,
        IProgress<string>? progress,
        CancellationToken cancellationToken)
    {
        var control = new ServiceControl();
        var registered = (await control.QueryAsync(ServiceName, cancellationToken).ConfigureAwait(false)).State
                         != ServiceState.NotInstalled;
        if (registered)
        {
            var imagePath = ReadServiceImagePath();
            if (PointsAt(imagePath, pgCtl, dataDir))
            {
                return;
            }

            progress?.Report($"Replacing a PostgreSQL service left from an earlier install ({DataDirFromImagePath(imagePath) ?? "unknown folder"})...");
            await control.StopIfExistsAsync(ServiceName, cancellationToken).ConfigureAwait(false);
            var delete = await HiddenProcessRunner.RunAsync("sc.exe", new[] { "delete", ServiceName }, cancellationToken: cancellationToken)
                .ConfigureAwait(false);
            if (delete.ExitCode is not (0 or 1060 or 1072))
            {
                throw new InvalidOperationException(
                    $"Could not remove the old {ServiceName} service (exit code {delete.ExitCode}): {delete.StdOut.Trim()}");
            }
            await control.WaitUntilRemovedAsync(ServiceName, cancellationToken).ConfigureAwait(false);
        }

        progress?.Report("Registering PostgreSQL as a Windows service...");
        var register = await HiddenProcessRunner.RunAsync(
            pgCtl,
            new[] { "register", "-N", ServiceName, "-D", dataDir, "-w" },
            cancellationToken: cancellationToken).ConfigureAwait(false);
        if (register.ExitCode != 0)
        {
            throw new InvalidOperationException($"pg_ctl register failed: {register.StdErr}");
        }
    }

    internal static bool PointsAt(string? imagePath, string pgCtl, string dataDir)
    {
        var registeredDataDir = DataDirFromImagePath(imagePath);
        var registeredInstall = ExistingInstallDetector.InstallDirFromPostgresImagePath(imagePath);
        var ownInstall = Path.GetDirectoryName(Path.GetDirectoryName(Path.GetDirectoryName(pgCtl)));
        return registeredDataDir is not null && registeredInstall is not null && ownInstall is not null &&
               SamePath(registeredDataDir, dataDir) && SamePath(registeredInstall, ownInstall);
    }

    /// <summary>The -D argument of <c>pg_ctl runservice</c>, as pg_ctl register writes it.</summary>
    internal static string? DataDirFromImagePath(string? imagePath)
    {
        if (string.IsNullOrWhiteSpace(imagePath))
        {
            return null;
        }

        var match = DataDirArgumentRegex().Match(imagePath);
        if (!match.Success)
        {
            return null;
        }

        return match.Groups[1].Success ? match.Groups[1].Value : match.Groups[2].Value;
    }

    private static bool SamePath(string a, string b)
    {
        try
        {
            return string.Equals(
                Path.GetFullPath(a.Trim().Trim('"')).TrimEnd('\\', '/'),
                Path.GetFullPath(b.Trim().Trim('"')).TrimEnd('\\', '/'),
                StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return false;
        }
    }

    private static string? ReadServiceImagePath()
    {
        try
        {
            using var key = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Services\" + ServiceName);
            return key?.GetValue("ImagePath", null, RegistryValueOptions.DoNotExpandEnvironmentNames) as string;
        }
        catch (Exception ex) when (ex is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            return null;
        }
    }

    [GeneratedRegex(@"\s-D\s+(?:""([^""]+)""|(\S+))")]
    private static partial Regex DataDirArgumentRegex();

    private static async Task InitializeDataDirectoryAsync(string initDbExe, string dataDir, string superUserPassword, CancellationToken cancellationToken)
    {
        var pwFile = Path.GetTempFileName();
        try
        {
            await File.WriteAllTextAsync(pwFile, superUserPassword, cancellationToken).ConfigureAwait(false);

            var result = await HiddenProcessRunner.RunAsync(
                initDbExe,
                new[] { "-U", "postgres", "-A", "scram-sha-256", "-E", "UTF8", "-D", dataDir, "--pwfile=" + pwFile },
                cancellationToken: cancellationToken).ConfigureAwait(false);

            if (result.ExitCode != 0)
            {
                throw new InvalidOperationException($"initdb failed: {result.StdErr}");
            }
        }
        finally
        {
            File.Delete(pwFile);
        }
    }

    private static void SetPort(string dataDir, int port)
    {
        var confPath = Path.Combine(dataDir, "postgresql.conf");
        var lines = File.ReadAllLines(confPath).ToList();
        lines.RemoveAll(l => l.TrimStart().StartsWith("port", StringComparison.OrdinalIgnoreCase) && l.Contains('='));
        lines.Add($"port = {port}");
        File.WriteAllLines(confPath, lines);
    }

    /// <summary>initdb's default pg_hba.conf already restricts to local connections; we still pin it explicitly rather than relying on defaults that may change across versions.</summary>
    private static void RestrictToLocalhost(string dataDir)
    {
        var hbaPath = Path.Combine(dataDir, "pg_hba.conf");
        var content =
            "host all all 127.0.0.1/32 scram-sha-256\n" +
            "host all all ::1/128 scram-sha-256\n";
        File.WriteAllText(hbaPath, content);
    }

    /// <summary>
    /// <c>sc start</c> returns as soon as SCM accepts the request. Postgres then still
    /// recovers WAL / starts accepting clients — the same window Docker waits out with
    /// <c>pg_isready</c>. The old Inno flow never hit this because it used an already-running
    /// system server.
    /// </summary>
    private static async Task WaitUntilAcceptingConnectionsAsync(
        string binDir,
        IProgress<string>? progress,
        CancellationToken cancellationToken)
    {
        var pgIsReady = Path.Combine(binDir, "bin", "pg_isready.exe");
        var port = PostgresBinariesConfig.DefaultPort.ToString();
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(90);
        var attempt = 0;

        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (File.Exists(pgIsReady))
            {
                var ready = await HiddenProcessRunner.RunAsync(
                    pgIsReady,
                    new[] { "-h", "127.0.0.1", "-p", port },
                    cancellationToken: cancellationToken).ConfigureAwait(false);
                if (ready.ExitCode == 0)
                {
                    return;
                }
            }

            if (DateTime.UtcNow >= deadline)
            {
                throw new InvalidOperationException(
                    "PostgreSQL started as a Windows service but did not accept connections within 90 seconds.");
            }

            attempt++;
            progress?.Report($"Waiting for PostgreSQL to accept connections ({attempt})...");
            await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken).ConfigureAwait(false);
        }
    }
}
