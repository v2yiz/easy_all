#!/usr/bin/env bash

set -euo pipefail

fail() {
    printf '%s\n' "$*" '请在 Linux/容器中运行 npm test；macOS 可单独运行 npm run test:worker。' >&2
    exit 1
}

((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 1))) \
    || fail "完整测试需要 Bash 4.1+（当前 ${BASH_VERSION}）。"
for utility in stat date; do
    "${utility}" --version 2>/dev/null | grep -q 'GNU coreutils' \
        || fail "完整测试需要 GNU coreutils 的 ${utility}。"
done
