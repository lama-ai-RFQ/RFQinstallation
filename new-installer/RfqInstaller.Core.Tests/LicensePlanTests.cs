using System.Security.Cryptography.X509Certificates;
using RfqInstaller.Core.Certificates;
using RfqInstaller.Core.Models;
using Xunit;

namespace RfqInstaller.Core.Tests;

public sealed class LicensePlanTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "rfq-plan-" + Guid.NewGuid().ToString("N"));

    public LicensePlanTests() => Directory.CreateDirectory(_root);

    public void Dispose() => Directory.Delete(_root, recursive: true);

    private static LocalLicenseCheck Check(string? subscriptionId, int? maxUsers) => new()
    {
        SignatureValid = true,
        SubscriptionId = subscriptionId,
        Limits = maxUsers is { } users ? new Dictionary<string, int> { ["max_users"] = users } : new(),
    };

    [Theory]
    [InlineData("sub_1", 1, true, false)]
    [InlineData("sub_1", 3, false, true)]
    [InlineData(null, 1, false, false)]
    [InlineData(null, 1000, false, false)]
    public void PlanComesFromTheSubscriptionAndUserLimit(string? subscriptionId, int maxUsers, bool individual, bool team)
    {
        var check = Check(subscriptionId, maxUsers);

        Assert.Equal(individual, check.IndividualPlan);
        Assert.Equal(team, check.TeamPlan);
    }

    [Fact]
    public void CertificateCoversThisComputerAndTheServerUrlHost()
    {
        SelfSignedCertGenerator.GenerateIfMissing(_root, "https://office-pc.example.test");

        using var certificate = X509Certificate2.CreateFromPem(File.ReadAllText(Path.Combine(_root, "cert.pem")));
        var san = certificate.Extensions.OfType<X509SubjectAlternativeNameExtension>().Single();
        var names = san.EnumerateDnsNames().ToList();
        Assert.Contains("localhost", names);
        Assert.Contains(System.Net.Dns.GetHostName().ToLowerInvariant(), names);
        Assert.Contains("office-pc.example.test", names);
    }
}
