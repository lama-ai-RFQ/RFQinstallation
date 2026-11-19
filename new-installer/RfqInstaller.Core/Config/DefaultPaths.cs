namespace RfqInstaller.Core.Config;

/// <summary>Computes install-time default folders, working around known Windows footguns rather than trusting SpecialFolder blindly.</summary>
public static class DefaultPaths
{
    /// <summary>Setup grants access to its install folder and its children. A shared system
    /// or profile folder must never receive that grant as the installation itself.</summary>
    public static string? InstallFolderProblem(string? path)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path))
            return "Enter the full path to a folder for RFQ Application.";

        try
        {
            var directory = new DirectoryInfo(path);
            var fullPath = Path.TrimEndingDirectorySeparator(directory.FullName);
            const string dedicatedFolder = "Choose a dedicated application folder, such as an RFQ Application subfolder.";
            if (directory.Parent is null)
                return dedicatedFolder;
            if (File.Exists(fullPath))
                return "The selected path is a file. Choose a folder for RFQ Application.";

            Environment.SpecialFolder[] sharedFolders = [
                Environment.SpecialFolder.Windows, Environment.SpecialFolder.System, Environment.SpecialFolder.SystemX86,
                Environment.SpecialFolder.ProgramFiles, Environment.SpecialFolder.ProgramFilesX86,
                Environment.SpecialFolder.CommonProgramFiles, Environment.SpecialFolder.CommonProgramFilesX86,
                Environment.SpecialFolder.CommonApplicationData, Environment.SpecialFolder.UserProfile,
                Environment.SpecialFolder.ApplicationData, Environment.SpecialFolder.LocalApplicationData,
                Environment.SpecialFolder.MyDocuments, Environment.SpecialFolder.DesktopDirectory,
            ];
            foreach (var shared in sharedFolders)
            {
                var known = Environment.GetFolderPath(shared);
                if (string.Equals(fullPath, known, StringComparison.OrdinalIgnoreCase) ||
                    known.StartsWith(fullPath + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                    return dedicatedFolder;
            }
            return null;
        }
        catch (Exception ex) when (ex is ArgumentException or IOException or NotSupportedException)
        {
            return "The install folder path is invalid. Choose another folder.";
        }
    }

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

    /// <summary>
    /// The model folder for a service that runs as Network Service or Local System. The app
    /// downloads models into it as that account, which can't open the installing user's
    /// Documents or AppData; ProgramData is local, never synced, and not tied to one user.
    /// </summary>
    public static string MachineModelPath() =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            "RFQApplication",
            "RFQ_Models");

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
