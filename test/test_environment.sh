#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "${TMP_DIR}"' EXIT
CHECK_ENVIRONMENT="${ROOT_DIR}/test/check_environment.sh"

bash "${CHECK_ENVIRONMENT}"
for utility in stat date; do
    cat >"${TMP_DIR}/${utility}" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod 0755 "${TMP_DIR}/${utility}"
    if output=$(PATH="${TMP_DIR}:${PATH}" bash "${CHECK_ENVIRONMENT}" 2>&1); then
        printf 'not ok - unsupported %s must fail the environment check\n' "${utility}" >&2
        exit 1
    fi
    [[ "${output}" == *"GNU coreutils 的 ${utility}"* && "${output}" == *'npm run test:worker'* ]] \
        || { printf 'not ok - missing %s must explain test prerequisites\n' "${utility}" >&2; exit 1; }
    rm -- "${TMP_DIR}/${utility}"
done
printf 'ok - test environment prerequisite checks passed\n'
