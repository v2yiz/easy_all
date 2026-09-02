#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
SCRIPT="${ROOT_DIR}/bootstrap.sh"

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

bash -n "${SCRIPT}"
content=$(<"${SCRIPT}")

[[ "${content}" == *'apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends git ca-certificates'* ]] \
    || fail "bootstrap must install git before cloning"
[[ "${content}" == *'git clone --depth 1 --branch main'* ]] \
    || fail "bootstrap must shallow-clone main"
[[ "${content}" == *'&& -f "${REPO_DIR}/profiles/reality.sh"'* \
    && "${content}" == *'&& -f "${REPO_DIR}/profiles/xhttp-cloudflare.sh"'* \
    && "${content}" == *'&& -f "${REPO_DIR}/profiles/xhttp-gcore.sh"'* \
    && "${content}" == *'&& -f "${REPO_DIR}/lib/xhttp-runtime.sh"'* \
    && "${content}" == *'&& -f "${REPO_DIR}/lib/cdn-traffic-guard.sh"'* \
    && "${content}" == *'&& -f "${REPO_DIR}/lib/globalping-cdn.sh"'* \
    && "${content}" == *'&& -f "${REPO_DIR}/lib/cloudflare-ip-pool.sh"'* \
    && "${content}" == *'&& -f "${REPO_DIR}/lib/quota.sh"'* \
    && "${content}" == *'&& -f "${REPO_DIR}/lib/platform.sh"'* \
    && "${content}" == *'&& -f "${REPO_DIR}/lib/profile-common.sh"'* \
    && "${content}" == *'&& -f "${REPO_DIR}/lib/network.sh"'* \
    && "${content}" == *'&& -f "${REPO_DIR}/lib/mihomo-template.sh"'* \
    && "${content}" == *'&& -f "${REPO_DIR}/lib/firewall.sh"'* \
    && "${content}" == *'&& -f "${REPO_DIR}/lib/xray-core.sh"'* \
    && "${content}" == *'&& -f "${REPO_DIR}/lib/scheduled-maintenance.sh"'* \
    && "${content}" == *'&& -f "${REPO_DIR}/lib/subscription-auth.sh"'* \
    && "${content}" == *'&& -f "${REPO_DIR}/lib/tcp-tuning.sh"'* \
    && "${content}" == *'&& -f "${REPO_DIR}/templates/mihomo.yaml"'* ]] \
    || fail "bootstrap must validate the complete project"
[[ "${content}" == *'"${SUDO[@]}" "${REPO_DIR}/easy_all" install'* ]] \
    || fail "bootstrap must preserve interactive stdin when starting installation"
[[ "${content}" != *'archive/refs/heads/main.tar.gz'* ]] \
    || fail "bootstrap must use git rather than a source archive"

install_line=$(grep -n 'apt-get .*install -y' "${SCRIPT}" | cut -d: -f1)
clone_line=$(grep -n 'git clone --depth 1' "${SCRIPT}" | cut -d: -f1)
((install_line < clone_line)) || fail "git installation must precede git clone"

printf 'ok - bootstrap shell tests passed\n'
