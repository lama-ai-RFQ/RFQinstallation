using Npgsql;

namespace RfqInstaller.Core.Database;

/// <summary>
/// Creates the rfq_db database, rfq_user role, and grants — a native-C# port of
/// setup_database_auto.ps1's SQL (same statements, same idempotency: safe to re-run, existing
/// user gets its password updated rather than failing). Uses Npgsql directly instead of shelling
/// out to psql.exe, so there's no PATH dependency and no console window.
/// </summary>
public static class DatabaseSetup
{
    public const string DatabaseName = "rfq_db";
    public const string AppUserName = "rfq_user";

    public static async Task EnsureDatabaseAndUserAsync(
        int port,
        string superUserPassword,
        string appUserPassword,
        IProgress<string>? progress,
        CancellationToken cancellationToken)
    {
        var maintenanceConnString = new NpgsqlConnectionStringBuilder
        {
            Host = "127.0.0.1",
            Port = port,
            Username = "postgres",
            Password = superUserPassword,
            Database = "postgres",
        }.ConnectionString;

        await using (var connection = new NpgsqlConnection(maintenanceConnString))
        {
            try
            {
                await OpenWhenReadyAsync(connection, progress, cancellationToken).ConfigureAwait(false);
            }
            catch (PostgresException ex) when (ex.SqlState == PostgresErrorCodes.InvalidPassword)
            {
                throw new InvalidOperationException(
                    "PostgreSQL is running, but the stored postgres superuser password does not match this database cluster. " +
                    "Restore the password originally used to initialize pgdata, or delete pgdata if this is a disposable failed install.",
                    ex);
            }

            var dbExists = await ScalarBoolAsync(connection, "SELECT 1 FROM pg_database WHERE datname = @n", ("n", DatabaseName), cancellationToken)
                .ConfigureAwait(false);
            if (!dbExists)
            {
                progress?.Report($"Creating database '{DatabaseName}'...");
                await ExecuteAsync(connection, $"CREATE DATABASE \"{DatabaseName}\"", cancellationToken).ConfigureAwait(false);
            }

            var userExists = await ScalarBoolAsync(connection, "SELECT 1 FROM pg_roles WHERE rolname = @n", ("n", AppUserName), cancellationToken)
                .ConfigureAwait(false);
            if (!userExists)
            {
                progress?.Report($"Creating database user '{AppUserName}'...");
                await ExecuteAsync(
                    connection,
                    $"CREATE USER \"{AppUserName}\" WITH PASSWORD {QuoteLiteral(appUserPassword)}",
                    cancellationToken).ConfigureAwait(false);
            }
            else
            {
                progress?.Report($"Updating password for '{AppUserName}'...");
                await ExecuteAsync(
                    connection,
                    $"ALTER USER \"{AppUserName}\" WITH PASSWORD {QuoteLiteral(appUserPassword)}",
                    cancellationToken).ConfigureAwait(false);
            }

            await ExecuteAsync(connection, $"GRANT ALL PRIVILEGES ON DATABASE \"{DatabaseName}\" TO \"{AppUserName}\"", cancellationToken)
                .ConfigureAwait(false);
        }

        var dbConnString = new NpgsqlConnectionStringBuilder
        {
            Host = "127.0.0.1",
            Port = port,
            Username = "postgres",
            Password = superUserPassword,
            Database = DatabaseName,
        }.ConnectionString;

        await using var dbConnection = new NpgsqlConnection(dbConnString);
        await OpenWhenReadyAsync(dbConnection, progress, cancellationToken).ConfigureAwait(false);

        progress?.Report("Setting up schema permissions...");
        await ExecuteAsync(dbConnection, $"ALTER SCHEMA public OWNER TO \"{AppUserName}\"", cancellationToken).ConfigureAwait(false);
        await ExecuteAsync(dbConnection, $"GRANT USAGE, CREATE ON SCHEMA public TO \"{AppUserName}\"", cancellationToken).ConfigureAwait(false);
        await ExecuteAsync(dbConnection, $"GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO \"{AppUserName}\"", cancellationToken).ConfigureAwait(false);
        await ExecuteAsync(dbConnection, $"GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO \"{AppUserName}\"", cancellationToken).ConfigureAwait(false);
        await ExecuteAsync(dbConnection, $"ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO \"{AppUserName}\"", cancellationToken).ConfigureAwait(false);
        await ExecuteAsync(dbConnection, $"ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO \"{AppUserName}\"", cancellationToken).ConfigureAwait(false);
    }

    private static async Task OpenWhenReadyAsync(
        NpgsqlConnection connection,
        IProgress<string>? progress,
        CancellationToken cancellationToken)
    {
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(90);
        Exception? lastError = null;
        var attempt = 0;
        while (DateTime.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                await connection.OpenAsync(cancellationToken).ConfigureAwait(false);
                return;
            }
            catch (Exception ex) when (IsStartupRace(ex))
            {
                lastError = ex;
                attempt++;
                progress?.Report($"Waiting for PostgreSQL to finish starting ({attempt})...");
                await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken).ConfigureAwait(false);
            }
        }

        throw new InvalidOperationException(
            "PostgreSQL did not finish starting in time.",
            lastError);
    }

    private static bool IsStartupRace(Exception exception)
    {
        // A server-originated error proves PostgreSQL is already accepting connections. Only its
        // explicit startup/shutdown states are retryable; authentication and configuration errors
        // must surface immediately instead of being mislabeled as a 90-second startup timeout.
        var postgresError = FindPostgresException(exception);
        if (postgresError is not null)
        {
            return postgresError.SqlState is "57P03" or "57P01";
        }

        for (var current = exception; current is not null; current = current.InnerException)
        {
            if (current is NpgsqlException or System.Net.Sockets.SocketException)
            {
                return true;
            }
        }

        return false;
    }

    private static PostgresException? FindPostgresException(Exception exception)
    {
        for (var current = exception; current is not null; current = current.InnerException)
        {
            if (current is PostgresException postgres)
            {
                return postgres;
            }
        }

        return null;
    }

    private static async Task ExecuteAsync(NpgsqlConnection connection, string sql, CancellationToken cancellationToken)
    {
        await using var cmd = new NpgsqlCommand(sql, connection);
        await cmd.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    /// <summary>
    /// CREATE/ALTER USER cannot take bind parameters for PASSWORD. Escape as a SQL string literal
    /// the same way the old setup_database_auto.ps1 script did.
    /// </summary>
    private static string QuoteLiteral(string value)
    {
        ArgumentNullException.ThrowIfNull(value);
        return "'" + value.Replace("'", "''", StringComparison.Ordinal) + "'";
    }

    private static async Task<bool> ScalarBoolAsync(NpgsqlConnection connection, string sql, (string Name, object Value) param, CancellationToken cancellationToken)
    {
        await using var cmd = new NpgsqlCommand(sql, connection);
        cmd.Parameters.AddWithValue(param.Name, param.Value);
        var result = await cmd.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
        return result is not null;
    }
}
