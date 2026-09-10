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
            await connection.OpenAsync(cancellationToken).ConfigureAwait(false);

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
                await using var cmd = new NpgsqlCommand($"CREATE USER \"{AppUserName}\" WITH PASSWORD @p", connection);
                cmd.Parameters.AddWithValue("p", appUserPassword);
                await cmd.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
            }
            else
            {
                progress?.Report($"Updating password for '{AppUserName}'...");
                await using var cmd = new NpgsqlCommand($"ALTER USER \"{AppUserName}\" WITH PASSWORD @p", connection);
                cmd.Parameters.AddWithValue("p", appUserPassword);
                await cmd.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
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
        await dbConnection.OpenAsync(cancellationToken).ConfigureAwait(false);

        progress?.Report("Setting up schema permissions...");
        await ExecuteAsync(dbConnection, $"ALTER SCHEMA public OWNER TO \"{AppUserName}\"", cancellationToken).ConfigureAwait(false);
        await ExecuteAsync(dbConnection, $"GRANT USAGE, CREATE ON SCHEMA public TO \"{AppUserName}\"", cancellationToken).ConfigureAwait(false);
        await ExecuteAsync(dbConnection, $"GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO \"{AppUserName}\"", cancellationToken).ConfigureAwait(false);
        await ExecuteAsync(dbConnection, $"GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO \"{AppUserName}\"", cancellationToken).ConfigureAwait(false);
        await ExecuteAsync(dbConnection, $"ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO \"{AppUserName}\"", cancellationToken).ConfigureAwait(false);
        await ExecuteAsync(dbConnection, $"ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO \"{AppUserName}\"", cancellationToken).ConfigureAwait(false);
    }

    private static async Task ExecuteAsync(NpgsqlConnection connection, string sql, CancellationToken cancellationToken)
    {
        await using var cmd = new NpgsqlCommand(sql, connection);
        await cmd.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    private static async Task<bool> ScalarBoolAsync(NpgsqlConnection connection, string sql, (string Name, object Value) param, CancellationToken cancellationToken)
    {
        await using var cmd = new NpgsqlCommand(sql, connection);
        cmd.Parameters.AddWithValue(param.Name, param.Value);
        var result = await cmd.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
        return result is not null;
    }
}
