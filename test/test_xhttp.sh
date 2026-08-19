#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
PROFILE="${ROOT_DIR}/lib/xhttp.sh"
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

bash -n "${ROOT_DIR}/easy_all" "${PROFILE}"
assert_contains "installer refuses root credentials" "$(<"${PROFILE}")" \
    "拒绝使用 AWS 根用户访问密钥"
assert_contains "Xray XHTTP inbound" "$(<"${PROFILE}")" \
    'tag:"vless-xhttp-h2-in"'
assert_contains "Xray fixes XHTTP to stream-up" "$(<"${PROFILE}")" \
    'mode:"stream-up"'
assert_contains "quota mode exposes Stats API only on loopback" "$(<"${PROFILE}")" \
    'api:{tag:"api",listen:"127.0.0.1:10085",services:["StatsService"]}'
assert_contains "XHTTP state persists the quota start date" "$(<"${PROFILE}")" \
    'QUOTA_START_DATE=%q'
assert_contains "Xray keepalive stays below CloudFront response timeout" "$(<"${PROFILE}")" \
    'readonly XHTTP_STREAM_UP_SERVER_SECS="20-40"'
assert_contains "Nginx proxies XHTTP over gRPC" "$(<"${PROFILE}")" \
    'grpc_pass grpc://127.0.0.1:${XRAY_XHTTP_LOOPBACK_PORT}'
assert_contains "Nginx validates subscription tokens" "$(<"${PROFILE}")" \
    'map $arg_token $easy_all_subscription_allowed'
assert_contains "Nginx protects direct-origin subscription access" "$(<"${PROFILE}")" \
    'if (\$http_x_easy_all_origin_key != "${ORIGIN_HEADER_SECRET}") { return 404; }'
assert_contains "Nginx serves internal Mihomo subscription" "$(<"${PROFILE}")" \
    'mihomo_alias="${SUBSCRIPTION_MIHOMO_FILE}"'
assert_contains "installer validates sshd before scheduled reboot" "$(<"${PROFILE}")" \
    '"${sshd_bin}" -t'
assert_contains "installer enables SSH at boot" "$(<"${PROFILE}")" \
    'systemctl enable --now "${unit}"'
assert_contains "installer verifies SSH boot enablement" "$(<"${PROFILE}")" \
    'systemctl is-enabled --quiet "${unit}"'
assert_contains "installer verifies ACME renewal cron" "$(<"${PROFILE}")" \
    'die "未找到 acme.sh 自动续期定时任务"'
assert_contains "XHTTP repairs a missing ACME renewal cron job" "$(<"${PROFILE}")" \
    'run_acme --install-cronjob'
assert_contains "XHTTP writes a managed cron fallback when acme.sh does not" "$(<"${PROFILE}")" \
    "easy_all-acme-renewal"
assert_contains "installer verifies renewal reload hook" "$(<"${PROFILE}")" \
    '源站证书、私钥或续期重载钩子安装不完整'
assert_contains "subscription updates enable rollback" "$(<"${PROFILE}")" \
    'UPDATE_SUB_ROLLBACK_ON_EXIT=1'
assert_contains "CloudFront health failures are fatal" "$(<"${PROFILE}")" \
    'die "CloudFront 公网验收失败'
assert_contains "CloudFront reinstallation discovers an existing alias before creation" \
    "$(<"${PROFILE}")" 'alias_conflicts=$(find_distribution_by_alias || true)'
assert_contains "CloudFront reinstallation automatically adopts a unique alias match" \
    "$(<"${PROFILE}")" 'AWS_ADOPT_DISTRIBUTION=1'
assert_contains "non-interactive uninstall requires FORCE" "$(<"${PROFILE}")" \
    '非交互卸载必须显式设置 FORCE=1'

(
    # shellcheck source=/dev/null
    source "${PROFILE}"

    assert_equal "profile" "xhttp" "${EASY_ALL_PROFILE}"
    assert_equal "unified state" "/etc/easy_all" "${STATE_DIR}"
    assert_equal "unified service" "easy_all-xray.service" "${XRAY_SERVICE}"
    assert_equal "unified nginx config" "/etc/nginx/conf.d/easy_all.conf" "${NGINX_CONFIG}"
    assert_equal "schema" "2" "${STATE_SCHEMA_VERSION}"
    assert_equal "AWS control region" "us-east-1" "${AWS_CONTROL_REGION}"
    assert_equal "caching disabled policy" \
        "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" "${CLOUDFRONT_CACHE_POLICY_ID}"
    assert_equal "all viewer except host policy" \
        "b689b0a8-53d0-40ab-baf2-68738e2966ac" "${CLOUDFRONT_ORIGIN_REQUEST_POLICY_ID}"
    assert_equal "stream-up server keepalive" "20-40" "${XHTTP_STREAM_UP_SERVER_SECS}"
    assert_equal "XMUX max concurrency" "4-8" "${XHTTP_XMUX_MAX_CONCURRENCY}"
    assert_equal "XMUX browser-like keepalive" "0" "${XHTTP_XMUX_H_KEEP_ALIVE_PERIOD}"
    assert_equal "CloudFront origin response timeout" "60" "${CLOUDFRONT_ORIGIN_READ_TIMEOUT}"
    assert_contains "XHTTP prompts for the Mihomo download filename" \
        "$(<"${PROFILE}")" 'Mihomo 下载文件名（不含 .yaml）'
    assert_contains "XHTTP default prompts explain the enter default" \
        "$(<"${PROFILE}")" '[${default}]（直接回车使用默认值）'
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
            STATE_VERSION="1"
            PROTOCOL="xhttp"
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

    aws() {
        printf '%s\n' '{"DistributionList":{"Items":[
          {"Id":"CONFLICT123","DomainName":"d111111abcdef8.cloudfront.net","Status":"Deployed",
           "Comment":"legacy distribution","Aliases":{"Quantity":1,"Items":["node.example.com"]}},
          {"Id":"OTHER123","DomainName":"d222222abcdef8.cloudfront.net","Status":"Deployed",
           "Comment":"unrelated","Aliases":{"Quantity":1,"Items":["other.example.com"]}}
        ]}}'
    }
    assert_equal "CloudFront alias conflict discovery reports the owning distribution" \
        $'CONFLICT123\td111111abcdef8.cloudfront.net\tDeployed\tlegacy distribution' \
        "$(find_distribution_by_alias)"
    unset -f aws

    PROTOCOL="xhttp"
    XHTTP_NODE_NAME="EASY_ALL_XHTTP_TEST"
    VLESS_UUID="00000000-0000-4000-8000-000000000001"
    VLESS_CDN_DOMAIN="node.example.com"
    AWS_ORIGIN_DOMAIN="origin.example.com"
    XHTTP_PATH="/xhttp-test-path"
    XRAY_XHTTP_LOOPBACK_PORT="10086"
    ORIGIN_HEADER_SECRET="test-origin-header-secret"
    AWS_ACM_CERTIFICATE_ARN="arn:aws:acm:us-east-1:111122223333:certificate/test"
    ALLOWED_TOKENS='{"owner":"owner-token-123"}'
    SUB_DOWNLOAD_NAME="EASY_ALL_TEST"

    link=$(build_node_link)
    assert_contains "VLESS scheme" "${link}" "vless://"
    assert_contains "CloudFront hostname" "${link}" "@node.example.com:443"
    assert_contains "XHTTP transport" "${link}" "type=xhttp"
    assert_contains "XHTTP stream-up" "${link}" "mode=stream-up"
    assert_contains "XHTTP path" "${link}" "path=%2Fxhttp-test-path"
    assert_contains "XHTTP XMUX extra" "${link}" "extra="
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
        .Origins.Items[0].CustomOriginConfig.OriginReadTimeout == 60 and
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
        .Comment == "easy_all:xhttp:node.example.com"
    ' "${distribution}" >/dev/null || fail "CloudFront distribution config is invalid"

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
assert_contains "README warns against root keys" "${readme}" "不要为根用户创建访问密钥"
assert_contains "README documents AWS token terminology" "${readme}" "Access Key ID"
assert_contains "README matches current IAM group option" "${readme}" "添加用户到组"
assert_contains "README names managed policy" "${readme}" "easy_all_deploy_policy"
assert_contains "AWS guide highlights the required Route 53 zone replacement" \
    "${readme}" "REPLACE_WITH_YOUR_ROUTE53_HOSTED_ZONE_ID"
assert_contains "AWS guide requires the global AWS account partition" \
    "${readme}" "AWS 中国区域账号"
assert_contains "AWS guide documents CloudFront's monthly free transfer allowance" \
    "${readme}" "1 TB 向互联网传出"
assert_contains "README includes top-down Mermaid install flow" "${readme}" 'flowchart TD'
assert_contains "README documents direct-enter semantics" "${readme}" \
    "直接回车会采用该值"

[[ ! -e "${ROOT_DIR}/sample-worker.js" ]] || fail "XHTTP profile must not retain Worker source"

printf 'easy_all XHTTP tests passed\n'
