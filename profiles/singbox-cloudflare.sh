#!/usr/bin/env bash

# Backward-compatibility shim for Cloudflare Mode 5 (xhttp-cloudflare-streamup.sh).

set -Eeuo pipefail
umask 077

_SINGBOX_SHIM_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=profiles/xhttp-cloudflare-streamup.sh
source "${_SINGBOX_SHIM_DIR}/xhttp-cloudflare-streamup.sh"
