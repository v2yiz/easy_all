#!/usr/bin/env bash
# 中断安装自愈的单元测试：端口守卫分类、残留识别与安装进度标记。
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
# macOS 的 mktemp 忽略 TMPDIR，受限环境里用户临时目录可能不可写；退回显式模板。
TMP_DIR=$(mktemp -d 2>/dev/null || true)
if [[ -z "${TMP_DIR}" ]]; then
    TMP_DIR=$(mktemp -d "${TMP_ROOT_FALLBACK:-/tmp}/easy_all_test.XXXXXX")
fi
trap 'rm -rf -- "${TMP_DIR}"' EXIT

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    local label=$1 text=$2 expected=$3
    [[ "${text}" == *"${expected}"* ]] || fail "${label}: missing <${expected}> in <${text}>"
}

assert_not_contains() {
    local label=$1 text=$2 unexpected=$3
    [[ "${text}" != *"${unexpected}"* ]] || fail "${label}: unexpected <${unexpected}> in <${text}>"
}

assert_equal() {
    local label=$1 expected=$2 actual=$3
    [[ "${expected}" == "${actual}" ]] || fail "${label}: expected <${expected}> but got <${actual}>"
}

# 隔离全部外部依赖：路径走临时目录，ss 用可编程的假命令。
export RUNTIME_TMP="${TMP_DIR}/runtime"
mkdir -p "${RUNTIME_TMP}"
export EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE="${TMP_DIR}/progress/install-progress.env"
export EASY_ALL_GUARD_STATE_DIR="${TMP_DIR}/state"
export EASY_ALL_GUARD_STATE_FILE="${TMP_DIR}/state/state.env"
export EASY_ALL_GUARD_SERVICE_FILE="${TMP_DIR}/systemd/easy_all-xray.service"
export EASY_ALL_GUARD_NGINX_CONFIG="${TMP_DIR}/nginx/easy_all.conf"
export EASY_ALL_GUARD_NGINX_DEFAULT_SITE="${TMP_DIR}/nginx/sites-enabled/default"
export EASY_ALL_GUARD_NGINX_SITES_DIR="${TMP_DIR}/nginx/sites-enabled"
export EASY_ALL_GUARD_NGINX_CONF_DIR="${TMP_DIR}/nginx/conf.d"
export EASY_ALL_SS_CMD_OVERRIDE="${TMP_DIR}/fake-ss"
export EASY_ALL_POLICY_STATE_DIR_OVERRIDE="${TMP_DIR}/policy-state"
export FAKE_SS_BUSY_PORTS="${TMP_DIR}/fake-ss-busy"
export FAKE_SS_OWNER=nginx

printf '#!/usr/bin/env bash\n' >"${EASY_ALL_SS_CMD_OVERRIDE}"
printf 'set -Eeuo pipefail\n' >>"${EASY_ALL_SS_CMD_OVERRIDE}"
cat >>"${EASY_ALL_SS_CMD_OVERRIDE}" <<'FAKE_SS'
port=${!#}
port=${port##*:}
[[ -f "${FAKE_SS_BUSY_PORTS}" ]] || exit 0
grep -qx -- "${port}" "${FAKE_SS_BUSY_PORTS}" || exit 0
if [[ " $* " == *" -ltnp "* ]]; then
    # FAKE_SS_OWNER=@none 模拟普通用户看不到进程归属（ss 无 users 字段）
    if [[ "${FAKE_SS_OWNER:-nginx}" == "@none" ]]; then
        printf 'LISTEN 0 511 0.0.0.0:%s 0.0.0.0:*\n' "${port}"
    else
        printf 'LISTEN 0 511 0.0.0.0:%s 0.0.0.0:* users:(("%s",pid=4242,fd=6))\n' \
            "${port}" "${FAKE_SS_OWNER:-nginx}"
    fi
else
    printf 'LISTEN 0 511 0.0.0.0:%s 0.0.0.0:*\n' "${port}"
fi
FAKE_SS
chmod +x "${EASY_ALL_SS_CMD_OVERRIDE}"

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/log.sh"
EASY_ALL_RUNTIME_LIB_DIR="${ROOT_DIR}/lib"
RUNTIME_LIB_DIR="${ROOT_DIR}/lib"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/profile-common.sh"

# die 只退出当前子 shell：capture() 用 $( ) 包起来即可拿到消息与状态。
die() { printf '%s\n' "$*" >&2; exit 1; }
warn() { printf '%s\n' "$*" >&2; }

busy() { printf '%s\n' "$@" >"${FAKE_SS_BUSY_PORTS}"; }
idle() { rm -f -- "${FAKE_SS_BUSY_PORTS}"; }
reset_artifacts() {
    rm -rf -- "${TMP_DIR}/state" "${TMP_DIR}/systemd" "${TMP_DIR}/nginx" \
        "${TMP_DIR}/progress"
}
capture() {
    local output status=0
    output=$("$@" 2>&1) || status=$?
    printf '%s' "${output}"
    return "${status}"
}

# 1. 端口空闲时不报错
idle
reset_artifacts
assert_equal "idle port passes" "0" "$(assert_install_ports_free 80 443 >/dev/null 2>&1 && echo 0 || echo 1)"

# 2. 第三方占用保持原文案，并点名占用进程
busy 80
FAKE_SS_OWNER=sshd
export FAKE_SS_OWNER
output=$(capture assert_install_ports_free 80 || true)
assert_contains "third-party owner is reported" "${output}" "sshd"
assert_contains "third-party keeps original hint" "${output}" "easy_all 仅支持专用 VPS"
assert_not_contains "third-party is not called residue" "${output}" "cleanup-partial"

# 3. 自身残留占用：给出去残留指引而不是「仅支持专用 VPS」
install_progress_begin combined
install_progress_stage packages
busy 80
FAKE_SS_OWNER=nginx
export FAKE_SS_OWNER
output=$(capture assert_install_ports_free 80 || true)
assert_contains "residue guidance is offered" "${output}" "cleanup-partial"
assert_contains "residue reports the stage" "${output}" "packages"
assert_not_contains "residue is not blamed on a dedicated VPS" "${output}" "仅支持专用 VPS"

# 4. 已安装状态（存在状态文件）永不判为残留
mkdir -p "${EASY_ALL_GUARD_STATE_DIR}"
: >"${EASY_ALL_GUARD_STATE_FILE}"
mkdir -p "$(dirname "${EASY_ALL_GUARD_NGINX_CONFIG}")"
: >"${EASY_ALL_GUARD_NGINX_CONFIG}"
assert_equal "installed state is never residue" "1" \
    "$(install_residue_reason >/dev/null 2>&1 && echo 0 || echo 1)"
output=$(capture assert_install_ports_free 80 || true)
assert_contains "installed-but-busy port still warns" "${output}" "easy_all 仅支持专用 VPS"

# 5. 残留识别：状态目录、服务单元、Nginx 配置、进度标记
reset_artifacts
mkdir -p "${EASY_ALL_GUARD_STATE_DIR}"
assert_equal "empty state dir alone is not residue" "1" \
    "$(install_residue_reason >/dev/null 2>&1 && echo 0 || echo 1)"
: >"${EASY_ALL_GUARD_STATE_DIR}/runtime-write.lock"
assert_equal "state dir with only the write lock is not residue" "1" \
    "$(install_residue_reason >/dev/null 2>&1 && echo 0 || echo 1)"
mkdir -p "${EASY_ALL_GUARD_STATE_DIR}/xray"
output=$(capture install_residue_reason || true)
assert_contains "state dir with content is residue" "${output}" "未完成的状态目录"

rm -rf -- "${EASY_ALL_GUARD_STATE_DIR}"
mkdir -p "$(dirname "${EASY_ALL_GUARD_SERVICE_FILE}")"
: >"${EASY_ALL_GUARD_SERVICE_FILE}"
output=$(capture install_residue_reason || true)
assert_contains "leftover unit file is residue" "${output}" "残留服务单元"

rm -f -- "${EASY_ALL_GUARD_SERVICE_FILE}"
mkdir -p "$(dirname "${EASY_ALL_GUARD_NGINX_CONFIG}")"
: >"${EASY_ALL_GUARD_NGINX_CONFIG}"
output=$(capture install_residue_reason || true)
assert_contains "leftover nginx config is residue" "${output}" "残留 Nginx 配置"

rm -f -- "${EASY_ALL_GUARD_NGINX_CONFIG}"
assert_equal "clean host has no residue" "1" \
    "$(install_residue_reason >/dev/null 2>&1 && echo 0 || echo 1)"

# 6. 进度标记生命周期：写入、更新保留其他字段、清理删除目录
install_progress_begin combined
assert_equal "marker records profile" "combined" "$(install_progress_field PROFILE)"
assert_equal "marker starts at start" "start" "$(install_progress_field STAGE)"
install_progress_stage services
assert_equal "marker stage advances" "services" "$(install_progress_field STAGE)"
assert_equal "marker keeps profile on stage update" "combined" \
    "$(install_progress_field PROFILE)"
[[ -n "$(install_progress_field STARTED_AT)" ]] || fail "marker keeps started time"
# 覆盖 begin：上一次中断留下的标记不应保留旧阶段
install_progress_begin reality
assert_equal "rebegin resets stage" "start" "$(install_progress_field STAGE)"
assert_equal "rebegin replaces profile" "reality" "$(install_progress_field PROFILE)"
install_progress_clear
[[ ! -f "${EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE}" ]] \
    || fail "clearing the marker removes the file"
[[ ! -d "$(dirname "${EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE}")" ]] \
    || fail "clearing the marker removes the empty directory"

# 7. 未知端口归属（无 users 信息）时仍能给出可执行结论
busy 443
FAKE_SS_OWNER="@none"
export FAKE_SS_OWNER
output=$(capture assert_install_ports_free 443 || true)
assert_contains "unowned busy port still errors" "${output}" "TCP 443 已被占用"

# 8. 旧版本遗留：nginx 默认站点占端口、没有 marker 与 conf.d，也要给恢复动作
reset_artifacts
busy 80
FAKE_SS_OWNER=nginx
export FAKE_SS_OWNER
# 没有 Debian 默认站点时只报占用，不臆测成残留
output=$(capture assert_install_ports_free 80 || true)
assert_contains "nginx without default site keeps plain verdict" "${output}" "仅支持专用 VPS"
assert_not_contains "no default site means no leftover hint" "${output}" "systemctl disable --now nginx"

mkdir -p "$(dirname "${EASY_ALL_GUARD_NGINX_DEFAULT_SITE}")"
: >"${EASY_ALL_GUARD_NGINX_DEFAULT_SITE}"
output=$(capture assert_install_ports_free 80 || true)
assert_contains "debian default site keeps dedicated-vps verdict" "${output}" "仅支持专用 VPS"
assert_contains "debian default site names the fix" "${output}" "systemctl disable --now nginx"

# 我方已写好 conf.d 时不再当作默认站点残留
mkdir -p "$(dirname "${EASY_ALL_GUARD_NGINX_CONFIG}")"
: >"${EASY_ALL_GUARD_NGINX_CONFIG}"
output=$(capture assert_install_ports_free 80 || true)
assert_not_contains "managed nginx config suppresses leftover hint" "${output}" "systemctl disable --now nginx"

# 9. 旧版本残留候选：只有 Debian 默认站点时认定为可清理，多一个站点即放弃
reset_artifacts
mkdir -p "${EASY_ALL_GUARD_NGINX_SITES_DIR}" "${EASY_ALL_GUARD_NGINX_CONF_DIR}"
: >"${EASY_ALL_GUARD_NGINX_DEFAULT_SITE}"
assert_equal "only default site is a cleanup candidate" "0" \
    "$(legacy_nginx_residue_candidate && echo 0 || echo 1)"
assert_equal "installed state blocks the candidate" "1" \
    "$(mkdir -p "${EASY_ALL_GUARD_STATE_DIR}" && : >"${EASY_ALL_GUARD_STATE_FILE}" \
        && (legacy_nginx_residue_candidate && echo 0 || echo 1))"
rm -rf -- "${EASY_ALL_GUARD_STATE_DIR}"

: >"${EASY_ALL_GUARD_NGINX_SITES_DIR}/my-site.conf"
assert_equal "extra site file blocks the candidate" "1" \
    "$(legacy_nginx_residue_candidate && echo 0 || echo 1)"
rm -f -- "${EASY_ALL_GUARD_NGINX_SITES_DIR}/my-site.conf"

: >"${EASY_ALL_GUARD_NGINX_CONF_DIR}/other.conf"
assert_equal "extra conf.d file blocks the candidate" "1" \
    "$(legacy_nginx_residue_candidate && echo 0 || echo 1)"
rm -f -- "${EASY_ALL_GUARD_NGINX_CONF_DIR}/other.conf"

# 非交互安装遇到候选时必须拒绝，而不是偷偷停掉 nginx
output=$(capture prepare_fresh_install 80 </dev/null || true)
assert_contains "non-interactive candidate is refused" "${output}" \
    "非交互安装无法确认 nginx 归属"
assert_contains "refusal repeats the manual fix" "${output}" "systemctl disable --now nginx"

# 10. root crontab 清理：只删 easy_all 的定时重启行，过滤失败时绝不提交空内容
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/scheduled-maintenance.sh"
mkdir -p "${TMP_DIR}/bin"
cat >"${TMP_DIR}/bin/crontab" <<'FAKE_CRONTAB'
#!/usr/bin/env bash
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
chmod +x "${TMP_DIR}/bin/crontab"
export FAKE_CRONTAB_FILE="${TMP_DIR}/root-crontab"
export CRON_REBOOT_MARKER="# easy_all-managed-reboot"

printf '0 3 * * * /usr/local/bin/user-backup\n0 4 * * * true # easy_all-managed-reboot\n' \
    >"${FAKE_CRONTAB_FILE}"
PATH="${TMP_DIR}/bin:${PATH}" remove_daily_reboot_schedule
assert_contains "user cron entry survives" "$(cat "${FAKE_CRONTAB_FILE}")" "user-backup"
assert_not_contains "managed reboot entry removed" "$(cat "${FAKE_CRONTAB_FILE}")" \
    "easy_all-managed-reboot"

# 没有 marker 的 Profile（Bunny）调用时必须是纯 no-op
printf '0 3 * * * /usr/local/bin/user-backup\n' >"${FAKE_CRONTAB_FILE}"
before=$(cat "${FAKE_CRONTAB_FILE}")
( unset CRON_REBOOT_MARKER
  PATH="${TMP_DIR}/bin:${PATH}" remove_daily_reboot_schedule ) \
    || fail "missing marker must not error"
assert_equal "missing marker leaves crontab untouched" "${before}" \
    "$(cat "${FAKE_CRONTAB_FILE}")"

# 过滤失败时必须放弃写入，不能清空整份 crontab
filter_managed_reboot_cron() { return 1; }
PATH="${TMP_DIR}/bin:${PATH}" remove_daily_reboot_schedule \
    && fail "filter failure should be reported"
assert_equal "filter failure keeps crontab" "${before}" "$(cat "${FAKE_CRONTAB_FILE}")"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/scheduled-maintenance.sh"

# configure_daily_reboot 遇到空 marker 时必须失败退出：空标记会让 awk 过滤输出全空，抹除管理员全部定时任务
( CRON_REBOOT_MARKER=""
  REBOOT_SCHEDULE_MODE=custom REBOOT_HOUR=5 \
      PATH="${TMP_DIR}/bin:${PATH}" configure_daily_reboot ) >/dev/null 2>&1 \
    && fail "configure_daily_reboot must refuse to run with an empty CRON_REBOOT_MARKER"
assert_equal "empty marker keeps crontab on configure_daily_reboot" "${before}" \
    "$(cat "${FAKE_CRONTAB_FILE}")"

# 有 marker 时写入受管任务并保留管理员条目
REBOOT_SCHEDULE_MODE=custom REBOOT_HOUR=5 CRON_REBOOT_MARKER="${CRON_REBOOT_MARKER}" \
    PATH="${TMP_DIR}/bin:${PATH}" configure_daily_reboot
assert_contains "managed reboot job written" "$(cat "${FAKE_CRONTAB_FILE}")" "0 5 * * *"
assert_contains "user cron survives reboot schedule" "$(cat "${FAKE_CRONTAB_FILE}")" "user-backup"

# 过滤失败时 configure_daily_reboot 也不得提交截断的 crontab
before_configure=$(cat "${FAKE_CRONTAB_FILE}")
filter_managed_reboot_cron() { return 1; }
( REBOOT_SCHEDULE_MODE=custom REBOOT_HOUR=6 CRON_REBOOT_MARKER="${CRON_REBOOT_MARKER}" \
      PATH="${TMP_DIR}/bin:${PATH}" configure_daily_reboot ) >/dev/null 2>&1 \
    && fail "configure_daily_reboot must report filter failure"
assert_equal "filter failure keeps crontab on configure_daily_reboot" "${before_configure}" \
    "$(cat "${FAKE_CRONTAB_FILE}")"

# 11. 只有完整快照才允许逐项恢复（部分快照不得推断“安装前不存在”）
systemctl() { :; }
stop_maintenance_services() { :; }
stop_services() { :; }
remove_globalping_refresh_timer() { :; }
remove_daily_reboot_schedule() { :; }
restore_install_snapshot() { printf 'RESTORED\n'; }
snapshot_dir="${EASY_ALL_GUARD_STATE_DIR}/backups"
mkdir -p "${snapshot_dir}"
: >"${snapshot_dir}/pre-install-ufw.active"
output=$(capture cleanup_partial_install_local || true)
assert_not_contains "partial snapshot must not restore" "${output}" "RESTORED"
assert_contains "partial snapshot is reported" "${output}" "未找到完整安装前快照"
: >"${snapshot_dir}/pre-install-complete"
output=$(capture cleanup_partial_install_local || true)
assert_contains "complete snapshot restores" "${output}" "RESTORED"
rm -rf -- "${EASY_ALL_GUARD_STATE_DIR}"

# 12. apt 窗口抑制器（事务化）：写入/恢复/自愈/失败保留
export EASY_ALL_POLICY_RC_OVERRIDE="${TMP_DIR}/policy-rc.d"
suspend_service_start || fail "suspend should succeed"
[[ -f "${EASY_ALL_POLICY_RC_OVERRIDE}" ]] || fail "policy-rc.d should be created"
assert_contains "policy file blocks start" "$(cat "${EASY_ALL_POLICY_RC_OVERRIDE}")" "exit 101"
[[ -f "$(easy_all_policy_pending_file)" ]] || fail "pending transaction should exist"
restore_service_start_policy || fail "restore should succeed"
[[ ! -e "${EASY_ALL_POLICY_RC_OVERRIDE}" ]] || fail "policy file should be removed"
[[ ! -f "$(easy_all_policy_pending_file)" ]] || fail "pending transaction should be cleared"

printf '#!/bin/sh\nexit 0\n' >"${EASY_ALL_POLICY_RC_OVERRIDE}"
suspend_service_start || fail "suspend over existing policy should succeed"
restore_service_start_policy || fail "restore over existing policy should succeed"
assert_equal "existing policy is restored" "#!/bin/sh
exit 0" "$(cat "${EASY_ALL_POLICY_RC_OVERRIDE}")"

# 模拟 SIGKILL 遗留：不调用 restore，下一次入口必须自愈
suspend_service_start || fail "second suspend should succeed"
recover_pending_service_policy || fail "pending transaction should self-heal"
assert_equal "leftover transaction restores original" "#!/bin/sh
exit 0" "$(cat "${EASY_ALL_POLICY_RC_OVERRIDE}")"
[[ ! -f "$(easy_all_policy_pending_file)" ]] || fail "self-heal clears pending"

# 恢复失败必须保留事务，供下次重试
suspend_service_start || fail "third suspend should succeed"
printf '#!/bin/sh\nexit 0\n' >"$(easy_all_policy_backup_file)"  # 占位后删除
rm -f -- "$(easy_all_policy_backup_file)"
sed -i '' 's/^HAD_PREVIOUS=0$/HAD_PREVIOUS=1/' "$(easy_all_policy_pending_file)" 2>/dev/null \
    || sed -i 's/^HAD_PREVIOUS=0$/HAD_PREVIOUS=1/' "$(easy_all_policy_pending_file)"
recover_pending_service_policy && fail "missing backup must fail"
[[ -f "$(easy_all_policy_pending_file)" ]] || fail "failed restore keeps pending for retry"
# 清理现场，避免影响后续用例
rm -rf -- "$(easy_all_policy_state_dir)" "${EASY_ALL_POLICY_RC_OVERRIDE}"

# 13. 跨模式清理：profile 映射齐全，未知模式拒绝猜测
assert_equal "reality maps to its profile" "reality.sh" "$(profile_script_for reality)"
assert_equal "bunny maps to its profile" "ws-bunny.sh" "$(profile_script_for bunny-ws)"
assert_equal "unknown mode is rejected" "1" \
    "$(profile_script_for nope >/dev/null 2>&1 && echo 0 || echo 1)"
output=$(capture run_recorded_profile_cleanup nope || true)
assert_contains "unknown recorded mode is explained" "${output}" "无法识别上次安装的模式"

# 14. 残留文件清理：只删传入路径，并清掉进度标记
mkdir -p "${TMP_DIR}/cleanup/conf.d" "${TMP_DIR}/cleanup/state/xray" \
    "${TMP_DIR}/cleanup/web" "${TMP_DIR}/cleanup/bin"
: >"${TMP_DIR}/cleanup/conf.d/easy_all.conf"
: >"${TMP_DIR}/cleanup/state/xray/config.json"
: >"${TMP_DIR}/cleanup/bin/easy_all"
install_progress_begin combined
cleanup_partial_install_files \
    "${TMP_DIR}/cleanup/conf.d/easy_all.conf" \
    "${TMP_DIR}/cleanup/state" \
    "${TMP_DIR}/cleanup/bin/easy_all"
[[ ! -e "${TMP_DIR}/cleanup/conf.d/easy_all.conf" ]] || fail "listed config should be removed"
[[ ! -e "${TMP_DIR}/cleanup/state" ]] || fail "listed state dir should be removed"
[[ ! -e "${TMP_DIR}/cleanup/bin/easy_all" ]] || fail "listed command should be removed"
[[ -d "${TMP_DIR}/cleanup/web" ]] || fail "unlisted paths must be kept"
[[ ! -f "${EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE}" ]] || fail "marker should be cleared"

# 15. 静态回归网：首次安装回滚必须清掉进度标记，并还原安装前 IPv6 配置
for profile in reality xhttp-cloudflare-streamup; do
    body=$(awk '/^rollback_fresh_install\(\) \{/,/^\}/' "${ROOT_DIR}/profiles/${profile}.sh")
    [[ "${body}" == *install_progress_clear* ]] \
        || fail "rollback_fresh_install in ${profile}.sh must clear the install marker"
    # 回滚随后会删掉 STATE_DIR（含 IPv6 快照）：还原必须发生在此之前。
    [[ "${body}" == *restore_preinstall_ipv6* ]] \
        || fail "rollback_fresh_install in ${profile}.sh must restore pre-install IPv6"
done

# 16. 提示文案必须与实际行为一致：无 marker 时引导 --assume-mode，而不是直接 cleanup-partial
hint=$(residue_recovery_hint)
assert_not_contains "hint without marker does not promise plain cleanup-partial" \
    "${hint}" "sudo easy_all cleanup-partial"
assert_contains "hint without marker offers --assume-mode" "${hint}" "--assume-mode"
install_progress_begin reality
hint=$(residue_recovery_hint)
assert_contains "hint with marker offers plain cleanup-partial" "${hint}" "sudo easy_all cleanup-partial"
install_progress_clear

# 17. launcher 标记快照：模式与身份必须来自同一次读取
mk_marker() {
    install -d -m 0700 "$(dirname "$1")"
    printf 'PROFILE=%s\nSTAGE=packages\nSTARTED_AT=%s\n' "$2" "$3" >"$1"
}
marker_file="${TMP_DIR}/identity/install-progress.env"
absent=$(bash -c 'source "$1"; launcher_marker_snapshot "$2"' _ "${ROOT_DIR}/easy_all" "${marker_file}")
assert_equal "identity is absent without marker" "absent" "${absent}"
mk_marker "${marker_file}" combined "T1"
present=$(bash -c 'source "$1"; launcher_marker_snapshot "$2"' _ "${ROOT_DIR}/easy_all" "${marker_file}")
assert_equal "snapshot encodes mode, stage and start time" "present|combined|packages|T1" "${present}"
mk_marker "${marker_file}" reality "T2"
replaced=$(bash -c 'source "$1"; launcher_marker_snapshot "$2"' _ "${ROOT_DIR}/easy_all" "${marker_file}")
[[ "${replaced}" != "${present}" ]] || fail "replaced marker must change identity"
[[ "${absent}" != "${present}" ]] || fail "appearing marker must change identity"
rm -f -- "${marker_file}"

# 18. 删除失败必须保留 marker 并返回非零
install_progress_begin combined
rm() { return 1; }
cleanup_partial_install_files "${TMP_DIR}/whatever" \
    && fail "delete failure must be reported"
[[ -f "${EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE}" ]] \
    || fail "delete failure must keep the marker for retry"
unset -f rm
install_progress_clear

# 19. 跨模式清理必须用独立进程，Bunny 部分清理必须停掉 nginx
body=$(awk '/^run_recorded_profile_cleanup\(\) \{/,/^\}/' "${ROOT_DIR}/lib/profile-common.sh")
[[ "${body}" == *"bash -c"* ]] || fail "cross-mode cleanup must run in a separate process"
bunny_body=$(awk '/^cleanup_partial_install\(\) \{/,/^\}/' "${ROOT_DIR}/profiles/ws-bunny.sh")
[[ "${bunny_body}" == *"systemctl disable --now nginx"* ]] \
    || fail "bunny partial cleanup must stop the restored default site"

# 20. policy 事务内容损坏时必须保留事务与原策略，不得把“读不出来”当成“原来没有”
export EASY_ALL_POLICY_RC_OVERRIDE="${TMP_DIR}/policy-rc.d"
rm -rf -- "$(easy_all_policy_state_dir)" "${EASY_ALL_POLICY_RC_OVERRIDE}"
install -d -m 0700 "$(easy_all_policy_state_dir)"
printf 'ORIGINAL-POLICY\n' >"${EASY_ALL_POLICY_RC_OVERRIDE}"
: >"$(easy_all_policy_pending_file)"                     # 空 pending
recover_pending_service_policy && fail "empty pending must fail"
[[ -f "$(easy_all_policy_pending_file)" ]] || fail "empty pending must be kept"
assert_equal "empty pending keeps original policy" "ORIGINAL-POLICY" \
    "$(cat "${EASY_ALL_POLICY_RC_OVERRIDE}")"

printf 'HAD_PREVIOUS=1\nOWNER_PID=1\n' >"$(easy_all_policy_pending_file)"   # 持有者仍活着
RUNTIME_WRITE_LOCK_DEPTH=1
recover_pending_service_policy || fail "foreign live owner must not fail"
RUNTIME_WRITE_LOCK_DEPTH=0
[[ -f "$(easy_all_policy_pending_file)" ]] || fail "live owner transaction must be kept"
assert_equal "live owner keeps policy untouched" "ORIGINAL-POLICY" \
    "$(cat "${EASY_ALL_POLICY_RC_OVERRIDE}")"
rm -rf -- "$(easy_all_policy_state_dir)" "${EASY_ALL_POLICY_RC_OVERRIDE}"

# 21. dpkg 状态：hold 的 nginx 也算已安装；unpacked/half-configured 不算
install -d -m 0755 "${TMP_DIR}/dpkgbin"
cat >"${TMP_DIR}/dpkgbin/dpkg-query" <<'FAKE_DPKG'
#!/usr/bin/env bash
cat "${FAKE_DPKG_STATUS:-/dev/null}"
FAKE_DPKG
chmod +x "${TMP_DIR}/dpkgbin/dpkg-query"
for case_spec in "install ok installed:0" "hold ok installed:0" "install ok unpacked:1" "install ok half-configured:1" "deinstall ok config-files:1"; do
    state=${case_spec%:*}
    expected=${case_spec##*:}
    printf '%s' "${state}" >"${TMP_DIR}/dpkg-status"
    actual=$(PATH="${TMP_DIR}/dpkgbin:${PATH}" FAKE_DPKG_STATUS="${TMP_DIR}/dpkg-status" \
        bash -c 'source "$1" >/dev/null 2>&1; nginx_package_installed' _ "${ROOT_DIR}/lib/profile-common.sh" \
        && echo 0 || echo 1)
    assert_equal "dpkg state ${state}" "${expected}" "${actual}"
done
rm -rf -- "${TMP_DIR}/dpkgbin"

# 22. Bunny 部分清理必须在删除失败时保留 marker（静态：调用方检查返回值）
bunny_cleanup_body=$(awk '/^cleanup_partial_install\(\) \{/,/^\}/' "${ROOT_DIR}/profiles/ws-bunny.sh")
[[ "${bunny_cleanup_body}" == *"bunny_remove_local ||"* ]] \
    || fail "bunny cleanup must check bunny_remove_local result before clearing marker"

# 23. Bunny 本机清理：安装前配置恢复失败时必须保留状态目录与备份
# shellcheck source=lib/firewall.sh
source "${ROOT_DIR}/lib/firewall.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/bunny-runtime.sh"
export STATE_DIR="${TMP_DIR}/bunny/state"
export BACKUP_DIR="${STATE_DIR}/backups"
export WEB_ROOT="${TMP_DIR}/bunny/web"
export XRAY_SERVICE="easy_all-xray.service"
export XRAY_SERVICE_FILE="${TMP_DIR}/bunny/units/easy_all-xray.service"
export BUNNY_REFRESH_SERVICE_FILE="${TMP_DIR}/bunny/units/bunny-ips.service"
export BUNNY_REFRESH_TIMER_FILE="${TMP_DIR}/bunny/units/bunny-ips.timer"
export CERT_RENEW_SERVICE_FILE="${TMP_DIR}/bunny/units/cert-renew.service"
export CERT_RENEW_TIMER_FILE="${TMP_DIR}/bunny/units/cert-renew.timer"
export NGINX_CONFIG="${TMP_DIR}/bunny/nginx/easy_all.conf"
export COMMAND_PATH="${TMP_DIR}/bunny/bin/easy_all"
export UFW_BEFORE_RULES="${TMP_DIR}/bunny/ufw-before.rules"
ufw() { :; }
systemctl() { :; }

prepare_bunny_fixture() {
    rm -rf -- "${TMP_DIR}/bunny"
    install -d -m 0700 "${STATE_DIR}" "${BACKUP_DIR}" "${WEB_ROOT}" \
        "$(dirname "${XRAY_SERVICE_FILE}")" "${TMP_DIR}/bunny/linger" \
        "${TMP_DIR}/bunny/nginx"
    printf 'ORIGINAL-UFW\n' >"${BACKUP_DIR}/pre-install-ufw-default"
    printf 'ORIGINAL-NGINX\n' >"${BACKUP_DIR}/pre-install-nginx-default"
    printf 'x\n' >"${STATE_DIR}/state.env"
}

# 恢复目标不可写 -> 必须失败、保留 backup 与状态目录
prepare_bunny_fixture
install -d -m 0500 "${TMP_DIR}/bunny/ro"
export UFW_DEFAULT_CONFIG="${TMP_DIR}/bunny/ro/ufw-default"
export NGINX_DEFAULT_SITE="${TMP_DIR}/bunny/sites-enabled/default"
bunny_remove_local && fail "restore failure must be reported"
[[ -f "${BACKUP_DIR}/pre-install-ufw-default" ]] || fail "failed restore must keep the backup"
[[ -f "${STATE_DIR}/state.env" ]] || fail "failed restore must keep the state dir"
chmod 0700 "${TMP_DIR}/bunny/ro"

# 恢复目标可写 -> 成功并删除状态目录
prepare_bunny_fixture
export UFW_DEFAULT_CONFIG="${TMP_DIR}/bunny/ufw-default"
install -d -m 0755 "$(dirname "${NGINX_DEFAULT_SITE}")"
bunny_remove_local || fail "successful cleanup must return 0"
[[ ! -d "${STATE_DIR}" ]] || fail "successful cleanup removes the state dir"
assert_equal "restored ufw default" "ORIGINAL-UFW" "$(cat "${UFW_DEFAULT_CONFIG}")"
assert_equal "restored nginx default site" "ORIGINAL-NGINX" "$(cat "${NGINX_DEFAULT_SITE}")"

# 23b. Bunny 回源防火墙必须同时建立 SSH 开机自启与 Fail2ban，且重复执行不堆叠规则
bunny_fw_dir="${TMP_DIR}/bunny-fw"
rm -rf -- "${bunny_fw_dir}"
install -d -m 0700 "${bunny_fw_dir}" "${TMP_DIR}/runtime"
printf '%s\n' '*filter' ':ufw-before-input - [0:0]' \
    '-A ufw-before-input -i lo -j ACCEPT' 'COMMIT' >"${bunny_fw_dir}/before.rules"
export SCRIPT_DIR="${ROOT_DIR}/lib"
export RUNTIME_TMP="${TMP_DIR}/runtime"
export UFW_BEFORE_RULES="${bunny_fw_dir}/before.rules"
export BUNNY_EDGE_IP_FILE="${bunny_fw_dir}/edge-ips"
bunny_wiring_log="${bunny_fw_dir}/wiring.log"

run_bunny_firewall_with_stubs() (
    curl() { printf '%s\n' '["198.51.100.0/24"]' >"${RUNTIME_TMP}/bunny-edges.json"; }
    iptables-restore() { :; }
    bunny_reject_ssh_443() { SSH_PORTS="2222"; }
    verify_ssh_ufw_no_unmanaged_block() { :; }
    disable_ufw_ipv6() { :; }
    apply_ssh_ufw_policy() { :; }
    ufw() { :; }
    ensure_ssh_boot_service() { printf '%s\n' 'ssh-boot' >>"${bunny_wiring_log}"; }
    ensure_ssh_fail2ban() { printf '%s\n' 'fail2ban' >>"${bunny_wiring_log}"; }
    bunny_refresh_firewall
)

: >"${bunny_wiring_log}"
run_bunny_firewall_with_stubs || fail "bunny_refresh_firewall must succeed with a stubbed firewall"
assert_equal "bunny firewall configures SSH boot safety and fail2ban" \
    $'ssh-boot\nfail2ban' "$(<"${bunny_wiring_log}")"
grep -qx -- '-A easy_all_bunny -s 198.51.100.0/24 -j ACCEPT' "${UFW_BEFORE_RULES}" \
    || fail "bunny firewall must allow the official edge pool"
grep -qx -- '-A easy_all_bunny -j DROP' "${UFW_BEFORE_RULES}" \
    || fail "bunny firewall must drop non-edge traffic to 443"
assert_equal "bunny edge pool persisted" "198.51.100.0/24" "$(<"${BUNNY_EDGE_IP_FILE}")"

run_bunny_firewall_with_stubs || fail "bunny firewall refresh must be idempotent"
assert_equal "bunny firewall block is not duplicated" "1" \
    "$(grep -c -- '-A easy_all_bunny -s 198.51.100.0/24 -j ACCEPT' "${UFW_BEFORE_RULES}")"
assert_equal "bunny firewall block has a single jump rule" "1" \
    "$(grep -c -- '-j easy_all_bunny' "${UFW_BEFORE_RULES}")"

# 23c. 安装前的 nginx 默认站点必须按快照恢复（Reality/XHTTP/组合的卸载与回滚路径）
(
    export BACKUP_DIR="${TMP_DIR}/site/state/backups"
    export EASY_ALL_GUARD_NGINX_DEFAULT_SITE="${TMP_DIR}/site/sites-enabled/default"
    install -d -m 0700 "${BACKUP_DIR}" "$(dirname "${EASY_ALL_GUARD_NGINX_DEFAULT_SITE}")"
    printf 'ORIGINAL-SITE\n' >"${EASY_ALL_GUARD_NGINX_DEFAULT_SITE}"
    snapshot_preinstall_nginx_default_site
    printf 'EASY-ALL-SERVED\n' >"${EASY_ALL_GUARD_NGINX_DEFAULT_SITE}"
    restore_preinstall_nginx_default_site || fail "site-restore: restore must succeed"
    assert_equal "site-restore: original default site is back" "ORIGINAL-SITE" \
        "$(<"${EASY_ALL_GUARD_NGINX_DEFAULT_SITE}")"

    # 安装前没有该文件：快照只写 .missing 标记，恢复=删除（保留“安装前不存在”的语义）
    rm -rf -- "${BACKUP_DIR}/pre-install-nginx-default"
    export EASY_ALL_GUARD_NGINX_DEFAULT_SITE="${TMP_DIR}/site2/sites-enabled/default"
    install -d -m 0700 "$(dirname "${EASY_ALL_GUARD_NGINX_DEFAULT_SITE}")"
    snapshot_preinstall_nginx_default_site
    [[ -f "${BACKUP_DIR}/pre-install-nginx-default.missing" ]] \
        || fail "site-restore: absent default site must be recorded"
    printf 'LATER-INSTALL\n' >"${EASY_ALL_GUARD_NGINX_DEFAULT_SITE}"
    restore_preinstall_nginx_default_site || fail "site-restore: restore must succeed"
    [[ ! -e "${EASY_ALL_GUARD_NGINX_DEFAULT_SITE}" ]] \
        || fail "site-restore: a site missing before install must stay removed"
) || fail "nginx default site snapshot/restore checks failed"

# 24. PID 复用导致遗留事务未能恢复时，suspend_service_start 绝不能覆盖原备份或重开事务
export EASY_ALL_POLICY_RC_OVERRIDE="${TMP_DIR}/policy-rc.d"
rm -rf -- "$(easy_all_policy_state_dir)" "${EASY_ALL_POLICY_RC_OVERRIDE}"
install -d -m 0700 "$(easy_all_policy_state_dir)"
printf 'ORIGINAL-POLICY\n' >"$(easy_all_policy_backup_file)"
printf '#!/bin/sh\nexit 101\n' >"${EASY_ALL_POLICY_RC_OVERRIDE}"
printf 'HAD_PREVIOUS=1\nOWNER_PID=1\n' >"$(easy_all_policy_pending_file)"
RUNTIME_WRITE_LOCK_DEPTH=1
suspend_status=0
suspend_output=$(capture suspend_service_start) || suspend_status=$?
RUNTIME_WRITE_LOCK_DEPTH=0
((suspend_status != 0)) || fail "suspend with unrecovered pending transaction must fail"
assert_contains "unrecovered pending warns about backup protection" "${suspend_output}" \
    "拒绝覆盖原备份"
assert_equal "backup keeps original policy" "ORIGINAL-POLICY" \
    "$(cat "$(easy_all_policy_backup_file)")"
assert_equal "target policy file stays untouched" "#!/bin/sh
exit 101" "$(cat "${EASY_ALL_POLICY_RC_OVERRIDE}")"
[[ -f "$(easy_all_policy_pending_file)" ]] || fail "pending file must still exist"
assert_equal "pending owner is not overwritten" $'HAD_PREVIOUS=1\nOWNER_PID=1' \
    "$(cat "$(easy_all_policy_pending_file)")"
rm -rf -- "$(easy_all_policy_state_dir)" "${EASY_ALL_POLICY_RC_OVERRIDE}"

# 25. --assume-mode 别名与无标记提示
alias_probe=$(bash -c 'source "$1"; for v in 5 组合 combined 1 直连 2 cf 3 bunny 4; do printf "%s=%s\n" "$v" "$(launcher_mode_alias "$v")"; done' _ "${ROOT_DIR}/easy_all")
assert_contains "alias 5 maps to combined" "${alias_probe}" "5=combined"
assert_contains "alias 组合 maps to combined" "${alias_probe}" "组合=combined"
assert_contains "alias 1 maps to reality" "${alias_probe}" "1=reality"
assert_contains "alias cf maps to cloudflare-streamup" "${alias_probe}" "cf=cloudflare-streamup"
assert_equal "unknown alias is rejected" "1" \
    "$(bash -c 'source "$1"; launcher_mode_alias 9 >/dev/null 2>&1' _ "${ROOT_DIR}/easy_all" && echo 0 || echo 1)"
assert_contains "usage lists menu numbers" "$(bash -c 'source "$1"; launcher_mode_usage' _ "${ROOT_DIR}/easy_all")" "3|bunny-ws 4|combined"

# 无标记残留 + 非交互：提示必须给出可用写法，而不是只报"不支持"
reset_artifacts
mkdir -p "${EASY_ALL_GUARD_STATE_DIR}/xray"
EASY_ALL_SELECTED_MODE=combined
output=$(capture prepare_fresh_install 80 </dev/null || true)
assert_contains "no-marker non-interactive names the command" "${output}" "cleanup-partial --assume-mode"
assert_contains "no-marker non-interactive lists accepted forms" "${output}" "4|combined"
rm -rf -- "${EASY_ALL_GUARD_STATE_DIR}"

# 26. 只有 Debian 默认站点但端口没被监听时，不得再报"端口被 nginx 占用"
reset_artifacts
mkdir -p "${EASY_ALL_GUARD_NGINX_SITES_DIR}" "${EASY_ALL_GUARD_NGINX_CONF_DIR}"
: >"${EASY_ALL_GUARD_NGINX_DEFAULT_SITE}"
idle
idle_rc=0
output=$(capture prepare_fresh_install 80 </dev/null || true)
assert_not_contains "idle candidate must not claim the port is busy" "${output}" "端口被 nginx 占用"
assert_not_contains "idle candidate must not prompt" "${output}" "确认这是上次安装残留"
capture prepare_fresh_install 80 </dev/null >/dev/null 2>&1 || idle_rc=$?
assert_equal "idle candidate lets the install continue" "0" "${idle_rc}"

# 端口被监听但占用者不是 nginx：不得说成 nginx 残留，应交给端口守卫报真实占用者
busy 80
FAKE_SS_OWNER=sshd
export FAKE_SS_OWNER
output=$(capture prepare_fresh_install 80 </dev/null || true)
assert_not_contains "non-nginx owner must not be called nginx residue" "${output}" "端口被 nginx 占用"
assert_contains "non-nginx owner falls through to the port guard" "${output}" "sshd"

# 占用者无法辨认（ss 无 users 信息）：同样不得栽给 nginx，交给端口守卫
FAKE_SS_OWNER="@none"
export FAKE_SS_OWNER
output=$(capture prepare_fresh_install 80 </dev/null || true)
assert_not_contains "unknown owner must not be called nginx residue" "${output}" "端口被 nginx 占用"
assert_contains "unknown owner falls through to the port guard" "${output}" "TCP 80 已被占用"
assert_contains "unknown owner keeps the dedicated-vps verdict" "${output}" "仅支持专用 VPS"

# 端口确实被 nginx 监听时才进入"归属不明"的确认分支
FAKE_SS_OWNER=nginx
export FAKE_SS_OWNER
output=$(capture prepare_fresh_install 80 </dev/null || true)
assert_contains "busy candidate refuses non-interactively" "${output}" "非交互安装无法确认 nginx 归属"
reset_artifacts
idle

# 17) 安装失败诊断：在独立脚本里复现生产路径（set -e + ERR/EXIT 陷阱）
# 不放在 $( ) 里直接 set -e：bash 默认在命令替换中清除 errexit，ERR 陷阱语义会随版本漂移。
run_failure_scenario() { # $1=EXIT 陷阱体
    local script="${TMP_DIR}/failure-scenario.sh"
    {
        printf 'set -Eeuo pipefail\n'
        printf 'source %q\n' "${ROOT_DIR}/lib/log.sh"
        printf 'RUNTIME_LIB_DIR=%q\n' "${ROOT_DIR}/lib"
        printf 'source %q\n' "${ROOT_DIR}/lib/profile-common.sh"
        printf 'install_failure_begin combined\n'
        printf 'install_progress_begin combined\n'
        printf 'install_progress_stage services\n'
        printf 'EASY_ALL_LAST_ERROR=%q\n' 'Cloudflare API 请求失败：GET /zones'
        printf 'trap %q EXIT\n' "$1"
        printf 'false\n'
    } >"${script}"
    bash "${script}" 2>&1
}

reset_artifacts
failure_report=$(run_failure_scenario 'install_failure_report') || true
assert_contains "failure-report: mode" "${failure_report}" "模式：combined"
assert_contains "failure-report: stage" "${failure_report}" \
    "失败阶段：services（服务、证书与防火墙）"
assert_contains "failure-report: location" "${failure_report}" "失败位置："
assert_contains "failure-report: source file" "${failure_report}" "failure-scenario.sh:"
assert_contains "failure-report: command" "${failure_report}" "失败命令：false"
assert_contains "failure-report: message" "${failure_report}" \
    "错误信息：Cloudflare API 请求失败：GET /zones"

# 18) 失败报告只打印一次（退出清理与后续调用不应重复刷屏）
reset_artifacts
once=$(run_failure_scenario 'install_failure_report; install_failure_report') || true
assert_equal "failure-report: printed once" "1" "$(grep -c '安装失败' <<<"${once}")"

# 18b) 展示阶段的失败不再算“安装失败”（避免成功安装尾部命令报错时误导）
reset_artifacts
disarmed=$(bash -c '
    set -Eeuo pipefail
    source "$1/lib/log.sh"
    RUNTIME_LIB_DIR="$1/lib"
    source "$1/lib/profile-common.sh"
    install_failure_begin combined
    INSTALL_FAILURE_ARMED=0
    trap "install_failure_report" EXIT
    false
' _ "${ROOT_DIR}" 2>&1) || true
assert_not_contains "failure-report: disarmed after commit" "${disarmed}" "安装失败"

confirm_out=$(printf 'n\n' | (
    read_confirmation '确认？' answer 2>/dev/null
    printf '%s' "${answer}"
))
assert_equal "confirmation: reads answer" "n" "${confirm_out}"

printf 'ok - install guard\n'
