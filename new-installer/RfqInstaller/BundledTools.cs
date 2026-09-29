using System.IO;
using System.Reflection;

namespace RfqInstaller;

/// <summary>
/// Tools embedded in the installer exe itself, so the single downloaded RfqInstaller.exe works
/// without a Bundled\ folder beside it.
/// </summary>
public static class BundledTools
{
    private const string NssmResourceName = "Bundled.nssm.exe";

    /// <summary>
    /// Writes the embedded nssm.exe to a fresh, per-run temp directory and returns its path.
    /// A unique directory per run avoids reusing (or racing on) a file another process could
    /// have planted at a predictable path before the elevated install executes it.
    /// </summary>
    public static string ExtractNssm()
    {
        var directory = Path.Combine(Path.GetTempPath(), "RfqInstaller", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "nssm.exe");

        using var resource = Assembly.GetExecutingAssembly().GetManifestResourceStream(NssmResourceName)
            ?? throw new InvalidOperationException($"Embedded resource '{NssmResourceName}' is missing from the installer.");
        using (var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        {
            resource.CopyTo(file);
        }

        return path;
    }
}
