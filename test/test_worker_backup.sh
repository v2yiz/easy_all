#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "${TMP_DIR}"' EXIT
source "${ROOT_DIR}/lib/worker-backup.sh"
fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
die() { fail "$@"; }
info() { :; }
warn() { :; }
validate_domain() { [[ "$1" == *.* ]]; }
validate_cloudflare_worker_name() { [[ "$1" =~ ^[a-z0-9-]+$ ]]; }
validate_uuid() { [[ "$1" =~ ^[0-9a-f-]{36}$ ]]; }
validate_public_ipv4() { [[ "$1" == 104.* ]]; }
quota_enabled() { return 0; } # Backup remains independent even with VPS quotas enabled.
WORKER_BACKUP_DOMAIN=backup.example.com
WORKER_BACKUP_NAME=easyall-backup-test
WORKER_BACKUP_UUID=11111111-2222-4333-8444-555555555555
WORKER_BACKUP_PATH=/vless-test
WORKER_BACKUP_IPS='[]'
CLOUDFLARE_ZONE_NAME=example.com
VLESS_CDN_DOMAIN=node.example.com
SUBSCRIPTION_DOMAIN=sub.example.com
CLOUDFLARE_WORKER_NAME=easyall
CLOUDFLARE_WORKER_DOMAIN_ID=subscription-domain
validate_worker_backup_state
cloudflare_client_candidates() {
    printf '104.16.1.1\tfailed\n'
    for index in 2 3 4 5 6 7; do
        printf '104.16.%s.%s\tcandidate\n' "${index}" "${index}"
    done
}
worker_backup_probe() { [[ "${1:-}" != '104.16.1.1' ]]; }
WORKER_BACKUP_DOMAIN_ID=backup-domain
cloudflare_refresh_backup_nodes
[[ "$(jq length <<<"${WORKER_BACKUP_IPS}")" == "6" ]] || fail 'select six successful candidate IPs'
[[ "$(build_worker_backup_links | wc -l | tr -d ' ')" == 6 ]] || fail 'publish six IP nodes'
[[ "$(build_worker_backup_links)" != *'@backup.example.com:443'* ]] || fail 'omit domain server entry'
[[ "$(build_worker_backup_mihomo)" == *'udp: false'* ]] || fail 'TCP only'
[[ "$(build_worker_backup_links)" == *'host=backup.example.com&sni=backup.example.com'* ]] || fail 'separate server and TLS hostname'
worker_backup_probe() { return 1; }
previous_ips=${WORKER_BACKUP_IPS}
cloudflare_refresh_backup_nodes
[[ "${WORKER_BACKUP_IPS}" == "${previous_ips}" ]] || fail 'preserve last successful list on total failure'
WORKER_BACKUP_IPS='[]'
cloudflare_refresh_backup_nodes
[[ -z "$(build_worker_backup_links)" ]] || fail 'first failure publishes no domain fallback'
# Deployment checks metadata, ordering and dynamic-scope isolation.
RUNTIME_TMP=${TMP_DIR}
XHTTP_CLOUDFLARE_PROFILE_ROOT=${ROOT_DIR}/profiles
CLOUDFLARE_API_BASE=https://api.invalid
CLOUDFLARE_ACCOUNT_ID=account
CLOUDFLARE_API_TOKEN=test-token
CLOUDFLARE_WORKER_READY_ATTEMPTS=1
CLOUDFLARE_WORKER_READY_INTERVAL=0
WORKER_BACKUP_DOMAIN_ID=''
assert_worker_upload_module() {
    local argument found=0
    for argument in "$@"; do
        if [[ "${argument}" == "worker.js=@${ROOT_DIR}/worker-src/backup.js;filename=worker.js;type=application/javascript+module" ]]; then
            found=1
            break
        fi
    done
    [[ "${found}" == "1" ]] || fail 'Worker upload part filename must match metadata main_module'
}
cloudflare_api_request() {
    printf '%s %s\n' "$1" "$2" >>"${TMP_DIR}/calls"
    case "$2" in
    */workers/scripts) printf '[]' ;;
    */subdomain) [[ "$3" == *'"enabled":false'* ]] || fail 'disable workers.dev' ;;
    esac
}
curl() {
    assert_worker_upload_module "$@"
    jq -e '.placement.region == "aws:ap-east-1" and .bindings[0].type == "secret_text" and .bindings[1].text == "/vless-test"' \
        "${TMP_DIR}/backup-worker-metadata.json" >/dev/null || fail 'Worker upload metadata'
    printf 'upload\n' >>"${TMP_DIR}/calls"
    printf '{"success":true}'
}
cloudflare_attach_subscription_worker_domain() {
    [[ "${CLOUDFLARE_WORKER_NAME}" == easyall-backup-test && "${SUBSCRIPTION_DOMAIN}" == backup.example.com ]] || fail 'backup binding'
    CLOUDFLARE_WORKER_DOMAIN_ID=new-backup-domain
    CLOUDFLARE_CREATED_WORKER_DOMAIN_ID=new-backup-domain
    printf 'domain\n' >>"${TMP_DIR}/calls"
}
worker_backup_probe() { printf 'probe\n' >>"${TMP_DIR}/calls"; }
cloudflare_deploy_backup_worker
[[ "${WORKER_BACKUP_DOMAIN_ID}" == new-backup-domain && "${WORKER_BACKUP_CREATED}" == 1 ]] || fail 'persist created resource IDs'
[[ "${CLOUDFLARE_WORKER_NAME}" == easyall && "${SUBSCRIPTION_DOMAIN}" == sub.example.com \
    && "${CLOUDFLARE_WORKER_DOMAIN_ID}" == subscription-domain ]] || fail 'subscription configuration preserved'
[[ "$(tail -n 2 "${TMP_DIR}/calls")" == $'domain\nprobe' ]] || fail 'bind before verification'
cloudflare_delete_subscription_worker_resources() {
    [[ "$1" == new-backup-domain && "$2" == easyall-backup-test ]] || fail 'rollback ownership'
    printf 'deleted\n' >"${TMP_DIR}/deleted"
}
cloudflare_rollback_backup_worker
[[ -f "${TMP_DIR}/deleted" ]] || fail 'rollback new resource'
# Verify production flow uses deployment before source publication and aggregation.
for function in install_all apply_cloud_resources update_subscription; do
    body=$(sed -n "/^${function}()/,/^}/p" "${ROOT_DIR}/profiles/xhttp-cloudflare-streamup.sh")
    deploy=$(grep -n '^    cloudflare_deploy_backup_worker$' <<<"${body}" | cut -d: -f1)
    aggregate=$(grep -n 'cloudflare_deploy_subscription_worker$' <<<"${body}" | cut -d: -f1)
    [[ -n "${deploy}" && "${deploy}" -lt "${aggregate}" ]] || fail "${function} deployment order"
    finalize=$(grep -n 'cloudflare_finalize_backup_worker$' <<<"${body}" | cut -d: -f1)
    [[ -n "${finalize}" && "${deploy}" -lt "${finalize}" ]] || fail "${function} finalize order"
    save=$(grep -n '^    save_state$' <<<"${body}" | tail -n 1 | cut -d: -f1)
    [[ -n "${save}" && "${save}" -lt "${finalize}" ]] || fail "${function} saves state before final cleanup"
    [[ "${body}" == *'! subscription_enabled && worker_backup_enabled'* \
        && "${body}" == *'cloudflare_refresh_backup_nodes'* ]] \
        || fail "${function} refreshes backup IPs in link mode"
    if [[ "${function}" != "install_all" ]]; then
        health=$(grep -n 'cloudflare_validate_cdn_health$' <<<"${body}" | cut -d: -f1)
        commit=$(grep -n 'commit_subscription_update$' <<<"${body}" | cut -d: -f1)
        [[ -n "${health}" && "${health}" -lt "${finalize}" && "${finalize}" -lt "${commit}" ]] || fail "${function} health before finalize before commit"
    fi
done
body=$(sed -n '/^write_subscriptions()/,/^}/p' "${ROOT_DIR}/lib/xhttp-runtime.sh")
[[ "${body}" == *cloudflare_refresh_backup_nodes* ]] || fail 'node refresh hook'
# Verify Smart Placement rejection downgrades to off
WORKER_BACKUP_DOMAIN=backup.example.com
WORKER_BACKUP_NAME=easyall-backup-test
WORKER_BACKUP_UUID=11111111-2222-4333-8444-555555555555
WORKER_BACKUP_PATH=/vless-test
WORKER_BACKUP_PLACEMENT=aws:ap-east-1
WORKER_BACKUP_DOMAIN_ID=''
WORKER_BACKUP_CREATED=0
: >"${TMP_DIR}/curl_count"
curl() {
    assert_worker_upload_module "$@"
    printf 'x' >>"${TMP_DIR}/curl_count"
    local count
    count=$(wc -c <"${TMP_DIR}/curl_count" | tr -d ' ')
    if [[ "${count}" -eq 1 ]]; then
        printf '{"success":false,"errors":[{"message":"Smart placement is not enabled"}]}'
    else
        jq -e 'has("placement") | not' "${TMP_DIR}/backup-worker-metadata.json" >/dev/null || fail 'Placement removed on fallback'
        printf '{"success":true}'
    fi
}
worker_backup_probe() { return 0; }
cloudflare_deploy_backup_worker
[[ "${WORKER_BACKUP_PLACEMENT}" == "off" ]] || fail 'Placement downgraded to off'

# Verify existing worker rollback restores the exact previous deployment.
WORKER_BACKUP_DOMAIN=backup.example.com
WORKER_BACKUP_NAME=easyall-backup-test
WORKER_BACKUP_DOMAIN_ID=old-domain-id
WORKER_BACKUP_UUID=22222222-2222-4333-8444-555555555555
WORKER_BACKUP_CREATED=0
cloudflare_api_request() {
    case "$1 $2" in
    "GET "*/deployments)
        printf '{"deployments":[{"versions":[{"version_id":"11111111-1111-4111-8111-111111111111","percentage":75},{"version_id":"22222222-2222-4222-8222-222222222222","percentage":25}]}]}'
        ;;
    "POST "*/deployments?force=true)
        jq -e '
          .strategy == "percentage"
          and .versions == [
            {"version_id":"11111111-1111-4111-8111-111111111111","percentage":75},
            {"version_id":"22222222-2222-4222-8222-222222222222","percentage":25}
          ]
          and .annotations["workers/message"] == "easy_all automatic rollback"
        ' <<<"$3" >/dev/null || fail 'restore exact previous deployment'
        printf 'reverted\n' >"${TMP_DIR}/reverted"
        printf '{}'
        ;;
    */workers/scripts) printf '[{"id":"easyall-backup-test"}]' ;;
    */workers/domains) printf '[{"id":"old-domain-id","service":"easyall-backup-test","hostname":"backup.example.com"}]' ;;
    */subdomain) printf '{"success":true}' ;;
    esac
}
curl() {
    printf '{"success":true}'
}
worker_backup_probe() { return 1; }
(cloudflare_deploy_backup_worker 2>/dev/null) || true
snapshot="${TMP_DIR}/backup-worker-deployment-prev.json"
[[ -s "${snapshot}" ]] || fail 'previous deployment snapshot created'
cloudflare_rollback_backup_worker
[[ -f "${TMP_DIR}/reverted" ]] || fail 'rollback restored previous deployment'
[[ ! -f "${snapshot}" ]] || fail 'deployment snapshot removed on successful rollback'

# Refuse to overwrite an existing Worker when no valid active deployment can be saved.
cloudflare_api_request() {
    case "$1 $2" in
    "GET "*/deployments) printf '{"deployments":[]}' ;;
    */workers/scripts) printf '[{"id":"easyall-backup-test"}]' ;;
    */workers/domains) printf '[{"id":"old-domain-id","service":"easyall-backup-test","hostname":"backup.example.com"}]' ;;
    esac
}
curl() {
    printf 'unexpected\n' >"${TMP_DIR}/unexpected-upload"
    printf '{"success":true}'
}
if (cloudflare_deploy_backup_worker 2>/dev/null); then
    fail 'deployment without a rollback target must fail'
fi
[[ ! -e "${TMP_DIR}/unexpected-upload" ]] || fail 'invalid deployment snapshot prevented upload'

# Verify rollback API failure preserves snapshot
printf '{"strategy":"percentage","versions":[{"version_id":"11111111-1111-4111-8111-111111111111","percentage":100}]}' >"${snapshot}"
cloudflare_api_request() { return 1; }
(cloudflare_rollback_backup_worker 2>/dev/null) && fail 'rollback should fail on API rejection' || true
[[ -f "${snapshot}" ]] || fail 'deployment snapshot preserved on rollback failure'
rm -f -- "${snapshot}"

# Verify decommissioning is transactional: deploy does not delete; finalize does
WORKER_BACKUP_DOMAIN=backup.example.com
WORKER_BACKUP_NAME=easyall-backup-test
WORKER_BACKUP_DOMAIN_ID=old-domain-id
WORKER_BACKUP_DECOMMISSION=1
rm -f -- "${TMP_DIR}/decommission-deleted"
cloudflare_delete_subscription_worker_resources() {
    printf '%s:%s' "$1" "$2" >"${TMP_DIR}/decommission-deleted"
}
cloudflare_deploy_backup_worker
[[ ! -e "${TMP_DIR}/decommission-deleted" ]] || fail 'decommission must not delete during deploy'
[[ "${WORKER_BACKUP_DOMAIN}" == "backup.example.com" ]] || fail 'decommission preserves domain before finalize'
! worker_backup_enabled || fail 'decommissioned worker must report disabled'
cloudflare_finalize_backup_worker
[[ "$(<"${TMP_DIR}/decommission-deleted")" == "old-domain-id:easyall-backup-test" ]] || fail 'decommission deleted on finalize'
[[ -z "${WORKER_BACKUP_DOMAIN}" && -z "${WORKER_BACKUP_NAME}" \
    && -z "${WORKER_BACKUP_PLACEMENT}" ]] || fail 'decommission cleared state'

# A failed final cleanup must leave the old identifiers available for retry/rollback.
WORKER_BACKUP_DOMAIN=backup.example.com
WORKER_BACKUP_NAME=easyall-backup-test
WORKER_BACKUP_DOMAIN_ID=old-domain-id
WORKER_BACKUP_UUID=11111111-2222-4333-8444-555555555555
WORKER_BACKUP_PATH=/vless-test
WORKER_BACKUP_IPS='["104.16.2.2"]'
WORKER_BACKUP_PLACEMENT=off
WORKER_BACKUP_DECOMMISSION=1
cloudflare_delete_subscription_worker_resources() { return 1; }
if cloudflare_finalize_backup_worker; then
    fail 'decommission finalize must fail when resource deletion fails'
fi
[[ "${WORKER_BACKUP_DOMAIN}" == backup.example.com \
    && "${WORKER_BACKUP_NAME}" == easyall-backup-test \
    && "${WORKER_BACKUP_DOMAIN_ID}" == old-domain-id \
    && "${WORKER_BACKUP_PLACEMENT}" == off \
    && "${WORKER_BACKUP_DECOMMISSION}" == 1 ]] || fail 'failed finalize preserved state'

# Verify domain rotation transaction: deploy does not delete old worker; finalize deletes old worker
WORKER_BACKUP_DECOMMISSION=0
WORKER_BACKUP_DOMAIN=backup-new.example.com
WORKER_BACKUP_NAME=easyall-backup-new
WORKER_BACKUP_DOMAIN_ID=new-domain-id
WORKER_BACKUP_PREV_NAME=easyall-backup-prev
WORKER_BACKUP_PREV_DOMAIN_ID=prev-domain-id
rm -f -- "${TMP_DIR}/previous-deleted"
cloudflare_delete_subscription_worker_resources() {
    printf '%s:%s' "$1" "$2" >"${TMP_DIR}/previous-deleted"
}
cloudflare_finalize_backup_worker
[[ "$(<"${TMP_DIR}/previous-deleted")" == "prev-domain-id:easyall-backup-prev" ]] || fail 'domain rotation deleted old worker on finalize'
[[ -z "${WORKER_BACKUP_PREV_NAME}" ]] || fail 'cleared prev worker name'

# Verify link mode allows backup worker in collect_install_inputs & update_subscription
for func in collect_install_inputs update_subscription; do
    body=$(sed -n "/^${func}()/,/^}/p" "${ROOT_DIR}/profiles/xhttp-cloudflare-streamup.sh")
    backup_call=$(grep -n 'collect_worker_backup_inputs' <<<"${body}" | cut -d: -f1)
    fi_line=$(grep -n '^    fi$' <<<"${body}" | head -n 1 | cut -d: -f1)
    [[ -n "${backup_call}" && "${backup_call}" -gt "${fi_line}" ]] || fail "${func} allows worker backup in link mode"
done

# Old installations remain unchanged.
unset WORKER_BACKUP_DOMAIN
[[ -z "$(build_worker_backup_links)" ]] || fail 'legacy installation'
printf 'ok - Worker backup deployment, independent quota, refresh and rollback\n'
