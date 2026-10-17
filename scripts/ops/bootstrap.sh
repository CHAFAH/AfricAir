#!/usr/bin/env bash
set -Eeuo pipefail

echo "Initializing Target Host System Dependencies..."
sudo apt-get update -y
sudo apt-get install -y nginx git curl coreutils build-essential

# Node Engine Setup via NVM & Corepack
if ! command -v node &> /dev/null; then
    curl -fsSL https://nodesource.com | sudo -E bash -
    sudo apt-get install -y nodejs
fi

sudo corepack enable
sudo pnpm setup

# Provision Directory Tree Structure
sudo mkdir -p /var/www/africair/{releases,shared}
sudo chown -R $USER:$USER /var/www/africair
echo "Host Workspace Successfully Boostrapped."
