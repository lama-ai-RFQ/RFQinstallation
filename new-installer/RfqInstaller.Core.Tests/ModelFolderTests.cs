using RfqInstaller.Core.Config;
using RfqInstaller.Core.Models;
using RfqInstaller.Core.Orchestration;
using Xunit;

namespace RfqInstaller.Core.Tests;

/// <summary>
/// A customer's service ran as Network Service with its model folder in the installing user's
/// AppData, where that account can't read or download models.
/// </summary>
public sealed class ModelFolderTests
{
    private static InstallPlan Plan(InstallMode mode, ServiceAccountKind account) => new()
    {
        LicenseKey = "RFQ.test.key",
        InstallPath = @"C:\Program Files\RFQ Application",
        SettingsPassword = "unused",
        Mode = mode,
        ServiceAccount = account,
    };

    [Theory]
    [InlineData(ServiceAccountKind.NetworkService)]
    [InlineData(ServiceAccountKind.LocalSystem)]
    public void AServiceNotRunningAsTheInstallingUserGetsAMachineModelFolder(ServiceAccountKind account)
    {
        var path = InstallOrchestrator.ModelPath(Plan(InstallMode.WindowsService, account));

        Assert.Equal(DefaultPaths.MachineModelPath(), path);
        Assert.StartsWith(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            path,
            StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void TheInstallingUsersServiceOrStandaloneAppKeepsTheUsersModelFolder()
    {
        Assert.Equal(
            DefaultPaths.DefaultModelPath(),
            InstallOrchestrator.ModelPath(Plan(InstallMode.WindowsService, ServiceAccountKind.CurrentUser)));
        Assert.Equal(
            DefaultPaths.DefaultModelPath(),
            InstallOrchestrator.ModelPath(Plan(InstallMode.Standalone, ServiceAccountKind.NetworkService)));
    }
}
