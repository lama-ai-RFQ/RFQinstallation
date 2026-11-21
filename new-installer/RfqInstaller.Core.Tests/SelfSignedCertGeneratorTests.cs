using System.Security.Cryptography.X509Certificates;
using RfqInstaller.Core.Certificates;
using Xunit;

namespace RfqInstaller.Core.Tests;

public sealed class SelfSignedCertGeneratorTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "rfq-cert-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true);
    }

    [Theory]
    [InlineData("PSD-")]
    [InlineData("bad-.example.test")]
    public void CertificateSkipsHostNamesThatCannotBeEncodedAsDnsNames(string host)
    {
        // Uri accepts these names, but the certificate builder's IDN conversion rejects them.
        Assert.Equal(UriHostNameType.Dns, Uri.CheckHostName(host));

        SelfSignedCertGenerator.GenerateIfMissing(_root, $"https://{host}");

        using var certificate = X509Certificate2.CreateFromPemFile(
            Path.Combine(_root, "cert.pem"), Path.Combine(_root, "key.pem"));
        var san = certificate.Extensions.OfType<X509SubjectAlternativeNameExtension>().Single();
        Assert.True(certificate.HasPrivateKey);
        Assert.Contains("localhost", san.EnumerateDnsNames());
        Assert.DoesNotContain(host.ToLowerInvariant(), san.EnumerateDnsNames());
        Assert.Contains(System.Net.IPAddress.Loopback, san.EnumerateIPAddresses());
    }

    [Fact]
    public void CertificateRetainsInternationalServerNames()
    {
        SelfSignedCertGenerator.GenerateIfMissing(_root, "https://bücher.example.test");

        using var certificate = X509Certificate2.CreateFromPem(File.ReadAllText(Path.Combine(_root, "cert.pem")));
        var san = certificate.Extensions.OfType<X509SubjectAlternativeNameExtension>().Single();
        Assert.Contains("xn--bcher-kva.example.test", san.EnumerateDnsNames());
    }
}
