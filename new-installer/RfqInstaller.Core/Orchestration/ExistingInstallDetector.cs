using System.Runtime.Versioning;
using System.Text.Json;
using Microsoft.Win32;
using RfqInstaller.Core.Database;
using RfqInstaller.Core.Models;

namespace RfqInstaller.Core.Orchestration;

/// <summary>An RFQ Application install already on this machine, as found by <see cref="ExistingInstallDetector"/>.</summary>
public record ExistingInstallation(
    string InstallPath,
    InstallMode Mode,
    string? ServiceAccountName,
    string? InstalledVersion);

/// <summary>
/// Finds an existing install so the wizard can offer Repair. An install folder is any candidate
/// folder holding an .env file. Candidates are checked in order: the RFQapplication service's NSSM
/// AppDirectory, the folder the RFQPostgreSQL service runs from, the Add/Remove Programs entry, and
/// the wizard's default path. That way an install on another drive (e.g. D:\Program Files) is
/// still found, even though the current installer never writes the uninstall entry. Read-only.
/// </summary>
[SupportedOSPlatform("windows")]
public static class ExistingInstallDetector
{
    public const string DefaultInstallPath = @"C:\Program Files\RFQ Application";

    private const string ServicesKey = @"SYSTEM\CurrentControlSet\Services\";
    private const string AppServiceName = "RFQapplication";
    private const string UninstallKey = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\RFQApplication";

    public static ExistingInstallation? Detect()
    {
        var appServiceDirectory = ReadLocalMachineValue(ServicesKey + AppServiceName + @"\Parameters", "AppDirectory");
        var serviceAccount = ReadLocalMachineValue(ServicesKey + AppServiceName, "ObjectName");
        var postgresImagePath = ReadLocalMachineValue(ServicesKey + PostgresProvisioner.ServiceName, "ImagePath");
        var uninstallLocation = ReadLocalMachineValue(UninstallKey, "InstallLocation");

        return Select(
            new[]
            {
                appServiceDirectory,
                InstallDirFromPostgresImagePath(postgresImagePath),
                uninstallLocation,
                DefaultInstallPath,
            },
            appServiceDirectory,
            serviceAccount);
    }

    internal static ExistingInstallation? Select(
        IEnumerable<string?> candidates,
        string? appServiceDirectory,
        string? serviceAccount)
    {
        foreach (var candidate in candidates)
        {
            if (string.IsNullOrWhiteSpace(candidate))
            {
                continue;
            }

            var installPath = Normalize(candidate);
            if (!File.Exists(Path.Combine(installPath, ".env")))
            {
                continue;
            }

            var isService = !string.IsNullOrWhiteSpace(appServiceDirectory) &&
                            string.Equals(installPath, Normalize(appServiceDirectory), StringComparison.OrdinalIgnoreCase);
            return new ExistingInstallation(
                installPath,
                isService ? InstallMode.WindowsService : InstallMode.Standalone,
                isService ? serviceAccount : null,
                ReadInstalledVersion(installPath));
        }

        return null;
    }

    /// <summary>
    /// pg_ctl registers the service as <c>"{install}\pgsql\bin\pg_ctl.exe" runservice -N ... -D ...</c>;
    /// the install folder is three levels above pg_ctl.exe.
    /// </summary>
    internal static string? InstallDirFromPostgresImagePath(string? imagePath)
    {
        if (string.IsNullOrWhiteSpace(imagePath))
        {
            return null;
        }

        var trimmed = imagePath.Trim();
        string exePath;
        if (trimmed.StartsWith('"'))
        {
            var closingQuote = trimmed.IndexOf('"', 1);
            if (closingQuote < 0)
            {
                return null;
            }

            exePath = trimmed[1..closingQuote];
        }
        else
        {
            var exeEnd = trimmed.IndexOf(".exe", StringComparison.OrdinalIgnoreCase);
            if (exeEnd < 0)
            {
                return null;
            }

            exePath = trimmed[..(exeEnd + ".exe".Length)];
        }

        if (!string.Equals(Path.GetFileName(exePath), "pg_ctl.exe", StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        var binDir = Path.GetDirectoryName(exePath);
        var pgsqlDir = binDir is null ? null : Path.GetDirectoryName(binDir);
        return pgsqlDir is null ? null : Path.GetDirectoryName(pgsqlDir);
    }

    internal static string? ReadInstalledVersion(string installPath)
    {
        try
        {
            var manifestPath = Path.Combine(installPath, "local_manifest.json");
            if (File.Exists(manifestPath))
            {
                using var document = JsonDocument.Parse(File.ReadAllText(manifestPath));
                if (document.RootElement.ValueKind == JsonValueKind.Object &&
                    document.RootElement.TryGetProperty("version", out var version) &&
                    version.ValueKind == JsonValueKind.String &&
                    !string.IsNullOrWhiteSpace(version.GetString()))
                {
                    return version.GetString()!.Trim();
                }
            }

            var versionFile = Path.Combine(installPath, "version.txt");
            if (File.Exists(versionFile))
            {
                var text = File.ReadAllText(versionFile).Trim();
                return text.Length > 0 ? text : null;
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException)
        {
            // The version is only shown for information; a damaged manifest is one reason to repair.
        }

        return null;
    }

    private static string Normalize(string path) =>
        Path.GetFullPath(path.Trim().Trim('"')).TrimEnd('\\', '/');

    private static string? ReadLocalMachineValue(string keyPath, string valueName)
    {
        try
        {
            using var key = Registry.LocalMachine.OpenSubKey(keyPath);
            return key?.GetValue(valueName) as string;
        }
        catch (Exception ex) when (ex is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            return null;
        }
    }
}
