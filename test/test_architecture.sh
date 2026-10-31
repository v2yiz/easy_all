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

[[ "${LAUNCHER_CONTENT}" == *'export LANG=C.UTF-8 LC_ALL=C.UTF-8'* ]] \
    || fail "launcher must normalize inherited locale settings"
[[ "${LAUNCHER_CONTENT}" != *'export MIHOMO_TEMPLATE_SOURCE='* ]] \
    || fail "launcher must not inject a default Mihomo template source"
[[ "$(<"${CLOUDFLARE_PROFILE}")" != *'--data-urlencode "token=${token'* ]] \
    || fail "Cloudflare Worker validation must not pass subscription tokens on the command line"

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
while IFS= read -r template_path; do
    grep -Fxq "templates/$(basename -- "${template_path}")" "${RUNTIME_MANIFEST}" \
        || fail "bundled Mihomo template is missing from the runtime manifest: ${template_path}"
done < <(find "${ROOT_DIR}/templates" -maxdepth 1 -type f -name '*.yaml' | sort)
while IFS= read -r runtime_path; do
    [[ "${runtime_path}" == *.sh ]] || continue
    while IFS= read -r sourced_module; do
        grep -Fxq "lib/${sourced_module}" "${RUNTIME_MANIFEST}" \
            || fail "runtime manifest omits sourced module lib/${sourced_module}"
    done < <(
        sed -nE 's@^[[:space:]]*source "\$\{[^}]+\}/([^"/]+\.sh)".*@\1@p' \
            "${ROOT_DIR}/${runtime_path}"
    )
done <<<"${RUNTIME_MANIFEST_CONTENT}"
grep -Fxq 'lib/reality-subscription.js' "${RUNTIME_MANIFEST}" \
    || fail "Reality njs renderer must be installed with the runtime"
for lifecycle in remove_subscription_service_runtime rollback_fresh_install uninstall_all; do
    lifecycle_body=$(sed -n "/^${lifecycle}()/,/^}/p" "${REALITY_PROFILE}")
    [[ "${lifecycle_body}" == *'"${REALITY_SUBSCRIPTION_JS}"'* ]] \
        || fail "Reality renderer cleanup is missing from ${lifecycle}"
done
[[ "$(<"${XHTTP_RUNTIME}")" != *'reality-subscription.js'* \
    && "$(<"${XHTTP_RUNTIME}")" != *'libnginx-mod-http-js'* ]] \
    || fail "XHTTP must retain its existing static renderer and dependencies"
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
    worker-config.sh
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
[[ "${RUNTIME_MANIFEST_CONTENT}" == *'lib/worker-config.sh'* \
    && "$(<"${RUNTIME_CORE}")" == *'source "${RUNTIME_LIB_DIR}/worker-config.sh"'* ]] \
    || fail "shared Worker aggregation input handling must be packaged"
reality_current=$(<"${REALITY_PROFILE}")
[[ "${reality_current}" == *'reality_worker_delete_resources "${previous_worker_domain_id}"'* \
    && "${reality_current}" == *'reality_worker_detach_domain "${previous_account_id}"'* \
    && "${reality_current}" == *'subscription_origin_domain()'* \
    && "${reality_current}" == *'PREVIOUS_SUBSCRIPTION_MODE'* ]] \
    || fail "Reality Worker aggregation must clean up the previous mode and its domains"
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

grep -Eq '^prompt_secret\(\)' "${ROOT_DIR}/lib/profile-common.sh" \
    && ! grep -Eq '^prompt_secret\(\)' "${XHTTP_RUNTIME}" "${REALITY_PROFILE}" \
    || fail "secret prompts must be shared by independently sourced Reality and CDN profiles"
for reality_renderer in "${REALITY_PROFILE}" "${ROOT_DIR}/worker-src/index.js"; do
    grep -Fq 'support-x25519mlkem768: true' "${reality_renderer}" \
        || fail "Reality ML-KEM key share flag is missing from ${reality_renderer}"
done
grep -Eq '^refresh_runtime_subscription\(\)' "${REALITY_PROFILE}" \
    && ! grep -Eq '^refresh_runtime_subscription\(\)' "${XHTTP_RUNTIME}" \
    || fail "the core-update subscription hook must belong to Reality only"
for runtime in "${REALITY_PROFILE}" "${XHTTP_RUNTIME}"; do
    rollback_body=$(sed -n '/^rollback_subscription_update()/,/^}/p' "${runtime}")
    [[ "${rollback_body}" == *'restore_state_file "${UPDATE_SUB_BACKUP_DIR}/state.env" "${STATE_FILE}"'* ]] \
        || fail "subscription rollback must use shared atomic state restoration"
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
[[ "$(<"${RUNTIME_CORE}")" == *'stop easy_all-quota.service easy_all-globalping-refresh.service'* ]] \
    || fail "runtime core must own stopping one-shot maintenance services"
for uninstall_profile in "${REALITY_PROFILE}" "${CLOUDFLARE_PROFILE}"; do
    uninstall_body=$(sed -n '/^uninstall_all()/,/^}/p' "${uninstall_profile}")
    stop_maintenance_line=$(grep -n '^    stop_maintenance_services$' <<<"${uninstall_body}" | cut -d: -f1)
    write_lock_line=$(grep -n '^    acquire_runtime_write_lock ' <<<"${uninstall_body}" | cut -d: -f1)
    first_delete_line=$(grep -nE '^[[:space:]]*(purge_cloudflare_resources_before_uninstall|reality_cloudflare_purge_managed_resources|stop_protocol_services|stop_services)\b' \
        <<<"${uninstall_body}" | head -n 1 | cut -d: -f1)
    [[ -n "${stop_maintenance_line}" && -n "${write_lock_line}" && -n "${first_delete_line}" \
        && "${stop_maintenance_line}" -lt "${write_lock_line}" \
        && "${write_lock_line}" -lt "${first_delete_line}" ]] \
        || fail "uninstall must stop maintenance units and take the runtime write lock before deleting (${uninstall_profile})"
done
! grep -Eq '^(main|usage)\(\)' "${REALITY_PROFILE}" "${CLOUDFLARE_PROFILE}" \
    || fail "profiles must not own command dispatch or usage tables"

# The declared protocol hooks may differ in protocol details, but these two carry
# no protocol-specific reason to diverge and silently drifted once already.
state_source_body=$(sed -n '/^source_state_file()/,/^}/p' "${XHTTP_RUNTIME}")
[[ "${state_source_body}" == *'unset STATE_VERSION'* ]] \
    || fail "state loading must not reuse a stale STATE_VERSION"
subscription_acceptance_body=$(sed -n '/^validate_subscription_runtime()/,/^}/p' "${XHTTP_RUNTIME}")
[[ "${subscription_acceptance_body}" == *'openssl base64 -d -A'* \
    && "${subscription_acceptance_body}" == *"type=xhttp"* ]] \
    || fail "CDN subscription acceptance must decode and validate the base64 payload"
reality_acceptance_body=$(sed -n '/^validate_subscription_runtime()/,/^}/p' "${REALITY_PROFILE}")
[[ "${reality_acceptance_body}" == *'openssl base64 -d -A'* \
    && "${reality_acceptance_body}" == *'security=reality'* ]] \
    || fail "Reality subscription acceptance must decode and validate the base64 payload"
# `... | grep -q` exits as soon as it matches, and under `set -o pipefail` the upstream writer's
# SIGPIPE turns the whole pipeline into a failure. Both hooks decode into a variable instead.
for acceptance_body in "${subscription_acceptance_body}" "${reality_acceptance_body}"; do
    ! grep -Eq '\|[[:space:]]*grep[[:space:]]+-[A-Za-z]*q' <<<"${acceptance_body}" \
        || fail "subscription acceptance must not pipe into grep -q under pipefail"
done

grep -Eq '^xhttp_render_xray_config\(\)' "${CLOUDFLARE_PROFILE}" \
    || fail "Cloudflare Profile does not implement the XHTTP render hook"
! grep -Eq '^write_subscriptions\(\)' "${CLOUDFLARE_PROFILE}" \
    || fail "CDN profiles must use shared subscription rendering"
! grep -Eq '^finish_xhttp_apply\(\)' "${CLOUDFLARE_PROFILE}" \
    || fail "CDN profiles must use shared apply finalization"
! grep -Eq 'cloudflare_cleanup_stale_header_rules' "${CLOUDFLARE_PROFILE}" \
    || fail "Cloudflare must not delete rules by zone-wide easy_all prefix"
grep -Fq 'state_version_supported "${state_version}" "${REALITY_MIN_STATE_VERSION}"' "${ROOT_DIR}/easy_all" \
    && grep -Fq 'state_version_supported "${state_version}" "${CLOUDFLARE_MIN_STATE_VERSION}"' "${ROOT_DIR}/easy_all" \
    || fail "all modes must enforce their minimum compatible state schema"
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

if grep -Eq 'DST-PORT,(22|65533),' "${ROOT_DIR}/templates/mihomo-classic.yaml"; then
    fail "Mihomo subscription template must not force SSH ports to DIRECT"
fi
grep -Fq 'GEOSITE,google,PROXY' "${ROOT_DIR}/templates/mihomo-classic.yaml" \
    || fail "Mihomo subscription template must keep non-YouTube Google services on the VPS exit"
grep -Fxq '# EASY_ALL_WORKER_RULE' "${ROOT_DIR}/templates/mihomo-classic.yaml" \
    || fail "Mihomo subscription template must expose the conditional Worker rule marker"
grep -Fq "'https://1.1.1.1/dns-query#PROXY'" "${ROOT_DIR}/templates/mihomo-classic.yaml" \
    || fail "Mihomo public DNS must use a proxied resolver"
awk '
    $0 == "    - name: GLOBAL" { in_global=1; next }
    in_global && $0 == "        - PROXY" { has_proxy=1; next }
    in_global && /^    - name:/ { exit }
    END { exit !(in_global && has_proxy) }
' "${ROOT_DIR}/templates/mihomo-classic.yaml" \
    || fail "Mihomo template must define GLOBAL as a PROXY-only group"
if grep -Eq '代理模式|油管兜底' "${ROOT_DIR}/templates/mihomo-classic.yaml"; then
    fail "Mihomo must use PROXY directly"
fi
grep -Fq 'GEOSITE,github,PROXY' "${ROOT_DIR}/templates/mihomo-classic.yaml" \
    || fail "Mihomo subscription template must keep GitHub services on the VPS exit"
if grep -Fq "'geosite:github':" "${ROOT_DIR}/templates/mihomo-classic.yaml"; then
    fail "GitHub DNS should inherit the default proxied resolver"
fi
# The shipped default is the COMMON lite template and must keep the same exit policy.
default_template="${ROOT_DIR}/templates/mihomo.yaml"
if grep -Eq 'DST-PORT,(22|65533),' "${default_template}"; then
    fail "default Mihomo template must not force SSH ports to DIRECT"
fi
grep -Fq 'RULE-SET,geosite-google,PROXY' "${default_template}" \
    || fail "default Mihomo template must keep Google services on the VPS exit"
grep -Fq 'MATCH,PROXY' "${default_template}" \
    || fail "default Mihomo template must fall back to PROXY"
grep -Fq 'AND,((NETWORK,UDP),(DST-PORT,443)),REJECT' "${default_template}" \
    || fail "default Mihomo template must reject QUIC before the TCP fallback"
grep -Fq 'AND,((NETWORK,TCP),(DST-PORT,5228-5230)),PROXY' "${default_template}" \
    || fail "default Mihomo template must keep the FCM push ports on PROXY"
awk '
    $0 == "    - name: GLOBAL" { in_global=1; next }
    in_global && $0 == "        - PROXY" { has_proxy=1; next }
    in_global && /^    - name:/ { exit }
    END { exit !(in_global && has_proxy) }
' "${default_template}" \
    || fail "default Mihomo template must define GLOBAL as a PROXY-only group"
if grep -Eq '代理模式|油管兜底' "${default_template}"; then
    fail "default Mihomo template must use PROXY directly"
fi

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

(
    quota_enabled() { return 0; }
    quota_active_accounts_json() { return 1; }
    die() { exit 1; }
    if (write_subscription_token_map) >/dev/null 2>&1; then
        fail "token map must fail when quota accounts cannot be read"
    fi
)
(
    quota_enabled() { return 0; }
    quota_active_accounts_json() { printf '%s' '{"owner":{"token":"t"}}'; }
    output=$(write_subscription_token_map) \
        || fail "token map must still render readable quota accounts"
    [[ "${output}" == *'"t" "owner";'* ]] \
        || fail "token map must include the active quota token"
)

[[ "$(<"${ROOT_DIR}/lib/tcp-tuning.sh")" == *'net.ipv4.tcp_mtu_probing = 1'* \
    && "$(<"${ROOT_DIR}/lib/tcp-tuning.sh")" == *'net.ipv4.tcp_slow_start_after_idle = 0'* \
    && "$(<"${ROOT_DIR}/lib/tcp-tuning.sh")" == *'linux-xanmod-lts-x64v'* \
    && "$(<"${ROOT_DIR}/lib/tcp-tuning.sh")" == *'show_bbrv3_status()'* \
    && "$(<"${REALITY_PROFILE}")" == *'show_tcp_acceleration_status'* \
    && "$(<"${REALITY_PROFILE}")" != *'BBR_ALLOW_EXISTING_XANMOD'* \
    && "$(<"${XHTTP_RUNTIME}")" != *'BBR_ALLOW_EXISTING_XANMOD'* ]] \
    || fail "shared XanMod BBRv3 kernel and TCP tuning policy drifted"
[[ "$(<"${REALITY_PROFILE}")" == *'ca-certificates curl wget gnupg'* \
    && "$(<"${XHTTP_RUNTIME}")" == *'ca-certificates curl wget gnupg'* ]] \
    || fail "all Profiles must install gnupg before verifying the XanMod key"

[[ "$(<"${ROOT_DIR}/lib/profile-common.sh")" != *'register_easy_all_command()'* \
    && "$(<"${ROOT_DIR}/lib/profile-common.sh")" == *'validate_domain()'* ]] \
    || fail "profile common must not retain dead launcher registration code"

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
