using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace RfqInstaller.Core.Certificates;

/// <summary>
/// Generates the localhost self-signed TLS cert/key pair the app serves HTTPS with, using pure
/// .NET X509 APIs — no OpenSSL install required. Written to the exact file names/location
/// RFQautomation's backend/main/generate_ssl_certs.py already checks for and skips regenerating
/// (cert.pem/key.pem next to the app executable), so no OpenSSL dependency exists at first run.
/// </summary>
public static class SelfSignedCertGenerator
{
    public static void GenerateIfMissing(string installPath)
    {
        var certPath = Path.Combine(installPath, "cert.pem");
        var keyPath = Path.Combine(installPath, "key.pem");

        if (File.Exists(certPath) && File.Exists(keyPath))
        {
            return;
        }

        using var rsa = RSA.Create(2048);

        var request = new CertificateRequest(
            "C=US, ST=State, L=City, O=Development, CN=localhost",
            rsa,
            HashAlgorithmName.SHA256,
            RSASignaturePadding.Pkcs1);

        request.CertificateExtensions.Add(
            new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment, critical: true));
        request.CertificateExtensions.Add(
            new X509EnhancedKeyUsageExtension(new OidCollection { new Oid("1.3.6.1.5.5.7.3.1") }, critical: false)); // serverAuth

        var sanBuilder = new SubjectAlternativeNameBuilder();
        sanBuilder.AddDnsName("localhost");
        sanBuilder.AddIpAddress(System.Net.IPAddress.Loopback);
        request.CertificateExtensions.Add(sanBuilder.Build());

        using var certificate = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(365));

        var certPem = PemEncode("CERTIFICATE", certificate.RawData);
        var keyPem = PemEncode("PRIVATE KEY", rsa.ExportPkcs8PrivateKey());

        Directory.CreateDirectory(installPath);
        File.WriteAllText(certPath, certPem);
        File.WriteAllText(keyPath, keyPem);
    }

    private static string PemEncode(string label, byte[] der)
    {
        var base64 = Convert.ToBase64String(der);
        var lines = new List<string> { $"-----BEGIN {label}-----" };
        for (var i = 0; i < base64.Length; i += 64)
        {
            lines.Add(base64.Substring(i, Math.Min(64, base64.Length - i)));
        }
        lines.Add($"-----END {label}-----");
        return string.Join("\n", lines) + "\n";
    }
}
