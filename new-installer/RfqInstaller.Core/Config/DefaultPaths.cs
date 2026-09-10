namespace RfqInstaller.Core.Config;

/// <summary>Computes install-time default folders, working around known Windows footguns rather than trusting SpecialFolder blindly.</summary>
public static class DefaultPaths
{
    /// <summary>
    /// The AI model is ~30 GB and needs to stay fully present on local disk at all times. On many
    /// Windows machines (very commonly on managed/corporate devices), "Documents" is silently
    /// redirected into OneDrive via Known Folder Move — <see cref="Environment.SpecialFolder.MyDocuments"/>
    /// still resolves fine, it just quietly points at a synced folder. Downloading a 30 GB model
    /// there would try to upload all of it to OneDrive (bandwidth/quota) and OneDrive's
    /// Files-On-Demand can later evict the local copy to a cloud-only placeholder, breaking the
    /// app's ability to read it. So: use the normal "Documents\RFQ_Models" default only when
    /// Documents is a real local folder; otherwise fall back to the per-machine, never-synced
    /// local app-data folder.
    /// </summary>
    public static string DefaultModelPath()
    {
        var documents = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);

        if (IsOneDriveRedirected(documents))
        {
            var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            return Path.Combine(localAppData, "RFQApplication", "RFQ_Models");
        }

        return Path.Combine(documents, "RFQ_Models");
    }

    private static bool IsOneDriveRedirected(string documentsPath)
    {
        foreach (var variable in new[] { "OneDriveCommercial", "OneDriveConsumer", "OneDrive" })
        {
            var oneDriveRoot = Environment.GetEnvironmentVariable(variable);
            if (!string.IsNullOrEmpty(oneDriveRoot) &&
                documentsPath.StartsWith(oneDriveRoot, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }
}
