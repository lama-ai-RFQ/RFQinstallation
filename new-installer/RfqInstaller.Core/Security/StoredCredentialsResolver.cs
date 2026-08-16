namespace RfqInstaller.Core.Security;

public record StoredCredential(string DisplayName, string EnvKey, string? Value, string Source);

/// <summary>
/// Resolves the current value of each installer-managed secret regardless of which store actually
/// holds it, for a single "view stored credentials" experience: Credential Manager if that's what
/// was chosen (and the service account can actually use it), or the plaintext value already sitting
/// in `.env` otherwise (the customer's explicit, accepted alternative). Read-only; never writes
/// anything.
/// </summary>
public static class StoredCredentialsResolver
{
    private static readonly (string DisplayName, string EnvKey, string CredentialManagerTarget)[] Entries =
    {
        ("PostgreSQL superuser (postgres)", "SQL_SUPER_USER", "RFQApplication_SQL_SUPER_USER"),
        ("RFQ database user (rfq_user)", "RFQ_USER_PASSWORD", "RFQApplication_RFQ_USER_PASSWORD"),
        ("Settings page password", "SETTINGS_PASSWORD", "RFQApplication_SETTINGS_PASSWORD"),
    };

    public static List<StoredCredential> ResolveAll(string installPath)
    {
        var envValues = ReadEnvValues(Path.Combine(installPath, ".env"));

        var results = new List<StoredCredential>();
        foreach (var (displayName, envKey, credentialManagerTarget) in Entries)
        {
            envValues.TryGetValue(envKey, out var rawValue);

            if (rawValue != CredentialManagerWriter.Sentinel)
            {
                results.Add(string.IsNullOrEmpty(rawValue)
                    ? new StoredCredential(displayName, envKey, null, "not set")
                    : new StoredCredential(displayName, envKey, rawValue, ".env file"));
                continue;
            }

            var fromCredentialManager = CredentialManagerReader.TryRead(credentialManagerTarget);
            results.Add(fromCredentialManager is not null
                ? new StoredCredential(displayName, envKey, fromCredentialManager, "Windows Credential Manager")
                : new StoredCredential(displayName, envKey, null, "could not be resolved"));
        }

        return results;
    }

    private static Dictionary<string, string> ReadEnvValues(string envPath)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        if (!File.Exists(envPath))
        {
            return result;
        }

        foreach (var line in File.ReadAllLines(envPath))
        {
            var trimmed = line.TrimStart();
            if (trimmed.StartsWith('#') || !trimmed.Contains('='))
            {
                continue;
            }

            var separatorIndex = trimmed.IndexOf('=');
            var key = trimmed[..separatorIndex].Trim();
            var value = trimmed[(separatorIndex + 1)..].Trim();
            result[key] = value;
        }

        return result;
    }
}
