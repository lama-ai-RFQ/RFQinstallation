using System.Text.Json;
using RfqInstaller.Core.Models;
using RfqInstaller.Core.Shortcuts;

namespace RfqInstaller.Core.Desktop;

/// <summary>
/// Individual and Team installs open Scint in its desktop app (Scint.exe, shipped in the app
/// bundle) instead of the browser. The app reads %ProgramData%\Scint\desktop.json to find the
/// server, to start it on standalone installs, and to trust the install's self-signed certificate.
/// Enterprise installs, and app releases older than Scint.exe, keep opening the browser.
/// </summary>
public static class DesktopAppSetup
{
    public const string ExecutableName = "Scint.exe";
    public const string ShortcutName = "Scint.lnk";
    public const string LegacyShortcutName = "RFQ Application.lnk";
    private const string MainExecutableName = "RFQ_Application.exe";
    private const string DefaultAppPort = "8000";

    public static string DefaultConfigPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "Scint", "desktop.json");

    public static string DesktopShortcutPath(string name) =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), name);

    /// <summary>Scint.exe of this install, when the installed release ships one.</summary>
    public static string? ExecutablePath(string installPath)
    {
        var path = Path.Combine(installPath, ExecutableName);
        return File.Exists(path) ? path : null;
    }

    /// <summary>The app's address: SERVER_URL (scheme and host) plus the app's PORT (8000) unless it names a port.</summary>
    public static string AppUrl(string serverUrl, string? appPort = null)
    {
        var uri = new Uri(serverUrl);
        var authority = uri.IsDefaultPort ? $"{uri.Host}:{appPort ?? DefaultAppPort}" : uri.Authority;
        return $"{uri.Scheme}://{authority}/";
    }

    public static void WriteConfig(string configPath, string installPath, InstallMode mode, string serverUrl, string? appPort = null)
    {
        var config = new Dictionary<string, string>
        {
            ["server_url"] = AppUrl(serverUrl, appPort),
            ["mode"] = mode == InstallMode.Standalone ? "standalone" : "service",
            ["certificate_file"] = Path.Combine(installPath, "cert.pem"),
        };
        if (mode == InstallMode.Standalone)
        {
            // The desktop app starts and stops the server on standalone installs.
            config["backend_exe"] = Path.Combine(installPath, MainExecutableName);
        }

        Directory.CreateDirectory(Path.GetDirectoryName(configPath)!);
        File.WriteAllText(configPath, JsonSerializer.Serialize(config, new JsonSerializerOptions { WriteIndented = true }));
    }

    /// <summary>
    /// Points the install at Scint.exe: writes its config and the "Scint" desktop shortcut (replacing
    /// the old "RFQ Application" one). Returns Scint.exe's path, or null when this install keeps
    /// the browser (Enterprise license, or a release without the desktop app).
    /// </summary>
    public static string? Configure(string installPath, InstallMode mode, string licenseKey, bool createShortcut,
        string? configPath = null)
    {
        var exe = ExecutablePath(installPath);
        if (exe is null || !Licensing.LocalLicenseValidator.Validate(licenseKey).SelfServe)
        {
            return null;
        }

        var env = Config.EnvFileReader.Read(installPath);
        WriteConfig(
            configPath ?? DefaultConfigPath,
            installPath,
            mode,
            env.GetValueOrDefault("SERVER_URL") is { Length: > 0 } serverUrl ? serverUrl : "https://localhost",
            env.GetValueOrDefault("PORT"));
        if (createShortcut)
        {
            ShellShortcut.Create(DesktopShortcutPath(ShortcutName), exe, installPath, exe, "Scint");
            var legacy = DesktopShortcutPath(LegacyShortcutName);
            if (File.Exists(legacy))
            {
                File.Delete(legacy);
            }
        }
        return exe;
    }

    /// <summary>Uninstall: the shortcut and the machine config.</summary>
    public static void Remove(string? configPath = null, string? shortcutPath = null)
    {
        foreach (var path in new[] { shortcutPath ?? DesktopShortcutPath(ShortcutName), configPath ?? DefaultConfigPath })
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
    }
}
