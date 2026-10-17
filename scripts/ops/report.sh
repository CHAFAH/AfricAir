#!/usr/bin/env bash
set -euo pipefail

echo "=================== PIPELINE EXECUTION SUMMARY REPORT ==================="
echo "Deployment Timestamp: $(date)"
echo "Host Operating Version: $(uname -a)"
echo "Current Deployment Pointer: $(readlink -f /var/www/africair/current)"
echo "Node System Footprint: $(node -v)"
echo "Active Memory Footprint:"
free -h
echo "========================================================================"
