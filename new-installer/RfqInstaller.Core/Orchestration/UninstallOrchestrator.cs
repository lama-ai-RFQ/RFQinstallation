using RfqInstaller.Core.Database;
using RfqInstaller.Core.Services;

namespace RfqInstaller.Core.Orchestration;

/// <summary>
/// Removes everything the installer created: the app + updater services, the app's private
/// PostgreSQL instance/service, and (optionally) the installed files and database contents.
/// Keeping the database is the default — deleting a customer's data on uninstall is a one-way
/// door, so it requires an explicit opt-in.
/// </summary>
public class UninstallOrchestrator
{
    public async Task RunAsync(string installPath, bool deleteDatabase, IProgress<string> progress, CancellationToken cancellationToken)
    {
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

        if (deleteDatabase)
        {
            progress.Report("Removing PostgreSQL service and data...");
            var pgCtl = Path.Combine(installPath, "pgsql", "bin", "pg_ctl.exe");
            var dataDir = Path.Combine(installPath, "pgdata");
            if (File.Exists(pgCtl))
            {
                await Processes.HiddenProcessRunner.RunAsync(pgCtl, new[] { "unregister", "-N", PostgresProvisioner.ServiceName }, cancellationToken: cancellationToken)
                    .ConfigureAwait(false);
            }
            if (Directory.Exists(dataDir))
            {
                Directory.Delete(dataDir, recursive: true);
            }
        }
        else
        {
            progress.Report("Keeping database — stopping PostgreSQL service only...");
            await Processes.HiddenProcessRunner.RunAsync("sc.exe", new[] { "stop", PostgresProvisioner.ServiceName }, cancellationToken: cancellationToken)
                .ConfigureAwait(false);
        }

        progress.Report("Removing Add/Remove Programs entry...");
        UninstallRegistration.Unregister();

        progress.Report("Removing installed files...");
        // The uninstaller itself typically runs from inside installPath; scheduling deletion of
        // the running executable's own file is handled by the caller (see RfqInstaller.Uninstall).
    }
}
