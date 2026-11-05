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

echo "=== 3. Globalping 选优定时器修改为 3 小时 ==="
mkdir -p "${TMP_DIR}/state" "${TMP_DIR}/runtime" "${TMP_DIR}/systemd"
export STATE_DIR="${TMP_DIR}/state"
export RUNTIME_TMP="${TMP_DIR}/runtime"
export COMMAND_PATH="/usr/local/bin/easy_all"
export GLOBALPING_REFRESH_SERVICE_FILE_OVERRIDE="${TMP_DIR}/systemd/easy_all-globalping-refresh.service"
export GLOBALPING_REFRESH_TIMER_FILE_OVERRIDE="${TMP_DIR}/systemd/easy_all-globalping-refresh.timer"
export CDN_PROVIDER="cloudflare"

mkdir -p "${TMP_DIR}/bin"
cat >"${TMP_DIR}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${TMP_DIR}/bin/systemctl"
PATH="${TMP_DIR}/bin:${PATH}"

source "${ROOT_DIR}/lib/globalping-cdn.sh"
install_globalping_refresh_timer
timer_content=$(<"${GLOBALPING_REFRESH_TIMER_FILE_OVERRIDE}")
assert_contains "timer OnActiveSec=3h" "${timer_content}" "OnActiveSec=3h"
assert_contains "timer OnUnitActiveSec=3h" "${timer_content}" "OnUnitActiveSec=3h"
assert_contains "timer Description 3 hours" "${timer_content}" "Description=Refresh easy_all CDN endpoints every three hours"

echo "=== 4. 组合模式 Cloudflare API Token 提示文案与权限要求 ==="
combined_content=$(<"${ROOT_DIR}/profiles/combined.sh")
assert_contains "combined token prompt" "${combined_content}" "Cloudflare API Token（仅限 DNS 编辑权限；将保存到 root 受控文件以支持后续定时与免交互运维）"

echo "=== 5. 移除遗留死变量 PARAMS_SOURCE 与 INSTALL_PARAMS_DELETE ==="
common_content=$(<"${ROOT_DIR}/lib/profile-common.sh")
assert_not_contains "PARAMS_SOURCE removed" "${common_content}" "PARAMS_SOURCE"
assert_not_contains "INSTALL_PARAMS_DELETE removed" "${common_content}" "INSTALL_PARAMS_DELETE"

echo "=== 6. 验证 Debian 12+ / Ubuntu 22.04+ 及 amd64 / arm64 平台支持 ==="
TEST_OS_RELEASE="${TMP_DIR}/os-release"
TEST_BIN_DIR="${TMP_DIR}/platform_bin"
mkdir -p "${TEST_BIN_DIR}"

run_check_platform_test() {
    local id=$1 version_id=$2 codename=$3 arch=$4
    cat >"${TEST_OS_RELEASE}" <<EOF
ID=${id}
VERSION_ID="${version_id}"
VERSION_CODENAME=${codename}
EOF
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

# 6.2 验证非法系统或架构被拦截
res_u20=$(run_check_platform_test "ubuntu" "20.04" "focal" "amd64" || true)
assert_contains "Ubuntu 20.04 rejected" "${res_u20}" "不支持当前 Ubuntu 版本/代号"

res_u2410=$(run_check_platform_test "ubuntu" "24.10" "oracular" "amd64" || true)
assert_contains "Ubuntu 24.10 non-LTS rejected" "${res_u2410}" "不支持当前 Ubuntu 版本/代号"

res_deb11=$(run_check_platform_test "debian" "11" "bullseye" "amd64" || true)
assert_contains "Debian 11 rejected" "${res_deb11}" "不支持当前 Debian 版本/代号"

res_debsid=$(run_check_platform_test "debian" "14" "forky" "amd64" || true)
assert_contains "Debian testing/sid rejected" "${res_debsid}" "不支持当前 Debian 版本/代号"

res_centos=$(run_check_platform_test "centos" "9" "stream" "amd64" || true)
assert_contains "CentOS rejected" "${res_centos}" "仅支持 Debian 12+ 或 Ubuntu 22.04+"

res_arch_mips=$(run_check_platform_test "debian" "12" "bookworm" "mips64el" || true)
assert_contains "Unsupported arch rejected" "${res_arch_mips}" "仅支持 amd64 与 arm64"

# 6.3 验证 Zabbly 仓库配置与 Skyline 逻辑
source "${ROOT_DIR}/lib/tcp-tuning.sh"
assert_equal "Zabbly kernel package name" "linux-zabbly" "${ZABBLY_KERNEL_PACKAGE}"
assert_equal "Zabbly key fingerprint" "4EFC590696CB15B87C73A3AD82CC8797C838DCFD" "${ZABBLY_KEY_FINGERPRINT}"
assert_equal "TCP sysctl 文件不再使用 BBR 命名" "99-easy_all-tcp.conf" "${TCP_SYSCTL_CONF##*/}"

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
    if [[ "${2:-}" == "delete" && "${3:-}" =~ ^[0-9]+$ ]]; then
        awk -v drop="${3}" 'NR != drop' "${rules}" >"${rules}.tmp"
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

echo "=== 7. 验证 Swap 自动创建与 sudo vim 依赖安装 ==="
# 7.1 验证各模式的 apt 依赖清单包含 sudo 和 vim（只看 pkgs 数组，避免注释误命中）
package_list_of() {
    awk '/local pkgs=\(/{flag=1; next} flag && /^[[:space:]]*\)/{exit} flag' "$1"
}
for script in lib/xhttp-runtime.sh profiles/reality.sh profiles/ws-bunny.sh; do
    pkg_text=$(package_list_of "${ROOT_DIR}/${script}")
    assert_contains "${script} pkgs contain sudo" "${pkg_text}" "sudo"
    assert_contains "${script} pkgs contain vim" "${pkg_text}" "vim"
done

# 7.2 验证 ensure_swap：已有 Swap 时不操作
TEST_MEMINFO_EXISTING="${TMP_DIR}/meminfo_existing"
cat >"${TEST_MEMINFO_EXISTING}" <<'EOF'
MemTotal:        2048000 kB
SwapTotal:       1048576 kB
EOF
export EASY_ALL_MEMINFO_FILE="${TEST_MEMINFO_EXISTING}"
export EASY_ALL_SWAP_FILE="${TMP_DIR}/test_swap_file"
export EASY_ALL_FSTAB_FILE="${TMP_DIR}/test_fstab"
: >"${EASY_ALL_FSTAB_FILE}"
rm -f -- "${EASY_ALL_SWAP_FILE}"

source "${ROOT_DIR}/lib/platform.sh"
ensure_swap
[[ ! -f "${EASY_ALL_SWAP_FILE}" ]] || fail "已有 Swap 时不应创建 swapfile"
assert_equal "fstab remains empty when swap exists" "" "$(<"${EASY_ALL_FSTAB_FILE}")"

# 7.3 验证 ensure_swap：无 Swap 时自动创建并写入 fstab
TEST_MEMINFO_NONE="${TMP_DIR}/meminfo_none"
cat >"${TEST_MEMINFO_NONE}" <<'EOF'
MemTotal:        2048000 kB
SwapTotal:             0 kB
EOF
export EASY_ALL_MEMINFO_FILE="${TEST_MEMINFO_NONE}"
# 创建假 mkswap / swapon
MOCK_SWAP_BIN="${TMP_DIR}/swap_bin"
mkdir -p "${MOCK_SWAP_BIN}"
cat >"${MOCK_SWAP_BIN}/mkswap" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"${MOCK_SWAP_BIN}/swapon" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"${MOCK_SWAP_BIN}/fallocate" <<'EOF'
#!/usr/bin/env bash
# 模拟 fallocate 快速创建 1GB 稀疏测试文件
truncate -s 10M "$3" 2>/dev/null || dd if=/dev/zero of="$3" bs=1M count=1 status=none
exit 0
EOF
chmod +x "${MOCK_SWAP_BIN}/mkswap" "${MOCK_SWAP_BIN}/swapon" "${MOCK_SWAP_BIN}/fallocate"

PATH="${MOCK_SWAP_BIN}:${PATH}" ensure_swap
[[ -f "${EASY_ALL_SWAP_FILE}" ]] || fail "无 Swap 时应创建 swapfile"
assert_contains "fstab written with swapfile" "$(<"${EASY_ALL_FSTAB_FILE}")" "${EASY_ALL_SWAP_FILE} none swap sw 0 0"

echo "=== 8. 验证前置初始化幂等跳过与回滚保护 ==="
# 8.1 验证 packages_already_installed
MOCK_DPKG_DIR="${TMP_DIR}/mock_dpkg_bin"
mkdir -p "${MOCK_DPKG_DIR}"
cat >"${MOCK_DPKG_DIR}/dpkg" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "--print-architecture" ]]; then
    echo "amd64"
    exit 0
fi
if [[ "$1" == "-s" ]]; then
    if [[ "$2" == "missing_pkg" ]]; then
        echo "dpkg-query: package 'missing_pkg' is not installed" >&2
        exit 1
    fi
    echo "Package: $2"
    echo "Status: install ok installed"
    exit 0
fi
exit 0
EOF
chmod +x "${MOCK_DPKG_DIR}/dpkg"
export PATH="${MOCK_DPKG_DIR}:${PATH}"

packages_already_installed "sudo" "vim" "curl" || fail "已安装包列表应返回 0"
if packages_already_installed "sudo" "missing_pkg"; then
    fail "含未安装包列表应返回 1"
fi

# 8.2 验证 Skyline 已激活时 configure_tcp_acceleration 刷新 TCP 参数并维持运行
(
    rm -f -- "${TMP_DIR}/tcp_param_called"
    configure_tcp_parameters() { touch "${TMP_DIR}/tcp_param_called"; }
    skyline_speeder_active() { return 0; }
    SYSTEMD_SYSTEM_DIR="${TMP_DIR}/mock_systemd"
    EASY_ALL_TCP_DIR_OVERRIDE="${TMP_DIR}/mock_tcp_dir"
    mkdir -p "${SYSTEMD_SYSTEM_DIR}" "${EASY_ALL_TCP_DIR_OVERRIDE}"
    touch "${SYSTEMD_SYSTEM_DIR}/easy_all-fq.service"
    touch "${EASY_ALL_TCP_DIR_OVERRIDE}/apply-fq.sh"
    skip_out=$(configure_tcp_acceleration 2>&1 || true)
    [[ -f "${TMP_DIR}/tcp_param_called" ]] || fail "Skyline 运行时应刷新 TCP 参数"
    assert_contains "Skyline active logged" "${skip_out}" "Skyline Speeder 已在运行"
)

# 8.4 验证 show_tcp_acceleration_status 纯净输出 Skyline Speeder 状态
(
    skyline_speeder_active() { return 0; }
    status_out=$(show_tcp_acceleration_status 2>&1 || true)
    assert_contains "status reports Skyline" "${status_out}" "Skyline Speeder: active"
    assert_not_contains "status does not mention BBR" "${status_out}" "BBR"
)

# 8.5 前置初始化（TCP 加速/Skyline）不再由卸载处理，相关函数一并移除
(
    assert_not_contains "no uninstall_tcp_acceleration symbol" \
        "$(declare -f)" "uninstall_tcp_acceleration"
    assert_not_contains "no restore_tcp_runtime symbol" \
        "$(declare -f)" "restore_tcp_runtime"
    for script in lib/bunny-runtime.sh lib/xhttp-runtime.sh profiles/reality.sh \
        profiles/combined.sh profiles/xhttp-cloudflare-streamup.sh; do
        assert_not_contains "${script} does not tear down TCP acceleration" \
            "$(<"${ROOT_DIR}/${script}")" "uninstall_tcp_acceleration"
    done
)

# 8.6 验证 ensure_swap 边界：fstab 无结尾换行时自动补换行
TEST_FSTAB_NONL="${TMP_DIR}/fstab_nonl"
printf 'UUID=123 / ext4 defaults 0 0' >"${TEST_FSTAB_NONL}"
export EASY_ALL_FSTAB_FILE="${TEST_FSTAB_NONL}"
export EASY_ALL_SWAP_FILE="${TMP_DIR}/test_swap_nonl"
rm -f -- "${EASY_ALL_SWAP_FILE}"
PATH="${MOCK_SWAP_BIN}:${PATH}" ensure_swap
assert_contains "fstab appends newline properly" "$(<"${TEST_FSTAB_NONL}")" $'\n'"${EASY_ALL_SWAP_FILE} none swap sw 0 0"

# 8.7 验证 ensure_swap 边界：swapon 失败时清理刚创建的 swapfile
TEST_SWAP_FAIL="${TMP_DIR}/test_swap_fail"
rm -f -- "${TEST_SWAP_FAIL}"
export EASY_ALL_SWAP_FILE="${TEST_SWAP_FAIL}"
MOCK_FAIL_BIN="${TMP_DIR}/mock_fail_bin"
mkdir -p "${MOCK_FAIL_BIN}"
cat >"${MOCK_FAIL_BIN}/fallocate" <<'EOF'
#!/bin/sh
touch "$3"
exit 0
EOF
cat >"${MOCK_FAIL_BIN}/swapon" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "${MOCK_FAIL_BIN}/fallocate" "${MOCK_FAIL_BIN}/swapon"
PATH="${MOCK_FAIL_BIN}:${PATH}" ensure_swap || true
[[ ! -f "${TEST_SWAP_FAIL}" ]] || fail "swapon 失败时应清理刚创建的 swapfile"

# 8.8 验证 FQ helper 独立目录与开机任务持久化（P1）
TEST_TCP_DIR="${TMP_DIR}/test_tcp_dir"
export EASY_ALL_TCP_DIR_OVERRIDE="${TEST_TCP_DIR}"
export SYSTEMD_SYSTEM_DIR="${TMP_DIR}/systemd"
mkdir -p "${SYSTEMD_SYSTEM_DIR}"
systemctl() { return 0; }
physical_fq_active() { return 0; }
default_route_iface() { echo "eth0"; }
configure_physical_fq() { return 0; }
BACKUP_DIR="${TMP_DIR}/backups"
mkdir -p "${BACKUP_DIR}"

apply_physical_fq_qdisc
[[ -f "${TEST_TCP_DIR}/apply-fq.sh" ]] || fail "apply-fq.sh 应写入 EASY_ALL_TCP_DIR"
assert_contains "fq service references tcp dir helper" \
    "$(<"${SYSTEMD_SYSTEM_DIR}/easy_all-fq.service")" "${TEST_TCP_DIR}/apply-fq.sh"

# 8.9 验证 IPv6 snapshot / configure / restore
TEST_IPV6_CONF="${TMP_DIR}/99-enable-ipv6.conf"
TEST_PROC_IPV6="${TMP_DIR}/proc_ipv6"
mkdir -p "${TEST_PROC_IPV6}"
export EASY_ALL_PROC_IPV6_DIR="${TEST_PROC_IPV6}"
export IPV6_SYSCTL_CONF="${TEST_IPV6_CONF}"
export BACKUP_DIR="${TMP_DIR}/ipv6_backups"
rm -rf "${BACKUP_DIR}"
mkdir -p "${BACKUP_DIR}"

# 场景 A: 原系统无 IPv6 配置，安装后生成，卸载时恢复为删除
sysctl() { return 0; }
snapshot_ipv6_state
[[ -f "${BACKUP_DIR}/pre-install-enable-ipv6.missing" ]] || fail "应生成 missing 标记"
configure_ipv4_only
[[ -f "${TEST_IPV6_CONF}" ]] || fail "configure_ipv4_only 应创建配置文件"
assert_contains "disable_ipv6 set in conf" "$(<"${TEST_IPV6_CONF}")" "net.ipv6.conf.all.disable_ipv6 = 1"

restore_preinstall_ipv6
[[ ! -f "${TEST_IPV6_CONF}" ]] || fail "restore_preinstall_ipv6 应删除新创建的配置文件"

# 场景 B: 原系统手动禁用 IPv6 (disable_ipv6=1)，snapshot 记录运行值，restore 回写原值而非设为 0
rm -rf "${BACKUP_DIR}"
mkdir -p "${BACKUP_DIR}"
sysctl() {
    if [[ "$1" == "-n" ]]; then
        echo "1"
        return 0
    fi
    return 0
}
snapshot_ipv6_state
assert_contains "runtime ipv6 snapshot records 1" \
    "$(<"${BACKUP_DIR}/pre-install-ipv6-runtime.conf")" "net.ipv6.conf.all.disable_ipv6 = 1"

# 场景 C: 验证 restore_preinstall_ipv6 回写运行参数时剥离 key 与 value 空白
RESTORE_SYSCTL_LOG="${TMP_DIR}/restore_sysctl.log"
: >"${RESTORE_SYSCTL_LOG}"
printf 'net.ipv6.conf.all.disable_ipv6 = 1 \r\n' >"${BACKUP_DIR}/pre-install-ipv6-runtime.conf"
touch "${BACKUP_DIR}/pre-install-enable-ipv6.missing"
sysctl() {
    printf '%s\n' "$*" >>"${RESTORE_SYSCTL_LOG}"
    return 0
}
restore_preinstall_ipv6
assert_contains "sysctl called with stripped key and value" \
    "$(<"${RESTORE_SYSCTL_LOG}")" "-w net.ipv6.conf.all.disable_ipv6=1"

# 8.10 验证 Bunny 卸载恢复 IPv6，且不再拆除 TCP 前置初始化（P2/P3）
assert_contains "bunny_remove_local calls restore_preinstall_ipv6" \
    "$(<"${ROOT_DIR}/lib/bunny-runtime.sh")" "restore_preinstall_ipv6"
assert_not_contains "bunny_remove_local keeps TCP acceleration" \
    "$(<"${ROOT_DIR}/lib/bunny-runtime.sh")" "uninstall_tcp_acceleration"

# 8.11 验证 arm64 Xray 架构适配与 Profile 写死常量清理（P1）
assert_not_contains "reality has no hardcoded XRAY_ARCHIVE" \
    "$(<"${ROOT_DIR}/profiles/reality.sh")" "readonly XRAY_ARCHIVE"
assert_not_contains "xhttp has no hardcoded XRAY_ARCHIVE" \
    "$(<"${ROOT_DIR}/lib/xhttp-runtime.sh")" "readonly XRAY_ARCHIVE"

(
    # 真实调用 download_xray：arm64 架构必须选到 arm64 asset 并通过 dgst 校验
    MOCK_ARM64_DPKG="${TMP_DIR}/mock_arm64_dpkg"
    mkdir -p "${MOCK_ARM64_DPKG}"
    cat >"${MOCK_ARM64_DPKG}/dpkg" <<'EOF'
#!/bin/sh
if [ "$1" = "--print-architecture" ]; then
    echo "arm64"
    exit 0
fi
exit 0
EOF
    chmod +x "${MOCK_ARM64_DPKG}/dpkg"
    XRAY_JSON="${TMP_DIR}/xray-release.json"
    cat >"${XRAY_JSON}" <<'EOF_JSON'
{
  "tag_name": "v26.1.1",
  "assets": [
    {"name": "Xray-linux-64.zip", "browser_download_url": "https://github.com/XTLS/Xray-core/releases/download/v26.1.1/Xray-linux-64.zip"},
    {"name": "Xray-linux-64.zip.dgst", "browser_download_url": "https://github.com/XTLS/Xray-core/releases/download/v26.1.1/Xray-linux-64.zip.dgst"},
    {"name": "Xray-linux-arm64-v8a.zip", "browser_download_url": "https://github.com/XTLS/Xray-core/releases/download/v26.1.1/Xray-linux-arm64-v8a.zip"},
    {"name": "Xray-linux-arm64-v8a.zip.dgst", "browser_download_url": "https://github.com/XTLS/Xray-core/releases/download/v26.1.1/Xray-linux-arm64-v8a.zip.dgst"}
  ]
}
EOF_JSON
    FAKE_SHA=$(printf 'fake-xray-zip' | openssl dgst -sha256 | awk '{print $NF}')
    XRAY_ZIP="${TMP_DIR}/fake-xray.zip"
    printf 'fake-xray-zip' >"${XRAY_ZIP}"
    XRAY_DGST_FILE="${TMP_DIR}/fake-xray.zip.dgst"
    printf 'SHA2-256: %s\n' "${FAKE_SHA}" >"${XRAY_DGST_FILE}"
    XRAY_URLS="${TMP_DIR}/xray-urls"
    : >"${XRAY_URLS}"
    xray_run=$(PATH="${MOCK_ARM64_DPKG}:${PATH}" \
        PROBE_ROOT="${ROOT_DIR}" XRAY_JSON="${XRAY_JSON}" XRAY_ZIP="${XRAY_ZIP}" \
        XRAY_DGST_FILE="${XRAY_DGST_FILE}" XRAY_URLS="${XRAY_URLS}" FAKE_SHA="${FAKE_SHA}" \
        XRAY_DIR="${TMP_DIR}/mock_xray" XRAY_BIN="${TMP_DIR}/mock_xray/xray" \
        XRAY_CONFIG="${TMP_DIR}/mock_xray/config.json" RUNTIME_TMP="${TMP_DIR}/xray_runtime" \
        bash -c '
            source "${PROBE_ROOT}/lib/log.sh"
            source "${PROBE_ROOT}/lib/xray-core.sh"
            make_temp_dir() { mktemp -d "${RUNTIME_TMP}/part.XXXXXX"; }
            download_https_file() {
                case "$1" in
                    */releases/latest) cp "${XRAY_JSON}" "$2" ;;
                    *.zip.dgst) cp "${XRAY_DGST_FILE}" "$2" ;;
                    *.zip) printf "%s\n" "$1" >>"${XRAY_URLS}"; cp "${XRAY_ZIP}" "$2" ;;
                esac
            }
            sha256sum() { printf "%s  %s\n" "${FAKE_SHA}" "${2:-}"; }
            unzip() { mkdir -p "$4" && printf "fake-xray-bin" >"$4/xray"; }
            mkdir -p "${RUNTIME_TMP}" "${XRAY_DIR}"
            download_xray
        ' 2>&1) || fail "arm64 download_xray 失败：${xray_run}"
    assert_equal "download_xray installs reported version" "v26.1.1" \
        "$(<"${TMP_DIR}/mock_xray/version")"
    assert_contains "arm64 requests arm64 asset" "$(<"${XRAY_URLS}")" "Xray-linux-arm64-v8a.zip"
    [[ -x "${TMP_DIR}/mock_xray/xray" ]] || fail "download_xray 应安装 Xray 可执行文件"
)

# 8.12 验证 snapshot_ipv6_state 防重入保护（P3）
(
    TEST_REENTER_BACKUP="${TMP_DIR}/reenter_backup"
    mkdir -p "${TEST_REENTER_BACKUP}"
    TEST_REENTER_SYSCTL="${TMP_DIR}/reenter_ipv6.conf"
    export IPV6_SYSCTL_CONF="${TEST_REENTER_SYSCTL}"
    export BACKUP_DIR="${TEST_REENTER_BACKUP}"
    # 首次快照：原系统无配置文件
    rm -f -- "${TEST_REENTER_SYSCTL}"
    snapshot_ipv6_state
    [[ -f "${TEST_REENTER_BACKUP}/pre-install-enable-ipv6.missing" ]] || fail "首次快照应生成 missing 标记"
    # 后续安装生成了新配置文件
    echo "net.ipv6.conf.all.disable_ipv6 = 1" >"${TEST_REENTER_SYSCTL}"
    # 模拟续装或重复拍快照：不应覆盖 missing 标记，也不应创建 pre-install-enable-ipv6.conf
    snapshot_ipv6_state
    [[ ! -f "${TEST_REENTER_BACKUP}/pre-install-enable-ipv6.conf" ]] || fail "重复快照不应覆盖已存在的安装前状态"
    [[ -f "${TEST_REENTER_BACKUP}/pre-install-enable-ipv6.missing" ]] || fail "原始 missing 标记应保留"
)

# 8.13 验证各 Profile 的 apply 入口均包含 configure_ipv4_only（P2）
combined_script=$(<"${ROOT_DIR}/profiles/combined.sh")
assert_contains "combined apply_easy_all has configure_ipv4_only" \
    "${combined_script}" $'configure_tcp_acceleration\n    configure_ipv4_only'

xhttp_script=$(<"${ROOT_DIR}/profiles/xhttp-cloudflare-streamup.sh")
assert_contains "xhttp apply_easy_all has configure_ipv4_only" \
    "${xhttp_script}" $'configure_tcp_acceleration\n    configure_ipv4_only'

reality_script=$(<"${ROOT_DIR}/profiles/reality.sh")
assert_contains "reality apply_easy_all has configure_ipv4_only" \
    "${reality_script}" $'configure_tcp_acceleration\n    configure_ipv4_only'

bunny_script=$(<"${ROOT_DIR}/profiles/ws-bunny.sh")
assert_contains "bunny apply_easy_all has configure_ipv4_only" \
    "${bunny_script}" $'apply_cloud_resources\n    configure_ipv4_only'

# 8.14 验证 Xray 服务单元注入内存积极归还环境变量 (GOMEMLIMIT / madvdontneed)
(
    TEST_XRAY_SERVICE_FILE="${TMP_DIR}/test-xray.service"
    export XRAY_SERVICE_FILE="${TEST_XRAY_SERVICE_FILE}"
    export XRAY_SERVICE="easy_all-xray.service"
    export RUNTIME_TMP="${TMP_DIR}"
    export XRAY_DIR="${TMP_DIR}/xray"
    export XRAY_BIN="${TMP_DIR}/xray/xray"
    export XRAY_CONFIG="${TMP_DIR}/xray/config.json"
    systemctl() { return 0; }
    source "${ROOT_DIR}/lib/xray-core.sh"
    install_xray_service
    unit_content=$(<"${TEST_XRAY_SERVICE_FILE}")
    assert_contains "xray service has GOMEMLIMIT" "${unit_content}" "Environment=GOMEMLIMIT=128MiB"
    assert_contains "xray service has madvdontneed" "${unit_content}" "Environment=GODEBUG=madvdontneed=1"
)

# 8.15 验证 optimize_nginx_system_config 将 worker_processes auto 收敛为 1，且不改主配置权限
(
    TEST_NGINX_CONF="${TMP_DIR}/test_nginx.conf"
    cat >"${TEST_NGINX_CONF}" <<'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
EOF
    chmod 0644 "${TEST_NGINX_CONF}"
    export EASY_ALL_NGINX_MAIN_CONF="${TEST_NGINX_CONF}"
    source "${ROOT_DIR}/lib/profile-common.sh"
    umask 077
    optimize_nginx_system_config
    assert_contains "nginx worker_processes tuned to 1" "$(<"${TEST_NGINX_CONF}")" "worker_processes 1;"
    assert_equal "nginx main conf keeps its mode" "-rw-r--r--" \
        "$(ls -l "${TEST_NGINX_CONF}" | cut -c1-10)"
)

# 8.16 验证 skyline_build_jobs 限制 arm64 源码编译并发数
(
    # 模拟物理内存 1GB
    TEST_MEM_1G="${TMP_DIR}/meminfo_1g"
    cat >"${TEST_MEM_1G}" <<'EOF'
MemTotal:        1048576 kB
SwapTotal:       1048576 kB
EOF
    export EASY_ALL_MEMINFO_FILE="${TEST_MEM_1G}"
    unset EASY_ALL_CARGO_BUILD_JOBS
    assert_equal "1G RAM sets CARGO_BUILD_JOBS=1" "1" "$(skyline_build_jobs)"

    # 模拟物理内存 4GB
    TEST_MEM_4G="${TMP_DIR}/meminfo_4g"
    cat >"${TEST_MEM_4G}" <<'EOF'
MemTotal:        4194304 kB
SwapTotal:       1048576 kB
EOF
    export EASY_ALL_MEMINFO_FILE="${TEST_MEM_4G}"
    assert_equal "4G RAM sets CARGO_BUILD_JOBS=2" "2" "$(skyline_build_jobs)"

    # 环境变量覆盖优先
    export EASY_ALL_CARGO_BUILD_JOBS="4"
    assert_equal "env override CARGO_BUILD_JOBS" "4" "$(skyline_build_jobs)"
)

# 8.17 验证内核版本选择：只取最高的 Zabbly 内核，残留的 XanMod 内核不得参与
export KERNEL_BOOT_DIR_OVERRIDE="${TMP_DIR}/bootdir"
mkdir -p "${KERNEL_BOOT_DIR_OVERRIDE}"
for kernel in 6.12.9-zabbly+ 7.2.15-zabbly+ 9.9.9-xanmod1; do
    printf x >"${KERNEL_BOOT_DIR_OVERRIDE}/vmlinuz-${kernel}"
done
printf x >"${KERNEL_BOOT_DIR_OVERRIDE}/initrd.img-7.2.15-zabbly+"
printf x >"${KERNEL_BOOT_DIR_OVERRIDE}/initrd.img-6.12.9-zabbly+"
assert_equal "kernel release picks highest Zabbly kernel" "7.2.15-zabbly+" \
    "$(bash -c "source '${ROOT_DIR}/lib/log.sh'; source '${ROOT_DIR}/lib/tcp-tuning.sh'; zabbly_kernel_release_on_disk")"
bash -c "source '${ROOT_DIR}/lib/log.sh'; source '${ROOT_DIR}/lib/tcp-tuning.sh'; zabbly_kernel_image_installed" \
    || fail "存在 zabbly vmlinuz + initrd 时应判定内核已安装"
rm -f -- "${KERNEL_BOOT_DIR_OVERRIDE}/initrd.img-7.2.15-zabbly+"
assert_equal "kernel release falls back to newest complete kernel" "6.12.9-zabbly+" \
    "$(bash -c "source '${ROOT_DIR}/lib/log.sh'; source '${ROOT_DIR}/lib/tcp-tuning.sh'; zabbly_kernel_release_on_disk")"
rm -f -- "${KERNEL_BOOT_DIR_OVERRIDE}/initrd.img-6.12.9-zabbly+"
if bash -c "source '${ROOT_DIR}/lib/log.sh'; source '${ROOT_DIR}/lib/tcp-tuning.sh'; zabbly_kernel_image_installed"; then
    fail "缺少 initrd 时不应判定内核已安装"
fi

# 8.18 验证 TCP 调优配置不再写入拥塞控制算法与 modules-load 文件
TUNING_CONF="${TMP_DIR}/99-easy_all-tcp.conf"
TUNING_BIN="${TMP_DIR}/tuning_bin"
mkdir -p "${TUNING_BIN}"
printf '#!/bin/sh\nexit 0\n' >"${TUNING_BIN}/sysctl"
chmod +x "${TUNING_BIN}/sysctl"
tuning_conf_text=$(TCP_SYSCTL_CONF_OVERRIDE="${TUNING_CONF}" RUNTIME_TMP="${TMP_DIR}" \
    PATH="${TUNING_BIN}:${PATH}" bash -c "
        source '${ROOT_DIR}/lib/log.sh'
        source '${ROOT_DIR}/lib/tcp-tuning.sh'
        ensure_vps_ip_family() { :; }
        apply_physical_fq_qdisc() { :; }
        PROTOCOL=reality
        CDN_PROVIDER=
        configure_tcp_parameters
        cat '${TUNING_CONF}'
    ")
assert_contains "TCP tuning keeps fq qdisc" "${tuning_conf_text}" "net.core.default_qdisc = fq"
assert_not_contains "TCP tuning no longer sets a congestion control" "${tuning_conf_text}" \
    "tcp_congestion_control"
[[ ! -e "${TMP_DIR}/easy_all-bbr.conf" ]] || fail "不应再生成 modules-load 文件"

# 8.19 验证 Skyline 重新挂载失败时 apply 不得报成功
(
    apply_physical_fq_qdisc() { :; }
    configure_tcp_parameters() { :; }
    SKYLINE_PROBE=0
    skyline_speeder_active() {
        SKYLINE_PROBE=$((SKYLINE_PROBE + 1))
        ((SKYLINE_PROBE == 1))
    }
    systemctl() { return 1; }
    SYSTEMD_SYSTEM_DIR="${TMP_DIR}/mock_systemd"
    EASY_ALL_TCP_DIR_OVERRIDE="${TMP_DIR}/mock_tcp_dir"
    mkdir -p "${SYSTEMD_SYSTEM_DIR}" "${EASY_ALL_TCP_DIR_OVERRIDE}"
    touch "${SYSTEMD_SYSTEM_DIR}/easy_all-fq.service" "${EASY_ALL_TCP_DIR_OVERRIDE}/apply-fq.sh"
    set +e
    reattach_out=$(configure_tcp_acceleration 2>&1)
    reattach_rc=$?
    set -e
    ((reattach_rc != 0)) || fail "Skyline 重新启用失败时 configure_tcp_acceleration 必须返回非零"
    assert_contains "reattach failure is reported" "${reattach_out}" "重新启用失败"
)


echo "=== 9. Bunny 模式输入边界校验（Token / 路径 / UUID 直写 state.env 与 Nginx） ==="
BUNNY_PROBE="${TMP_DIR}/bunny-input-probe.sh"
cat >"${BUNNY_PROBE}" <<'PROBE'
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$1
TMP=$2
# ws-bunny 会对所有常量做 readonly：同名函数只填充尚未预设的变量，保留测试的隔离路径。
readonly() {
    local arg name val
    for arg in "$@"; do
        [[ "${arg}" == -* ]] && continue
        if [[ "${arg}" == *=* ]]; then
            name=${arg%%=*}
            val=${arg#*=}
            if [[ -z "${!name+x}" ]]; then
                printf -v "${name}" '%s' "${val}"
            fi
        fi
    done
}
# macOS 的 mktemp 忽略 TMPDIR；限制环境可能不可写默认临时目录。
mktemp() {
    if [[ $# -eq 1 && "$1" == "-d" ]]; then
        command mktemp -d "${TMP}/runtime.XXXXXX"
        return
    fi
    command mktemp "$@"
}
export EASY_ALL_RUNTIME_LIB_DIR="${ROOT}/lib"
export STATE_DIR="${TMP}/state" BACKUP_DIR="${TMP}/state/backups" STATE_FILE="${TMP}/state/state.env"
export BUNNY_RECOVERY_DIR="${TMP}/bunny" BUNNY_KEY_FILE="${TMP}/bunny/key" \
    BUNNY_CLOUDFLARE_TOKEN_FILE="${TMP}/bunny/cf.token" BUNNY_CONFIG="${TMP}/bunny/config.json"
export CERT_DIR="${TMP}/certs" WEB_ROOT="${TMP}/web" SUBSCRIPTION_DIR="${TMP}/web/subscriptions" \
    COMMAND_PATH="${TMP}/bin/easy_all" XRAY_DIR="${TMP}/xray" \
    NGINX_CONFIG="${TMP}/nginx/easy_all.conf" UFW_BEFORE_RULES="${TMP}/ufw/before.rules" \
    LEGO_DIR="${TMP}/acme" LEGO_BIN="${TMP}/acme/lego" BUNNY_EDGE_IP_FILE="${TMP}/bunny-edge-ips"
export EASY_ALL_POLICY_STATE_DIR_OVERRIDE="${TMP}/policy"
export RUNTIME_WRITE_LOCK_FILE_OVERRIDE="${TMP}/lock"
install -d -m 0700 "${TMP}/bunny"
printf '%s\n' '{"zone":"example.com","origin":"origin.example.com","cdn":"cdn.example.com","ipv4":"198.51.100.10","name":"easyallabc123","secret":"0123456789abcdef","bandwidth_gb":500}' \
    >"${TMP}/bunny/config.json"
printf 'key\n' >"${TMP}/bunny/key"
printf 'token\n' >"${TMP}/bunny/cf.token"
# shellcheck source=/dev/null
source "${ROOT}/profiles/ws-bunny.sh"
bunny_collect_inputs
printf 'collected uuid=%s owner=%s path=%s\n' "${VLESS_UUID}" "${OWNER_TOKEN}" "${WEBSOCKET_PATH}"
PROBE
chmod +x "${BUNNY_PROBE}"

BUNNY_UUID="11111111-2222-4111-8111-111111111111"
probe_bunny() {
    local owner=$1 path=$2 uuid=$3 output probe_status=0
    rm -rf -- "${TMP_DIR}/bunny-probe"
    output=$(VPS_IP=198.51.100.10 OWNER_TOKEN="${owner}" WEBSOCKET_PATH="${path}" \
        VLESS_UUID="${uuid}" bash "${BUNNY_PROBE}" "${ROOT_DIR}" "${TMP_DIR}/bunny-probe" 2>&1) \
        || probe_status=$?
    printf '%s' "${output}"
    return "${probe_status}"
}

bunny_ok_out=$(probe_bunny 'abcdefgh12345678' '/ws-abc123' "${BUNNY_UUID}") \
    || fail "bunny install must accept valid token/path/UUID"
assert_contains "bunny probe collects identity" "${bunny_ok_out}" "collected uuid=${BUNNY_UUID}"

bad_token_rc=0
bad_token_out=$(probe_bunny 'bad"tokenvalue' '/ws-abc123' "${BUNNY_UUID}") || bad_token_rc=$?
((bad_token_rc != 0)) || fail "bunny install must reject a token that would break state.env or the Nginx map"
assert_contains "short token is rejected" "$(probe_bunny 'short' '/ws-abc123' "${BUNNY_UUID}" || true)" \
    "订阅 Token 无效"

bad_path_rc=0
bad_path_out=$(probe_bunny 'abcdefgh12345678' '/ws bad' "${BUNNY_UUID}") || bad_path_rc=$?
((bad_path_rc != 0)) || fail "bunny install must reject a websocket path with blanks"
assert_contains "blank websocket path is rejected" "${bad_path_out}" "WEBSOCKET_PATH 无效"
assert_contains "non-absolute websocket path is rejected" \
    "$(probe_bunny 'abcdefgh12345678' 'no-slash' "${BUNNY_UUID}" || true)" "WEBSOCKET_PATH 无效"

bad_uuid_rc=0
bad_uuid_out=$(probe_bunny 'abcdefgh12345678' '/ws-abc123' 'not-a-uuid') || bad_uuid_rc=$?
((bad_uuid_rc != 0)) || fail "bunny install must reject an invalid VLESS UUID"
assert_contains "invalid UUID is rejected" "${bad_uuid_out}" "VLESS_UUID 无效"


echo "=== 10. Reality 动态端口 NAT 目标必须等于 inbound 实监端口（不写死 443） ==="
REALITY_PORT_PROBE="${TMP_DIR}/reality-port-probe.sh"
cat >"${REALITY_PORT_PROBE}" <<'PROBE'
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$1
TMP=$2
PORT=$3
readonly() {
    local arg name val
    for arg in "$@"; do
        [[ "${arg}" == -* ]] && continue
        if [[ "${arg}" == *=* ]]; then
            name=${arg%%=*}
            val=${arg#*=}
            if [[ -z "${!name+x}" ]]; then printf -v "${name}" '%s' "${val}"; fi
        fi
    done
}
mktemp() {
    if [[ $# -eq 1 && "$1" == "-d" ]]; then command mktemp -d "${TMP}/runtime.XXXXXX"; return; fi
    command mktemp "$@"
}
export EASY_ALL_RUNTIME_LIB_DIR="${ROOT}/lib"
# 端口从外部注入：若代码里写死 443，注入 8443 时渲染结果就会暴露失配。
export SERVICE_PORT="${PORT}"
export STATE_DIR="${TMP}/state" BACKUP_DIR="${TMP}/state/backups" STATE_FILE="${TMP}/state/state.env" \
    XRAY_DIR="${TMP}/xray" XRAY_CONFIG="${TMP}/xray/config.json" XRAY_BIN="${TMP}/bin/xray" \
    WEB_ROOT="${TMP}/web" CERT_DIR="${TMP}/certs" \
    EASY_ALL_POLICY_STATE_DIR_OVERRIDE="${TMP}/policy" \
    RUNTIME_WRITE_LOCK_FILE_OVERRIDE="${TMP}/lock"
install -d -m 0700 "${TMP}/bin" "${XRAY_DIR}"
cat >"${XRAY_BIN}" <<'XRAY'
#!/usr/bin/env bash
case "${1:-}" in
x25519) printf '%s\n' 'PrivateKey: test-private-key' 'Password: test-public-key' ;;
run) exit 0 ;;
esac
exit 0
XRAY
chmod +x "${XRAY_BIN}"
# shellcheck source=/dev/null
source "${ROOT}/profiles/reality.sh"
VLESS_UUID=11111111-2222-4111-8111-111111111111
REALITY_TARGET=swdist.apple.com:443
REALITY_PRIVATE_KEY=""
REALITY_SHORT_ID=""
detect_ssh_ports() { SSH_PORTS=22; }
write_xray_config
printf 'inbound=%s\n' "$(jq -r '.inbounds[0].port' "${XRAY_CONFIG}")"
printf 'nat=%s\n' "$(write_dynamic_nat_rules | awk '{print $NF}')"
PROBE

for reality_port in 443 8443; do
    port_probe_out=$(bash "${REALITY_PORT_PROBE}" "${ROOT_DIR}" \
        "${TMP_DIR}/reality-port-${reality_port}" "${reality_port}") \
        || fail "reality port probe failed for ${reality_port}"
    assert_contains "reality inbound follows SERVICE_PORT=${reality_port}" \
        "${port_probe_out}" "inbound=${reality_port}"
    assert_contains "reality NAT target follows SERVICE_PORT=${reality_port}" \
        "${port_probe_out}" "nat=${reality_port}"
done

echo "=== 11. 卸载只回收业务端口：保留 UFW 启用状态、SSH 放行与 Fail2ban 基线 ==="

# 11.1 外部注入的 RUNTIME_TMP 必须被尊重，且不登记进 cleanup_files（退出时不删外部目录）
runtime_probe="${TMP_DIR}/runtime-inject"
install -d -m 0700 "${runtime_probe}/injected" "${runtime_probe}/policy"
runtime_probe_out=$(EASY_ALL_RUNTIME_LIB_DIR="${ROOT_DIR}/lib" \
    RUNTIME_TMP="${runtime_probe}/injected" \
    EASY_ALL_POLICY_STATE_DIR_OVERRIDE="${runtime_probe}/policy" \
    RUNTIME_WRITE_LOCK_FILE_OVERRIDE="${runtime_probe}/lock" \
    bash -c 'source "$1/runtime-core.sh"; trap - EXIT; printf "%s|%s|%s" "${RUNTIME_TMP}" "${cleanup_files[*]:-}" "${RUNTIME_TMP_CREATED}"' \
    _ "${ROOT_DIR}/lib") || fail "runtime-core 必须接受外部注入的 RUNTIME_TMP"
assert_equal "注入的 RUNTIME_TMP 保持不变且不登记清理" \
    "${runtime_probe}/injected||0" "${runtime_probe_out}"
[[ -d "${runtime_probe}/injected" ]] || fail "注入的 RUNTIME_TMP 不应被删除"

# 11.2 UFW 业务端口回收：保留 SSH 放行与 Fail2ban 封禁，删除 443/8443，绝不 disable
ufw_dir="${TMP_DIR}/ufw-reclaim"
install -d -m 0700 "${ufw_dir}"
cat >"${ufw_dir}/ufw" <<'FAKE_UFW'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${FAKE_UFW_LOG}"
case "${1:-}" in
status) cat "${FAKE_UFW_STATUS}" ;;
reload) exit 0 ;;
--force)
    [[ "${2:-}" == "delete" ]] || exit 0
    awk -v n="${3:-}" '
        /^\[/ {
            line=$0; sub(/^\[[[:space:]]*/, "", line); num=line; sub(/\].*$/, "", num)
            if (num == n) next
        }
        {print}
    ' "${FAKE_UFW_STATUS}" >"${FAKE_UFW_STATUS}.new"
    mv -f -- "${FAKE_UFW_STATUS}.new" "${FAKE_UFW_STATUS}"
    ;;
*) exit 0 ;;
esac
FAKE_UFW
chmod +x "${ufw_dir}/ufw"
cat >"${ufw_dir}/status" <<'FAKE_STATUS'
Status: active

To                         Action      From
--                         ------      ----
[ 1] Anywhere                   DENY IN     203.0.113.7                # easy_all-fail2ban-cidr
[ 2] 2222/tcp                   ALLOW IN    Anywhere                   # easy_all-managed
[ 3] 443/tcp                    ALLOW IN    Anywhere                   # easy_all-managed
[ 4] 8443/tcp                   ALLOW IN    Anywhere                   # easy_all-managed
[ 5] 8080/tcp                   ALLOW IN    Anywhere                   # debian-init-managed
FAKE_STATUS
export FAKE_UFW_STATUS="${ufw_dir}/status" FAKE_UFW_LOG="${ufw_dir}/log"
: >"${FAKE_UFW_LOG}"
# shellcheck source=lib/firewall.sh
source "${ROOT_DIR}/lib/firewall.sh"
detect_ssh_ports() { SSH_PORTS="2222"; }
( export PATH="${ufw_dir}:${PATH}"; reclaim_ufw_business_rules ) \
    || fail "reclaim_ufw_business_rules 必须保留 SSH 放行"
ufw_status_after=$(<"${FAKE_UFW_STATUS}")
assert_contains "回收后保留 SSH 2222 放行" "${ufw_status_after}" "2222/tcp"
assert_not_contains "回收后删除业务端口 443" "${ufw_status_after}" "443/tcp"
assert_not_contains "回收后删除业务端口 8443" "${ufw_status_after}" "8443/tcp"
assert_contains "回收后保留 Fail2ban 封禁规则" "${ufw_status_after}" "easy_all-fail2ban-cidr"
assert_contains "回收不碰初始化基线的额外端口" "${ufw_status_after}" "8080/tcp"
assert_not_contains "回收过程绝不 disable UFW" "$(<"${FAKE_UFW_LOG}")" "disable"

# 11.2b 仅按来源放行 SSH 时，回收不得擅自扩大为全网放行
cat >"${FAKE_UFW_STATUS}" <<'FAKE_STATUS2'
Status: active

To                         Action      From
--                         ------      ----
[ 1] 2222/tcp                   ALLOW IN    203.0.113.0/24             # user-ssh
[ 2] 443/tcp                    ALLOW IN    Anywhere                   # easy_all-managed
FAKE_STATUS2
: >"${FAKE_UFW_LOG}"
( export PATH="${ufw_dir}:${PATH}"; reclaim_ufw_business_rules ) \
    || fail "按来源放行 SSH 时回收不应失败"
scoped_status=$(<"${FAKE_UFW_STATUS}")
assert_equal "按来源的 SSH 放行保持原样" "1" "$(grep -c '2222/tcp' <<<"${scoped_status}")"
assert_not_contains "回收不得把按来源的 SSH 放行扩大为全网放行" \
    "$(<"${FAKE_UFW_LOG}")" "allow 2222/tcp"
assert_not_contains "按来源场景仍回收业务端口 443" "${scoped_status}" "443/tcp"
# Fail2ban 封禁规则位于 [ 1]（真实 insert 1 顺序）时，按来源的 DENY 不能算作 SSH 全局阻断
if ( export PATH="${ufw_dir}:${PATH}"; ufw_ssh_port_has_unmanaged_block 2222 ); then
    fail "按来源的 DENY 不得被当作 SSH 全局阻断"
fi

# 11.3 卸载保留 Fail2ban 配置，并把旧版运行时目录里的 helper 迁移到系统路径
f2b_dir="${TMP_DIR}/f2b"
install -d -m 0700 "${f2b_dir}/jail.d" "${f2b_dir}/action.d" "${f2b_dir}/sbin" \
    "${f2b_dir}/runtime" "${f2b_dir}/backups" "${f2b_dir}/bin" "${f2b_dir}/ssh"
export EASY_ALL_FAIL2BAN_CONFIG="${f2b_dir}/jail.d/99-easy-all-sshd.local"
export EASY_ALL_FAIL2BAN_ACTION_CONFIG="${f2b_dir}/action.d/easy-all-ufw-cidr.conf"
export EASY_ALL_FAIL2BAN_CIDR_HELPER="${f2b_dir}/sbin/fail2ban-ufw-cidr.sh"
export EASY_ALL_LEGACY_FAIL2BAN_CIDR_HELPER="${f2b_dir}/runtime/fail2ban-ufw-cidr.sh"
export EASY_ALL_FAIL2BAN_CIDR_STATE_DIR="${f2b_dir}/state"
export EASY_ALL_SSH_PORT_CONFIG="${f2b_dir}/ssh/00-easy-all-ports.conf"
export BACKUP_DIR="${f2b_dir}/backups"
printf 'MANAGED-JAIL\n' >"${EASY_ALL_FAIL2BAN_CONFIG}"
printf 'PREINSTALL-JAIL\n' >"${BACKUP_DIR}/pre-install-fail2ban-jail.conf"
printf 'legacy-helper\n' >"${EASY_ALL_LEGACY_FAIL2BAN_CIDR_HELPER}"
chmod 0755 "${EASY_ALL_LEGACY_FAIL2BAN_CIDR_HELPER}"
printf '[Definition]\nactionban = %s ban <ip> %s\n' \
    "${EASY_ALL_LEGACY_FAIL2BAN_CIDR_HELPER}" "${EASY_ALL_FAIL2BAN_CIDR_STATE_DIR}" \
    >"${EASY_ALL_FAIL2BAN_ACTION_CONFIG}"
cat >"${f2b_dir}/bin/sshd" <<'FAKE_SSHD'
#!/usr/bin/env bash
exit 0
FAKE_SSHD
chmod +x "${f2b_dir}/bin/sshd"
systemctl() { printf 'systemctl %s\n' "$*" >>"${f2b_dir}/systemctl.log"; return 0; }
fail2ban-client() { return 0; }
ssh_effective_listeners() { printf '0.0.0.0:2222\n'; }
ssh_actual_listeners() { printf '0.0.0.0:2222\n'; }
wait_for_ssh_listeners() { return 0; }
ufw() { :; }
( export PATH="${f2b_dir}/bin:${PATH}"; restore_platform_security_state ) \
    || fail "保留基线的 restore_platform_security_state 必须成功"
assert_equal "卸载保留受管 Fail2ban jail" "MANAGED-JAIL" "$(<"${EASY_ALL_FAIL2BAN_CONFIG}")"
assert_equal "旧版 helper 迁移到系统路径" "legacy-helper" \
    "$(<"${EASY_ALL_FAIL2BAN_CIDR_HELPER}")"
assert_not_contains "action 配置不再引用运行时目录" \
    "$(<"${EASY_ALL_FAIL2BAN_ACTION_CONFIG}")" "${EASY_ALL_LEGACY_FAIL2BAN_CIDR_HELPER}"
assert_contains "action 配置指向系统 helper" \
    "$(<"${EASY_ALL_FAIL2BAN_ACTION_CONFIG}")" "${EASY_ALL_FAIL2BAN_CIDR_HELPER}"
assert_not_contains "卸载不禁用 Fail2ban" \
    "$(<"${f2b_dir}/systemctl.log")" "disable fail2ban"
# action 配置改路径后必须让运行中的 Fail2ban 重读，否则内存里仍持有旧路径
assert_contains "迁移后重启 Fail2ban 以加载新 helper" \
    "$(<"${f2b_dir}/systemctl.log")" "restart fail2ban.service"

# 11.3b 迁移失败必须中止（保留旧副本供重试），不能删掉唯一一份 helper
f2b_fail="${TMP_DIR}/f2b-migrate-fail"
install -d -m 0700 "${f2b_fail}/jail.d" "${f2b_fail}/action.d" "${f2b_fail}/runtime" \
    "${f2b_fail}/backups" "${f2b_fail}/bin"
printf 'blocker\n' >"${f2b_fail}/blocker"
printf 'legacy-helper\n' >"${f2b_fail}/runtime/fail2ban-ufw-cidr.sh"
chmod 0755 "${f2b_fail}/runtime/fail2ban-ufw-cidr.sh"
printf 'MANAGED-JAIL\n' >"${f2b_fail}/jail.d/99-easy-all-sshd.local"
printf '[Definition]\nactionban = %s ban <ip> %s\n' \
    "${f2b_fail}/runtime/fail2ban-ufw-cidr.sh" "${f2b_fail}/state" \
    >"${f2b_fail}/action.d/easy-all-ufw-cidr.conf"
cp "${f2b_dir}/bin/sshd" "${f2b_fail}/bin/sshd"
(
    export EASY_ALL_FAIL2BAN_CONFIG="${f2b_fail}/jail.d/99-easy-all-sshd.local"
    export EASY_ALL_FAIL2BAN_ACTION_CONFIG="${f2b_fail}/action.d/easy-all-ufw-cidr.conf"
    export EASY_ALL_FAIL2BAN_CIDR_HELPER="${f2b_fail}/blocker/fail2ban-ufw-cidr.sh"
    export EASY_ALL_LEGACY_FAIL2BAN_CIDR_HELPER="${f2b_fail}/runtime/fail2ban-ufw-cidr.sh"
    export EASY_ALL_FAIL2BAN_CIDR_STATE_DIR="${f2b_fail}/state"
    export EASY_ALL_SSH_PORT_CONFIG="${f2b_fail}/ssh/00-easy-all-ports.conf"
    export BACKUP_DIR="${f2b_fail}/backups"
    export PATH="${f2b_fail}/bin:${PATH}"
    restore_platform_security_state
) && fail "迁移失败时必须中止卸载以保留旧 helper"
[[ -f "${f2b_fail}/runtime/fail2ban-ufw-cidr.sh" ]] \
    || fail "迁移失败后旧 helper 必须保留"

# 11.4 移除 UFW 规则区块不得留下 .bak 垃圾文件
block_file="${TMP_DIR}/before.rules"
printf '%s\n' 'keep-1' '# easy_all-bunny-start' 'drop-me' '# easy_all-bunny-end' 'keep-2' \
    >"${block_file}"
chmod 0600 "${block_file}"
remove_ufw_managed_block "${block_file}" '# easy_all-bunny-start' '# easy_all-bunny-end' \
    || fail "remove_ufw_managed_block 必须成功"
assert_equal "受管规则区块被移除" $'keep-1\nkeep-2' "$(<"${block_file}")"
[[ ! -e "${block_file}.bak" ]] || fail "不得留下 .bak 备份文件"
assert_equal "区块移除保留原文件权限" "600" \
    "$(stat -c '%a' "${block_file}" 2>/dev/null || stat -f '%Lp' "${block_file}")"

# 11.7 UFW inactive 时 ufw show added 中按来源的 DENY 不能算 SSH 全局阻断
ufw_inactive="${TMP_DIR}/ufw-inactive"
install -d -m 0700 "${ufw_inactive}"
cat >"${ufw_inactive}/ufw" <<'FAKE_UFW_INACTIVE'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
status) printf 'Status: inactive\n' ;;
show) cat "${FAKE_UFW_ADDED}" ;;
*) exit 0 ;;
esac
FAKE_UFW_INACTIVE
chmod +x "${ufw_inactive}/ufw"
export FAKE_UFW_ADDED="${ufw_inactive}/added"
printf '%s\n' "ufw deny from 203.0.113.7 to any port 2222 proto tcp" >"${FAKE_UFW_ADDED}"
if ( unset -f ufw; export PATH="${ufw_inactive}:${PATH}"; ufw_ssh_port_has_unmanaged_block 2222 ); then
    fail "按来源的 DENY 不得被判为 SSH 全局阻断"
fi
printf '%s\n' "ufw deny 2222/tcp" >"${FAKE_UFW_ADDED}"
( unset -f ufw; export PATH="${ufw_inactive}:${PATH}"; ufw_ssh_port_has_unmanaged_block 2222 ) \
    || fail "全局 DENY 2222/tcp 必须被判为阻断"

# 11.5 卸载与安装失败回滚都不得关闭 UFW 或删除 Fail2ban 基线
assert_not_contains "仓库内不得再有 ufw --force disable" \
    "$(grep -Rh -- 'ufw --force disable' "${ROOT_DIR}/lib" "${ROOT_DIR}/profiles" 2>/dev/null || true)" \
    "ufw --force disable"
for profile in profiles/reality.sh profiles/xhttp-cloudflare-streamup.sh profiles/combined.sh; do
    uninstall_body=$(awk '/^uninstall_all\(\)/,/^}/' "${ROOT_DIR}/${profile}")
    assert_contains "${profile} 卸载回收业务端口" "${uninstall_body}" "restore_preinstall_firewall"
    assert_not_contains "${profile} 卸载不带旧的回滚参数" "${uninstall_body}" "restore_preinstall_firewall 1"
done
rollback_body=$(awk '/^rollback_fresh_install\(\)/,/^}/' "${ROOT_DIR}/profiles/reality.sh")
assert_not_contains "reality 回滚不关闭 UFW" "${rollback_body}" "ufw --force disable"

# 11.6 Bunny 依赖安装必须等待 dpkg 锁；debian-init 模块 URL 必须跟随分支
assert_contains "ws-bunny apt 等待 dpkg 锁" \
    "$(awk '/^install_packages\(\)/,/^}/' "${ROOT_DIR}/profiles/ws-bunny.sh")" \
    "-o DPkg::Lock::Timeout=300"
assert_contains "debian-init 模块 URL 跟随 EASY_ALL_BRANCH" \
    "$(<"${ROOT_DIR}/scripts/debian-init.sh")" \
    'easy_all/${EASY_ALL_BRANCH}/lib/platform.sh'


echo "=== 12. 已初始化主机重装时明确跳过日志（B1） ==="
# shellcheck source=lib/profile-common.sh
source "${ROOT_DIR}/lib/profile-common.sh"
meminfo="${TMP_DIR}/meminfo"
printf 'SwapTotal:       1048572 kB\n' >"${meminfo}"
init_state=$( (
    systemctl() { return 0; }
    fail2ban-client() { return 0; }
    ufw() { printf '%s\n' 'Status: active'; }
    EASY_ALL_MEMINFO_FILE="${meminfo}" report_host_init_state
) 2>&1 ) || fail "已初始化主机必须能输出状态"
assert_contains "已初始化主机提示跳过重复安装" "${init_state}" \
    "已就绪的依赖、内核与 TCP 加速将跳过重复安装"
printf 'SwapTotal:             0 kB\n' >"${meminfo}"
first_state=$( (
    systemctl() { return 1; }
    fail2ban-client() { return 1; }
    ufw() { printf '%s\n' 'Status: inactive'; }
    EASY_ALL_MEMINFO_FILE="${meminfo}" report_host_init_state
) 2>&1 ) || fail "未初始化主机必须能输出状态"
assert_contains "未初始化主机提示首次安装" "${first_state}" "首次安装"
for profile in profiles/reality.sh profiles/xhttp-cloudflare-streamup.sh profiles/ws-bunny.sh profiles/combined.sh; do
    body=$(awk '/^(install_all|run_reality_install_pipeline)\(\)/,/^}/' "${ROOT_DIR}/${profile}")
    assert_contains "${profile} 初始化阶段输出状态" "${body}" "report_host_init_state"
done


echo "=== 13. 旧状态版本卸载不再崩溃，并迁移旧版 Fail2ban helper ==="
legacy_dir="${TMP_DIR}/legacy"
install -d -m 0700 "${legacy_dir}/runtime" "${legacy_dir}/sbin" "${legacy_dir}/action.d"
printf 'legacy-helper\n' >"${legacy_dir}/runtime/fail2ban-ufw-cidr.sh"
chmod 0755 "${legacy_dir}/runtime/fail2ban-ufw-cidr.sh"
printf '[Definition]\nactionban = %s ban <ip> %s\n' \
    "${legacy_dir}/runtime/fail2ban-ufw-cidr.sh" "${legacy_dir}/state" \
    >"${legacy_dir}/action.d/easy-all-ufw-cidr.conf"
legacy_calls="${legacy_dir}/calls.log"
: >"${legacy_calls}"
# 独立脚本执行：真实调用时 legacy_local_uninstall 不在 || 条件里，set -e 会生效。
cat >"${legacy_dir}/run-legacy-uninstall.sh" <<'LEGACY_UNINSTALL'
set -Eeuo pipefail
root_dir=$1
legacy_dir=$2
calls=$3
# shellcheck source=/dev/null
source "${root_dir}/easy_all"
# 模拟真实场景：launcher 在加载 profile 前没有 log.sh 提供的日志函数。
unset -f warn success info die
unset EASY_ALL_LOG_LOADED
id() { printf '0\n'; }
rm() { printf 'rm %s\n' "$*" >>"${calls}"; }
systemctl() { return 0; }
fail2ban-client() { return 0; }
crontab() { return 1; }
export EASY_ALL_FAIL2BAN_CONFIG="${legacy_dir}/jail.d/99-easy-all-sshd.local"
export EASY_ALL_FAIL2BAN_ACTION_CONFIG="${legacy_dir}/action.d/easy-all-ufw-cidr.conf"
export EASY_ALL_FAIL2BAN_CIDR_HELPER="${legacy_dir}/sbin/fail2ban-ufw-cidr.sh"
export EASY_ALL_LEGACY_FAIL2BAN_CIDR_HELPER="${legacy_dir}/runtime/fail2ban-ufw-cidr.sh"
export EASY_ALL_FAIL2BAN_CIDR_STATE_DIR="${legacy_dir}/state"
legacy_local_uninstall
LEGACY_UNINSTALL
legacy_rc=0
bash "${legacy_dir}/run-legacy-uninstall.sh" "${ROOT_DIR}" "${legacy_dir}" "${legacy_calls}" \
    || legacy_rc=$?
assert_equal "旧状态版本卸载退出码" "0" "${legacy_rc}"
[[ -f "${legacy_dir}/sbin/fail2ban-ufw-cidr.sh" ]] || fail "旧 helper 必须迁移到系统路径"
assert_contains "action 配置指向新 helper" \
    "$(<"${legacy_dir}/action.d/easy-all-ufw-cidr.conf")" "${legacy_dir}/sbin/fail2ban-ufw-cidr.sh"
assert_contains "旧状态版本卸载执行了本机清理" "$(<"${legacy_calls}")" "rm -rf /etc/easy_all"

echo "ok - all audit fixes verified successfully"
