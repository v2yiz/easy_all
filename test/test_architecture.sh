#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
REALITY_PROFILE="${ROOT_DIR}/profiles/reality.sh"
XHTTP_PROFILE="${ROOT_DIR}/profiles/xhttp-aws.sh"
XHTTP_RUNTIME="${ROOT_DIR}/lib/xhttp-runtime.sh"
CLOUDFLARE_PROFILE="${ROOT_DIR}/profiles/xhttp-cloudflare.sh"
GCORE_PROFILE="${ROOT_DIR}/profiles/websocket-gcore.sh"
LAUNCHER_CONTENT=$(<"${ROOT_DIR}/easy_all")
BOOTSTRAP_CONTENT=$(<"${ROOT_DIR}/bootstrap.sh")

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

module_functions() {
    sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)().*/\1/p' "$1"
}

bash -n "${ROOT_DIR}/easy_all" "${ROOT_DIR}/bootstrap.sh" \
    "${ROOT_DIR}"/profiles/*.sh "${ROOT_DIR}"/lib/*.sh \
    "${ROOT_DIR}/scripts/debian-init.sh"

for required_path in \
    profiles/reality.sh profiles/xhttp-cloudflare.sh profiles/xhttp-aws.sh profiles/websocket-gcore.sh \
    lib/xhttp-runtime.sh lib/globalping-cdn.sh lib/cloudflare-ip-pool.sh lib/quota.sh lib/cdn-traffic-guard.sh \
    lib/platform.sh lib/profile-common.sh lib/network.sh \
    lib/mihomo-template.sh lib/firewall.sh lib/xray-core.sh \
    lib/scheduled-maintenance.sh lib/subscription-auth.sh lib/tcp-tuning.sh; do
    [[ -f "${ROOT_DIR}/${required_path}" ]] \
        || fail "required runtime path is missing: ${required_path}"
done
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
[[ "${LAUNCHER_CONTENT}" == *'"lib/globalping-cdn.sh"'* \
    && "${BOOTSTRAP_CONTENT}" == *'lib/globalping-cdn.sh'* \
    && "$(<"${CLOUDFLARE_PROFILE}")" == *'source "${XHTTP_PROFILE_ROOT}/globalping-cdn.sh"'* \
    && "$(<"${XHTTP_PROFILE}")" == *'source "${XHTTP_PROFILE_ROOT}/globalping-cdn.sh"'* \
    && "$(<"${GCORE_PROFILE}")" != *'globalping-cdn.sh'* ]] \
    || fail "Globalping CDN module must remain scoped to Cloudflare and AWS"
[[ "${LAUNCHER_CONTENT}" == *'"lib/cloudflare-ip-pool.sh"'* \
    && "${BOOTSTRAP_CONTENT}" == *'lib/cloudflare-ip-pool.sh'* \
    && "$(<"${CLOUDFLARE_PROFILE}")" == *'source "${XHTTP_PROFILE_ROOT}/cloudflare-ip-pool.sh"'* \
    && "$(<"${XHTTP_PROFILE}")" != *'cloudflare-ip-pool.sh'* ]] \
    || fail "Cloudflare official IP pool must remain scoped to mode 2"
[[ "${LAUNCHER_CONTENT}" == *'"profiles/xhttp-cloudflare.sh"'* \
    && "${BOOTSTRAP_CONTENT}" == *'profiles/xhttp-cloudflare.sh'* \
    && "$(<"${CLOUDFLARE_PROFILE}")" == *'source "${XHTTP_PROFILE_ROOT}/xhttp-runtime.sh"'* \
    && "$(<"${CLOUDFLARE_PROFILE}")" != *'xhttp-aws.sh'* ]] \
    || fail "Cloudflare CDN profile must be packaged and reuse the XHTTP runtime"
[[ "${LAUNCHER_CONTENT}" == *'"lib/xhttp-runtime.sh"'* \
    && "${BOOTSTRAP_CONTENT}" == *'lib/xhttp-runtime.sh'* \
    && "$(<"${XHTTP_PROFILE}")" == *'source "${XHTTP_PROFILE_ROOT}/xhttp-runtime.sh"'* ]] \
    || fail "shared XHTTP runtime is missing from Profile packaging"
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
    ! grep -Eq "^${function_name}\\(\\)" "${CLOUDFLARE_PROFILE}" \
        || fail "Cloudflare Profile redefines XHTTP runtime function ${function_name}"
done < <(module_functions "${XHTTP_RUNTIME}")

grep -Eq '^xhttp_render_xray_config\(\)' "${XHTTP_PROFILE}" \
    || fail "AWS Profile does not implement the XHTTP render hook"
grep -Eq '^xhttp_render_xray_config\(\)' "${CLOUDFLARE_PROFILE}" \
    || fail "Cloudflare Profile does not implement the XHTTP render hook"
[[ "$(<"${ROOT_DIR}/lib/network.sh")" != *'fetch_mihomo_template'* ]] \
    || fail "network module must not depend on Profile template functions"

if grep -Eq 'DST-PORT,(22|65533),' "${ROOT_DIR}/templates/mihomo.yaml"; then
    fail "Mihomo subscription template must not force SSH ports to DIRECT"
fi
grep -Fq 'DOMAIN-SUFFIX,gemini.google.com,PROXY' "${ROOT_DIR}/templates/mihomo.yaml" \
    || fail "Mihomo subscription template must keep Gemini on the selected PROXY exit"

[[ "$(<"${ROOT_DIR}/lib/scheduled-maintenance.sh")" == *'systemctl is-enabled --quiet cron.service'* \
    && "$(<"${ROOT_DIR}/lib/scheduled-maintenance.sh")" == *'systemctl is-active --quiet cron.service'* \
    && "$(<"${ROOT_DIR}/lib/scheduled-maintenance.sh")" == *'configure_daily_reboot()'* ]] \
    || fail "scheduled maintenance must cover ACME renewal and reboot policy"

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/subscription-auth.sh"
[[ "$(normalize_allowed_tokens '{" owner ":" test-token "}')" == '{"owner":"test-token"}' ]] \
    || fail "shared subscription auth does not normalize valid credentials"
[[ "$(normalize_subscription_mode deploy)" == "deploy" \
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
    || fail "profile common helpers must include validation and unified registration"

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
    grep -Fq 'net.ipv4.tcp_keepalive_time = before-net.ipv4.tcp_keepalive_time' \
        "${BACKUP_DIR}/pre-install-tcp-runtime.conf" \
        || fail "TCP runtime snapshot omits keepalive state"
    grep -Fq 'net.ipv4.ip_local_port_range = before-net.ipv4.ip_local_port_range' \
        "${BACKUP_DIR}/pre-install-tcp-runtime.conf" \
        || fail "TCP runtime snapshot omits ephemeral port state"
    restore_tcp_runtime
    cmp -s "${BACKUP_DIR}/pre-install-tcp-runtime.conf" "${restored}" \
        || fail "TCP runtime rollback does not reload the snapshot"
)

(
    XRAY_CONFIG="/definitely/missing/easy_all-xray.json"
    die() { fail "$*"; }
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/lib/network.sh"
    [[ "${XRAY_OUTBOUND_DOMAIN_STRATEGY}" == "AsIs" ]] \
        || fail "Xray direct egress must use automatic dual-stack resolution"
    jq -e '
        .tcpKeepAliveIdle == 300
        and .tcpKeepAliveInterval == 30
    ' <<<"$(xray_inbound_sockopt_json)" >/dev/null \
        || fail "Xray inbound TCP keepalive policy drifted"
    jq -e '
        map(.tag) == ["direct","direct-ipv4","block"]
        and .[0].settings.domainStrategy == "AsIs"
        and .[1].settings.domainStrategy == "ForceIPv4"
    ' <<<"$(xray_direct_outbounds_json)" >/dev/null \
        || fail "shared direct outbound policy is invalid"
    jq -e '
        map(.tag) == ["direct","direct-ipv4","block"]
        and .[0].settings.domainStrategy == "AsIs"
        and .[1].settings.domainStrategy == "ForceIPv4"
    ' <<<"$(xray_xhttp_outbounds_json)" >/dev/null \
        || fail "shared XHTTP outbound policy must stay direct"
    jq -e '
        .domainStrategy == "IPOnDemand"
        and (.rules[0].ip | index("169.254.0.0/16"))
        and .rules[0].outboundTag == "block"
        and .rules[1].outboundTag == "direct-ipv4"
        and (.rules[1].domain | index("domain:gemini.google.com"))
        and (.rules[1].domain | index("domain:accounts.google.com"))
        and (.rules[1].domain | index("domain:gemini.gstatic.com"))
        and (.rules[1].domain | index("domain:www.gstatic.com"))
        and (.rules[1].domain | index("domain:lh3.googleusercontent.com"))
        and .rules[2].outboundTag == "direct"
    ' <<<"$(xray_direct_routing_json)" >/dev/null \
        || fail "shared direct routing policy is invalid"
    jq -e '
        .domainStrategy == "IPOnDemand"
        and .rules[0].outboundTag == "block"
        and .rules[1].outboundTag == "direct-ipv4"
        and .rules[2].outboundTag == "direct"
    ' <<<"$(xray_xhttp_routing_json)" >/dev/null \
        || fail "shared XHTTP routing policy must stay direct"
)

printf 'ok - shared architecture tests passed\n'
