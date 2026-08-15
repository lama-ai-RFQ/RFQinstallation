namespace RfqInstaller.Demo.Models;

public enum InstallMode
{
    WindowsService,
    Standalone
}

public enum WizardStep
{
    Welcome,
    License,
    InstallMode,
    InstallLocation,
    DesktopShortcut,
    ReadyToInstall,
    Installing,
    Finish
}

public class WizardState
{
    public string LicenseKey { get; set; } = string.Empty;

    public InstallMode Mode { get; set; } = InstallMode.WindowsService;

    public string InstallPath { get; set; } = @"C:\Program Files\RFQ Application";

    public bool CreateDesktopShortcut { get; set; } = true;

    public bool LaunchAfterFinish { get; set; } = true;
}
