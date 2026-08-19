#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "${TMP_DIR}"' EXIT

TESTS_RUN=0
SCRIPT_LOADED=0

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
    if ( "$@" ) >/dev/null 2>&1; then
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

source_script_copy() {
    if [[ "${SCRIPT_LOADED}" == "1" ]]; then
        return
    fi

    local script_copy="${TMP_DIR}/debian_init.test.sh"
    HOME="${TMP_DIR}/home"
    export HOME
    mkdir -p "${HOME}/.ssh"
    sed 's/^main "$@"/: # main disabled for tests/' \
        "${ROOT_DIR}/debian_init.sh" >"${script_copy}"
    # shellcheck source=/dev/null
    source "${script_copy}"
    SCRIPT_LOADED=1
}

extract_remote_script() {
    awk '/^  cat > "\$local_script" <<'"'"'REMOTE'"'"'/ {in_block=1; next}
      in_block && /^REMOTE$/ {in_block=0; next}
      in_block {sub(/^  /, ""); print}' \
        "${ROOT_DIR}/debian_init.sh"
}

test_validators_and_normalizers() {
    source_script_copy

    local secret
    secret="$(printf 's3cr3t\n' | prompt_secret "hidden" 2>/dev/null)"
    assert_equal "secret prompt returns only typed value" "s3cr3t" "${secret}"

    secret="$(printf 'same\nsame\n' | prompt_confirmed_secret "hidden" 2>/dev/null)"
    assert_equal "confirmed secret returns only typed value" "same" "${secret}"

    assert_success "valid port is accepted" validate_port "22"
    assert_success "highest port is accepted" validate_port "65535"
    assert_failure "zero port is rejected" validate_port "0"
    assert_failure "non-numeric port is rejected" validate_port "ssh"
    assert_equal "port list accepts commas and removes duplicates" \
        "80 443" "$(normalize_port_list "80,443,80")"
    assert_equal "empty port list remains empty" "" "$(normalize_port_list "")"
    assert_failure "port list rejects invalid ports" normalize_port_list "80,70000"

    assert_success "valid host alias is accepted" validate_host_alias "v2yiz-node_1"
    assert_failure "host alias starting with dash is rejected" validate_host_alias "-bad"
    assert_failure "host alias with shell metacharacter is rejected" validate_host_alias "bad;name"

    assert_success "valid server host is accepted" validate_server_host "203.0.113.10"
    assert_failure "empty server host is rejected" validate_server_host ""
    assert_failure "server host with spaces is rejected" validate_server_host "bad host"

    assert_success "valid initial SSH user is accepted" validate_server_user "root"
    assert_success "user ending with dollar is accepted" validate_server_user "deploy$"
    assert_failure "initial SSH user starting with digit is rejected" validate_server_user "1bad"

    assert_success "valid normal user is accepted" validate_linux_user "v2yiz"
    assert_success "normal user with underscore is accepted" validate_linux_user "_svc"
    assert_failure "normal user with uppercase is rejected" validate_linux_user "Chenpei"
    assert_failure "normal user with dot is rejected" validate_linux_user "bad.name"

    assert_equal "home path expands" "${HOME}/.ssh/id_ed25519" "$(expand_path "~/.ssh/id_ed25519")"
    assert_equal "bare tilde expands" "${HOME}" "$(expand_path "~")"
    assert_equal "plain path is unchanged" "/tmp/key" "$(expand_path "/tmp/key")"

    assert_equal "alias spaces are replaced" "root-node.example.com" "$(sanitize_alias "root node.example.com")"
    assert_equal "alias invalid chars are replaced" "root-node" "$(sanitize_alias "root@node")"
    assert_equal "empty sanitized alias falls back" "server" "$(sanitize_alias "###")"
}

test_collected_ssh_ports() {
    source_script_copy

    local unchanged changed
    unchanged="$(
        collect_inputs >/dev/null <<'EOF'
203.0.113.10
root

deploy
secret
secret
node-a
22
no
EOF
        validate_collected_inputs
        printf '%s:%s:%s' "$CURRENT_PORT" "$FINAL_PORT" "$CHANGE_PORT"
    )"
    assert_equal "unchanged SSH port is always initialized" "22:22:no" "$unchanged"

    changed="$(
        collect_inputs >/dev/null <<'EOF'
203.0.113.10
root

deploy
secret
secret
node-b
22
yes
2222
EOF
        validate_collected_inputs
        printf '%s:%s:%s' "$CURRENT_PORT" "$FINAL_PORT" "$CHANGE_PORT"
    )"
    assert_equal "changed SSH port is always initialized" "22:2222:yes" "$changed"

    local same_port
    same_port="$(
        collect_inputs >/dev/null <<'EOF'
203.0.113.10
root

deploy
secret
secret
node-c
22
yes
22
EOF
        validate_collected_inputs
        printf '%s:%s:%s' "$CURRENT_PORT" "$FINAL_PORT" "$CHANGE_PORT"
    )"
    assert_equal "same SSH port is normalized to no change" "22:22:no" "$same_port"

    unset FINAL_PORT
    assert_failure "missing final SSH port is rejected before remote changes" validate_collected_inputs
}

test_managed_ssh_config() {
    source_script_copy

    write_ssh_config "node-a" "203.0.113.10" "v2yiz" "2222" "${HOME}/.ssh/id_ed25519"
    local content
    content="$(<"${SSH_CONFIG}")"
    assert_contains "ssh_config contains managed begin marker" "# >>> managed by setup_debian_ssh_key_only: node-a" "${content}"
    assert_contains "ssh_config writes normal user" "  User v2yiz" "${content}"
    assert_contains "ssh_config writes port" "  Port 2222" "${content}"
    assert_contains "ssh_config forces identity only" "  IdentitiesOnly yes" "${content}"
    assert_contains "ssh_config keeps idle sessions alive" "  ServerAliveInterval 30" "${content}"
    assert_contains "ssh_config limits dead keepalive probes" "  ServerAliveCountMax 3" "${content}"

    write_ssh_config "node-a" "198.51.100.20" "deploy" "2200" "${HOME}/.ssh/deploy"
    content="$(<"${SSH_CONFIG}")"
    assert_contains "managed block is replaced" "  HostName 198.51.100.20" "${content}"
    assert_contains "managed block user is replaced" "  User deploy" "${content}"
    assert_not_contains "old managed host is removed" "203.0.113.10" "${content}"

    printf '%s\n' "Host external" "  HostName example.com" >>"${SSH_CONFIG}"
    assert_failure "same alias inside managed block is ignored" host_alias_exists_outside_managed_block "node-a"
    assert_success "outside alias is detected" host_alias_exists_outside_managed_block "external"
}

test_remote_script_contract() {
    local remote_script="${TMP_DIR}/remote.sh"
    extract_remote_script >"${remote_script}"

    assert_success "embedded remote script is valid POSIX sh" sh -n "${remote_script}"

    local content
    content="$(<"${remote_script}")"
    assert_contains "remote installs tmux" "vim tmux curl wget" "${content}"
    assert_contains "remote installs build-essential" "git build-essential" "${content}"
    assert_contains "remote installs uv as normal user" "su - \"\$normal_user\" -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'" "${content}"
    assert_contains "remote installs Python 3.12 with uv" "python install 3.12" "${content}"
    assert_contains "remote updates existing user password" "chpasswd" "${content}"
    assert_contains "remote uses actual primary group" "normal_group=\"\$(id -gn \"\$normal_user\")\"" "${content}"
    assert_contains "remote writes sudoers with password sudo" "ALL=(ALL:ALL) ALL" "${content}"
    assert_contains "remote configures Shanghai timezone" "timedatectl set-timezone Asia/Shanghai" "${content}"
    assert_contains "remote enables time sync" "systemd-timesyncd" "${content}"
    assert_contains "remote uses fq" "net.core.default_qdisc = fq" "${content}"
    assert_contains "remote uses Google BBR" "net.ipv4.tcp_congestion_control = bbr" "${content}"
    assert_contains "remote bounds receive buffers at 16 MiB" "net.core.rmem_max = 16777216" "${content}"
    assert_contains "remote bounds send buffers at 16 MiB" "net.core.wmem_max = 16777216" "${content}"
    assert_contains "remote tunes TCP receive buffers" "net.ipv4.tcp_rmem = 4096 131072 16777216" "${content}"
    assert_contains "remote tunes TCP send buffers" "net.ipv4.tcp_wmem = 4096 16384 16777216" "${content}"
    assert_contains "remote keeps receive autotuning" "net.ipv4.tcp_moderate_rcvbuf = 1" "${content}"
    assert_contains "remote keeps PMTU probing disabled" "net.ipv4.tcp_mtu_probing = 0" "${content}"
    assert_contains "remote restores idle slow start" "net.ipv4.tcp_slow_start_after_idle = 1" "${content}"
    assert_contains "remote persists the BBR module" "debian-init-bbr.conf" "${content}"
    assert_not_contains "remote does not install XanMod" "dl.xanmod.org" "${content}"
    assert_not_contains "remote does not hardcode application ports" "80 443 8080 8443 8888" "${content}"
    assert_contains "remote reads sshd effective ports" "sshd_bin\" -T" "${content}"
    assert_contains "remote includes explicit extra ports" 'printf '\''%s\n'\'' $extra_tcp_ports' "${content}"
    assert_contains "remote defaults UFW incoming to deny" "ufw default deny incoming" "${content}"
    assert_contains "remote defaults UFW routed to deny" "ufw default deny routed" "${content}"
    assert_contains "remote enables UFW" "ufw --force enable" "${content}"
    assert_contains "remote marks managed UFW rules" "debian-init-managed" "${content}"
    assert_not_contains "remote does not touch firewalld" "firewall-cmd" "${content}"
    assert_not_contains "remote does not touch nftables" "nft insert rule" "${content}"
    assert_contains "remote disables SSH password login" "PasswordAuthentication no" "${content}"
    assert_contains "remote keeps root key-only login policy" "PermitRootLogin prohibit-password" "${content}"
    assert_contains "remote always persists the final SSH port" \
        'echo "Port $final_port"' "${content}"
    assert_contains "remote snapshots old managed rules before adding replacements" \
        'old_rule_numbers="$(managed_ufw_rule_numbers)"' "${content}"
    assert_contains "remote enables SSH at boot" 'systemctl enable --now "$ssh_unit"' "${content}"
    assert_contains "remote verifies SSH boot enablement" 'systemctl is-enabled --quiet "$ssh_unit"' "${content}"
    assert_contains "remote verifies SSH is active" 'systemctl is-active --quiet "$ssh_unit"' "${content}"
}

test_script_surface_contract() {
    local content readme
    content="$(<"${ROOT_DIR}/debian_init.sh")"
    readme="$(<"${ROOT_DIR}/README.md")"

    assert_contains "script intro identifies Debian init" "Debian 服务器初始化与 SSH 密钥登录配置脚本" "${content}"
    assert_contains "prompt distinguishes initial SSH user" "初始 SSH 登录用户" "${content}"
    assert_contains "prompt distinguishes final normal user" "最终 SSH 登录的普通用户名" "${content}"
    assert_contains "default prompt explains the enter default" \
        '[${default}]（直接回车使用默认值）' "${content}"
    assert_contains "prompt asks for explicit extra UFW ports" \
        "UFW 额外放行 TCP 端口" "${content}"
    assert_contains "intro documents Google BBR" \
        "Debian 官方内核 Google BBR/TCP" "${content}"
    assert_not_contains "normal user has no default constant" "DEFAULT_NORMAL_USER" "${content}"
    assert_contains "remote stage failure probes final login" "第 3 步 SSH 连接中断或远端命令返回失败" "${content}"
    assert_contains "remote stage fallback verifies normal user" 'verify_key_login "${NORMAL_USER}@${SERVER_HOST}" "$FINAL_PORT"' "${content}"
    assert_contains "remote stage propagates initialization failures" \
        '"$PUBLIC_KEY" "$EXTRA_TCP_PORTS" \' "${content}"
    assert_contains "local temporary cleanup returns success" "cleanup_local_temp_files" "${content}"
    assert_contains "final ssh_config uses normal user" 'write_ssh_config "$HOST_ALIAS" "$SERVER_HOST" "$NORMAL_USER"' "${content}"
    assert_contains "local steps use normalized print_step" 'print_step "1/5"' "${content}"
    local old_name="init""_server.sh"
    assert_not_contains "script does not mention old filename" "${old_name}" "${content}"
    assert_contains "README labels debian_init as independent" \
        "独立工具：debian_init" "${readme}"
    assert_contains "README says debian_init is not an easy_all prerequisite" \
        '不是 `easy_all` 的组成部分或安装前置步骤' "${readme}"
    assert_contains "README documents explicit extra UFW ports" \
        "用户显式输入的额外 TCP 端口" "${readme}"
}

test_bbr_matches_easy_all() {
    local debian_content reality_content xhttp_content setting
    debian_content="$(<"${ROOT_DIR}/debian_init.sh")"
    reality_content="$(<"${ROOT_DIR}/lib/reality.sh")"
    xhttp_content="$(<"${ROOT_DIR}/lib/xhttp.sh")"
    local -a settings=(
        "net.core.default_qdisc = fq"
        "net.ipv4.tcp_congestion_control = bbr"
        "net.core.rmem_max = 16777216"
        "net.core.wmem_max = 16777216"
        "net.ipv4.tcp_rmem = 4096 131072 16777216"
        "net.ipv4.tcp_wmem = 4096 16384 16777216"
        "net.ipv4.tcp_moderate_rcvbuf = 1"
        "net.ipv4.tcp_mtu_probing = 0"
        "net.ipv4.tcp_slow_start_after_idle = 1"
        "net.core.somaxconn = 4096"
    )
    for setting in "${settings[@]}"; do
        assert_contains "debian_init has shared BBR setting ${setting}" \
            "${setting}" "${debian_content}"
        assert_contains "Reality has shared BBR setting ${setting}" \
            "${setting}" "${reality_content}"
        assert_contains "XHTTP has shared BBR setting ${setting}" \
            "${setting}" "${xhttp_content}"
    done
}

test_validators_and_normalizers
test_collected_ssh_ports
test_managed_ssh_config
test_remote_script_contract
test_script_surface_contract
test_bbr_matches_easy_all

printf 'ok - debian_init shell tests passed (%s assertions)\n' "${TESTS_RUN}"
