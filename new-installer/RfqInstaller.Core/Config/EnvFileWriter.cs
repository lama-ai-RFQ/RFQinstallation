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
    private static readonly HashSet<string> RetiredDistributionKeys = new(StringComparer.OrdinalIgnoreCase)
    {
        "AWS_KEY",
        "AWS_SECRET",
        "GITHUB_PAT",
        "GITHUB_USERNAME",
        "S3_RELEASE_BUCKET",
        "S3_RELEASE_REGION",
        "CLOUDFRONT_KEY_PAIR_ID",
        "CLOUDFRONT_PRIVATE_KEY",
        "CLOUDFRONT_PRIVATE_KEY_PATH",
    };

    public static void Upsert(string installPath, IReadOnlyDictionary<string, string> values)
    {
        var envPath = Path.Combine(installPath, ".env");
        var lines = File.Exists(envPath)
            ? File.ReadAllLines(envPath).ToList()
            : LoadTemplateLines();
        var managed = values.ToDictionary(pair => pair.Key, StringComparer.OrdinalIgnoreCase);
        var written = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var output = new List<string>(lines.Count);
        foreach (var line in lines)
        {
            var key = EnvFileReader.AssignmentKey(line);
            if (key is null || !managed.TryGetValue(key, out var entry))
            {
                if (key is null || !RetiredDistributionKeys.Contains(key))
                    output.Add(line);
                continue;
            }

            if (written.Add(key))
                output.Add($"{entry.Key}={entry.Value}");
        }

        if (written.Count < managed.Count)
        {
            output.Add("");
            output.Add("# Added by installer");
            foreach (var (key, value) in values)
                if (!written.Contains(key))
                    output.Add($"{key}={value}");
        }

        Directory.CreateDirectory(installPath);
        // python-dotenv treats a UTF-8 BOM as part of the first key.
        File.WriteAllLines(envPath, output);
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
