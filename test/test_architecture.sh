#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
REALITY_PROFILE="${ROOT_DIR}/profiles/reality.sh"
XHTTP_PROFILE="${ROOT_DIR}/profiles/xhttp-cloudflare-streamup.sh"
XHTTP_RUNTIME="${ROOT_DIR}/lib/xhttp-runtime.sh"
RUNTIME_CORE="${ROOT_DIR}/lib/runtime-core.sh"
CLOUDFLARE_PROFILE="${ROOT_DIR}/profiles/xhttp-cloudflare-streamup.sh"
LAUNCHER_CONTENT=$(<"${ROOT_DIR}/easy_all")
BOOTSTRAP_CONTENT=$(<"${ROOT_DIR}/bootstrap.sh")
RUNTIME_MANIFEST="${ROOT_DIR}/runtime.manifest"
RUNTIME_MANIFEST_CONTENT=$(grep -Ev '^[[:space:]]*(#|$)' "${RUNTIME_MANIFEST}")

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

module_functions() {
    sed -n 's/^[[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\)().*/\1/p' "$1"
}

for script in "${ROOT_DIR}/easy_all" "${ROOT_DIR}/bootstrap.sh" \
    "${ROOT_DIR}"/profiles/*.sh "${ROOT_DIR}"/lib/*.sh \
    "${ROOT_DIR}"/test/*.sh "${ROOT_DIR}/scripts/debian-init.sh"; do
    bash -n "${script}"
done

[[ -f "${RUNTIME_MANIFEST}" ]] || fail "runtime manifest is missing"
while IFS= read -r required_path; do
    [[ -f "${ROOT_DIR}/${required_path}" ]] \
        || fail "required runtime path is missing: ${required_path}"
done <<<"${RUNTIME_MANIFEST_CONTENT}"
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

[[ "${RUNTIME_MANIFEST_CONTENT}" == *'lib/globalping-cdn.sh'* \
    && "$(<"${CLOUDFLARE_PROFILE}")" == *'source "${XHTTP_LIB_DIR}/globalping-cdn.sh"'* ]] \
    || fail "Globalping CDN module is missing from the Cloudflare profile"
[[ "${RUNTIME_MANIFEST_CONTENT}" == *'lib/cloudflare-ip-pool.sh'* \
    && "$(<"${CLOUDFLARE_PROFILE}")" == *'source "${XHTTP_LIB_DIR}/cloudflare-ip-pool.sh"'* ]] \
    || fail "Cloudflare official IP pool must remain scoped to Cloudflare streamup mode"
[[ "${RUNTIME_MANIFEST_CONTENT}" == *'profiles/xhttp-cloudflare-streamup.sh'* \
    && "${RUNTIME_MANIFEST_CONTENT}" == *'lib/xhttp-runtime.sh'* \
    && "$(<"${CLOUDFLARE_PROFILE}")" == *'source "${XHTTP_LIB_DIR}/xhttp-runtime.sh"'* ]] \
    || fail "shared XHTTP runtime is missing from Profile packaging"
[[ "$(<"${REALITY_PROFILE}")" == *'source "${SCRIPT_DIR}/runtime-core.sh"'* \
    && "$(<"${XHTTP_RUNTIME}")" == *'source "${SCRIPT_DIR}/runtime-core.sh"'* ]] \
    || fail "all profiles must reuse the protocol-neutral runtime core"
[[ "${BOOTSTRAP_CONTENT}" == *'"${REPO_DIR}/easy_all" verify-release'* \
    && "${BOOTSTRAP_CONTENT}" != *'lib/xhttp-runtime.sh'* ]] \
    || fail "bootstrap must delegate target runtime validation to the target release"

for retired_identifier in \
    XHTTP_PROFILE_FILE ENTRY_SCRIPT_FILE EASY_ALL_ENTRY_SCRIPT \
    XHTTP_ORIGIN_DNS_NAME \
    verify_origin_dns issue_origin_certificate xhttp_issue_origin_certificate \
    cloudflare_zone_for_domain; do
    ! grep -Eq "(^|[^[:alnum:]_])${retired_identifier}([^[:alnum:]_]|$)" \
        "${ROOT_DIR}/easy_all" "${REALITY_PROFILE}" \
        "${XHTTP_RUNTIME}" "${CLOUDFLARE_PROFILE}" >/dev/null \
        || fail "retired runtime identifier remains: ${retired_identifier}"
done
for retired_xhttp_identifier in \
    ACME_HOME ACME_BIN ACME_OWNERSHIP_MARKER CERT_RELOAD_HOOK install_acme \
    remove_managed_acme_domain remove_managed_acme_cron; do
    ! grep -Eq "(^|[^[:alnum:]_])${retired_xhttp_identifier}([^[:alnum:]_]|$)" \
        "${XHTTP_RUNTIME}" "${CLOUDFLARE_PROFILE}" >/dev/null \
        || fail "retired XHTTP identifier remains: ${retired_xhttp_identifier}"
done
for retired_acme_identifier in \
    ACME_HOME ACME_BIN ACME_OWNERSHIP_MARKER CERT_RELOAD_HOOK install_acme \
    install_acme_from_github run_acme ensure_acme_renewal_setup \
    remove_managed_acme_domain remove_managed_acme_cron; do
    ! grep -Eq "(^|[^[:alnum:]_])${retired_acme_identifier}([^[:alnum:]_]|$)" \
        "${ROOT_DIR}/easy_all" "${REALITY_PROFILE}" \
        "${ROOT_DIR}"/lib/*.sh >/dev/null \
        || fail "retired ACME identifier remains: ${retired_acme_identifier}"
done
for module in "${shared_modules[@]}"; do
    [[ "$(<"${RUNTIME_CORE}")" == *'source "${RUNTIME_LIB_DIR}/'"${module}"'"'* ]] \
        || fail "runtime core does not source shared module ${module}"
    grep -Fxq "lib/${module}" "${RUNTIME_MANIFEST}" \
        || fail "runtime manifest does not install ${module}"
done

for module in log.sh runtime-core.sh platform.sh profile-common.sh network.sh mihomo-template.sh firewall.sh xray-core.sh scheduled-maintenance.sh subscription-auth.sh tcp-tuning.sh; do
    while read -r function_name; do
        [[ -n "${function_name}" ]] || continue
        ! grep -Eq "^${function_name}\\(\\)" "${REALITY_PROFILE}" \
            || fail "Reality redefines shared function ${function_name}"
        ! grep -Eq "^${function_name}\\(\\)" "${XHTTP_RUNTIME}" \
            || fail "XHTTP runtime redefines shared function ${function_name}"
        ! grep -Eq "^${function_name}\\(\\)" "${CLOUDFLARE_PROFILE}" \
            || fail "Cloudflare Profile redefines shared function ${function_name}"
    done < <(module_functions "${ROOT_DIR}/lib/${module}")
done

protocol_hook_names=(
    check_install_conflicts configure_ufw install_packages rebuild_traffic_runtime
    restore_preinstall_firewall rollback_subscription_update show_subscription
    snapshot_fresh_install snapshot_subscription_update snapshot_ufw_state
    source_state_file validate_protocol_runtime validate_subscription_runtime
    write_xray_config
)
while IFS= read -r function_name; do
    allowed_hook=0
    for hook_name in "${protocol_hook_names[@]}"; do
        [[ "${function_name}" != "${hook_name}" ]] || allowed_hook=1
    done
    [[ "${allowed_hook}" == "1" ]] \
        || fail "Reality duplicates non-hook XHTTP runtime function ${function_name}"
done < <(
    comm -12 \
        <(module_functions "${REALITY_PROFILE}" | sort -u) \
        <(module_functions "${XHTTP_RUNTIME}" | sort -u)
)

grep -Eq '^update_current_core\(\)' "${RUNTIME_CORE}" \
    && grep -Fq 'xray-version.missing' "${RUNTIME_CORE}" \
    && ! grep -Eq '^update_current_core\(\)' "${REALITY_PROFILE}" "${XHTTP_RUNTIME}" \
    || fail "Xray core update and complete rollback must be owned by runtime-core"
grep -Eq '^cleanup\(\)' "${RUNTIME_CORE}" \
    && ! grep -Eq '^cleanup\(\)' "${REALITY_PROFILE}" "${XHTTP_RUNTIME}" \
    || fail "runtime cleanup must have one shared implementation"
grep -Eq '^uri_encode\(\)' "${RUNTIME_CORE}" \
    && ! grep -Eq '^uri_encode\(\)' "${REALITY_PROFILE}" "${XHTTP_RUNTIME}" \
    || fail "runtime URI encoding must have one shared implementation"
! grep -Eq '^(main|usage)\(\)' "${REALITY_PROFILE}" "${CLOUDFLARE_PROFILE}" \
    || fail "profiles must not own command dispatch or usage tables"

grep -Eq '^xhttp_render_xray_config\(\)' "${CLOUDFLARE_PROFILE}" \
    || fail "Cloudflare Profile does not implement the XHTTP render hook"
! grep -Eq '^write_subscriptions\(\)' "${CLOUDFLARE_PROFILE}" \
    || fail "CDN profiles must use shared subscription rendering"
! grep -Eq '^finish_xhttp_apply\(\)' "${CLOUDFLARE_PROFILE}" \
    || fail "CDN profiles must use shared apply finalization"
! grep -Eq 'cloudflare_cleanup_stale_header_rules' "${CLOUDFLARE_PROFILE}" \
    || fail "Cloudflare must not delete rules by zone-wide easy_all prefix"
grep -Fq '[[ "${state_version}" == "7" ]]' "${ROOT_DIR}/easy_all" \
    && grep -Fq '[[ "${state_version}" == "9" ]]' "${ROOT_DIR}/easy_all" \
    || fail "all modes must enforce their current state schema"
[[ "$(<"${XHTTP_RUNTIME}")" == *'"${UPDATE_SUB_BACKUP_DIR}/certificate.pem"'* \
    && "$(<"${XHTTP_RUNTIME}")" == *'"${UPDATE_SUB_BACKUP_DIR}/private.key"'* ]] \
    || fail "CDN rollback must preserve local TLS certificate and key"
finish_apply_body=$(sed -n '/^finish_xhttp_apply()/,/^}/p' "${XHTTP_RUNTIME}")
[[ "${finish_apply_body}" != *'UPDATE_SUB_ROLLBACK_ON_EXIT=0'* \
    && "${finish_apply_body}" != *'end_quota_maintenance'* ]] \
    || fail "shared apply finalization must not commit the caller-owned rollback transaction"
[[ "${finish_apply_body}" == *'[[ "${defer_state_save}" == "1" ]] || save_state'* \
    && "${finish_apply_body}" == *'[[ "${defer_state_save}" == "1" ]] || show_subscription'* ]] \
    || fail "deferred Worker updates must not reload stale state before commit"
grep -Fq 'commit_subscription_update' "${CLOUDFLARE_PROFILE}" \
    || fail "CDN profiles must commit rollback only after provider-specific validation"
[[ "$(<"${ROOT_DIR}/lib/network.sh")" != *'fetch_mihomo_template'* ]] \
    || fail "network module must not depend on Profile template functions"

if grep -Eq 'DST-PORT,(22|65533),' "${ROOT_DIR}/templates/mihomo.yaml"; then
    fail "Mihomo subscription template must not force SSH ports to DIRECT"
fi
grep -Fq 'GEOSITE,google,PROXY' "${ROOT_DIR}/templates/mihomo.yaml" \
    || fail "Mihomo subscription template must keep Gemini and all Google services on the VPS exit"
grep -Fq "'geosite:google':" "${ROOT_DIR}/templates/mihomo.yaml" \
    || fail "Google services must have an explicit DNS policy matching their proxy route"

[[ "$(<"${ROOT_DIR}/lib/scheduled-maintenance.sh")" == *'configure_daily_reboot()'* \
    && "$(<"${ROOT_DIR}/lib/scheduled-maintenance.sh")" != *'refresh-xray-assets'* \
    && "$(<"${ROOT_DIR}/lib/scheduled-maintenance.sh")" != *'acme'* ]] \
    || fail "scheduled maintenance must cover reboot policy without removed asset refresh or ACME"
[[ "$(<"${XHTTP_RUNTIME}")" == *'snapshot_platform_security_state'* ]] \
    || fail "CDN fresh installs must snapshot shared platform security state"
for profile in "${CLOUDFLARE_PROFILE}"; do
    rollback_body=$(sed -n '/^rollback_fresh_install()/,/^}/p' "${profile}")
    [[ "${rollback_body}" == *'restore_platform_security_state'* \
        && "${rollback_body}" == *'restore_bbr_tcp_install_state'* \
        && "${rollback_body}" == *'restore_preinstall_crontab'* ]] \
        || fail "$(basename "${profile}") fresh rollback does not restore shared host state"
done
cloudflare_install=$(sed -n '/^install_all()/,/^}/p' "${CLOUDFLARE_PROFILE}")
cloudflare_refresh_line=$(grep -n 'refresh_globalping_cache' <<<"${cloudflare_install}" | head -n 1 | cut -d: -f1)
cloudflare_deploy_line=$(grep -n 'cloudflare_deploy_subscription_worker' <<<"${cloudflare_install}" | head -n 1 | cut -d: -f1)
cloudflare_validate_line=$(grep -n 'cloudflare_validate_subscription_worker' <<<"${cloudflare_install}" | head -n 1 | cut -d: -f1)
cloudflare_save_line=$(grep -n 'save_state' <<<"${cloudflare_install}" | head -n 1 | cut -d: -f1)
[[ -n "${cloudflare_refresh_line}" && -n "${cloudflare_deploy_line}" \
    && -n "${cloudflare_validate_line}" && -n "${cloudflare_save_line}" \
    && "${cloudflare_refresh_line}" -lt "${cloudflare_deploy_line}" \
    && "${cloudflare_deploy_line}" -lt "${cloudflare_validate_line}" \
    && "${cloudflare_validate_line}" -lt "${cloudflare_save_line}" ]] \
    || fail "Cloudflare must commit state only after Worker aggregation validation"
cloudflare_rollback_body=$(sed -n '/^rollback_fresh_install()/,/^}/p' "${CLOUDFLARE_PROFILE}")
[[ "${cloudflare_rollback_body}" == *'cloudflare_rollback_fresh_install_resources'* \
    && "${cloudflare_rollback_body}" != *'purge_cloudflare_resources_before_uninstall'* ]] \
    || fail "CDN fresh rollback must attempt provider resource cleanup before local rollback"
[[ "$(<"${ROOT_DIR}/lib/subscription-auth.sh")" == *'access_log off;'* ]] \
    || fail "token-bearing subscription locations must suppress access logs"

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
    info() { :; }
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/lib/network.sh"
    VPS_IP_FAMILY="ipv4"
    VPS_PUBLIC_IPV6=""
    [[ "${XRAY_OUTBOUND_DOMAIN_STRATEGY}" == "UseIPv4" ]] \
        || fail "Xray direct egress must resolve IPv4 only"
    jq -e '
        .tcpKeepAliveIdle == 300
        and .tcpKeepAliveInterval == 30
    ' <<<"$(xray_inbound_sockopt_json)" >/dev/null \
        || fail "Xray inbound TCP keepalive policy drifted"
    jq -e '
        map(.tag) == ["direct","block"]
        and .[0].settings.domainStrategy == "UseIPv4"
        and .[0].targetStrategy == "ForceIPv4"
        and .[0].sendThrough == "0.0.0.0"
        and .[1].protocol == "blackhole"
    ' <<<"$(xray_direct_outbounds_json)" >/dev/null \
        || fail "shared direct outbound policy is invalid"
    jq -e '
        map(.tag) == ["direct","block"]
        and .[0].settings.domainStrategy == "UseIPv4"
        and .[0].targetStrategy == "ForceIPv4"
        and .[1].protocol == "blackhole"
    ' <<<"$(xray_xhttp_outbounds_json)" >/dev/null \
        || fail "shared XHTTP outbound policy must stay direct"
    jq -e '
        .domainStrategy == "IPOnDemand"
        and (.rules[0].ip | index("169.254.0.0/16"))
        and .rules[0].outboundTag == "block"
        and .rules[1].outboundTag == "block"
        and .rules[1].network == "udp"
        and .rules[1].port == "443"
        and .rules[2].outboundTag == "direct"
    ' <<<"$(xray_direct_routing_json)" >/dev/null \
        || fail "shared direct routing policy is invalid"
    jq -e '
        .domainStrategy == "IPOnDemand"
        and .rules[0].outboundTag == "block"
        and .rules[1].outboundTag == "block"
        and .rules[1].network == "udp"
        and .rules[1].port == "443"
        and .rules[2].outboundTag == "direct"
    ' <<<"$(xray_xhttp_routing_json)" >/dev/null \
        || fail "shared XHTTP routing policy must stay direct"

    VPS_IP_FAMILY="dual"
    VPS_PUBLIC_IPV6="2001:db8::10"
    GOOGLE_EGRESS_MODE="ipv6"
    GOOGLE_EGRESS_RESOLVED="ipv6"
    jq -e '
        map(.tag) == ["direct","block"]
        and .[0].settings.domainStrategy == "UseIPv4"
        and .[0].targetStrategy == "ForceIPv4"
        and .[0].sendThrough == "0.0.0.0"
    ' <<<"$(xray_direct_outbounds_json)" >/dev/null \
        || fail "legacy dual/IPv6 state must render IPv4-only outbounds"
    jq -e '
        .rules | length == 3
        and .[2].outboundTag == "direct"
    ' <<<"$(xray_direct_routing_json)" >/dev/null \
        || fail "legacy dual state must not emit Google family routes"
    refresh_google_egress_selection >/dev/null
    [[ "${VPS_IP_FAMILY}:${VPS_PUBLIC_IPV6}:${GOOGLE_EGRESS_MODE}:${GOOGLE_EGRESS_RESOLVED}" \
        == "ipv4::ipv4:ipv4" ]] \
        || fail "legacy address-family state must normalize to IPv4"
)

printf 'ok - shared architecture tests passed\n'
