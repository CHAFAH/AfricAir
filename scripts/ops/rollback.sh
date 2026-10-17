#!/usr/bin/env bash
set -Eeuo pipefail

CURRENT_DIR="/var/www/africair/current"
cd /var/www/africair/releases

# Determine the exact previous timestamp directory folder
PREVIOUS_RELEASE=$(ls -1t | sed -n '2p')

if [ -z "$PREVIOUS_RELEASE" ]; then
    echo "CRITICAL FAULT: Deployment pipeline found no historic rollbacks to revert to!"
    exit 1
fi

echo "ROLLBACK TRIGGERED: Reverting environment state safely to release directory: $PREVIOUS_RELEASE"
ln -sfn "/var/www/africair/releases/$PREVIOUS_RELEASE" "$CURRENT_DIR.next"
mv -Tf "$CURRENT_DIR.next" "$CURRENT_DIR"

sudo systemctl restart africair-api.service
sudo systemctl reload nginx
echo "Rollback sequence executed successfully."
