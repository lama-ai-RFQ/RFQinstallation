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

public class ModelFileEntry
{
    public required string RelativePath { get; init; }
    public required string Url { get; init; }
    public long SizeBytes { get; init; }
}

/// <summary>One downloadable piece of the release (matches local_manifest.json's per-component "files" entries, e.g. app-executable / core-dependencies / assets).</summary>
public class PackageComponent
{
    public required string Name { get; init; }
    public required string Url { get; init; }
    public long SizeBytes { get; init; }
    public string? Sha256 { get; init; }
}

/// <summary>Response from the license-broker HTTPS API: validates the key and hands back short-lived, scoped download URLs plus install-time config — replacing what used to be a manually-typed GitHub token + AWS key/secret/region.</summary>
public class BrokerResponse
{
    public bool Valid { get; init; }
    public string Message { get; init; } = string.Empty;

    public string? CustomerId { get; init; }
    public DateTimeOffset? ExpiresAtUtc { get; init; }
    public Dictionary<string, bool> Features { get; init; } = new();
    public Dictionary<string, int> Limits { get; init; } = new();

    /// <summary>Pre-signed HTTPS URLs for each release component archive (app-executable, core-dependencies, assets, ...).</summary>
    public List<PackageComponent> Components { get; init; } = new();
    /// <summary>Pre-signed HTTPS URLs for each LLM model file, if the license entitles model download.</summary>
    public List<ModelFileEntry> ModelFiles { get; init; } = new();

    public string? DefaultServerUrl { get; init; }
    public string? UpdateChannel { get; init; }

    /// <summary>How long the returned URLs remain valid; the client should not cache/reuse them past this.</summary>
    public DateTimeOffset? UrlsExpireAtUtc { get; init; }
}
