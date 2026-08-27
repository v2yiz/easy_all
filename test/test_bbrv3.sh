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
install -d -m 0700 "${STATE_DIR}" "${BACKUP_DIR}" "${RUNTIME_TMP}"
printf 'reno cubic bbr\n' >"${BBRV3_AVAILABLE_CC_FILE_OVERRIDE}"

die() { fail "$*"; }
warn() { :; }
info() { :; }
success() { :; }

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

module_content=$(<"${ROOT_DIR}/lib/tcp-tuning.sh")
assert_contains "XanMod key fingerprint is pinned" "${module_content}" \
    'D38D7D1DA1349567ADED882D86F7D09EE734E623'
assert_contains "XanMod repository uses HTTPS" "${module_content}" \
    'https://deb.xanmod.org'
assert_contains "XanMod key download requires HTTPS" "${module_content}" \
    "--proto '=https'"
assert_contains "XanMod LTS package installation is explicit" "${module_content}" \
    'apt-get install -y --no-install-recommends "${BBRV3_KERNEL_PACKAGE}"'
assert_contains "minimal installations can acquire the key verification dependency" \
    "${module_content}" 'apt-get install -y --no-install-recommends gnupg'
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

install -m 0600 /dev/null "${BBRV3_REBOOT_MARKER}"
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
[[ ! -e "${BBRV3_REBOOT_MARKER}" ]] \
    || fail "active BBRv3 must clear the reboot marker"

bbrv3_running_kernel_supported() { return 1; }
uname() { printf '6.1.0-amd64\n'; }
configure_bbr_tcp
[[ -f "${BBRV3_REBOOT_MARKER}" ]] \
    || fail "a newly installed BBRv3 kernel must require reboot"

printf 'ok - BBRv3 shell tests passed\n'
