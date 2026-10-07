using System.Text.Json;
using RfqInstaller.Core.Desktop;
using RfqInstaller.Core.Models;
using Xunit;

namespace RfqInstaller.Core.Tests;

public sealed class DesktopAppSetupTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "rfq-desktop-" + Guid.NewGuid().ToString("N"));

    public DesktopAppSetupTests() => Directory.CreateDirectory(_root);

    public void Dispose() => Directory.Delete(_root, recursive: true);

    [Theory]
    [InlineData("https://localhost", null, "https://localhost:8000/")]
    [InlineData("https://localhost/", "9000", "https://localhost:9000/")]
    [InlineData("https://rfq.acme.local:8443", null, "https://rfq.acme.local:8443/")]
    [InlineData("http://localhost", null, "http://localhost:8000/")]
    public void AppUrlAddsTheAppPortUnlessTheServerUrlNamesOne(string serverUrl, string? port, string expected)
    {
        Assert.Equal(expected, DesktopAppSetup.AppUrl(serverUrl, port));
    }

    [Fact]
    public void StandaloneConfigLetsTheAppStartTheServer()
    {
        var configPath = Path.Combine(_root, "Scint", "desktop.json");

        DesktopAppSetup.WriteConfig(configPath, @"C:\Program Files\RFQ Application", InstallMode.Standalone, "https://localhost");

        var config = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(configPath))!;
        Assert.Equal("https://localhost:8000/", config["server_url"]);
        Assert.Equal("standalone", config["mode"]);
        Assert.Equal(@"C:\Program Files\RFQ Application\RFQ_Application.exe", config["backend_exe"]);
        Assert.Equal(@"C:\Program Files\RFQ Application\cert.pem", config["certificate_file"]);
    }

    [Fact]
    public void ServiceConfigOnlyPointsAtTheServer()
    {
        var configPath = Path.Combine(_root, "desktop.json");

        DesktopAppSetup.WriteConfig(configPath, @"D:\Scint", InstallMode.WindowsService, "https://rfq.acme.local", "8000");

        var config = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(configPath))!;
        Assert.Equal("https://rfq.acme.local:8000/", config["server_url"]);
        Assert.Equal("service", config["mode"]);
        Assert.False(config.ContainsKey("backend_exe"));
    }

    [Fact]
    public void ReleasesWithoutScintExeKeepTheBrowser()
    {
        var configPath = Path.Combine(_root, "desktop.json");

        var result = DesktopAppSetup.Configure(_root, InstallMode.Standalone, "RFQ.not.signed", createShortcut: false, configPath);

        Assert.Null(result);
        Assert.False(File.Exists(configPath));
    }

    [Fact]
    public void KeysWithoutAValidSignatureKeepTheBrowser()
    {
        // Only a signed Individual/Team key (with a Stripe subscription) switches to the app.
        File.WriteAllText(Path.Combine(_root, DesktopAppSetup.ExecutableName), "");
        var configPath = Path.Combine(_root, "desktop.json");

        var result = DesktopAppSetup.Configure(_root, InstallMode.Standalone, "RFQ.not.signed", createShortcut: false, configPath);

        Assert.Null(result);
        Assert.False(File.Exists(configPath));
    }

    [Fact]
    public void RemoveDeletesTheShortcutAndTheMachineConfig()
    {
        var configPath = Path.Combine(_root, "desktop.json");
        var shortcutPath = Path.Combine(_root, DesktopAppSetup.ShortcutName);
        DesktopAppSetup.WriteConfig(configPath, _root, InstallMode.WindowsService, "https://localhost");
        File.WriteAllText(shortcutPath, "");

        DesktopAppSetup.Remove(configPath, shortcutPath);

        Assert.False(File.Exists(configPath));
        Assert.False(File.Exists(shortcutPath));
    }
}
