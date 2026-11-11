#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
TMP_DIR=$(mktemp -d "${TMP_ROOT_FALLBACK:-/tmp}/easy_all_audit_fixes.XXXXXX")
trap 'rm -rf -- "${TMP_DIR}"' EXIT

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

assert_equal() {
    local label=$1 expected=$2 actual=$3
    [[ "${expected}" == "${actual}" ]] \
        || fail "${label}: expected <${expected}> but got <${actual}>"
}

assert_contains() {
    local label=$1 text=$2 expected=$3
    [[ "${text}" == *"${expected}"* ]] \
        || fail "${label}: missing <${expected}>"
}

assert_not_contains() {
    local label=$1 text=$2 unexpected=$3
    [[ "${text}" != *"${unexpected}"* ]] \
        || fail "${label}: unexpectedly contained <${unexpected}>"
}

# 断言 first 出现在 second 之前（两者都必须存在）
assert_before() {
    local label=$1 text=$2 first=$3 second=$4 prefix
    [[ "${text}" == *"${first}"* ]] || fail "${label}: missing <${first}>"
    [[ "${text}" == *"${second}"* ]] || fail "${label}: missing <${second}>"
    prefix=${text%%"${first}"*}
    [[ "${prefix}" != *"${second}"* ]] \
        || fail "${label}: <${second}> 必须出现在 <${first}> 之后"
}

echo "=== 1. 完全删除所有配额相关内容 ==="
[[ ! -f "${ROOT_DIR}/lib/quota.sh" ]] || fail "lib/quota.sh 仍然存在"
assert_not_contains "manifest" "$(<"${ROOT_DIR}/runtime.manifest")" "lib/quota.sh"

help_output=$(bash "${ROOT_DIR}/easy_all" help 2>&1 || true)
assert_not_contains "help quota-status" "${help_output}" "quota-status"
assert_not_contains "help quota-set" "${help_output}" "quota-set"
assert_not_contains "help quota-reset" "${help_output}" "quota-reset"

echo "=== 2. fail2ban-ufw-cidr 规则去重与 /32 匹配 ==="
export EASY_ALL_FAIL2BAN_UFW_BIN="${TMP_DIR}/mock_ufw.sh"
export UFW_RULES_FILE="${TMP_DIR}/ufw_rules.txt"
: >"${UFW_RULES_FILE}"

cat >"${EASY_ALL_FAIL2BAN_UFW_BIN}" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
cmd="${1:-}"
case "${cmd}" in
    status)
        printf '%s\n\n' 'Status: active'
        printf '%s\n' 'To                         Action      From'
        printf '%s\n' '--                         ------      ----'
        cat "${UFW_RULES_FILE}"
        ;;
    insert)
        network="$5"
        clean_ip="${network%/32}"
        printf 'Anywhere                   DENY IN     %s                    # easy_all-fail2ban-cidr\n' "${clean_ip}" >>"${UFW_RULES_FILE}"
        ;;
    --force)
        if [[ "${2:-}" == "delete" ]]; then
            network="$5"
            clean_ip="${network%/32}"
            grep -v "DENY IN     ${clean_ip} " "${UFW_RULES_FILE}" > "${UFW_RULES_FILE}.tmp" || true
            mv -f "${UFW_RULES_FILE}.tmp" "${UFW_RULES_FILE}"
        fi
        ;;
    *)
        ;;
esac
EOF
chmod +x "${EASY_ALL_FAIL2BAN_UFW_BIN}"

HELPER_BIN="${TMP_DIR}/fail2ban-ufw-cidr.sh"
source "${ROOT_DIR}/lib/log.sh"
source "${ROOT_DIR}/lib/platform.sh"
write_fail2ban_cidr_ufw_helper "${HELPER_BIN}"

# 测试 1: 首次 ban 1.2.3.4
bash "${HELPER_BIN}" ban 1.2.3.4 "${TMP_DIR}/f2b_state"
rule_count_1=$(grep -c "DENY IN     1.2.3.4 " "${UFW_RULES_FILE}" || true)
assert_equal "first ban creates 1 rule" "1" "${rule_count_1}"

# 测试 2: 再次 ban 1.2.3.4 (模拟重复触发或封禁)，规则不应堆叠
bash "${HELPER_BIN}" ban 1.2.3.4 "${TMP_DIR}/f2b_state"
rule_count_2=$(grep -c "DENY IN     1.2.3.4 " "${UFW_RULES_FILE}" || true)
assert_equal "repeated ban does not duplicate rule" "1" "${rule_count_2}"

# 测试 3: 前缀冲突防护，存在 1.2.3.40 时，1.2.3.4 不应误判为已存在
printf 'Anywhere                   DENY IN     1.2.3.40                   # easy_all-fail2ban-cidr\n' >"${UFW_RULES_FILE}"
rm -rf "${TMP_DIR}/f2b_state"
bash "${HELPER_BIN}" ban 1.2.3.4 "${TMP_DIR}/f2b_state"
rule_count_3=$(grep -c "DENY IN     1.2.3.4 " "${UFW_RULES_FILE}" || true)
assert_equal "ban 1.2.3.4 with 1.2.3.40 present creates distinct rule" "1" "${rule_count_3}"

# 测试 4: unban 1.2.3.4
bash "${HELPER_BIN}" unban 1.2.3.4 "${TMP_DIR}/f2b_state"
rule_count_unban=$(grep -c "DENY IN     1.2.3.4 " "${UFW_RULES_FILE}" || true)
assert_equal "unban removes rule" "0" "${rule_count_unban}"

echo "=== 3. CDN 流量保护定时器（替代已删除的 Globalping 选优定时器）==="
mkdir -p "${TMP_DIR}/state" "${TMP_DIR}/runtime" "${TMP_DIR}/systemd"
export STATE_DIR="${TMP_DIR}/state"
export RUNTIME_TMP="${TMP_DIR}/runtime"
export COMMAND_PATH="/usr/local/bin/easy_all"
export CDN_PROVIDER="aws"

mkdir -p "${TMP_DIR}/bin"
cat >"${TMP_DIR}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${TMP_DIR}/bin/systemctl"
PATH="${TMP_DIR}/bin:${PATH}"

# 容器/沙箱都没有 /etc/systemd/system 写权限：这里校验计时器单元的真实配置来源，
# 以及驱动它的是同一条 cdn-traffic-sync 命令（不是已删除的 Globalping 刷新命令）。
guard_content=$(<"${ROOT_DIR}/lib/cdn-traffic-guard.sh")
assert_contains "guard timer OnBootSec=15s" "${guard_content}" "OnBootSec=15s"
assert_contains "guard timer OnUnitActiveSec=15s" "${guard_content}" "OnUnitActiveSec=15s"
assert_contains "guard timer AccuracySec=1s" "${guard_content}" "AccuracySec=1s"
assert_contains "guard ExecStart 复用命令路径" "${guard_content}" \
    'ExecStart=${COMMAND_PATH} $(cdn_traffic_sync_command)'
sync_command=$( (
    source "${ROOT_DIR}/lib/cdn-traffic-guard.sh"
    cdn_traffic_sync_command
) )
assert_equal "计时器驱动 cdn-traffic-sync" "cdn-traffic-sync" "${sync_command}"
# 计量 epoch 必须稳定且不伪造：缺 /proc/sys/kernel/random/boot_id 时不得回退成时间戳
# （每轮换 epoch 会让增量恒为 0，985GB 保护永不触发）。
boot_id_fixture="${TMP_DIR}/boot_id"
printf '%s\n' 'boot-fixture-1234' >"${boot_id_fixture}"
epoch_calls=$(
    (
        EASY_ALL_BOOT_ID_FILE_OVERRIDE="${boot_id_fixture}" \
            bash -c 'source "$1"; cdn_traffic_epoch_id; cdn_traffic_epoch_id' _ \
            "${ROOT_DIR}/lib/cdn-traffic-guard.sh"
    )
)
assert_equal "epoch 在同一开机内稳定（不每轮取新值）" "1" \
    "$(printf '%s\n' "${epoch_calls}" | sort -u | awk 'END {print NR}')"
assert_contains "epoch 取自 boot_id" "${epoch_calls}" "boot-fixture-1234"
epoch_missing=$(
    (
        EASY_ALL_BOOT_ID_FILE_OVERRIDE="${TMP_DIR}/no-such-boot-id" \
            bash -c 'source "$1"; if cdn_traffic_epoch_id; then printf returned; else printf failed; fi' _ \
            "${ROOT_DIR}/lib/cdn-traffic-guard.sh"
    )
)
assert_equal "boot_id 缺失时判定失败，不回退时间戳" "failed" "${epoch_missing}"
assert_not_contains "旧 Globalping 选优定时器已删除" "${guard_content}" "globalping"
[[ ! -e "${ROOT_DIR}/lib/globalping-cdn.sh" ]] || fail "lib/globalping-cdn.sh 必须删除"
# 旧 Globalping 链路属于已删除的旧栈：新版本不接管 schema 0，也不保留兼容清理分支。
assert_not_contains "帮助不再暴露 Globalping 刷新命令" \
    "${help_output:-}" "refresh-cdn-ips"
assert_not_contains "卸载流程不再包含旧 Globalping 兼容分支" \
    "$(awk '/^cdn_local_uninstall_common\(\)/,/^}/' "${ROOT_DIR}/lib/cloudfront-mode.sh")" \
    "globalping"

echo "=== 4. 新链路 Cloudflare Token 最小权限与 AWS 凭据仅内存 ==="
core_content=$(<"${ROOT_DIR}/lib/cloudfront-mode.sh")
shared_dns_content=$(<"${ROOT_DIR}/lib/cf-dns.sh")
# Token 收集与 0600 落盘是五模式共用的单一实现：模式 4/5 只沿用默认的 Zone 只读 + DNS 编辑。
assert_contains "shared token prompt defaults to zone read + DNS edit" \
    "${shared_dns_content}" 'Cloudflare API Token（Zone 只读 + DNS 编辑）'
assert_contains "token persistence lives in the shared library" \
    "${shared_dns_content}" "persist_cloudflare_token()"
assert_not_contains "cloudfront core does not reimplement the token prompt" \
    "${core_content}" "prompt_secret 'Cloudflare API Token"
assert_contains "AWS 凭据只在当前进程使用" "${core_content}" "仅限当前进程使用，不落盘"
assert_not_contains "不再要求 SSL/证书编辑权限" "${core_content}" "SSL/证书 编辑权限"
assert_contains "thin cloudfront profile delegates inputs to the shared core" \
    "$(<"${ROOT_DIR}/profiles/cloudfront.sh")" "collect_cloudfront_install_inputs"

echo "=== 5. 移除遗留死变量 PARAMS_SOURCE 与 INSTALL_PARAMS_DELETE ==="
common_content=$(<"${ROOT_DIR}/lib/profile-common.sh")
assert_not_contains "PARAMS_SOURCE removed" "${common_content}" "PARAMS_SOURCE"
assert_not_contains "INSTALL_PARAMS_DELETE removed" "${common_content}" "INSTALL_PARAMS_DELETE"

echo "=== 6. 验证 Debian 12/13 与 Ubuntu 22.04/24.04/26.04 LTS 及 amd64 / arm64 平台支持 ==="
TEST_OS_RELEASE="${TMP_DIR}/os-release"
TEST_BIN_DIR="${TMP_DIR}/platform_bin"
mkdir -p "${TEST_BIN_DIR}"

run_check_platform_test() {
    local id=$1 version_id=$2 codename=$3 arch=$4 omit_version=${5:-}
    if [[ "${omit_version}" == "noversion" ]]; then
        cat >"${TEST_OS_RELEASE}" <<EOF
ID=${id}
VERSION_CODENAME=${codename}
EOF
    else
        cat >"${TEST_OS_RELEASE}" <<EOF
ID=${id}
VERSION_ID="${version_id}"
VERSION_CODENAME=${codename}
EOF
    fi
    cat >"${TEST_BIN_DIR}/dpkg" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "--print-architecture" ]]; then
    printf '%s\n' "${MOCK_ARCH:-amd64}"
    exit 0
fi
if [[ "$1" == "--compare-versions" ]]; then
    python3 -c '
import sys
v1 = [int(x) for x in sys.argv[1].split(".") if x.isdigit()]
v2 = [int(x) for x in sys.argv[3].split(".") if x.isdigit()]
op = sys.argv[2]
if op == "ge":
    sys.exit(0 if v1 >= v2 else 1)
elif op == "lt":
    sys.exit(0 if v1 < v2 else 1)
elif op == "gt":
    sys.exit(0 if v1 > v2 else 1)
elif op == "le":
    sys.exit(0 if v1 <= v2 else 1)
sys.exit(0)
' "$2" "$3" "$4"
    exit $?
fi
exit 0
EOF
    chmod +x "${TEST_BIN_DIR}/dpkg"
    cat >"${TEST_BIN_DIR}/systemd-detect-virt" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${TEST_BIN_DIR}/systemd-detect-virt"

    PATH="${TEST_BIN_DIR}:${PATH}" MOCK_ARCH="${arch}" EASY_ALL_OS_RELEASE_FILE="${TEST_OS_RELEASE}" bash -c "
        source '${ROOT_DIR}/lib/log.sh'
        source '${ROOT_DIR}/lib/platform.sh'
        check_platform
    " 2>&1
}

# 6.1 验证合法组合均通过
res_deb12_amd64=$(run_check_platform_test "debian" "12" "bookworm" "amd64" || true)
assert_equal "Debian 12 amd64 must pass" "" "${res_deb12_amd64}"

res_deb13_arm64=$(run_check_platform_test "debian" "13" "trixie" "arm64" || true)
assert_equal "Debian 13 arm64 must pass" "" "${res_deb13_arm64}"

res_u22_amd64=$(run_check_platform_test "ubuntu" "22.04" "jammy" "amd64" || true)
assert_equal "Ubuntu 22.04 amd64 must pass" "" "${res_u22_amd64}"

res_u24_arm64=$(run_check_platform_test "ubuntu" "24.04" "noble" "arm64" || true)
assert_equal "Ubuntu 24.04 arm64 must pass" "" "${res_u24_arm64}"

res_u2604_amd64=$(run_check_platform_test "ubuntu" "26.04" "resolute" "amd64" || true)
assert_equal "Ubuntu 26.04 amd64 must pass" "" "${res_u2604_amd64}"

# 6.2 验证非法系统或架构被拦截
res_u20=$(run_check_platform_test "ubuntu" "20.04" "focal" "amd64" || true)
assert_contains "Ubuntu 20.04 rejected" "${res_u20}" "不支持当前 Ubuntu 版本/代号"

res_u2410=$(run_check_platform_test "ubuntu" "24.10" "oracular" "amd64" || true)
assert_contains "Ubuntu 24.10 non-LTS rejected" "${res_u2410}" "不支持当前 Ubuntu 版本/代号"

res_deb11=$(run_check_platform_test "debian" "11" "bullseye" "amd64" || true)
assert_contains "Debian 11 rejected" "${res_deb11}" "不支持当前 Debian 版本/代号"

res_debsid=$(run_check_platform_test "debian" "14" "forky" "amd64" || true)
assert_contains "Debian testing/sid rejected" "${res_debsid}" "不支持当前 Debian 版本/代号"

res_debsid_noversion=$(run_check_platform_test "debian" "" "sid" "amd64" "noversion" || true)
assert_contains "Debian sid (no VERSION_ID) rejected" "${res_debsid_noversion}" "不支持当前 Debian 版本/代号"

res_focal_noversion=$(run_check_platform_test "ubuntu" "" "focal" "amd64" "noversion" || true)
assert_contains "Ubuntu focal (no VERSION_ID) rejected" "${res_focal_noversion}" "不支持当前 Ubuntu 版本/代号"

res_deb_mismatch=$(run_check_platform_test "debian" "12" "trixie" "amd64" || true)
assert_contains "Debian version/codename mismatch rejected" "${res_deb_mismatch}" "系统版本信息不一致"

res_ubuntu_mismatch=$(run_check_platform_test "ubuntu" "22.04" "noble" "amd64" || true)
assert_contains "Ubuntu version/codename mismatch rejected" "${res_ubuntu_mismatch}" "系统版本信息不一致"

res_resolute_mismatch=$(run_check_platform_test "ubuntu" "24.04" "resolute" "amd64" || true)
assert_contains "Ubuntu 26.04 codename with 24.04 VERSION_ID rejected" "${res_resolute_mismatch}" "系统版本信息不一致"

res_bookworm_deb11=$(run_check_platform_test "debian" "11" "bookworm" "amd64" || true)
assert_contains "Debian 11 with bookworm codename rejected" "${res_bookworm_deb11}" "系统版本信息不一致"

res_bookworm_noversion=$(run_check_platform_test "debian" "" "bookworm" "amd64" "noversion" || true)
assert_contains "Debian bookworm (no VERSION_ID) rejected" "${res_bookworm_noversion}" "系统版本信息缺失"

res_noble_noversion=$(run_check_platform_test "ubuntu" "" "noble" "amd64" "noversion" || true)
assert_contains "Ubuntu noble (no VERSION_ID) rejected" "${res_noble_noversion}" "系统版本信息缺失"

res_cross_family_debian=$(run_check_platform_test "debian" "22.04" "jammy" "amd64" || true)
assert_contains "Ubuntu codename under Debian rejected" "${res_cross_family_debian}" "不支持当前 Debian 版本/代号"

res_cross_family_ubuntu=$(run_check_platform_test "ubuntu" "12" "bookworm" "amd64" || true)
assert_contains "Debian codename under Ubuntu rejected" "${res_cross_family_ubuntu}" "不支持当前 Ubuntu 版本/代号"

res_centos=$(run_check_platform_test "centos" "9" "stream" "amd64" || true)
assert_contains "CentOS rejected" "${res_centos}" "仅支持 Debian 12+ 或 Ubuntu 22.04+"

res_arch_mips=$(run_check_platform_test "debian" "12" "bookworm" "mips64el" || true)
assert_contains "Unsupported arch rejected" "${res_arch_mips}" "仅支持 amd64 与 arm64"

# 6.3 验证 Zabbly 仓库配置与 Skyline 逻辑
source "${ROOT_DIR}/lib/tcp-tuning.sh"
assert_equal "Zabbly kernel package name" "linux-zabbly" "${ZABBLY_KERNEL_PACKAGE}"
assert_equal "Zabbly key fingerprint" "4EFC590696CB15B87C73A3AD82CC8797C838DCFD" "${ZABBLY_KEY_FINGERPRINT}"
assert_equal "TCP sysctl 文件不再使用 BBR 命名" "99-easy_all-tcp.conf" "${TCP_SYSCTL_CONF##*/}"

# 6.3b TCP 调优文件按模式派生：直连写 tcp_no_metrics_save，CDN 模式不写
# （回归：残留的 reality 判断使直连模式漏写该参数）。sysctl/ip/tc/systemctl 是外部边界，用替身。
TCP_STUB_DIR="${TMP_DIR}/tcp-stub"
mkdir -p "${TCP_STUB_DIR}"
printf '#!/usr/bin/env bash\nexit 0\n' >"${TCP_STUB_DIR}/sysctl"
printf '#!/usr/bin/env bash\nexit 0\n' >"${TCP_STUB_DIR}/systemctl"
cat >"${TCP_STUB_DIR}/ip" <<'FAKE_IP'
#!/usr/bin/env bash
printf 'default via 203.0.113.1 dev eth0\n'
FAKE_IP
cat >"${TCP_STUB_DIR}/tc" <<'FAKE_TC'
#!/usr/bin/env bash
case "$*" in
*'filter show'*) printf '[]\n' ;;
*) printf '[{"kind":"fq","handle":"0:","root":true}]\n' ;;
esac
FAKE_TC
chmod 0755 "${TCP_STUB_DIR}"/*
tcp_tuning_case() { # $1=PROTOCOL $2=CDN_PROVIDER -> 输出生成的 sysctl 文件
    PATH="${TCP_STUB_DIR}:${PATH}" \
    STATE_DIR="${TMP_DIR}/tcp-state-$1${2:-}" \
    TCP_SYSCTL_CONF_OVERRIDE="${TMP_DIR}/tcp-state-$1${2:-}/99-easy_all-tcp.conf" \
    EASY_ALL_TCP_DIR_OVERRIDE="${TMP_DIR}/tcp-helper-$1${2:-}" \
    SYSTEMD_SYSTEM_DIR="${TMP_DIR}/tcp-systemd-$1${2:-}" \
    RUNTIME_TMP="${TMP_DIR}/tcp-runtime-$1${2:-}" \
    BACKUP_DIR="${TMP_DIR}/tcp-backup-$1${2:-}" \
        bash -c '
            source "$1/lib/log.sh"
            source "$1/lib/network.sh"
            source "$1/lib/tcp-tuning.sh"
            PROTOCOL=$2
            CDN_PROVIDER=$3
            install -d -m 0700 "${RUNTIME_TMP}" "${BACKUP_DIR}" \
                "${TCP_SYSCTL_CONF%/*}" "${SYSTEMD_SYSTEM_DIR}"
            configure_tcp_parameters >/dev/null
            cat "${TCP_SYSCTL_CONF}"
        ' _ "${ROOT_DIR}" "$1" "${2:-}" || fail "TCP 调优失败（$1 ${2:-无 CDN}）"
}
direct_tuning=$(tcp_tuning_case anytls)
assert_contains "模式 1 写入 tcp_no_metrics_save" "${direct_tuning}" \
    "net.ipv4.tcp_no_metrics_save = 1"
cdn_tuning=$(tcp_tuning_case combined-cloudfront aws)
assert_not_contains "模式 5 不写 tcp_no_metrics_save" "${cdn_tuning}" "tcp_no_metrics_save"
assert_contains "所有模式都保留 fq 与缓冲区调优" "${cdn_tuning}" "net.core.default_qdisc = fq"

# 6.4 UFW SSH 端口策略：必须校验真实端口，而不是回落的 22（回归：非 22 端口时初始化中断）
UFW_FAKE_BIN="${TMP_DIR}/ufw-fake"
mkdir -p "${UFW_FAKE_BIN}"
cat >"${UFW_FAKE_BIN}/ufw" <<'FAKE_UFW'
#!/usr/bin/env bash
set -Eeuo pipefail
rules="${FAKE_UFW_RULES:?}"
touch "${rules}"
render_numbered() {
    local index=0 port source
    printf '%s\n\n%s\n%s\n' 'Status: active' 'To                         Action      From' \
        '--                         ------      ----'
    while IFS=$'\t' read -r port source; do
        [[ -n "${port}" ]] || continue
        index=$((index + 1))
        printf '[%2d] %s/tcp                   ALLOW IN    %s                   # easy_all-managed\n' \
            "${index}" "${port}" "${source}"
    done <"${rules}"
}
case "${1:-}" in
status)
    if [[ "${2:-}" == "numbered" ]]; then render_numbered; else printf '%s\n' 'Status: active'; fi
    ;;
show) printf '%s\n' '# persisted rules' ;;
allow)
    port=${2:-}
    printf '%s\t%s\n' "${port%/tcp}" 'Anywhere' >>"${rules}"
    ;;
--force)
    # 既支持按编号删（历史夹具行为），也支持删除完整规则规格（spec-delete）。
    if [[ "${2:-}" == "delete" ]]; then
        if [[ "${3:-}" =~ ^[0-9]+$ ]]; then
            awk -v drop="${3}" 'NR != drop' "${rules}" >"${rules}.tmp"
            mv -f "${rules}.tmp" "${rules}"
            exit 0
        fi
        shift 2
        spec_port="" spec_source="Anywhere"
        while (($#)); do
            case "$1" in
            comment) shift 2 ;;
            from) spec_source=$2; shift 2 ;;
            proto | to) shift 2 ;;
            any) shift ;;
            port) shift ;;
            *) spec_port=${1%/tcp}; shift ;;
            esac
        done
        [[ -n "${spec_port}" ]] || exit 0
        awk -v port="${spec_port}" -v source="${spec_source}" '
            BEGIN { FS = "\t"; deleted = 0 }
            !deleted && $1 == port && $2 == source { deleted = 1; next }
            { print }
        ' "${rules}" >"${rules}.tmp"
        mv -f "${rules}.tmp" "${rules}"
    fi
    ;;
esac
exit 0
FAKE_UFW
chmod +x "${UFW_FAKE_BIN}/ufw"

# 非 22 端口：两参数（真实 SSH 端口）必须成功且放行该端口
UFW_RULES_TWO_ARGS="${TMP_DIR}/ufw_rules_two_args.tsv"
: >"${UFW_RULES_TWO_ARGS}"
PATH="${UFW_FAKE_BIN}:${PATH}" FAKE_UFW_RULES="${UFW_RULES_TWO_ARGS}" SSH_PORTS="2222" \
    bash -c 'source "$1"; source "$2"; apply_ssh_ufw_policy "2222" "2222"' \
    _ "${ROOT_DIR}/lib/log.sh" "${ROOT_DIR}/lib/firewall.sh" \
    || fail "apply_ssh_ufw_policy must accept a non-22 SSH port"
grep -qx $'2222\tAnywhere' "${UFW_RULES_TWO_ARGS}" \
    || fail "UFW must allow the real SSH port 2222"

# 一参数在未检测到 SSH 端口时回落到 22；用它放行 2222 必须失败（旧 debian-init 写法）
UFW_RULES_ONE_ARG="${TMP_DIR}/ufw_rules_one_arg.tsv"
: >"${UFW_RULES_ONE_ARG}"
if PATH="${UFW_FAKE_BIN}:${PATH}" FAKE_UFW_RULES="${UFW_RULES_ONE_ARG}" SSH_PORTS="" \
    bash -c 'source "$1"; source "$2"; apply_ssh_ufw_policy "2222"' \
    _ "${ROOT_DIR}/lib/log.sh" "${ROOT_DIR}/lib/firewall.sh" >/dev/null 2>&1; then
    fail "single-argument apply_ssh_ufw_policy must fail when SSH ports are undetected"
fi

# 远端脚本跑在 root + 真实 apt/sshd 环境，无法在用例内执行；只钉住调用形态（两个参数）。
assert_contains "debian-init passes the real SSH port to UFW policy" \
    "$(<"${ROOT_DIR}/scripts/debian-init.sh")" 'apply_ssh_ufw_policy "$ports" "$final_port"'

# 远端脚本要 source lib/platform.sh 与 lib/firewall.sh（共 22 处 warn 调用），但它自己
# 不是从 lib/log.sh 起的运行时：缺 warn 时 set -e 下 warn: command not found 会中断初始化。
debian_init_content=$(<"${ROOT_DIR}/scripts/debian-init.sh")
remote_script_body=$(printf '%s\n' "${debian_init_content}" \
    | awk '/<<.REMOTE./ {inside = 1; next} inside && /^REMOTE$/ {exit} inside {print}')
[[ -n "${remote_script_body}" ]] || fail "无法提取 debian-init 的远端子脚本"
assert_contains "远端脚本自带 warn 实现" "${remote_script_body}" 'warn() {'
assert_before "warn 必须早于 source lib/firewall.sh 定义" "${remote_script_body}" \
    'warn() {' 'source "$firewall_module"'
assert_before "warn 必须早于 source lib/platform.sh 定义" "${remote_script_body}" \
    'warn() {' 'source "$platform_module"'

# ssh-copy-id 没给 host key 策略时，全新 VPS 首次连接会停在指纹提示（非交互下直接失败）。
copy_public_key_body=$(printf '%s\n' "${debian_init_content}" \
    | awk '/^copy_public_key\(\)/ {inside = 1} inside {print} inside && /^}$/ {exit}')
assert_equal "copy_public_key 两个分支都带 StrictHostKeyChecking=accept-new" "2" \
    "$(grep -c 'StrictHostKeyChecking=accept-new' <<<"${copy_public_key_body}" || true)"

# 6.5 远端 mktemp 目录的捕获要先规范化再做严格正则校验：部分镜像会把 MOTD/rc 输出混进
# 命令 stdout，多行结果会让旧写法直接判非法并中断初始化。只看行序，不做整文件 hash 比对。
# 字面量本身含 $'\n' / $'\r'，用 \$ / \\ 转义构造（bash 3.2 的 $(...) 内 heredoc 不可靠）。
newline_trim_literal="remote_dir=\${remote_dir##*\$'\\n'}"
cr_trim_literal="remote_dir=\${remote_dir%\$'\\r'}"
line_of() { # $1=字面量 -> 首次出现的行号（无匹配输出空）
    grep -nF -- "$1" "${ROOT_DIR}/scripts/debian-init.sh" | head -n 1 | cut -d: -f1 || true
}
normalize_line=$(line_of "${newline_trim_literal}")
cr_trim_line=$(line_of "${cr_trim_literal}")
validate_line=$(line_of '"$remote_dir" =~ ^/tmp/easy_all_init')
[[ -n "${normalize_line}" ]] || fail "debian-init 缺少远端临时目录的换行规范化"
[[ -n "${cr_trim_line}" ]] || fail "debian-init 缺少远端临时目录的 CR 规范化"
[[ -n "${validate_line}" ]] || fail "debian-init 缺少远端临时目录的严格正则校验"
((normalize_line < validate_line)) \
    || fail "换行规范化（第 ${normalize_line} 行）必须早于正则校验（第 ${validate_line} 行）"
((cr_trim_line < validate_line)) \
    || fail "CR 规范化（第 ${cr_trim_line} 行）必须早于正则校验（第 ${validate_line} 行）"
# 行为断言：两步展开本身就是规范化，MOTD/CR 混入 stdout 时也要取出目录。
raw=$'Welcome to Ubuntu\r\nLast login: x\r\n/tmp/easy_all_init.abc12345\r'
remote_dir=${raw##*$'\n'}
remote_dir=${remote_dir%$'\r'}
assert_equal "MOTD 与 CR 混入 stdout 后仍取出远端目录" \
    "/tmp/easy_all_init.abc12345" "${remote_dir}"

echo "=== 7. 系统依赖与五模式运行时入口 ==="
# 依赖清单只在共享运行时定义一次：sudo/vim 与 DNS-01 所需包都必须在这里。
package_list_of() {
    awk '/local pkgs=\(/{flag=1; next} flag && /^[[:space:]]*\)/{exit} flag' "$1"
}
runtime_pkgs=$(package_list_of "${ROOT_DIR}/lib/runtime-core.sh")
assert_contains "runtime-core pkgs contain sudo" "${runtime_pkgs}" "sudo"
assert_contains "runtime-core pkgs contain vim" "${runtime_pkgs}" "vim"
assert_contains "runtime-core pkgs contain certbot" "${runtime_pkgs}" "certbot"
assert_contains "runtime-core pkgs contain the Cloudflare DNS-01 plugin" \
    "${runtime_pkgs}" "python3-certbot-dns-cloudflare"
assert_contains "runtime-core pkgs contain iptables (mangle metering)" "${runtime_pkgs}" "iptables"
assert_not_contains "旧栈的 xhttp 运行时已删除" \
    "$(ls "${ROOT_DIR}/lib")" "xhttp-runtime.sh"
assert_not_contains "旧栈的 Xray 核心已删除" "$(ls "${ROOT_DIR}/lib")" "xray-core.sh"

echo "=== 8. 订阅鉴权由 Caddy 精确匹配承担（不再生成 Nginx 路由） ==="
auth_content=$(<"${ROOT_DIR}/lib/subscription-auth.sh")
assert_not_contains "不再生成 nginx map" "${auth_content}" "write_subscription_nginx_maps"
assert_not_contains "不再生成 nginx location" "${auth_content}" "write_subscription_nginx_locations"
caddy_runtime=$(<"${ROOT_DIR}/lib/caddy-runtime.sh")
assert_contains "订阅入口精确匹配 /subscribe /sub" "${caddy_runtime}" \
    "@easy_all_sub path /subscribe /sub"
assert_contains "公共头先于任何终止响应" "${caddy_runtime}" 'header Vary "User-Agent"'
assert_contains "Token 用精确列表比较而非正则" "${caddy_runtime}" 'expression !({query.token} in'

echo "=== 9. 状态 schema 门禁：只接受 schema 1，旧版本必须先用旧版本卸载 ==="
state_content=$(<"${ROOT_DIR}/lib/state.sh")
assert_contains "STATE_VERSION 固定为 1" "${state_content}" 'EASY_ALL_STATE_SCHEMA_VERSION="1"'
launcher_content=$(<"${ROOT_DIR}/easy_all")
assert_contains "launcher 使用 schema 1" "${launcher_content}" 'CURRENT_STATE_VERSION="1"'
assert_contains "launcher 拒绝旧 schema" "${launcher_content}" "state_legacy_rejection_message"
assert_not_contains "launcher 不再有旧 Cloudflare 迁移分支" \
    "${launcher_content}" "launcher_marker_is_legacy_cloudflare"

echo "ok - all audit fixes verified successfully"
