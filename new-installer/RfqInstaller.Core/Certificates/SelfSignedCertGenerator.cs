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
    public static void GenerateIfMissing(string installPath, string? serverUrl = null)
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
        foreach (var name in HostNames(serverUrl))
        {
            sanBuilder.AddDnsName(name);
        }
        sanBuilder.AddIpAddress(System.Net.IPAddress.Loopback);
        if (ServerUrlHost(serverUrl) is { } host && System.Net.IPAddress.TryParse(host, out var address)
            && !System.Net.IPAddress.IsLoopback(address))
        {
            sanBuilder.AddIpAddress(address);
        }
        request.CertificateExtensions.Add(sanBuilder.Build());

        using var certificate = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(365));

        var certPem = PemEncode("CERTIFICATE", certificate.RawData);
        var keyPem = PemEncode("PRIVATE KEY", rsa.ExportPkcs8PrivateKey());

        Directory.CreateDirectory(installPath);
        File.WriteAllText(certPath, certPem);
        File.WriteAllText(keyPath, keyPem);
    }

    /// <summary>
    /// localhost, this computer's name (with its domain when joined to one) and the server URL's
    /// host, so browsers on other computers that open the server by name accept the certificate
    /// once it is trusted (Team plan teammates, Enterprise users).
    /// </summary>
    public static IReadOnlyList<string> HostNames(string? serverUrl)
    {
        var names = new List<string> { "localhost" };
        void Add(string? name)
        {
            if (!string.IsNullOrWhiteSpace(name) && Uri.CheckHostName(name) == UriHostNameType.Dns
                && !names.Contains(name, StringComparer.OrdinalIgnoreCase))
            {
                names.Add(name.ToLowerInvariant());
            }
        }

        var machine = System.Net.Dns.GetHostName();
        Add(machine);
        var domain = System.Net.NetworkInformation.IPGlobalProperties.GetIPGlobalProperties().DomainName;
        if (!string.IsNullOrWhiteSpace(domain))
        {
            Add($"{machine}.{domain}");
        }
        Add(ServerUrlHost(serverUrl));
        return names;
    }

    private static string? ServerUrlHost(string? serverUrl) =>
        Uri.TryCreate(serverUrl, UriKind.Absolute, out var uri) ? uri.Host : null;

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
