using System.Diagnostics;
using RfqInstaller.Core.Database;
using RfqInstaller.Core.Services;
using RfqInstaller.Core.Networking;

namespace RfqInstaller.Core.Orchestration;

/// <summary>
/// Removes the application binaries and services. Keeps the database and its engine available
/// for recovery by default. Deleting the database requires the user's explicit opt-in.
/// </summary>
public class UninstallOrchestrator
{
    public async Task RunAsync(string installPath, bool deleteDatabase, IProgress<string> progress, CancellationToken cancellationToken)
    {
        if (Config.DefaultPaths.InstallFolderProblem(installPath) is { } problem)
            throw new InvalidOperationException(problem);
        using var setupLock = InstallOrchestrator.AcquireSetupLock();
        var nssmPath = Path.Combine(installPath, "nssm.exe");
        if (File.Exists(nssmPath))
        {
            var nssm = new NssmServiceManager(nssmPath);
            progress.Report("Stopping RFQ Application service...");
            if (await nssm.ExistsAsync("RFQapplication", cancellationToken).ConfigureAwait(false))
            {
                await nssm.RemoveAsync("RFQapplication", cancellationToken).ConfigureAwait(false);
            }

            progress.Report("Stopping RFQ Updater service...");
            if (await nssm.ExistsAsync("RFQUpdaterService", cancellationToken).ConfigureAwait(false))
            {
                await nssm.RemoveAsync("RFQUpdaterService", cancellationToken).ConfigureAwait(false);
            }
        }

        progress.Report("Stopping the RFQ PostgreSQL service...");
        var control = new ServiceControl();
        await control.StopIfExistsAsync(PostgresProvisioner.ServiceName, cancellationToken).ConfigureAwait(false);
        if (deleteDatabase)
        {
            progress.Report("Removing PostgreSQL service and data...");
            var pgCtl = Path.Combine(installPath, "pgsql", "bin", "pg_ctl.exe");
            var dataDir = Path.Combine(installPath, "pgdata");
            var postgres = await control.QueryAsync(PostgresProvisioner.ServiceName, cancellationToken).ConfigureAwait(false);
            if (postgres.State != ServiceState.NotInstalled)
            {
                var result = await Processes.HiddenProcessRunner.RunAsync(
                    pgCtl, new[] { "unregister", "-N", PostgresProvisioner.ServiceName }, cancellationToken: cancellationToken).ConfigureAwait(false);
                if (result.ExitCode != 0)
                    throw new IOException($"Could not unregister {PostgresProvisioner.ServiceName} (exit code {result.ExitCode}). The database has been kept.");
                await control.WaitUntilRemovedAsync(PostgresProvisioner.ServiceName, cancellationToken).ConfigureAwait(false);
            }
            if (Directory.Exists(dataDir))
            {
                Directory.Delete(dataDir, recursive: true);
            }
        }

        progress.Report("Removing the Windows Firewall rule...");
        await FirewallRule.RemoveAsync(FirewallRule.AppRuleName, cancellationToken).ConfigureAwait(false);

        progress.Report("Removing desktop shortcut...");
        // Matches the exact name/location InstallOrchestrator.CreateDesktopShortcut used — only
        // ever created for Standalone installs, but harmless to check unconditionally here.
        var shortcutPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "RFQ Application.lnk");
        if (File.Exists(shortcutPath))
        {
            File.Delete(shortcutPath);
        }
        Desktop.DesktopAppSetup.Remove();

        progress.Report("Removing installed files...");
        RemoveApplicationFiles(installPath);

        progress.Report("Removing Add/Remove Programs entry...");
        UninstallRegistration.Unregister();
    }

    // The selected install folder can also contain databases, configuration and customer
    // documents. Only remove known app binaries and their runtime. The UI removes its own exe.
    internal static void RemoveApplicationFiles(string installPath)
    {
        if (!Directory.Exists(installPath))
            return;
        string[] files = [ "RFQ_Application.exe", Desktop.DesktopAppSetup.ExecutableName,
            Releases.ReleaseUpdaterArtifact.InstalledFileName, "nssm.exe", "local_manifest.json" ];
        foreach (var name in files)
            File.Delete(Path.Combine(installPath, name));
        foreach (var name in new[] { "_internal", "native-code" })
        {
            var path = Path.Combine(installPath, name);
            if (Directory.Exists(path))
                Directory.Delete(path, recursive: true);
        }
    }

    public static Process ScheduleUninstallerDeletion(string installPath, int processId)
    {
        // Windows locks the running exe. The helper only deletes that file, even when
        // the user chose to delete the database. Pass the path as data, outside the command.
        var startInfo = new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"),
            ArgumentList = { "-NoProfile", "-NonInteractive", "-Command",
                "Wait-Process -Id $env:RFQ_UNINSTALL_PID -ErrorAction SilentlyContinue; " +
                "[IO.File]::Delete($env:RFQ_UNINSTALL_EXE)" },
            WorkingDirectory = Environment.SystemDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden,
        };
        startInfo.Environment["RFQ_UNINSTALL_PID"] = processId.ToString();
        startInfo.Environment["RFQ_UNINSTALL_EXE"] = Path.Combine(installPath, "RfqInstaller.Uninstall.exe");
        return Process.Start(startInfo) ?? throw new IOException("Could not start uninstaller cleanup.");
    }
}
