using YamlDotNet.Serialization;

namespace RfqInstaller.Core.Config;

/// <summary>
/// Merges the license block into backend/main/user_config.yaml, matching the exact schema
/// RFQautomation's LicenseValidator already reads/writes (license_key, customer_id, last_validated,
/// validation_status, features, limits) — preserving every other top-level section (email,
/// project, user_groups, ...) untouched on a reinstall/upgrade.
/// </summary>
public static class UserConfigWriter
{
    public static void WriteLicense(
        string installPath,
        string licenseKey,
        string? customerId,
        IReadOnlyDictionary<string, bool> features,
        IReadOnlyDictionary<string, int> limits)
    {
        var configPath = Path.Combine(installPath, "backend", "main", "user_config.yaml");
        var deserializer = new DeserializerBuilder().Build();
        var serializer = new SerializerBuilder().Build();

        Dictionary<object, object> root;
        if (File.Exists(configPath))
        {
            var existing = deserializer.Deserialize<Dictionary<object, object>>(File.ReadAllText(configPath));
            root = existing ?? new Dictionary<object, object>();
        }
        else
        {
            root = new Dictionary<object, object>();
        }

        root["license"] = new Dictionary<object, object>
        {
            ["license_key"] = licenseKey,
            ["customer_id"] = customerId ?? string.Empty,
            ["last_validated"] = DateTime.UtcNow.ToString("o"),
            ["validation_status"] = "valid",
            ["features"] = features.ToDictionary(f => (object)f.Key, f => (object)f.Value),
            ["limits"] = limits.ToDictionary(l => (object)l.Key, l => (object)l.Value),
        };

        Directory.CreateDirectory(Path.GetDirectoryName(configPath)!);
        File.WriteAllText(configPath, serializer.Serialize(root));
    }
}
