using System.IO;

namespace RfqInstaller;

internal sealed class BundledTools : IDisposable
{
    private readonly DirectoryInfo _directory = Directory.CreateTempSubdirectory("RfqInstaller-");
    public string NssmPath => Path.Combine(_directory.FullName, "nssm.exe");
    public string UninstallerPath => Path.Combine(_directory.FullName, "RfqInstaller.Uninstall.exe");

    public void Extract()
    {
        foreach (var path in new[] { NssmPath, UninstallerPath })
        {
            var name = "Bundled." + Path.GetFileName(path);
            using var resource = typeof(BundledTools).Assembly.GetManifestResourceStream(name)
                ?? throw new InvalidOperationException($"The installer is missing {name}.");
            using var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            resource.CopyTo(file);
        }
    }

    public void Dispose()
    {
        try { _directory.Delete(recursive: true); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}
