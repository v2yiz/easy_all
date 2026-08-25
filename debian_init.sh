#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly DEBIAN_INIT_SOURCE="${BASH_SOURCE[0]}"
readonly DEBIAN_INIT_ROOT="$(cd -- "$(dirname -- "${DEBIAN_INIT_SOURCE}")" >/dev/null 2>&1 && pwd)"
readonly DEBIAN_INIT_LOCAL="${DEBIAN_INIT_ROOT}/scripts/debian-init.sh"
readonly DEBIAN_INIT_URL="https://raw.githubusercontent.com/v2yiz/easy_all/main/scripts/debian-init.sh"

if [[ -f "${DEBIAN_INIT_LOCAL}" ]]; then
    exec bash "${DEBIAN_INIT_LOCAL}" "$@"
fi

command -v curl >/dev/null 2>&1 \
    || { printf '错误: 本机缺少 curl\n' >&2; exit 1; }

debian_init_temp=$(mktemp)
cleanup_debian_init() {
    rm -f -- "${debian_init_temp}"
}
trap cleanup_debian_init EXIT
curl -fsSL --retry 3 "${DEBIAN_INIT_URL}" -o "${debian_init_temp}" \
    || { printf '错误: 下载 debian-init.sh 失败\n' >&2; exit 1; }
bash "${debian_init_temp}" "$@"
