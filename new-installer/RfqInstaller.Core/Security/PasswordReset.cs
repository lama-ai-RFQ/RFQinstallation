using System.Runtime.Versioning;
using Microsoft.Win32;
using Npgsql;
using RfqInstaller.Core.Config;
using RfqInstaller.Core.Database;
using RfqInstaller.Core.Services;

namespace RfqInstaller.Core.Security;

public enum ManagedPassword
{
    SuperUser,
    AppUser,
    Settings,
}

/// <summary>
/// Sets a new value for one of the install's passwords, from Repair: the postgres superuser, the
/// rfq_user database login, or the Settings page password. The database is changed first, then
/// the stored copy, in whichever place the install keeps it (.env or Windows Credential Manager).
/// Services read passwords when they start, so affected services are restarted afterwards.
///
/// A lost superuser password can still be reset: PostgreSQL briefly accepts the postgres login
/// from this computer without a password, then pg_hba.conf is put back exactly as it was.
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class PasswordReset
{
    public const string AppServiceName = "RFQapplication";
    public const string UpdaterServiceName = "RFQUpdaterService";

    private static readonly Dictionary<ManagedPassword, (string EnvKey, string Target, string UserName)> Stores = new()
    {
        [ManagedPassword.SuperUser] = ("SQL_SUPER_USER", "RFQApplication_SQL_SUPER_USER", "postgres"),
        [ManagedPassword.AppUser] = ("RFQ_USER_PASSWORD", "RFQApplication_RFQ_USER_PASSWORD", DatabaseSetup.AppUserName),
        [ManagedPassword.Settings] = ("SETTINGS_PASSWORD", "RFQApplication_SETTINGS_PASSWORD", "rfq_app"),
    };

    private readonly string _installPath;
    private readonly ServiceControl _services;
    private readonly Func<string?> _serviceAccountName;

    public PasswordReset(string installPath, ServiceControl? services = null)
        : this(installPath, services ?? new ServiceControl(), ServiceAccountName)
    {
    }

    internal PasswordReset(string installPath, ServiceControl services, Func<string?> serviceAccountName)
    {
        _installPath = installPath;
        _services = services;
        _serviceAccountName = serviceAccountName;
    }

    public async Task ResetAsync(ManagedPassword which, string newPassword, IProgress<string>? progress, CancellationToken cancellationToken)
    {
        if (Problem(which, newPassword) is { } problem)
        {
            throw new ArgumentException(problem, nameof(newPassword));
        }

        // Checked before the database changes, so a refused reset leaves everything as it was.
        EnsureStoreIsWritableHere(which);

        switch (which)
        {
            case ManagedPassword.SuperUser:
                progress?.Report("Changing the postgres password in the database...");
                await ChangeDatabasePasswordAsync("postgres", newPassword, progress, cancellationToken).ConfigureAwait(false);
                break;
            case ManagedPassword.AppUser:
                progress?.Report("Changing the rfq_user password in the database...");
                await ChangeDatabasePasswordAsync(DatabaseSetup.AppUserName, newPassword, progress, cancellationToken).ConfigureAwait(false);
                break;
        }

        progress?.Report("Saving the new password...");
        Store(which, newPassword);

        // The updater caches SETTINGS_PASSWORD separately. Refresh it first so an app startup
        // failure cannot leave the old password authorizing updater requests.
        if (which == ManagedPassword.Settings)
        {
            await RestartIfInstalledAsync(UpdaterServiceName, progress, cancellationToken).ConfigureAwait(false);
        }

        // The app reads all three when it starts (the superuser too, for schema updates).
        await RestartIfInstalledAsync(AppServiceName, progress, cancellationToken).ConfigureAwait(false);
    }

    private async Task RestartIfInstalledAsync(string serviceName, IProgress<string>? progress, CancellationToken cancellationToken)
    {
        if ((await _services.QueryAsync(serviceName, cancellationToken).ConfigureAwait(false)).State != ServiceState.NotInstalled)
        {
            progress?.Report($"Restarting {serviceName} so it uses the new password...");
            await _services.StopIfExistsAsync(serviceName, cancellationToken).ConfigureAwait(false);
            await _services.StartAndWaitAsync(serviceName, cancellationToken).ConfigureAwait(false);
        }
    }

    /// <summary>Shared by Repair's UI and the reset operation, before any database changes.</summary>
    public static string? Problem(ManagedPassword which, string password)
    {
        if (string.IsNullOrWhiteSpace(password))
        {
            return "Enter a new password.";
        }

        // .env is also read by python-dotenv, which strips quotes/comments and expands ${...}.
        // The updater strips boundary quotes too; embedded quotes are literal in both readers.
        // Keep values literal for every existing reader rather than changing the file format.
        if (password.Any(c => char.IsWhiteSpace(c) || char.IsControl(c)) ||
            password[0] is '\'' or '"' || password[^1] is '\'' or '"' ||
            password.Contains("${", StringComparison.Ordinal))
        {
            return "Use a password without whitespace, control characters, ${ sequences, or quotes at the start or end.";
        }

        if (password == CredentialManagerWriter.Sentinel)
        {
            return "Choose a password other than the reserved Credential Manager marker.";
        }

        if (which == ManagedPassword.Settings)
        {
            return PasswordPolicy.Evaluate(password).MeetsMinimum
                ? null
                : "Use at least 8 characters with 3 of: upper case, lower case, a digit, a symbol, and not a common password.";
        }

        return password.Length >= 12 ? null : "Use at least 12 characters for a database password.";
    }

    /// <summary>
    /// A password kept in Credential Manager lives in the vault of the account the RFQ service runs
    /// as. Written from another account it would land in that account's vault, where the service
    /// can never read it, so refuse instead of reporting success.
    /// </summary>
    private void EnsureStoreIsWritableHere(ManagedPassword which)
    {
        var (envKey, _, _) = Stores[which];
        if (!EnvFileReader.Read(_installPath).TryGetValue(envKey, out var current) || current != CredentialManagerWriter.Sentinel)
        {
            return;
        }

        var serviceAccount = _serviceAccountName();
        var serviceSid = string.IsNullOrWhiteSpace(serviceAccount) ? null : AccountIdentity.TryResolve(serviceAccount);
        if (serviceSid is null)
        {
            throw new InvalidOperationException(
                "This install keeps that password in Windows Credential Manager, but Setup can't verify which " +
                "Windows account owns it. Standalone installs have no RFQ Application service to identify the owner. " +
                "Reset was refused to avoid changing the database while leaving the app's saved password unchanged. Nothing was changed.");
        }

        if (IsCredentialOwner(serviceSid.Value, AccountIdentity.CurrentSid().Value))
        {
            return;
        }

        throw new InvalidOperationException(
            $"This install keeps that password in the Windows Credential Manager of {serviceAccount}, the account " +
            $"RFQ Application runs as, but Setup is running as {AccountIdentity.CurrentName()}. Sign in to Windows as " +
            $"{serviceAccount}, run Setup, choose Repair and reset it from there. Nothing was changed.");
    }

    internal static bool IsCredentialOwner(string? ownerSid, string currentSid) =>
        !string.IsNullOrWhiteSpace(ownerSid) && string.Equals(ownerSid, currentSid, StringComparison.OrdinalIgnoreCase);

    private static string? ServiceAccountName()
    {
        try
        {
            using var key = Registry.LocalMachine.OpenSubKey($@"SYSTEM\CurrentControlSet\Services\{AppServiceName}");
            return key?.GetValue("ObjectName") as string;
        }
        catch (Exception ex) when (ex is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            return null;
        }
    }

    /// <summary>Writes the new value where the install keeps that password now.</summary>
    internal void Store(ManagedPassword which, string newPassword)
    {
        var (envKey, target, userName) = Stores[which];
        var env = EnvFileReader.Read(_installPath);
        if (env.TryGetValue(envKey, out var current) && current == CredentialManagerWriter.Sentinel)
        {
            if (!CredentialManagerWriter.TryWrite(target, userName, newPassword))
            {
                throw new InvalidOperationException(
                    $"The new password is set in the database but couldn't be saved to Windows Credential Manager ({target}). " +
                    "Run Setup signed in as the Windows account RFQ Application runs as, and reset it again.");
            }
            return;
        }

        EnvFileWriter.Upsert(_installPath, new Dictionary<string, string> { [envKey] = newPassword });
    }

    private async Task ChangeDatabasePasswordAsync(string role, string newPassword, IProgress<string>? progress, CancellationToken cancellationToken)
    {
        var port = DatabasePort();
        var superUser = StoredCredentialsResolver.ResolveAll(_installPath).First(c => c.EnvKey == "SQL_SUPER_USER").Value;
        if (superUser is not null)
        {
            try
            {
                await AlterAsync(port, superUser, role, newPassword, cancellationToken).ConfigureAwait(false);
                return;
            }
            catch (PostgresException ex) when (ex.SqlState == PostgresErrorCodes.InvalidPassword)
            {
                progress?.Report("The stored postgres password doesn't work; resetting it through local access...");
            }
        }

        await WithTemporaryLocalTrustAsync(
                () => AlterAsync(port, password: null, role, newPassword, cancellationToken),
                progress,
                cancellationToken)
            .ConfigureAwait(false);
    }

    private int DatabasePort() =>
        EnvFileReader.Read(_installPath).TryGetValue("DB_PORT", out var raw) && int.TryParse(raw, out var port)
            ? port
            : PostgresBinariesConfig.DefaultPort;

    private static async Task AlterAsync(int port, string? password, string role, string newPassword, CancellationToken cancellationToken)
    {
        var builder = new NpgsqlConnectionStringBuilder
        {
            Host = "127.0.0.1",
            Port = port,
            Username = "postgres",
            Database = "postgres",
            Timeout = 15,
        };
        if (password is not null)
        {
            builder.Password = password;
        }

        await using var connection = new NpgsqlConnection(builder.ConnectionString);
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(60);
        while (true)
        {
            try
            {
                await connection.OpenAsync(cancellationToken).ConfigureAwait(false);
                break;
            }
            catch (PostgresException ex) when (ex.SqlState is "57P03" or "57P01" && DateTime.UtcNow < deadline)
            {
                // Still starting up after the restart.
                await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken).ConfigureAwait(false);
            }
        }
        await using var command = new NpgsqlCommand(
            $"ALTER USER \"{role.Replace("\"", "\"\"", StringComparison.Ordinal)}\" WITH PASSWORD " +
            "'" + newPassword.Replace("'", "''", StringComparison.Ordinal) + "'",
            connection);
        await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    /// <summary>
    /// Lets only the postgres login connect from this computer (127.0.0.1) without a password while
    /// <paramref name="action"/> runs, then restores pg_hba.conf byte for byte and restarts
    /// PostgreSQL, also when the action fails.
    /// </summary>
    internal async Task WithTemporaryLocalTrustAsync(Func<Task> action, IProgress<string>? progress, CancellationToken cancellationToken)
    {
        var hba = Path.Combine(_installPath, "pgdata", "pg_hba.conf");
        if (!File.Exists(hba))
        {
            throw new InvalidOperationException($"{hba} was not found, so the postgres password can't be reset.");
        }

        var original = await File.ReadAllBytesAsync(hba, cancellationToken).ConfigureAwait(false);
        try
        {
            await File.WriteAllTextAsync(hba, "host postgres postgres 127.0.0.1/32 trust\n", cancellationToken).ConfigureAwait(false);
            progress?.Report("Restarting PostgreSQL with temporary local access...");
            await RestartPostgresAsync(cancellationToken).ConfigureAwait(false);
            await action().ConfigureAwait(false);
        }
        finally
        {
            await File.WriteAllBytesAsync(hba, original, CancellationToken.None).ConfigureAwait(false);
            progress?.Report("Restoring PostgreSQL's normal access rules...");
            await RestartPostgresAsync(CancellationToken.None).ConfigureAwait(false);
        }
    }

    private async Task RestartPostgresAsync(CancellationToken cancellationToken)
    {
        await _services.StopIfExistsAsync(PostgresProvisioner.ServiceName, cancellationToken).ConfigureAwait(false);
        await _services.StartAndWaitAsync(PostgresProvisioner.ServiceName, cancellationToken, TimeSpan.FromSeconds(90))
            .ConfigureAwait(false);
        // RUNNING comes before PostgreSQL accepts connections; wait for that too.
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(60);
        while (true)
        {
            try
            {
                using var client = new System.Net.Sockets.TcpClient();
                await client.ConnectAsync("127.0.0.1", DatabasePort(), cancellationToken).ConfigureAwait(false);
                return;
            }
            catch (System.Net.Sockets.SocketException) when (DateTime.UtcNow < deadline)
            {
                await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken).ConfigureAwait(false);
            }
        }
    }
}
