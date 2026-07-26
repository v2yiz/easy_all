#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
TMP_DIR="$(mktemp -d)"
SCRIPT_COPY="${TMP_DIR}/easy_anytls.test.sh"
FAKE_BIN="${TMP_DIR}/bin"
TESTS_RUN=0

fail_test() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

assert_success() {
    local description=$1
    shift
    TESTS_RUN=$((TESTS_RUN + 1))
    "$@" || fail_test "${description}"
}

assert_failure() {
    local description=$1
    shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@"; then
        fail_test "${description}"
    fi
}

assert_equal() {
    local description=$1 expected=$2 actual=$3
    TESTS_RUN=$((TESTS_RUN + 1))
    [[ "${actual}" == "${expected}" ]] \
        || fail_test "${description}: expected '${expected}', got '${actual}'"
}

assert_contains() {
    local description=$1 needle=$2 haystack=$3
    TESTS_RUN=$((TESTS_RUN + 1))
    [[ "${haystack}" == *"${needle}"* ]] \
        || fail_test "${description}: missing '${needle}'"
}

assert_not_contains() {
    local description=$1 needle=$2 haystack=$3
    TESTS_RUN=$((TESTS_RUN + 1))
    [[ "${haystack}" != *"${needle}"* ]] \
        || fail_test "${description}: unexpected '${needle}'"
}

file_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

mkdir -p "${FAKE_BIN}" "${TMP_DIR}/state" "${TMP_DIR}/sing-box-config"
sed \
    -e "s|^readonly STATE_DIR=.*|readonly STATE_DIR=\"${TMP_DIR}/state\"|" \
    -e "s|^readonly COMMAND_INSTALL_DIR=.*|readonly COMMAND_INSTALL_DIR=\"${TMP_DIR}/command\"|" \
    -e "s|^readonly SING_BOX_BIN=.*|readonly SING_BOX_BIN=\"${FAKE_BIN}/sing-box\"|" \
    -e "s|^readonly SING_BOX_CONFIG_DIR=.*|readonly SING_BOX_CONFIG_DIR=\"${TMP_DIR}/sing-box-config\"|" \
    -e "s|^readonly ACME_HOME=.*|readonly ACME_HOME=\"${TMP_DIR}/acme\"|" \
    "${ROOT_DIR}/easy_anytls.sh" >"${SCRIPT_COPY}"

cat >"${FAKE_BIN}/sing-box" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
version) printf 'sing-box version 1.13.12\n' ;;
check) exit 0 ;;
*) exit 0 ;;
esac
EOF
chmod +x "${FAKE_BIN}/sing-box"

# shellcheck source=/dev/null
source "${SCRIPT_COPY}"
trap 'cleanup; rm -rf -- "${TMP_DIR}"' EXIT

test_validators() {
    assert_success "valid domain accepted" validate_domain "node.example.com"
    assert_failure "IP is not accepted as domain" validate_domain "203.0.113.10"
    assert_failure "wildcard domain rejected" validate_domain "*.example.com"
    assert_failure "leading hyphen rejected" validate_domain "-node.example.com"
    assert_failure "empty label rejected" validate_domain "node..example.com"
    assert_equal "domain normalized" "node.example.com" \
        "$(normalize_domain "Node.Example.COM.")"

    assert_success "valid IPv4 accepted" validate_ipv4 "203.0.113.10"
    assert_failure "invalid IPv4 rejected" validate_ipv4 "203.0.113.999"

    assert_success "latest selector accepted" validate_sing_box_selector "latest"
    assert_success "alpha selector accepted" validate_sing_box_selector "alpha"
    assert_success "stable version accepted" validate_sing_box_selector "1.13.12"
    assert_success "alpha version accepted" \
        validate_sing_box_selector "v1.14.0-alpha.26"
    assert_failure "partial version rejected" validate_sing_box_selector "1.13"

    assert_success "minimum AnyTLS version accepted" \
        version_at_least "1.12.0" "1.12.0"
    assert_success "new alpha core accepted" \
        version_at_least "v1.14.0-alpha.1" "1.12.0"
    assert_failure "old version rejected" \
        version_at_least "1.11.15" "1.12.0"
}

test_dns_set_validation() {
    assert_success "single matching A accepted" \
        validate_resolved_ipv4_set "203.0.113.10" "203.0.113.10"
    assert_success "duplicate matching A accepted" \
        validate_resolved_ipv4_set "203.0.113.10" \
        $'203.0.113.10\n203.0.113.10'
    assert_failure "empty A set rejected" \
        validate_resolved_ipv4_set "203.0.113.10" ""
    assert_failure "mismatching A rejected" \
        validate_resolved_ipv4_set "203.0.113.10" "198.51.100.20"
    assert_failure "mixed A set rejected" \
        validate_resolved_ipv4_set "203.0.113.10" \
        $'203.0.113.10\n198.51.100.20'
}

test_links_and_client_config() {
    ANYTLS_DOMAIN="node.example.com"
    ANYTLS_PASSWORD="pa ss/word+with?chars"
    NODE_NAME="My AnyTLS"
    local link config
    link=$(build_anytls_link)
    assert_contains "link uses AnyTLS scheme" "anytls://" "${link}"
    assert_contains "password is URI encoded" \
        "pa%20ss%2Fword%2Bwith%3Fchars@" "${link}"
    assert_contains "link uses verified TLS" "insecure=0" "${link}"
    assert_contains "node name is URI encoded" "#My%20AnyTLS" "${link}"

    config=$(build_client_outbound_json)
    assert_equal "client config is AnyTLS" "anytls" \
        "$(jq -r '.type' <<<"${config}")"
    assert_equal "client config uses domain as SNI" "node.example.com" \
        "$(jq -r '.tls.server_name' <<<"${config}")"
    assert_equal "client config verifies certificate" "false" \
        "$(jq -r '.tls.insecure' <<<"${config}")"
}

test_worker_output() {
    ANYTLS_DOMAIN="node.example.com"
    ANYTLS_PASSWORD="safe-password-123456"
    NODE_NAME="MY_ANYTLS"
    SUB_DOWNLOAD_NAME="Team_Sub"
    local worker="${TMP_DIR}/worker.js" content
    write_worker "${worker}"
    content=$(<"${worker}")
    assert_contains "Worker contains AnyTLS URI" "anytls://" "${content}"
    assert_contains "Worker contains AnyTLS Mihomo type" \
        "type: anytls" "${content}"
    assert_contains "Worker contains server" "node.example.com" "${content}"
    assert_contains "Worker requires token" "env.SUB_TOKEN" "${content}"
    assert_contains "Worker verifies certificates" \
        "skip-cert-verify: false" "${content}"
    assert_not_contains "Worker has no VLESS output" "vless://" "${content}"
    assert_success "Worker JavaScript syntax valid" node --check "${worker}"
}

test_state_secret_boundary() {
    ANYTLS_DOMAIN="node.example.com"
    ANYTLS_PASSWORD="state-password-123456"
    NODE_NAME="MY_ANYTLS"
    SING_BOX_VERSION="alpha"
    SING_BOX_CHANNEL="alpha"
    SING_BOX_INSTALLED_VERSION="1.14.0-alpha.26"
    SUB_TOKEN="subscription-token"
    WORKER_NAME="easy-anytls"
    WORKER_URL=""
    CF_ACCOUNT_ID="account-id"
    DEPLOY_MODE="worker"
    SUB_DOWNLOAD_NAME="MY_SUB"
    CF_DNS_API_TOKEN="dns-secret-must-not-be-saved"
    CF_WORKER_API_TOKEN="worker-secret-must-not-be-saved"
    save_state
    local content
    content=$(<"${STATE_FILE}")
    assert_contains "state saves selected channel" \
        "SING_BOX_CHANNEL=alpha" "${content}"
    assert_contains "state saves AnyTLS password for show" \
        "ANYTLS_PASSWORD=state-password-123456" "${content}"
    assert_not_contains "state excludes DNS token" \
        "dns-secret-must-not-be-saved" "${content}"
    assert_not_contains "state excludes Worker token" \
        "worker-secret-must-not-be-saved" "${content}"
    assert_contains "state tracks acme.sh ownership" \
        "ACME_INSTALLED_BY_EASY_ANYTLS=0" "${content}"
    assert_equal "state file mode is 600" "600" \
        "$(file_mode "${STATE_FILE}")"
}

test_cloudflare_credential_boundaries() {
    local certificate_body worker_body
    CF_DNS_API_TOKEN="dns-token"
    CF_DNS_TOKEN_VALUE=""
    collect_cloudflare_dns_credentials
    assert_equal "certificate collection accepts DNS token alone" \
        "dns-token" "${CF_DNS_TOKEN_VALUE}"

    certificate_body=$(declare -f collect_cloudflare_dns_credentials)
    assert_not_contains "certificate collection does not request Account ID" \
        "CF_ACCOUNT_ID" "${certificate_body}"
    assert_not_contains "certificate collection does not request Zone ID" \
        "CF_ZONE_ID" "${certificate_body}"

    worker_body=$(declare -f deploy_worker)
    assert_contains "automatic Worker deployment requests Account ID" \
        "Cloudflare Account ID" "${worker_body}"
    assert_contains "automatic Worker deployment requests Worker token" \
        "Cloudflare Worker API Token" "${worker_body}"
    assert_contains "Worker multipart filename matches main_module" \
        "filename=worker.js" "${worker_body}"
    assert_contains "Worker subdomain request sends JSON" \
        "Content-Type: application/json" "${worker_body}"
}

test_acme_issue_statuses() {
    assert_success "acme successful issuance is usable" \
        acme_issue_status_is_usable 0
    assert_success "acme unchanged-domain skip is usable" \
        acme_issue_status_is_usable 2
    assert_failure "acme API failure remains fatal" \
        acme_issue_status_is_usable 1
}

test_release_resolution() {
    local digest="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    curl() {
        case "$*" in
        *"?per_page=100"*)
            jq -cn --arg digest "${digest}" '[
              {
                draft: false,
                prerelease: true,
                tag_name: "v1.14.0-alpha.26",
                assets: [{
                  name: "sing-box-1.14.0-alpha.26-linux-amd64.tar.gz",
                  browser_download_url: "https://example.test/alpha.tar.gz",
                  digest: $digest
                }]
              },
              {
                draft: false,
                prerelease: false,
                tag_name: "v1.13.12",
                assets: []
              }
            ]'
            ;;
        *"/latest"*)
            jq -cn --arg digest "${digest}" '{
              tag_name: "v1.13.12",
              assets: [{
                name: "sing-box-1.13.12-linux-amd64.tar.gz",
                browser_download_url: "https://example.test/stable.tar.gz",
                digest: $digest
              }]
            }'
            ;;
        *"/tags/v1.12.0"*)
            jq -cn --arg digest "${digest}" '{
              tag_name: "v1.12.0",
              assets: [{
                name: "sing-box-1.12.0-linux-amd64.tar.gz",
                browser_download_url: "https://example.test/pinned.tar.gz",
                digest: $digest
              }]
            }'
            ;;
        *) return 1 ;;
        esac
    }

    resolve_sing_box_release latest
    assert_equal "latest resolves stable version" "1.13.12" \
        "${SING_BOX_RELEASE_VERSION}"
    assert_equal "latest records stable channel" "latest" "${SING_BOX_CHANNEL}"

    resolve_sing_box_release alpha
    assert_equal "alpha resolves newest alpha" "1.14.0-alpha.26" \
        "${SING_BOX_RELEASE_VERSION}"
    assert_equal "alpha records alpha channel" "alpha" "${SING_BOX_CHANNEL}"

    resolve_sing_box_release 1.12.0
    assert_equal "specific version resolves exactly" "1.12.0" \
        "${SING_BOX_RELEASE_VERSION}"
    assert_equal "specific version records pinned channel" \
        "pinned" "${SING_BOX_CHANNEL}"
    unset -f curl
}

test_server_config() {
    ANYTLS_DOMAIN="node.example.com"
    ANYTLS_PASSWORD="server-password-123456"
    write_sing_box_config
    local content
    content=$(<"${SING_BOX_CONFIG}")
    assert_equal "server inbound is AnyTLS" "anytls" \
        "$(jq -r '.inbounds[0].type' <<<"${content}")"
    assert_equal "server listens on 443" "443" \
        "$(jq -r '.inbounds[0].listen_port' <<<"${content}")"
    assert_equal "server uses certificate path" "${CERT_FILE}" \
        "$(jq -r '.inbounds[0].tls.certificate_path' <<<"${content}")"
    assert_equal "server keeps AI IPv4 route action" "ipv4_only" \
        "$(jq -r '.route.rules[0].strategy' <<<"${content}")"
    assert_equal "server config file mode is 600" "600" \
        "$(file_mode "${SING_BOX_CONFIG}")"
}

test_reload_hook() {
    install_certificate_reload_hook
    local content
    content=$(<"${CERT_RELOAD_HOOK}")
    assert_contains "reload hook only restarts an active service" \
        "if ! /usr/bin/systemctl is-active --quiet sing-box.service" "${content}"
    assert_contains "reload hook restarts sing-box" \
        "/usr/bin/systemctl restart sing-box.service" "${content}"
    assert_contains "reload hook waits for TCP 443" \
        "sport = :443" "${content}"
    assert_equal "reload hook is executable" "755" \
        "$(file_mode "${CERT_RELOAD_HOOK}")"
}

test_safe_uninstall_helpers() {
    local script_content uninstall_body
    mkdir -p "${BACKUP_DIR}"
    touch \
        "${BACKUP_DIR}/install-sing-box.1.bak" \
        "${BACKUP_DIR}/sing-box-config.1.bak" \
        "${BACKUP_DIR}/install-nftables.conf.1.bak" \
        "${BACKUP_DIR}/install-sysctl-bbrv3.1.bak"
    purge_anytls_backups
    assert_failure "AnyTLS purge removes sing-box binary backup" \
        test -e "${BACKUP_DIR}/install-sing-box.1.bak"
    assert_failure "AnyTLS purge removes sing-box config backup" \
        test -e "${BACKUP_DIR}/sing-box-config.1.bak"
    assert_success "AnyTLS purge preserves nftables initialization backup" \
        test -e "${BACKUP_DIR}/install-nftables.conf.1.bak"
    assert_success "AnyTLS purge preserves sysctl initialization backup" \
        test -e "${BACKUP_DIR}/install-sysctl-bbrv3.1.bak"

    script_content=$(<"${ROOT_DIR}/easy_anytls.sh")
    uninstall_body=$(declare -f uninstall_anytls)
    assert_contains "AnyTLS exposes purge uninstall mode" \
        "uninstall --purge" "${script_content}"
    assert_contains "remote Worker deletion requires explicit opt-in" \
        'DELETE_CLOUDFLARE_WORKER:-0' "${script_content}"
    assert_contains "shared acme removal requires explicit opt-in" \
        'PURGE_SHARED_ACME:-0' "${script_content}"
    assert_not_contains "AnyTLS uninstall never restores system settings" \
        "restore_system_changes" "${uninstall_body}"
    assert_contains "AnyTLS uninstall removes its reboot schedule" \
        "remove_daily_reboot_schedule" "${uninstall_body}"
    assert_contains "AnyTLS uninstall cleans its acme.sh installation" \
        "purge_acme_installation" "${uninstall_body}"
    assert_contains "AnyTLS records acme.sh ownership before install completes" \
        "acme-installed-by-easy-anytls" "${script_content}"
    assert_not_contains "AnyTLS uninstall never purges XanMod" \
        "purge_xanmod" "${uninstall_body}"

    mkdir -p "${ACME_HOME}/other.example_ecc"
    touch "${ACME_HOME}/other.example_ecc/other.example.conf"
    ACME_INSTALLED_BY_EASY_ANYTLS=1
    PURGE_SHARED_ACME=0
    purge_acme_installation >/dev/null
    assert_success "AnyTLS purge preserves acme.sh with another domain" \
        test -d "${ACME_HOME}"

    local cron_input cron_output
    cron_input=$'15 3 * * * /usr/local/bin/backup\n0 4 * * * /sbin/reboot\n0 6 * * * /usr/bin/flock -n /run/daily-reboot.lock /sbin/reboot'
    cron_output=$(filter_managed_reboot_cron <<<"${cron_input}")
    assert_contains "reboot cleanup preserves unrelated cron" \
        "/usr/local/bin/backup" "${cron_output}"
    assert_not_contains "reboot cleanup removes legacy reboot cron" \
        "0 4 * * * /sbin/reboot" "${cron_output}"
    assert_not_contains "reboot cleanup removes managed reboot cron" \
        "/run/daily-reboot.lock" "${cron_output}"
}

test_startup_readiness_wait() {
    local checks=0
    systemctl() {
        case "${1:-}" in
        is-active) return 0 ;;
        is-failed) return 1 ;;
        *) return 0 ;;
        esac
    }
    tcp_port_is_listening() {
        checks=$((checks + 1))
        ((checks >= 3))
    }
    sleep() { :; }

    assert_success "startup readiness waits for a delayed listener" \
        wait_for_sing_box_ready 5
    assert_equal "startup readiness retried the listener check" "3" "${checks}"

    tcp_port_is_listening() { return 1; }
    assert_failure "startup readiness fails after the listener timeout" \
        wait_for_sing_box_ready 2
}

test_validators
test_dns_set_validation
test_links_and_client_config
test_worker_output
test_state_secret_boundary
test_cloudflare_credential_boundaries
test_acme_issue_statuses
test_release_resolution
test_server_config
test_reload_hook
test_safe_uninstall_helpers
test_startup_readiness_wait

printf 'ok - easy_anytls shell tests passed (%s assertions)\n' "${TESTS_RUN}"
