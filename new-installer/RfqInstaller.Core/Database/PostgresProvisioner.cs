using RfqInstaller.Core.Archive;
using RfqInstaller.Core.Networking;
using RfqInstaller.Core.Processes;

namespace RfqInstaller.Core.Database;

public record PostgresInstance(string BinDir, string DataDir, int Port, string ServiceName, string SuperUserPassword);

/// <summary>
/// Provisions a private, app-owned PostgreSQL instance under the install directory — no system-wide
/// install, no PATH dependency, no interactive EDB installer. Binaries come from a portable "zip"
/// distribution (see PostgresBinariesConfig); the instance runs on its own dedicated port and its
/// own Windows service so it can never collide with a PostgreSQL the customer already has installed
/// for something else. Safe to re-run: skips steps whose result already exists on disk.
/// </summary>
public class PostgresProvisioner
{
    public const string ServiceName = "RFQPostgreSQL";

    private readonly HttpDownloader _downloader;

    public PostgresProvisioner(HttpDownloader? downloader = null)
    {
        _downloader = downloader ?? new HttpDownloader();
    }

    public async Task<PostgresInstance> ProvisionAsync(
        string installPath,
        string generatedSuperUserPassword,
        IProgress<string>? progress,
        CancellationToken cancellationToken)
    {
        var binDir = Path.Combine(installPath, "pgsql");
        var dataDir = Path.Combine(installPath, "pgdata");

        if (!File.Exists(Path.Combine(binDir, "bin", "postgres.exe")))
        {
            progress?.Report("Downloading PostgreSQL engine...");
            var zipPath = Path.Combine(Path.GetTempPath(), $"rfq-postgres-{PostgresBinariesConfig.Version}.zip");
            await _downloader.DownloadAsync(PostgresBinariesConfig.DownloadUrl, zipPath, expectedSizeBytes: null, progress: null, cancellationToken)
                .ConfigureAwait(false);

            progress?.Report("Extracting PostgreSQL engine...");
            ZipExtractor.Extract(zipPath, binDir, progress: null, cancellationToken);
        }

        var pgCtl = Path.Combine(binDir, "bin", "pg_ctl.exe");
        var initDb = Path.Combine(binDir, "bin", "initdb.exe");

        var alreadyInitialized = File.Exists(Path.Combine(dataDir, "PG_VERSION"));
        if (!alreadyInitialized)
        {
            progress?.Report("Initializing database cluster...");
            await InitializeDataDirectoryAsync(initDb, dataDir, generatedSuperUserPassword, cancellationToken).ConfigureAwait(false);
            SetPort(dataDir, PostgresBinariesConfig.DefaultPort);
            RestrictToLocalhost(dataDir);
        }

        var serviceAlreadyRegistered = await IsServiceRegisteredAsync(cancellationToken).ConfigureAwait(false);
        if (!serviceAlreadyRegistered)
        {
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

        progress?.Report("Starting PostgreSQL service...");
        await HiddenProcessRunner.RunAsync("sc.exe", new[] { "start", ServiceName }, cancellationToken: cancellationToken)
            .ConfigureAwait(false); // ignore exit code: "already running" is not an error here

        return new PostgresInstance(binDir, dataDir, PostgresBinariesConfig.DefaultPort, ServiceName, generatedSuperUserPassword);
    }

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

    private static async Task<bool> IsServiceRegisteredAsync(CancellationToken cancellationToken)
    {
        var result = await HiddenProcessRunner.RunAsync("sc.exe", new[] { "query", ServiceName }, cancellationToken: cancellationToken)
            .ConfigureAwait(false);
        return result.ExitCode == 0;
    }
}
