namespace RfqInstaller.Core.Config;

/// <summary>Reads KEY=value pairs from an install folder's .env file. Read-only; never writes anything.</summary>
public static class EnvFileReader
{
    public static Dictionary<string, string> Read(string installPath)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        var envPath = Path.Combine(installPath, ".env");
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
