using RfqInstaller.Core.Config;
using RfqInstaller.Core.Database;
using RfqInstaller.Core.Licensing;
using RfqInstaller.Core.Models;
using RfqInstaller.Core.Security;

namespace RfqInstaller.Core.Orchestration;

/// <summary>What an existing install needs to provide before it can be repaired.</summary>
public record RepairReadiness(
    string? LicenseKey,
    LocalLicenseCheck? License,
    string UpdateChannel,
    string BrokerUrl,
    bool HasBundledDatabase,
    string? SuperUserPassword,
    string? AppUserPassword,
    IReadOnlyList<string> Problems)
{
    public bool CanRepair => Problems.Count == 0;
}

/// <summary>
/// Read-only checks that run before a repair changes anything. Repair never writes .env or
/// Credential Manager, so everything it needs must already be recoverable from them: the license
/// key always, and the postgres superuser and rfq_user passwords only when
/// <paramref name="checkDatabase"/> is set and the install has its own private Postgres in pgdata.
/// Without the database check, repair only restarts that Postgres as it is, which needs no
/// password. Installs without pgdata (the legacy installer used a system-wide Postgres) never need
/// database credentials, because repair leaves that database alone.
/// </summary>
public static class RepairPreflight
{
    private const string DefaultUpdateChannel = "customer";

    public static RepairReadiness Check(string installPath, bool checkDatabase)
    {
        var problems = new List<string>();
        var env = EnvFileReader.Read(installPath);

        if (!File.Exists(Path.Combine(installPath, ".env")))
        {
            problems.Add($"No existing installation was found in {installPath} (its .env file is missing). Run Setup and choose Install instead.");
        }

        string? licenseKey = null;
        LocalLicenseCheck? license = null;
        if (env.TryGetValue("LICENSE_KEY", out var rawLicense) && IsRealValue(rawLicense))
        {
            licenseKey = rawLicense;
            license = LocalLicenseValidator.Validate(rawLicense);
            if (!license.SignatureValid || license.Expired)
            {
                problems.Add($"The license key in .env can't be used: {license.Message} Run Setup and choose Install to enter a new license key.");
            }
        }
        else if (problems.Count == 0)
        {
            problems.Add("The .env file has no license key. Run Setup and choose Install to enter one.");
        }

        var updateChannel = env.TryGetValue("RFQ_UPDATE_CHANNEL", out var channel) && IsRealValue(channel)
            ? channel
            : DefaultUpdateChannel;
        var brokerUrl = env.TryGetValue("RFQ_LICENSE_BROKER_URL", out var broker) && IsRealValue(broker)
            ? broker
            : InstallPlan.DefaultBrokerUrl;

        var hasBundledDatabase = PostgresProvisioner.IsAlreadyInitialized(installPath);
        string? superUserPassword = null;
        string? appUserPassword = null;
        if (hasBundledDatabase && checkDatabase)
        {
            var credentials = StoredCredentialsResolver.ResolveAll(installPath);
            superUserPassword = RequireCredential(credentials, env, "SQL_SUPER_USER", problems);
            appUserPassword = RequireCredential(credentials, env, "RFQ_USER_PASSWORD", problems);
        }

        return new RepairReadiness(
            licenseKey,
            license,
            updateChannel,
            brokerUrl,
            hasBundledDatabase,
            superUserPassword,
            appUserPassword,
            problems);
    }

    private static string? RequireCredential(
        IEnumerable<StoredCredential> credentials,
        IReadOnlyDictionary<string, string> env,
        string envKey,
        List<string> problems)
    {
        var credential = credentials.First(c => c.EnvKey == envKey);
        if (credential.Value is not null)
        {
            return credential.Value;
        }

        var storedInCredentialManager = env.TryGetValue(envKey, out var raw) && raw == CredentialManagerWriter.Sentinel;
        problems.Add(storedInCredentialManager
            ? $"The {credential.DisplayName} password is stored in Windows Credential Manager but couldn't be read. " +
              "Run Setup from a normal desktop session, signed in as the Windows user who originally installed RFQ Application."
            : $"The {credential.DisplayName} password isn't set in .env, so the existing database can't be reconnected.");
        return null;
    }

    private static bool IsRealValue(string? value) =>
        !string.IsNullOrWhiteSpace(value) && !value.StartsWith("your_", StringComparison.OrdinalIgnoreCase);
}
