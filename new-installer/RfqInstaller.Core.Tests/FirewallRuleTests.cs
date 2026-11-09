using RfqInstaller.Core.Networking;
using RfqInstaller.Core.Orchestration;
using RfqInstaller.Core.Processes;
using Xunit;

namespace RfqInstaller.Core.Tests;

public class FirewallRuleTests
{
    [Fact]
    public void AddRuleOpensOnlyTheAppPortOnDomainAndPrivateNetworks()
    {
        var args = FirewallRule.AddArguments(FirewallRule.AppRuleName, 8000);

        Assert.Equal(new[] { "advfirewall", "firewall", "add", "rule" }, args.Take(4));
        Assert.Contains("name=RFQ-Application-HTTPS", args);
        Assert.Contains("dir=in", args);
        Assert.Contains("action=allow", args);
        Assert.Contains("protocol=TCP", args);
        Assert.Contains("localport=8000", args);
        Assert.Contains("profile=domain,private", args);
        Assert.DoesNotContain(args, a => a.Contains("public", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void NoArgumentContainsSpacesOrQuotes()
    {
        // netsh re-parses its command line; values with spaces would be split.
        var all = FirewallRule.AddArguments(FirewallRule.AppRuleName, 443)
            .Concat(FirewallRule.DeleteArguments(FirewallRule.AppRuleName))
            .Concat(FirewallRule.ShowArguments(FirewallRule.AppRuleName));
        Assert.All(all, a => Assert.False(a.Any(c => char.IsWhiteSpace(c) || c == '"'), a));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(65536)]
    [InlineData(-1)]
    public void RejectsInvalidPorts(int port)
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => FirewallRule.AddArguments(FirewallRule.AppRuleName, port));
    }

    [Theory]
    [InlineData("")]
    [InlineData("ORYX Inspect")]
    [InlineData("bad\"name")]
    public void RejectsNamesNetshWouldSplit(string name)
    {
        Assert.Throws<ArgumentException>(() => FirewallRule.DeleteArguments(name));
    }

    [Fact]
    public void ExistenceComesFromTheExitCodeNotTheTranslatedText()
    {
        Assert.True(FirewallRule.ShowOutputMeansExists(new ProcessResult(0, "Regelname: RFQ-Application-HTTPS", "")));
        Assert.False(FirewallRule.ShowOutputMeansExists(new ProcessResult(1, "No rules match the specified criteria.", "")));
    }

    [Fact]
    public void WarningTellsTheUserWhatToOpen()
    {
        var warning = InstallOrchestrator.FirewallWarning(8443, "access denied");
        Assert.Contains("8443", warning);
        Assert.Contains("access denied", warning);
    }

    [Fact]
    public void AppPortComesFromTheInstallsEnvFile()
    {
        var dir = Directory.CreateTempSubdirectory("rfq-port-").FullName;
        try
        {
            Assert.Equal(InstallOrchestrator.DefaultAppPort, InstallOrchestrator.AppPort(dir));
            File.WriteAllText(Path.Combine(dir, ".env"), "SERVER_URL=https://localhost\nPORT=8443\n");
            Assert.Equal(8443, InstallOrchestrator.AppPort(dir));
            File.WriteAllText(Path.Combine(dir, ".env"), "PORT=not-a-port\n");
            Assert.Equal(InstallOrchestrator.DefaultAppPort, InstallOrchestrator.AppPort(dir));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public void BrowserAddressIncludesTheAppPort()
    {
        var dir = Directory.CreateTempSubdirectory("rfq-address-").FullName;
        try
        {
            Assert.Equal("https://office-pc:8000", InstallOrchestrator.BrowserAddress("https://office-pc", dir));
            File.WriteAllText(Path.Combine(dir, ".env"), "PORT=8443\n");
            Assert.Equal("https://office-pc:8443", InstallOrchestrator.BrowserAddress("https://office-pc/", dir));
            // A SERVER_URL that names its own port wins.
            Assert.Equal("https://rfq.example.com:9000", InstallOrchestrator.BrowserAddress("https://rfq.example.com:9000", dir));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }
}
