using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using RfqInstaller.Core.Licensing;
using RfqInstaller.Core.Models;

namespace RfqInstaller.Core.Networking;

/// <summary>
/// Native client for activation, refresh-token rotation, release discovery, and
/// exact-object download signing. Access tokens are intentionally memory-only.
/// </summary>
public sealed class LicenseBrokerClient : IDisposable
{
    private const string DefaultBaseUrl = "https://license-api.scint.ai";
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private static readonly Regex LogicalIdPattern = new(
        "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$",
        RegexOptions.CultureInvariant);
    private static readonly Regex Sha256Pattern = new(
        "^[0-9a-f]{64}$",
        RegexOptions.CultureInvariant);
    private static readonly Regex SensitiveValuePattern = new(
        @"(?i)(Bearer\s+|(?:access_token|refresh_token|license_key|url)\s*[=:]\s*)[^\s,;""']+",
        RegexOptions.CultureInvariant);

    private readonly HttpClient _http;
    private readonly bool _ownsHttpClient;
    private readonly Uri _baseUri;
    private readonly ILicenseCredentialStore _store;
    private readonly int _maxAttempts;
    private readonly TimeProvider _timeProvider;
    private readonly object _accessLock = new();
    private string? _accessToken;
    private DateTimeOffset _accessExpiresAt;

    public LicenseBrokerClient(
        HttpClient? httpClient = null,
        string? baseUrl = null,
        ILicenseCredentialStore? credentialStore = null,
        int maxAttempts = 4,
        TimeProvider? timeProvider = null)
    {
        var configuredUrl = string.IsNullOrWhiteSpace(baseUrl)
            ? Environment.GetEnvironmentVariable("RFQ_LICENSE_BROKER_URL")
            : baseUrl;
        configuredUrl = string.IsNullOrWhiteSpace(configuredUrl) ? DefaultBaseUrl : configuredUrl;
        if (!Uri.TryCreate(configuredUrl.TrimEnd('/') + "/", UriKind.Absolute, out var parsedBaseUri) ||
            parsedBaseUri.Scheme != Uri.UriSchemeHttps ||
            string.IsNullOrWhiteSpace(parsedBaseUri.Host) ||
            !string.IsNullOrEmpty(parsedBaseUri.UserInfo) ||
            !string.IsNullOrEmpty(parsedBaseUri.Query) ||
            !string.IsNullOrEmpty(parsedBaseUri.Fragment))
        {
            throw new ArgumentException("Broker base URL must be an absolute HTTPS URL.", nameof(baseUrl));
        }
        _baseUri = parsedBaseUri;
        if (maxAttempts is < 1 or > 8)
        {
            throw new ArgumentOutOfRangeException(nameof(maxAttempts), "maxAttempts must be between 1 and 8.");
        }

        _http = httpClient ?? new HttpClient();
        _ownsHttpClient = httpClient is null;
        _store = credentialStore ?? new WindowsDpapiCredentialStore();
        _maxAttempts = maxAttempts;
        _timeProvider = timeProvider ?? TimeProvider.System;
    }

    public async Task<ActivationResult> ActivateAsync(
        string licenseKey,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(licenseKey);
        using var storeLock = await _store.AcquireLockAsync(cancellationToken).ConfigureAwait(false);
        var state = _store.Load();
        if (state is null)
        {
            state = CreateDeviceState();
            _store.Save(state);
        }

        var timestamp = _timeProvider.GetUtcNow().ToUnixTimeSeconds();
        var licenseHash = Sha256Hex(Encoding.UTF8.GetBytes(licenseKey));
        var message = Encoding.UTF8.GetBytes(
            $"rfq-license-broker-activation:v1\n{licenseHash}\n{timestamp}");
        var request = new Dictionary<string, object>
        {
            ["license_key"] = licenseKey,
            ["device_public_key"] = GetPublicKeyPem(state),
            ["timestamp"] = timestamp,
            ["device_proof"] = Sign(state, message),
        };
        var tokenPair = await RequestAsync<BrokerTokenResponse>(
            HttpMethod.Post,
            "v1/activations",
            request,
            bearerToken: null,
            idempotencyKey: $"{state.DeviceUuid}:{licenseHash}",
            retryable: true,
            cancellationToken).ConfigureAwait(false);
        RememberTokenPair(tokenPair, state);
        return new ActivationResult
        {
            TokenType = tokenPair.TokenType,
            ExpiresIn = tokenPair.ExpiresIn,
            RefreshExpiresIn = tokenPair.RefreshExpiresIn,
            DeviceId = tokenPair.DeviceId,
        };
    }

    public Task<WindowsRelease> GetLatestWindowsReleaseAsync(
        string channel,
        CancellationToken cancellationToken = default)
    {
        ValidateLogicalId(channel, nameof(channel));
        return AuthorizedRequestAsync<WindowsRelease>(
            HttpMethod.Get,
            $"v1/releases/windows/{Uri.EscapeDataString(channel)}/latest",
            body: null,
            retryable: true,
            cancellationToken);
    }

    public async Task<SignedArtifactResponse> SignReleaseAsync(
        string releaseId,
        IEnumerable<string> artifactIds,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(releaseId);
        ArgumentNullException.ThrowIfNull(artifactIds);
        var ids = artifactIds.ToArray();
        if (ids.Length is < 1 or > 32 || ids.Distinct(StringComparer.Ordinal).Count() != ids.Length)
        {
            throw new ArgumentException("Between 1 and 32 unique artifact IDs are required.", nameof(artifactIds));
        }
        foreach (var id in ids)
        {
            ValidateLogicalId(id, nameof(artifactIds));
        }

        var response = await AuthorizedRequestAsync<SignedArtifactResponse>(
            HttpMethod.Post,
            "v1/downloads/sign",
            new Dictionary<string, object>
            {
                ["release_id"] = releaseId,
                ["artifact_ids"] = ids,
            },
            retryable: true,
            cancellationToken).ConfigureAwait(false);
        ValidateSignedArtifacts(response, releaseId, ids);
        return response;
    }

    public async Task<SignedArtifactResponse> SignRuntimeAssetsAsync(
        IEnumerable<string> assetIds,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(assetIds);
        var ids = assetIds.ToArray();
        if (ids.Length is < 1 or > 32 || ids.Distinct(StringComparer.Ordinal).Count() != ids.Length)
        {
            throw new ArgumentException("Between 1 and 32 unique runtime asset IDs are required.", nameof(assetIds));
        }
        foreach (var id in ids)
        {
            ValidateLogicalId(id, nameof(assetIds));
        }

        var response = await AuthorizedRequestAsync<SignedArtifactResponse>(
            HttpMethod.Post,
            "v1/downloads/sign",
            new Dictionary<string, object>
            {
                ["runtime_asset_ids"] = ids,
            },
            retryable: true,
            cancellationToken).ConfigureAwait(false);
        ValidateSignedArtifacts(response, expectedReleaseId: null, ids);
        return response;
    }

    public async Task<SignedWindowsRelease> ActivateAndGetSignedWindowsReleaseAsync(
        string licenseKey,
        string channel = "customer",
        CancellationToken cancellationToken = default)
    {
        await ActivateAsync(licenseKey, cancellationToken).ConfigureAwait(false);
        var release = await GetLatestWindowsReleaseAsync(channel, cancellationToken).ConfigureAwait(false);
        ValidateRelease(release, channel);
        var signed = await SignReleaseAsync(
            release.ReleaseId,
            release.Artifacts.Select(artifact => artifact.ArtifactId),
            cancellationToken).ConfigureAwait(false);
        return new SignedWindowsRelease { Release = release, Artifacts = signed.Artifacts };
    }

    /// <summary>
    /// Compatibility adapter for the unchanged InstallOrchestrator.
    /// </summary>
    public async Task<BrokerResponse> ValidateAndIssueAsync(
        string licenseKey,
        CancellationToken cancellationToken = default)
    {
        try
        {
            var signed = await ActivateAndGetSignedWindowsReleaseAsync(
                licenseKey,
                "customer",
                cancellationToken).ConfigureAwait(false);
            var releaseArtifacts = signed.Release.Artifacts.ToDictionary(
                artifact => artifact.ArtifactId,
                StringComparer.Ordinal);
            var components = signed.Artifacts
                .Where(artifact =>
                    releaseArtifacts.TryGetValue(artifact.ArtifactId, out var metadata) &&
                    metadata.Name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase))
                .Select(artifact => new PackageComponent
                {
                    Name = artifact.ArtifactId,
                    Url = artifact.Url,
                    SizeBytes = artifact.Size,
                    Sha256 = artifact.Sha256,
                }).ToList();
            if (components.Count == 0)
            {
                throw new BrokerClientException("The Windows release contains no installable ZIP components.");
            }
            return new BrokerResponse
            {
                Valid = true,
                Message = "License activated.",
                UpdateChannel = signed.Release.Channel,
                UrlsExpireAtUtc = signed.Artifacts.Count == 0
                    ? null
                    : DateTimeOffset.FromUnixTimeSeconds(signed.Artifacts.Min(artifact => artifact.ExpiresAt)),
                Components = components,
            };
        }
        catch (BrokerClientException ex)
        {
            return new BrokerResponse
            {
                Valid = false,
                Message = ex.Message,
            };
        }
    }

    private async Task<T> AuthorizedRequestAsync<T>(
        HttpMethod method,
        string path,
        object? body,
        bool retryable,
        CancellationToken cancellationToken)
    {
        var token = await GetAccessTokenAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return await RequestAsync<T>(
                method, path, body, token, null, retryable, cancellationToken).ConfigureAwait(false);
        }
        catch (BrokerClientException ex) when (ex.StatusCode == HttpStatusCode.Unauthorized)
        {
            ClearAccessToken(token);
            token = await GetAccessTokenAsync(cancellationToken).ConfigureAwait(false);
            return await RequestAsync<T>(
                method, path, body, token, null, retryable, cancellationToken).ConfigureAwait(false);
        }
    }

    private async Task<string> GetAccessTokenAsync(CancellationToken cancellationToken)
    {
        lock (_accessLock)
        {
            if (_accessToken is not null &&
                _timeProvider.GetUtcNow().AddSeconds(30) < _accessExpiresAt)
            {
                return _accessToken;
            }
        }

        using var storeLock = await _store.AcquireLockAsync(cancellationToken).ConfigureAwait(false);
        lock (_accessLock)
        {
            if (_accessToken is not null &&
                _timeProvider.GetUtcNow().AddSeconds(30) < _accessExpiresAt)
            {
                return _accessToken;
            }
        }

        var state = _store.Load();
        if (state?.RefreshToken is null)
        {
            throw new CredentialStoreException("This device has not been activated.");
        }
        if (state.RefreshPendingGeneration is not null)
        {
            throw new CredentialStoreException(
                "A previous refresh has an unknown outcome; refusing to replay it. Reactivate this device.");
        }

        cancellationToken.ThrowIfCancellationRequested();
        var refreshToken = state.RefreshToken;
        var timestamp = _timeProvider.GetUtcNow().ToUnixTimeSeconds();
        var message = Encoding.UTF8.GetBytes(
            $"rfq-license-broker-token:v1\n{refreshToken}\n{timestamp}");
        var request = new Dictionary<string, object>
        {
            ["refresh_token"] = refreshToken,
            ["timestamp"] = timestamp,
            ["device_proof"] = Sign(state, message),
        };
        state.RefreshPendingGeneration = state.RefreshGeneration + 1;
        _store.Save(state);

        // Refresh tokens are single-use. Never retry an ambiguous transport outcome.
        var tokenPair = await RequestAsync<BrokerTokenResponse>(
            HttpMethod.Post,
            "v1/tokens",
            request,
            bearerToken: null,
            idempotencyKey: null,
            retryable: false,
            cancellationToken).ConfigureAwait(false);
        state.RefreshPendingGeneration = null;
        RememberTokenPair(tokenPair, state);
        lock (_accessLock)
        {
            return _accessToken!;
        }
    }

    private async Task<T> RequestAsync<T>(
        HttpMethod method,
        string path,
        object? body,
        string? bearerToken,
        string? idempotencyKey,
        bool retryable,
        CancellationToken cancellationToken)
    {
        var attempts = retryable ? _maxAttempts : 1;
        for (var attempt = 0; attempt < attempts; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            using var request = new HttpRequestMessage(method, new Uri(_baseUri, path));
            request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
            if (bearerToken is not null)
            {
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", bearerToken);
            }
            if (idempotencyKey is not null)
            {
                request.Headers.TryAddWithoutValidation("Idempotency-Key", idempotencyKey);
            }
            if (body is not null)
            {
                request.Content = new StringContent(
                    JsonSerializer.Serialize(body, JsonOptions),
                    Encoding.UTF8,
                    "application/json");
            }

            HttpResponseMessage response;
            try
            {
                response = await _http.SendAsync(
                    request,
                    HttpCompletionOption.ResponseHeadersRead,
                    cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested && attempt + 1 < attempts)
            {
                await DelayAsync(attempt, null, cancellationToken).ConfigureAwait(false);
                continue;
            }
            catch (HttpRequestException) when (attempt + 1 < attempts)
            {
                await DelayAsync(attempt, null, cancellationToken).ConfigureAwait(false);
                continue;
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                throw new BrokerClientException(
                    $"Broker transport timed out for {method} {path} on {_baseUri.Host}.",
                    method: method.Method,
                    path: path,
                    host: _baseUri.Host);
            }
            catch (HttpRequestException ex)
            {
                throw new BrokerClientException(
                    FormatTransportFailure(method, path, ex),
                    method: method.Method,
                    path: path,
                    host: _baseUri.Host,
                    innerException: ex);
            }

            using (response)
            {
                if (IsTransient(response.StatusCode) && attempt + 1 < attempts)
                {
                    await DelayAsync(attempt, response, cancellationToken).ConfigureAwait(false);
                    continue;
                }
                if (!response.IsSuccessStatusCode)
                {
                    throw await CreateResponseExceptionAsync(method, path, response, cancellationToken)
                        .ConfigureAwait(false);
                }
                try
                {
                    await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
                    var value = await JsonSerializer.DeserializeAsync<T>(
                        stream,
                        JsonOptions,
                        cancellationToken).ConfigureAwait(false);
                    return value ?? throw new BrokerClientException(
                        $"Broker returned an empty JSON response for {method} {path} on {_baseUri.Host}.",
                        method: method.Method,
                        path: path,
                        host: _baseUri.Host);
                }
                catch (JsonException ex)
                {
                    throw new BrokerClientException(
                        $"Broker returned malformed JSON for {method} {path} on {_baseUri.Host}.",
                        method: method.Method,
                        path: path,
                        host: _baseUri.Host,
                        innerException: ex);
                }
            }
        }
        throw new BrokerClientException(
            $"Broker request attempts were exhausted for {method} {path} on {_baseUri.Host}.",
            method: method.Method,
            path: path,
            host: _baseUri.Host);
    }

    private async Task<BrokerClientException> CreateResponseExceptionAsync(
        HttpMethod method,
        string path,
        HttpResponseMessage response,
        CancellationToken cancellationToken)
    {
        var status = (int)response.StatusCode;
        var detail = $"Broker returned HTTP {status}.";
        string? code = null;
        string? requestId = null;
        try
        {
            await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            var problem = await JsonSerializer.DeserializeAsync<ProblemResponse>(
                stream,
                JsonOptions,
                cancellationToken).ConfigureAwait(false);
            if (!string.IsNullOrWhiteSpace(problem?.Detail))
            {
                detail = problem.Detail;
            }
            code = problem?.Code;
            requestId = problem?.RequestId;
        }
        catch (JsonException)
        {
            // Fall back to the status-only error; never include an arbitrary response body.
        }

        var message = new StringBuilder()
            .Append("License broker request failed.")
            .Append(" Host=").Append(_baseUri.Host)
            .Append(" Request=").Append(method.Method).Append(' ').Append(path)
            .Append(" HTTP=").Append(status);
        if (!string.IsNullOrWhiteSpace(code))
        {
            message.Append(" Code=").Append(Redact(code));
        }
        if (!string.IsNullOrWhiteSpace(requestId))
        {
            message.Append(" RequestId=").Append(Redact(requestId));
        }
        message.Append(" Detail=").Append(Redact(detail));
        return new BrokerClientException(
            message.ToString(),
            response.StatusCode,
            code is null ? null : Redact(code),
            method: method.Method,
            path: path,
            host: _baseUri.Host,
            requestId: requestId is null ? null : Redact(requestId));
    }

    private string FormatTransportFailure(HttpMethod method, string path, HttpRequestException ex)
    {
        var cause = ex.InnerException?.Message ?? ex.Message;
        return Redact(
            $"License broker transport failed. Host={_baseUri.Host} Request={method.Method} {path} " +
            $"Error={ex.HttpRequestError} Detail={cause}");
    }

    private void RememberTokenPair(BrokerTokenResponse tokenPair, DeviceCredentialState state)
    {
        if (string.IsNullOrWhiteSpace(tokenPair.AccessToken) ||
            string.IsNullOrWhiteSpace(tokenPair.RefreshToken) ||
            string.IsNullOrWhiteSpace(tokenPair.DeviceId) ||
            tokenPair.TokenType != "Bearer" ||
            tokenPair.ExpiresIn <= 0 ||
            tokenPair.RefreshExpiresIn <= 0)
        {
            throw new BrokerClientException("Broker token response is incomplete or invalid.");
        }

        state.RefreshToken = tokenPair.RefreshToken;
        state.RefreshGeneration++;
        state.RefreshPendingGeneration = null;
        state.BrokerDeviceId = tokenPair.DeviceId;
        _store.Save(state);
        lock (_accessLock)
        {
            _accessToken = tokenPair.AccessToken;
            _accessExpiresAt = _timeProvider.GetUtcNow().AddSeconds(tokenPair.ExpiresIn);
        }
    }

    private static DeviceCredentialState CreateDeviceState()
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        return new DeviceCredentialState
        {
            DeviceUuid = Guid.NewGuid().ToString(),
            DevicePrivateKey = key.ExportPkcs8PrivateKeyPem(),
            RefreshGeneration = 0,
        };
    }

    private static string GetPublicKeyPem(DeviceCredentialState state)
    {
        using var key = ImportPrivateKey(state);
        return key.ExportSubjectPublicKeyInfoPem();
    }

    private static string Sign(DeviceCredentialState state, byte[] message)
    {
        using var key = ImportPrivateKey(state);
        var signature = key.SignData(
            message,
            HashAlgorithmName.SHA256,
            DSASignatureFormat.Rfc3279DerSequence);
        return Convert.ToBase64String(signature).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    }

    private static ECDsa ImportPrivateKey(DeviceCredentialState state)
    {
        ECDsa? key = null;
        try
        {
            key = ECDsa.Create();
            key.ImportFromPem(state.DevicePrivateKey);
            if (key.KeySize != 256)
            {
                throw new CryptographicException("Stored device key is not P-256.");
            }
            return key;
        }
        catch (Exception ex) when (ex is ArgumentException or CryptographicException)
        {
            key?.Dispose();
            throw new CredentialStoreException("Stored device key is invalid.", ex);
        }
    }

    private static string Sha256Hex(byte[] value) =>
        Convert.ToHexString(SHA256.HashData(value)).ToLowerInvariant();

    private static void ValidateRelease(WindowsRelease release, string requestedChannel)
    {
        if (release.SchemaVersion != 1 ||
            release.Platform != "windows" ||
            release.Channel != requestedChannel ||
            string.IsNullOrWhiteSpace(release.ReleaseId) ||
            !LogicalIdPattern.IsMatch(release.Version) ||
            release.ReleaseId != $"{requestedChannel}:windows:{release.Version}" ||
            release.Artifacts.Count == 0 ||
            release.Artifacts.Any(artifact =>
                !LogicalIdPattern.IsMatch(artifact.ArtifactId) ||
                string.IsNullOrWhiteSpace(artifact.Name) ||
                artifact.Size <= 0 ||
                !Sha256Pattern.IsMatch(artifact.Sha256)))
        {
            throw new BrokerClientException("Broker returned an invalid Windows release catalog.");
        }
    }

    private static void ValidateSignedArtifacts(
        SignedArtifactResponse response,
        string? expectedReleaseId,
        IReadOnlyCollection<string> requestedIds)
    {
        var releaseIdMatches = expectedReleaseId is null
            ? string.IsNullOrEmpty(response.ReleaseId)
            : response.ReleaseId == expectedReleaseId;
        if (!releaseIdMatches ||
            response.Artifacts.Count != requestedIds.Count ||
            response.Artifacts.Select(artifact => artifact.ArtifactId)
                .ToHashSet(StringComparer.Ordinal)
                .SetEquals(requestedIds) == false ||
            response.Artifacts.Any(artifact =>
                !Uri.TryCreate(artifact.Url, UriKind.Absolute, out var uri) ||
                uri.Scheme != Uri.UriSchemeHttps ||
                artifact.Size <= 0 ||
                artifact.ExpiresAt <= 0 ||
                !Sha256Pattern.IsMatch(artifact.Sha256)))
        {
            throw new BrokerClientException("Broker returned invalid signed artifact metadata.");
        }
    }

    private static void ValidateLogicalId(string value, string parameterName)
    {
        if (string.IsNullOrWhiteSpace(value) || !LogicalIdPattern.IsMatch(value))
        {
            throw new ArgumentException("Value is not a valid broker logical ID.", parameterName);
        }
    }

    private async Task DelayAsync(
        int attempt,
        HttpResponseMessage? response,
        CancellationToken cancellationToken)
    {
        var delay = response?.Headers.RetryAfter?.Delta;
        if (delay is null && response?.Headers.RetryAfter?.Date is { } retryAt)
        {
            delay = retryAt - _timeProvider.GetUtcNow();
        }
        var boundedDelay = delay.HasValue && delay.Value > TimeSpan.Zero
            ? TimeSpan.FromMilliseconds(Math.Min(delay.Value.TotalMilliseconds, 8000))
            : TimeSpan.FromMilliseconds(Math.Min(250 * Math.Pow(2, attempt), 4000));
        await Task.Delay(boundedDelay, cancellationToken).ConfigureAwait(false);
    }

    private static bool IsTransient(HttpStatusCode statusCode) =>
        (int)statusCode is 408 or 425 or 429 || (int)statusCode >= 500;

    private void ClearAccessToken(string tokenUsed)
    {
        lock (_accessLock)
        {
            if (_accessToken == tokenUsed)
            {
                _accessToken = null;
                _accessExpiresAt = default;
            }
        }
    }

    private static string Redact(string value) =>
        SensitiveValuePattern.Replace(value, match => match.Groups[1].Value + "[redacted]");

    public void Dispose()
    {
        lock (_accessLock)
        {
            _accessToken = null;
            _accessExpiresAt = default;
        }
        if (_ownsHttpClient)
        {
            _http.Dispose();
        }
    }

    private sealed class ProblemResponse
    {
        [JsonPropertyName("detail")]
        public string? Detail { get; init; }

        [JsonPropertyName("code")]
        public string? Code { get; init; }

        [JsonPropertyName("request_id")]
        public string? RequestId { get; init; }
    }
}

public sealed class BrokerClientException : Exception
{
    public BrokerClientException(
        string message,
        HttpStatusCode? statusCode = null,
        string? code = null,
        Exception? innerException = null,
        string? method = null,
        string? path = null,
        string? host = null,
        string? requestId = null)
        : base(message, innerException)
    {
        StatusCode = statusCode;
        Code = code;
        Method = method;
        Path = path;
        Host = host;
        RequestId = requestId;
    }

    public HttpStatusCode? StatusCode { get; }
    public string? Code { get; }
    public string? Method { get; }
    public string? Path { get; }
    public string? Host { get; }
    public string? RequestId { get; }
}
