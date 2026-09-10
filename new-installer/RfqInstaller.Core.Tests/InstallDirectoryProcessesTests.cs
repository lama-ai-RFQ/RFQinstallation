using RfqInstaller.Core.Processes;

namespace RfqInstaller.Core.Tests;

public class InstallDirectoryProcessesTests
{
    [Fact]
    public void IsUnderInstallDirectory_matches_nested_binaries()
    {
        Assert.True(InstallDirectoryProcesses.IsUnderInstallDirectory(
            @"D:\Program Files\RFQ Application\_internal\_asyncio.pyd",
            @"D:\Program Files\RFQ Application"));
        Assert.True(InstallDirectoryProcesses.IsUnderInstallDirectory(
            @"D:\Program Files\RFQ Application\RFQ_Application.exe",
            @"D:\Program Files\RFQ Application"));
    }

    [Fact]
    public void IsUnderInstallDirectory_does_not_match_sibling_folder()
    {
        Assert.False(InstallDirectoryProcesses.IsUnderInstallDirectory(
            @"D:\Program Files\RFQ Application Backup\RFQ_Application.exe",
            @"D:\Program Files\RFQ Application"));
    }

    [Fact]
    public void IsFileInUse_detects_sharing_violation()
    {
        var sharing = new IOException("The process cannot access the file because it is being used by another process.")
        {
            HResult = unchecked((int)0x80070020)
        };
        Assert.True(InstallDirectoryProcesses.IsFileInUse(sharing));
        Assert.True(InstallDirectoryProcesses.IsFileInUse(new InvalidOperationException("wrap", sharing)));
        Assert.False(InstallDirectoryProcesses.IsFileInUse(new IOException("disk full")));
    }
}
