"""Direct boto3 upload to RunPod's S3-compatible network-volume API.

runpod's built-in rp_upload.upload_image is incompatible with RunPod S3:
it defaults the bucket to today's date (e.g. "06-26") and can't derive the
region from the s3api-<dc>.runpod.io URL. RunPod S3 requires the bucket to be
the network-volume ID and a real region (e.g. EUR-IS-1). So we upload directly.

Env (set on the serverless template):
  BUCKET_ENDPOINT_URL   e.g. https://s3api-eur-is-1.runpod.io
  BUCKET_NAME           the network-volume ID, e.g. 7v1hzig2vv
  BUCKET_REGION         e.g. EUR-IS-1
  BUCKET_ACCESS_KEY_ID  RunPod S3 access key (user_...)
  BUCKET_SECRET_ACCESS_KEY  RunPod S3 secret (rps_...)
"""

import os
import uuid

import boto3
from botocore.config import Config


def upload_to_runpod_s3(job_id: str, file_path: str, file_extension: str) -> str:
    """Upload a file to the RunPod network-volume bucket; return a presigned GET URL."""
    endpoint = os.environ["BUCKET_ENDPOINT_URL"].rstrip("/")
    bucket = os.environ["BUCKET_NAME"]
    region = os.environ.get("BUCKET_REGION", "EUR-IS-1")

    client = boto3.client(
        "s3",
        endpoint_url=endpoint,
        aws_access_key_id=os.environ["BUCKET_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["BUCKET_SECRET_ACCESS_KEY"],
        region_name=region,
        config=Config(signature_version="s3v4", retries={"max_attempts": 3, "mode": "standard"}),
    )

    key = f"upscale-output/{job_id}/{uuid.uuid4().hex[:8]}{file_extension}"
    content_type = "image/" + file_extension.lstrip(".").lower().replace("jpg", "jpeg")

    with open(file_path, "rb") as f:
        client.put_object(Bucket=bucket, Key=key, Body=f.read(), ContentType=content_type)

    # 7-day presigned URL — the Next.js /upscale route downloads it and re-stores
    # into Supabase board-images right away, so a short-lived link is fine.
    return client.generate_presigned_url(
        "get_object",
        Params={"Bucket": bucket, "Key": key},
        ExpiresIn=604800,
    )
