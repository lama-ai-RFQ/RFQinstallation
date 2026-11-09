using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Reflection;
using System.Runtime.Versioning;
using System.Text;
using Microsoft.Win32;
using RfqInstaller.Core.Config;
using RfqInstaller.Core.Database;
using RfqInstaller.Core.Licensing;
using RfqInstaller.Core.Models;
using RfqInstaller.Core.Orchestration;
using RfqInstaller.Core.Security;
using RfqInstaller.Core.Services;

namespace RfqInstaller.Core.Diagnostics;

public sealed record DiagnosticsInput(
    string? InstallPath,
    string? SignedInUserName = null,
    string? InstallerLogPath = null,
    string? LastError = null);

/// <summary>
/// One report with everything support needs to see why an install or its services don't work,
/// so a customer pastes one block instead of running a dozen commands. It never contains a
/// password, the license key or any other secret: .env values are only shown for settings known
/// to be harmless, and any stored password that turns up anyway (in a log, say) is blanked out.
/// </summary>
[SupportedOSPlatform("windows")]
public static class InstallDiagnostics
{
    private static readonly string[] ServiceNames = { "RFQapplication", "RFQUpdaterService", PostgresProvisioner.ServiceName };

    /// <summary>.env settings whose values are safe to show.</summary>
    private static readonly string[] ShownSettings =
    {
        "RFQ_LICENSE_BROKER_URL", "SERVER_URL", "PORT", "DB_PORT", "RFQ_UPDATE_CHANNEL", "RFQ_UPDATER_SOURCE",
        "RFQ_RUNTIME_ASSET_MODE", "WINDOWS", "LOCAL_DATABASE", "CONTAINER", "MODEL_PATH",
    };

    private static readonly int[] WatchedPorts = { 443, 8000, 8502, 8503, PostgresBinariesConfig.DefaultPort };

    public static async Task<string> CollectAsync(DiagnosticsInput input, CancellationToken cancellationToken = default)
    {
        var report = new StringBuilder();
        var secrets = new List<string>();

        Section(report, "Setup");
        Line(report, "Collected", $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} local ({DateTime.UtcNow:yyyy-MM-dd HH:mm:ss} UTC)");
        Line(report, "Installer version", Assembly.GetEntryAssembly()?.GetName().Version?.ToString() ?? "unknown");
        Line(report, "Windows", $"{Environment.OSVersion} ({(Environment.Is64BitOperatingSystem ? "64-bit" : "32-bit")})");
        Line(report, "Computer", Environment.MachineName);
        Try(report, "Setup runs as", () =>
            AccountIdentity.CurrentName() + (Elevation.ElevationHelper.IsElevated() ? " (administrator)" : " (not elevated)"));
        Try(report, "Signed in to Windows", () => input.SignedInUserName ?? SignedInUser.Detect().Name);
        if (input.InstallerLogPath is not null)
        {
            Line(report, "Installer log", input.InstallerLogPath);
        }

        var installPath = input.InstallPath;
        Dictionary<string, string> env = new(StringComparer.Ordinal);
        if (!string.IsNullOrWhiteSpace(installPath))
        {
            Section(report, "Install folder");
            Line(report, "Path", installPath);
            Line(report, "Exists", Directory.Exists(installPath) ? "yes" : "no");
            if (Directory.Exists(installPath))
            {
                Line(report, "Version", ExistingInstallDetector.ReadInstalledVersion(installPath) ?? "unknown");
                foreach (var (label, relative) in new[]
                         {
                             (".env", ".env"), ("App", "RFQ_Application.exe"), ("Updater", "windows_updater.exe"),
                             ("PostgreSQL engine", @"pgsql\bin\postgres.exe"), ("Database (pgdata)", @"pgdata\PG_VERSION"),
                         })
                {
                    Line(report, label, File.Exists(Path.Combine(installPath, relative)) ? "present" : "missing");
                }

                Access(report, "Install folder access", installPath);
                var pgdata = Path.Combine(installPath, "pgdata");
                if (Directory.Exists(pgdata))
                {
                    Access(report, "pgdata access", pgdata);
                }

                env = EnvFileReader.Read(installPath);
                Settings(report, env, secrets);
                StoredPasswords(report, installPath, secrets);
            }
        }

        var brokerUrl = env.TryGetValue("RFQ_LICENSE_BROKER_URL", out var configured) && configured.Length > 0
            ? configured
            : InstallPlan.DefaultBrokerUrl;
        await BrokerAsync(report, brokerUrl, cancellationToken).ConfigureAwait(false);

        var licenseState = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "RFQ", "license-client.dat");
        Line(report, "Device activation state",
            File.Exists(licenseState) ? $"saved, last changed {File.GetLastWriteTime(licenseState):yyyy-MM-dd HH:mm:ss}" : "none on this computer");

        await ServicesAsync(report, cancellationToken).ConfigureAwait(false);
        Ports(report);

        if (!string.IsNullOrWhiteSpace(installPath))
        {
            var logs = Path.Combine(installPath, "logs");
            Tail(report, Path.Combine(logs, "RFQapplication_stderr.log"), 40);
            Tail(report, Path.Combine(logs, "RFQUpdaterService_stderr.log"), 15);
            Tail(report, Path.Combine(logs, "updater.log"), 15);
        }
        if (input.InstallerLogPath is not null)
        {
            Tail(report, input.InstallerLogPath, 60);
        }

        if (!string.IsNullOrWhiteSpace(input.LastError))
        {
            Section(report, "Last error");
            report.AppendLine(input.LastError.Trim());
        }

        return Redact(report.ToString(), secrets);
    }

    /// <summary>Saves the report next to the installer log and returns its path.</summary>
    public static string Save(string report, string directory)
    {
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, $"diagnostics-{DateTime.Now:yyyyMMdd-HHmmss}.txt");
        File.WriteAllText(path, report, Encoding.UTF8);
        return path;
    }

    internal static string Redact(string text, IEnumerable<string> secrets)
    {
        foreach (var secret in secrets.Where(s => s.Length >= 4).Distinct().OrderByDescending(s => s.Length))
        {
            text = text.Replace(secret, "[redacted]", StringComparison.Ordinal);
        }

        return text;
    }

    /// <summary>How a .env setting is shown: its value only when it's on the harmless list.</summary>
    internal static string DescribeSetting(string key, string value)
    {
        if (ShownSettings.Contains(key, StringComparer.Ordinal))
        {
            return value.Length > 0 ? value : "(empty)";
        }

        if (value == CredentialManagerWriter.Sentinel)
        {
            return "set (in Windows Credential Manager)";
        }

        return value.Length == 0 || value.StartsWith("your_", StringComparison.OrdinalIgnoreCase)
            ? "not set"
            : "set";
    }

    private static void Settings(StringBuilder report, Dictionary<string, string> env, List<string> secrets)
    {
        Section(report, "Settings (.env)");
        foreach (var (key, value) in env.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            if (!ShownSettings.Contains(key, StringComparer.Ordinal) && value.Length > 0 && value != CredentialManagerWriter.Sentinel)
            {
                secrets.Add(value);
            }

            if (key == "LICENSE_KEY" && value.Length > 0)
            {
                var license = LocalLicenseValidator.Validate(value);
                Line(report, key, license.SignatureValid
                    ? $"set, customer {license.CustomerId}, expires {license.ExpirationDate:yyyy-MM-dd}{(license.Expired ? " (expired)" : "")}"
                    : $"set, but not valid: {license.Message}");
                continue;
            }

            Line(report, key, DescribeSetting(key, value));
        }
    }

    private static void StoredPasswords(StringBuilder report, string installPath, List<string> secrets)
    {
        Section(report, "Stored passwords (values never shown)");
        try
        {
            foreach (var credential in StoredCredentialsResolver.ResolveAll(installPath))
            {
                if (credential.Value is not null)
                {
                    secrets.Add(credential.Value);
                }
                Line(report, credential.DisplayName, credential.Value is null
                    ? $"not readable ({credential.Source})"
                    : $"readable, from {credential.Source}");
            }
        }
        catch (Exception ex)
        {
            Line(report, "Error", ex.Message);
        }
    }

    private static async Task BrokerAsync(StringBuilder report, string brokerUrl, CancellationToken cancellationToken)
    {
        Section(report, "License broker");
        Line(report, "URL", brokerUrl);
        if (!Uri.TryCreate(brokerUrl, UriKind.Absolute, out var uri))
        {
            Line(report, "Reachable", "no: not a valid URL");
            return;
        }

        try
        {
            using var client = new TcpClient();
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(8));
            await client.ConnectAsync(uri.Host, uri.Port, timeout.Token).ConfigureAwait(false);
            Line(report, "Reachable", $"yes ({uri.Host}:{uri.Port})");
        }
        catch (Exception ex) when (ex is SocketException or OperationCanceledException && !cancellationToken.IsCancellationRequested)
        {
            Line(report, "Reachable", $"no ({uri.Host}:{uri.Port}): {(ex is OperationCanceledException ? "timed out" : ex.Message)}");
        }
    }

    private static async Task ServicesAsync(StringBuilder report, CancellationToken cancellationToken)
    {
        Section(report, "Windows services");
        var control = new ServiceControl();
        var events = new List<string>();
        foreach (var name in ServiceNames)
        {
            try
            {
                var status = await control.QueryAsync(name, cancellationToken).ConfigureAwait(false);
                if (status.State == ServiceState.NotInstalled)
                {
                    Line(report, name, "not installed");
                    continue;
                }

                var details = ReadService(name);
                Line(report, name,
                    $"{status.State}" +
                    (status.Win32ExitCode is { } win32 && win32 != 0 ? $", Windows exit code {win32}" : "") +
                    (status.ServiceExitCode is { } service && service != 0 ? $", service exit code {service}" : "") +
                    $", runs as {details.Account ?? "LocalSystem"}");
                if (details.Command is not null)
                {
                    Line(report, "  command", details.Command);
                }
                if (details.AppDirectory is not null)
                {
                    Line(report, "  folder", details.AppDirectory);
                }

                events.AddRange(await control.RecentEventsAsync(name, details.DisplayName, cancellationToken).ConfigureAwait(false));
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                Line(report, name, $"could not query: {ex.Message}");
            }
        }

        if (events.Count > 0)
        {
            Section(report, "Service events in the last hour (newest first)");
            foreach (var entry in events.Distinct().OrderByDescending(e => e, StringComparer.Ordinal).Take(15))
            {
                report.AppendLine(entry);
            }
        }
    }

    private static (string? Account, string? Command, string? AppDirectory, string? DisplayName) ReadService(string name)
    {
        try
        {
            using var key = Registry.LocalMachine.OpenSubKey($@"SYSTEM\CurrentControlSet\Services\{name}");
            using var parameters = key?.OpenSubKey("Parameters");
            var command = parameters?.GetValue("Application") as string is { } application
                ? $"{application} {parameters.GetValue("AppParameters") as string}".Trim()
                : key?.GetValue("ImagePath", null, RegistryValueOptions.DoNotExpandEnvironmentNames) as string;
            return (key?.GetValue("ObjectName") as string, command, parameters?.GetValue("AppDirectory") as string,
                key?.GetValue("DisplayName") as string);
        }
        catch (Exception ex) when (ex is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            return (null, null, null, null);
        }
    }

    private static void Ports(StringBuilder report)
    {
        Section(report, "Ports in use");
        try
        {
            var listening = IPGlobalProperties.GetIPGlobalProperties().GetActiveTcpListeners().Select(e => e.Port).ToHashSet();
            foreach (var port in WatchedPorts)
            {
                Line(report, port.ToString(), listening.Contains(port) ? "something is listening" : "free");
            }
        }
        catch (NetworkInformationException ex)
        {
            Line(report, "Error", ex.Message);
        }
    }

    private static void Access(StringBuilder report, string label, string path)
    {
        try
        {
            var rules = FolderAccess.Describe(path);
            Line(report, label, rules[0]);
            foreach (var rule in rules.Skip(1).Take(14))
            {
                report.AppendLine("    " + rule);
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            Line(report, label, $"could not read: {ex.Message}");
        }
    }

    private static void Tail(StringBuilder report, string path, int lines)
    {
        var tail = ServiceControl.TailLines(path, lines);
        if (tail.Count == 0)
        {
            return;
        }

        Section(report, $"Last {tail.Count} lines of {path}");
        foreach (var line in tail)
        {
            report.AppendLine(line);
        }
    }

    private static void Section(StringBuilder report, string title)
    {
        report.AppendLine();
        report.AppendLine($"== {title} ==");
    }

    private static void Line(StringBuilder report, string label, string value) => report.AppendLine($"{label}: {value}");

    private static void Try(StringBuilder report, string label, Func<string> value)
    {
        try
        {
            Line(report, label, value());
        }
        catch (Exception ex)
        {
            Line(report, label, $"unknown ({ex.Message})");
        }
    }
}
