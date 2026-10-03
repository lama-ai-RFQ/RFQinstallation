using RfqInstaller.Core.Models;
using RfqInstaller.Core.Orchestration;
using Xunit;

namespace RfqInstaller.Core.Tests;

public sealed class ExistingInstallDetectorTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "rfq-detect-" + Guid.NewGuid().ToString("N"));

    public ExistingInstallDetectorTests() => Directory.CreateDirectory(_root);

    public void Dispose() => Directory.Delete(_root, recursive: true);

    [Fact]
    public void InstallDirFromQuotedPostgresImagePath()
    {
        var installDir = ExistingInstallDetector.InstallDirFromPostgresImagePath(
            "\"D:\\Program Files\\RFQ Application\\pgsql\\bin\\pg_ctl.exe\" runservice -N \"RFQPostgreSQL\" -D \"D:\\Program Files\\RFQ Application\\pgdata\" -w");

        Assert.Equal(@"D:\Program Files\RFQ Application", installDir);
    }

    [Fact]
    public void InstallDirFromUnquotedPostgresImagePath()
    {
        var installDir = ExistingInstallDetector.InstallDirFromPostgresImagePath(
            @"C:\RFQ\pgsql\bin\pg_ctl.exe runservice -N RFQPostgreSQL -D C:\RFQ\pgdata");

        Assert.Equal(@"C:\RFQ", installDir);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("\"C:\\Program Files\\PostgreSQL\\16\\bin\\postgres.exe\" -D data")]
    [InlineData("\"C:\\unterminated")]
    public void InstallDirFromPostgresImagePathIgnoresOtherServices(string? imagePath)
    {
        Assert.Null(ExistingInstallDetector.InstallDirFromPostgresImagePath(imagePath));
    }

    [Fact]
    public void SelectSkipsCandidatesWithoutEnvFile()
    {
        var empty = CreateDir("empty");
        var installed = CreateInstall("installed");

        var found = ExistingInstallDetector.Select(new[] { null, empty, installed }, appServiceDirectory: null, serviceAccount: null);

        Assert.NotNull(found);
        Assert.Equal(installed, found.InstallPath);
        Assert.Equal(InstallMode.Standalone, found.Mode);
        Assert.Null(found.ServiceAccountName);
    }

    [Fact]
    public void SelectReportsServiceModeWhenAppServiceRunsFromThatFolder()
    {
        var installed = CreateInstall("svc");

        var found = ExistingInstallDetector.Select(
            new[] { installed },
            appServiceDirectory: installed.ToUpperInvariant() + "\\",
            serviceAccount: @".\admin");

        Assert.NotNull(found);
        Assert.Equal(InstallMode.WindowsService, found.Mode);
        Assert.Equal(@".\admin", found.ServiceAccountName);
    }

    [Fact]
    public void SelectReturnsNullWhenNothingIsInstalled()
    {
        Assert.Null(ExistingInstallDetector.Select(new[] { CreateDir("nothing") }, null, null));
    }

    [Fact]
    public void ReadsVersionFromManifestThenVersionTxt()
    {
        var withManifest = CreateInstall("manifest");
        File.WriteAllText(Path.Combine(withManifest, "local_manifest.json"), "{\"version\": \"3.8.969\"}");
        File.WriteAllText(Path.Combine(withManifest, "version.txt"), "1.0.0");
        var withVersionTxt = CreateInstall("versiontxt");
        File.WriteAllText(Path.Combine(withVersionTxt, "version.txt"), "3.8.900\n");
        var withBrokenManifest = CreateInstall("broken");
        File.WriteAllText(Path.Combine(withBrokenManifest, "local_manifest.json"), "{not json");

        Assert.Equal("3.8.969", ExistingInstallDetector.ReadInstalledVersion(withManifest));
        Assert.Equal("3.8.900", ExistingInstallDetector.ReadInstalledVersion(withVersionTxt));
        Assert.Null(ExistingInstallDetector.ReadInstalledVersion(withBrokenManifest));
    }

    private string CreateDir(string name)
    {
        var path = Path.Combine(_root, name);
        Directory.CreateDirectory(path);
        return path;
    }

    private string CreateInstall(string name)
    {
        var path = CreateDir(name);
        File.WriteAllText(Path.Combine(path, ".env"), "LICENSE_KEY=x\n");
        return path;
    }
}

public sealed class RepairPreflightTests : IDisposable
{
    private readonly string _installPath = Path.Combine(Path.GetTempPath(), "rfq-repair-" + Guid.NewGuid().ToString("N"));

    public RepairPreflightTests() => Directory.CreateDirectory(_installPath);

    public void Dispose() => Directory.Delete(_installPath, recursive: true);

    [Fact]
    public void MissingEnvFileBlocksRepair()
    {
        var readiness = RepairPreflight.Check(_installPath, checkDatabase: false);

        Assert.False(readiness.CanRepair);
        Assert.Contains(readiness.Problems, p => p.Contains(".env file is missing"));
        Assert.Single(readiness.Problems);
    }

    [Fact]
    public void ReadsDatabasePasswordsChannelAndBrokerFromEnv()
    {
        WriteEnv(
            "LICENSE_KEY=RFQ.not.valid",
            "SQL_SUPER_USER=super-secret",
            "RFQ_USER_PASSWORD=app-secret",
            "RFQ_UPDATE_CHANNEL=beta",
            "RFQ_LICENSE_BROKER_URL=https://broker.example");
        CreatePgData();

        var readiness = RepairPreflight.Check(_installPath, checkDatabase: true);

        Assert.True(readiness.HasBundledDatabase);
        Assert.Equal("super-secret", readiness.SuperUserPassword);
        Assert.Equal("app-secret", readiness.AppUserPassword);
        Assert.Equal("beta", readiness.UpdateChannel);
        Assert.Equal("https://broker.example", readiness.BrokerUrl);
        Assert.Equal("RFQ.not.valid", readiness.LicenseKey);
        // The only problem is the unsigned test license; the credentials resolved fine.
        var problem = Assert.Single(readiness.Problems);
        Assert.Contains("license key", problem);
    }

    [Fact]
    public void PlaceholderDatabasePasswordBlocksDatabaseCheck()
    {
        WriteEnv(
            "LICENSE_KEY=RFQ.not.valid",
            "SQL_SUPER_USER=your_postgres_password_here",
            "RFQ_USER_PASSWORD=app-secret");
        CreatePgData();

        var readiness = RepairPreflight.Check(_installPath, checkDatabase: true);

        Assert.Null(readiness.SuperUserPassword);
        Assert.Contains(readiness.Problems, p => p.Contains("PostgreSQL superuser") && p.Contains("isn't set in .env"));
    }

    [Fact]
    public void FileOnlyRepairNeedsNoDatabasePasswords()
    {
        WriteEnv(
            "LICENSE_KEY=RFQ.not.valid",
            "SQL_SUPER_USER=__CREDENTIAL_MANAGER__",
            "RFQ_USER_PASSWORD=your_password_here");
        CreatePgData();

        var readiness = RepairPreflight.Check(_installPath, checkDatabase: false);

        Assert.True(readiness.HasBundledDatabase);
        Assert.Null(readiness.SuperUserPassword);
        Assert.Null(readiness.AppUserPassword);
        Assert.DoesNotContain(readiness.Problems, p => p.Contains("password"));
    }

    [Fact]
    public void InstallWithoutPgDataNeedsNoDatabaseCredentials()
    {
        WriteEnv("LICENSE_KEY=RFQ.not.valid");

        var readiness = RepairPreflight.Check(_installPath, checkDatabase: true);

        Assert.False(readiness.HasBundledDatabase);
        Assert.Null(readiness.SuperUserPassword);
        Assert.Equal("customer", readiness.UpdateChannel);
        Assert.Equal(InstallPlan.DefaultBrokerUrl, readiness.BrokerUrl);
        Assert.DoesNotContain(readiness.Problems, p => p.Contains("password"));
    }

    [Fact]
    public void MissingLicenseKeyBlocksRepair()
    {
        WriteEnv("LICENSE_KEY=your_license_key_here");

        var readiness = RepairPreflight.Check(_installPath, checkDatabase: false);

        Assert.Null(readiness.LicenseKey);
        Assert.Contains(readiness.Problems, p => p.Contains("no license key"));
    }

    private void WriteEnv(params string[] lines) =>
        File.WriteAllLines(Path.Combine(_installPath, ".env"), lines);

    private void CreatePgData()
    {
        var pgData = Path.Combine(_installPath, "pgdata");
        Directory.CreateDirectory(pgData);
        File.WriteAllText(Path.Combine(pgData, "PG_VERSION"), "16");
    }
}
