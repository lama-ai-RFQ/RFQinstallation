namespace RfqInstaller.Core.Database;

/// <summary>
/// Pins the portable PostgreSQL binaries zip the installer provisions under
/// <c>{install}\pgsql</c>. Production downloads go through the license broker as
/// <see cref="RuntimeAssetId"/>; <see cref="DownloadUrl"/> is only an override
/// for local/sandbox testing.
/// </summary>
public static class PostgresBinariesConfig
{
    public const string RuntimeAssetId = "postgres.windows.binaries";

    public static string Version { get; set; } = "16.15-3";

    public static string? DownloadUrl { get; set; } =
        Environment.GetEnvironmentVariable("RFQ_POSTGRES_BINARIES_URL");

    public static string? Sha256 { get; set; } =
        Environment.GetEnvironmentVariable("RFQ_POSTGRES_BINARIES_SHA256");

    /// <summary>Dedicated port for the app's own PostgreSQL instance, distinct from the PostgreSQL default (5432) to avoid clashing with any pre-existing system install.</summary>
    public const int DefaultPort = 55432;
}
