using Microsoft.Win32;

namespace RfqInstaller.Core.Orchestration;

/// <summary>Registers/removes the standard Windows "Add or remove programs" entry, pointing at the bundled uninstaller exe (RfqInstaller.Uninstall.exe, copied into the install folder).</summary>
public static class UninstallRegistration
{
    private const string RegistryKeyPath = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\RFQApplication";

    public static void Register(string installPath, string version)
    {
        using var key = Registry.LocalMachine.CreateSubKey(RegistryKeyPath);
        var uninstallExe = Path.Combine(installPath, "RfqInstaller.Uninstall.exe");

        key.SetValue("DisplayName", "RFQ Application");
        key.SetValue("DisplayVersion", version);
        key.SetValue("Publisher", "RFQ");
        key.SetValue("InstallLocation", installPath);
        key.SetValue("UninstallString", $"\"{uninstallExe}\"");
        key.SetValue("DisplayIcon", uninstallExe);
        key.SetValue("NoModify", 1, RegistryValueKind.DWord);
        key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
    }

    public static void Unregister()
    {
        Registry.LocalMachine.DeleteSubKeyTree(RegistryKeyPath, throwOnMissingSubKey: false);
    }
}
