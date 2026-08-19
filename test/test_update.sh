#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
SCRIPT="${ROOT_DIR}/update.sh"

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

bash -n "${SCRIPT}"
content=$(<"${SCRIPT}")
readme=$(<"${ROOT_DIR}/README.md")

[[ "${content}" == *'git clone --depth 1 --branch main'* ]] \
    || fail "updater must shallow-clone main"
[[ "${content}" == *'&& -f "${REPO_DIR}/lib/reality.sh"'* \
    && "${content}" == *'&& -f "${REPO_DIR}/lib/xhttp.sh"'* \
    && "${content}" == *'&& -f "${REPO_DIR}/sample-mihomo.yaml"'* ]] \
    || fail "updater must validate the complete project"
[[ "${content}" == *'"${SUDO[@]}" "${REPO_DIR}/easy_all" update'* ]] \
    || fail "updater must run update from the downloaded project"
[[ "${content}" == *'[[ -t 0 ]]'* && "${content}" == *'不要使用 curl | bash'* ]] \
    || fail "updater must preserve interactive stdin"
[[ "${readme}" == *'main/update.sh)'* ]] \
    || fail "README must document the one-command project update"
[[ "${readme}" == *'main/debian_init.sh)'* ]] \
    || fail "README must document the one-command debian_init launch"
[[ "${readme}" == *'## 命令说明'* && "${readme}" == *'不下载 GitHub 项目代码'* ]] \
    || fail "README must distinguish deployment refresh from project code updates"
[[ "${readme}" == *'### 轮换 UUID'* && "${readme}" == *'sudo env VLESS_UUID='* ]] \
    || fail "README must document UUID rotation through update"
[[ "${readme}" == *'### 更新订阅 Token'* && "${readme}" == *'sudo env ALLOWED_TOKENS='* ]] \
    || fail "README must document subscription token updates"

printf 'ok - update bootstrap tests passed\n'
