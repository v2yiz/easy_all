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
assert_not_contains "旧 Globalping 选优定时器已删除" "${guard_content}" "globalping"
[[ ! -e "${ROOT_DIR}/lib/globalping-cdn.sh" ]] || fail "lib/globalping-cdn.sh 必须删除"
# 旧 Globalping 单元/Token/cache 只能由卸载按固定文件名回收，不再有刷新命令或状态展示。
cleanup_body=$(awk '/^cdn_cleanup_legacy_globalping_artifacts\(\)/,/^}/' \
    "${ROOT_DIR}/lib/cloudfront-mode.sh")
assert_contains "卸载清理停用旧 Globalping 定时器" "${cleanup_body}" \
    "easy_all-globalping-refresh.timer"
assert_contains "卸载清理停用旧 Globalping 服务" "${cleanup_body}" \
    "easy_all-globalping-refresh.service"
assert_contains "卸载清理删除旧 Globalping Token" "${cleanup_body}" "globalping.token"
assert_contains "卸载流程调用旧 Globalping 清理" \
    "$(awk '/^cdn_local_uninstall_common\(\)/,/^}/' "${ROOT_DIR}/lib/cloudfront-mode.sh")" \
    "cdn_cleanup_legacy_globalping_artifacts"
assert_not_contains "帮助不再暴露 Globalping 刷新命令" \
    "${help_output:-}" "refresh-cdn-ips"

echo "=== 4. 新链路 Cloudflare Token 最小权限与 AWS 凭据仅内存 ==="
core_content=$(<"${ROOT_DIR}/lib/cloudfront-mode.sh")
assert_contains "cloudfront token prompt asks for zone read + DNS edit" \
    "${core_content}" "Zone 只读 + DNS 编辑权限"
assert_contains "AWS 凭据只在当前进程使用" "${core_content}" "仅限当前进程使用，不落盘"
assert_not_contains "不再要求 SSL/证书编辑权限" "${core_content}" "SSL/证书 编辑权限"
assert_contains "thin cloudfront profile delegates inputs to the shared core" \
    "$(<"${ROOT_DIR}/profiles/cloudfront.sh")" "collect_cloudfront_install_inputs"

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

echo "=== 7. 验证 Swap 自动创建与 sudo vim 依赖安装 ==="
# 7.1 验证各模式的 apt 依赖清单包含 sudo 和 vim（只看 pkgs 数组，避免注释误命中）
package_list_of() {
    awk '/local pkgs=\(/{flag=1; next} flag && /^[[:space:]]*\)/{exit} flag' "$1"
}
for script in lib/xhttp-runtime.sh profiles/reality.sh; do
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
    for script in lib/xhttp-runtime.sh profiles/reality.sh \
        profiles/combined.sh profiles/cloudfront.sh \
        lib/cloudfront-mode.sh; do
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
# 两种 CDN 模式共用 lib/cloudfront-mode.sh 的 apply 入口。
combined_script=$(<"${ROOT_DIR}/lib/cloudfront-mode.sh")
assert_contains "cdn apply_easy_all has configure_ipv4_only" \
    "${combined_script}" $'configure_tcp_acceleration\n    configure_ipv4_only'

reality_script=$(<"${ROOT_DIR}/profiles/reality.sh")
assert_contains "reality apply_easy_all has configure_ipv4_only" \
    "${reality_script}" $'configure_tcp_acceleration\n    configure_ipv4_only'

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


echo "=== 10. Reality 动态端口 NAT 目标必须等于 inbound 实监端口（不写死 443） ==="
REALITY_PORT_PROBE="${TMP_DIR}/reality-port-probe.sh"
cat >"${REALITY_PORT_PROBE}" <<'PROBE'
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$1
TMP=$2
PORT=$3
SHORT_ID=${4:-}
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
REALITY_SHORT_ID="${SHORT_ID}"
detect_ssh_ports() { SSH_PORTS=22; }
# Short ID 校验失败时 write_xray_config 会 die：一律取回退出码与错误文本供断言。
set +e
xray_err=$(write_xray_config 2>&1)
xray_rc=$?
set -e
printf 'rc=%s\n' "${xray_rc}"
printf 'err=%s\n' "${xray_err}"
printf 'inbound=%s\n' "$(jq -r '.inbounds[0].port' "${XRAY_CONFIG}" 2>/dev/null || true)"
printf 'nat=%s\n' "$(write_dynamic_nat_rules 2>/dev/null | awk '{print $NF}' || true)"
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
status_file="${FAKE_UFW_STATUS:?}"
# 真实 ufw 的编号来自规则顺序：渲染时重新编号，`insert 1` 会让所有既有规则编号后移。
render_status() {
    local index=0 body
    printf '%s\n\n%s\n%s\n' 'Status: active' 'To                         Action      From' \
        '--                         ------      ----'
    while IFS= read -r body; do
        [[ -n "${body}" ]] || continue
        index=$((index + 1))
        printf '[%2d] %s\n' "${index}" "${body}"
    done < <(awk '/^\[/ { body=$0; sub(/^[^]]*\][[:space:]]*/, "", body); print body }' "${status_file}")
}
insert_first_row() {
    local counter
    [[ "${FAKE_UFW_INSERT_BEFORE_DELETE:-0}" == "1" ]] || return 0
    counter=$(cat "${FAKE_UFW_INSERT_COUNTER}" 2>/dev/null || printf '0')
    counter=$((counter + 1))
    printf '%s' "${counter}" >"${FAKE_UFW_INSERT_COUNTER}"
    # 模拟 Fail2ban 的 `ufw insert 1`：新封禁规则插到首位，其余规则编号全部后移。
    { printf '[ 1] Anywhere                   DENY IN     198.51.100.%s                 # easy_all-fail2ban-cidr\n' "${counter}"
      cat "${status_file}"
    } >"${status_file}.new"
    mv -f -- "${status_file}.new" "${status_file}"
}
delete_row() {
    # 按完整规格定位：编号 / 端点 / 来源 / 注释。忽略来源或注释会让「把 CIDR 规则的来源
    # 生成错」或「漏掉 comment」的实现仍然通过，测试就失去意义。
    local mode=$1 endpoint_spec=$2 source_spec=${3:-Anywhere} comment_spec=${4:-} target
    target=$(awk -v mode="${mode}" -v endpoint="${endpoint_spec}" \
        -v source="${source_spec}" -v comment="${comment_spec}" '
        /^\[/ {
            rows++
            if (found) next
            body=$0; sub(/^[^]]*\][[:space:]]*/, "", body)
            row_comment=""
            if (index(body, " # ") != 0) {
                row_comment = substr(body, index(body, " # ") + 3)
                body = substr(body, 1, index(body, " # ") - 1)
            }
            split(body, fields, /[[:space:]]+/)
            if (mode == "number" && rows + 0 == endpoint + 0) { print rows; found = 1 }
            if (mode == "spec" && fields[1] == endpoint && fields[2] == "ALLOW" \
                && fields[3] == "IN" && fields[4] == source && row_comment == comment) {
                print rows; found = 1
            }
        }
    ' "${status_file}")
    if [[ -n "${target}" ]]; then
        endpoint_spec=$(awk -v idx="${target}" '
            /^\[/ {
                n++
                if (n == idx) {
                    body=$0; sub(/^[^]]*\][[:space:]]*/, "", body)
                    split(body, fields, /[[:space:]]+/)
                    print fields[1]
                    exit
                }
            }
        ' "${status_file}")
        printf 'delete-row %s\n' "${endpoint_spec}" >>"${FAKE_UFW_LOG}"
        awk -v idx="${target}" 'BEGIN { n = 0 } /^\[/ { n++; if (n == idx) next } { print }' \
            "${status_file}" >"${status_file}.new"
        mv -f -- "${status_file}.new" "${status_file}"
        return 0
    fi
    printf 'delete-row none\n' >>"${FAKE_UFW_LOG}"
    printf 'Could not delete non-existent rule\n' >&2
    return 1
}
case "${1:-}" in
status) render_status ;;
reload) exit 0 ;;
allow)
    printf '[ 1] %s/tcp                   ALLOW IN    Anywhere                   # easy_all-managed\n' \
        "${2%/tcp}" >>"${status_file}"
    ;;
--force)
    [[ "${2:-}" == "delete" ]] || exit 0
    insert_first_row
    if [[ "${3:-}" =~ ^[0-9]+$ ]]; then
        delete_row number "${3}" || exit 1
    else
        shift 2
        # 只接受实现真实使用的两种完整规格：少一个词就失败，避免桩把残缺规格当成有效删除。
        #   allow <port>/tcp comment <c>
        #   allow proto tcp from <cidr> to any port <port> comment <c>
        spec_endpoint="" spec_source="Anywhere" spec_comment=""
        if [[ "${1:-}" == "allow" && "${2:-}" == "proto" ]]; then
            [[ "${3:-}" == "tcp" && "${4:-}" == "from" && "${6:-}" == "to" \
                && "${7:-}" == "any" && "${8:-}" == "port" && "${10:-}" == "comment" ]] \
                || { printf 'invalid rule spec\n' >&2; exit 1; }
            spec_source=${5:-}
            spec_endpoint="${9%/tcp}/tcp"
            spec_comment=${11:-}
        elif [[ "${1:-}" == "allow" && "${3:-}" == "comment" ]]; then
            spec_endpoint="${2%/tcp}/tcp"
            spec_comment=${4:-}
        else
            printf 'invalid rule spec\n' >&2
            exit 1
        fi
        [[ -n "${spec_endpoint}" && -n "${spec_source}" && -n "${spec_comment}" ]] \
            || { printf 'invalid rule spec\n' >&2; exit 1; }
        delete_row spec "${spec_endpoint}" "${spec_source}" "${spec_comment}" || exit 1
    fi
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

# 11.1b 桩自身必须按完整规格定位：残缺规格要失败，否则「来源/动作生成错」的实现仍会假通过。
if PATH="${ufw_dir}:${PATH}" "${ufw_dir}/ufw" --force delete 443/tcp comment easy_all-managed \
    >/dev/null 2>&1; then
    fail "FAKE_UFW 必须拒绝缺失 allow 动作的删除规格"
fi
if PATH="${ufw_dir}:${PATH}" "${ufw_dir}/ufw" --force delete allow proto udp from 198.51.100.0/24 \
    to any port 443 comment easy_all-cf-origin >/dev/null 2>&1; then
    fail "FAKE_UFW 必须拒绝非 tcp 的删除规格"
fi

# 11.2a 删除期间插入首位规则（Fail2ban 的 `ufw insert 1`）不得误删 SSH 放行
# SSH 放行排在业务端口之后：按编号删除只要漂移一位就会命中 SSH 放行。
cat >"${FAKE_UFW_STATUS}" <<'FAKE_STATUS_DRIFT'
Status: active

To                         Action      From
--                         ------      ----
[ 1] Anywhere                   DENY IN     203.0.113.7                # easy_all-fail2ban-cidr
[ 2] 443/tcp                    ALLOW IN    Anywhere                   # easy_all-managed
[ 3] 2222/tcp                   ALLOW IN    Anywhere                   # easy_all-managed
[ 4] 8443/tcp                   ALLOW IN    Anywhere                   # easy_all-managed
[ 5] 8080/tcp                   ALLOW IN    Anywhere                   # debian-init-managed
FAKE_STATUS_DRIFT
: >"${FAKE_UFW_LOG}"
rm -f -- "${TMP_DIR}/ufw-insert-counter"
(
    export PATH="${ufw_dir}:${PATH}"
    export FAKE_UFW_INSERT_BEFORE_DELETE=1
    export FAKE_UFW_INSERT_COUNTER="${TMP_DIR}/ufw-insert-counter"
    reclaim_ufw_business_rules
) || fail "删除期间插入首位规则时回收不应失败"
drift_status=$(<"${FAKE_UFW_STATUS}")
drift_log=$(<"${FAKE_UFW_LOG}")
assert_contains "编号漂移后仍保留 SSH 2222 放行" "${drift_status}" "2222/tcp"
assert_not_contains "编号漂移后回收不得删除 SSH 放行" "${drift_log}" "delete-row 2222/tcp"
assert_not_contains "编号漂移后仍删除业务端口 443" "${drift_status}" "443/tcp"
assert_not_contains "编号漂移后仍删除业务端口 8443" "${drift_status}" "8443/tcp"
assert_equal "删除期间插入的 Fail2ban 封禁规则全部保留" "3" \
    "$(grep -c 'easy_all-fail2ban-cidr' <<<"${drift_status}")"
assert_contains "编号漂移后不碰初始化的额外端口" "${drift_status}" "8080/tcp"

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

# 11.3 卸载保留 Fail2ban 配置与运行状态，不回收常驻安全基线
f2b_dir="${TMP_DIR}/f2b"
install -d -m 0700 "${f2b_dir}/jail.d" "${f2b_dir}/action.d" "${f2b_dir}/sbin" \
    "${f2b_dir}/backups" "${f2b_dir}/bin" "${f2b_dir}/ssh"
export EASY_ALL_FAIL2BAN_CONFIG="${f2b_dir}/jail.d/99-easy-all-sshd.local"
export EASY_ALL_FAIL2BAN_ACTION_CONFIG="${f2b_dir}/action.d/easy-all-ufw-cidr.conf"
export EASY_ALL_FAIL2BAN_CIDR_HELPER="${f2b_dir}/sbin/fail2ban-ufw-cidr.sh"
export EASY_ALL_FAIL2BAN_CIDR_STATE_DIR="${f2b_dir}/state"
export EASY_ALL_SSH_PORT_CONFIG="${f2b_dir}/ssh/00-easy-all-ports.conf"
export BACKUP_DIR="${f2b_dir}/backups"
printf 'MANAGED-JAIL\n' >"${EASY_ALL_FAIL2BAN_CONFIG}"
printf 'PREINSTALL-JAIL\n' >"${BACKUP_DIR}/pre-install-fail2ban-jail.conf"
printf 'managed-helper\n' >"${EASY_ALL_FAIL2BAN_CIDR_HELPER}"
chmod 0755 "${EASY_ALL_FAIL2BAN_CIDR_HELPER}"
write_fail2ban_cidr_action_config "${EASY_ALL_FAIL2BAN_ACTION_CONFIG}"
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
assert_equal "卸载保留 Fail2ban helper" "managed-helper" \
    "$(<"${EASY_ALL_FAIL2BAN_CIDR_HELPER}")"
assert_contains "action 配置指向系统 helper" \
    "$(<"${EASY_ALL_FAIL2BAN_ACTION_CONFIG}")" "${EASY_ALL_FAIL2BAN_CIDR_HELPER}"
assert_not_contains "卸载不禁用 Fail2ban" \
    "$(<"${f2b_dir}/systemctl.log")" "disable fail2ban"

# 11.4 移除 UFW 规则区块不得留下 .bak 垃圾文件
block_file="${TMP_DIR}/before.rules"
printf '%s\n' 'keep-1' '# easy_all-test-start' 'drop-me' '# easy_all-test-end' 'keep-2' \
    >"${block_file}"
chmod 0600 "${block_file}"
remove_ufw_managed_block "${block_file}" '# easy_all-test-start' '# easy_all-test-end' \
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
reality_uninstall_body=$(awk '/^uninstall_all\(\)/,/^}/' "${ROOT_DIR}/profiles/reality.sh")
assert_contains "profiles/reality.sh 卸载回收业务端口" \
    "${reality_uninstall_body}" "restore_preinstall_firewall"
assert_not_contains "profiles/reality.sh 卸载不带旧的回滚参数" \
    "${reality_uninstall_body}" "restore_preinstall_firewall 1"
cdn_local_uninstall_body=$(awk '/^cdn_local_uninstall_common\(\)/,/^}/' \
    "${ROOT_DIR}/lib/cloudfront-mode.sh")
assert_contains "CloudFront 卸载回收业务端口" \
    "${cdn_local_uninstall_body}" "restore_preinstall_firewall"
assert_not_contains "CloudFront 卸载不带旧的回滚参数" \
    "${cdn_local_uninstall_body}" "restore_preinstall_firewall 1"
rollback_body=$(awk '/^rollback_fresh_install\(\)/,/^}/' "${ROOT_DIR}/profiles/reality.sh")
assert_not_contains "reality 回滚不关闭 UFW" "${rollback_body}" "ufw --force disable"

# 11.6 debian-init 模块 URL 必须跟随分支
assert_contains "debian-init 模块 URL 跟随 EASY_ALL_BRANCH" \
    "$(<"${ROOT_DIR}/scripts/debian-init.sh")" \
    'easy_all/${EASY_ALL_BRANCH}/lib/platform.sh'

# 11.7 内核 ipv6.disable=1（没有 /proc/sys/net/ipv6）时不得把 net.ipv6.* 写进 sysctl 文件：
#      sysctl -p 会失败，而远端初始化脚本带 set -e，直接终止在半安装状态。
awk '/^configure_tcp_tuning\(\) \{/,/^\}/' "${ROOT_DIR}/scripts/debian-init.sh" \
    >"${TMP_DIR}/tcp-tuning-fn.sh"
[[ -s "${TMP_DIR}/tcp-tuning-fn.sh" ]] || fail "无法从 debian-init.sh 提取 configure_tcp_tuning"
cat >"${TMP_DIR}/tcp-tuning-run.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
log() { :; }
source "$1"
configure_tcp_tuning
EOF
mkdir -p "${TMP_DIR}/tcp-tuning-bin" "${TMP_DIR}/proc-ipv6-present"
cat >"${TMP_DIR}/tcp-tuning-bin/sysctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${TCP_TUNING_LOG}"
EOF
chmod +x "${TMP_DIR}/tcp-tuning-bin/sysctl"
run_tcp_tuning() {
    local conf=$1 proc_dir=$2
    TCP_TUNING_LOG="${TMP_DIR}/tcp-tuning.log" \
        sysctl_config="${conf}" \
        EASY_ALL_PROC_IPV6_DIR="${proc_dir}" \
        PATH="${TMP_DIR}/tcp-tuning-bin:${PATH}" \
        bash "${TMP_DIR}/tcp-tuning-run.sh" "${TMP_DIR}/tcp-tuning-fn.sh"
}
: >"${TMP_DIR}/tcp-tuning.log"
run_tcp_tuning "${TMP_DIR}/sysctl-no-ipv6.conf" "${TMP_DIR}/proc-ipv6-absent" \
    || fail "没有 /proc/sys/net/ipv6 时 configure_tcp_tuning 必须正常结束"
assert_not_contains "没有 ipv6 proc 时不写 net.ipv6" \
    "$(<"${TMP_DIR}/sysctl-no-ipv6.conf")" "net.ipv6"
assert_contains "没有 ipv6 proc 时仍写 IPv4 调优" \
    "$(<"${TMP_DIR}/sysctl-no-ipv6.conf")" "net.ipv4.tcp_mtu_probing = 1"
assert_contains "没有 ipv6 proc 时仍应用 sysctl" \
    "$(<"${TMP_DIR}/tcp-tuning.log")" "-p ${TMP_DIR}/sysctl-no-ipv6.conf"
run_tcp_tuning "${TMP_DIR}/sysctl-with-ipv6.conf" "${TMP_DIR}/proc-ipv6-present" \
    || fail "有 /proc/sys/net/ipv6 时 configure_tcp_tuning 必须正常结束"
assert_contains "有 ipv6 proc 时仍关闭 IPv6" \
    "$(<"${TMP_DIR}/sysctl-with-ipv6.conf")" "net.ipv6.conf.all.disable_ipv6 = 1"


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
for profile in profiles/reality.sh lib/cloudfront-mode.sh; do
    body=$(awk '/^(install_all|run_reality_install_pipeline)\(\)/,/^}/' "${ROOT_DIR}/${profile}")
    assert_contains "${profile} 初始化阶段输出状态" "${body}" "report_host_init_state"
done


echo "=== 13. 模式菜单与回滚残留 ==="
mode_body=$(awk '/^choose_install_mode\(\)/,/^}/' "${ROOT_DIR}/easy_all")
assert_contains "菜单序号 1 映射到直连 Reality" "${mode_body}" "1) printf 'reality\\n' ;;"
assert_contains "菜单序号 2 映射到纯 CDN（CloudFront）" "${mode_body}" "2) printf 'cloudfront\\n' ;;"
assert_contains "菜单序号 3 映射到纯 CloudFlare" "${mode_body}" "3) printf 'cloudflare\\n' ;;"
assert_contains "菜单序号 4 映射到直连+CloudFront" "${mode_body}" "4) printf 'combined\\n' ;;"
assert_contains "菜单序号 5 映射到直连+CloudFlare" "${mode_body}" "5) printf 'combined-cloudflare\\n' ;;"
assert_not_contains "菜单不再使用已移除的历史标识" "${mode_body}" "cloudflare-streamup"
launcher_body=$(<"${ROOT_DIR}/easy_all")
assert_contains "状态识别接受新 CloudFront 协议" "${launcher_body}" "combined-cloudfront"
assert_contains "profile_file 注册 CloudFront" "${launcher_body}" "profiles/cloudfront.sh"
assert_contains "manifest 登记 CloudFront profile" "$(<"${ROOT_DIR}/runtime.manifest")" "profiles/cloudfront.sh"
assert_contains "manifest 登记 CloudFront 共享核心" "$(<"${ROOT_DIR}/runtime.manifest")" "lib/cloudfront-mode.sh"
assert_contains "manifest 登记 Cloudflare 橙云共享层" "$(<"${ROOT_DIR}/runtime.manifest")" "lib/cloudflare-mode.sh"
assert_contains "manifest 登记 Cloudflare 状态字段库" "$(<"${ROOT_DIR}/runtime.manifest")" "lib/cloudflare-state.sh"
assert_contains "无效序号提示模式不支持" "${mode_body}" "不支持的安装模式"

rollback_body=$(awk '/^rollback_subscription_update\(\)/,/^}/' "${ROOT_DIR}/lib/xhttp-runtime.sh")
assert_not_contains "共享回滚不再处理 Cloudflare Origin CA（模式 1 自带实现）" \
    "${rollback_body}" "CLOUDFLARE_CREATED_ORIGIN_CERT_ID"
# 模式 1 必须继续在回滚时吊销本次新签的证书（state.env 恢复后只剩旧证书 ID，不删即孤儿）。
reality_update_rollback_body=$(awk '/^rollback_subscription_update\(\)/,/^}/' "${ROOT_DIR}/profiles/reality.sh")
assert_contains "Reality 回滚时仍能识别本进程新签的证书 ID" \
    "${reality_update_rollback_body}" "CLOUDFLARE_CREATED_ORIGIN_CERT_ID"
# 签发成功不置位就会让两条回滚分支静默漏删。
issue_body=$(awk '/^cloudflare_issue_origin_certificate\(\)/,/^}/' "${ROOT_DIR}/lib/cf-dns.sh")
assert_contains "签发成功记录本次新建的 Origin CA 证书 ID" "${issue_body}" \
    'CLOUDFLARE_CREATED_ORIGIN_CERT_ID=${CLOUDFLARE_ORIGIN_CERT_ID}'
assert_not_contains "已删除的 Provider 回滚钩子不再被引用" "${rollback_body}" "rollback_provider_subscription_update"
assert_not_contains "Bunny 时代的 disable_ufw_ipv6 已删除" "$(<"${ROOT_DIR}/lib/firewall.sh")" "disable_ufw_ipv6"
assert_not_contains "manifest 不再登记已删除的优选实现" \
    "$(<"${ROOT_DIR}/runtime.manifest")" "lib/cloudflare-ip-pool.sh"
[[ ! -e "${ROOT_DIR}/lib/cloudflare-ip-pool.sh" ]] || fail "lib/cloudflare-ip-pool.sh 必须删除"


echo "=== 14. renew-cert 入口与事务顺序 ==="
renew_body=$(awk '/^renew_certificate\(\)/,/^}/' "${ROOT_DIR}/lib/cloudfront-mode.sh")
for token in require_root acquire_runtime_write_lock collect_installed_state \
    cdn_verify_origin_certificate save_state release_runtime_write_lock; do
    assert_contains "CloudFront renew_certificate 含 ${token}" "${renew_body}" "${token}"
done
# 证书部署必须走事务函数（先验证候选、失败恢复现用证书与 Nginx 配置），
# 而不是直接覆盖证书文件；否则 reload 失败就会留下半部署。
assert_contains "CloudFront renew-cert 通过部署事务安装证书" "${renew_body}" \
    "cdn_install_origin_lineage"
assert_contains "CloudFront renew-cert 先校验现用证书" "${renew_body}" \
    "cdn_verify_origin_certificate"
assert_before "CloudFront renew-cert 先 reload 再 save_state" \
    "${renew_body}" "systemctl reload nginx" "save_state"
assert_before "CloudFront renew-cert 部署完成才 save_state" \
    "${renew_body}" "cdn_install_origin_lineage" "save_state"
assert_contains "CloudFront renew-cert 只续源站 LE 证书" "${renew_body}" \
    "cdn_run_certbot 1"
assert_contains "CloudFront renew-cert 部署事务自带失败回滚" \
    "$(awk '/^cdn_install_origin_lineage\(\)/,/^}/' "${ROOT_DIR}/lib/cloudfront-mode.sh")" \
    "恢复部署前的现用证书、私钥与 Nginx 配置"
# apply / apply-cloud 成功前必须注册命令并（重新）安装并校验保护定时器。
for entry in apply_easy_all apply_cloud_resources; do
    entry_body=$(awk "/^${entry}\(\)/,/^}/" "${ROOT_DIR}/lib/cloudfront-mode.sh")
    assert_contains "${entry} 成功前提交本机运行时" "${entry_body}" "cdn_commit_local_runtime"
    assert_before "${entry} 先提交运行时再报告成功" \
        "${entry_body}" "cdn_commit_local_runtime" "success "
done
commit_body=$(awk '/^cdn_commit_local_runtime\(\)/,/^}/' "${ROOT_DIR}/lib/cloudfront-mode.sh")
assert_contains "提交运行时注册命令" "${commit_body}" "register_easy_all_command"
assert_contains "提交运行时安装保护定时器" "${commit_body}" \
    "install_cdn_traffic_protection_timer"
assert_contains "安装定时器后断言 active" \
    "$(awk '/^install_cdn_traffic_protection_timer\(\)/,/^}/' "${ROOT_DIR}/lib/cdn-traffic-guard.sh")" \
    'systemctl is-active --quiet "${CDN_TRAFFIC_GUARD_TIMER}"'
assert_not_contains "CloudFront renew-cert 不重新申请 ACM" "${renew_body}" "request-certificate"
assert_not_contains "CloudFront renew-cert 不触 AWS" "${renew_body}" "aws_cli"
# 待落实阻断时证书修复必须先保持 deny，再走统一受限恢复
renew_restricted_body=${renew_body%%"cdn_traffic_recover_restricted_runtime"*}
assert_contains "renew-cert 在受限恢复前先写 503 Nginx" \
    "${renew_restricted_body}" "write_nginx_config 1"

reality_renew_body=$(awk '/^renew_subscription_certificate\(\)/,/^}/' "${ROOT_DIR}/profiles/reality.sh")
for token in acquire_runtime_write_lock snapshot_subscription_update release_runtime_write_lock; do
    assert_contains "Reality renew-cert 含 ${token}" "${reality_renew_body}" "${token}"
done
assert_before "Reality renew-cert 先 reload 再 save_state" \
    "${reality_renew_body}" "systemctl reload nginx" "save_state"
assert_before "Reality renew-cert 先关闭回滚再吊销旧证书" \
    "${reality_renew_body}" "UPDATE_SUB_ROLLBACK_ON_EXIT=0" "cloudflare_finalize_certificate_rotation"

# edit-sub 的收尾阶段（save_state / 动态端口定时器）失败不能回滚：finalize 已不可逆地吊销旧证书，
# 回滚会恢复已吊销的旧证书，并连同刚生效的新证书一起删掉。
reality_update_body=$(awk '/^update_subscription\(\)/,/^}/' "${ROOT_DIR}/profiles/reality.sh")
assert_contains "Reality edit-sub 在吊销旧证书前关闭回滚" \
    "${reality_update_body%%cloudflare_finalize_certificate_rotation*}" \
    "UPDATE_SUB_ROLLBACK_ON_EXIT=0"
assert_not_contains "Reality edit-sub 吊销旧证书后不再回滚" \
    "${reality_update_body#*cloudflare_finalize_certificate_rotation}" \
    "UPDATE_SUB_ROLLBACK_ON_EXIT=0"

self_update_body=$(awk '/^unified_self_update\(\)/,/^}/' "${ROOT_DIR}/easy_all")
assert_before "self-update 先取写锁再注册命令" \
    "${self_update_body}" "acquire_runtime_write_lock" "register-command"

zone_body=$(awk '/^cloudflare_lookup_parent_zone\(\)/,/^}/' "${ROOT_DIR}/lib/cf-dns.sh")
assert_contains "Zone 匹配双向忽略大小写" "${zone_body}" '($name|ascii_downcase)'

# 行为：renew-cert 入口必须加载已安装状态（曾经的回归：未加载状态在 set -u 下直接崩溃）
if [[ -e /etc/easy_all/state.env ]]; then
    echo "skip - 本机已安装 easy_all，跳过 renew-cert 未安装路径校验"
else
    # 用独立 bash 进程跑：测试前面已经 source 过部分 lib，重复 source 会撞 readonly 变量。
    renew_probe=$(bash -c '
        set -Eeuo pipefail
        ROOT_DIR=$1
        TMP_DIR=$2
        export EASY_ALL_POLICY_STATE_DIR_OVERRIDE="${TMP_DIR}/policy-state"
        export EASY_ALL_POLICY_RC_OVERRIDE="${TMP_DIR}/policy-rc.d"
        mktemp() {
            case "$#" in
            0) command mktemp "${TMP_DIR}/file.XXXXXX" ;;
            1)
                if [[ "$1" == "-d" ]]; then
                    command mktemp -d "${TMP_DIR}/dir.XXXXXX"
                else
                    command mktemp "$@"
                fi
                ;;
            *) command mktemp "$@" ;;
            esac
        }
        # shellcheck source=/dev/null
        source "${ROOT_DIR}/profiles/combined.sh" >/dev/null \
            || { printf "PROFILE_SOURCE_FAILED\\n"; exit 3; }
        require_root() { :; }
        acquire_runtime_write_lock() { :; }
        snapshot_subscription_update() { :; }
        commit_subscription_update() { :; }
        set +e
        out=$( (EASY_ALL_STATE_FILE_OVERRIDE="${TMP_DIR}/absent-state.env" renew_certificate) 2>&1 )
        rc=$?
        printf "RC=%s\\n%s\\n" "${rc}" "${out}"
    ' _ "${ROOT_DIR}" "${TMP_DIR}" 2>&1) || true
    assert_not_contains "renew-cert 入口能够加载 profile" "${renew_probe}" "PROFILE_SOURCE_FAILED"
    assert_not_contains "renew-cert 不得因未加载状态崩溃" "${renew_probe}" "unbound variable"
    assert_contains "renew-cert 先加载安装状态" "${renew_probe}" "尚未安装"
    assert_contains "renew-cert 在未安装时报错退出" "${renew_probe}" "RC=1"
fi


echo "=== 15. SSH 加固后必须重载运行中的 sshd；root 初始用户不得依赖尚未安装的 sudo ==="
# 远端脚本在 root + 真实 systemd 环境里运行，这里只抽取单个函数用可执行桩验证行为。
REMOTE_BODY="${TMP_DIR}/debian-init-remote.sh"
awk -v start="<<'REMOTE'" '
    index($0, start) { inside = 1; next }
    inside && $0 == "REMOTE" { exit }
    inside { print }
' "${ROOT_DIR}/scripts/debian-init.sh" >"${REMOTE_BODY}"
bash -n "${REMOTE_BODY}" || fail "远端初始化脚本必须是合法 bash"
remote_body=$(<"${REMOTE_BODY}")
assert_contains "SSH 加固配置在 UFW/Fail2ban 之后重载" "${remote_body}" \
    $'ensure_ssh_fail2ban\napply_ssh_hardening_runtime'
assert_not_contains "reload 失败不得回退 restart（会断开当前会话）" \
    "${remote_body}" "systemctl restart"

hardening_fn=$(awk '/^apply_ssh_hardening_runtime\(\) \{/,/^\}/' "${REMOTE_BODY}")
[[ -n "${hardening_fn}" ]] || fail "远端脚本必须定义 apply_ssh_hardening_runtime"

SSH_PROBE_BIN="${TMP_DIR}/ssh-probe-bin"
install -d -m 0700 "${SSH_PROBE_BIN}"
cat >"${SSH_PROBE_BIN}/sshd" <<'FAKE_SSHD'
#!/usr/bin/env bash
[[ "${1:-}" == "-T" ]] || exit 1
cat "${FAKE_SSHD_T_OUTPUT:?}"
FAKE_SSHD
cat >"${SSH_PROBE_BIN}/systemctl" <<'FAKE_SYSTEMCTL'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"${FAKE_SYSTEMCTL_LOG:?}"
case "${1:-}" in
cat) [[ "${2:-}" == "ssh.service" ]] ;;
is-active) [[ "${FAKE_SSH_UNIT_ACTIVE:-1}" == "1" ]] ;;
reload)
    if [[ "${FAKE_SYSTEMCTL_RELOAD_FAIL:-0}" == "1" ]]; then
        printf 'Job for ssh.service failed: injected\n' >&2
        exit 1
    fi
    ;;
esac
FAKE_SYSTEMCTL
chmod +x "${SSH_PROBE_BIN}/sshd" "${SSH_PROBE_BIN}/systemctl"

FAKE_SSHD_T_OUTPUT="${TMP_DIR}/sshd-T.conf"
FAKE_SYSTEMCTL_LOG="${TMP_DIR}/systemctl.log"
export FAKE_SSHD_T_OUTPUT FAKE_SYSTEMCTL_LOG SSH_HARDENING_FN="${hardening_fn}"
run_ssh_hardening_probe() {
    PATH="${SSH_PROBE_BIN}:${PATH}" bash -c '
        set -Eeuo pipefail
        log() { printf "%s\n" "$*"; }
        die() { printf "错误: %s\n" "$*" >&2; exit 1; }
        sshd_bin=sshd
        config_dir=/etc/ssh/sshd_config.d
        config_file="${config_dir}/00-debian-init-hardening.conf"
        eval "${SSH_HARDENING_FN}"
        apply_ssh_hardening_runtime
    '
}

cat >"${FAKE_SSHD_T_OUTPUT}" <<'EOF'
port 22
passwordauthentication no
kbdinteractiveauthentication no
pubkeyauthentication yes
EOF
: >"${FAKE_SYSTEMCTL_LOG}"
reload_out=$(run_ssh_hardening_probe 2>&1) || fail "有效加固配置下必须重载成功"
assert_contains "重载成功留下可见日志" "${reload_out}" "已重载"
assert_contains "对运行中的 ssh 单元执行 reload" "$(<"${FAKE_SYSTEMCTL_LOG}")" \
    "systemctl reload ssh.service"

# 其他配置片段覆盖片段值时（有效配置仍是密码登录）必须终止，而不是“文件已写就算成功”。
cat >"${FAKE_SSHD_T_OUTPUT}" <<'EOF'
port 22
passwordauthentication yes
kbdinteractiveauthentication no
pubkeyauthentication yes
EOF
if overridden_out=$(run_ssh_hardening_probe 2>&1); then
    fail "有效配置仍允许密码登录时必须终止"
fi
assert_contains "被覆盖时指出具体配置项" "${overridden_out}" "passwordauthentication"

# reload 失败必须终止并保留 systemctl 原始输出（不得静默继续，也不得 restart）。
cat >"${FAKE_SSHD_T_OUTPUT}" <<'EOF'
port 22
passwordauthentication no
kbdinteractiveauthentication no
pubkeyauthentication yes
EOF
: >"${FAKE_SYSTEMCTL_LOG}"
if reload_failed_out=$(FAKE_SYSTEMCTL_RELOAD_FAIL=1 run_ssh_hardening_probe 2>&1); then
    fail "reload 失败时必须终止"
fi
assert_contains "reload 失败保留 systemctl 输出" "${reload_failed_out}" "injected"
assert_not_contains "reload 失败不得回退 restart" "$(<"${FAKE_SYSTEMCTL_LOG}")" "restart"

# S2：root 初始用户直接执行远端脚本（sudo 要到远端第 2 步才安装）；非 root 保留 sudo 提权。
INIT_UNDER_TEST="${TMP_DIR}/debian-init-under-test.sh"
awk '$0 != "main \"$@\""' "${ROOT_DIR}/scripts/debian-init.sh" >"${INIT_UNDER_TEST}"
bash -n "${INIT_UNDER_TEST}" || fail "去掉 main 后的 debian-init 必须语法正确"
SSH_CALL_LOG="${TMP_DIR}/debian-init-ssh.log"
export SSH_CALL_LOG INIT_UNDER_TEST
run_debian_init_remote() {
    bash -c '
        set -Eeuo pipefail
        ssh() {
            printf "%s\n" "$*" >>"${SSH_CALL_LOG}"
            case "$*" in
            *easy_all_init.XXXXXXXX*) printf "/tmp/easy_all_init.PROBE\n" ;;
            esac
        }
        scp() { return 0; }
        mktemp() { command mktemp "${TMPDIR:-/tmp}/init-probe.XXXXXX"; }
        SERVER_PASSWORD=""
        PLATFORM_MODULE_FILE=/dev/null
        FIREWALL_MODULE_FILE=/dev/null
        # shellcheck source=/dev/null
        source "${INIT_UNDER_TEST}"
        run_remote_initialization "$1" 22 22 normaluser normalpass /dev/null "" /dev/null /dev/null
    ' _ "$1"
}
: >"${SSH_CALL_LOG}"
run_debian_init_remote "root@198.51.100.10" || fail "以 root 初始化时远端命令必须能生成"
root_call_log=$(<"${SSH_CALL_LOG}")
assert_contains "root 初始用户直接执行远端脚本" "${root_call_log}" \
    "bash '/tmp/easy_all_init.PROBE/setup_debian_ssh_key_only.sh'"
assert_not_contains "root 初始用户不得加 sudo 前缀（精简系统没有 sudo）" "${root_call_log}" "sudo"
: >"${SSH_CALL_LOG}"
run_debian_init_remote "debian@198.51.100.10" || fail "以普通用户初始化时远端命令必须能生成"
assert_contains "非 root 初始用户保留 sudo 提权" "$(<"${SSH_CALL_LOG}")" \
    "sudo bash '/tmp/easy_all_init.PROBE/setup_debian_ssh_key_only.sh'"

echo "=== 16. Skyline 失败必须带阶段与退出码终止（不得降级 BBR、不得误报成功） ==="
# 失败注入点：守护进程启动失败。其余步骤用桩跳过，只验证真实 configure_tcp_acceleration 的失败路径。
(
    require_supported_tcp_architecture() { :; }
    check_skyline_requirements() { :; }
    install_skyline_speeder() { :; }
    stop_skyline_speeder() { :; }
    configure_tcp_parameters() { :; }
    skyline_prepare_log() { :; }
    skyline_runtime_diagnostics() { printf 'diag-called\n' >&2; }
    skyline_speeder_active() { return 1; }
    running_kernel_supported() { return 0; }
    dpkg() { return 0; }
    getconf() { printf 'glibc 2.36\n'; }
    skyline-speederd() { printf 'skyline-speederd 0.5.1\n'; }
    systemctl() { return 1; }
    sysctl() { return 0; }
    SYSTEMD_SYSTEM_DIR="${TMP_DIR}/skyline_systemd"
    install -d -m 0700 "${SYSTEMD_SYSTEM_DIR}" "${SKYLINE_SOURCE_DIR}"
    printf '%s\n' "${SKYLINE_COMMIT}" >"${SKYLINE_SOURCE_DIR}/.easy-all-installed"
    touch "${SYSTEMD_SYSTEM_DIR}/skyline-speederd.service" \
        "${SYSTEMD_SYSTEM_DIR}/skyline-speeder-enable.service"
    set +e
    skyline_out=$(configure_tcp_acceleration 2>&1)
    skyline_rc=$?
    set -e
    ((skyline_rc != 0)) || fail "守护进程启动失败时 configure_tcp_acceleration 必须返回非零"
    assert_contains "失败信息包含阶段" "${skyline_out}" "启动 Skyline Speeder 守护进程失败"
    assert_contains "失败信息包含命令退出码" "${skyline_out}" "退出码 1"
    assert_contains "失败信息包含诊断日志路径" "${skyline_out}" "/var/log/easy_all"
    assert_contains "失败前先取运行现场" "${skyline_out}" "diag-called"
    assert_not_contains "不得降级为 BBR" "${skyline_out}" "BBR"
    assert_not_contains "不得误报成功" "${skyline_out}" "Skyline Speeder 已启用"
)

echo "=== 17. 状态目录存在但读不到状态文件时必须提示 root，不得谎报「尚未安装」 ==="
# 公开入口：EASY_ALL_STATE_FILE_OVERRIDE 支持把状态文件指到任意路径（测试与自愈都靠它）。
run_launcher_status() {
    EASY_ALL_STATE_FILE_OVERRIDE="$1" bash "${ROOT_DIR}/easy_all" status 2>&1
}

absent_dir="${TMP_DIR}/absent-state-dir"
absent_rc=0
absent_out=$(run_launcher_status "${absent_dir}/state.env") || absent_rc=$?
assert_equal "未安装：状态目录不存在时退出码为 1" "1" "${absent_rc}"
assert_contains "未安装：状态目录不存在时仍报「尚未安装」" "${absent_out}" "尚未安装"

empty_dir="${TMP_DIR}/empty-state-dir"
install -d -m 0700 "${empty_dir}"
empty_rc=0
empty_out=$(run_launcher_status "${empty_dir}/state.env") || empty_rc=$?
assert_equal "未安装：目录可访问但没有状态文件时退出码为 1" "1" "${empty_rc}"
assert_contains "未安装：目录可访问但没有状态文件时报「尚未安装」" "${empty_out}" "尚未安装"

if [[ "$(id -u)" -eq 0 ]]; then
    echo "skip - root 无法模拟无权限状态目录"
else
    denied_dir="${TMP_DIR}/denied-state-dir"
    install -d -m 0700 "${denied_dir}"
    printf 'STATE_VERSION="0"\nPROTOCOL="cdn"\n' >"${denied_dir}/state.env"
    chmod 000 "${denied_dir}"
    denied_rc=0
    denied_out=$(run_launcher_status "${denied_dir}/state.env") || denied_rc=$?
    assert_equal "无权读取：状态目录不可读时退出码为 1" "1" "${denied_rc}"
    assert_contains "无权读取：给出 sudo easy_all <command> 指引" \
        "${denied_out}" "sudo easy_all status"
    assert_not_contains "无权读取：不得谎报「尚未安装」" "${denied_out}" "尚未安装"
    chmod 700 "${denied_dir}"

    denied_file_dir="${TMP_DIR}/denied-state-file"
    install -d -m 0755 "${denied_file_dir}"
    printf 'STATE_VERSION="0"\nPROTOCOL="cdn"\n' >"${denied_file_dir}/state.env"
    chmod 000 "${denied_file_dir}/state.env"
    denied_file_rc=0
    denied_file_out=$(run_launcher_status "${denied_file_dir}/state.env") || denied_file_rc=$?
    assert_equal "无权读取：状态文件不可读时退出码为 1" "1" "${denied_file_rc}"
    assert_contains "无权读取：状态文件不可读时同样提示 sudo" \
        "${denied_file_out}" "sudo easy_all status"
    chmod 600 "${denied_file_dir}/state.env"
fi

echo "=== 18. Swap 空间判定：df 取不到数字或为 0 时必须跳过创建（df -Pk） ==="
SWAP_FN=$(awk '/^ensure_swap\(\) \{/,/^\}/' "${ROOT_DIR}/lib/platform.sh")
[[ -n "${SWAP_FN}" ]] || fail "lib/platform.sh 必须定义 ensure_swap"
export SWAP_FN
run_swap_probe() {
    local mode=$1 root=$2
    install -d -m 0700 "${root}"
    SWAP_PROBE_LOG="${root}/probe.log"
    export SWAP_PROBE_LOG
    bash -c '
        set -Eeuo pipefail
        mode=$1
        root=$2
        warn() { printf "warn: %s\n" "$*" >&2; }
        info() { printf "info: %s\n" "$*" >&2; }
        success() { printf "success: %s\n" "$*" >&2; }
        die() { printf "die: %s\n" "$*" >&2; exit 1; }
        # S14 关键点：必须用 df -Pk（一个文件系统一行），且空/0 都不得放行 fallocate。
        df() {
            printf "df-args: %s\n" "$*" >>"${SWAP_PROBE_LOG}"
            case "${mode}" in
            empty) : ;;
            zero) printf "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sda1 1000000 1000000 0 100%% /\n" ;;
            ok) printf "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sda1 10000000 1000000 3000000 25%% /\n" ;;
            esac
        }
        fallocate() { printf "fallocate %s\n" "$*" >>"${SWAP_PROBE_LOG}"; printf "x" >"${root}/swapfile"; }
        dd() { printf "dd\n" >>"${SWAP_PROBE_LOG}"; }
        mkswap() { printf "mkswap\n" >>"${SWAP_PROBE_LOG}"; }
        swapon() { printf "swapon\n" >>"${SWAP_PROBE_LOG}"; }
        printf "SwapTotal:       0 kB\n" >"${root}/meminfo"
        : >"${root}/fstab"
        eval "${SWAP_FN}"
        EASY_ALL_SWAP_FILE="${root}/swapfile" \
            EASY_ALL_MEMINFO_FILE="${root}/meminfo" \
            EASY_ALL_FSTAB_FILE="${root}/fstab" \
            ensure_swap
    ' _ "${mode}" "${root}"
}

empty_swap_out=$(run_swap_probe empty "${TMP_DIR}/swap-empty" 2>&1) \
    || fail "df 无输出时 ensure_swap 不得失败"
assert_contains "swap: df 取不到数字时提示无法确认" "${empty_swap_out}" "无法确认磁盘剩余空间"
assert_not_contains "swap: 无法确认时不得创建 Swap 文件" "${empty_swap_out}" "正在创建 1GB 交换文件"
[[ ! -e "${TMP_DIR}/swap-empty/swapfile" ]] || fail "swap: 无法确认时不得执行 fallocate"
assert_contains "swap: 用 df -Pk 取可用空间" "$(<"${TMP_DIR}/swap-empty/probe.log")" "df-args: -Pk "

zero_swap_out=$(run_swap_probe zero "${TMP_DIR}/swap-zero" 2>&1) \
    || fail "df 可用空间为 0 时 ensure_swap 不得失败"
assert_contains "swap: 可用空间为 0 时提示空间不足" "${zero_swap_out}" "磁盘已无可用空间"
assert_not_contains "swap: 可用空间为 0 时不得创建 Swap 文件" "${zero_swap_out}" "正在创建 1GB 交换文件"
[[ ! -e "${TMP_DIR}/swap-zero/swapfile" ]] || fail "swap: 可用空间为 0 时不得执行 fallocate"

ok_swap_out=$(run_swap_probe ok "${TMP_DIR}/swap-ok" 2>&1) \
    || fail "空间充足时 ensure_swap 必须创建 Swap"
assert_contains "swap: 空间充足时继续创建" "${ok_swap_out}" "已成功配置并启用 1GB Swap"
[[ -e "${TMP_DIR}/swap-ok/swapfile" ]] || fail "swap: 空间充足时必须执行 fallocate"

echo "=== 19. SSH/UFW 实参中的端口必须是规范十进制（080 → 80） ==="
port_probe=$(bash -c '
    set -Eeuo pipefail
    init_script=$1
    tmp=$2
    die() { printf "die: %s\n" "$*" >&2; exit 1; }
    ssh() {
        printf "%s\n" "$*" >>"${tmp}/port-ssh.log"
        case "$*" in
        *easy_all_init.XXXXXXXX*) printf "/tmp/easy_all_init.PROBE\n" ;;
        esac
    }
    scp() { return 0; }
    mktemp() { command mktemp "${tmp}/port-probe.XXXXXX"; }
    SERVER_PASSWORD=""
    PLATFORM_MODULE_FILE=/dev/null
    FIREWALL_MODULE_FILE=/dev/null
    # shellcheck source=/dev/null
    source "${init_script}"
    printf "norm-list=%s\n" "$(normalize_port_list "080,8080 00080")"
    printf "norm-port=%s\n" "$(normalize_port 080)"
    validate_port 080 && printf "validate-080=ok\n"
    set +e
    zero_out=$(validate_port 000 2>&1)
    zero_rc=$?
    big_out=$(validate_port 70000 2>&1)
    big_rc=$?
    set -e
    printf "zero=%s|%s\n" "${zero_rc}" "${zero_out}"
    printf "big=%s|%s\n" "${big_rc}" "${big_out}"
    SERVER_HOST="198.51.100.10"
    SERVER_USER=root
    NORMAL_USER=normaluser
    HOST_ALIAS=probe
    CHANGE_PORT=no
    CURRENT_PORT=0080
    FINAL_PORT=080
    EXTRA_TCP_PORTS="080 8080"
    validate_collected_inputs
    printf "normalized=%s|%s|%s\n" "${CURRENT_PORT}" "${FINAL_PORT}" "${EXTRA_TCP_PORTS}"
    run_remote_initialization "root@198.51.100.10" "${CURRENT_PORT}" "${FINAL_PORT}" \
        normaluser normalpass /dev/null "${EXTRA_TCP_PORTS}" /dev/null /dev/null >/dev/null
    printf "ssh-log=%s\n" "$(<"${tmp}/port-ssh.log")"
' _ "${INIT_UNDER_TEST}" "${TMP_DIR}") || fail "端口归一化探针执行失败"
assert_contains "port: 额外端口列表归一化为十进制" "${port_probe}" "norm-list=80 8080"
assert_contains "port: 单个端口归一化为十进制" "${port_probe}" "norm-port=80"
assert_contains "port: 前导零端口通过校验" "${port_probe}" "validate-080=ok"
assert_contains "port: 全零端口被判为范围错误" "${port_probe}" "1-65535"
assert_contains "port: 超范围端口被拒绝" "${port_probe}" "big=1|"
assert_contains "port: CURRENT_PORT/FINAL_PORT/额外端口都归一到十进制" \
    "${port_probe}" "normalized=80|80|80 8080"
assert_contains "port: ssh -p 使用规范端口" "${port_probe}" "-p 80 "
assert_contains "port: 远端实参使用规范端口" "${port_probe}" "'80' '80' 'normaluser'"
assert_contains "port: 远端 UFW 额外端口使用规范列表" "${port_probe}" "'80 8080'"

echo "=== 20. IPv4-only 策略文件走 mktemp，成功/失败都不留临时文件 ==="
IPV4ONLY_FN=$(awk '/^configure_ipv4_only\(\) \{/,/^\}/' "${ROOT_DIR}/lib/platform.sh")
[[ -n "${IPV4ONLY_FN}" ]] || fail "lib/platform.sh 必须定义 configure_ipv4_only"
export IPV4ONLY_FN
run_ipv4_probe() {
    local root=$1 mode=$2
    install -d -m 0700 "${root}"
    bash -c '
        set -Eeuo pipefail
        root=$1
        mode=$2
        die() { printf "die: %s\n" "$*" >&2; exit 1; }
        install() {
            printf "install %s\n" "$*" >>"${root}/probe.log"
            if [[ "${mode}" == "install-fail" && "$*" == *"0644"* ]]; then
                return 1
            fi
            command install "$@"
        }
        sysctl() { printf "sysctl %s\n" "$*" >>"${root}/probe.log"; return 0; }
        RUNTIME_TMP="${root}/runtime"
        IPV6_SYSCTL_CONF="${root}/sysctl/99-enable-ipv6.conf"
        EASY_ALL_PROC_IPV6_DIR="${root}/proc-ipv6"
        command install -d -m 0700 "${RUNTIME_TMP}" "${EASY_ALL_PROC_IPV6_DIR}" \
            "$(dirname "${IPV6_SYSCTL_CONF}")"
        eval "${IPV4ONLY_FN}"
        configure_ipv4_only
    ' _ "${root}" "${mode}"
}

ipv4_ok_root="${TMP_DIR}/ipv4-only-ok"
ipv4_ok_out=$(run_ipv4_probe "${ipv4_ok_root}" ok 2>&1) || fail "configure_ipv4_only 正常路径失败: ${ipv4_ok_out}"
assert_contains "ipv4-only: 目标文件按 0644 安装" "$(<"${ipv4_ok_root}/probe.log")" "install -m 0644 "
assert_contains "ipv4-only: 策略内容写全" "$(<"${ipv4_ok_root}/sysctl/99-enable-ipv6.conf")" \
    "net.ipv6.conf.all.disable_ipv6 = 1"
assert_equal "ipv4-only: 成功后不残留临时文件" "0" \
    "$(find "${ipv4_ok_root}/runtime" -maxdepth 1 -name 'enable-ipv6.*' | wc -l | tr -d ' ')"
assert_contains "ipv4-only: 成功后应用 sysctl" "$(<"${ipv4_ok_root}/probe.log")" "sysctl -p "

ipv4_fail_root="${TMP_DIR}/ipv4-only-fail"
ipv4_fail_rc=0
ipv4_fail_out=$(run_ipv4_probe "${ipv4_fail_root}" install-fail 2>&1) || ipv4_fail_rc=$?
((ipv4_fail_rc != 0)) || fail "install 失败时 configure_ipv4_only 必须终止"
assert_contains "ipv4-only: 失败保留诊断" "${ipv4_fail_out}" "写入 IPv4-only 策略文件失败"
assert_equal "ipv4-only: 失败后不残留临时文件" "0" \
    "$(find "${ipv4_fail_root}/runtime" -maxdepth 1 -name 'enable-ipv6.*' | wc -l | tr -d ' ')"

echo "=== 21. bootstrap.sh 仓库地址可覆盖，apt 调用显式非交互（含 sudo 路径） ==="
boot_dir="${TMP_DIR}/bootstrap"
install -d -m 0700 "${boot_dir}/bin"
for util in bash sh env cat rm chmod mkdir; do
    util_path=$(command -v "${util}") || fail "探针缺少 ${util}"
    ln -s "${util_path}" "${boot_dir}/bin/${util}"
done
# 固定以非 root 运行：id -u 永远返回 1000，才能稳定考察 sudo 路径。
cat >"${boot_dir}/bin/id" <<'FAKE_ID'
#!/usr/bin/env bash
[[ "${1:-}" == "-u" ]] && { printf '%s\n' "${FAKE_BOOTSTRAP_UID:-1000}"; exit 0; }
exit 0
FAKE_ID
printf '#!/usr/bin/env bash\nexit 0\n' >"${boot_dir}/bin/curl"
# macOS 的 mktemp 忽略 TMPDIR 且系统临时目录在受限环境下不可写：探针把无模板的 `mktemp -d`
# 固定到测试目录（仓库其他测试同样用「退回显式模板」）。
cat >"${boot_dir}/bin/mktemp" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "-d" && \$# -eq 1 ]]; then
    exec $(command -v mktemp) -d "${TMP_DIR}/bootstrap.XXXXXX"
fi
exec $(command -v mktemp) "\$@"
EOF
# sudo 要模拟真实行为：VAR=value 前缀作为环境变量后执行其余命令。
printf '%s\n' '#!/usr/bin/env bash' \
    'printf "sudo %s\\n" "$*" >>"${FAKE_BOOTSTRAP_LOG}"' \
    'while [[ "${1:-}" == *=* ]]; do export "$1"; shift; done' \
    'exec "$@"' >"${boot_dir}/bin/sudo"
# apt-get 只记录实参与其看到的 DEBIAN_FRONTEND，并在安装时同步提供 git。
cat >"${boot_dir}/bin/apt-get" <<'FAKE_APT'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'apt-get DEBIAN_FRONTEND=%s :: %s\n' "${DEBIAN_FRONTEND:-unset}" "$*" >>"${FAKE_BOOTSTRAP_LOG}"
[[ "$*" == *" install "* ]] || exit 0
cat >"${FAKE_BOOTSTRAP_BIN}/git" <<'FAKE_GIT'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'git %s\n' "$*" >>"${FAKE_BOOTSTRAP_LOG}"
[[ "${1:-}" == "clone" ]] || exit 0
dest=${!#}
mkdir -p "${dest}"
printf 'runtime-manifest\n' >"${dest}/runtime.manifest"
cat >"${dest}/easy_all" <<'STUB'
#!/usr/bin/env bash
printf 'easy_all %s\n' "$*" >>"${FAKE_BOOTSTRAP_LOG}"
STUB
chmod +x "${dest}/easy_all"
FAKE_GIT
chmod +x "${FAKE_BOOTSTRAP_BIN}/git"
FAKE_APT
chmod +x "${boot_dir}/bin/id" "${boot_dir}/bin/curl" "${boot_dir}/bin/sudo" \
    "${boot_dir}/bin/apt-get" "${boot_dir}/bin/mktemp"
bootstrap_log="${boot_dir}/bootstrap.log"
: >"${bootstrap_log}"
EASY_ALL_REPOSITORY_URL_OVERRIDE="https://example.test/fork/easy_all.git" \
    PATH="${boot_dir}/bin" FAKE_BOOTSTRAP_LOG="${bootstrap_log}" \
    FAKE_BOOTSTRAP_BIN="${boot_dir}/bin" \
    bash "${ROOT_DIR}/bootstrap.sh" install \
    || fail "bootstrap.sh 在 git/apt-get 桩环境下应能跑通"
bootstrap_calls=$(<"${bootstrap_log}")
assert_contains "bootstrap: 克隆地址取 EASY_ALL_REPOSITORY_URL_OVERRIDE" \
    "${bootstrap_calls}" "clone --depth 1 --branch main https://example.test/fork/easy_all.git"
assert_contains "bootstrap: sudo 路径把 DEBIAN_FRONTEND 作为 apt-get 实参" \
    "${bootstrap_calls}" "sudo env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 update"
assert_contains "bootstrap: apt-get install 实际收到 noninteractive" \
    "${bootstrap_calls}" \
    "apt-get DEBIAN_FRONTEND=noninteractive :: -o DPkg::Lock::Timeout=300 install -y --no-install-recommends git ca-certificates"
assert_contains "bootstrap: 默认仓库地址保持不变" "$(<"${ROOT_DIR}/bootstrap.sh")" \
    'readonly REPOSITORY_URL="${EASY_ALL_REPOSITORY_URL_OVERRIDE:-https://github.com/v2yiz/easy_all.git}"'

# root 分支：SUDO 为空数组，apt 仍必须真的执行（`VAR=值` 不能落在命令位置被当命令跑）。
# 第一次探针已由 apt 桩安装 git；root 分支要重新验证 apt，先移除。
rm -f -- "${boot_dir}/bin/git"
root_bootstrap_log="${boot_dir}/bootstrap-root.log"
: >"${root_bootstrap_log}"
FAKE_BOOTSTRAP_UID=0 EASY_ALL_REPOSITORY_URL_OVERRIDE="https://example.test/fork/easy_all.git" \
    PATH="${boot_dir}/bin" FAKE_BOOTSTRAP_LOG="${root_bootstrap_log}" \
    FAKE_BOOTSTRAP_BIN="${boot_dir}/bin" \
    bash "${ROOT_DIR}/bootstrap.sh" install \
    || fail "bootstrap.sh 在 root（无 sudo）分支下也必须跑通"
root_bootstrap_calls=$(<"${root_bootstrap_log}")
assert_contains "bootstrap(root): apt 实际执行并收到 noninteractive" \
    "${root_bootstrap_calls}" \
    "apt-get DEBIAN_FRONTEND=noninteractive :: -o DPkg::Lock::Timeout=300 update"
assert_not_contains "bootstrap(root): 不加 sudo 前缀" "${root_bootstrap_calls}" "sudo "
# 仓库克隆在 mktemp 目录（通常 /tmp）：/tmp 被挂 noexec 时直接执行脚本会 EACCES，
# 必须显式经 bash 执行（chmod 0700 只解决权限位，解决不了 noexec 挂载）。
assert_contains "bootstrap: 仓库脚本显式经 bash 执行" \
    "$(<"${ROOT_DIR}/bootstrap.sh")" 'bash "${REPO_DIR}/easy_all"'
assert_not_contains "bootstrap: 不再直接执行仓库脚本" \
    "$(<"${ROOT_DIR}/bootstrap.sh")" '"${SUDO[@]+"${SUDO[@]}"}" "${REPO_DIR}/easy_all"'
# 同一遗漏也在 easy_all self-update：克隆目录同样在 mktemp（/tmp）下。
update_body=$(awk '/^unified_self_update\(\)/,/^}/' "${ROOT_DIR}/easy_all")
[[ -n "${update_body}" ]] || fail "无法提取 unified_self_update"
assert_contains "self-update: verify-release 经 bash 执行" \
    "${update_body}" 'bash "${repo_dir}/easy_all" verify-release'
assert_contains "self-update: register-command 经 bash 执行" \
    "${update_body}" 'bash "${repo_dir}/easy_all" register-command'
assert_not_contains "self-update: 不直接执行克隆目录里的脚本" \
    "${update_body}" '^    "${repo_dir}/easy_all"'

echo "=== 22. Reality Short ID 只接受偶数位十六进制（1–8 对） ==="
short_id_probe() {
    local label=$1 short_id=$2 output
    output=$(bash "${REALITY_PORT_PROBE}" "${ROOT_DIR}" "${TMP_DIR}/short-id-${label}" 443 "${short_id}") \
        || fail "short id probe failed for ${label}"
    printf '%s\n' "${output}"
}
for valid_short_id in ab 0123456789abcdef; do
    valid_out=$(short_id_probe "valid-${valid_short_id}" "${valid_short_id}")
    assert_contains "short id: ${valid_short_id}（偶数位）通过" "${valid_out}" "rc=0"
done
for invalid_short_id in abc 0123456789abcdef00 zz11; do
    invalid_out=$(short_id_probe "invalid-${invalid_short_id}" "${invalid_short_id}")
    assert_not_contains "short id: ${invalid_short_id} 必须被拒绝" "${invalid_out}" "rc=0"
    assert_contains "short id: ${invalid_short_id} 报错说明偶数位" "${invalid_out}" "偶数位"
done

echo "=== 23. 定时重启：reboot 前非阻塞抢运行时写锁，抢不到只留痕 ==="
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/scheduled-maintenance.sh"
cron_dir="${TMP_DIR}/reboot-cron"
install -d -m 0700 "${cron_dir}/bin" "${cron_dir}/no-flock-bin"
cat >"${cron_dir}/bin/crontab" <<'FAKE_CRONTAB'
#!/usr/bin/env bash
set -Eeuo pipefail
state=${FAKE_CRONTAB_FILE:?}
case "${1:-}" in
-l)
    [[ -f "${state}" ]] || { printf 'no crontab for root\n' >&2; exit 1; }
    cat "${state}"
    ;;
-r) rm -f -- "${state}" ;;
*) cat >"${state}" ;;
esac
FAKE_CRONTAB
chmod +x "${cron_dir}/bin/crontab"
export FAKE_CRONTAB_FILE="${cron_dir}/root-crontab"
export CRON_REBOOT_MARKER="# easy_all-managed-reboot"
export RUNTIME_WRITE_LOCK_FILE="${cron_dir}/runtime-write.lock"
# 沙箱/CI 不一定有 util-linux flock：生成期只做 `command -v flock` 门禁，用函数桩满足。
flock() { :; }
printf '0 3 * * * /usr/local/bin/user-backup\n' >"${FAKE_CRONTAB_FILE}"
REBOOT_SCHEDULE_MODE=custom REBOOT_HOUR=5 \
    PATH="${cron_dir}/bin:${PATH}" configure_daily_reboot \
    || fail "configure_daily_reboot 应写入定时重启任务"
cron_line=$(grep -F "${CRON_REBOOT_MARKER}" "${FAKE_CRONTAB_FILE}" || true)
[[ -n "${cron_line}" ]] || fail "应写入一条受管定时重启行"
assert_contains "cron: 保留管理员自己的定时任务" "$(<"${FAKE_CRONTAB_FILE}")" "user-backup"
assert_contains "cron: 重启前非阻塞抢写锁" "${cron_line}" "flock -n 8"
assert_contains "cron: 锁路径取自 RUNTIME_WRITE_LOCK_FILE" \
    "${cron_line}" "exec 8>\"${RUNTIME_WRITE_LOCK_FILE}\""
assert_before "cron: 先抢锁再 reboot" "${cron_line}" "flock -n 8" "/usr/sbin/reboot"
# 锁必须在同一 shell 里持有到 reboot：子 shell 一退出就释放，等于没锁。
assert_not_contains "cron: 抢锁不得放在子 shell 里（否则 reboot 时锁已释放）" \
    "${cron_line}" "( exec 8>"
assert_contains "cron: 抢不到锁时 logger 留痕（固定文案）" \
    "${cron_line}" "logger -t easy_all 'easy_all 定时重启已跳过：运行时写锁不可用或正被占用'"
assert_not_contains "cron: reboot 不再无条件执行" "${cron_line}" ") && /usr/sbin/reboot"

# cron 把未转义的 % 当换行：预命令与新增的锁路径都必须被转义。
scheduled_reboot_profile_pre_command() { printf '/bin/echo 100%%'; }
RUNTIME_WRITE_LOCK_FILE="${cron_dir}/lock%probe" \
    REBOOT_SCHEDULE_MODE=custom REBOOT_HOUR=6 \
    PATH="${cron_dir}/bin:${PATH}" configure_daily_reboot \
    || fail "configure_daily_reboot 应接受带 % 的预命令与锁路径"
escaped_line=$(grep -F "${CRON_REBOOT_MARKER}" "${FAKE_CRONTAB_FILE}" || true)
assert_contains "cron: 预命令中的 % 被转义" "${escaped_line}" '100\%'
assert_not_contains "cron: 预命令不留裸 %" "${escaped_line}" '100%'
assert_contains "cron: 锁路径中的 % 被转义" "${escaped_line}" 'lock\%probe'
unset -f scheduled_reboot_profile_pre_command

# 缺 flock 时必须在生成任务前报错，而不是写一条将来静默不工作的任务。
crontab_before=$(<"${FAKE_CRONTAB_FILE}")
flock_missing_out=$( ( unset -f flock
    PATH="${cron_dir}/no-flock-bin" REBOOT_SCHEDULE_MODE=custom REBOOT_HOUR=7 \
        configure_daily_reboot ) 2>&1 ) && fail "缺少 flock 时 configure_daily_reboot 必须报错"
assert_contains "cron: 缺 flock 时明确报错" "${flock_missing_out}" "缺少 flock"
assert_equal "cron: 缺 flock 时不改写 crontab" "${crontab_before}" "$(<"${FAKE_CRONTAB_FILE}")"

echo "ok - all audit fixes verified successfully"

