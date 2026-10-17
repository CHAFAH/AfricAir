#!/usr/bin/env bash
set -euo pipefail

BUCKET_NAME="your-africair-cdn-bucket"
echo "Pushing compiled static distribution folder to CloudFront S3 CDN Edge Nodes..."

if ! command -v aws &> /dev/null; then
    echo "ERROR: AWS CLI environment tools not found on runner."
    exit 1
fi

# Sync compiled static files directly to target S3 cloud storage
aws s3 sync dist/ "s3://$BUCKET_NAME/" --delete --cache-control "public, max-age=31536000, immutable"
echo "CDN Synchronization Complete."
