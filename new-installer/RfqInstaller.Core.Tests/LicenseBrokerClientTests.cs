using System.Net;
using System.Text;
using System.Text.Json;
using RfqInstaller.Core.Licensing;
using RfqInstaller.Core.Networking;
using Xunit;

namespace RfqInstaller.Core.Tests;

public sealed class LicenseBrokerClientTests
{
    [Fact]
    public async Task ActivatesPersistsStateAndSignsTheEntitledWindowsRelease()
    {
        var handler = new BrokerHandler();
        var store = new MemoryCredentialStore();
        using var http = new HttpClient(handler);
        using var client = new LicenseBrokerClient(
            http,
            "https://license-api.example.test",
            store,
            maxAttempts: 1);

        var result = await client.ActivateAndGetSignedWindowsReleaseAsync(
            "RFQ.payload.signature",
            "customer");

        Assert.Equal("customer:windows:v1.2.3", result.Release.ReleaseId);
        Assert.Single(result.Artifacts);
        Assert.Equal("app-executable.zip", result.Artifacts[0].ArtifactId);
        Assert.NotNull(store.State?.RefreshToken);
        Assert.Equal("device-1", store.State?.BrokerDeviceId);
        Assert.Equal(1, store.State?.RefreshGeneration);
        Assert.True(handler.ActivationProofWasPresent);
    }

    [Fact]
    public async Task FailedBrokerResponsesIncludeStatusCodePathAndRequestId()
    {
        using var http = new HttpClient(new FailureHandler());
        using var client = new LicenseBrokerClient(
            http,
            "https://license-api.example.test",
            new MemoryCredentialStore(),
            maxAttempts: 1);

        var error = await Assert.ThrowsAsync<BrokerClientException>(() =>
            client.ActivateAndGetSignedWindowsReleaseAsync("RFQ.payload.signature", "customer"));

        Assert.Equal(HttpStatusCode.InternalServerError, error.StatusCode);
        Assert.Equal("internal_error", error.Code);
        Assert.Equal("GET", error.Method);
        Assert.Contains("v1/releases/windows/customer/latest", error.Path);
        Assert.Equal("license-api.example.test", error.Host);
        Assert.Equal("req-123", error.RequestId);
        Assert.Contains("HTTP=500", error.Message);
        Assert.Contains("RequestId=req-123", error.Message);
        Assert.Contains("The request could not be completed.", error.Message);
    }

    [Fact]
    public async Task SignsRuntimeAssetsWithoutAReleaseId()
    {
        var handler = new BrokerHandler();
        using var http = new HttpClient(handler);
        using var client = new LicenseBrokerClient(
            http,
            "https://license-api.example.test",
            new MemoryCredentialStore(),
            maxAttempts: 1);

        await client.ActivateAsync("RFQ.payload.signature");
        var signed = await client.SignRuntimeAssetsAsync(new[] { "postgres.windows.binaries" });

        Assert.Null(signed.ReleaseId);
        Assert.Single(signed.Artifacts);
        Assert.Equal("postgres.windows.binaries", signed.Artifacts[0].ArtifactId);
        Assert.Equal("https://downloads.example.test/postgres.zip?Policy=signed", signed.Artifacts[0].Url);
        Assert.True(handler.RuntimeSignWasRequested);
    }

    private sealed class BrokerHandler : HttpMessageHandler
    {
        private const string Sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        public bool ActivationProofWasPresent { get; private set; }
        public bool RuntimeSignWasRequested { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            var path = request.RequestUri!.AbsolutePath;
            if (path == "/v1/activations")
            {
                var body = JsonDocument.Parse(await request.Content!.ReadAsStringAsync(cancellationToken));
                ActivationProofWasPresent =
                    body.RootElement.GetProperty("device_proof").GetString()?.Length > 0 &&
                    body.RootElement.GetProperty("device_public_key").GetString()?.Contains("PUBLIC KEY") == true &&
                    request.Headers.Contains("Idempotency-Key");
                return Json(HttpStatusCode.Created, """
                    {
                      "access_token":"access-1",
                      "token_type":"Bearer",
                      "expires_in":900,
                      "refresh_token":"refresh-1",
                      "refresh_expires_in":2592000,
                      "device_id":"device-1"
                    }
                    """);
            }

            Assert.Equal("Bearer", request.Headers.Authorization?.Scheme);
            Assert.Equal("access-1", request.Headers.Authorization?.Parameter);
            if (path == "/v1/releases/windows/customer/latest")
            {
                return Json(HttpStatusCode.OK, $$"""
                    {
                      "schema_version":1,
                      "release_id":"customer:windows:v1.2.3",
                      "channel":"customer",
                      "platform":"windows",
                      "version":"v1.2.3",
                      "artifacts":[{
                        "artifact_id":"app-executable.zip",
                        "name":"app-executable.zip",
                        "size":4,
                        "sha256":"{{Sha}}",
                        "content_type":"application/octet-stream"
                      }]
                    }
                    """);
            }
            if (path == "/v1/downloads/sign")
            {
                var body = JsonDocument.Parse(await request.Content!.ReadAsStringAsync(cancellationToken));
                if (body.RootElement.TryGetProperty("runtime_asset_ids", out var runtimeIds))
                {
                    RuntimeSignWasRequested = runtimeIds[0].GetString() == "postgres.windows.binaries";
                    return Json(HttpStatusCode.OK, $$"""
                        {
                          "artifacts":[{
                            "artifact_id":"postgres.windows.binaries",
                            "url":"https://downloads.example.test/postgres.zip?Policy=signed",
                            "size":8,
                            "sha256":"{{Sha}}",
                            "expires_at":4102444800
                          }]
                        }
                        """);
                }
                return Json(HttpStatusCode.OK, $$"""
                    {
                      "release_id":"customer:windows:v1.2.3",
                      "artifacts":[{
                        "artifact_id":"app-executable.zip",
                        "url":"https://downloads.example.test/app.zip?Policy=signed",
                        "size":4,
                        "sha256":"{{Sha}}",
                        "expires_at":4102444800
                      }]
                    }
                    """);
            }
            return new HttpResponseMessage(HttpStatusCode.NotFound);
        }

        private static HttpResponseMessage Json(HttpStatusCode status, string body) =>
            new(status)
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json"),
            };
    }

    private sealed class FailureHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            var path = request.RequestUri!.AbsolutePath;
            if (path == "/v1/activations")
            {
                return Task.FromResult(new HttpResponseMessage(HttpStatusCode.Created)
                {
                    Content = new StringContent(
                        """
                        {
                          "access_token":"access-1",
                          "token_type":"Bearer",
                          "expires_in":900,
                          "refresh_token":"refresh-1",
                          "refresh_expires_in":2592000,
                          "device_id":"device-1"
                        }
                        """,
                        Encoding.UTF8,
                        "application/json"),
                });
            }

            Assert.Equal("/v1/releases/windows/customer/latest", path);
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.InternalServerError)
            {
                Content = new StringContent(
                    """
                    {
                      "detail":"The request could not be completed.",
                      "code":"internal_error",
                      "request_id":"req-123"
                    }
                    """,
                    Encoding.UTF8,
                    "application/problem+json"),
            });
        }
    }

    private sealed class MemoryCredentialStore : ILicenseCredentialStore
    {
        public DeviceCredentialState? State { get; private set; }

        public Task<IDisposable> AcquireLockAsync(CancellationToken cancellationToken) =>
            Task.FromResult<IDisposable>(new NoopLock());

        public DeviceCredentialState? Load() => State;

        public void Save(DeviceCredentialState state) => State = state;

        private sealed class NoopLock : IDisposable
        {
            public void Dispose()
            {
            }
        }
    }
}
