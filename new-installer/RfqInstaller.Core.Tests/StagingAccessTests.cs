using System.Security.AccessControl;
using System.Security.Principal;
using RfqInstaller.Core.Orchestration;
using RfqInstaller.Core.Security;
using Xunit;

namespace RfqInstaller.Core.Tests;

/// <summary>
/// A service running as Network Service could not launch the app: the files had been unpacked in
/// the installing user's temp folder and moved, keeping that folder's permissions.
/// </summary>
public sealed class StagingAccessTests : IDisposable
{
    // Local Service stands in for the service account: unlike Network Service, which CI runners
    // often run as, no temp folder grants it access.
    private static readonly SecurityIdentifier ServiceAccount = new(WellKnownSidType.LocalServiceSid, null);
    private readonly string _root = Directory.CreateTempSubdirectory("rfq-staging-access-").FullName;
    public void Dispose() => Directory.Delete(_root, recursive: true);

    [Fact]
    public void UnpackedFilesGetTheInstallFoldersAccessForTheServiceAccount()
    {
        var install = Directory.CreateDirectory(Path.Combine(_root, "install")).FullName;
        FolderAccess.Grant(install, FileSystemRights.Modify, new[] { ServiceAccount });

        var staging = InstallOrchestrator.CreateStagingRoot(install);
        Directory.CreateDirectory(Path.Combine(staging, "_internal"));
        File.WriteAllText(Path.Combine(staging, "RFQ_Application.exe"), "app");
        File.WriteAllText(Path.Combine(staging, "_internal", "python312.dll"), "runtime");
        InstallOrchestrator.MoveDirectoryContents(staging, install, CancellationToken.None);

        Assert.True(Allows(Path.Combine(install, "RFQ_Application.exe"), ServiceAccount));
        Assert.True(Allows(Path.Combine(install, "_internal", "python312.dll"), ServiceAccount));
    }

    [Fact]
    public void AFileMovedInFromAnotherFolderKeepsThatFoldersAccess()
    {
        // Why staging moved into the install folder: the move does not re-apply permissions.
        var install = Directory.CreateDirectory(Path.Combine(_root, "install")).FullName;
        FolderAccess.Grant(install, FileSystemRights.Modify, new[] { ServiceAccount });
        var elsewhere = Directory.CreateDirectory(Path.Combine(_root, "elsewhere")).FullName;
        File.WriteAllText(Path.Combine(elsewhere, "RFQ_Application.exe"), "app");

        InstallOrchestrator.MoveDirectoryContents(elsewhere, install, CancellationToken.None);

        Assert.False(Allows(Path.Combine(install, "RFQ_Application.exe"), ServiceAccount));
    }

    [Fact]
    public void AnInterruptedInstallsStagingIsClearedAndNotLeftBehind()
    {
        var install = Directory.CreateDirectory(Path.Combine(_root, "install")).FullName;
        var leftover = Directory.CreateDirectory(
            Path.Combine(install, InstallOrchestrator.StagingFolderName, "old")).FullName;
        File.WriteAllText(Path.Combine(leftover, "half-unpacked.dll"), "partial");

        var staging = InstallOrchestrator.CreateStagingRoot(install);

        Assert.False(Directory.Exists(leftover));
        Assert.True(Directory.Exists(staging));
        Assert.Equal(Path.Combine(install, InstallOrchestrator.StagingFolderName), Path.GetDirectoryName(staging));
    }

    private static bool Allows(string file, SecurityIdentifier sid)
    {
        foreach (FileSystemAccessRule rule in new FileInfo(file).GetAccessControl()
                     .GetAccessRules(true, true, typeof(SecurityIdentifier)))
        {
            if (rule.AccessControlType == AccessControlType.Allow &&
                sid.Equals(rule.IdentityReference) &&
                rule.FileSystemRights.HasFlag(FileSystemRights.ReadAndExecute))
            {
                return true;
            }
        }

        return false;
    }
}
