using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace RfqInstaller.Core.Security;

/// <summary>
/// Persists generated secrets (DB/settings passwords) as DPAPI LocalMachine-scope protected blobs
/// in a JSON file next to the app (secrets.dat). Only used when the service account is Network
/// Service or Local System — the recommended/default Current User account uses Windows Credential
/// Manager instead (see CredentialManagerWriter), since it can actually read that back at runtime.
/// LocalMachine scope (not CurrentUser-scope DPAPI) is used here because Network Service/Local
/// System have no loaded user profile to unlock a CurrentUser-scope secret. RFQautomation's config
/// loader resolves the `__CREDENTIAL_MANAGER__` sentinel in `.env` by trying this file first, then
/// falling back to Credential Manager (see backend/main config loader patch) — so this file must
/// only exist when it's actually the intended store, or it would shadow a real Credential Manager
/// entry.
/// </summary>
[SupportedOSPlatform("windows")]
public class SecretStore
{
    public const string Sentinel = "__CREDENTIAL_MANAGER__";
    private const int FormatVersion = 1;

    private readonly Dictionary<string, string> _plaintextByName = new();

    public void Set(string name, string plaintextValue) => _plaintextByName[name] = plaintextValue;

    public void Save(string path)
    {
        var secrets = _plaintextByName.ToDictionary(
            kv => kv.Key,
            kv => Convert.ToBase64String(Protect(kv.Value)));

        var doc = new SecretsFile { Version = FormatVersion, Secrets = secrets };
        var json = JsonSerializer.Serialize(doc, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(path, json, Encoding.UTF8);
    }

    private static byte[] Protect(string plaintext) =>
        ProtectedData.Protect(Encoding.UTF8.GetBytes(plaintext), optionalEntropy: null, DataProtectionScope.LocalMachine);

    private class SecretsFile
    {
        public int Version { get; set; }
        public Dictionary<string, string> Secrets { get; set; } = new();
    }
}
