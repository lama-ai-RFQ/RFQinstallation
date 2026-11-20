using System.IO.Compression;
using System.Security.Cryptography;
using RfqInstaller.Core.Models;
using RfqInstaller.Core.Orchestration;
using Xunit;

namespace RfqInstaller.Core.Tests;

[Collection("Native Windows installer")]
public sealed class ReleaseStagingTests : IDisposable
{
    private readonly string _root = Directory.CreateTempSubdirectory("rfq-release-tests-").FullName;
    public void Dispose() => Directory.Delete(_root, recursive: true);

    [Theory]
    [InlineData(false, true, null, "executable")]
    [InlineData(true, false, null, "updater")]
    [InlineData(true, true, ".env", ".env")]
    [InlineData(true, true, "pgdata/PG_VERSION", "pgdata")]
    [InlineData(true, true, "backend/main/user_config.yaml", "user_config.yaml")]
    [InlineData(true, true, "key.pem", "key.pem")]
    public async Task IncompleteOrMispackagedReleaseFailsBeforeStoppingServices(
        bool includeApp, bool includeUpdater, string? extraEntry, string expectedError)
    {
        var install = Directory.CreateDirectory(Path.Combine(_root, "install")).FullName;
        var app = Path.Combine(install, "RFQ_Application.exe");
        File.WriteAllText(app, "previous app");
        File.WriteAllText(Path.Combine(install, "windows_updater.exe"), "previous updater");
        File.WriteAllText(Path.Combine(install, ".env"), "customer settings");
        var archive = Path.Combine(_root, "app.zip");
        using (var zip = ZipFile.Open(archive, ZipArchiveMode.Create))
        {
            void Add(string name)
            {
                using var writer = new StreamWriter(zip.CreateEntry(name).Open());
                writer.Write("release file");
            }
            if (includeApp) Add("RFQ_Application.exe");
            if (includeUpdater) Add("windows_updater.exe");
            if (extraEntry is not null) Add(extraEntry);
        }
        var nssm = Path.Combine(_root, "nssm.exe");
        File.WriteAllText(nssm, "bundled tool");
        var size = new FileInfo(archive).Length;
        var sha = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(archive)));
        var release = new SignedWindowsRelease
        {
            Release = new WindowsRelease
            {
                ReleaseId = "customer:windows:1", Channel = "customer", Platform = "windows", Version = "1",
                Artifacts = [new ReleaseArtifact { ArtifactId = "app", Name = "app.zip", Size = size, Sha256 = sha }],
            },
            Artifacts = [new SignedArtifact { ArtifactId = "app", Url = "https://unused.invalid/app.zip", Size = size, Sha256 = sha }],
        };
        var steps = new RecordingProgress();
        var error = await Assert.ThrowsAsync<InvalidDataException>(() =>
            new InstallOrchestrator(nssm).DownloadAndExtractComponentsAsync(release, _root, install, steps, CancellationToken.None));

        Assert.Contains(expectedError, error.Message, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("Stopping existing RFQ services", steps.Names);
        Assert.Equal("previous app", File.ReadAllText(app));
        Assert.Equal("previous updater", File.ReadAllText(Path.Combine(install, "windows_updater.exe")));
        Assert.Equal("customer settings", File.ReadAllText(Path.Combine(install, ".env")));
        Assert.False(Directory.Exists(Path.Combine(install, InstallOrchestrator.StagingFolderName)));
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void CompleteReleaseStagesAppToolsAndManifestTogether(bool separateUpdater)
    {
        var stage = Directory.CreateDirectory(Path.Combine(_root, "stage")).FullName;
        var archive = Path.Combine(_root, "app.zip");
        using (var zip = ZipFile.Open(archive, ZipArchiveMode.Create))
        {
            using (var app = new StreamWriter(zip.CreateEntry("RFQ_Application.exe").Open()))
                app.Write("new app");
            using var updater = new StreamWriter(zip.CreateEntry("windows_updater.exe").Open());
            updater.Write("archive updater");
        }
        var nssm = Path.Combine(_root, "nssm.exe");
        var manifest = Path.Combine(_root, "manifest.json");
        File.WriteAllText(nssm, "bundled tool");
        File.WriteAllText(manifest, "{}");
        var downloaded = new List<string> { archive, manifest };
        var catalog = new List<ReleaseArtifact>();
        if (separateUpdater)
        {
            var updater = Path.Combine(_root, "updater-current.exe");
            File.WriteAllText(updater, "current updater");
            downloaded.Add(updater);
            catalog.Add(new ReleaseArtifact { ArtifactId = "updater", Name = Path.GetFileName(updater), Sha256 = "unused" });
        }

        new InstallOrchestrator(nssm).StageRelease([archive], catalog, downloaded, stage, new RecordingProgress(), CancellationToken.None);
        Assert.Equal("new app", File.ReadAllText(Path.Combine(stage, "RFQ_Application.exe")));
        Assert.Equal(separateUpdater ? "current updater" : "archive updater", File.ReadAllText(Path.Combine(stage, "windows_updater.exe")));
        Assert.Equal("bundled tool", File.ReadAllText(Path.Combine(stage, "nssm.exe")));
        Assert.Equal("{}", File.ReadAllText(Path.Combine(stage, "local_manifest.json")));
    }

    [Theory]
    [InlineData("app.zip.part2", "deps.zip")]
    [InlineData("app.zip.part1", "app.zip.part3")]
    [InlineData("app.zip.part1", "app.zip.part01")]
    [InlineData("app.zip.part1", "app.zip")]
    [InlineData("app.zip.part1", "app.zip.partX")]
    public void RejectsIncompleteOrAmbiguousMultipartArchives(string first, string second)
    {
        Assert.Throws<InvalidDataException>(() => InstallOrchestrator.MultipartArchives([first, second]).ToArray());
    }

    [Fact]
    public void MultipartArchivesUseTheNumberedOrderRegardlessOfCatalogOrder()
    {
        var paths = Enumerable.Range(1, 12).Select(i => $"app.zip.part{i}").ToArray();
        var (name, parts) = Assert.Single(InstallOrchestrator.MultipartArchives(paths.Reverse().Append("deps.zip").ToArray()));
        Assert.Equal("app.zip", name);
        Assert.Equal(paths, parts);
    }

    [Fact]
    public void SecondSetupCanRetryAfterFirstSetupExits()
    {
        using (InstallOrchestrator.AcquireSetupLock())
            Assert.Throws<InvalidOperationException>(() => InstallOrchestrator.AcquireSetupLock());
        using var retry = InstallOrchestrator.AcquireSetupLock();
    }

    private sealed class RecordingProgress : IProgress<InstallStepProgress>
    {
        public System.Collections.Concurrent.ConcurrentQueue<string> Names { get; } = new();
        public void Report(InstallStepProgress value) => Names.Enqueue(value.StepName);
    }
}
