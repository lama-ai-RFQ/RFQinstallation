namespace RfqInstaller.Core.Config;

/// <summary>Reads KEY=value pairs from an install folder's .env file. Read-only; never writes anything.</summary>
public static class EnvFileReader
{
    public static Dictionary<string, string> Read(string installPath)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var envPath = Path.Combine(installPath, ".env");
        if (!File.Exists(envPath))
        {
            return result;
        }

        foreach (var line in File.ReadAllLines(envPath))
        {
            if (AssignmentKey(line) is { } key)
                result[key] = line[(line.IndexOf('=') + 1)..].Trim();
        }

        return result;
    }
    // python-dotenv also accepts exported assignments and single-quoted keys.
    internal static string? AssignmentKey(string line)
    {
        int separator = line.IndexOf('=');
        if (separator < 0) return null;
        var key = line[..separator].Trim();
        if (key.StartsWith('#')) return null;
        if (key.Length > 6 && key.StartsWith("export", StringComparison.Ordinal) && char.IsWhiteSpace(key[6]))
            key = key[7..].TrimStart();
        if (key.Length >= 2 && key[0] == '\'' && key[^1] == '\'')
            key = key[1..^1];
        return key.Length == 0 ? null : key;
    }
}
