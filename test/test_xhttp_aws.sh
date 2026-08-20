#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
PROFILE="${ROOT_DIR}/lib/xhttp.sh"
PLATFORM_MODULE="${ROOT_DIR}/lib/platform.sh"
ACME_RENEWAL_MODULE="${ROOT_DIR}/lib/acme-renewal.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "${TMP_DIR}"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_equal() {
    local label=$1 expected=$2 actual=$3
    [[ "${expected}" == "${actual}" ]] || fail "${label}: expected [${expected}], got [${actual}]"
}

assert_contains() {
    local label=$1 text=$2 expected=$3
    [[ "${text}" == *"${expected}"* ]] || fail "${label}: missing [${expected}]"
}

assert_not_contains() {
    local label=$1 text=$2 unexpected=$3
    [[ "${text}" != *"${unexpected}"* ]] || fail "${label}: unexpected [${unexpected}]"
}

bash -n "${ROOT_DIR}/easy_all" "${ROOT_DIR}"/lib/*.sh
assert_contains "installer refuses root credentials" "$(<"${PROFILE}")" \
    "拒绝使用 AWS 根用户访问密钥"
assert_contains "Xray XHTTP inbound" "$(<"${PROFILE}")" \
    'tag:"vless-xhttp-h2-in"'
assert_contains "Xray fixes XHTTP to stream-up" "$(<"${PROFILE}")" \
    'mode:"stream-up"'
assert_contains "traffic accounting exposes Stats API only on loopback" "$(<"${PROFILE}")" \
    'api:{tag:"api",listen:"127.0.0.1:10085",services:["StatsService"]}'
assert_contains "XHTTP state persists the quota start date" "$(<"${PROFILE}")" \
    'QUOTA_START_DATE=%q'
assert_contains "Xray keepalive stays below CloudFront response timeout" "$(<"${PROFILE}")" \
    'readonly XHTTP_STREAM_UP_SERVER_SECS="20-40"'
assert_not_contains "XHTTP relies on the compatible core padding defaults" "$(<"${PROFILE}")" \
    'XHTTP_X_PADDING_BYTES'
assert_contains "Nginx stream timeout covers long-lived XHTTP requests" "$(<"${PROFILE}")" \
    'readonly XHTTP_NGINX_STREAM_TIMEOUT="1h"'
assert_contains "Nginx proxies XHTTP over gRPC" "$(<"${PROFILE}")" \
    'grpc_pass grpc://127.0.0.1:${XRAY_XHTTP_LOOPBACK_PORT}'
assert_contains "Nginx validates subscription tokens" "$(<"${PROFILE}")" \
    'map $arg_token $easy_all_subscription_allowed'
assert_contains "Nginx protects direct-origin subscription access" "$(<"${PROFILE}")" \
    'if (\$http_x_easy_all_origin_key != "${ORIGIN_HEADER_SECRET}") { return 404; }'
assert_contains "Nginx serves internal Mihomo subscription" "$(<"${PROFILE}")" \
    'mihomo_alias="${SUBSCRIPTION_MIHOMO_FILE}"'
assert_contains "installer validates sshd before scheduled reboot" "$(<"${PLATFORM_MODULE}")" \
    '"${sshd_bin}" -t'
assert_contains "installer enables SSH at boot" "$(<"${PLATFORM_MODULE}")" \
    'systemctl enable --now "${unit}"'
assert_contains "installer verifies SSH boot enablement" "$(<"${PLATFORM_MODULE}")" \
    'systemctl is-enabled --quiet "${unit}"'
assert_contains "installer verifies ACME renewal cron" "$(<"${ACME_RENEWAL_MODULE}")" \
    'die "未找到 acme.sh 自动续期定时任务"'
assert_contains "XHTTP repairs a missing ACME renewal cron job" "$(<"${ACME_RENEWAL_MODULE}")" \
    'run_acme --install-cronjob'
assert_contains "XHTTP writes a managed cron fallback when acme.sh does not" "$(<"${ACME_RENEWAL_MODULE}")" \
    "easy_all-acme-renewal"
assert_contains "installer verifies renewal reload hook" "$(<"${PROFILE}")" \
    '源站证书、私钥或续期重载钩子安装不完整'
assert_contains "subscription updates enable rollback" "$(<"${PROFILE}")" \
    'UPDATE_SUB_ROLLBACK_ON_EXIT=1'
assert_contains "CloudFront health failures are fatal" "$(<"${PROFILE}")" \
    'die "CloudFront 公网验收失败'
assert_not_contains "CloudFront installation does not auto-adopt unmarked legacy distributions" \
    "$(<"${PROFILE}")" 'AWS_ADOPT_DISTRIBUTION=1'
assert_contains "CloudFront alias conflicts require explicit old-resource cleanup" \
    "$(<"${PROFILE}")" '脚本不会接管旧部署，请先删除旧分配或解除该别名'
assert_contains "CloudFront billing mode is persisted" "$(<"${PROFILE}")" \
    'AWS_CLOUDFRONT_BILLING_MODE=%q'
assert_contains "CloudFront fee protection threshold is persisted" "$(<"${PROFILE}")" \
    'CLOUDFRONT_FEE_PROTECTION_GB=%q'
assert_contains "global fee protection can remove every Xray client" "$(<"${PROFILE}")" \
    "cloudfront_fee_protection_blocked && clients='[]'"
assert_contains "pay-as-you-go clears WAF association" "$(<"${PROFILE}")" \
    'AWS_WAF_WEB_ACL_ARN=""'
assert_contains "non-interactive uninstall requires FORCE" "$(<"${PROFILE}")" \
    '非交互卸载必须显式设置 FORCE=1'

(
    # shellcheck source=/dev/null
    source "${PROFILE}"

    assert_equal "profile" "xhttp" "${EASY_ALL_PROFILE}"
    assert_equal "unified state" "/etc/easy_all" "${STATE_DIR}"
    assert_equal "unified service" "easy_all-xray.service" "${XRAY_SERVICE}"
    assert_equal "unified nginx config" "/etc/nginx/conf.d/easy_all.conf" "${NGINX_CONFIG}"
    assert_equal "schema" "4" "${STATE_SCHEMA_VERSION}"
    assert_equal "AWS control region" "us-east-1" "${AWS_CONTROL_REGION}"
    assert_equal "default CloudFront billing mode" "payg" \
        "${DEFAULT_AWS_CLOUDFRONT_BILLING_MODE}"
    validate_cloudfront_billing_mode flat-free \
        || fail "flat-free CloudFront billing mode must be valid"
    validate_cloudfront_billing_mode payg \
        || fail "payg CloudFront billing mode must be valid"
    if validate_cloudfront_billing_mode invalid; then
        fail "unknown CloudFront billing modes must be rejected"
    fi
    AWS_CLOUDFRONT_BILLING_MODE=1
    choose_cloudfront_billing_mode
    assert_equal "CloudFront billing choice 1 selects flat-free" "flat-free" \
        "${AWS_CLOUDFRONT_BILLING_MODE}"
    assert_equal "flat-free mode disables global fee protection" "0" \
        "${CLOUDFRONT_FEE_PROTECTION_GB}"
    AWS_CLOUDFRONT_BILLING_MODE=2
    choose_cloudfront_billing_mode
    assert_equal "CloudFront billing choice 2 selects pay-as-you-go" "payg" \
        "${AWS_CLOUDFRONT_BILLING_MODE}"
    assert_equal "pay-as-you-go enables the 980 GB global fee protection" "980" \
        "${CLOUDFRONT_FEE_PROTECTION_GB}"
    assert_equal "caching disabled policy" \
        "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" "${CLOUDFRONT_CACHE_POLICY_ID}"
    assert_equal "all viewer except host policy" \
        "b689b0a8-53d0-40ab-baf2-68738e2966ac" "${CLOUDFRONT_ORIGIN_REQUEST_POLICY_ID}"
    assert_equal "stream-up server keepalive" "20-40" "${XHTTP_STREAM_UP_SERVER_SECS}"
    assert_equal "Nginx XHTTP stream timeout" "1h" "${XHTTP_NGINX_STREAM_TIMEOUT}"
    assert_equal "XMUX max concurrency" "4-8" "${XHTTP_XMUX_MAX_CONCURRENCY}"
    assert_equal "XMUX browser-like keepalive" "0" "${XHTTP_XMUX_H_KEEP_ALIVE_PERIOD}"
    assert_equal "CloudFront origin response timeout" "120" "${CLOUDFRONT_ORIGIN_READ_TIMEOUT}"

    ufw_state="${TMP_DIR}/xhttp-ufw-state"
    cat >"${ufw_state}" <<'EOF'
22/tcp|ALLOW IN|Anywhere|easy_all-managed
8443/tcp|ALLOW IN|Anywhere|easy_all-managed
80/tcp|ALLOW IN|Anywhere|debian-init-managed
9999/tcp|ALLOW IN|Anywhere|user-rule
EOF
    ufw() {
        local endpoint number temp="${ufw_state}.new"
        if [[ "${1:-}" == "status" && "${2:-}" == "numbered" ]]; then
            printf 'Status: active\n'
            awk -F'|' '{printf "[ %d] %s %s %s # %s\n", NR, $1, $2, $3, $4}' "${ufw_state}"
            return 0
        fi
        if [[ "${1:-}" == "allow" ]]; then
            endpoint=$2
            if awk -F'|' -v endpoint="${endpoint}" \
                '$1 == endpoint && $2 == "ALLOW IN" {found=1} END {exit(found ? 0 : 1)}' \
                "${ufw_state}"; then
                return 0
            fi
            printf '%s|ALLOW IN|Anywhere|%s\n' "${endpoint}" "${4:-}" >>"${ufw_state}"
            return 0
        fi
        if [[ "${1:-}" == "--force" && "${2:-}" == "delete" ]]; then
            number=$3
            awk -v number="${number}" 'NR != number' "${ufw_state}" >"${temp}"
            mv "${temp}" "${ufw_state}"
            return 0
        fi
        [[ "${1:-}" == "--force" && "${2:-}" == "enable" ]] && return 0
        [[ "${1:-}" == "reload" ]] && return 0
        return 1
    }
    apply_managed_ufw_tcp_ports "22 80 443"
    apply_managed_ufw_tcp_ports "22 80 443"
    ufw_state_text=$(<"${ufw_state}")
    xhttp_ssh_count=$(awk -F'|' '$1 == "22/tcp" && $2 == "ALLOW IN" {count++} END {print count+0}' "${ufw_state}")
    assert_equal "XHTTP UFW reapply keeps exactly one SSH allow rule" "1" "${xhttp_ssh_count}"
    assert_contains "XHTTP UFW reapply keeps the existing managed SSH rule" \
        "${ufw_state_text}" "22/tcp|ALLOW IN|Anywhere|easy_all-managed"
    assert_contains "XHTTP UFW accepts an existing external HTTP allow rule" \
        "${ufw_state_text}" "80/tcp|ALLOW IN|Anywhere|debian-init-managed"
    assert_contains "XHTTP UFW adds a missing HTTPS rule" \
        "${ufw_state_text}" "443/tcp|ALLOW IN|Anywhere|easy_all-managed"
    assert_not_contains "XHTTP UFW removes only a stale managed rule" \
        "${ufw_state_text}" "8443/tcp|ALLOW IN|Anywhere|easy_all-managed"
    assert_contains "XHTTP UFW preserves unrelated user rules" \
        "${ufw_state_text}" "9999/tcp|ALLOW IN|Anywhere|user-rule"
    unset -f ufw

    assert_contains "XHTTP prompts for the Mihomo download filename" \
        "$(<"${PROFILE}")" 'Mihomo 下载文件名（不含 .yaml）'
    assert_contains "XHTTP default prompts explain the enter default" \
        "$(<"${ROOT_DIR}/lib/profile-runtime.sh")" \
        '[${default}]（直接回车使用默认值）'
    assert_contains "XHTTP subscription prompt recommends self-hosting for one server" \
        "$(<"${PROFILE}")" "只有当前服务器时推荐"
    assert_contains "XHTTP subscription prompt recommends node output for aggregation" \
        "$(<"${PROFILE}")" "多节点聚合或已有订阅服务器时推荐"

    SUB_DOWNLOAD_NAME="CUSTOM_SUB.yaml"
    choose_subscription_download_name
    assert_equal "XHTTP normalizes a custom download filename" \
        "CUSTOM_SUB" "${SUB_DOWNLOAD_NAME}"
    SUB_DOWNLOAD_NAME=""

    SUBSCRIBE_MODE="1"
    SUBSCRIPTION_MODE=""
    choose_subscription_mode
    assert_equal "subscription choice 1 deploys the service" "deploy" "${SUBSCRIPTION_MODE}"
    SUBSCRIBE_MODE="2"
    SUBSCRIPTION_MODE=""
    choose_subscription_mode
    assert_equal "subscription choice 2 outputs links only" "link" "${SUBSCRIPTION_MODE}"
    unset SUBSCRIBE_MODE

    SUBSCRIPTION_MODE="link"
    PROMPT_SUBSCRIPTION_MODE=1
    choose_subscription_mode
    assert_equal "update-sub keeps the current link mode by default" \
        "link" "${SUBSCRIPTION_MODE}"
    PROMPT_SUBSCRIPTION_MODE=0

    dig() {
        case "$*" in
            *"@1.1.1.1"*) return 0 ;;
            *"@8.8.8.8"*) printf '%s\n' '198.51.100.10' ;;
        esac
    }
    AWS_ORIGIN_DOMAIN="origin.example.com"
    VPS_PUBLIC_IPV4="198.51.100.10"
    verify_origin_dns

    (
        crontab() {
            printf '17 2 * * * "%s" --cron --home "%s"\n' "${ACME_BIN}" "${ACME_HOME}"
        }
        systemctl() { return 0; }
        verify_acme_renewal_setup
    )
    if (
        crontab() { printf '17 2 * * * /usr/local/bin/unrelated-job\n'; }
        systemctl() { return 0; }
        verify_acme_renewal_setup
    ) >/dev/null 2>&1; then
        fail "ACME renewal verification must reject a missing cron entry"
    fi

    (
        source_state_file() {
            STATE_VERSION="4"
            PROTOCOL="xhttp"
            AWS_CLOUDFRONT_BILLING_MODE="flat-free"
            VLESS_UUID="00000000-0000-4000-8000-000000000001"
            VLESS_CDN_DOMAIN="node.example.com"
            XHTTP_NODE_NAME="STORED_XHTTP"
            XHTTP_PATH="/xhttp-stored-suffix"
            AWS_ORIGIN_DOMAIN="origin.example.com"
            XRAY_XHTTP_LOOPBACK_PORT="10086"
        }
        VLESS_UUID="00000000-0000-4000-8000-000000000002"
        XHTTP_NODE_NAME="UPDATED_XHTTP"
        XHTTP_PATH="/xhttp-updated-suffix"
        load_state
        assert_equal "UUID environment override wins during update" \
            "00000000-0000-4000-8000-000000000002" "${VLESS_UUID}"
        assert_equal "node name environment override wins during update" \
            "UPDATED_XHTTP" "${XHTTP_NODE_NAME}"
        assert_equal "XHTTP path environment override wins during update" \
            "/xhttp-updated-suffix" "${XHTTP_PATH}"
    )
    if (
        source_state_file() { STATE_VERSION="3"; }
        load_state
    ) >/dev/null 2>&1; then
        fail "XHTTP v4 must reject old state without global protection state"
    fi

    zones='{"HostedZones":[{"Id":"/hostedzone/ZBASE","Name":"example.com.","Config":{"PrivateZone":false}},{"Id":"/hostedzone/ZPRIVATE","Name":"node.example.com.","Config":{"PrivateZone":true}},{"Id":"/hostedzone/ZBOUNDARY","Name":"notexample.com.","Config":{"PrivateZone":false}}]}'
    assert_equal "Route 53 public parent zone" $'/hostedzone/ZBASE\texample.com.' \
        "$(find_route53_zone_for_domain node.example.com "${zones}")"
    assert_equal "Route 53 boundary-safe matching" $'/hostedzone/ZBOUNDARY\tnotexample.com.' \
        "$(find_route53_zone_for_domain node.notexample.com "${zones}")"

    VLESS_CDN_DOMAIN="node.example.com"
    certificates='{"CertificateSummaryList":[
      {"CertificateArn":"arn:pending-exact","DomainName":"node.example.com","Status":"PENDING_VALIDATION"},
      {"CertificateArn":"arn:issued-wildcard","DomainName":"*.example.com","Status":"ISSUED"},
      {"CertificateArn":"arn:unrelated","DomainName":"other.example.net","Status":"ISSUED"},
      {"CertificateArn":"arn:issued-san","DomainName":"service.example.net","Status":"ISSUED",
       "SubjectAlternativeNameSummaries":["san.example.org"]}
    ]}'
    assert_equal "ACM reuse prefers an issued covering certificate" "arn:issued-wildcard" \
        "$(select_reusable_acm_certificate "${certificates}")"
    VLESS_CDN_DOMAIN="deep.node.example.com"
    assert_equal "ACM wildcard reuse is limited to one label" "" \
        "$(select_reusable_acm_certificate "${certificates}")"
    VLESS_CDN_DOMAIN="san.example.org"
    assert_equal "ACM reuse considers certificate SANs" "arn:issued-san" \
        "$(select_reusable_acm_certificate "${certificates}")"

    VLESS_CDN_DOMAIN="node.example.com"
    aws() {
        printf '%s\n' '{"DistributionList":{"Items":[
          {"Id":"EASYALL123","Comment":"easy_all:xhttp:node.example.com"},
          {"Id":"OTHER123","Comment":"unrelated"}
        ]}}'
    }
    assert_equal "reinstall discovers the managed CloudFront distribution" "EASYALL123" \
        "$(find_managed_distribution)"
    aws() {
        printf '%s\n' '{"DistributionList":{"Items":[
          {"Id":"EASYALL123","Comment":"easy_all:xhttp:node.example.com"},
          {"Id":"EASYALL456","Comment":"easy_all:xhttp:node.example.com"}
        ]}}'
    }
    if (find_managed_distribution) >/dev/null 2>&1; then
        fail "duplicate managed CloudFront distributions must be rejected"
    fi
    unset -f aws

    AWS_ACCOUNT_ID="111122223333"
    AWS_ACCOUNT_PLAN_UPGRADE=1
    account_plan_counter_file="${TMP_DIR}/account-plan-counter"
    printf '0\n' >"${account_plan_counter_file}"
    aws() {
        local count
        if [[ "$*" == *"freetier get-account-plan-state"* ]]; then
            count=$(<"${account_plan_counter_file}")
            count=$((count + 1))
            printf '%s\n' "${count}" >"${account_plan_counter_file}"
            if ((count == 1)); then
                printf '%s\n' '{"accountPlanType":"FREE","accountPlanStatus":"ACTIVE"}'
            else
                printf '%s\n' '{"accountPlanType":"PAID","accountPlanStatus":"ACTIVE"}'
            fi
        elif [[ "$*" == *"freetier upgrade-account-plan"* ]]; then
            printf '%s\n' '{"accountPlanType":"PAID","accountPlanStatus":"ACTIVE"}'
        else
            return 1
        fi
    }
    paid_upgrade_output=$(ensure_aws_paid_account_plan)
    assert_contains "Free AWS accounts are upgraded through the API" \
        "${paid_upgrade_output}" "已升级为 Paid"
    unset -f aws
    unset AWS_ACCOUNT_PLAN_UPGRADE

    PROTOCOL="xhttp"
    XHTTP_NODE_NAME="EASY_ALL_XHTTP_TEST"
    VLESS_UUID="00000000-0000-4000-8000-000000000001"
    VLESS_CDN_DOMAIN="node.example.com"
    AWS_ORIGIN_DOMAIN="origin.example.com"
    XHTTP_PATH="/xhttp-test-path"
    XRAY_XHTTP_LOOPBACK_PORT="10086"
    ORIGIN_HEADER_SECRET="test-origin-header-secret"
    AWS_ACM_CERTIFICATE_ARN="arn:aws:acm:us-east-1:111122223333:certificate/test"
    AWS_CLOUDFRONT_BILLING_MODE="flat-free"
    AWS_WAF_WEB_ACL_ARN="arn:aws:wafv2:us-east-1:111122223333:global/webacl/easy-all/test"
    ALLOWED_TOKENS='{"owner":"owner-token-123"}'
    SUB_DOWNLOAD_NAME="EASY_ALL_TEST"

    link=$(build_node_link)
    assert_contains "VLESS scheme" "${link}" "vless://"
    assert_contains "CloudFront hostname" "${link}" "@node.example.com:443"
    assert_contains "XHTTP transport" "${link}" "type=xhttp"
    assert_contains "XHTTP stream-up" "${link}" "mode=stream-up"
    assert_contains "XHTTP path" "${link}" "path=%2Fxhttp-test-path"
    assert_contains "XHTTP XMUX extra" "${link}" "extra="
    assert_contains "XHTTP link uses the supported uplink method key" "${link}" "uplinkHTTPMethod"
    assert_not_contains "XHTTP link omits the ignored legacy uplink key" "${link}" "uplinkMethod"
    encoded_extra=$(sed -n 's/.*[?&]extra=\([^&]*\).*/\1/p' <<<"${link}")
    extra_json=$(printf '%b' "${encoded_extra//%/\\x}")
    jq -e '
        .noGRPCHeader == false and
        (has("xPaddingBytes") | not) and
        (has("xPaddingObfsMode") | not) and
        .uplinkHTTPMethod == "POST"
    ' <<<"${extra_json}" >/dev/null || fail "XHTTP URI extra is invalid"
    assert_not_contains "XHTTP XMUX omits request-count rotation" \
        "${link}" "hMaxRequestTimes"
    [[ "${link}" != *"trojan"* ]] || fail "links must contain only VLESS"
    assert_equal "exactly one link" "1" "$(wc -l <<<"${link}" | tr -d ' ')"

    mihomo=$(build_mihomo_node)
    assert_contains "Mihomo XHTTP" "${mihomo}" "network: xhttp"
    assert_contains "Mihomo stream-up" "${mihomo}" "mode: stream-up"
    assert_contains "Mihomo XMUX" "${mihomo}" "reuse-settings:"
    assert_contains "Mihomo XMUX uses conservative concurrency" \
        "${mihomo}" 'max-concurrency: "4-8"'
    assert_not_contains "Mihomo relies on its compatible padding defaults" \
        "${mihomo}" 'x-padding-'
    assert_not_contains "Mihomo XMUX omits request-count rotation" \
        "${mihomo}" "h-max-request-times"
    assert_contains "Mihomo XMUX uses browser-like keepalive" "${mihomo}" "h-keep-alive-period: 0"

    distribution="${TMP_DIR}/distribution.json"
    build_distribution_config "${distribution}" "test-caller-reference"
    jq -e '
        .CallerReference == "test-caller-reference" and
        .Aliases.Items == ["node.example.com"] and
        .DefaultRootObject == "" and
        .Origins.Items[0].DomainName == "origin.example.com" and
        .Origins.Items[0].CustomOriginConfig.OriginProtocolPolicy == "https-only" and
        .Origins.Items[0].CustomOriginConfig.OriginSslProtocols.Items == ["TLSv1.2"] and
        .Origins.Items[0].CustomOriginConfig.OriginReadTimeout == 120 and
        .Origins.Items[0].CustomOriginConfig.OriginKeepaliveTimeout == 60 and
        .Origins.Items[0].ConnectionAttempts == 2 and
        .Origins.Items[0].ConnectionTimeout == 3 and
        .Origins.Items[0].CustomHeaders.Items[0].HeaderName == "X-Easy-All-Origin-Key" and
        .DefaultCacheBehavior.ViewerProtocolPolicy == "https-only" and
        .DefaultCacheBehavior.CachePolicyId == "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" and
        .DefaultCacheBehavior.OriginRequestPolicyId == "b689b0a8-53d0-40ab-baf2-68738e2966ac" and
        (.DefaultCacheBehavior.AllowedMethods.Items | sort) == (["GET","HEAD","OPTIONS","PUT","POST","PATCH","DELETE"] | sort) and
        .DefaultCacheBehavior.GrpcConfig.Enabled == true and
        .HttpVersion == "http2" and
        .ViewerCertificate.ACMCertificateArn == "arn:aws:acm:us-east-1:111122223333:certificate/test" and
        .WebACLId == "arn:aws:wafv2:us-east-1:111122223333:global/webacl/easy-all/test" and
        .Comment == "easy_all:xhttp:node.example.com"
    ' "${distribution}" >/dev/null || fail "CloudFront distribution config is invalid"

    payg_distribution="${TMP_DIR}/distribution-payg.json"
    AWS_CLOUDFRONT_BILLING_MODE="payg"
    AWS_WAF_WEB_ACL_ARN=""
    build_distribution_config "${payg_distribution}" "payg-caller-reference"
    jq -e '.CallerReference == "payg-caller-reference" and .WebACLId == ""' \
        "${payg_distribution}" >/dev/null \
        || fail "pay-as-you-go CloudFront config must not attach WAF"
    AWS_CLOUDFRONT_BILLING_MODE="flat-free"
    AWS_WAF_WEB_ACL_ARN="arn:aws:wafv2:us-east-1:111122223333:global/webacl/easy-all/test"

    origin_change="${TMP_DIR}/origin-a-create.json"
    build_origin_a_change_batch "${origin_change}" '[]' '203.0.113.10'
    jq -e '
        .Changes|length == 1 and
        .[0].Action == "CREATE" and
        .[0].ResourceRecordSet.Name == "origin.example.com." and
        .[0].ResourceRecordSet.Type == "A" and
        .[0].ResourceRecordSet.ResourceRecords == [{"Value":"203.0.113.10"}]
    ' "${origin_change}" >/dev/null || fail "Route 53 origin A create batch is invalid"

    origin_replace="${TMP_DIR}/origin-a-replace.json"
    origin_conflicts='[{"Name":"origin.example.com.","Type":"A","TTL":300,"ResourceRecords":[{"Value":"198.51.100.8"}]},{"Name":"origin.example.com.","Type":"AAAA","TTL":300,"ResourceRecords":[{"Value":"2001:db8::8"}]}]'
    build_origin_a_change_batch "${origin_replace}" "${origin_conflicts}" '203.0.113.10'
    jq -e '
        .Changes|length == 3 and
        .[0].Action == "DELETE" and .[0].ResourceRecordSet.Type == "A" and
        .[1].Action == "DELETE" and .[1].ResourceRecordSet.Type == "AAAA" and
        .[2].Action == "CREATE" and .[2].ResourceRecordSet.Type == "A" and
        .[2].ResourceRecordSet.ResourceRecords == [{"Value":"203.0.113.10"}]
    ' "${origin_replace}" >/dev/null || fail "Route 53 origin A replacement batch is invalid"

    viewer_alias="${TMP_DIR}/viewer-alias.json"
    build_viewer_alias_change_batch "${viewer_alias}" '[]' \
        "d111111abcdef8.cloudfront.net."
    jq -e '
        .Changes|length == 2 and
        .[0].Action == "CREATE" and .[0].ResourceRecordSet.Type == "A" and
        .[1].Action == "CREATE" and .[1].ResourceRecordSet.Type == "AAAA" and
        .[0].ResourceRecordSet.AliasTarget.HostedZoneId == "Z2FDTNDATAQYW2" and
        .[1].ResourceRecordSet.AliasTarget.DNSName == "d111111abcdef8.cloudfront.net."
    ' "${viewer_alias}" >/dev/null || fail "Route 53 viewer Alias creation batch is invalid"

    subscriptions='{"subscriptionSummaries":[
      {"arn":"arn:plan:other","planTier":"FREE","resourceArns":["arn:distribution:other"]},
      {"arn":"arn:plan:easy-all","planTier":"FREE","resourceArns":["arn:distribution:easy-all","arn:waf:easy-all"]}
    ]}'
    assert_equal "pricing plan selection is scoped to the CloudFront distribution" \
        '[{"arn":"arn:plan:easy-all","planTier":"FREE","resourceArns":["arn:distribution:easy-all","arn:waf:easy-all"]}]' \
        "$(select_cloudfront_pricing_subscription "${subscriptions}" "arn:distribution:easy-all")"

    AWS_ACCOUNT_ID="111122223333"
    AWS_CLOUDFRONT_DISTRIBUTION_ID="EASYALL123"
    AWS_CLOUDFRONT_DISTRIBUTION_ARN="arn:aws:cloudfront::111122223333:distribution/EASYALL123"
    AWS_WAF_WEB_ACL_ARN="arn:aws:wafv2:us-east-1:111122223333:global/webacl/easy-all/test"
    AWS_ROUTE53_ZONE_ID="ZVIEWER123"
    AWS_CLOUDFRONT_PRICING_PLAN_ARN=""
    pricing_calls="${TMP_DIR}/pricing-plan-calls"
    : >"${pricing_calls}"
    aws() {
        printf '%s\n' "$*" >>"${pricing_calls}"
        case "$*" in
        *"pricing-plan-manager list-subscriptions"*)
            printf '%s\n' '{"subscriptionSummaries":[]}'
            ;;
        *"pricing-plan-manager create-subscription"*)
            printf '%s\n' '{"subscription":{"arn":"arn:aws:pricingplanmanager:us-east-1:111122223333:subscription/easy-all","status":"SYNC_IN_PROGRESS"},"eTag":"v1"}'
            ;;
        *"pricing-plan-manager get-subscription"*)
            printf '%s\n' '{"subscription":{"arn":"arn:aws:pricingplanmanager:us-east-1:111122223333:subscription/easy-all","planTier":"FREE","status":"ACTIVE","resourceArns":["arn:aws:cloudfront::111122223333:distribution/EASYALL123","arn:aws:wafv2:us-east-1:111122223333:global/webacl/easy-all/test","arn:aws:route53:::hostedzone/ZVIEWER123"]},"eTag":"v2"}'
            ;;
        *) return 1 ;;
        esac
    }
    ensure_cloudfront_free_pricing_plan >/dev/null
    pricing_call_text=$(<"${pricing_calls}")
    assert_contains "pricing plan creation is hard-coded to the FREE tier" \
        "${pricing_call_text}" "--plan-tier FREE"
    assert_contains "pricing plan creation includes the viewer Route 53 zone" \
        "${pricing_call_text}" "arn:aws:route53:::hostedzone/ZVIEWER123"
    assert_not_contains "pricing plan automation never approves a paid subscription" \
        "${pricing_call_text}" "approve-paid-subscription"
    unset -f aws

    AWS_CLOUDFRONT_BILLING_MODE="payg"
    AWS_CLOUDFRONT_PRICING_PLAN_ARN="stale-value"
    payg_calls="${TMP_DIR}/payg-calls"
    : >"${payg_calls}"
    aws() {
        printf '%s\n' "$*" >>"${payg_calls}"
        [[ "$*" == *"pricing-plan-manager list-subscriptions"* ]] || return 1
        printf '%s\n' '{"subscriptionSummaries":[]}'
    }
    ensure_cloudfront_payg_mode >/dev/null
    assert_equal "pay-as-you-go mode clears pricing plan state" "" \
        "${AWS_CLOUDFRONT_PRICING_PLAN_ARN}"
    assert_not_contains "pay-as-you-go mode never creates a fixed plan" \
        "$(<"${payg_calls}")" "create-subscription"
    aws() {
        [[ "$*" == *"pricing-plan-manager list-subscriptions"* ]] || return 1
        printf '%s\n' '{"subscriptionSummaries":[{"arn":"arn:plan:legacy","planTier":"FREE","resourceArns":["arn:aws:cloudfront::111122223333:distribution/EASYALL123"]}]}'
    }
    if (ensure_cloudfront_payg_mode) >/dev/null 2>&1; then
        fail "pay-as-you-go mode must reject a distribution with a fixed plan"
    fi
    unset -f aws

    AWS_ORIGIN_ROUTE53_ZONE_ID="ZSAME"
    AWS_ROUTE53_ZONE_ID="ZSAME"
    payg_estimate=$(show_cloudfront_billing_estimate)
    assert_contains "pay-as-you-go estimate includes one hosted zone" \
        "${payg_estimate}" '1 个 Hosted Zone：固定费用估算 $0.50/月'
    assert_contains "pay-as-you-go estimate includes DNS query pricing" \
        "${payg_estimate}" '每 100 万次约 $0.40'
    AWS_CLOUDFRONT_BILLING_MODE="flat-free"
    AWS_ORIGIN_ROUTE53_ZONE_ID="ZORIGIN"
    AWS_ROUTE53_ZONE_ID="ZVIEWER"
    flat_estimate=$(show_cloudfront_billing_estimate)
    assert_contains "flat-free estimate has no overage charge" \
        "${flat_estimate}" '超出费用仍为 $0'
    assert_contains "flat-free estimate prices a separate origin hosted zone" \
        "${flat_estimate}" '源站 Zone 另估 $0.50/月'

    payg_flow=$(
        AWS_CLOUDFRONT_BILLING_MODE="payg"
        AWS_WAF_WEB_ACL_ARN="stale-waf"
        install_aws_cli() { printf 'cli\n'; }
        collect_aws_credentials() { printf 'credentials\n'; }
        find_route53_zones() { printf 'zones\n'; }
        show_cloudfront_billing_estimate() { printf 'estimate\n'; }
        find_or_request_acm_certificate() { printf 'acm\n'; }
        ensure_aws_paid_account_plan() { printf 'paid\n'; }
        ensure_cloudfront_web_acl() { printf 'waf\n'; }
        configure_cloudfront_distribution() {
            printf 'cloudfront:%s\n' "${AWS_WAF_WEB_ACL_ARN:-empty}"
        }
        ensure_viewer_alias_records() { printf 'alias\n'; }
        wait_for_cloudfront() { printf 'wait\n'; }
        ensure_cloudfront_free_pricing_plan() { printf 'flat-plan\n'; }
        ensure_cloudfront_payg_mode() { printf 'payg\n'; }
        validate_cloudfront_health() { printf 'health\n'; }
        clear_aws_credentials() { printf 'clear\n'; }
        configure_aws_cdn
    )
    assert_equal "pay-as-you-go cloud flow omits WAF and fixed plan" \
        $'cli\ncredentials\nzones\nestimate\nacm\npaid\ncloudfront:empty\nalias\nwait\npayg\nhealth\nclear' \
        "${payg_flow}"

    flat_flow=$(
        AWS_CLOUDFRONT_BILLING_MODE="flat-free"
        install_aws_cli() { :; }
        collect_aws_credentials() { :; }
        find_route53_zones() { :; }
        show_cloudfront_billing_estimate() { :; }
        find_or_request_acm_certificate() { :; }
        ensure_aws_paid_account_plan() { :; }
        ensure_cloudfront_web_acl() { printf 'waf\n'; AWS_WAF_WEB_ACL_ARN='flat-waf'; }
        configure_cloudfront_distribution() { printf 'cloudfront:%s\n' "${AWS_WAF_WEB_ACL_ARN}"; }
        ensure_viewer_alias_records() { :; }
        wait_for_cloudfront() { :; }
        ensure_cloudfront_free_pricing_plan() { printf 'flat-plan\n'; }
        ensure_cloudfront_payg_mode() { printf 'payg\n'; }
        validate_cloudfront_health() { :; }
        clear_aws_credentials() { :; }
        configure_aws_cdn
    )
    assert_equal "flat-free cloud flow creates WAF and Free plan" \
        $'waf\ncloudfront:flat-waf\nflat-plan' "${flat_flow}"

    template="${ROOT_DIR}/sample-mihomo.yaml"
    node_file="${TMP_DIR}/mihomo-node.yaml"
    mihomo_file="${TMP_DIR}/subscription.yaml"
    validate_mihomo_template "${template}"
    build_mihomo_node >"${node_file}"
    render_mihomo_subscription "${template}" "${node_file}" "${mihomo_file}"
    assert_equal "one rendered VLESS node" "1" \
        "$(grep -Fc 'type: vless' "${mihomo_file}" | tr -d ' ')"
    assert_equal "one rendered XHTTP node" "1" \
        "$(grep -Fc 'network: xhttp' "${mihomo_file}" | tr -d ' ')"
    assert_contains "Mihomo subscription CDN domain" "$(<"${mihomo_file}")" "node.example.com"
    assert_contains "Mihomo subscription node name" "$(<"${mihomo_file}")" "EASY_ALL_XHTTP_TEST"
    assert_contains "Mihomo subscription rules" "$(<"${mihomo_file}")" "RULE-SET,telegramcidr,PROXY,no-resolve"
    assert_contains "Mihomo subscription XMUX" "$(<"${mihomo_file}")" "h-keep-alive-period: 0"

    encoded=$(printf '%s' "$(build_node_link)" | openssl base64 -A)
    decoded=$(printf '%s' "${encoded}" | openssl base64 -d -A)
    assert_contains "base64 subscription VLESS" "${decoded}" "vless://"
    assert_contains "base64 subscription XHTTP" "${decoded}" "type=xhttp"
    assert_contains "base64 subscription XMUX" "${decoded}" "extra="

    token_map=$(write_subscription_token_map)
    assert_equal "Nginx token map contains only token values" \
        '    "owner-token-123" 1;' "${token_map}"

    QUOTA_ENABLED=1
    USER_ACCOUNTS='{"owner":{"token":"owner-token-123","uuid":"00000000-0000-4000-8000-000000000001","quota_gb":0},"friend":{"token":"friend-token-123","uuid":"00000000-0000-4000-8000-000000000002","quota_gb":100}}'
    quota_token_map=$(write_subscription_token_map)
    assert_contains "quota token map selects the owner subscription directory" \
        "${quota_token_map}" '"owner-token-123" "owner";'
    assert_contains "quota token map selects the friend subscription directory" \
        "${quota_token_map}" '"friend-token-123" "friend";'
    SUBSCRIPTION_MODE="deploy"
    quota_locations=$(write_subscription_nginx_locations)
    assert_contains "quota subscription uses a token-selected base64 file" \
        "${quota_locations}" '$easy_all_subscription_allowed/base64.txt'
    assert_contains "Mihomo download keeps the configured filename without an extension" \
        "${quota_locations}" 'Content-Disposition "attachment; filename=EASY_ALL_TEST"'
    assert_not_contains "Mihomo download does not append yaml to the filename" \
        "${quota_locations}" 'filename=EASY_ALL_TEST.yaml'
    QUOTA_ENABLED=0
    USER_ACCOUNTS=""

    SUBSCRIPTION_MODE="link"
    link_nginx=$(
        write_subscription_nginx_maps
        write_subscription_nginx_locations
    )
    assert_equal "link-only mode omits subscription Nginx routes" "" "${link_nginx}"
    SUBSCRIPTION_MODE="deploy"

    subscription_output=$(
        collect_installed_state() { :; }
        show_node() { :; }
        show_subscription
    )
    assert_contains "XHTTP subscription output labels the owner" \
        "${subscription_output}" "通用订阅 (owner):"

    local_apply_calls=$(
        require_root() { printf 'root\n'; }
        begin_quota_maintenance() { :; }
        end_quota_maintenance() { :; }
        collect_installed_state() { printf 'state\n'; }
        snapshot_subscription_update() {
            printf 'snapshot\n'
            UPDATE_SUB_ROLLBACK_ON_EXIT=1
        }
        configure_bbr_tcp() { printf 'bbr\n'; }
        configure_ufw() { printf 'ufw\n'; }
        prepare_aws_origin_dns() { printf 'dns\n'; }
        configure_aws_cdn() { printf 'cdn\n'; }
        refresh_runtime() { printf 'runtime\n'; }
        write_subscriptions() { printf 'subscriptions\n'; }
        validate_subscription_runtime() { printf 'validate-subscription\n'; }
        save_state() { printf 'save\n'; }
        register_easy_all_command() { printf 'register\n'; }
        show_subscription() { printf 'show\n'; }
        success() { :; }
        apply_easy_all
    )
    assert_equal "default XHTTP apply stays local" \
        $'root\nstate\nsnapshot\nbbr\nufw\nruntime\nsubscriptions\nvalidate-subscription\nsave\nregister\nshow' "${local_apply_calls}"

    cloud_apply_calls=$(
        require_root() { printf 'root\n'; }
        begin_quota_maintenance() { :; }
        end_quota_maintenance() { :; }
        collect_installed_state() { printf 'state\n'; }
        snapshot_subscription_update() {
            printf 'snapshot\n'
            UPDATE_SUB_ROLLBACK_ON_EXIT=1
        }
        configure_bbr_tcp() { printf 'bbr\n'; }
        configure_ufw() { printf 'ufw\n'; }
        prepare_aws_origin_dns() { printf 'dns\n'; }
        configure_aws_cdn() { printf 'cdn\n'; }
        refresh_runtime() { printf 'runtime\n'; }
        write_subscriptions() { printf 'subscriptions\n'; }
        validate_subscription_runtime() { printf 'validate-subscription\n'; }
        save_state() { printf 'save\n'; }
        register_easy_all_command() { printf 'register\n'; }
        show_subscription() { printf 'show\n'; }
        success() { :; }
        apply_cloud_resources
    )
    assert_equal "explicit cloud apply completes CDN before switching runtime" \
        $'root\nstate\nsnapshot\nbbr\nufw\ndns\ncdn\nruntime\nsubscriptions\nvalidate-subscription\nsave\nregister\nshow' "${cloud_apply_calls}"
)

readme=$(cat "${ROOT_DIR}/README.md" "${ROOT_DIR}/docs/aws-guide.md")
assert_contains "README rejects AWS root credentials" "${readme}" "不要使用 AWS 根用户凭证"
assert_contains "README documents AWS token terminology" "${readme}" "Access Key ID"
assert_contains "README matches current IAM group option" "${readme}" "添加用户到组"
assert_contains "README names managed policy" "${readme}" "easy_all_deploy_policy"
assert_contains "AWS guide highlights the required Route 53 zone replacement" \
    "${readme}" "REPLACE_WITH_YOUR_ROUTE53_HOSTED_ZONE_ID"
assert_contains "AWS guide requires the global AWS account partition" \
    "${readme}" "AWS 中国区域账号"
assert_contains "AWS guide documents CloudFront's monthly free transfer allowance" \
    "${readme}" "100 GB + 100 万次请求"
assert_contains "AWS guide documents CloudFront pay-as-you-go free allowance" \
    "${readme}" "1 TB + 1000 万次请求"
assert_contains "AWS guide estimates standard Route 53 queries" \
    "${readme}" '$0.40/百万次'
assert_contains "AWS guide requires Route 53 public DNS delegation for XHTTP" \
    "${readme}" "这是 CDN XHTTP 的**必要条件**"
assert_contains "AWS guide distinguishes DNS delegation from domain registration transfer" \
    "${readme}" "注册商不必迁入 AWS"
assert_contains "AWS guide protects DNSSEC migrations" "${readme}" "DNSSEC"
assert_contains "README includes top-down Mermaid install flow" "${readme}" 'flowchart TD'
assert_contains "README documents direct-enter semantics" "${readme}" \
    "直接回车会采用该值"

[[ ! -e "${ROOT_DIR}/sample-worker.js" ]] || fail "XHTTP profile must not retain Worker source"

printf 'easy_all XHTTP tests passed\n'
