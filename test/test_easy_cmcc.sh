#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
TMP_DIR="$(mktemp -d)"
FAKE_CORE="${TMP_DIR}/easy_all.sh"

cleanup() {
    rm -rf -- "${TMP_DIR}"
}
trap cleanup EXIT

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

assert_equal() {
    [[ "$2" == "$3" ]] || fail "$1: expected '$2', got '$3'"
}

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "profile=%s worker=%s args=%s\\n" "$EASY_ALL_PROFILE" "$WORKER_NAME" "$*"' \
    >"${FAKE_CORE}"
chmod 755 "${FAKE_CORE}"

output=$(EASY_CMCC_CORE="${FAKE_CORE}" EASY_CMCC_REGISTER_COMMAND=0 \
    "${ROOT_DIR}/easy_cmcc.sh" install)
assert_equal "install forces the CMCC profile and XHTTP" \
    "profile=cmcc worker=easy-cmcc args=install vless-xhttp" "${output}"

output=$(EASY_CMCC_CORE="${FAKE_CORE}" EASY_CMCC_REGISTER_COMMAND=0 WORKER_NAME=wrong-name \
    "${ROOT_DIR}/easy_cmcc.sh" update)
assert_equal "update keeps the dedicated Worker name" \
    "profile=cmcc worker=easy-cmcc args=update" "${output}"

if EASY_CMCC_CORE="${FAKE_CORE}" EASY_CMCC_REGISTER_COMMAND=0 \
    "${ROOT_DIR}/easy_cmcc.sh" switch reality >/dev/null 2>&1; then
    fail "CMCC entrypoint must reject protocol switching"
fi

if EASY_CMCC_CORE="${FAKE_CORE}" EASY_CMCC_REGISTER_COMMAND=0 \
    "${ROOT_DIR}/easy_cmcc.sh" install reality >/dev/null 2>&1; then
    fail "CMCC entrypoint must reject an install protocol override"
fi

printf 'ok - easy_cmcc wrapper tests passed\n'
