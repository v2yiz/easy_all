#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
TMP_DIR="$(mktemp -d)"
FAKE_CORE="${TMP_DIR}/easy_core.sh"

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
    'main() {' \
    '  printf "profile=%s entry=%s worker=%s args=%s\\n" "$EASY_ALL_PROFILE" "$EASY_ALL_ENTRY_COMMAND" "${WORKER_NAME:-}" "$*"' \
    '}' \
    >"${FAKE_CORE}"

output=$(EASY_ALL_CORE_SOURCE="${FAKE_CORE}" "${ROOT_DIR}/easy_all.sh" update)
assert_equal "generic entry downloads and loads the generic profile core" \
    "profile=general entry=easy_all worker= args=update" "${output}"

output=$(EASY_ALL_CORE_SOURCE="${FAKE_CORE}" WORKER_NAME=wrong-name \
    "${ROOT_DIR}/easy_cmcc.sh" install)
assert_equal "CMCC entry loads the dedicated profile and Worker name" \
    "profile=cmcc entry=easy_cmcc worker=easy-cmcc args=install" "${output}"

if EASY_ALL_PROFILE=cmcc EASY_ALL_ENTRY_SCRIPT="${ROOT_DIR}/easy_cmcc.sh" \
    EASY_ALL_ENTRY_COMMAND=easy_cmcc bash -c 'source "$1"; choose_protocol reality' \
    _ "${ROOT_DIR}/easy_core.sh" >/dev/null 2>&1; then
    fail "CMCC core must reject Reality"
fi

printf 'ok - easy entrypoint tests passed\n'
