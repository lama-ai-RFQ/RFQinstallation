using System.Text.RegularExpressions;
using RfqInstaller.Core.Models;

namespace RfqInstaller.Core.Releases;

/// <summary>
/// Picks the Windows updater executable from a broker release catalog.
/// Matches the running updater's broker self-update selection
/// (<c>artifact_id=updater</c> or a <c>windows_updater.exe</c> asset).
/// </summary>
public static class ReleaseUpdaterArtifact
{
    public const string InstalledFileName = "windows_updater.exe";

    private static readonly Regex PreferredName = new(
        @"(?i)(^|[-_])windows[-_]?updater.*\.exe$|windows_updater\.exe$",
        RegexOptions.CultureInvariant | RegexOptions.Compiled);

    public static ReleaseArtifact? Select(IEnumerable<ReleaseArtifact> artifacts)
    {
        ArgumentNullException.ThrowIfNull(artifacts);
        var candidates = artifacts.ToList();

        var explicitUpdater = candidates.FirstOrDefault(artifact =>
            string.Equals(artifact.ArtifactId, "updater", StringComparison.OrdinalIgnoreCase));
        if (explicitUpdater is not null)
        {
            if (!FileName(explicitUpdater.Name).EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("The Windows release lists an updater that is not an executable.");
            return explicitUpdater;
        }

        foreach (var artifact in candidates)
        {
            if (PreferredName.IsMatch(FileName(artifact.Name)))
            {
                return artifact;
            }
        }

        foreach (var artifact in candidates)
        {
            var name = FileName(artifact.Name);
            if (name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) &&
                name.Contains("updater", StringComparison.OrdinalIgnoreCase))
            {
                return artifact;
            }
        }

        return null;
    }

    public static string DownloadedFileName(ReleaseArtifact artifact)
    {
        ArgumentNullException.ThrowIfNull(artifact);
        return FileName(artifact.Name);
    }

    private static string FileName(string? name)
    {
        var fileName = Path.GetFileName(name);
        return string.IsNullOrWhiteSpace(fileName) ? string.Empty : fileName;
    }
}
