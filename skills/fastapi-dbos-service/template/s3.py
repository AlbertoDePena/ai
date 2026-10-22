"""
S3-compatible client configuration.

Local: points at Silo via S3_ENDPOINT_URL + static credentials, path-style
addressing. Silo is a maintained fork of the open-source MinIO server and keeps
the S3 API unchanged, so nothing below is Silo-specific - swapping in another
S3-compatible service, or real S3, is an env change.

Prod: unset S3_ENDPOINT_URL and the AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY
env vars entirely. boto3/aioboto3 will then talk to real AWS S3 and pick up
credentials from the task's IAM role (on Fargate) or your normal AWS credential
chain - no code change needed. Path-style addressing also works against real
S3 for existing buckets, but virtual-hosted style (the AWS default) is
preferred for new buckets, so flip S3_FORCE_PATH_STYLE=false in prod.
"""

import os

from botocore.config import Config


def s3_client_kwargs() -> dict:
    force_path_style = os.environ.get("S3_FORCE_PATH_STYLE", "true").lower() == "true"

    kwargs: dict = {
        "region_name": os.environ.get("AWS_REGION", "us-east-1"),
        "config": Config(s3={"addressing_style": "path" if force_path_style else "auto"}),
    }

    endpoint_url = os.environ.get("S3_ENDPOINT_URL")
    if endpoint_url:
        kwargs["endpoint_url"] = endpoint_url

    access_key = os.environ.get("AWS_ACCESS_KEY_ID")
    secret_key = os.environ.get("AWS_SECRET_ACCESS_KEY")
    if access_key and secret_key:
        kwargs["aws_access_key_id"] = access_key
        kwargs["aws_secret_access_key"] = secret_key
    # else: fall through to the default credential chain (IAM role, etc.)

    return kwargs
