using System.Reflection;
using System.Text;

namespace RfqInstaller.Core.Config;

/// <summary>
/// Writes/updates the app's .env file. Starts from the existing .env on a reinstall/upgrade
/// (preserving anything not explicitly managed here) or from the bundled env.template on a fresh
/// install, then upserts only the keys the installer is responsible for.
/// </summary>
public static class EnvFileWriter
{
    public static void Upsert(string installPath, IReadOnlyDictionary<string, string> values)
    {
        var envPath = Path.Combine(installPath, ".env");
        var lines = File.Exists(envPath)
            ? File.ReadAllLines(envPath).ToList()
            : LoadTemplateLines();

        var remaining = new Dictionary<string, string>(values, StringComparer.Ordinal);

        for (var i = 0; i < lines.Count; i++)
        {
            var line = lines[i];
            var trimmed = line.TrimStart();
            if (trimmed.StartsWith('#') || !trimmed.Contains('='))
            {
                continue;
            }

            var key = trimmed[..trimmed.IndexOf('=')].Trim();
            if (remaining.TryGetValue(key, out var newValue))
            {
                lines[i] = $"{key}={newValue}";
                remaining.Remove(key);
            }
        }

        if (remaining.Count > 0)
        {
            lines.Add("");
            lines.Add("# Added by installer");
            foreach (var (key, value) in remaining)
            {
                lines.Add($"{key}={value}");
            }
        }

        Directory.CreateDirectory(installPath);
        File.WriteAllLines(envPath, lines, Encoding.UTF8);
    }

    private static List<string> LoadTemplateLines()
    {
        var assembly = Assembly.GetExecutingAssembly();
        const string resourceName = "RfqInstaller.Core.Resources.env.template";
        using var stream = assembly.GetManifestResourceStream(resourceName)
            ?? throw new InvalidOperationException($"Embedded resource '{resourceName}' not found.");
        using var reader = new StreamReader(stream, Encoding.UTF8);
        var text = reader.ReadToEnd();
        return text.Replace("\r\n", "\n").Split('\n').ToList();
    }
}
