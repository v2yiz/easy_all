#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
REALITY_PROFILE="${ROOT_DIR}/lib/reality.sh"
XHTTP_PROFILE="${ROOT_DIR}/lib/xhttp.sh"
LAUNCHER_CONTENT=$(<"${ROOT_DIR}/easy_all")
BOOTSTRAP_CONTENT=$(<"${ROOT_DIR}/bootstrap.sh")

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

module_functions() {
    sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)().*/\1/p' "$1"
}

bash -n "${ROOT_DIR}/easy_all" "${ROOT_DIR}/bootstrap.sh" "${ROOT_DIR}"/lib/*.sh

shared_modules=(
    quota.sh
    platform.sh
    profile-runtime.sh
    network.sh
    firewall.sh
    xray-core.sh
    acme-renewal.sh
    subscription-auth.sh
    validation.sh
    tcp-tuning.sh
    reboot-schedule.sh
)

for module in "${shared_modules[@]}"; do
    [[ "$(<"${REALITY_PROFILE}")" == *'source "${SCRIPT_DIR}/'"${module}"'"'* ]] \
        || fail "Reality does not source shared module ${module}"
    [[ "$(<"${XHTTP_PROFILE}")" == *'source "${SCRIPT_DIR}/'"${module}"'"'* ]] \
        || fail "XHTTP does not source shared module ${module}"
    [[ "${LAUNCHER_CONTENT}" == *'"lib/'"${module}"'"'* ]] \
        || fail "runtime installer does not register ${module}"
    [[ "${BOOTSTRAP_CONTENT}" == *'lib/'"${module}"* ]] \
        || fail "bootstrap does not validate ${module}"
done

for module in platform.sh profile-runtime.sh network.sh firewall.sh xray-core.sh acme-renewal.sh subscription-auth.sh validation.sh tcp-tuning.sh reboot-schedule.sh; do
    while read -r function_name; do
        [[ -n "${function_name}" ]] || continue
        ! grep -Eq "^${function_name}\\(\\)" "${REALITY_PROFILE}" \
            || fail "Reality redefines shared function ${function_name}"
        ! grep -Eq "^${function_name}\\(\\)" "${XHTTP_PROFILE}" \
            || fail "XHTTP redefines shared function ${function_name}"
    done < <(module_functions "${ROOT_DIR}/lib/${module}")
done

[[ "$(<"${ROOT_DIR}/lib/acme-renewal.sh")" == *'systemctl is-enabled --quiet cron.service'* \
    && "$(<"${ROOT_DIR}/lib/acme-renewal.sh")" == *'systemctl is-active --quiet cron.service'* ]] \
    || fail "shared ACME renewal must verify cron boot and runtime state"

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/subscription-auth.sh"
[[ "$(normalize_allowed_tokens '{" owner ":" test-token "}')" == '{"owner":"test-token"}' ]] \
    || fail "shared subscription auth does not normalize valid credentials"
if normalize_allowed_tokens '{"owner":12345678}' >/dev/null 2>&1; then
    fail "shared subscription auth accepts a non-string token"
fi
if normalize_allowed_tokens \
    '{"owner":"test-token"," owner ":"friend-token"}' >/dev/null 2>&1; then
    fail "shared subscription auth accepts duplicate normalized usernames"
fi

[[ "$(<"${ROOT_DIR}/lib/tcp-tuning.sh")" == *'net.ipv4.tcp_mtu_probing = 0'* \
    && "$(<"${REALITY_PROFILE}")" == *'readonly BBR_ALLOW_EXISTING_XANMOD="1"'* \
    && "$(<"${XHTTP_PROFILE}")" == *'readonly BBR_ALLOW_EXISTING_XANMOD="0"'* ]] \
    || fail "shared TCP tuning or profile XanMod policies drifted"

[[ "$(<"${ROOT_DIR}/lib/profile-runtime.sh")" == *'bash "${launcher}" register-command'* ]] \
    || fail "profiles must delegate command registration to the unified launcher"
[[ "$(<"${ROOT_DIR}/lib/profile-runtime.sh")" != *'已注册单文件命令'* ]] \
    || fail "profiles must not install an incomplete single-file command"

printf 'ok - shared architecture tests passed\n'
