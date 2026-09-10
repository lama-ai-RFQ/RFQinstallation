using System.IO.Compression;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using RfqInstaller.Core.Models;

namespace RfqInstaller.Core.Licensing;

/// <summary>
/// Offline signature/format/expiration check, mirroring RFQautomation's backend/main/license_validator.py
/// exactly (same key format, same compact JSON payload, same feature/limit short-code maps, same 7-day
/// grace period) so the wizard can give instant feedback without a network round trip. This is a
/// convenience pre-check only — the license-broker call is the source of truth for entitlements and
/// install-time config, since the payload itself never carries download credentials.
/// </summary>
public static class LocalLicenseValidator
{
    private const int GracePeriodDays = 7;

    private static readonly Dictionary<string, string> FeatureCodeToName = new()
    {
        ["a"] = "ai_extraction",
        ["p"] = "price_prediction",
        ["e"] = "email_automation",
        ["aa"] = "advanced_analytics",
        ["mu"] = "multi_user",
        ["ai"] = "api_integrations",
    };

    private static readonly Dictionary<string, string> LimitCodeToName = new()
    {
        ["mp"] = "max_projects",
        ["ms"] = "max_suppliers",
        ["mq"] = "max_quotations_per_month",
        ["mu"] = "max_users",
    };

    public static LocalLicenseCheck Validate(string licenseKey)
    {
        if (string.IsNullOrWhiteSpace(licenseKey))
        {
            return new LocalLicenseCheck { SignatureValid = false, Message = "License key is empty." };
        }

        var key = licenseKey.Trim();
        if (!key.StartsWith("RFQ.", StringComparison.Ordinal) && !key.StartsWith("RFQ-", StringComparison.Ordinal))
        {
            return new LocalLicenseCheck { SignatureValid = false, Message = "License key must start with 'RFQ.'." };
        }

        var separator = key[3];
        var parts = key.Split(separator);
        if (parts.Length != 3)
        {
            return new LocalLicenseCheck { SignatureValid = false, Message = "License key format is invalid (expected 3 segments)." };
        }

        byte[] payloadCompressed;
        byte[] signature;
        try
        {
            payloadCompressed = Base64UrlDecode(parts[1]);
            signature = Base64UrlDecode(parts[2]);
        }
        catch (FormatException)
        {
            return new LocalLicenseCheck { SignatureValid = false, Message = "License key is not validly encoded." };
        }

        using var rsa = RSA.Create();
        rsa.ImportFromPem(Encoding.ASCII.GetString(LoadEmbeddedPublicKey()));

        var signatureValid = rsa.VerifyData(payloadCompressed, signature, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        if (!signatureValid)
        {
            return new LocalLicenseCheck { SignatureValid = false, Message = "License key signature is invalid." };
        }

        JsonElement payload;
        try
        {
            var json = ZlibInflate(payloadCompressed);
            payload = JsonSerializer.Deserialize<JsonElement>(json);
        }
        catch (Exception ex) when (ex is InvalidDataException or JsonException)
        {
            return new LocalLicenseCheck { SignatureValid = false, Message = "License key payload could not be decoded." };
        }

        var customerId = payload.TryGetProperty("c", out var cEl) ? cEl.GetString() : null;
        DateOnly? expiration = null;
        if (payload.TryGetProperty("e", out var eEl) && DateOnly.TryParse(eEl.GetString(), out var parsedExpiration))
        {
            expiration = parsedExpiration;
        }

        var expired = expiration.HasValue &&
                      expiration.Value.ToDateTime(TimeOnly.MinValue) < DateTime.UtcNow.Date.AddDays(-GracePeriodDays);

        var features = new Dictionary<string, bool>();
        if (payload.TryGetProperty("f", out var fEl) && fEl.ValueKind == JsonValueKind.Object)
        {
            foreach (var prop in fEl.EnumerateObject())
            {
                if (FeatureCodeToName.TryGetValue(prop.Name, out var name))
                {
                    features[name] = prop.Value.ValueKind == JsonValueKind.Number
                        ? prop.Value.GetInt32() != 0
                        : prop.Value.GetBoolean();
                }
            }
        }

        var limits = new Dictionary<string, int>();
        if (payload.TryGetProperty("l", out var lEl) && lEl.ValueKind == JsonValueKind.Object)
        {
            foreach (var prop in lEl.EnumerateObject())
            {
                if (LimitCodeToName.TryGetValue(prop.Name, out var name))
                {
                    limits[name] = prop.Value.GetInt32();
                }
            }
        }

        return new LocalLicenseCheck
        {
            SignatureValid = true,
            Expired = expired,
            CustomerId = customerId,
            ExpirationDate = expiration,
            Message = expired ? "License key has expired." : "License key is valid.",
            Features = features,
            Limits = limits,
        };
    }

    private static byte[] LoadEmbeddedPublicKey()
    {
        var assembly = Assembly.GetExecutingAssembly();
        const string resourceName = "RfqInstaller.Core.Resources.license_public_key.pem";
        using var stream = assembly.GetManifestResourceStream(resourceName)
            ?? throw new InvalidOperationException($"Embedded resource '{resourceName}' not found.");
        using var reader = new MemoryStream();
        stream.CopyTo(reader);
        return reader.ToArray();
    }

    private static byte[] Base64UrlDecode(string input)
    {
        var s = input.Replace('-', '+').Replace('_', '/');
        switch (s.Length % 4)
        {
            case 2: s += "=="; break;
            case 3: s += "="; break;
        }
        return Convert.FromBase64String(s);
    }

    /// <summary>Inflates RFC1950 zlib-wrapped data, matching Python's zlib.decompress().</summary>
    private static byte[] ZlibInflate(byte[] zlibData)
    {
        using var input = new MemoryStream(zlibData);
        using var zlib = new ZLibStream(input, CompressionMode.Decompress);
        using var output = new MemoryStream();
        zlib.CopyTo(output);
        return output.ToArray();
    }
}
