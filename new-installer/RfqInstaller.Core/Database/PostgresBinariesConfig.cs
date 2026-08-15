namespace RfqInstaller.Core.Database;

/// <summary>
/// Pins the exact portable PostgreSQL "binaries zip" the installer downloads (from
/// https://www.enterprisedb.com/download-postgresql-binaries or a mirror you control) so it never
/// depends on a system-wide PostgreSQL install or PATH. There is no safe built-in default here —
/// like <see cref="Networking.LicenseBrokerClient.BaseUrl"/>, this must be verified and pinned by
/// the team before shipping a build (URL, exact version, and SHA-256 of the zip you tested with).
/// </summary>
public static class PostgresBinariesConfig
{
    public static string Version { get; set; } = "16.4-1";
    public static string DownloadUrl { get; set; } =
        Environment.GetEnvironmentVariable("RFQ_POSTGRES_BINARIES_URL")
        ?? "https://REPLACE-ME/postgresql-16.4-1-windows-x64-binaries.zip";
    public static string? Sha256 { get; set; } =
        Environment.GetEnvironmentVariable("RFQ_POSTGRES_BINARIES_SHA256");

    /// <summary>Dedicated port for the app's own PostgreSQL instance, distinct from the PostgreSQL default (5432) to avoid clashing with any pre-existing system install.</summary>
    public const int DefaultPort = 55432;
}
