#!/usr/bin/env bash
set -Eeuo pipefail

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RELEASE_DIR="/var/www/africair/releases/$TIMESTAMP"
CURRENT_DIR="/var/www/africair/current"

echo "Deploying Release Package to Linux Environment: $TIMESTAMP"
mkdir -p "$RELEASE_DIR"

# Copy Workspace Artifacts
cp -R dist "$RELEASE_DIR/"
cp -R server "$RELEASE_DIR/"
cp package.json pnpm-workspace.yaml pnpm-lock.yaml "$RELEASE_DIR/"

# Install Production Dependencies Only
cd "$RELEASE_DIR"
pnpm install --prod --frozen-lockfile

# Safe Atomic Link Management Switch
echo "Swapping Symbolic Link Pointers Atomically..."
ln -sfn "$RELEASE_DIR" "$CURRENT_DIR.next"
mv -Tf "$CURRENT_DIR.next" "$CURRENT_DIR"

# Cycle Service Control Engine
echo "Reloading Process Architectures..."
sudo systemctl daemon-reload
sudo systemctl restart africair-api.service
sudo systemctl reload nginx

# Run Verification Loop Execution
../../scripts/ops/healthcheck.sh
