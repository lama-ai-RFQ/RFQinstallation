using System.Runtime.InteropServices;
using RfqInstaller.Core.Shortcuts;
using Xunit;

namespace RfqInstaller.Core.Tests;

public sealed class ShellShortcutTests
{
    [Fact]
    public void SavedShortcutRetainsItsTargetWorkingDirectoryAndIcon()
    {
        if (!OperatingSystem.IsWindows()) return;

        var root = Directory.CreateTempSubdirectory("rfq-shortcut-").FullName;
        object? shell = null;
        object? shortcut = null;
        try
        {
            var path = Path.Combine(root, "RFQ Application.lnk");
            var target = Path.Combine(Environment.SystemDirectory, "cmd.exe");
            var originalTarget = new string(target.ToCharArray());

            ShellShortcut.Create(path, target, root, target, "RFQ shortcut regression");

            Assert.Equal(originalTarget, target);
            // Read through Windows Script Host, independently of our IShellLink declaration.
            shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell", throwOnError: true)!);
            shortcut = ((dynamic)shell!).CreateShortcut(path);
            Assert.Equal(originalTarget, (string)((dynamic)shortcut).TargetPath, ignoreCase: true);
            Assert.Equal(root, (string)((dynamic)shortcut).WorkingDirectory, ignoreCase: true);
            Assert.Equal(originalTarget, ((string)((dynamic)shortcut).IconLocation).Split(',')[0], ignoreCase: true);
            Assert.Equal("RFQ shortcut regression", (string)((dynamic)shortcut).Description);
        }
        finally
        {
            if (shortcut is not null) Marshal.FinalReleaseComObject(shortcut);
            if (shell is not null) Marshal.FinalReleaseComObject(shell);
            Directory.Delete(root, recursive: true);
        }
    }
}
