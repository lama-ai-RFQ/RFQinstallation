"""
License-broker Lambda: validates an RFQ Application license key and, if valid,
returns short-lived S3 presigned URLs for the release package plus install-time
config (server URL default, update channel). This is what the new Windows
installer calls instead of asking the user for a GitHub token and AWS
key/secret/region -- those credentials never reach the client at all.

License validation is the exact scheme already implemented in
RFQautomation/backend/main/license_validator.py and
RFQautomation/generate_license_key.py: `RFQ.<payload_b64>.<signature_b64>`,
RSA-PKCS1v15/SHA256 signature over the zlib-compressed JSON payload, verified
against the bundled public key. It is deliberately re-verified here (not just
trusted from the client) since the client-side check in the installer is only
a fast pre-check for UI feedback -- this Lambda is the actual authority that
hands out real download credentials.

Deploy with the accompanying template.yaml (AWS SAM). See README.md.
"""

from __future__ import annotations

import base64
import json
import logging
import os
import zlib
from datetime import datetime, timedelta, timezone
from pathlib import Path

import boto3
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding

logger = logging.getLogger()
logger.setLevel(logging.INFO)

GRACE_PERIOD_DAYS = 7
URL_EXPIRY_SECONDS = int(os.environ.get("URL_EXPIRY_SECONDS", "3600"))

RELEASE_BUCKET = os.environ["RELEASE_BUCKET"]  # e.g. rfq-distribution-us
RELEASE_MANIFEST_KEY = os.environ.get("RELEASE_MANIFEST_KEY", "latest/manifest.json")
MODEL_BUCKET = os.environ.get("MODEL_BUCKET", "rfq-models")
MODEL_PREFIX = os.environ.get("MODEL_PREFIX", "Mistral-7B-Instruct-v0-3/")
DEFAULT_SERVER_URL = os.environ.get("DEFAULT_SERVER_URL", "https://localhost")
UPDATE_CHANNEL = os.environ.get("UPDATE_CHANNEL", "customer")

FEATURE_CODE_TO_NAME = {
    "a": "ai_extraction",
    "p": "price_prediction",
    "e": "email_automation",
    "aa": "advanced_analytics",
    "mu": "multi_user",
    "ai": "api_integrations",
}
LIMIT_CODE_TO_NAME = {
    "mp": "max_projects",
    "ms": "max_suppliers",
    "mq": "max_quotations_per_month",
    "mu": "max_users",
}

_PUBLIC_KEY_PEM = (Path(__file__).resolve().parent / "license_public_key.pem").read_bytes()
_s3 = boto3.client("s3")


def _b64url_decode(value: str) -> bytes:
    padded = value + "=" * (-len(value) % 4)
    return base64.urlsafe_b64decode(padded.encode("ascii"))


def validate_license_key(license_key: str) -> tuple[bool, str, dict | None]:
    key = (license_key or "").strip()
    if not key.startswith(("RFQ.", "RFQ-")):
        return False, "License key must start with 'RFQ.'.", None

    separator = key[3]
    parts = key.split(separator)
    if len(parts) != 3:
        return False, "License key format is invalid (expected 3 segments).", None

    try:
        payload_compressed = _b64url_decode(parts[1])
        signature = _b64url_decode(parts[2])
    except Exception:
        return False, "License key is not validly encoded.", None

    public_key = serialization.load_pem_public_key(_PUBLIC_KEY_PEM)
    try:
        public_key.verify(signature, payload_compressed, padding.PKCS1v15(), hashes.SHA256())
    except InvalidSignature:
        return False, "License key signature is invalid.", None

    try:
        payload = json.loads(zlib.decompress(payload_compressed))
    except Exception:
        return False, "License key payload could not be decoded.", None

    expiration_str = payload.get("e")
    if expiration_str:
        expiration = datetime.strptime(expiration_str, "%Y-%m-%d").replace(tzinfo=timezone.utc)
        if expiration < datetime.now(timezone.utc) - timedelta(days=GRACE_PERIOD_DAYS):
            return False, "License key has expired.", None

    return True, "License key is valid.", payload


def _expand_codes(raw: dict | None, code_map: dict[str, str]) -> dict:
    if not raw:
        return {}
    return {code_map[code]: value for code, value in raw.items() if code in code_map}


def _presign(bucket: str, key: str) -> tuple[str, int]:
    head = _s3.head_object(Bucket=bucket, Key=key)
    url = _s3.generate_presigned_url(
        "get_object",
        Params={"Bucket": bucket, "Key": key},
        ExpiresIn=URL_EXPIRY_SECONDS,
    )
    return url, head["ContentLength"]


def _release_components() -> list[dict]:
    """Reads the release manifest (written by the existing build/publish pipeline,
    see RFQautomation/scripts/distribution) and presigns each component archive."""
    manifest_obj = _s3.get_object(Bucket=RELEASE_BUCKET, Key=RELEASE_MANIFEST_KEY)
    manifest = json.loads(manifest_obj["Body"].read())

    components = []
    for name, component in manifest.get("components", {}).items():
        for file_entry in component.get("files", []):
            key = f"{os.path.dirname(RELEASE_MANIFEST_KEY)}/{file_entry['filename']}"
            url, size = _presign(RELEASE_BUCKET, key)
            components.append({
                "name": name,
                "url": url,
                "sizeBytes": size,
                "sha256": component.get("sha256"),
            })
    return components


def _model_files() -> list[dict]:
    paginator = _s3.get_paginator("list_objects_v2")
    files = []
    for page in paginator.paginate(Bucket=MODEL_BUCKET, Prefix=MODEL_PREFIX):
        for obj in page.get("Contents", []):
            if obj["Key"].endswith("/"):
                continue
            url = _s3.generate_presigned_url(
                "get_object",
                Params={"Bucket": MODEL_BUCKET, "Key": obj["Key"]},
                ExpiresIn=URL_EXPIRY_SECONDS,
            )
            files.append({
                "relativePath": obj["Key"][len(MODEL_PREFIX):],
                "url": url,
                "sizeBytes": obj["Size"],
            })
    return files


def handler(event, _context):
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _response(400, {"valid": False, "message": "Malformed request body."})

    license_key = body.get("license_key", "")
    valid, message, payload = validate_license_key(license_key)

    if not valid:
        logger.info("License validation failed: %s", message)
        return _response(200, {"valid": False, "message": message})

    customer_id = payload.get("c") if payload else None
    logger.info("License validated for customer_id=%s", customer_id)

    try:
        components = _release_components()
        model_files = _model_files()
    except Exception:
        logger.exception("License valid but failed to prepare download URLs")
        return _response(200, {
            "valid": False,
            "message": "License is valid, but the download service is temporarily unavailable. Please try again shortly.",
        })

    now = datetime.now(timezone.utc)
    return _response(200, {
        "valid": True,
        "message": message,
        "customerId": customer_id,
        "expiresAtUtc": payload.get("e"),
        "features": _expand_codes(payload.get("f"), FEATURE_CODE_TO_NAME),
        "limits": _expand_codes(payload.get("l"), LIMIT_CODE_TO_NAME),
        "components": components,
        "modelFiles": model_files,
        "defaultServerUrl": DEFAULT_SERVER_URL,
        "updateChannel": UPDATE_CHANNEL,
        "urlsExpireAtUtc": (now + timedelta(seconds=URL_EXPIRY_SECONDS)).isoformat(),
    })


def _response(status_code: int, body: dict):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }
