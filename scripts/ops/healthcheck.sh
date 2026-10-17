#!/usr/bin/env bash
set -Eeuo pipefail

TARGET_ENDPOINT="http://127.0.0" # Update to match your application's actual metrics/health endpoint URL
echo "Starting Application Health Verification Layer on $TARGET_ENDPOINT..."

for attempt in {1..5}; do
    STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$TARGET_ENDPOINT" || echo "000")
    if [ "$STATUS_CODE" -eq 200 ]; then
        echo "SUCCESS: Gateway service returned status code 200 OK."
        exit 0
    fi
    echo "Warning: Health criteria failed (HTTP Status: $STATUS_CODE). Retrying in 3 seconds..."
    sleep 3
done

echo "CRITICAL PIPELINE ERROR: Production deployment failed health validation checks!"
exit 1
