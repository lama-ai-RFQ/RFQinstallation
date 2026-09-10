using System.Net;
using System.Security.Cryptography;
using RfqInstaller.Core.Networking;
using Xunit;

namespace RfqInstaller.Core.Tests;

public sealed class HttpDownloaderTests
{
    [Fact]
    public async Task VerifiesSizeAndSha256BeforePublishingDownload()
    {
        var content = "verified broker artifact"u8.ToArray();
        using var http = new HttpClient(new ContentHandler(content));
        var downloader = new HttpDownloader(http);
        var directory = Directory.CreateTempSubdirectory("rfq-downloader-test-");
        var destination = Path.Combine(directory.FullName, "artifact.zip");
        try
        {
            await downloader.DownloadAsync(
                "https://downloads.example.test/artifact.zip",
                destination,
                content.Length,
                progress: null,
                CancellationToken.None,
                maxAttempts: 1,
                expectedSha256: Convert.ToHexString(SHA256.HashData(content)).ToLowerInvariant());

            Assert.Equal(content, await File.ReadAllBytesAsync(destination));
            Assert.False(File.Exists(destination + ".part"));
        }
        finally
        {
            directory.Delete(recursive: true);
        }
    }

    [Fact]
    public async Task RejectsAnArtifactWithTheWrongDigest()
    {
        var content = "tampered"u8.ToArray();
        using var http = new HttpClient(new ContentHandler(content));
        var downloader = new HttpDownloader(http);
        var directory = Directory.CreateTempSubdirectory("rfq-downloader-test-");
        var destination = Path.Combine(directory.FullName, "artifact.zip");
        try
        {
            await Assert.ThrowsAsync<IOException>(() => downloader.DownloadAsync(
                "https://downloads.example.test/artifact.zip",
                destination,
                content.Length,
                progress: null,
                CancellationToken.None,
                maxAttempts: 1,
                expectedSha256: new string('a', 64)));

            Assert.False(File.Exists(destination));
            Assert.False(File.Exists(destination + ".part"));
        }
        finally
        {
            directory.Delete(recursive: true);
        }
    }

    private sealed class ContentHandler(byte[] content) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken) =>
            Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new ByteArrayContent(content),
            });
    }
}
