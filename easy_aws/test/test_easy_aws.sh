#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
REPO_DIR=$(cd -- "${ROOT_DIR}/.." >/dev/null 2>&1 && pwd)
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

bash -n "${ROOT_DIR}/easy_aws"
assert_contains "installer refuses root credentials" "$(<"${ROOT_DIR}/easy_aws")" \
    "拒绝使用 AWS 根用户访问密钥"
assert_contains "Xray WebSocket heartbeat" "$(<"${ROOT_DIR}/easy_aws")" \
    "heartbeatPeriod:60"
assert_contains "Xray XHTTP inbound" "$(<"${ROOT_DIR}/easy_aws")" \
    'tag:"vless-xhttp-h2-in"'
assert_contains "Xray accepts XHTTP client modes" "$(<"${ROOT_DIR}/easy_aws")" \
    'xhttpSettings:{host:$xhttp_host,path:$xhttp_path,mode:"auto"}'
assert_contains "Nginx proxies XHTTP over gRPC" "$(<"${ROOT_DIR}/easy_aws")" \
    'grpc_pass grpc://127.0.0.1:${XRAY_XHTTP_LOOPBACK_PORT}'

(
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/easy_aws"

    assert_equal "profile" "aws" "${EASY_AWS_PROFILE}"
    assert_equal "isolated state" "/etc/easy_aws" "${STATE_DIR}"
    assert_equal "isolated service" "easy-aws-xray.service" "${XRAY_SERVICE}"
    assert_equal "isolated nginx config" "/etc/nginx/conf.d/easy_aws.conf" "${NGINX_CONFIG}"
    assert_equal "schema" "1" "${STATE_SCHEMA_VERSION}"
    assert_equal "AWS control region" "us-east-1" "${AWS_CONTROL_REGION}"
    assert_equal "caching disabled policy" \
        "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" "${CLOUDFRONT_CACHE_POLICY_ID}"
    assert_equal "all viewer except host policy" \
        "b689b0a8-53d0-40ab-baf2-68738e2966ac" "${CLOUDFRONT_ORIGIN_REQUEST_POLICY_ID}"

    (
        source_state_file() {
            PROTOCOL="vless-ws"
            VLESS_NODE_NAME="LEGACY_WS"
            VLESS_UUID="00000000-0000-4000-8000-000000000001"
            VLESS_CDN_DOMAIN="node.example.com"
            VLESS_WS_PATH="/vless-legacy-suffix"
            AWS_ORIGIN_DOMAIN="origin.example.com"
            XRAY_VLESS_LOOPBACK_PORT="10085"
        }
        load_state
        assert_equal "legacy protocol migration" "vless-ws-xhttp" "${PROTOCOL}"
        assert_equal "legacy XHTTP path migration" "/xhttp-legacy-suffix" "${XHTTP_PATH}"
        assert_equal "legacy XHTTP port migration" "10086" "${XRAY_XHTTP_LOOPBACK_PORT}"
    )

    zones='{"HostedZones":[{"Id":"/hostedzone/ZBASE","Name":"example.com.","Config":{"PrivateZone":false}},{"Id":"/hostedzone/ZPRIVATE","Name":"node.example.com.","Config":{"PrivateZone":true}},{"Id":"/hostedzone/ZBOUNDARY","Name":"notexample.com.","Config":{"PrivateZone":false}}]}'
    assert_equal "Route 53 public parent zone" $'/hostedzone/ZBASE\texample.com.' \
        "$(find_route53_zone_for_domain node.example.com "${zones}")"
    assert_equal "Route 53 boundary-safe matching" $'/hostedzone/ZBOUNDARY\tnotexample.com.' \
        "$(find_route53_zone_for_domain node.notexample.com "${zones}")"

    PROTOCOL="vless-ws-xhttp"
    VLESS_NODE_NAME="AWS_WS_TEST"
    XHTTP_NODE_NAME="AWS_XHTTP_TEST"
    VLESS_UUID="00000000-0000-4000-8000-000000000001"
    VLESS_CDN_DOMAIN="node.example.com"
    AWS_ORIGIN_DOMAIN="origin.example.com"
    VLESS_WS_PATH="/vless-test-path"
    XHTTP_PATH="/xhttp-test-path"
    XRAY_VLESS_LOOPBACK_PORT="10085"
    XRAY_XHTTP_LOOPBACK_PORT="10086"
    ORIGIN_HEADER_SECRET="test-origin-header-secret"
    AWS_ACM_CERTIFICATE_ARN="arn:aws:acm:us-east-1:111122223333:certificate/test"
    ALLOWED_TOKENS='{"owner":"owner-token-123"}'
    SUB_DOWNLOAD_NAME="AWS_TEST"

    link=$(build_node_link)
    assert_contains "VLESS scheme" "${link}" "vless://"
    assert_contains "WebSocket transport" "${link}" "type=ws"
    assert_contains "CloudFront hostname" "${link}" "@node.example.com:443"
    assert_contains "Early Data" "${link}" "%3Fed%3D2560"
    assert_contains "XHTTP transport" "${link}" "type=xhttp"
    assert_contains "XHTTP stream-up" "${link}" "mode=stream-up"
    assert_contains "XHTTP path" "${link}" "path=%2Fxhttp-test-path"
    assert_contains "XHTTP XMUX extra" "${link}" "extra="
    [[ "${link}" != *"trojan"* ]] || fail "links must contain only VLESS"
    assert_equal "exactly two links" "2" "$(wc -l <<<"${link}" | tr -d ' ')"

    mihomo=$(build_mihomo_node)
    assert_contains "Mihomo WebSocket" "${mihomo}" "network: ws"
    assert_contains "Mihomo Early Data" "${mihomo}" "max-early-data: 2560"
    assert_contains "Mihomo smux disabled" "${mihomo}" "enabled: false"
    assert_contains "Mihomo XHTTP" "${mihomo}" "network: xhttp"
    assert_contains "Mihomo stream-up" "${mihomo}" "mode: stream-up"
    assert_contains "Mihomo XMUX" "${mihomo}" "reuse-settings:"
    assert_contains "Mihomo XMUX keepalive" "${mihomo}" "h-keep-alive-period: 60"

    distribution="${TMP_DIR}/distribution.json"
    build_distribution_config "${distribution}" "test-caller-reference"
    jq -e '
        .CallerReference == "test-caller-reference" and
        .Aliases.Items == ["node.example.com"] and
        .DefaultRootObject == "" and
        .Origins.Items[0].DomainName == "origin.example.com" and
        .Origins.Items[0].CustomOriginConfig.OriginProtocolPolicy == "https-only" and
        .Origins.Items[0].CustomOriginConfig.OriginSslProtocols.Items == ["TLSv1.2"] and
        .Origins.Items[0].ConnectionAttempts == 2 and
        .Origins.Items[0].ConnectionTimeout == 3 and
        .Origins.Items[0].CustomHeaders.Items[0].HeaderName == "X-Easy-Aws-Origin-Key" and
        .DefaultCacheBehavior.ViewerProtocolPolicy == "https-only" and
        .DefaultCacheBehavior.CachePolicyId == "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" and
        .DefaultCacheBehavior.OriginRequestPolicyId == "b689b0a8-53d0-40ab-baf2-68738e2966ac" and
        (.DefaultCacheBehavior.AllowedMethods.Items | sort) == (["GET","HEAD","OPTIONS","PUT","POST","PATCH","DELETE"] | sort) and
        .DefaultCacheBehavior.GrpcConfig.Enabled == true and
        .ViewerCertificate.ACMCertificateArn == "arn:aws:acm:us-east-1:111122223333:certificate/test" and
        .Comment == "easy_aws:node.example.com"
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

    SAMPLE_WORKER_SOURCE="${REPO_DIR}/for_cmcc/sample-worker.js"
    worker="${TMP_DIR}/subscribe-worker.js"
    write_worker "${worker}"
    node --check "${worker}"
    assert_equal "two rendered VLESS nodes" "2" \
        "$(grep -Fo '"type":"vless"' "${worker}" | wc -l | tr -d ' ')"
    assert_equal "one rendered WebSocket node" "1" \
        "$(grep -Fo '"network":"ws"' "${worker}" | wc -l | tr -d ' ')"
    assert_equal "one rendered XHTTP node" "1" \
        "$(grep -Fo '"network":"xhttp"' "${worker}" | wc -l | tr -d ' ')"
    assert_contains "Worker token" "$(<"${worker}")" "owner-token-123"
    assert_contains "Worker download name" "$(<"${worker}")" "AWS_TEST"
    node --input-type=module - "${worker}" <<'NODE'
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';

const workerPath = process.argv[2];
const module = await import(pathToFileURL(workerPath));
const base = 'https://worker.example.test/subscribe?token=owner-token-123';
const plainResponse = await module.default.fetch(new Request(base));
assert.equal(plainResponse.status, 200);
const decoded = Buffer.from(await plainResponse.text(), 'base64').toString('utf8');
assert.equal(decoded.trim().split('\n').length, 2);
assert.match(decoded, /^vless:\/\//);
assert.match(decoded, /type=ws/);
assert.match(decoded, /type=xhttp/);
assert.match(decoded, /mode=stream-up/);
assert.match(decoded, /extra=/);
assert.doesNotMatch(decoded, /trojan/);

const clashResponse = await module.default.fetch(new Request(`${base}&flag=clash`));
assert.equal(clashResponse.status, 200);
const clash = await clashResponse.text();
assert.match(clash, /network: ws/);
assert.match(clash, /max-early-data: 2560/);
assert.match(clash, /network: xhttp/);
assert.match(clash, /mode: "stream-up"/);
assert.match(clash, /reuse-settings:/);
assert.match(clash, /h-keep-alive-period: 60/);
NODE
)

readme=$(<"${ROOT_DIR}/README.md")
assert_contains "README warns against root keys" "${readme}" "不要为根用户创建访问密钥"
assert_contains "README documents manual Worker" "${readme}" "不会调用 Cloudflare Worker API"
assert_contains "README documents two nodes" "${readme}" "WebSocket 与 XHTTP"
assert_contains "README documents AWS token terminology" "${readme}" "Access Key ID"
assert_contains "README matches current IAM group option" "${readme}" "添加用户到组"
assert_contains "README names managed policy" "${readme}" "EasyAwsDeployPolicy"
assert_contains "README defaults to one Route 53 zone" "${readme}" "YOUR_ZONE_ID"
assert_contains "README explains missing CDN record" "${readme}" "安装前没有"
assert_contains "README requires AWS DNS" "${readme}" "DNS 使用 AWS Route 53"
assert_contains "README documents origin A automation" "${readme}" "创建源站 A"
assert_contains "README includes architecture diagram" "${readme}" "aws-architecture.svg"
assert_contains "README includes IAM diagram" "${readme}" "aws-iam-access-key.svg"
assert_contains "README includes CloudFront diagram" "${readme}" "aws-cloudfront-settings.svg"

printf 'easy_aws tests passed\n'
