using System.Text.Json.Serialization;

namespace RfqInstaller.Core.Models;

/// <summary>Result of the fully-offline RSA-signature check against the bundled public key (fast UI feedback only — the broker call is the source of truth for entitlements/config).</summary>
public class LocalLicenseCheck
{
    public bool SignatureValid { get; init; }
    public bool Expired { get; init; }
    public string? CustomerId { get; init; }
    public DateOnly? ExpirationDate { get; init; }
    public string Message { get; init; } = string.Empty;
    public Dictionary<string, bool> Features { get; init; } = new();
    public Dictionary<string, int> Limits { get; init; } = new();
}

/// <summary>One downloadable piece of the release (matches local_manifest.json's per-component "files" entries, e.g. app-executable / core-dependencies / assets).</summary>
public sealed class PackageComponent
{
    public required string Name { get; init; }
    public required string Url { get; init; }
    public long SizeBytes { get; init; }
    public string? Sha256 { get; init; }
}

public sealed class ActivationResult
{
    [JsonPropertyName("token_type")]
    public required string TokenType { get; init; }

    [JsonPropertyName("expires_in")]
    public int ExpiresIn { get; init; }

    [JsonPropertyName("refresh_expires_in")]
    public int RefreshExpiresIn { get; init; }

    [JsonPropertyName("device_id")]
    public required string DeviceId { get; init; }
}

internal sealed class BrokerTokenResponse
{
    [JsonPropertyName("access_token")]
    public string AccessToken { get; init; } = string.Empty;

    [JsonPropertyName("token_type")]
    public string TokenType { get; init; } = string.Empty;

    [JsonPropertyName("expires_in")]
    public int ExpiresIn { get; init; }

    [JsonPropertyName("refresh_token")]
    public string RefreshToken { get; init; } = string.Empty;

    [JsonPropertyName("refresh_expires_in")]
    public int RefreshExpiresIn { get; init; }

    [JsonPropertyName("device_id")]
    public string DeviceId { get; init; } = string.Empty;
}

public sealed class ReleaseArtifact
{
    [JsonPropertyName("artifact_id")]
    public required string ArtifactId { get; init; }

    [JsonPropertyName("name")]
    public required string Name { get; init; }

    [JsonPropertyName("size")]
    public long Size { get; init; }

    [JsonPropertyName("sha256")]
    public required string Sha256 { get; init; }

    [JsonPropertyName("content_type")]
    public string? ContentType { get; init; }
}

public sealed class WindowsRelease
{
    [JsonPropertyName("schema_version")]
    public int SchemaVersion { get; init; }

    [JsonPropertyName("release_id")]
    public required string ReleaseId { get; init; }

    [JsonPropertyName("channel")]
    public required string Channel { get; init; }

    [JsonPropertyName("platform")]
    public required string Platform { get; init; }

    [JsonPropertyName("version")]
    public required string Version { get; init; }

    [JsonPropertyName("published_at")]
    public DateTimeOffset? PublishedAt { get; init; }

    [JsonPropertyName("artifacts")]
    public List<ReleaseArtifact> Artifacts { get; init; } = new();
}

public sealed class SignedArtifact
{
    [JsonPropertyName("artifact_id")]
    public required string ArtifactId { get; init; }

    [JsonPropertyName("url")]
    public required string Url { get; init; }

    [JsonPropertyName("size")]
    public long Size { get; init; }

    [JsonPropertyName("sha256")]
    public required string Sha256 { get; init; }

    /// <summary>Unix timestamp supplied by the broker.</summary>
    [JsonPropertyName("expires_at")]
    public long ExpiresAt { get; init; }
}

public sealed class SignedArtifactResponse
{
    [JsonPropertyName("release_id")]
    public string? ReleaseId { get; init; }

    [JsonPropertyName("artifacts")]
    public List<SignedArtifact> Artifacts { get; init; } = new();
}

public sealed class SignedWindowsRelease
{
    public required WindowsRelease Release { get; init; }
    public required IReadOnlyList<SignedArtifact> Artifacts { get; init; }
}

/// <summary>
/// Compatibility projection consumed by the current InstallOrchestrator. New
/// integrations should use SignedWindowsRelease directly.
/// </summary>
public sealed class BrokerResponse
{
    public bool Valid { get; init; }
    public string Message { get; init; } = string.Empty;

    public string? CustomerId { get; init; }
    public DateTimeOffset? ExpiresAtUtc { get; init; }
    public Dictionary<string, bool> Features { get; init; } = new();
    public Dictionary<string, int> Limits { get; init; } = new();

    /// <summary>Pre-signed HTTPS URLs for each release component archive (app-executable, core-dependencies, assets, ...).</summary>
    public List<PackageComponent> Components { get; init; } = new();

    public string? DefaultServerUrl { get; init; }
    public string? UpdateChannel { get; init; }

    /// <summary>How long the returned URLs remain valid; the client should not cache/reuse them past this.</summary>
    public DateTimeOffset? UrlsExpireAtUtc { get; init; }
}
