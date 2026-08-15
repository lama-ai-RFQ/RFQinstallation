using System.IO.Compression;

namespace RfqInstaller.Core.Archive;

public record ExtractProgress(int EntriesDone, int EntriesTotal, string CurrentEntry);

/// <summary>
/// Pure .NET zip extraction (System.IO.Compression) with per-entry progress reporting — replaces
/// the old installer's 7-Zip / Python-zipfile / tar / Expand-Archive fallback chain, none of which
/// are needed since .NET's own ZipFile support is always present.
/// </summary>
public static class ZipExtractor
{
    public static void Extract(string zipPath, string destinationDirectory, IProgress<ExtractProgress>? progress, CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(destinationDirectory);

        using var archive = ZipFile.OpenRead(zipPath);
        var entries = archive.Entries.Where(e => !string.IsNullOrEmpty(e.Name) || e.FullName.EndsWith('/')).ToList();
        var total = entries.Count;
        var done = 0;

        var destinationRoot = Path.GetFullPath(destinationDirectory + Path.DirectorySeparatorChar);

        foreach (var entry in entries)
        {
            cancellationToken.ThrowIfCancellationRequested();

            var destinationPath = Path.GetFullPath(Path.Combine(destinationDirectory, entry.FullName));
            if (!destinationPath.StartsWith(destinationRoot, StringComparison.OrdinalIgnoreCase))
            {
                throw new IOException($"Zip entry '{entry.FullName}' would extract outside the destination directory.");
            }

            if (string.IsNullOrEmpty(entry.Name))
            {
                Directory.CreateDirectory(destinationPath);
            }
            else
            {
                Directory.CreateDirectory(Path.GetDirectoryName(destinationPath)!);
                entry.ExtractToFile(destinationPath, overwrite: true);
            }

            done++;
            progress?.Report(new ExtractProgress(done, total, entry.FullName));
        }
    }
}
