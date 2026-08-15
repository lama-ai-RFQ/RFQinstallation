using RfqInstaller.Demo.Models;

namespace RfqInstaller.Demo.Debug;

/// <summary>
/// Wizard shortcuts for local testing. Every skip is compiled out of Release builds.
/// Add steps to <see cref="SkipSteps"/> as you find more pages you want to bypass.
/// </summary>
public static class InstallerDebug
{
#if DEBUG
    public const bool Enabled = true;
#else
    public const bool Enabled = false;
#endif

    /// <summary>
    /// Wizard pages to jump over while <see cref="Enabled"/> is true.
    /// Example later: <c>WizardStep.License, WizardStep.ModelDownload</c>.
    /// </summary>
    public static IReadOnlySet<WizardStep> SkipSteps { get; } = Enabled
        ? new HashSet<WizardStep>
        {
            WizardStep.License,
        }
        : new HashSet<WizardStep>();

    public static bool ShouldSkip(WizardStep step) => SkipSteps.Contains(step);
}
