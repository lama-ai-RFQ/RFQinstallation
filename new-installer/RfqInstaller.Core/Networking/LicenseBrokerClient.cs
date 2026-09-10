using RfqInstaller.Core.Models;

namespace RfqInstaller.Core.Networking;

/// <summary>
/// PLACEHOLDER — the real license/download service does not exist yet.
///
/// Once a customer provides a valid license key, something outside the installer needs to:
///   1. Validate the key server-side.
///   2. Hand back download URLs for everything the install needs — the release package, the
///      model files, and (per the ongoing app dependencies documented in OLD_VS_NEW.md) whatever
///      credentials the *installed app itself* keeps needing afterward (AWS access for its own
///      S3 downloads, a GitHub token for the updater) — sourced from AWS primarily, falling back
///      to GitHub if AWS is unavailable.
///
/// The endpoint, auth mechanism, and exact request/response shape are not decided — that contract
/// will be supplied separately once the service is built. Intentionally unimplemented until then;
/// fails loudly with a clear message rather than guessing at a shape that would just be wrong.
/// </summary>
public class LicenseBrokerClient
{
    public Task<BrokerResponse> ValidateAndIssueAsync(string licenseKey, CancellationToken cancellationToken = default)
    {
        return Task.FromResult(new BrokerResponse
        {
            Valid = false,
            Message = "The license/download service is not yet implemented. Contact support.",
        });
    }
}
