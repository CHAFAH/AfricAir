#!/bin/sh
# Runs before 20-envsubst-on-templates.sh. With a read-only root filesystem the only writable place is
# the /tmp tmpfs, which starts empty, and the envsubst script skips an output directory that doesn't exist.
set -eu
mkdir -p "${NGINX_ENVSUBST_OUTPUT_DIR:-/tmp/nginx-conf}"
