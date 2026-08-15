# License Broker

Validates an RFQ Application license key and, if valid, returns short-lived S3
presigned URLs for the release package and model files, plus install-time
config. This is what the Windows installer's License Key page calls instead of
asking for a GitHub token and AWS key/secret/region.

## Why this exists

The license key itself (see `RFQautomation/backend/main/license_validator.py`
and `generate_license_key.py`) is a self-contained, offline-verifiable RSA
signature over a small JSON payload (customer ID, expiration, feature flags,
usage limits). It does **not** carry download credentials — it's signed, not
encrypted, so anything in the payload could be read by anyone holding a valid
key. This Lambda is the piece that turns "here is a valid key" into "here are
credentials scoped and time-boxed to this install," without ever handing out
a long-lived shared secret.

## What it needs from you

1. **A release manifest in S3**, at `s3://<ReleaseBucketName>/latest/manifest.json`
   (path configurable via `RELEASE_MANIFEST_KEY`), in the same shape as the
   existing `local_manifest.json` written by the current build/publish
   pipeline (`components: { <name>: { files: [{filename, sha256, size_bytes}] } }`).
   This Lambda expects the actual component archives to sit next to the
   manifest object (same S3 "folder").
2. **The model files** already in `s3://rfq-models/Mistral-7B-Instruct-v0-3/...`
   (or whatever bucket/prefix you set `MODEL_BUCKET`/`MODEL_PREFIX` to) — no
   changes needed there, this just lists and presigns whatever exists.
3. **Deploy** with AWS SAM:
   ```
   sam build
   sam deploy --guided \
     --parameter-overrides ReleaseBucketName=rfq-distribution-us
   ```
   The output `LicenseBrokerUrl` is what you set as
   `RfqInstaller.Core.Networking.LicenseBrokerClient.BaseUrl` (or the
   `RFQ_LICENSE_BROKER_URL` environment variable) before shipping an
   installer build — there is deliberately no working default baked in, so a
   misconfigured build fails loudly instead of silently pointing at nothing.

## Security notes

- Read-only IAM permissions against the two buckets — this function cannot
  write, delete, or modify anything.
- The endpoint is intentionally public (the license key is the credential);
  consider putting AWS WAF in front of it in production to rate-limit
  brute-force key guessing, since license keys aren't astronomically long.
- Presigned URL lifetime defaults to 1 hour (`URL_EXPIRY_SECONDS`) — long
  enough for a slow download, short enough that a leaked URL doesn't matter
  for long.
- Validation logic (RSA verify + zlib decompress + expiration/grace-period
  check) is intentionally kept in lockstep with
  `RFQautomation/backend/main/license_validator.py` — if that scheme ever
  changes, update both places.
