#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "${TMP_DIR}"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_equal() { [[ "$2" == "$3" ]] || fail "$1: expected [$2], got [$3]"; }
expect_failure() {
    local expected=$1 output
    shift
    if output=$("$@" 2>&1); then fail "unexpected success: $*"; fi
    [[ "${output}" == *"${expected}"* ]] || fail "missing [${expected}]: ${output}"
}

STATE_DIR="${TMP_DIR}/state"
STATE_FILE="${STATE_DIR}/state.env"
COMMAND_PATH="${TMP_DIR}/easy_all"
BACKUP_DIR="${STATE_DIR}/backups"
RUNTIME_TMP="${TMP_DIR}/runtime"
SYSCTL_CONFIG="${TMP_DIR}/tcp.conf"
BBR_MODULES_CONFIG="${TMP_DIR}/bbr-module.conf"
SYSTEMD_SYSTEM_DIR="${TMP_DIR}/systemd"
SKYLINE_BTF_FILE_OVERRIDE="${TMP_DIR}/btf"
SKYLINE_CGROUP_FILE_OVERRIDE="${TMP_DIR}/cgroup.controllers"
export TEST_TCP_CALLS="${TMP_DIR}/calls" TEST_SYSTEMD_DIR="${SYSTEMD_SYSTEM_DIR}"
export TEST_DAEMON_VERSION_FILE="${TMP_DIR}/daemon-version"
mkdir -p "${STATE_DIR}" "${BACKUP_DIR}" "${RUNTIME_TMP}" "${SYSTEMD_SYSTEM_DIR}"
record() { printf '%s\n' "$*" >>"${TEST_TCP_CALLS}"; }
die() { printf '%s\n' "$*" >&2; exit 73; }
info() { :; }
warn() { printf '%s\n' "$*" >&2; }
success() { :; }
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/tcp-tuning.sh"

assert_equal "legacy default" bbrv3 "$(normalize_tcp_acceleration '')"
assert_equal "menu BBR choice" bbrv3 "$(normalize_tcp_acceleration 1)"
assert_equal "menu Skyline choice" skyline "$(normalize_tcp_acceleration 2)"
expect_failure '' normalize_tcp_acceleration invalid
choose_tcp_acceleration </dev/null
assert_equal "noninteractive default" bbrv3 "${TCP_ACCELERATION}"
choose_tcp_acceleration skyline
assert_equal "explicit Skyline choice" skyline "${TCP_ACCELERATION}"
choose_tcp_acceleration </dev/null
assert_equal "saved choice survives" skyline "${TCP_ACCELERATION}"
expect_failure '选项无效' choose_tcp_acceleration invalid

(
    configure_bbr_tcp() { record bbr; }
    install_skyline_speeder() { fail "default must not install Skyline"; }
    unset TCP_ACCELERATION
    configure_tcp_acceleration
    assert_equal "default uses BBR implementation" bbr "$(cat "${TEST_TCP_CALLS}")"
)

uname() { printf '%s\n' "${TEST_KERNEL:-6.12.101-amd64}"; }
dpkg() {
    case "$*" in
    "--compare-versions ${TEST_KERNEL%%-*} ge 6.12") [[ "${TEST_KERNEL_OK}" == 1 ]] ;;
    '--compare-versions 2.36 lt 2.38') return 0 ;;
    '--compare-versions 2.39 lt 2.38') return 1 ;;
    *) fail "unexpected dpkg call: $*" ;;
    esac
}
getconf() { printf 'glibc %s\n' "${TEST_GLIBC:-2.39}"; }
TEST_KERNEL=6.1.0-amd64 TEST_KERNEL_OK=0
expect_failure 'Linux 6.12+' check_skyline_requirements
TEST_KERNEL=6.12.101-amd64 TEST_KERNEL_OK=1
expect_failure '内核 BTF' check_skyline_requirements
touch "${SKYLINE_BTF_FILE}"
expect_failure 'cgroup v2' check_skyline_requirements
touch "${SKYLINE_CGROUP_FILE}"
check_skyline_requirements
TEST_KERNEL=7.1.6-amd64
check_skyline_requirements

mkdir -p "${TMP_DIR}/fixture/source"
cat >"${TMP_DIR}/fixture/source/install.sh" <<'EOF'
#!/usr/bin/env bash
printf 'installer:%s\n' "$*" >>"${TEST_TCP_CALLS}"
case "$*" in
--check) exit "${TEST_PREFLIGHT_STATUS:-0}" ;;
'--prebuilt --no-enable'|'--source --no-enable')
    [[ "${TEST_INSTALL_STATUS:-0}" == 0 ]] || exit 1
    printf 'artifact:%s\n' "${SKYLINE_ARTIFACT_URL}" >>"${TEST_TCP_CALLS}"
    touch "${TEST_SYSTEMD_DIR}/skyline-speederd.service" "${TEST_SYSTEMD_DIR}/skyline-speeder-enable.service"
    printf '%s\n' "${TEST_INSTALL_VERSION:-0.5.1}" >"${TEST_DAEMON_VERSION_FILE}"
    ;;
--uninstall) exit "${TEST_UNINSTALL_STATUS:-0}" ;;
*) exit 1 ;;
esac
EOF
chmod 0755 "${TMP_DIR}/fixture/source/install.sh"
tar -czf "${TMP_DIR}/fixture.tar.gz" -C "${TMP_DIR}/fixture" source
curl() {
    local destination="" argument
    for argument; do
        if [[ "${argument}" == https://github.com/* ]]; then
            record "download-artifact:${argument}"
        elif [[ "${argument}" == https://codeload.github.com/* ]]; then
            record download
        fi
    done
    while (($#)); do
        if [[ "$1" == -o ]]; then destination=$2; break; fi
        shift
    done
    cp "${TMP_DIR}/fixture.tar.gz" "${destination}"
}
sha256sum() {
    local expected
    if [[ "$2" == - ]]; then
        expected=$(cat)
        assert_equal "source checksum is pinned" \
            "${SKYLINE_SOURCE_SHA256}  ${RUNTIME_TMP}/skyline-speeder.tar.gz" "${expected}"
    else
        expected=$(cat "$2")
        assert_equal "prebuilt checksum is pinned locally" \
            "${SKYLINE_ARTIFACT_SHA256}  ${RUNTIME_TMP}/skyline-speeder-${SKYLINE_VERSION}.tar.gz" "${expected}"
    fi
    [[ "${TEST_CHECKSUM_OK:-1}" == 1 ]]
}
: >"${TEST_TCP_CALLS}"
TEST_CHECKSUM_OK=0 expect_failure SHA256 install_skyline_speeder
[[ ! -d "${SKYLINE_SOURCE_DIR}" ]] || fail "bad checksum must not execute or retain the installer"
assert_equal "checksum rejected before execution" download "$(cat "${TEST_TCP_CALLS}")"
TEST_PREFLIGHT_STATUS=1 expect_failure '安装前检查失败' install_skyline_speeder
[[ ! -d "${SKYLINE_SOURCE_DIR}" ]] || fail "failed preflight must not retain the installer"
: >"${TEST_TCP_CALLS}"
install_skyline_speeder
install_skyline_speeder
assert_equal "verified installer reused" $'download\ninstaller:--check' "$(cat "${TEST_TCP_CALLS}")"
assert_equal "verified source records its pinned commit" "${SKYLINE_COMMIT}" \
    "$(cat "${SKYLINE_SOURCE_DIR}/.easy-all-commit")"
(
    printf 'old-commit\n' >"${SKYLINE_SOURCE_DIR}/.easy-all-commit"
    TEST_CHECKSUM_OK=0 expect_failure SHA256 install_skyline_speeder
    TEST_PREFLIGHT_STATUS=1 expect_failure '安装前检查失败' install_skyline_speeder
    assert_equal "failed source refresh preserves the retained installer" old-commit \
        "$(cat "${SKYLINE_SOURCE_DIR}/.easy-all-commit")"
    mv() {
        if [[ "$1" == -- && "$2" == "${STATE_DIR}"/skyline-speeder.stage.* \
            && "$2" != *.previous && "$3" == "${SKYLINE_SOURCE_DIR}" ]]; then
            return 1
        fi
        command mv "$@"
    }
    expect_failure '保留 Skyline Speeder 安装器失败' install_skyline_speeder
    [[ -x "${SKYLINE_SOURCE_DIR}/install.sh" ]] || fail "failed promotion must restore the old installer"
    assert_equal "failed promotion restores the old source identity" old-commit \
        "$(cat "${SKYLINE_SOURCE_DIR}/.easy-all-commit")"
)
install_skyline_speeder
(
    mv -- "${SKYLINE_SOURCE_DIR}" "${TMP_DIR}/source-saved"
    mkdir -p "${SKYLINE_SOURCE_DIR}"
    touch "${SKYLINE_SOURCE_DIR}/partial-download"
    install_skyline_speeder
    [[ -x "${SKYLINE_SOURCE_DIR}/install.sh" && ! -e "${SKYLINE_SOURCE_DIR}/partial-download" ]] \
        || fail "a partial source directory must be replaced, not nested"
)

skyline-speederd() {
    [[ -f "${TEST_DAEMON_VERSION_FILE}" ]] || return 1
    printf 'skyline-speederd %s\n' "$(cat "${TEST_DAEMON_VERSION_FILE}")"
}

MOCK_CC=bbr MOCK_FQ=1 MOCK_ACTIVE=1
systemctl() {
    record "systemctl:$*"
    [[ "${TEST_SYSTEMCTL_FAIL:-}" != "$*" ]] || return 1
    case "$*" in
    'enable --now skyline-speeder-enable.service') MOCK_CC=skyline_cc ;;
    'disable --now skyline-speederd.service') MOCK_CC=bbr ;;
    'is-active --quiet '*) [[ "${MOCK_ACTIVE}" == 1 ]] ;;
    'is-failed --quiet easy_all-skyline-setup.service') [[ "${TEST_SETUP_FAILED:-0}" == 1 ]] ;;
    esac
}
sysctl() {
    case "$*" in
    '-n net.ipv4.tcp_congestion_control') printf '%s\n' "${MOCK_CC}" ;;
    '-n net.core.default_qdisc') printf 'fq\n' ;;
    "-p ${SYSCTL_CONFIG}") record fallback; MOCK_CC=bbr ;;
    *) fail "unexpected sysctl: $*" ;;
    esac
}
physical_fq_active() { [[ "${MOCK_FQ}" == 1 ]]; }
configure_tcp_parameters() { record tuning; printf 'fallback\n' >"${SYSCTL_CONFIG}"; }
(
    TEST_KERNEL=6.6.99-xanmod1 TEST_KERNEL_OK=0
    ensure_bbrv3_kernel() { record "kernel:$*"; }
    require_root() { :; }
    acquire_runtime_write_lock() { record lock; }
    release_runtime_write_lock() { record unlock; }
    collect_installed_state() { TCP_ACCELERATION=bbrv3; record load; }
    save_state() { record "save:${TCP_ACCELERATION}"; printf 'TCP_ACCELERATION=%s\n' "${TCP_ACCELERATION}" >"${STATE_FILE}"; }
    : >"${TEST_TCP_CALLS}"
    EASY_ALL_NO_REBOOT=1 update_tcp_acceleration skyline >"${TMP_DIR}/pending" 2>/dev/null
    calls=$(cat "${TEST_TCP_CALLS}")
    [[ "${calls}" == *$'kernel:6.12\ntuning'* && "${calls}" == *$'save:skyline\nunlock'* ]] \
        || fail "old kernels must be upgraded and the Skyline choice saved before reboot"
    [[ "${calls}" != *download* && "${calls}" != *installer:* ]] \
        || fail "old kernels must not attempt to install Skyline before reboot"
    [[ "$(cat "${TMP_DIR}/pending")" == *'pending-reboot'* ]] || fail "pending reboot status missing"
    [[ "$(cat "${TMP_DIR}/pending")" == *'只需重启一次'* ]] || fail "reboot must be the only remaining user action"
    [[ "${calls}" == *'systemctl:enable easy_all-skyline-setup.service'* \
        && "${calls}" != *'systemctl:enable --now easy_all-skyline-setup.service'* ]] \
        || fail "setup must be scheduled for boot, not run on the old kernel"
    unit=$(cat "${SYSTEMD_SYSTEM_DIR}/easy_all-skyline-setup.service")
    [[ "${unit}" == *"ConditionPathExists=${STATE_FILE}"* \
        && "${unit}" == *"ConditionPathExists=${BBRV3_REBOOT_MARKER}"* \
        && "${unit}" == *"ExecStart=\"${COMMAND_PATH}\" tcp-resume"* \
        && "${unit}" == *'After=network-online.target systemd-sysctl.service easy_all-fq.service'* \
        && "${unit}" == *'TimeoutStartSec=0'* ]] || fail "boot setup must wait for runtime prerequisites and allow source builds"
    TEST_KERNEL=6.12.101-xanmod1 TEST_KERNEL_OK=1
    status=$(show_tcp_acceleration_status)
    [[ "${status}" == *'pending-activation'* && "${status}" == *'自动安装并启用'* ]] \
        || fail "after reboot, status must explain automatic activation"
    status=$(TEST_SETUP_FAILED=1 show_tcp_acceleration_status)
    [[ "${status}" == *'degraded'* && "${status}" == *'journalctl -u easy_all-skyline-setup.service -b'* ]] \
        || fail "failed boot setup must expose its failure and recovery logs"
    TEST_SYSTEMCTL_FAIL='enable easy_all-skyline-setup.service' \
        expect_failure '启用 Skyline 开机安装任务失败' install_skyline_boot_setup
)
(
    require_root() { :; }
    try_acquire_runtime_write_lock() { record "lock:$*"; }
    release_runtime_write_lock() { record unlock; }
    collect_installed_state() { source "${STATE_FILE}"; record load; }
    ensure_bbrv3_kernel() { fail "boot setup must never trigger another kernel upgrade"; }
    TEST_KERNEL=6.6.99-xanmod1 TEST_KERNEL_OK=0
    : >"${TEST_TCP_CALLS}"
    expect_failure 'Linux 6.12+' resume_skyline_after_reboot
    [[ "$(cat "${TEST_TCP_CALLS}")" == $'lock:60\nload' ]] \
        || fail "boot setup must request a bounded lock wait before loading state"
    TEST_KERNEL=6.12.101-xanmod1 TEST_KERNEL_OK=1
    TEST_CHECKSUM_OK=0 expect_failure '预编译包 SHA256' resume_skyline_after_reboot
    [[ -f "${BBRV3_REBOOT_MARKER}" && -f "${SYSTEMD_SYSTEM_DIR}/easy_all-skyline-setup.service" ]] \
        || fail "failed boot setup must remain retryable"
    assert_equal "failed setup keeps BBR" bbr "${MOCK_CC}"
    : >"${TEST_TCP_CALLS}"
    resume_skyline_after_reboot 2>/dev/null
    [[ ! -e "${BBRV3_REBOOT_MARKER}" && ! -e "${SYSTEMD_SYSTEM_DIR}/easy_all-skyline-setup.service" ]] \
        || fail "successful boot setup must remove its marker and one-time unit"
    calls=$(cat "${TEST_TCP_CALLS}")
    [[ "${calls}" == *'systemctl:disable easy_all-skyline-setup.service'* \
        && "${calls}" != *'systemctl:stop easy_all-skyline-setup.service'* \
        && "${calls}" == *$'systemctl:daemon-reload\nunlock' ]] \
        || fail "successful setup must disable itself without stopping its own process"
    [[ "$(show_tcp_acceleration_status)" == *'Skyline Speeder: active'* ]] \
        || fail "Skyline must become active automatically after one reboot"
)
(
    require_root() { :; }
    try_acquire_runtime_write_lock() { [[ "$*" == 60 ]] || fail "boot wait must remain bounded"; return 1; }
    collect_installed_state() { fail "timed-out setup must not load or change state"; }
    install_skyline_boot_setup
    touch "${BBRV3_REBOOT_MARKER}"
    expect_failure '等待运行时锁 60 秒超时' resume_skyline_after_reboot
    expect_failure 'sudo easy_all tcp skyline 重试' resume_skyline_after_reboot
    [[ -f "${BBRV3_REBOOT_MARKER}" && -f "${SYSTEMD_SYSTEM_DIR}/easy_all-skyline-setup.service" ]] \
        || fail "a lock timeout must retain the boot setup for retry"
)
(
    install_skyline_boot_setup
    touch "${BBRV3_REBOOT_MARKER}"
    require_root() { :; }
    try_acquire_runtime_write_lock() { :; }
    release_runtime_write_lock() { :; }
    collect_installed_state() { TCP_ACCELERATION=bbrv3; }
    configure_tcp_acceleration() { fail "stale setup must not override the saved BBR choice"; }
    resume_skyline_after_reboot
    [[ ! -f "${SYSTEMD_SYSTEM_DIR}/easy_all-skyline-setup.service" ]] || fail "stale setup must remove itself"
    [[ -f "${BBRV3_REBOOT_MARKER}" ]] || fail "cancelling stale setup must retain the BBR reboot marker"
)
(
    install_skyline_boot_setup
    rm -f -- "${BBRV3_REBOOT_MARKER}"
    require_root() { :; }
    try_acquire_runtime_write_lock() { :; }
    release_runtime_write_lock() { :; }
    collect_installed_state() { TCP_ACCELERATION=skyline; }
    configure_tcp_acceleration() { fail "a completed setup must not run again without its marker"; }
    resume_skyline_after_reboot
    [[ ! -f "${SYSTEMD_SYSTEM_DIR}/easy_all-skyline-setup.service" ]] || fail "completed setup must remove any stale unit"
    touch "${BBRV3_REBOOT_MARKER}"
    TCP_ACCELERATION=skyline TEST_KERNEL=6.6.99-xanmod1 TEST_KERNEL_OK=0
    [[ "$(show_tcp_acceleration_status)" == *'准备开机自动启用任务'* ]] \
        || fail "a legacy reboot marker without a setup unit must not promise automatic activation"
)
TCP_ACCELERATION=skyline
touch "${BBRV3_REBOOT_MARKER}"
rm -f -- "${SKYLINE_SOURCE_DIR}/.easy-all-installed"
: >"${TEST_TCP_CALLS}"
TEST_CHECKSUM_OK=0 expect_failure '预编译包 SHA256' configure_tcp_acceleration
[[ "$(cat "${TEST_TCP_CALLS}")" != *installer:* ]] \
    || fail "a prebuilt checksum mismatch must stop before installer execution"
: >"${TEST_TCP_CALLS}"
configure_tcp_acceleration 2>"${TMP_DIR}/warning"
[[ "$(cat "${TMP_DIR}/warning")" == *'仅在丢包率极高'* ]] || fail "Skyline must warn about extreme loss"
[[ "$(cat "${TEST_TCP_CALLS}")" == *"download-artifact:https://github.com/CYBERVERSE-Research/skyline-speeder/releases/download/v0.5.1/skyline-speeder-v0.5.1-x86_64.tar.gz"* ]] \
    || fail "prebuilt version must be pinned"
[[ "$(cat "${TEST_TCP_CALLS}")" == *"artifact:${RUNTIME_TMP}/skyline-speeder-${SKYLINE_VERSION}.tar.gz"* ]] \
    || fail "the installer must receive the locally verified prebuilt archive"
[[ ! -e "${BBRV3_REBOOT_MARKER}" ]] || fail "Skyline must clear the BBR reboot marker"
[[ "$(show_tcp_acceleration_status)" == *'Skyline Speeder: active'* ]] || fail "Skyline status missing"
assert_equal "Skyline never prompts for a BBR reboot" '' "$(prompt_bbrv3_reboot)"

rm -f -- "${SKYLINE_SOURCE_DIR}/.easy-all-installed"
: >"${TEST_TCP_CALLS}"
TEST_GLIBC=2.36 configure_tcp_acceleration 2>"${TMP_DIR}/source-warning"
[[ "$(cat "${TMP_DIR}/source-warning")" == *'从源码编译 Rust/BPF'* ]] \
    || fail "older glibc must explain the build cost before compilation"
[[ "$(cat "${TEST_TCP_CALLS}")" == *'installer:--source --no-enable'* ]] \
    || fail "Debian 12 must explicitly build the pinned source"
[[ "$(cat "${TEST_TCP_CALLS}")" != *download-artifact:* ]] \
    || fail "source builds must not download an incompatible prebuilt archive"

: >"${TEST_TCP_CALLS}"
configure_tcp_acceleration 2>/dev/null
[[ "$(cat "${TEST_TCP_CALLS}")" != *installer:* ]] || fail "apply must reuse installed binaries"
printf '0.5.0\n' >"${TEST_DAEMON_VERSION_FILE}"
: >"${TEST_TCP_CALLS}"
configure_tcp_acceleration 2>/dev/null
[[ "$(cat "${TEST_TCP_CALLS}")" == *'installer:--prebuilt --no-enable'* ]] \
    || fail "apply must replace an outdated binary even when both units exist"
assert_equal "apply upgrades the pinned daemon version" 0.5.1 "$(cat "${TEST_DAEMON_VERSION_FILE}")"
printf 'old-commit\n' >"${SKYLINE_SOURCE_DIR}/.easy-all-commit"
: >"${TEST_TCP_CALLS}"
configure_tcp_acceleration 2>/dev/null
calls=$(cat "${TEST_TCP_CALLS}")
[[ "${calls}" == *'download'* && "${calls}" == *'installer:--prebuilt --no-enable'* ]] \
    || fail "a changed source pin must refresh both installer and installed objects"
assert_equal "successful installation records the installed pin" "${SKYLINE_COMMIT}" \
    "$(cat "${SKYLINE_SOURCE_DIR}/.easy-all-installed")"
(
    rm -f -- "${SKYLINE_SOURCE_DIR}/.easy-all-installed"
    TEST_INSTALL_STATUS=1 expect_failure 'Skyline Speeder 安装失败' configure_tcp_acceleration
    [[ ! -e "${SKYLINE_SOURCE_DIR}/.easy-all-installed" ]] || fail "failed installs must remain retryable"
    TEST_INSTALL_VERSION=0.5.0 expect_failure '版本验收失败' configure_tcp_acceleration
    [[ ! -e "${SKYLINE_SOURCE_DIR}/.easy-all-installed" ]] || fail "a wrong binary must not be recorded as installed"
)
configure_tcp_acceleration 2>/dev/null
MOCK_FQ=0
[[ "$(show_tcp_acceleration_status)" == *'degraded'* ]] || fail "bad actual qdisc must fail status"
expect_failure '已停用并回退 bbr' configure_tcp_acceleration
[[ "$(cat "${TEST_TCP_CALLS}")" == *$'systemctl:disable --now skyline-speederd.service\nfallback' ]] \
    || fail "failed activation must disable the guard before falling back"
MOCK_FQ=1 MOCK_ACTIVE=0
[[ "$(show_tcp_acceleration_status)" == *'degraded'* ]] || fail "dead daemon must fail status"
MOCK_ACTIVE=1 MOCK_CC=bbr
[[ "$(show_tcp_acceleration_status)" == *'degraded'* ]] || fail "wrong congestion control must fail status"
touch "${BBRV3_REBOOT_MARKER}"
status=$(show_tcp_acceleration_status)
[[ "${status}" == *'degraded'* && "${status}" == *'bbr'* \
    && "${status}" == *'sudo easy_all tcp skyline'* && "${status}" == *'sudo easy_all tcp bbrv3'* ]] \
    || fail "a fallback without a boot job must show the actual CC and both recovery choices"
rm -f -- "${BBRV3_REBOOT_MARKER}"
[[ "$(show_tcp_acceleration_status)" == *'sudo easy_all tcp skyline'* ]] \
    || fail "all degraded states must name the TCP recovery command"
TEST_SYSTEMCTL_FAIL='disable --now skyline-speeder-enable.service' \
    expect_failure '停止 Skyline Speeder 失败' stop_skyline_speeder

(
    ensure_bbrv3_kernel() { record kernel; }
    bbrv3_running_kernel_supported() { return 0; }
    TCP_ACCELERATION=bbrv3
    install_skyline_boot_setup
    : >"${TEST_TCP_CALLS}"
    configure_tcp_acceleration
    assert_equal "BBR stops both Skyline services before applying sysctl" \
        $'kernel\nsystemctl:stop easy_all-skyline-setup.service\nsystemctl:disable easy_all-skyline-setup.service\nsystemctl:daemon-reload\nsystemctl:disable --now skyline-speeder-enable.service\nsystemctl:disable --now skyline-speederd.service\ntuning' \
        "$(cat "${TEST_TCP_CALLS}")"
    [[ ! -f "${SYSTEMD_SYSTEM_DIR}/easy_all-skyline-setup.service" ]] || fail "BBR must cancel automatic Skyline setup"
)
(
    restore_tcp_runtime() { record restore; }
    install_skyline_boot_setup
    : >"${TEST_TCP_CALLS}"
    restore_bbr_tcp_install_state
    assert_equal "uninstall cancels setup before TCP restoration" \
        $'systemctl:stop easy_all-skyline-setup.service\nsystemctl:disable easy_all-skyline-setup.service\nsystemctl:daemon-reload\ninstaller:--uninstall\nrestore' "$(cat "${TEST_TCP_CALLS}")"
    TEST_UNINSTALL_STATUS=1 expect_failure '卸载 Skyline Speeder 失败' restore_bbr_tcp_install_state
    install_skyline_boot_setup
    TEST_SYSTEMCTL_FAIL='stop easy_all-skyline-setup.service' \
        expect_failure '停止 Skyline 开机安装任务失败' restore_bbr_tcp_install_state
    [[ -f "${SYSTEMD_SYSTEM_DIR}/easy_all-skyline-setup.service" ]] || fail "a job that cannot be stopped must not lose its unit"
    restore_preinstall_xanmod_packages() { record packages; }
    : >"${TEST_TCP_CALLS}"
    restore_bbr_tcp_install_state 1
    [[ "$(cat "${TEST_TCP_CALLS}")" == *$'installer:--uninstall\nrestore\npackages' \
        && ! -f "${SYSTEMD_SYSTEM_DIR}/easy_all-skyline-setup.service" ]] \
        || fail "fresh-install rollback must cancel setup and restore TCP and packages"
)
(
    require_root() { :; }
    acquire_runtime_write_lock() { record lock; }
    release_runtime_write_lock() { record unlock; }
    collect_installed_state() { TCP_ACCELERATION=skyline; record load; }
    configure_tcp_acceleration() { record "configure:${TCP_ACCELERATION}"; }
    save_state() { record "save:${TCP_ACCELERATION}"; }
    show_tcp_acceleration_status() { :; }
    prompt_bbrv3_reboot() { record reboot; }
    : >"${TEST_TCP_CALLS}"
    update_tcp_acceleration bbrv3
    assert_equal "switch persists only after successful configuration" \
        $'lock\nload\nconfigure:bbrv3\nsave:bbrv3\nunlock\nreboot' "$(cat "${TEST_TCP_CALLS}")"
    expect_failure '非交互模式请指定' update_tcp_acceleration </dev/null
    configure_tcp_acceleration() { die 'mock activation failed'; }
    : >"${TEST_TCP_CALLS}"
    expect_failure 'mock activation failed' update_tcp_acceleration skyline
    [[ "$(cat "${TEST_TCP_CALLS}")" != *save:* ]] || fail "failed switch must not save its choice"
)

printf 'ok - TCP acceleration selection and lifecycle tests passed\n'
