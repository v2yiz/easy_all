#!/usr/bin/env bash

# Shanghai Mobile / RackNerd CDN entrypoint: Gemini uses XHTTP, downloads use WSS.

set -Eeuo pipefail
umask 077

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
readonly SCRIPT_FILE="${SCRIPT_DIR}/$(basename -- "${BASH_SOURCE[0]}")"
readonly CORE_URL="${EASY_ALL_CORE_URL:-https://raw.githubusercontent.com/v2yiz/easy_all/main/easy_core.sh}"

CORE_FILE=""
CORE_IS_TEMP=0
cleanup() {
    [[ "${CORE_IS_TEMP}" != "1" || -z "${CORE_FILE}" || ! -f "${CORE_FILE}" ]] \
        || rm -f -- "${CORE_FILE}"
}
trap cleanup EXIT

die() {
    printf 'easy_cmcc: %s\n' "$*" >&2
    exit 1
}

download_core() {
    if [[ -n "${EASY_ALL_CORE_SOURCE:-}" ]]; then
        [[ -f "${EASY_ALL_CORE_SOURCE}" ]] || die "EASY_ALL_CORE_SOURCE 不存在：${EASY_ALL_CORE_SOURCE}"
        CORE_FILE=${EASY_ALL_CORE_SOURCE}
        return 0
    fi
    CORE_FILE=$(mktemp "${TMPDIR:-/tmp}/easy-cmcc-core.XXXXXX")
    CORE_IS_TEMP=1
    wget -qO "${CORE_FILE}" "${CORE_URL}" \
        || die "下载共享安装核心失败：${CORE_URL}"
    [[ -s "${CORE_FILE}" ]] || die "下载的共享安装核心为空"
}

download_core
export EASY_ALL_PROFILE=cmcc
export EASY_ALL_ENTRY_SCRIPT="${SCRIPT_FILE}"
export EASY_ALL_ENTRY_COMMAND=easy_cmcc
export WORKER_NAME=easy-cmcc
[[ "${CORE_IS_TEMP}" != "1" ]] || export EASY_ALL_DOWNLOADED_CORE_FILE="${CORE_FILE}"
# shellcheck source=/dev/null
source "${CORE_FILE}"
main "$@"
