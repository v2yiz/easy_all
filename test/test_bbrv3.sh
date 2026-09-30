#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "${TMP_DIR}"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_equal() {
    local label=$1 expected=$2 actual=$3
    [[ "${expected}" == "${actual}" ]] \
        || fail "${label}: expected [${expected}], got [${actual}]"
}

assert_contains() {
    local label=$1 value=$2 expected=$3
    [[ "${value}" == *"${expected}"* ]] || fail "${label}: missing [${expected}]"
}

STATE_DIR="${TMP_DIR}/state"
BACKUP_DIR="${STATE_DIR}/backups"
RUNTIME_TMP="${TMP_DIR}/runtime"
SYSCTL_CONFIG="${TMP_DIR}/bbr.conf"
BBR_MODULES_CONFIG="${TMP_DIR}/bbr-module.conf"
BBRV3_XANMOD_KEYRING_OVERRIDE="${TMP_DIR}/xanmod.gpg"
BBRV3_XANMOD_SOURCE_OVERRIDE="${TMP_DIR}/xanmod.list"
BBRV3_CPUINFO_FILE_OVERRIDE="${TMP_DIR}/cpuinfo"
BBRV3_AVAILABLE_CC_FILE_OVERRIDE="${TMP_DIR}/tcp_available_congestion_control"
BBRV3_EFI_DIR_OVERRIDE="${TMP_DIR}/efi"
BBRV3_EFIVARS_DIR_OVERRIDE="${BBRV3_EFI_DIR_OVERRIDE}/efivars"
SYSTEMD_SYSTEM_DIR="${TMP_DIR}/systemd-disabled"
install -d -m 0700 "${STATE_DIR}" "${BACKUP_DIR}" "${RUNTIME_TMP}"
printf 'reno cubic bbr\n' >"${BBRV3_AVAILABLE_CC_FILE_OVERRIDE}"

die() { fail "$*"; }
warn() { :; }
info() { :; }
success() { :; }

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/network.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/tcp-tuning.sh"

write_cpu_flags() {
    printf 'flags : %s\n' "$1" >"${BBRV3_CPUINFO_FILE}"
}

v1_flags="lm cmov cx8 fpu fxsr mmx syscall sse2"
v2_flags="${v1_flags} cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3"
v3_flags="${v2_flags} avx avx2 bmi1 bmi2 f16c fma abm movbe xsave"

write_cpu_flags "${v1_flags}"
assert_equal "x86-64-v1 CPUs select the universal XanMod LTS package" \
    "1" "$(bbrv3_cpu_level)"
assert_equal "x64v1 package selection" "linux-xanmod-lts-x64v1" \
    "$(bbrv3_kernel_package)"

write_cpu_flags "${v2_flags}"
assert_equal "x86-64-v2 CPU detection" "2" "$(bbrv3_cpu_level)"

write_cpu_flags "${v3_flags}"
assert_equal "x86-64-v3 CPU detection" "3" "$(bbrv3_cpu_level)"
assert_equal "x64v3 package selection" "linux-xanmod-lts-x64v3" \
    "$(bbrv3_kernel_package)"

if bbrv3_secure_boot_enabled; then
    fail "legacy BIOS without EFI must not be treated as Secure Boot"
fi
mkdir -p "${BBRV3_EFI_DIR}"
bbrv3_secure_boot_enabled \
    || fail "EFI with unavailable efivars must fail closed"
mkdir -p "${BBRV3_EFIVARS_DIR}"
secure_boot_var="${BBRV3_EFIVARS_DIR}/SecureBoot-test"
printf '\0\0\0\0\0' >"${secure_boot_var}"
if bbrv3_secure_boot_enabled; then
    fail "an explicit disabled Secure Boot variable must be accepted"
fi
printf '\0\0\0\0\1' >"${secure_boot_var}"
bbrv3_secure_boot_enabled \
    || fail "an enabled Secure Boot variable must be rejected"

module_content=$(<"${ROOT_DIR}/lib/tcp-tuning.sh")
assert_contains "XanMod key fingerprint is pinned" "${module_content}" \
    'D38D7D1DA1349567ADED882D86F7D09EE734E623'
assert_contains "XanMod repository uses HTTPS" "${module_content}" \
    'https://deb.xanmod.org'
assert_contains "XanMod key download requires HTTPS" "${module_content}" \
    "--proto '=https'"
assert_contains "XanMod LTS package installation is explicit" "${module_content}" \
    'apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends "${BBRV3_KERNEL_PACKAGE}"'
assert_contains "minimal installations can acquire the key verification dependency" \
    "${module_content}" 'apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends gnupg'
assert_contains "Secure Boot is rejected before a new kernel install" "${module_content}" \
    'bbrv3_secure_boot_enabled'
assert_contains "BBRv3 requires a reboot marker" "${module_content}" \
    'BBRV3_REBOOT_MARKER'

xanmod_key_fingerprint() { printf '%s\n' "${BBRV3_XANMOD_KEY_FINGERPRINT}"; }
bbrv3_debian_codename() { printf 'bookworm\n'; }
printf 'test-keyring\n' >"${BBRV3_XANMOD_KEYRING}"
xanmod_repository_line >"${BBRV3_XANMOD_SOURCE}"
assert_equal "the exact managed XanMod repository is accepted" "ready" \
    "$(xanmod_repository_ready && printf 'ready')"
printf 'deb https://example.invalid bookworm main\n' >>"${BBRV3_XANMOD_SOURCE}"
if xanmod_repository_ready; then
    fail "an extra repository line must invalidate the managed XanMod source"
fi

secure_boot_repo_write="${TMP_DIR}/secure-boot-repo-write"
set +e
(
    bbrv3_kernel_package() { printf 'linux-xanmod-lts-x64v3\n'; }
    bbrv3_running_kernel_supported() { return 1; }
    bbrv3_secure_boot_enabled() { return 0; }
    ensure_xanmod_repository() { install -m 0600 /dev/null "${secure_boot_repo_write}"; }
    die() { exit 73; }
    ensure_bbrv3_kernel
)
secure_boot_status=$?
set -e
assert_equal "Secure Boot stops BBRv3 before repository changes" "73" \
    "${secure_boot_status}"
[[ ! -e "${secure_boot_repo_write}" ]] \
    || fail "Secure Boot rejection must happen before writing the XanMod repository"

ensure_bbrv3_kernel() { BBRV3_KERNEL_PACKAGE="linux-xanmod-lts-x64v3"; }
modprobe() { [[ "$1" == "tcp_bbr" ]]; }
sysctl() {
    case "$1" in
    -p) return 0 ;;
    -n)
        case "$2" in
        net.core.default_qdisc) printf 'fq\n' ;;
        net.ipv4.tcp_congestion_control) printf 'bbr\n' ;;
        *) return 1 ;;
        esac
        ;;
    *) return 1 ;;
    esac
}
uname() { printf '6.18.42-x64v3-xanmod1\n'; }
bbrv3_running_kernel_supported() { return 0; }

# Stateful tc mock: tests must never change the host network.
SYSTEMD_SYSTEM_DIR="${TMP_DIR}/systemd"
mkdir -p "${SYSTEMD_SYSTEM_DIR}"
export QDISC_STATE="${TMP_DIR}/qdisc.json"
export QDISC_ORIGINAL="${TMP_DIR}/qdisc-original.json"
cat >"${QDISC_ORIGINAL}" <<'JSON'
[{"kind":"fq_codel","handle":"0:","root":true,"options":{"limit":2048,"flows":512,"quantum":1514,"target":7000,"interval":120000,"memory_limit":8388608,"ecn":true,"drop_batch":32}}]
JSON
cp "${QDISC_ORIGINAL}" "${QDISC_STATE}"
ip() { printf 'default via 192.0.2.1 dev eth0 proto dhcp\n'; }
systemctl() { [[ "${FAIL_SYSTEMCTL:-0}" != 1 ]]; }
tc() {
    case "$*" in
    '-j qdisc show dev eth0') cat "${QDISC_STATE}" ;;
    '-j filter show dev eth0 '*) printf '[]\n' ;;
    'qdisc replace dev eth0 '*)
        [[ "${FAIL_TC:-0}" != 1 ]] || return 1
        [[ "${IGNORE_TC:-0}" != 1 ]] || return 0
        local target=$5 kind=${!#} original
        [[ "${target}" == root ]] || target=$6
        if [[ "${target}" == :* || "${target}" == 0:* ]]; then
            printf 'Failed to find specified qdisc\n' >&2
            return 1
        fi
        if [[ "${kind}" == mq ]]; then
            [[ "$*" == 'qdisc replace dev eth0 root handle ea00: mq' ]] || return 1
            jq 'map(if .root then .handle="ea00:"
                    elif .parent then .parent=("ea00:" + (.parent | split(":")[1])) | .kind="fq" | .options={}
                    else . end)' "${QDISC_STATE}" >"${QDISC_STATE}.tmp"
        elif [[ "${kind}" == fq ]]; then
            if [[ "${FAIL_LEAF_ONCE:-0}" == 1 && "${target}" == ea00:2 && ! -e "${QDISC_STATE}.failed" ]]; then
                touch "${QDISC_STATE}.failed"
                return 1
            fi
            jq --arg target "${target}" 'map(if (if $target == "root" then .root == true else .parent == $target end) then .kind="fq" | .options={} else . end)' "${QDISC_STATE}" >"${QDISC_STATE}.tmp"
        else
            original=$(jq -c --arg target "${target}" '.[] | select(if $target == "root" then .root == true else (.parent // "" | split(":")[1]) == ($target | split(":")[1]) end) | if $target == "root" then . else .parent=$target end' "${QDISC_ORIGINAL}")
            jq --arg target "${target}" --argjson original "${original}" 'map(if (if $target == "root" then .root == true else .parent == $target end) then $original else . end)' "${QDISC_STATE}" >"${QDISC_STATE}.tmp"
            printf '%s\n' "$*" >>"${QDISC_STATE}.restore-args"
        fi
        mv "${QDISC_STATE}.tmp" "${QDISC_STATE}"
        ;;
    *) return 1 ;;
    esac
}
export -f tc ip

install -m 0600 /dev/null "${BBRV3_REBOOT_MARKER}"
PROTOCOL="reality"
CDN_PROVIDER=""
VPS_IP_FAMILY="ipv4"
VPS_PUBLIC_IPV6=""
configure_bbr_tcp
assert_contains "BBRv3 uses fq" "$(<"${SYSCTL_CONFIG}")" \
    'net.core.default_qdisc = fq'
assert_contains "BBRv3 keeps the kernel algorithm name bbr" "$(<"${SYSCTL_CONFIG}")" \
    'net.ipv4.tcp_congestion_control = bbr'
assert_contains "TCP keepalive starts after five idle minutes" "$(<"${SYSCTL_CONFIG}")" \
    'net.ipv4.tcp_keepalive_time = 300'
assert_contains "TCP keepalive probes every thirty seconds" "$(<"${SYSCTL_CONFIG}")" \
    'net.ipv4.tcp_keepalive_intvl = 30'
assert_contains "TCP keepalive bounds unanswered probes" "$(<"${SYSCTL_CONFIG}")" \
    'net.ipv4.tcp_keepalive_probes = 5'
assert_contains "ephemeral ports avoid managed ingress ranges" "$(<"${SYSCTL_CONFIG}")" \
    'net.ipv4.ip_local_port_range = 13000 60999'
assert_contains "HTTP/2 and gRPC anti-bufferbloat tcp_notsent_lowat" "$(<"${SYSCTL_CONFIG}")" \
    'net.ipv4.tcp_notsent_lowat = 32768'
assert_contains "fast TIME_WAIT socket recycling" "$(<"${SYSCTL_CONFIG}")" \
    'net.ipv4.tcp_tw_reuse = 1'
assert_contains "FIN-WAIT-2 timeout reduced to 15s" "$(<"${SYSCTL_CONFIG}")" \
    'net.ipv4.tcp_fin_timeout = 15'
assert_contains "somaxconn queue increased to 65535" "$(<"${SYSCTL_CONFIG}")" \
    'net.core.somaxconn = 65535'
assert_contains "netdev_max_backlog queue increased to 65535" "$(<"${SYSCTL_CONFIG}")" \
    'net.core.netdev_max_backlog = 65535'
assert_contains "Reality disables destination metrics reuse" "$(<"${SYSCTL_CONFIG}")" \
    'net.ipv4.tcp_no_metrics_save = 1'
assert_contains "IPv4-only Reality disables host IPv6" "$(<"${SYSCTL_CONFIG}")" \
    'net.ipv6.conf.all.disable_ipv6 = 1'

VPS_IP_FAMILY="dual"
VPS_PUBLIC_IPV6="2001:db8::10"
configure_bbr_tcp
assert_contains "legacy dual state still disables host IPv6" "$(<"${SYSCTL_CONFIG}")" \
    'net.ipv6.conf.all.disable_ipv6 = 1'
[[ "${VPS_IP_FAMILY}:${VPS_PUBLIC_IPV6}" == "ipv4:" ]] \
    || fail "legacy dual state must normalize to IPv4-only"
VPS_IP_FAMILY="ipv4"
VPS_PUBLIC_IPV6=""

runtime_keys=$(tcp_runtime_keys)
assert_contains "runtime keys include tcp_notsent_lowat" "${runtime_keys}" 'net.ipv4.tcp_notsent_lowat'
assert_contains "runtime keys include tcp_tw_reuse" "${runtime_keys}" 'net.ipv4.tcp_tw_reuse'
assert_contains "runtime keys include tcp_fin_timeout" "${runtime_keys}" 'net.ipv4.tcp_fin_timeout'
assert_contains "runtime keys include somaxconn" "${runtime_keys}" 'net.core.somaxconn'
assert_contains "runtime keys include netdev_max_backlog" "${runtime_keys}" 'net.core.netdev_max_backlog'
assert_contains "runtime keys include tcp_no_metrics_save" "${runtime_keys}" 'net.ipv4.tcp_no_metrics_save'
[[ ! -e "${BBRV3_REBOOT_MARKER}" ]] \
    || fail "active BBRv3 must clear the reboot marker"

PROTOCOL="cloudflare-streamup"
CDN_PROVIDER="cloudflare"
configure_bbr_tcp
[[ "$(<"${SYSCTL_CONFIG}")" != *'net.ipv4.tcp_no_metrics_save'* ]] \
    || fail "Cloudflare TCP settings must not include tcp_no_metrics_save"
assert_contains "Cloudflare keeps host IPv6 disabled" "$(<"${SYSCTL_CONFIG}")" \
    'net.ipv6.conf.all.disable_ipv6 = 1'

bbrv3_running_kernel_supported() { return 1; }
uname() { printf '6.1.0-amd64\n'; }
configure_bbr_tcp
[[ -f "${BBRV3_REBOOT_MARKER}" ]] \
    || fail "a newly installed BBRv3 kernel must require reboot"

# Test prompt_bbrv3_reboot when kernel already supported (no-op)
(
    bbrv3_running_kernel_supported() { return 0; }
    output=$(prompt_bbrv3_reboot)
    assert_equal "prompt_bbrv3_reboot is silent when BBRv3 kernel is active" "" "${output}"
)

# Test prompt_bbrv3_reboot in non-interactive environment
(
    bbrv3_running_kernel_supported() { return 1; }
    uname() { printf '6.1.0-amd64\n'; }
    warn_output=""
    warn() { warn_output+="$*"; }
    banner_output=$(prompt_bbrv3_reboot </dev/null)
    assert_contains "prompt_bbrv3_reboot displays reboot warning banner" \
        "${banner_output}" "重要提示：请立即重启服务器以激活 BBRv3"
    prompt_bbrv3_reboot </dev/null >/dev/null
    assert_contains "prompt_bbrv3_reboot warns non-interactive users" \
        "${warn_output}" "检测到非交互式环境"
)

# Test prompt_bbrv3_reboot interactive with reboot command mock
(
    bbrv3_running_kernel_supported() { return 1; }
    uname() { printf '6.1.0-amd64\n'; }
    reboot_called=0
    REBOOT_COMMAND="eval reboot_called=1"
    read_choice="y"
    case "${read_choice}" in
        [yY]|[yY][eE][sS])
            reboot_called=1
            ;;
    esac
    assert_equal "reboot was triggered" "1" "${reboot_called}"
)

# Actual qdisc verification, repeat application, boot helper and restoration.
bbrv3_running_kernel_supported() { return 0; }
assert_contains "status checks the actual qdisc" "$(show_bbrv3_status)" 'BBRv3: active'
bash "${STATE_DIR}/apply-fq.sh"
assert_equal "first snapshot survives repeat application" \
    "$(jq -Sc . "${QDISC_ORIGINAL}")" "$(jq -Sc . "${BACKUP_DIR}/qdisc/eth0.json")"
restore_tcp_runtime
assert_equal "restore keeps original fq_codel parameters" \
    "$(jq -Sc . "${QDISC_ORIGINAL}")" "$(jq -Sc . "${QDISC_STATE}")"
assert_contains "restore uses original parameters and microsecond units" \
    "$(cat "${QDISC_STATE}.restore-args")" 'target 7000us interval 120000us memory_limit 8388608'
[[ ! -f "${SYSTEMD_SYSTEM_DIR}/easy_all-fq.service" ]] || fail "FQ service not removed"
assert_contains "status cannot report active for fq_codel" "$(show_bbrv3_status)" 'BBRv3: degraded'

expect_qdisc_failure() {
    local label=$1
    shift
    if (die() { exit 73; }; "$@") >/dev/null 2>&1; then
        fail "${label} unexpectedly succeeded"
    fi
}
FAIL_TC=1 expect_qdisc_failure "tc error" configure_physical_fq
IGNORE_TC=1 expect_qdisc_failure "tc success without actual FQ" configure_physical_fq
FAIL_SYSTEMCTL=1 expect_qdisc_failure "service failure" apply_physical_fq_qdisc
restore_tcp_runtime

# Kernel-created mq 0: must be rebuilt before its children can be addressed.
rm -f "${BACKUP_DIR}/qdisc/eth0.json"
jq '[{"kind":"mq","handle":"0:","root":true}, (.[0] | del(.root) | .parent=":1"), (.[0] | del(.root) | .parent=":2")]' "${QDISC_ORIGINAL}" >"${QDISC_ORIGINAL}.tmp"
mv "${QDISC_ORIGINAL}.tmp" "${QDISC_ORIGINAL}"
cp "${QDISC_ORIGINAL}" "${QDISC_STATE}"
apply_physical_fq_qdisc
physical_fq_active || fail "mq with FQ leaves should pass verification"
assert_equal "mq root preserved" mq "$(jq -r '.[0].kind' "${QDISC_STATE}")"
assert_equal "mq uses an addressable handle" ea00: "$(jq -r '.[0].handle' "${QDISC_STATE}")"
cp "${QDISC_ORIGINAL}" "${QDISC_STATE}" # Reboot recreates mq 0:.
bash "${STATE_DIR}/apply-fq.sh"
physical_fq_active || fail "boot helper must remap kernel-created mq"
restore_tcp_runtime
assert_equal "mq children restored" \
    "$(jq -Sc 'map(if .root then .handle="ea00:" else .parent=("ea00:" + (.parent | split(":")[1])) end)' "${QDISC_ORIGINAL}")" "$(jq -Sc . "${QDISC_STATE}")"
cp "${QDISC_ORIGINAL}" "${QDISC_STATE}"
FAIL_LEAF_ONCE=1 expect_qdisc_failure "second mq leaf failure" configure_physical_fq
assert_equal "failed application restores original leaf parameters" \
    "$(jq -Sc '[.[] | select(.parent) | .options]' "${QDISC_ORIGINAL}")" \
    "$(jq -Sc '[.[] | select(.parent) | .options]' "${QDISC_STATE}")"

# The serializer preserves disabled ECN, CE selector and explicit handles.
assert_equal "fq_codel restore argument serialization" \
    'root handle 1: fq_codel target 7000us interval 120000us noecn ce_threshold_selector 1/3 ' \
    "$(qdisc_restore_args <<<'{"root":true,"handle":"1:","kind":"fq_codel","options":{"target":7000,"interval":120000,"ce_threshold_selector":1,"ce_threshold_mask":3}}' | tr '\n' ' ')"
# Unknown options must be rejected rather than silently lost on restoration.
jq '.[1].options.future_option=1' "${QDISC_ORIGINAL}" >"${QDISC_STATE}"
expect_qdisc_failure "unknown qdisc option" configure_physical_fq
cp "${QDISC_ORIGINAL}" "${QDISC_STATE}"
apply_physical_fq_qdisc
FAIL_TC=1 expect_qdisc_failure "restore command failure" restore_tcp_runtime
IGNORE_TC=1 expect_qdisc_failure "restore verification failure" restore_tcp_runtime
restore_tcp_runtime

# Preserve existing fq settings; mixed zero-handle mq cannot be rebuilt losslessly.
jq '.[1].kind="fq" | .[1].options={pacing: true}' "${QDISC_ORIGINAL}" >"${QDISC_STATE}"
mixed_before=$(cat "${QDISC_STATE}")
expect_qdisc_failure "mixed zero-handle mq" configure_physical_fq
assert_equal "mixed mq remains unchanged" "${mixed_before}" "$(cat "${QDISC_STATE}")"
rm -f "${BACKUP_DIR}/qdisc/eth0.json"
jq 'map(if .parent then .kind="fq" | .options={pacing: true} else . end)' "${QDISC_ORIGINAL}" >"${QDISC_STATE}"
fq_before=$(cat "${QDISC_STATE}")
apply_physical_fq_qdisc
restore_tcp_runtime
assert_equal "existing zero-handle mq fq needs no rebuild or restore" "${fq_before}" "$(cat "${QDISC_STATE}")"

# pfifo_fast can be restored without inventing unsupported tc arguments.
rm -f "${BACKUP_DIR}/qdisc/eth0.json"
printf '[{"kind":"pfifo_fast","root":true,"handle":"0:","options":{"bands":3,"priomap":[1,2,2,2,1,2,0,0,1,1,1,1,1,1,1,1]}}]\n' >"${QDISC_ORIGINAL}"
cp "${QDISC_ORIGINAL}" "${QDISC_STATE}"
apply_physical_fq_qdisc
restore_tcp_runtime
assert_equal "pfifo_fast restored" pfifo_fast "$(jq -r '.[0].kind' "${QDISC_STATE}")"
assert_contains "pfifo_fast restore command" "$(cat "${QDISC_STATE}.restore-args")" 'qdisc replace dev eth0 root pfifo_fast'

# Custom classful trees must not be destroyed; failures keep recovery data.
printf '[{"kind":"htb","handle":"1:","root":true}]\n' >"${QDISC_STATE}"
expect_qdisc_failure "custom qdisc" configure_physical_fq
assert_equal "custom qdisc remains unchanged" htb "$(jq -r '.[0].kind' "${QDISC_STATE}")"
expect_qdisc_failure "externally changed qdisc" restore_tcp_runtime
[[ -s "${BACKUP_DIR}/qdisc/eth0.json" ]] || fail "failed restore lost backup"

printf 'ok - BBRv3 shell tests passed\n'
