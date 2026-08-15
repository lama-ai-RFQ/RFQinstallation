using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;
using RfqInstaller.Core.Models;

namespace RfqInstaller.Core.Networking;

/// <summary>
/// Calls the vendor-hosted license-broker HTTPS API (see license-broker/ in this repo for the
/// reference Lambda implementation). Given a license key, the broker validates it server-side
/// and returns short-lived, scoped download URLs plus install-time config — this is what
/// replaces manually typing a GitHub token and AWS key/secret/region into the wizard.
/// </summary>
public class LicenseBrokerClient
{
    /// <summary>
    /// Base URL of the deployed license-broker API. This MUST be set to the real API Gateway
    /// invoke URL before shipping a build — there is no safe default, since a wrong/placeholder
    /// URL should fail loudly rather than silently pointing at nothing.
    /// </summary>
    public static string BaseUrl { get; set; } =
        Environment.GetEnvironmentVariable("RFQ_LICENSE_BROKER_URL") ?? "https://REPLACE-ME.execute-api.us-east-1.amazonaws.com";

    private readonly HttpClient _http;

    public LicenseBrokerClient(HttpClient? httpClient = null)
    {
        _http = httpClient ?? new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
    }

    public async Task<BrokerResponse> ValidateAndIssueAsync(string licenseKey, CancellationToken cancellationToken = default)
    {
        if (BaseUrl.Contains("REPLACE-ME", StringComparison.Ordinal))
        {
            return new BrokerResponse
            {
                Valid = false,
                Message = "Installer is not configured with a license-broker URL. Contact support.",
            };
        }

        using var request = new HttpRequestMessage(HttpMethod.Post, $"{BaseUrl.TrimEnd('/')}/validate-and-issue")
        {
            Content = JsonContent.Create(new BrokerRequest(licenseKey), options: JsonOptions),
        };

        HttpResponseMessage response;
        try
        {
            response = await _http.SendAsync(request, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException)
        {
            return new BrokerResponse
            {
                Valid = false,
                Message = $"Could not reach the license server: {ex.Message}",
            };
        }

        if (!response.IsSuccessStatusCode)
        {
            var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
            return new BrokerResponse
            {
                Valid = false,
                Message = $"License server rejected the request ({(int)response.StatusCode}): {Truncate(body, 300)}",
            };
        }

        var dto = await response.Content.ReadFromJsonAsync<BrokerResponseDto>(JsonOptions, cancellationToken).ConfigureAwait(false)
            ?? throw new InvalidOperationException("License server returned an empty response.");

        return new BrokerResponse
        {
            Valid = dto.Valid,
            Message = dto.Message ?? string.Empty,
            CustomerId = dto.CustomerId,
            ExpiresAtUtc = dto.ExpiresAtUtc,
            Features = dto.Features ?? new(),
            Limits = dto.Limits ?? new(),
            Components = dto.Components?.Select(c => new PackageComponent
            {
                Name = c.Name,
                Url = c.Url,
                SizeBytes = c.SizeBytes,
                Sha256 = c.Sha256,
            }).ToList() ?? new(),
            ModelFiles = dto.ModelFiles?.Select(m => new ModelFileEntry
            {
                RelativePath = m.RelativePath,
                Url = m.Url,
                SizeBytes = m.SizeBytes,
            }).ToList() ?? new(),
            DefaultServerUrl = dto.DefaultServerUrl,
            UpdateChannel = dto.UpdateChannel,
            UrlsExpireAtUtc = dto.UrlsExpireAtUtc,
        };
    }

    private static string Truncate(string s, int max) => s.Length <= max ? s : s[..max] + "...";

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    private record BrokerRequest([property: JsonPropertyName("license_key")] string LicenseKey);

    private class BrokerResponseDto
    {
        public bool Valid { get; set; }
        public string? Message { get; set; }
        public string? CustomerId { get; set; }
        public DateTimeOffset? ExpiresAtUtc { get; set; }
        public Dictionary<string, bool>? Features { get; set; }
        public Dictionary<string, int>? Limits { get; set; }
        public List<PackageComponentDto>? Components { get; set; }
        public List<ModelFileDto>? ModelFiles { get; set; }
        public string? DefaultServerUrl { get; set; }
        public string? UpdateChannel { get; set; }
        public DateTimeOffset? UrlsExpireAtUtc { get; set; }
    }

    private class ModelFileDto
    {
        public string RelativePath { get; set; } = string.Empty;
        public string Url { get; set; } = string.Empty;
        public long SizeBytes { get; set; }
    }

    private class PackageComponentDto
    {
        public string Name { get; set; } = string.Empty;
        public string Url { get; set; } = string.Empty;
        public long SizeBytes { get; set; }
        public string? Sha256 { get; set; }
    }
}
