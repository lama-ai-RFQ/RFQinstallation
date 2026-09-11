using RfqInstaller.Core.Models;
using RfqInstaller.Core.Orchestration;
using RfqInstaller.Core.Releases;
using Xunit;

namespace RfqInstaller.Core.Tests;

public sealed class ReleaseUpdaterArtifactTests
{
    [Fact]
    public void PrefersExplicitUpdaterArtifactId()
    {
        var selected = ReleaseUpdaterArtifact.Select(
        [
            Artifact("app-executable.zip", "app-executable.zip"),
            Artifact("updater", "windows_updater.exe"),
        ]);

        Assert.NotNull(selected);
        Assert.Equal("updater", selected.ArtifactId);
        Assert.Equal("windows_updater.exe", selected.Name);
    }

    [Fact]
    public void AcceptsWindowsUpdaterFileName()
    {
        var selected = ReleaseUpdaterArtifact.Select(
        [
            Artifact("windows_updater.exe", "windows_updater.exe"),
        ]);

        Assert.NotNull(selected);
        Assert.Equal("windows_updater.exe", selected.ArtifactId);
    }

    [Fact]
    public void IgnoresZipComponents()
    {
        Assert.Null(ReleaseUpdaterArtifact.Select(
        [
            Artifact("app-executable.zip", "app-executable.zip"),
            Artifact("updater.zip", "updater.zip"),
            Artifact("manifest.json", "manifest.json"),
        ]));
    }

    [Fact]
    public void InstallCopiesDownloadedUpdaterAsWindowsUpdaterExe()
    {
        var directory = Directory.CreateTempSubdirectory("rfq-updater-install-");
        try
        {
            var downloaded = Path.Combine(directory.FullName, "windows_updater.exe");
            var installPath = Path.Combine(directory.FullName, "install");
            Directory.CreateDirectory(installPath);
            File.WriteAllBytes(downloaded, "current-updater-release"u8.ToArray());

            InstallOrchestrator.InstallUpdaterFromRelease(
                [Artifact("updater", "windows_updater.exe")],
                [downloaded],
                installPath);

            Assert.Equal(
                "current-updater-release"u8.ToArray(),
                File.ReadAllBytes(Path.Combine(installPath, "windows_updater.exe")));
        }
        finally
        {
            directory.Delete(recursive: true);
        }
    }

    [Fact]
    public void InstallFailsWhenCatalogOmitsUpdater()
    {
        var error = Assert.Throws<InvalidDataException>(() =>
            InstallOrchestrator.InstallUpdaterFromRelease(
                [Artifact("app-executable.zip", "app-executable.zip")],
                [],
                "."));

        Assert.Contains("does not include a windows updater executable", error.Message);
    }

    private static ReleaseArtifact Artifact(string artifactId, string name) =>
        new()
        {
            ArtifactId = artifactId,
            Name = name,
            Size = 1,
            Sha256 = new string('a', 64),
        };
}
