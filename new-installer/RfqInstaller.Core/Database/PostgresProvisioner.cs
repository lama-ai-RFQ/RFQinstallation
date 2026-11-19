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

        await EnsureBinariesAsync(installPath, progress, cancellationToken, binaries).ConfigureAwait(false);
        var pgCtl = Path.Combine(binDir, "bin", "pg_ctl.exe");
        var initDb = Path.Combine(binDir, "bin", "initdb.exe");

        // initdb and the service read these files after dropping administrator rights (see
        // FolderAccess), so the accounts themselves need read access wherever the install lives.
        FolderAccess.Grant(binDir, FileSystemRights.ReadAndExecute, new[] { AccountIdentity.CurrentSid(), AccountIdentity.LocalSystem });

        await EnsurePostgresCanStartAsync(binDir, progress, cancellationToken).ConfigureAwait(false);

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

    internal async Task EnsureBinariesAsync(string installPath, IProgress<string>? progress,
        CancellationToken cancellationToken, SignedArtifact? binaries)
    {
        var binDir = Path.Combine(installPath, "pgsql");
        if (File.Exists(Path.Combine(binDir, "bin", "postgres.exe"))) return;

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

    // Authenticate against this exact cluster. Restore a stopped database to its original
    // state even when authentication fails, and never reconfigure a service to perform a probe.
    internal async Task VerifyExistingPasswordAsync(string installPath, string password, CancellationToken token)
    {
        var dataDir = Path.GetFullPath(Path.Combine(installPath, "pgdata"));
        var engine = Path.Combine(installPath, "pgsql");
        var pgCtl = Path.Combine(engine, "bin", "pg_ctl.exe");
        await EnsurePostgresCanStartAsync(engine, null, token).ConfigureAwait(false);
        var status = await HiddenProcessRunner.RunAsync(pgCtl, ["status", "-D", dataDir], cancellationToken: token)
            .ConfigureAwait(false);
        if (status.ExitCode == 0)
        {
            await VerifyRunningClusterAsync(dataDir, password, token).ConfigureAwait(false);
            return;
        }
        if (status.ExitCode != 3)
            throw new InvalidOperationException($"Could not inspect the existing database in {dataDir}: {status.StdErr.Trim()}");

        var control = new ServiceControl { SettlePolls = 1 };
        if (PointsAt(ReadServiceImagePath(), pgCtl, dataDir))
        {
            var state = (await control.QueryAsync(ServiceName, token).ConfigureAwait(false)).State;
            if (state != ServiceState.Stopped)
                throw new InvalidOperationException($"The database service is {state}. Wait for it to settle and retry.");
            try
            {
                await control.StartAndWaitAsync(ServiceName, token).ConfigureAwait(false);
                await VerifyRunningClusterAsync(dataDir, password, token).ConfigureAwait(false);
            }
            finally
            {
                await control.StopIfExistsAsync(ServiceName, CancellationToken.None).ConfigureAwait(false);
            }
            return;
        }

        // A retained cluster may have no service. Start pg_ctl on a temporary loopback port
        // without replacing another installation's service or registering a new one.
        int port;
        using (var listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0))
        {
            listener.Start();
            port = ((System.Net.IPEndPoint)listener.LocalEndpoint).Port;
        }
        var log = Path.Combine(dataDir, $"setup-check-{Guid.NewGuid():N}.log");
        token.ThrowIfCancellationRequested();
        try
        {
            // Let pg_ctl finish startup before acting on cancellation so the server can always be stopped.
            var started = await HiddenProcessRunner.RunAsync(pgCtl, ["start", "-D", dataDir, "-w", "-t", "60",
                "-l", log, "-o", $"-h 127.0.0.1 -p {port}"]).ConfigureAwait(false);
            if (started.ExitCode != 0)
                throw new InvalidOperationException($"Could not open the retained database for its password check: {started.StdErr.Trim()}");
            await VerifyRunningClusterAsync(dataDir, password, token, port).ConfigureAwait(false);
        }
        finally
        {
            // The port distinguishes this probe from a concurrently started external server.
            var pid = Path.Combine(dataDir, "postmaster.pid");
            if (File.Exists(pid) && File.ReadLines(pid).ElementAtOrDefault(3) == port.ToString())
            {
                var stopped = await HiddenProcessRunner.RunAsync(pgCtl, ["stop", "-D", dataDir, "-m", "fast", "-w"])
                    .ConfigureAwait(false);
                if (stopped.ExitCode != 0)
                    throw new InvalidOperationException($"Could not stop the password-check database: {stopped.StdErr.Trim()}");
            }
            File.Delete(log);
        }
    }

    private static async Task VerifyRunningClusterAsync(string dataDir, string password, CancellationToken token,
        int? expectedPort = null)
    {
        var pidFile = await File.ReadAllLinesAsync(Path.Combine(dataDir, "postmaster.pid"), token).ConfigureAwait(false);
        if (pidFile.Length < 4 || !SamePath(pidFile[1], dataDir) || !int.TryParse(pidFile[3], out var port)
            || port is < 1 or > 65535 || (expectedPort.HasValue && port != expectedPort))
            throw new InvalidOperationException($"Could not identify the running PostgreSQL cluster in {dataDir}.");

        await DatabaseSetup.VerifySuperUserAsync(port, password, dataDir, token).ConfigureAwait(false);
    }

    private async Task EnsurePostgresCanStartAsync(
        string engineDirectory, IProgress<string>? progress, CancellationToken token)
    {
        const int missingDll = unchecked((int)0xC0000135);
        var postgres = Path.Combine(engineDirectory, "bin", "postgres.exe");
        var probe = await HiddenProcessRunner.RunAsync(postgres, ["--version"], cancellationToken: token).ConfigureAwait(false);
        if (probe.ExitCode == missingDll)
        {
            // A fresh Windows installation does not include the x64 MSVC runtime used by EDB.
            // Use Microsoft's immutable download, pinned to the same hash as its official release.
            const string sha256 = "9c02c9ed120f671b900e6b9471d890e3b2414117a7e53f4ae2e855466fa2b7c9";
            const string url = "https://download.visualstudio.microsoft.com/download/pr/78d061c5-9ef3-42ab-98ed-3309d1095dc4/"
                + "9C02C9ED120F671B900E6B9471D890E3B2414117A7E53F4AE2E855466FA2B7C9/VC_redist.x64.exe";
            progress?.Report("Installing the Microsoft Visual C++ x64 runtime required by PostgreSQL...");
            var directory = Directory.CreateTempSubdirectory("rfq-vcredist-");
            try
            {
                FolderAccess.CreatePrivateDirectory(directory.FullName, [AccountIdentity.Administrators, AccountIdentity.LocalSystem]);
                var path = Path.Combine(directory.FullName, "VC_redist.x64.exe");
                await _downloader.DownloadAsync(url, path, 18863624, null, token, expectedSha256: sha256).ConfigureAwait(false);
                var install = await HiddenProcessRunner.RunAsync(path, ["/install", "/quiet", "/norestart"], cancellationToken: token)
                    .ConfigureAwait(false);
                // 1638 means a newer runtime is already present. 3010 requests a restart.
                if (install.ExitCode is not (0 or 1638 or 3010))
                    throw new InvalidOperationException($"Microsoft Visual C++ x64 runtime setup failed (exit {install.ExitCode}).");
                probe = await HiddenProcessRunner.RunAsync(postgres, ["--version"], cancellationToken: token).ConfigureAwait(false);
                if (probe.ExitCode != 0 && install.ExitCode == 3010)
                    throw new InvalidOperationException("Restart Windows to finish installing the Microsoft Visual C++ x64 runtime, then retry setup.");
            }
            finally
            {
                try { directory.Delete(recursive: true); } catch (IOException) { }
            }
        }
        if (probe.ExitCode != 0)
            throw new InvalidOperationException($"PostgreSQL could not start (Windows exit 0x{probe.ExitCode:X8}). {probe.StdErr.Trim()}");
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
                throw new InvalidOperationException($"initdb failed (exit 0x{result.ExitCode:X8}): {result.StdErr.Trim()}");
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
