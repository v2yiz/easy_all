#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
REALITY_PROFILE="${ROOT_DIR}/lib/reality.sh"
XHTTP_PROFILE="${ROOT_DIR}/lib/xhttp_aws.sh"
XHTTP_RUNTIME="${ROOT_DIR}/lib/xhttp-runtime.sh"
GCORE_PROFILE="${ROOT_DIR}/xhttp_gcore.sh"
LAUNCHER_CONTENT=$(<"${ROOT_DIR}/easy_all")
BOOTSTRAP_CONTENT=$(<"${ROOT_DIR}/bootstrap.sh")

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

module_functions() {
    sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)().*/\1/p' "$1"
}

bash -n "${ROOT_DIR}/easy_all" "${ROOT_DIR}/bootstrap.sh" "${GCORE_PROFILE}" "${ROOT_DIR}"/lib/*.sh

shared_modules=(
    quota.sh
    platform.sh
    profile-common.sh
    network.sh
    mihomo-template.sh
    firewall.sh
    xray-core.sh
    scheduled-maintenance.sh
    subscription-auth.sh
    tcp-tuning.sh
)

[[ "$(<"${XHTTP_RUNTIME}")" == *'source "${SCRIPT_DIR}/cdn-traffic-guard.sh"'* ]] \
    || fail "XHTTP runtime does not source its CDN traffic guard"
[[ "${LAUNCHER_CONTENT}" == *'"lib/cdn-traffic-guard.sh"'* \
    && "${BOOTSTRAP_CONTENT}" == *'lib/cdn-traffic-guard.sh'* ]] \
    || fail "CDN traffic guard is missing from runtime packaging"
[[ "${LAUNCHER_CONTENT}" == *'"xhttp_gcore.sh"'* \
    && "${BOOTSTRAP_CONTENT}" == *'xhttp_gcore.sh'* \
    && "$(<"${GCORE_PROFILE}")" == *'source "${XHTTP_PROFILE_ROOT}/xhttp-runtime.sh"'* \
    && "$(<"${GCORE_PROFILE}")" != *'source "${XHTTP_GCORE_PROFILE_ROOT}/lib/xhttp_aws.sh"'* ]] \
    || fail "Gcore CDN profile must be packaged and reuse the XHTTP runtime"
[[ "${LAUNCHER_CONTENT}" == *'"lib/xhttp-runtime.sh"'* \
    && "${BOOTSTRAP_CONTENT}" == *'lib/xhttp-runtime.sh'* \
    && "$(<"${XHTTP_PROFILE}")" == *'source "${XHTTP_PROFILE_ROOT}/xhttp-runtime.sh"'* ]] \
    || fail "shared XHTTP runtime is missing from Profile packaging"
[[ "$(<"${XHTTP_RUNTIME}")" == *'source "${SCRIPT_DIR}/warp.sh"'* \
    && "$(<"${REALITY_PROFILE}")" == *'source "${SCRIPT_DIR}/warp.sh"'* \
    && "${LAUNCHER_CONTENT}" == *'"lib/warp.sh"'* \
    && "${BOOTSTRAP_CONTENT}" == *'lib/warp.sh'* ]] \
    || fail "WARP must be packaged and loaded by Reality and XHTTP"

for obsolete_module in \
    profile-support.sh validation.sh acme-renewal.sh reboot-schedule.sh; do
    [[ ! -e "${ROOT_DIR}/lib/${obsolete_module}" ]] \
        || fail "obsolete split module still exists: ${obsolete_module}"
done

for module in "${shared_modules[@]}"; do
    [[ "$(<"${REALITY_PROFILE}")" == *'source "${SCRIPT_DIR}/'"${module}"'"'* ]] \
        || fail "Reality does not source shared module ${module}"
    [[ "$(<"${XHTTP_RUNTIME}")" == *'source "${SCRIPT_DIR}/'"${module}"'"'* ]] \
        || fail "XHTTP runtime does not source shared module ${module}"
    [[ "${LAUNCHER_CONTENT}" == *'"lib/'"${module}"'"'* ]] \
        || fail "runtime installer does not register ${module}"
    [[ "${BOOTSTRAP_CONTENT}" == *'lib/'"${module}"* ]] \
        || fail "bootstrap does not validate ${module}"
done

for module in platform.sh profile-common.sh network.sh mihomo-template.sh firewall.sh xray-core.sh scheduled-maintenance.sh subscription-auth.sh tcp-tuning.sh; do
    while read -r function_name; do
        [[ -n "${function_name}" ]] || continue
        ! grep -Eq "^${function_name}\\(\\)" "${REALITY_PROFILE}" \
            || fail "Reality redefines shared function ${function_name}"
        ! grep -Eq "^${function_name}\\(\\)" "${XHTTP_RUNTIME}" \
            || fail "XHTTP runtime redefines shared function ${function_name}"
    done < <(module_functions "${ROOT_DIR}/lib/${module}")
done

while read -r function_name; do
    [[ -n "${function_name}" ]] || continue
    ! grep -Eq "^${function_name}\\(\\)" "${XHTTP_PROFILE}" \
        || fail "AWS Profile redefines XHTTP runtime function ${function_name}"
    ! grep -Eq "^${function_name}\\(\\)" "${GCORE_PROFILE}" \
        || fail "Gcore Profile redefines XHTTP runtime function ${function_name}"
done < <(module_functions "${XHTTP_RUNTIME}")

grep -Eq '^xhttp_render_xray_config\(\)' "${XHTTP_PROFILE}" \
    || fail "AWS Profile does not implement the XHTTP render hook"
grep -Eq '^xhttp_render_xray_config\(\)' "${GCORE_PROFILE}" \
    || fail "Gcore Profile does not implement the XHTTP render hook"

[[ "$(<"${ROOT_DIR}/lib/network.sh")" != *'fetch_mihomo_template'* ]] \
    || fail "network module must not depend on Profile template functions"

if grep -Eq 'DST-PORT,(22|65533),' "${ROOT_DIR}/sample-mihomo.yaml"; then
    fail "Mihomo subscription template must not force SSH ports to DIRECT"
fi

[[ "$(<"${ROOT_DIR}/lib/scheduled-maintenance.sh")" == *'systemctl is-enabled --quiet cron.service'* \
    && "$(<"${ROOT_DIR}/lib/scheduled-maintenance.sh")" == *'systemctl is-active --quiet cron.service'* \
    && "$(<"${ROOT_DIR}/lib/scheduled-maintenance.sh")" == *'configure_daily_reboot()'* ]] \
    || fail "scheduled maintenance must cover ACME renewal and reboot policy"

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/subscription-auth.sh"
[[ "$(normalize_allowed_tokens '{" owner ":" test-token "}')" == '{"owner":"test-token"}' ]] \
    || fail "shared subscription auth does not normalize valid credentials"
[[ "$(normalize_subscription_mode selfhost)" == "deploy" \
    && "$(normalize_subscription_mode deploy)" == "deploy" \
    && "$(normalize_subscription_mode link)" == "link" ]] \
    || fail "shared subscription modes do not use the deploy/link enum"
if normalize_allowed_tokens '{"owner":12345678}' >/dev/null 2>&1; then
    fail "shared subscription auth accepts a non-string token"
fi
if normalize_allowed_tokens \
    '{"owner":"test-token"," owner ":"friend-token"}' >/dev/null 2>&1; then
    fail "shared subscription auth accepts duplicate normalized usernames"
fi

[[ "$(<"${ROOT_DIR}/lib/tcp-tuning.sh")" == *'net.ipv4.tcp_mtu_probing = 1'* \
    && "$(<"${ROOT_DIR}/lib/tcp-tuning.sh")" == *'net.ipv4.tcp_slow_start_after_idle = 0'* \
    && "$(<"${ROOT_DIR}/lib/tcp-tuning.sh")" == *'linux-xanmod-lts-x64v'* \
    && "$(<"${ROOT_DIR}/lib/tcp-tuning.sh")" == *'show_bbrv3_status()'* \
    && "$(<"${REALITY_PROFILE}")" == *'show_bbrv3_status'* \
    && "$(<"${XHTTP_PROFILE}")" == *'show_bbrv3_status'* \
    && "$(<"${GCORE_PROFILE}")" == *'show_bbrv3_status'* \
    && "$(<"${REALITY_PROFILE}")" != *'BBR_ALLOW_EXISTING_XANMOD'* \
    && "$(<"${XHTTP_RUNTIME}")" != *'BBR_ALLOW_EXISTING_XANMOD'* ]] \
    || fail "shared XanMod BBRv3 kernel and TCP tuning policy drifted"
[[ "$(<"${REALITY_PROFILE}")" == *'ca-certificates curl wget gnupg'* \
    && "$(<"${XHTTP_RUNTIME}")" == *'ca-certificates curl wget gnupg'* ]] \
    || fail "all Profiles must install gnupg before verifying the XanMod key"

[[ "$(<"${ROOT_DIR}/lib/profile-common.sh")" == *'bash "${launcher}" register-command'* ]] \
    || fail "profiles must delegate command registration to the unified launcher"
[[ "$(<"${ROOT_DIR}/lib/profile-common.sh")" != *'已注册单文件命令'* \
    && "$(<"${ROOT_DIR}/lib/profile-common.sh")" == *'validate_domain()'* ]] \
    || fail "profile common helpers must include validation without legacy registration"

(
    BACKUP_DIR=$(mktemp -d)
    STATE_DIR="${BACKUP_DIR}/state"
    restored="${BACKUP_DIR}/restored.conf"
    trap 'rm -rf -- "${BACKUP_DIR}"' EXIT
    warn() { :; }
    sysctl() {
        case "$1" in
        -n) printf 'before-%s\n' "$2" ;;
        -p) cp "$2" "${restored}" ;;
        *) return 1 ;;
        esac
    }
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/lib/tcp-tuning.sh"
    snapshot_tcp_runtime
    grep -Fq 'net.ipv4.tcp_slow_start_after_idle = before-net.ipv4.tcp_slow_start_after_idle' \
        "${BACKUP_DIR}/pre-install-tcp-runtime.conf" \
        || fail "TCP runtime snapshot omits slow-start state"
    restore_tcp_runtime
    cmp -s "${BACKUP_DIR}/pre-install-tcp-runtime.conf" "${restored}" \
        || fail "TCP runtime rollback does not reload the snapshot"
)

(
    XRAY_CONFIG="/definitely/missing/easy_all-xray.json"
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/lib/network.sh"
    [[ "${GEMINI_OUTBOUND_DOMAIN_STRATEGY}" == "ForceIPv4" ]] \
        || fail "Google and Gemini egress must be fixed to IPv4"
    ! declare -F measure_gemini_ip_family >/dev/null \
        || fail "fixed Google and Gemini egress must not retain latency probing"
    [[ "$(gemini_ip_family_status)" == "ipv4（未应用，请执行 easy_all apply）" ]] \
        || fail "Gemini status must report the fixed unapplied family"
)

printf 'ok - shared architecture tests passed\n'
