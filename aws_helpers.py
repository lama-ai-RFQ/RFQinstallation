#!/usr/bin/env python3

import argparse
import json
import os
import sys
from datetime import datetime, timezone


def check_dependencies(_args: argparse.Namespace) -> int:
    status = {
        "boto3": True,
        "cryptography": True,
        "errors": {},
    }

    try:
        import boto3  # noqa: F401
    except Exception as exc:
        status["boto3"] = False
        status["errors"]["boto3"] = str(exc)

    try:
        import cryptography  # noqa: F401
    except Exception as exc:
        status["cryptography"] = False
        status["errors"]["cryptography"] = str(exc)

    print(json.dumps(status))
    return 0 if status["boto3"] and status["cryptography"] else 1


def download_s3_object(args: argparse.Namespace) -> int:
    try:
        import boto3
    except Exception as exc:
        print(f"Failed to import boto3: {exc}", file=sys.stderr)
        return 1

    access_key = os.environ.get("AWS_ACCESS_KEY_ID")
    secret_key = os.environ.get("AWS_SECRET_ACCESS_KEY")

    if not access_key or not secret_key:
        print(
            "AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must be set in the environment.",
            file=sys.stderr,
        )
        return 1

    dest_dir = os.path.dirname(os.path.abspath(args.dest))
    if dest_dir:
        os.makedirs(dest_dir, exist_ok=True)

    try:
        client = boto3.client(
            "s3",
            aws_access_key_id=access_key,
            aws_secret_access_key=secret_key,
            region_name=args.region,
        )
        client.download_file(args.bucket, args.key, args.dest)
        return 0
    except Exception as exc:
        print(f"Failed to download s3://{args.bucket}/{args.key}: {exc}", file=sys.stderr)
        return 1


def generate_cloudfront_signed_url(args: argparse.Namespace) -> int:
    try:
        from botocore.signers import CloudFrontSigner
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import padding
    except Exception as exc:
        print(f"Failed to import CloudFront signing dependencies: {exc}", file=sys.stderr)
        return 1

    pem_text = sys.stdin.read()
    if not pem_text.strip():
        print("No private key PEM was provided on stdin.", file=sys.stderr)
        return 1

    try:
        private_key = serialization.load_pem_private_key(
            pem_text.encode("utf-8"),
            password=None,
        )
    except Exception as exc:
        print(f"Failed to load private key: {exc}", file=sys.stderr)
        return 1

    def rsa_signer(message: bytes) -> bytes:
        return private_key.sign(message, padding.PKCS1v15(), hashes.SHA1())

    try:
        expires_at = datetime.fromtimestamp(args.expires, tz=timezone.utc)
        signer = CloudFrontSigner(args.key_pair_id, rsa_signer)
        signed_url = signer.generate_presigned_url(
            args.resource_url,
            date_less_than=expires_at,
        )
        print(signed_url)
        return 0
    except Exception as exc:
        print(f"Failed to generate CloudFront signed URL: {exc}", file=sys.stderr)
        return 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="AWS helper utilities for the installer.")
    subparsers = parser.add_subparsers(dest="command")

    check_parser = subparsers.add_parser("check-dependencies")
    check_parser.set_defaults(func=check_dependencies)

    download_parser = subparsers.add_parser("download-s3-object")
    download_parser.add_argument("--bucket", required=True)
    download_parser.add_argument("--key", required=True)
    download_parser.add_argument("--region", required=True)
    download_parser.add_argument("--dest", required=True)
    download_parser.set_defaults(func=download_s3_object)

    sign_parser = subparsers.add_parser("generate-cloudfront-signed-url")
    sign_parser.add_argument("--resource-url", required=True)
    sign_parser.add_argument("--expires", required=True, type=int)
    sign_parser.add_argument("--key-pair-id", required=True)
    sign_parser.set_defaults(func=generate_cloudfront_signed_url)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    if not hasattr(args, "func"):
        parser.print_help(sys.stderr)
        return 1

    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
