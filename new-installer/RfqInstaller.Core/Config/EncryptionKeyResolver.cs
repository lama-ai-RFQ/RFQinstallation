namespace RfqInstaller.Core.Config;

/// <summary>
/// Same resolution rules as setup.iss (INFA-130): a usable key is a non-empty, non-placeholder
/// value; RFQ_CONFIG_ENCRYPTION_KEY is tried first, then AZURE_CONFIG_ENCRYPTION_KEY. Used so a
/// reinstall reuses the key already on disk instead of generating a new one over an existing DB.
/// </summary>
public static class EncryptionKeyResolver
{
    public const string RfqKeyName = "RFQ_CONFIG_ENCRYPTION_KEY";
    public const string AzureKeyName = "AZURE_CONFIG_ENCRYPTION_KEY";

    private const string AppPlaceholder = "your_app_encryption_key_here";
    private const string AzurePlaceholder = "your_azure_encryption_key_here";

    public static bool IsUsable(string? value)
    {
        var trimmed = value?.Trim() ?? string.Empty;
        if (trimmed.Length == 0)
        {
            return false;
        }

        return !trimmed.Equals(AppPlaceholder, StringComparison.OrdinalIgnoreCase)
            && !trimmed.Equals(AzurePlaceholder, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>Returns the existing key from {installPath}\.env, or null if this looks like a first install.</summary>
    public static string? ResolveFromInstallPath(string installPath)
    {
        var envPath = Path.Combine(installPath, ".env");
        if (!File.Exists(envPath))
        {
            return null;
        }

        var values = ReadEnvValues(envPath);
        if (values.TryGetValue(RfqKeyName, out var rfq) && IsUsable(rfq))
        {
            return rfq.Trim();
        }

        if (values.TryGetValue(AzureKeyName, out var azure) && IsUsable(azure))
        {
            return azure.Trim();
        }

        return null;
    }

    private static Dictionary<string, string> ReadEnvValues(string envPath)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
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
