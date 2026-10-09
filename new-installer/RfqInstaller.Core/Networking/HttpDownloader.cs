using System.Security.Cryptography;

namespace RfqInstaller.Core.Networking;

public record DownloadProgress(long BytesReceived, long? TotalBytes, string FileName);

/// <summary>
/// Plain-HTTPS file downloader used for everything the old installer needed Python/boto3 for
/// (release package, model files) — the broker hands back pre-signed URLs, so no AWS SDK or
/// credentials are needed on the client at all.
/// </summary>
public class HttpDownloader
{
    private readonly HttpClient _http;
    private readonly TimeSpan _readTimeout;

    public HttpDownloader(HttpClient? httpClient = null, TimeSpan? readTimeout = null)
    {
        _http = httpClient ?? new HttpClient();
        _readTimeout = readTimeout ?? TimeSpan.FromMinutes(2);
        if (_readTimeout <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(readTimeout), "The read timeout must be positive.");
        }
    }

    /// <summary>
    /// Downloads <paramref name="url"/> to <paramref name="destinationPath"/>. If a file of the
    /// expected size already exists (see <paramref name="expectedSizeBytes"/>), the download is
    /// skipped entirely — this is what makes "reuse existing downloads" on reinstall cheap.
    /// </summary>
    public async Task DownloadAsync(
        string url,
        string destinationPath,
        long? expectedSizeBytes,
        IProgress<DownloadProgress>? progress,
        CancellationToken cancellationToken,
        int maxAttempts = 3,
        string? expectedSha256 = null)
    {
        if (maxAttempts is < 1 or > 8)
        {
            throw new ArgumentOutOfRangeException(nameof(maxAttempts), "maxAttempts must be between 1 and 8.");
        }
        cancellationToken.ThrowIfCancellationRequested();
        var fileName = Path.GetFileName(destinationPath);
        if (expectedSha256 is not null &&
            (expectedSha256.Length != 64 || expectedSha256.Any(character => !Uri.IsHexDigit(character))))
        {
            throw new ArgumentException("Expected SHA-256 must contain 64 hexadecimal characters.", nameof(expectedSha256));
        }

        if (expectedSizeBytes is > 0 && File.Exists(destinationPath) &&
            new FileInfo(destinationPath).Length == expectedSizeBytes)
        {
            if (expectedSha256 is null ||
                await HasExpectedSha256Async(destinationPath, expectedSha256, cancellationToken).ConfigureAwait(false))
            {
                progress?.Report(new DownloadProgress(expectedSizeBytes.Value, expectedSizeBytes, fileName));
                return;
            }
        }

        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(destinationPath))!);

        Exception? lastError = null;
        for (var attempt = 1; attempt <= maxAttempts; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                await DownloadOnceAsync(
                    url,
                    destinationPath,
                    fileName,
                    expectedSizeBytes,
                    expectedSha256,
                    progress,
                    cancellationToken).ConfigureAwait(false);
                return;
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception ex)
            {
                lastError = ex;
                if (attempt < maxAttempts)
                {
                    await Task.Delay(TimeSpan.FromSeconds(2 * attempt), cancellationToken).ConfigureAwait(false);
                }
            }
            finally
            {
                TryDelete(destinationPath + ".part");
            }
        }

        throw new IOException($"Failed to download '{fileName}' after {maxAttempts} attempts.", lastError);
    }

    private async Task DownloadOnceAsync(
        string url,
        string destinationPath,
        string fileName,
        long? expectedSizeBytes,
        string? expectedSha256,
        IProgress<DownloadProgress>? progress,
        CancellationToken cancellationToken)
    {
        using var response = await _http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, cancellationToken)
            .ConfigureAwait(false);
        response.EnsureSuccessStatusCode();

        var total = response.Content.Headers.ContentLength;
        var tempPath = destinationPath + ".part";

        await using (var httpStream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false))
        await using (var fileStream = new FileStream(tempPath, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20, useAsync: true))
        {
            var buffer = new byte[1 << 20];
            long received = 0;
            using var readCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            while (true)
            {
                // ResponseHeadersRead only applies HttpClient.Timeout to the
                // headers. Bound each body read without limiting a large,
                // steadily progressing download's total duration.
                readCancellation.CancelAfter(_readTimeout);
                int read;
                try
                {
                    read = await httpStream.ReadAsync(buffer, readCancellation.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
                {
                    throw new TimeoutException($"The download of '{fileName}' stopped receiving data.");
                }
                readCancellation.CancelAfter(Timeout.InfiniteTimeSpan);
                if (read == 0)
                {
                    break;
                }
                if (expectedSizeBytes is > 0 && received + read > expectedSizeBytes.Value)
                {
                    throw new InvalidDataException("Downloaded file exceeds the expected size.");
                }
                await fileStream.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
                received += read;
                progress?.Report(new DownloadProgress(received, total, fileName));
            }
        }

        var actualSize = new FileInfo(tempPath).Length;
        if (expectedSizeBytes is > 0 && actualSize != expectedSizeBytes.Value)
        {
            TryDelete(tempPath);
            throw new InvalidDataException(
                $"Downloaded file size mismatch ({actualSize} != {expectedSizeBytes.Value}).");
        }
        if (expectedSha256 is not null &&
            !await HasExpectedSha256Async(tempPath, expectedSha256, cancellationToken).ConfigureAwait(false))
        {
            TryDelete(tempPath);
            throw new InvalidDataException("Downloaded file SHA-256 verification failed.");
        }

        File.Move(tempPath, destinationPath, overwrite: true);
    }

    private static async Task<bool> HasExpectedSha256Async(
        string path,
        string expectedSha256,
        CancellationToken cancellationToken)
    {
        await using var stream = new FileStream(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            1 << 20,
            useAsync: true);
        var actual = await SHA256.HashDataAsync(stream, cancellationToken).ConfigureAwait(false);
        var expected = Convert.FromHexString(expectedSha256);
        return CryptographicOperations.FixedTimeEquals(actual, expected);
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); } catch { /* best-effort cleanup */ }
    }
}
