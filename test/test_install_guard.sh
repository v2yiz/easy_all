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

# 5b. 旧 FQ helper 把开机快照放在了业务 STATE_DIR/backups/qdisc：卸载后只剩这条
#     严格空链时不能把机器当成“未完成安装”（否则永远无法重新安装）。
residue_present() {
    install_residue_reason >/dev/null 2>&1 && printf '0' || printf '1'
}
fq_chain_case() { # $1=变体，准备一个含严格空链或变体的状态目录
    reset_artifacts
    install -d -m 0700 "${EASY_ALL_GUARD_STATE_DIR}/backups/qdisc"
    : >"${EASY_ALL_GUARD_STATE_DIR}/runtime-write.lock"
    case "$1" in
    qdisc-json) printf '[]\n' >"${EASY_ALL_GUARD_STATE_DIR}/backups/qdisc/eth0.json" ;;
    qdisc-apply) printf '[]\n' >"${EASY_ALL_GUARD_STATE_DIR}/backups/qdisc/eth0.json.apply" ;;
    qdisc-hidden) : >"${EASY_ALL_GUARD_STATE_DIR}/backups/qdisc/.keep" ;;
    qdisc-lf-name) : >"${EASY_ALL_GUARD_STATE_DIR}/backups/qdisc/"$'\n' ;;
    qdisc-lf-symlink)
        : >"${TMP_DIR}/fq-lf-target"
        ln -s "${TMP_DIR}/fq-lf-target" "${EASY_ALL_GUARD_STATE_DIR}/backups/qdisc/"$'\n'
        ;;
    state-lf-extra) : >"${EASY_ALL_GUARD_STATE_DIR}/"$'\n' ;;
    pre-install) : >"${EASY_ALL_GUARD_STATE_DIR}/backups/pre-install-complete" ;;
    backups-extra-dir) install -d -m 0700 "${EASY_ALL_GUARD_STATE_DIR}/backups/certs" ;;
    state-extra) : >"${EASY_ALL_GUARD_STATE_DIR}/install-identity.json" ;;
    state-hidden) : >"${EASY_ALL_GUARD_STATE_DIR}/.hidden" ;;
    qdisc-symlink)
        install -d -m 0700 "${TMP_DIR}/fq-elsewhere/qdisc"
        rm -rf -- "${EASY_ALL_GUARD_STATE_DIR}/backups/qdisc"
        ln -s "${TMP_DIR}/fq-elsewhere/qdisc" "${EASY_ALL_GUARD_STATE_DIR}/backups/qdisc"
        ;;
    backups-symlink)
        install -d -m 0700 "${TMP_DIR}/fq-elsewhere-backups/qdisc"
        rm -rf -- "${EASY_ALL_GUARD_STATE_DIR}/backups"
        ln -s "${TMP_DIR}/fq-elsewhere-backups" "${EASY_ALL_GUARD_STATE_DIR}/backups"
        ;;
    esac
}
fq_chain_case empty
assert_equal "严格空链不算安装残留" "1" "$(residue_present)"
for variant in qdisc-json qdisc-apply qdisc-hidden pre-install backups-extra-dir \
    state-extra state-hidden qdisc-symlink backups-symlink qdisc-lf-name qdisc-lf-symlink \
    state-lf-extra; do
    fq_chain_case "${variant}"
    assert_equal "空链豁免不覆盖 ${variant}" "0" "$(residue_present)"
done
# marker 与服务判定不受空链豁免影响
fq_chain_case empty
install_progress_begin combined
output=$(capture install_residue_reason || true)
assert_contains "空链下的进度标记仍算残留" "${output}" "安装进度标记"
assert_not_contains "空链下的进度标记不再点名状态目录" "${output}" "未完成的状态目录"
install_progress_clear
fq_chain_case empty
install -d -m 0755 "$(dirname -- "${EASY_ALL_GUARD_SERVICE_FILE}")"
: >"${EASY_ALL_GUARD_SERVICE_FILE}"
output=$(capture install_residue_reason || true)
assert_contains "空链下的残留服务单元仍算残留" "${output}" "残留服务单元"
reset_artifacts
rm -rf -- "${TMP_DIR}/fq-elsewhere" "${TMP_DIR}/fq-elsewhere-backups"

# 6. 进度标记生命周期：写入、更新保留其他字段、清理删除目录
install_progress_begin combined
assert_equal "marker records profile" "combined" "$(install_progress_field PROFILE)"
install_progress_begin cloudfront cloudfront
assert_equal "marker records CloudFront chain" "cloudfront" "$(install_progress_field CHAIN)"
assert_equal "marker records CloudFront profile" "cloudfront" "$(install_progress_field PROFILE)"
install_progress_begin combined
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

# 8. nginx 占用端口时只报专用 VPS 结论，不再给出旧版本残留的猜测
reset_artifacts
busy 80
FAKE_SS_OWNER=nginx
export FAKE_SS_OWNER
output=$(capture assert_install_ports_free 80 || true)
assert_contains "nginx-owned port keeps dedicated-vps verdict" "${output}" "仅支持专用 VPS"
assert_not_contains "nginx-owned port does not guess a leftover" "${output}" "systemctl disable --now nginx"

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
# 定时重启的 cron 行需要 flock 抢运行时写锁，并写入锁路径；CI/沙箱不一定有 util-linux flock。
flock() { :; }
export RUNTIME_WRITE_LOCK_FILE="${TMP_DIR}/runtime-write.lock"

printf '0 3 * * * /usr/local/bin/user-backup\n0 4 * * * true # easy_all-managed-reboot\n' \
    >"${FAKE_CRONTAB_FILE}"
PATH="${TMP_DIR}/bin:${PATH}" remove_daily_reboot_schedule
assert_contains "user cron entry survives" "$(cat "${FAKE_CRONTAB_FILE}")" "user-backup"
assert_not_contains "managed reboot entry removed" "$(cat "${FAKE_CRONTAB_FILE}")" \
    "easy_all-managed-reboot"

# 没有 marker 的 Profile 调用时必须是纯 no-op
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
assert_equal "cloudfront maps to its profile" "cloudfront.sh" "$(profile_script_for cloudfront)"
assert_equal "combined maps to its profile" "combined.sh" "$(profile_script_for combined)"
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
body=$(awk '/^rollback_fresh_install\(\) \{/,/^\}/' "${ROOT_DIR}/profiles/reality.sh")
[[ "${body}" == *install_progress_clear* ]] \
    || fail "rollback_fresh_install in reality.sh must clear the install marker"
# 回滚随后会删掉 STATE_DIR（含 IPv6 快照）：还原必须发生在此之前。
[[ "${body}" == *restore_preinstall_ipv6* ]] \
    || fail "rollback_fresh_install in reality.sh must restore pre-install IPv6"

# 16. 残留提示文案：有标记时给 cleanup-partial，无标记时只能人工核对
install_progress_begin reality
hint=$(residue_recovery_hint)
assert_contains "hint with marker offers cleanup-partial" "${hint}" "sudo easy_all cleanup-partial"
install_progress_clear
hint=$(residue_recovery_hint)
assert_contains "hint without marker asks for manual review" "${hint}" "请人工核对后清理"
assert_not_contains "hint without marker does not promise cleanup-partial" \
    "${hint}" "sudo easy_all cleanup-partial"

# 17. launcher 标记快照：模式与身份必须来自同一次读取
mk_marker() {
    install -d -m 0700 "$(dirname "$1")"
    printf 'PROFILE=%s\nCHAIN=cloudfront\nSTAGE=packages\nSTARTED_AT=%s\n' "$2" "$3" >"$1"
}
marker_file="${TMP_DIR}/identity/install-progress.env"
absent=$(bash -c 'source "$1"; launcher_marker_snapshot "$2"' _ "${ROOT_DIR}/easy_all" "${marker_file}")
assert_equal "identity is absent without marker" "absent" "${absent}"
mk_marker "${marker_file}" combined "T1"
present=$(bash -c 'source "$1"; launcher_marker_snapshot "$2"' _ "${ROOT_DIR}/easy_all" "${marker_file}")
assert_equal "snapshot encodes mode, chain, stage and start time" \
    "present|combined|packages|T1|cloudfront" "${present}"
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

# 19. 跨模式清理必须用独立进程
body=$(awk '/^run_recorded_profile_cleanup\(\) \{/,/^\}/' "${ROOT_DIR}/lib/profile-common.sh")
[[ "${body}" == *"bash -c"* ]] || fail "cross-mode cleanup must run in a separate process"

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

# 23c. 安装前的 nginx 默认站点必须按快照恢复（Reality / 直连+CDN的卸载与回滚路径）
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

# 25. 无 progress marker 的残留：不再猜测模式，直接要求人工核对
reset_artifacts
mkdir -p "${EASY_ALL_GUARD_STATE_DIR}/xray"
EASY_ALL_SELECTED_MODE=combined
output=$(capture prepare_fresh_install 80 </dev/null || true)
assert_contains "markerless residue points at the marker file" "${output}" \
    "安装进度标记缺少模式信息"
# 该状态的标记没有模式信息，cleanup-partial 同样无法接管，提示不得把它当成出路
assert_not_contains "markerless residue does not loop back to cleanup-partial" \
    "${output}" "请先执行 sudo easy_all cleanup-partial"
rm -rf -- "${EASY_ALL_GUARD_STATE_DIR}"

# 标记存在但缺 PROFILE 时：同样给出可执行的人工核对指引，不推给 cleanup-partial
mkdir -p "${EASY_ALL_GUARD_STATE_DIR}/xray" "$(dirname -- "$(install_progress_file)")"
printf 'STAGE=services\nSTARTED_AT=1\n' >"$(install_progress_file)"
output=$(capture prepare_fresh_install 80 </dev/null || true)
assert_contains "marker without profile reports the missing mode" "${output}" \
    "安装进度标记缺少模式信息"
assert_not_contains "marker without profile does not loop back to cleanup-partial" \
    "${output}" "请先执行 sudo easy_all cleanup-partial"
rm -rf -- "${EASY_ALL_GUARD_STATE_DIR}"
rm -f -- "$(install_progress_file)"

# 26. 端口守卫不把 nginx 占用说成 easy_all 残留
reset_artifacts
busy 80
FAKE_SS_OWNER=sshd
export FAKE_SS_OWNER
output=$(capture prepare_fresh_install 80 </dev/null || true)
assert_contains "non-nginx owner falls through to the port guard" "${output}" "sshd"

FAKE_SS_OWNER="@none"
export FAKE_SS_OWNER
output=$(capture prepare_fresh_install 80 </dev/null || true)
assert_contains "unknown owner falls through to the port guard" "${output}" "TCP 80 已被占用"
assert_contains "unknown owner keeps the dedicated-vps verdict" "${output}" "仅支持专用 VPS"
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

# 27. 状态必需字段单一来源：launcher 分类与核心结构校验使用同一清单
launcher_fields_combined=$(bash -c 'source "$1"; cloudfront_state_required_fields combined-cloudfront' \
    _ "${ROOT_DIR}/easy_all")
launcher_fields_plain=$(bash -c 'source "$1"; cloudfront_state_required_fields cloudfront' \
    _ "${ROOT_DIR}/easy_all")
for field in VPS_PUBLIC_IPV4 CF_NODE_PREFIX OWNER_TOKEN DIRECT_DOMAIN DIRECT_NODE_NAME \
    REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID REALITY_TARGET; do
    assert_contains "combined 模式必需字段包含 ${field}" "${launcher_fields_combined}" "${field}"
done
assert_not_contains "模式 2 必需字段不含直连字段" "${launcher_fields_plain}" "DIRECT_DOMAIN"
assert_contains "两模式共同必需字段含 VPS_PUBLIC_IPV4" "${launcher_fields_plain}" "VPS_PUBLIC_IPV4"
launcher_body=$(<"${ROOT_DIR}/easy_all")
assert_contains "launcher 复用共享字段清单" "${launcher_body}" "cloudfront_state_required_fields"
assert_not_contains "launcher 不再自带重复的必需字段列表" "${launcher_body}" \
    "AWS_CLOUDFRONT_DISTRIBUTION_ID AWS_CLOUDFRONT_DOMAIN"
core_body=$(<"${ROOT_DIR}/lib/cloudfront-mode.sh")
assert_contains "核心结构校验复用共享字段清单" \
    "$(awk '/^cdn_validate_state_structure\(\)/,/^}/' <<<"${core_body}")" \
    'cloudfront_state_required_fields "${PROTOCOL}"'
assert_not_contains "核心不再保留重复的必需字段函数" "${core_body}" "cdn_state_required_fields()"

# launcher 分类：逐字段删除后必须判为不完整，完整状态仍判为完整
write_state_fixture() { # $1=文件 $2=协议
    local file=$1 protocol=$2 field
    {
        printf 'STATE_VERSION="0"\nPROTOCOL="%s"\nCDN_PROVIDER="aws"\n' "${protocol}"
        for field in VPS_PUBLIC_IPV4 CF_ZONE CLOUDFLARE_ZONE_ID CF_ORIGIN_DOMAIN CF_NODE_DOMAIN \
            SUBSCRIPTION_DOMAIN SUB_DOWNLOAD_NAME OWNER_TOKEN ALLOWED_TOKENS SUBSCRIPTION_CONFIG \
            VLESS_UUID CF_NODE_PREFIX XHTTP_PATH ORIGIN_HEADER_SECRET \
            AWS_CLOUDFRONT_DISTRIBUTION_ID AWS_CLOUDFRONT_DOMAIN AWS_ACM_CERTIFICATE_ARN; do
            printf '%s="值"\n' "${field}"
        done
        printf 'CDN_TRAFFIC_PROTECTION_GB="985"\n'
        [[ "${protocol}" == "cloudfront" ]] || printf '%s\n' \
            'DIRECT_DOMAIN="node.example.com"' 'DIRECT_NODE_NAME="n"' \
            'REALITY_TARGET="t.example.com:443"' 'REALITY_PRIVATE_KEY="p"' \
            'REALITY_PUBLIC_KEY="P"' 'REALITY_SHORT_ID="01"'
    } >"${file}"
}
launcher_state_complete() {
    bash -c 'source "$1"; launcher_cloudfront_state_complete "$2"' \
        _ "${ROOT_DIR}/easy_all" "$1"
}
fixture_dir="${TMP_DIR}/field-fixtures"
install -d -m 0700 "${fixture_dir}"
for protocol in cloudfront combined-cloudfront; do
    fixture="${fixture_dir}/${protocol}.env"
    write_state_fixture "${fixture}" "${protocol}"
    launcher_state_complete "${fixture}" || fail "完整 ${protocol} 状态必须判为完整"
    fields=$(bash -c 'source "$1"; cloudfront_state_required_fields "$2"' \
        _ "${ROOT_DIR}/easy_all" "${protocol}")
    while IFS= read -r field; do
        [[ -n "${field}" ]] || continue
        partial="${fixture_dir}/${protocol}.${field}.env"
        grep -v "^${field}=" "${fixture}" >"${partial}"
        launcher_state_complete "${partial}" \
            && fail "缺少 ${protocol}.${field} 不得判为完整状态"
done <<<"${fields}"
done
for field in VPS_PUBLIC_IPV4 CF_NODE_PREFIX OWNER_TOKEN DIRECT_DOMAIN; do
    assert_equal "示例字段 ${field} 已纳入字段清单" "1" \
        "$(grep -Ec "^${field}$" <<<"${launcher_fields_combined}")"
done

# 28. 不完整状态的卸载路由：两种协议、默认与 --purge-cloud 都只走本机通道
route_output=$(bash -c '
    source "$1"
    source "$(profile_file incomplete-cloudfront)"
    register_easy_all_command() { :; }
    uninstall_incomplete_cloudfront() { printf "LOCAL-ONLY\n"; }
    uninstall_all() { printf "STRICT\n"; }
    dispatch_profile_command incomplete-cloudfront uninstall
    dispatch_profile_command incomplete-combined-cloudfront uninstall --purge-cloud
    dispatch_profile_command cloudfront uninstall
    dispatch_profile_command combined-cloudfront uninstall --purge-cloud
' _ "${ROOT_DIR}/easy_all" 2>&1)
assert_equal "不完整走本机通道、完整走严格路径" \
    $'LOCAL-ONLY\nLOCAL-ONLY\nSTRICT\nSTRICT' "${route_output}"

# 真实卸载函数：只要本机清理，不调用 AWS/CF、不调用严格 load_state，并退出成功
incomplete_fixture="${fixture_dir}/incomplete-state.env"
incomplete_uninstall_output=""
incomplete_uninstall_status=0
run_incomplete_uninstall() { # $1=协议 $2=命令参数
    local protocol=$1 arg=${2:-}
    {
        printf 'STATE_VERSION="0"\nPROTOCOL="%s"\n' "${protocol}"
    } >"${incomplete_fixture}"
    INCOMPLETE_FIXTURE="${incomplete_fixture}" bash -c '
        set -Eeuo pipefail
        source "$1/profiles/cloudfront.sh"
        cdn_legacy_state_value() { sed -n "s/^$1=\"\(.*\)\"$/\1/p" "${INCOMPLETE_FIXTURE}"; }
        cdn_local_uninstall_common() { printf "LOCAL-ONLY\n"; }
        aws_cli() { printf "AWS-CALLED\n"; return 1; }
        cloudflare_api_request() { printf "CF-CALLED\n"; return 1; }
        load_state() { printf "STRICT-LOAD\n"; return 1; }
        require_root() { :; }
        FORCE=1
        uninstall_incomplete_cloudfront '"${arg}"'
    ' _ "${ROOT_DIR}" 2>&1
}
for protocol in cloudfront combined-cloudfront; do
    for arg in "" "--purge-cloud"; do
        incomplete_uninstall_status=0
        incomplete_uninstall_output=$(run_incomplete_uninstall "${protocol}" "${arg}") \
            || incomplete_uninstall_status=$?
        assert_equal "${protocol} ${arg:-default} 卸载退出 0" "0" "${incomplete_uninstall_status}"
        assert_contains "${protocol} ${arg:-default} 仅本机清理" \
            "${incomplete_uninstall_output}" "LOCAL-ONLY"
        assert_not_contains "${protocol} ${arg:-default} 不调用 AWS" \
            "${incomplete_uninstall_output}" "AWS-CALLED"
        assert_not_contains "${protocol} ${arg:-default} 不调用 Cloudflare" \
            "${incomplete_uninstall_output}" "CF-CALLED"
        assert_not_contains "${protocol} ${arg:-default} 不走严格 load_state" \
            "${incomplete_uninstall_output}" "STRICT-LOAD"
        assert_contains "${protocol} ${arg:-default} 保留云端资源" \
            "${incomplete_uninstall_output}" "云端资源已保留"
    done
done

# 29. 回滚失败：保留安装进度标记与安装前快照，且 cleanup-partial 可重试
rollback_fail_output=$(EASY_ALL_GUARD_STATE_DIR="${TMP_DIR}/rb-state" \
    EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE="${TMP_DIR}/rb-progress/install-progress.env" \
    bash -c '
        set -Eeuo pipefail
        source "$1/profiles/cloudfront.sh"
        install -d -m 0700 "${EASY_ALL_GUARD_STATE_DIR}/backups"
        : >"${EASY_ALL_GUARD_STATE_DIR}/backups/pre-install-complete"
        install_progress_begin combined cloudfront
        stop_maintenance_services() { :; }
        stop_services() { :; }
        restore_install_snapshot() { return 1; }
        remove_daily_reboot_schedule() { :; }
        cdn_print_cloud_inventory() { :; }
        status=0
        rollback_fresh_install || status=$?
        printf "STATUS=%s\n" "${status}"
        [[ -f "$(install_progress_file)" ]] && printf "MARKER=kept\n"
        [[ -f "${EASY_ALL_GUARD_STATE_DIR}/backups/pre-install-complete" ]] \
            && printf "SNAPSHOT=kept\n"
    ' _ "${ROOT_DIR}" 2>&1) || true
assert_contains "回滚失败必须非零" "${rollback_fail_output}" "STATUS=1"
assert_contains "回滚失败保留安装进度标记" "${rollback_fail_output}" "MARKER=kept"
assert_contains "回滚失败保留安装前快照" "${rollback_fail_output}" "SNAPSHOT=kept"
assert_contains "回滚失败提示重试 cleanup-partial" "${rollback_fail_output}" \
    "sudo easy_all cleanup-partial"
assert_not_contains "回滚失败不得宣称已清理" "${rollback_fail_output}" "云端资源已保留；确认不再使用"

rollback_retry_output=$(EASY_ALL_GUARD_STATE_DIR="${TMP_DIR}/rb-state2" \
    EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE="${TMP_DIR}/rb-progress2/install-progress.env" \
    bash -c '
        set -Eeuo pipefail
        source "$1/profiles/cloudfront.sh"
        install_progress_begin combined cloudfront
        stop_maintenance_services() { :; }
        stop_services() { :; }
        cleanup_partial_install_local() { :; }
        cdn_cleanup_legacy_globalping_artifacts() { :; }
        cdn_legacy_reclaim_origin_firewall_rules() { :; }
        remove_cdn_traffic_protection_timer() { :; }
        remove_certbot_deploy_hook() { :; }
        cdn_remove_origin_lineage() { :; }
        remove_daily_reboot_schedule() { :; }
        cleanup_partial_install_files() { install_progress_clear; }
        cdn_print_cloud_inventory() { :; }
        rollback_fresh_install
        [[ ! -f "$(install_progress_file)" ]] && printf "MARKER=cleared\n"
    ' _ "${ROOT_DIR}" 2>&1) || true
assert_contains "清理成功后才清标记" "${rollback_retry_output}" "MARKER=cleared"

# 30. 旧 cdn/combined 标记：不加载旧 Profile，不加载旧 Profile，用核心专用本机清理回收旧链路残留
legacy_classification=$(bash -c '
    source "$1"
    check() { launcher_marker_is_legacy_cloudflare "$1" "$2" && printf "%s|%s=legacy\n" "$1" "$2" || printf "%s|%s=new\n" "$1" "$2"; }
    check cdn ""
    check combined ""
    check combined cloudfront
    check cloudfront cloudfront
' _ "${ROOT_DIR}/easy_all" 2>&1)
assert_contains "旧 cdn 标记归为旧链路" "${legacy_classification}" "cdn|=legacy"
assert_contains "旧 combined 标记（无 CHAIN）归为旧链路" "${legacy_classification}" \
    "combined|=legacy"
assert_contains "新 combined 标记不是旧链路" "${legacy_classification}" \
    "combined|cloudfront=new"
assert_contains "新 cloudfront 标记不是旧链路" "${legacy_classification}" \
    "cloudfront|cloudfront=new"
cleanup_command_body=$(awk '/^cleanup_partial_install_command\(\)/,/^}/' "${ROOT_DIR}/easy_all")
assert_contains "cleanup-partial 按标记识别旧链路" "${cleanup_command_body}" \
    "launcher_marker_is_legacy_cloudflare"
assert_contains "旧链路改用核心本机清理" "${cleanup_command_body}" \
    "launcher_source_legacy_cleanup_core"
assert_not_contains "cleanup-partial 不再 source 已删的旧模块" \
    "${cleanup_command_body}" "profiles/cdn.sh"
[[ ! -e "${ROOT_DIR}/profiles/cdn.sh" ]] || fail "旧 profiles/cdn.sh 必须已删除"

legacy_cleanup_output=$(bash -c '
    set -Eeuo pipefail
    source "$1"
    launcher_source_legacy_cleanup_core
    cleanup_partial_install_local() { :; }
    cdn_cleanup_legacy_globalping_artifacts() { printf "GLOBALPING\n"; }
    cdn_legacy_reclaim_origin_firewall_rules() { printf "UFW-ORIGIN\n"; }
    remove_cdn_traffic_protection_timer() { :; }
    remove_certbot_deploy_hook() { printf "HOOK\n"; }
    cdn_remove_origin_lineage() { printf "LINEAGE\n"; }
    remove_daily_reboot_schedule() { :; }
    cleanup_partial_install_files() { printf "FILES %s\n" "$#"; install_progress_clear; }
    install_progress_begin cdn
    cleanup_partial_install
    [[ ! -f "$(install_progress_file)" ]] && printf "MARKER-CLEARED\n"
' _ "${ROOT_DIR}/easy_all" 2>&1) || true
for marker in GLOBALPING UFW-ORIGIN HOOK LINEAGE MARKER-CLEARED; do
    assert_contains "旧链路本机清理覆盖 ${marker}" "${legacy_cleanup_output}" "${marker}"
done
assert_contains "本机清理包含固定本机文件清单" "${legacy_cleanup_output}" "FILES 7"
core_cleanup_body=$(awk '/^cleanup_partial_install\(\)/,/^}/' "${ROOT_DIR}/lib/cloudfront-mode.sh")
assert_contains "新链路清理回收旧回源 UFW 规则" "${core_cleanup_body}" \
    "cdn_legacy_reclaim_origin_firewall_rules"
assert_contains "新链路清理删除自有 certbot lineage" "${core_cleanup_body}" \
    "cdn_remove_origin_lineage"
assert_not_contains "本机清理不调用 AWS" "${core_cleanup_body}" "aws_cli"
assert_not_contains "本机清理不调用 Cloudflare API" "${core_cleanup_body}" \
    "cloudflare_api_request"
lineage_body=$(awk '/^cdn_remove_origin_lineage\(\)/,/^}/' "${ROOT_DIR}/lib/cloudfront-mode.sh")
assert_contains "lineage 删除只用固定自有名称" "${lineage_body}" "CERTBOT_LINEAGE_NAME"
assert_not_contains "lineage 删除不碰其他站点目录" "${lineage_body}" "/etc/letsencrypt"

printf 'ok - install guard\n'
