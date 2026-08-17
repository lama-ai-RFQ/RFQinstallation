using RfqInstaller.Demo.Models;

namespace RfqInstaller.Demo;

/// <summary>
/// Written to disk before a UAC relaunch so the elevated process can continue the wizard.
/// Public (not nested) so System.Text.Json can round-trip it in the new process.
/// </summary>
public class ElevationHandoff
{
    public const string ResumeArgument = "--elevate-resume";

    public WizardState State { get; set; } = new();
    public WizardStep ResumeStep { get; set; }
    public string? ReadySignalPath { get; set; }
}
