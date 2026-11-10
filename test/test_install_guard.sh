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
export EASY_ALL_GUARD_SERVICE_FILE="${TMP_DIR}/systemd/easy_all-singbox.service"
export EASY_ALL_GUARD_CADDY_CONFIG="${TMP_DIR}/caddy/Caddyfile"
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
# 状态 schema 常量与字段集是单一来源：profile-common 的进度/身份写入直接使用它们。
# shellcheck source=lib/state.sh
source "${ROOT_DIR}/lib/state.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/profile-common.sh"

# die 只退出当前子 shell：capture() 用 $( ) 包起来即可拿到消息与状态。
die() { printf '%s\n' "$*" >&2; exit 1; }
warn() { printf '%s\n' "$*" >&2; }

busy() { printf '%s\n' "$@" >"${FAKE_SS_BUSY_PORTS}"; }
idle() { rm -f -- "${FAKE_SS_BUSY_PORTS}"; }
reset_artifacts() {
    rm -rf -- "${TMP_DIR}/state" "${TMP_DIR}/systemd" "${TMP_DIR}/caddy" \
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

# 1b. 调用方会把多端口字符串作为一个参数传入（模式 4 的 "443 8443"）：
#     整串交给 ss 会拼出非法表达式并被 2>/dev/null 吞掉，端口占用检查会静默失效。
busy 8443
FAKE_SS_OWNER=nginx
export FAKE_SS_OWNER
output=$(capture assert_install_ports_free "443 8443" || true)
assert_contains "多端口字符串必须逐端口检查" "${output}" "TCP 8443 已被占用"
idle

# 2. 第三方占用保持原文案，并点名占用进程
busy 80
FAKE_SS_OWNER=sshd
export FAKE_SS_OWNER
output=$(capture assert_install_ports_free 80 || true)
assert_contains "third-party owner is reported" "${output}" "sshd"
assert_contains "third-party keeps original hint" "${output}" "easy_all 仅支持专用 VPS"
assert_not_contains "third-party is not called residue" "${output}" "cleanup-partial"

# 3. 自身残留占用：给出去残留指引而不是「仅支持专用 VPS」
install_progress_begin combined-cloudfront
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
mkdir -p "$(dirname "${EASY_ALL_GUARD_CADDY_CONFIG}")"
: >"${EASY_ALL_GUARD_CADDY_CONFIG}"
assert_equal "installed state is never residue" "1" \
    "$(install_residue_reason >/dev/null 2>&1 && echo 0 || echo 1)"
output=$(capture assert_install_ports_free 80 || true)
assert_contains "installed-but-busy port still warns" "${output}" "easy_all 仅支持专用 VPS"

# 5. 残留识别：状态目录、服务单元、Caddy 配置、进度标记
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
mkdir -p "$(dirname "${EASY_ALL_GUARD_CADDY_CONFIG}")"
: >"${EASY_ALL_GUARD_CADDY_CONFIG}"
output=$(capture install_residue_reason || true)
assert_contains "leftover caddy config is residue" "${output}" "残留 Caddy 配置"

rm -f -- "${EASY_ALL_GUARD_CADDY_CONFIG}"
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
install_progress_begin anytls
assert_equal "rebegin resets stage" "start" "$(install_progress_field STAGE)"
assert_equal "rebegin replaces profile" "anytls" "$(install_progress_field PROFILE)"
install_progress_clear
[[ ! -f "${EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE}" ]] \
    || fail "clearing the marker removes the file"
[[ ! -d "$(dirname "${EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE}")" ]] \
    || fail "clearing the marker removes the empty directory"

# 6b. 标记链路身份：四种模式各自接受同链路标记，其他链路一律拒绝
# （回归：模式 1 的 anytls 链被漏掉，中断后续装总被要求清理重装）。
while read -r marker_profile marker_chain; do
    install_progress_begin "${marker_profile}" "${marker_chain}"
    install_marker_chain_matches "${marker_profile}" \
        || fail "标记链路 ${marker_chain} 必须匹配模式 ${marker_profile}"
done <<'MARKER_CASES'
anytls anytls
cloudfront cloudfront
combined-cloudfront cloudfront
cloudflare cloudflare
MARKER_CASES
install_progress_begin combined-cloudfront cloudfront
for wrong_profile in anytls cloudflare; do
    if install_marker_chain_matches "${wrong_profile}"; then
        fail "标记链路 cloudfront 不得匹配模式 ${wrong_profile}"
    fi
done
install_progress_clear

# 6c. 安装身份带 Origin Rule ID：中断后能定位已创建的云端规则
install -d -m 0700 "$(install_state_dir_path)"
PROTOCOL=anytls
CDN_PROFILE_KEY=anytls
CLOUDFLARE_ORIGIN_RULESET_ID=rs-identity
CLOUDFLARE_ORIGIN_RULE_ID=rule-identity
persist_install_identity || fail "安装身份写入失败"
identity_file=$(install_identity_file)
assert_equal "安装身份保存 Origin Rule ID" \
    "rs-identity/rule-identity" \
    "$(jq -r '.cloudflare_origin_ruleset_id + "/" + .cloudflare_origin_rule_id' "${identity_file}")"
CLOUDFLARE_ORIGIN_RULESET_ID=""
CLOUDFLARE_ORIGIN_RULE_ID=""
load_install_identity || fail "安装身份读取失败；无法安全续装"
assert_equal "续装恢复 Origin Rule ID" "rs-identity/rule-identity" \
    "${CLOUDFLARE_ORIGIN_RULESET_ID}/${CLOUDFLARE_ORIGIN_RULE_ID}"
rm -f -- "${identity_file}"
unset PROTOCOL CDN_PROFILE_KEY

# 6d. 订阅模式是安装身份的一部分：link 安装续装时必须恢复 link，
#     否则会拿默认 deploy 覆盖已下发的订阅契约。
install -d -m 0700 "$(install_state_dir_path)"
PROTOCOL=anytls
CDN_PROFILE_KEY=anytls
SUBSCRIPTION_MODE=link
persist_install_identity || fail "安装身份写入失败"
assert_equal "安装身份保存订阅模式" "link" \
    "$(jq -r '.subscription_mode // ""' "$(install_identity_file)")"
SUBSCRIPTION_MODE=deploy
load_install_identity || fail "安装身份读取失败；无法安全续装"
assert_equal "续装恢复订阅模式" "link" "${SUBSCRIPTION_MODE}"
rm -f -- "$(install_identity_file)"
unset PROTOCOL CDN_PROFILE_KEY SUBSCRIPTION_MODE

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
assert_equal "anytls maps to its profile" "anytls.sh" "$(profile_script_for anytls)"
assert_equal "cloudfront maps to its profile" "cloudfront.sh" "$(profile_script_for cloudfront)"
assert_equal "cloudflare maps to its profile" "cloudflare.sh" "$(profile_script_for cloudflare)"
assert_equal "combined-cloudfront maps to its profile" "combined.sh" \
    "$(profile_script_for combined-cloudfront)"
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
install_progress_begin combined-cloudfront
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
body=$(awk '/^rollback_fresh_install\(\) \{/,/^\}/' "${ROOT_DIR}/lib/anytls-mode.sh")
[[ "${body}" == *cleanup_partial_install* ]] \
    || fail "rollback_fresh_install in anytls-mode.sh must run the partial cleanup (clears the marker)"
[[ "${body}" == *cdn_print_cloud_inventory* ]] \
    || fail "rollback_fresh_install in anytls-mode.sh must report retained cloud resources"
cleanup_common_body=$(awk '/^cdn_local_uninstall_common\(\) \{/,/^\}/' "${ROOT_DIR}/lib/anytls-mode.sh")
# 回滚清理会删掉 STATE_DIR（含 IPv6 快照）：还原必须发生在其中。
[[ "${cleanup_common_body}" == *restore_preinstall_ipv6* ]] \
    || fail "anytls local uninstall must restore pre-install IPv6 before deleting the state dir"

# 16. 残留提示文案：有标记时给 cleanup-partial，无标记时只能人工核对
install_progress_begin anytls
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
    printf 'SCHEMA=1\nPROFILE=%s\nCHAIN=cloudfront\nSTAGE=packages\nSTARTED_AT=%s\n' "$2" "$3" >"$1"
}
marker_file="${TMP_DIR}/identity/install-progress.env"
absent=$(bash -c 'source "$1"; launcher_marker_snapshot "$2"' _ "${ROOT_DIR}/easy_all" "${marker_file}")
assert_equal "identity is absent without marker" "absent" "${absent}"
mk_marker "${marker_file}" combined-cloudfront "T1"
present=$(bash -c 'source "$1"; launcher_marker_snapshot "$2"' _ "${ROOT_DIR}/easy_all" "${marker_file}")
assert_equal "snapshot encodes mode, chain, stage, start time and schema" \
    "present|combined-cloudfront|packages|T1|cloudfront|1" "${present}"
mk_marker "${marker_file}" anytls "T2"
replaced=$(bash -c 'source "$1"; launcher_marker_snapshot "$2"' _ "${ROOT_DIR}/easy_all" "${marker_file}")
[[ "${replaced}" != "${present}" ]] || fail "replaced marker must change identity"
[[ "${absent}" != "${present}" ]] || fail "appearing marker must change identity"
rm -f -- "${marker_file}"

# 18. 删除失败必须保留 marker 并返回非零
install_progress_begin combined-cloudfront
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
        printf 'source %q\n' "${ROOT_DIR}/lib/state.sh"
        printf 'source %q\n' "${ROOT_DIR}/lib/profile-common.sh"
        printf 'install_failure_begin combined-cloudfront\n'
        printf 'install_progress_begin combined-cloudfront\n'
        printf 'install_progress_stage services\n'
        printf 'EASY_ALL_LAST_ERROR=%q\n' 'Cloudflare API 请求失败：GET /zones'
        printf 'trap %q EXIT\n' "$1"
        printf 'false\n'
    } >"${script}"
    bash "${script}" 2>&1
}

reset_artifacts
failure_report=$(run_failure_scenario 'install_failure_report') || true
assert_contains "failure-report: mode" "${failure_report}" "模式：combined-cloudfront"
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
launcher_fields_combined=$(bash -c 'source "$1/lib/state.sh"; state_required_fields combined-cloudfront' \
    _ "${ROOT_DIR}")
launcher_fields_plain=$(bash -c 'source "$1/lib/state.sh"; state_required_fields cloudfront' \
    _ "${ROOT_DIR}")
for field in VPS_PUBLIC_IPV4 CF_NODE_PREFIX OWNER_TOKEN DIRECT_DOMAIN DIRECT_NODE_NAME \
    ANYTLS_PASSWORD; do
    assert_contains "combined 模式必需字段包含 ${field}" "${launcher_fields_combined}" "${field}"
done
assert_not_contains "模式 2 必需字段不含直连字段" "${launcher_fields_plain}" "DIRECT_DOMAIN"
assert_contains "两模式共同必需字段含 VPS_PUBLIC_IPV4" "${launcher_fields_plain}" "VPS_PUBLIC_IPV4"
assert_not_contains "字段清单不再保留 Reality 字段" "${launcher_fields_combined}" "REALITY_"
launcher_body=$(<"${ROOT_DIR}/easy_all")
assert_contains "launcher 复用共享字段清单" "${launcher_body}" "state_missing_fields"
assert_not_contains "launcher 不再自带重复的必需字段函数" "${launcher_body}" \
    "cloudfront_state_required_fields"
assert_not_contains "launcher 不再引用已删除的旧状态库" "${launcher_body}" \
    "cloudflare_state_required_fields"
core_body=$(<"${ROOT_DIR}/lib/runtime-core.sh")
assert_contains "核心结构校验复用共享字段清单" \
    "$(awk '/^cdn_validate_state_structure\(\)/,/^}/' <<<"${core_body}")" \
    'state_required_fields "${protocol}"'
assert_contains "核心结构校验复用“值可为空”规则" \
    "$(awk '/^cdn_validate_state_structure\(\)/,/^}/' <<<"${core_body}")" \
    "state_field_allows_empty"

# launcher 分类：逐字段删除后必须判为不完整，完整状态仍判为完整。
write_state_fixture() { # $1=文件 $2=协议 $3=订阅模式
    local file=$1 protocol=$2 subscription_mode=${3:-deploy} field
    {
        printf 'STATE_VERSION="1"\n'
        printf 'PROTOCOL="%s"\n' "${protocol}"
        printf 'SUBSCRIPTION_MODE="%s"\n' "${subscription_mode}"
        while IFS= read -r field; do
            case "${field}" in
            PROTOCOL | SUBSCRIPTION_MODE) continue ;;
            CDN_TRAFFIC_PROTECTION_GB) printf '%s="985"\n' "${field}" ;;
            SCHEDULED_REBOOT_ENABLED) printf '%s="0"\n' "${field}" ;;
            SCHEDULED_REBOOT_HOUR) printf '%s="4"\n' "${field}" ;;
            *) printf '%s="值"\n' "${field}" ;;
            esac
        done < <(state_required_fields "${protocol}" "${subscription_mode}")
    } >"${file}"
}
launcher_state_complete() {
    bash -c 'source "$1"; launcher_state_complete "$2"' \
        _ "${ROOT_DIR}/easy_all" "$1"
}
fixture_dir="${TMP_DIR}/field-fixtures"
install -d -m 0700 "${fixture_dir}"
for protocol in anytls cloudfront cloudflare combined-cloudfront; do
    fixture="${fixture_dir}/${protocol}.env"
    write_state_fixture "${fixture}" "${protocol}"
    launcher_state_complete "${fixture}" || fail "完整 ${protocol} 状态必须判为完整"
    fields=$(bash -c 'source "$1/lib/state.sh"; state_required_fields "$2"' _ "${ROOT_DIR}" "${protocol}")
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

# 27b. 「字段存在」与「值非空」必须区分：合法空值仍算完整，真正缺字段只剩卸载通道。
empty_reboot_fixture="${fixture_dir}/empty-reboot.env"
sed 's/^SCHEDULED_REBOOT_HOUR=.*/SCHEDULED_REBOOT_HOUR=""/' \
    "${fixture_dir}/combined-cloudfront.env" >"${empty_reboot_fixture}"
launcher_state_complete "${empty_reboot_fixture}" \
    || fail "关闭定时重启时 HOUR 可为空，仍应判为完整"
sed 's/^SCHEDULED_REBOOT_ENABLED=.*/SCHEDULED_REBOOT_ENABLED="1"/' \
    "${empty_reboot_fixture}" >"${fixture_dir}/enabled-empty-hour.env"
launcher_state_complete "${fixture_dir}/enabled-empty-hour.env" \
    && fail "启用定时重启时空 HOUR 必须判为不完整"

link_fixture="${fixture_dir}/anytls-link.env"
write_state_fixture "${link_fixture}" anytls link
printf 'MIHOMO_TEMPLATE_SNAPSHOT=""\n' >>"${link_fixture}"
launcher_state_complete "${link_fixture}" \
    || fail "模式 1 link 不发布模板快照，空值仍应判为完整"
assert_equal "模式 1 link 不要求订阅域名" "0" \
    "$(grep -c '^SUBSCRIPTION_DOMAIN=' "${link_fixture}" || true)"
deploy_without_snapshot="${fixture_dir}/cloudfront-empty-snapshot.env"
sed 's/^MIHOMO_TEMPLATE_SNAPSHOT=.*/MIHOMO_TEMPLATE_SNAPSHOT=""/' \
    "${fixture_dir}/cloudfront.env" >"${deploy_without_snapshot}"
launcher_state_complete "${deploy_without_snapshot}" \
    && fail "有订阅站点的模式不得接受空模板快照"

# 28. 不完整状态的卸载路由：两种不完整协议都只走本机通道，完整状态走严格路径
route_output=$(bash -c '
    source "$1"
    source "$(profile_file incomplete-cloudfront)"
    register_easy_all_command() { :; }
    uninstall_incomplete() { printf "LOCAL-ONLY\n"; }
    uninstall_all() { printf "STRICT\n"; }
    dispatch_profile_command incomplete-cloudfront uninstall
    dispatch_profile_command incomplete-combined-cloudfront uninstall --purge-cloud
    dispatch_profile_command cloudfront uninstall
    dispatch_profile_command combined-cloudfront uninstall --purge-cloud
' _ "${ROOT_DIR}/easy_all" 2>&1)
assert_equal "不完整走本机通道、完整走严格路径" \
    $'LOCAL-ONLY\nLOCAL-ONLY\nSTRICT\nSTRICT' "${route_output}"

# 真实卸载函数：只要本机清理，不调用 AWS/CF、不调用严格 load_state，并退出成功
incomplete_uninstall_output=""
incomplete_uninstall_status=0
run_incomplete_uninstall() { # $1=命令参数
    local arg=${1:-} status=0
    local case_dir="${TMP_DIR}/incomplete-uninstall"
    mkdir -p "${case_dir}/state" "${case_dir}/subscriptions/data" \
        "${case_dir}/bin" "${case_dir}/singbox" "${case_dir}/caddy" \
        "${case_dir}/units"
    : >"${case_dir}/state/state.env"
    EASY_ALL_STATE_DIR_OVERRIDE="${case_dir}/state" \
    EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${case_dir}/subscriptions/data" \
    COMMAND_INSTALL_DIR="${case_dir}/bin" \
    COMMAND_PATH="${case_dir}/bin/easy_all" \
    SINGBOX_BIN="${case_dir}/singbox/sing-box" \
    CADDY_BIN="${case_dir}/caddy/caddy" \
    SINGBOX_SERVICE_FILE="${case_dir}/units/easy_all-singbox.service" \
    CADDY_SERVICE_FILE="${case_dir}/units/easy_all-caddy.service" \
    bash -c '
        set -Eeuo pipefail
        source "$1/profiles/cloudfront.sh"
        require_root() { :; }
        acquire_runtime_write_lock() { :; }
        stop_maintenance_services() { :; }
        stop_services() { :; }
        systemctl() { :; }
        # 内核边界替身：本测试不触碰宿主 iptables；生产路径失败关闭由 metering 门禁覆盖。
        remove_cdn_traffic_protection_timer() { :; }
        cdn_traffic_counters_remove() { :; }
        remove_certbot_deploy_hook() { :; }
        certificate_remove_lineage() { :; }
        restore_platform_security_state() { :; }
        restore_preinstall_firewall() { :; }
        restore_preinstall_ipv6() { :; }
        remove_daily_reboot_schedule() { :; }
        aws_cli() { printf "AWS-CALLED\n"; return 1; }
        cloudflare_api_request() { printf "CF-CALLED\n"; return 1; }
        load_state() { printf "STRICT-LOAD\n"; return 1; }
        FORCE=1
        uninstall_incomplete '"${arg}"'
    ' _ "${ROOT_DIR}" 2>&1 || status=$?
    printf '%s\n' "${status}"
}
for arg in "" "--purge-cloud"; do
    incomplete_uninstall_output=$(run_incomplete_uninstall "${arg}")
    incomplete_uninstall_status=${incomplete_uninstall_output##*$'\n'}
    assert_equal "incomplete uninstall ${arg:-default} 退出 0" "0" "${incomplete_uninstall_status}"
    assert_contains "incomplete uninstall ${arg:-default} 保留云端资源" \
        "${incomplete_uninstall_output}" "云端资源已保留"
    assert_not_contains "incomplete uninstall ${arg:-default} 不调用 AWS" \
        "${incomplete_uninstall_output}" "AWS-CALLED"
    assert_not_contains "incomplete uninstall ${arg:-default} 不调用 Cloudflare" \
        "${incomplete_uninstall_output}" "CF-CALLED"
    assert_not_contains "incomplete uninstall ${arg:-default} 不走严格 load_state" \
        "${incomplete_uninstall_output}" "STRICT-LOAD"
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
        cdn_traffic_counters_remove() { :; }
        remove_certbot_deploy_hook() { :; }
        cdn_remove_origin_lineage() { :; }
        remove_daily_reboot_schedule() { :; }
        cleanup_partial_install_files() { install_progress_clear; }
        cdn_print_cloud_inventory() { :; }
        rollback_fresh_install
        [[ ! -f "$(install_progress_file)" ]] && printf "MARKER=cleared\n"
    ' _ "${ROOT_DIR}" 2>&1) || true
assert_contains "清理成功后才清标记" "${rollback_retry_output}" "MARKER=cleared"

# 29b. restore_state_file 失败语义：返回非零，调用方（回滚）必须继续并保留恢复材料
restore_dir="${TMP_DIR}/restore-semantics"
mkdir -p "${restore_dir}/backup"
printf 'STATE_VERSION=1\n' >"${restore_dir}/backup/state.env"
restore_state_call() { # $1=目标 $2=是否注入 mv 失败
    local target=$1 fail_mv=${2:-0}
    bash -c '
        set -Eeuo pipefail
        source "$1/lib/state.sh"
        source "$1/lib/profile-common.sh"
        die() { printf "DIE:%s\n" "$*" >&2; exit 1; }
        fail() { printf "FAIL:%s\n" "$*" >&2; return 1; }
        cleanup_files=()
        if [[ "${FAIL_MV:-0}" == "1" ]]; then mv() { return 1; }; fi
        status=0
        restore_state_file "$2" "$3" || status=$?
        printf "STATUS=%s\n" "${status}"
    ' _ "${ROOT_DIR}" "${restore_dir}/backup/state.env" "${target}" 2>&1
}
restore_temp_output=$(FAIL_MV=0 restore_state_call "${restore_dir}/missing/state.env") \
    || true
assert_contains "恢复暂存创建失败必须返回错误" "${restore_temp_output}" \
    "创建状态恢复暂存文件失败"
assert_contains "恢复暂存创建失败必须返回 1" "${restore_temp_output}" "STATUS=1"
assert_not_contains "恢复暂存创建失败不得 die 退出整个回滚" "${restore_temp_output}" "DIE:"
mkdir -p "${restore_dir}/target"
restore_mv_output=$(FAIL_MV=1 restore_state_call "${restore_dir}/target/state.env") \
    || true
assert_contains "恢复最终 mv 失败必须返回错误" "${restore_mv_output}" \
    "原子恢复状态文件失败"
assert_contains "恢复最终 mv 失败必须返回 1" "${restore_mv_output}" "STATUS=1"
assert_not_contains "恢复最终 mv 失败不得 die 退出整个回滚" "${restore_mv_output}" "DIE:"

# 状态恢复失败：其余文件继续恢复，RUNTIME_TMP（含 part.* 备份）保留，临时 API 凭据删除。
preserve_dir="${TMP_DIR}/rollback-preserve"
mkdir -p "${preserve_dir}/tmp"
preserve_output=$(
    TMPDIR="${preserve_dir}/tmp" \
    RUNTIME_TMP= \
    EASY_ALL_STATE_DIR_OVERRIDE="${preserve_dir}/state" \
    EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${preserve_dir}/subs" \
    EASY_ALL_CERT_DIR_OVERRIDE="${preserve_dir}/state/certs" \
    RUNTIME_WRITE_LOCK_FILE_OVERRIDE="${preserve_dir}/runtime-write.lock" \
        bash -c '
            set -Eeuo pipefail
            source "$1/profiles/anytls.sh"
            printf "%s\n" "${RUNTIME_TMP}" >"$2"
            mkdir -p "${STATE_DIR}" "${CERT_DIR}" "${SUBSCRIPTION_DIR}"
            UPDATE_SUB_BACKUP_DIR=$(make_temp_dir)
            printf "old-state\n" >"${UPDATE_SUB_BACKUP_DIR}/state.env"
            printf "new-cert\n" >"${CERT_FILE}"
            printf "old-cert\n" >"${UPDATE_SUB_BACKUP_DIR}/certificate.pem"
            UPDATE_SUB_ROLLBACK_NO_RESTART=1
            mv() { return 1; }
            status=0
            rollback_subscription_update || status=$?
            printf "ROLLBACK-STATUS=%s CERT=%s PRESERVE=%s\n" "${status}" \
                "$(cat "${CERT_FILE}")" "${PRESERVE_RUNTIME_TMP:-unset}"
            printf "headers\n" >"${RUNTIME_TMP}/cloudflare-api-headers"
            printf "payload\n" >"${RUNTIME_TMP}/cloudflare-api-payload"
            cleanup
            printf "RUNTIME-TMP-EXISTS=%s\n" \
                "$([[ -d "${RUNTIME_TMP}" ]] && echo yes || echo no)"
            printf "HEADERS-EXISTS=%s PAYLOAD-EXISTS=%s\n" \
                "$([[ -e "${RUNTIME_TMP}/cloudflare-api-headers" ]] && echo yes || echo no)" \
                "$([[ -e "${RUNTIME_TMP}/cloudflare-api-payload" ]] && echo yes || echo no)"
        ' _ "${ROOT_DIR}" "${preserve_dir}/runtime-path" 2>&1
) || true
assert_contains "回滚中的状态恢复失败不得中止其余恢复" "${preserve_output}" \
    "ROLLBACK-STATUS=0"
assert_contains "状态恢复失败后证书继续恢复" "${preserve_output}" "CERT=old-cert"
assert_contains "状态恢复失败后设置保留临时目录" "${preserve_output}" "PRESERVE=1"
assert_contains "状态恢复失败后打印备份路径" "${preserve_output}" \
    "状态文件回滚失败；已保留回滚备份"
assert_contains "清理后 RUNTIME_TMP 仍存在" "${preserve_output}" "RUNTIME-TMP-EXISTS=yes"
assert_contains "保留前删除 API 请求头" "${preserve_output}" "HEADERS-EXISTS=no"
assert_contains "保留前删除 API 请求体" "${preserve_output}" "PAYLOAD-EXISTS=no"
preserve_runtime=$(<"${preserve_dir}/runtime-path")
[[ -d "${preserve_runtime}" ]] || fail "状态恢复失败后 RUNTIME_TMP 必须保留"
[[ -n "$(find "${preserve_runtime}" -maxdepth 1 -name 'part.*' -print -quit)" ]] \
    || fail "保留的 RUNTIME_TMP 必须包含 part.* 回滚备份"
[[ -z "$(find "${preserve_runtime}" -maxdepth 2 \
    \( -name 'cloudflare-api-headers' -o -name 'cloudflare-api-payload' \) -print -quit)" ]] \
    || fail "保留的 RUNTIME_TMP 不得残留 API 凭据文件"

# 29c. AnyTLS 凭据钩子：模式 1 安装尾部不再 command not found，保留目录不残留 Bearer Token
anytls_hook_body=$(bash -c 'source "$1/profiles/anytls.sh"; declare -F clear_profile_credentials' \
    _ "${ROOT_DIR}" 2>&1) || fail "AnyTLS 必须定义 clear_profile_credentials（127 退出的根因）"
assert_contains "AnyTLS 凭据钩子已定义" "${anytls_hook_body}" "clear_profile_credentials"
anytls_hook_output=$(
    RUNTIME_TMP="${TMP_DIR}/anytls-hook-runtime" \
        bash -c '
            set -Eeuo pipefail
            source "$1/profiles/anytls.sh"
            mkdir -p "${RUNTIME_TMP}"
            printf "Bearer secret-token\n" >"${RUNTIME_TMP}/cloudflare-api-headers"
            printf "payload\n" >"${RUNTIME_TMP}/cloudflare-api-payload"
            CLOUDFLARE_API_TOKEN=secret-token
            clear_profile_credentials
            [[ ! -e "${RUNTIME_TMP}/cloudflare-api-headers" ]] || exit 4
            [[ ! -e "${RUNTIME_TMP}/cloudflare-api-payload" ]] || exit 5
            [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]] || exit 6
            printf "HOOK-OK\n"
        ' _ "${ROOT_DIR}" 2>&1
) || fail "AnyTLS 凭据钩子调用失败（模式 1 安装尾部会以 127 退出）"
assert_contains "AnyTLS 钩子删除请求头/请求体并清空 Token" "${anytls_hook_output}" "HOOK-OK"

# 29d. 确认阶段收到 INT/TERM：凭据在确认入口之前已清除，130/143 退出且跳过回滚与后续清理。
# 不分配终端、不后台运行：替身直接进入确认阶段并向自身发送信号，避免依赖 pty/python3。
# 必须使用真实的 clear_profile_credentials（CloudFront 钩子覆盖 AWS 变量），只检查哨兵文件与变量。
confirm_dir="${TMP_DIR}/confirm-signal"
for confirm_signal in INT TERM; do
    confirm_case="${confirm_dir}/${confirm_signal}"
    mkdir -p "${confirm_case}/state" "${confirm_case}/subs" "${confirm_case}/runtime"
    confirm_expected=130
    if [[ "${confirm_signal}" == "TERM" ]]; then
        confirm_expected=143
    fi
    cat >"${confirm_case}/confirm.sh" <<'SCRIPT'
set -Eeuo pipefail
source "${EASY_ALL_TEST_ROOT}/profiles/cloudfront.sh"
install_cleanup_perform() { : >"${CONFIRM_PERFORM}"; }
install_cleanup_after_failure() {
    : >"${CONFIRM_READY}"
    local precheck=ok
    [[ ! -e "${RUNTIME_TMP}/cloudflare-api-headers" ]] || precheck=fail
    [[ ! -e "${RUNTIME_TMP}/cloudflare-api-payload" ]] || precheck=fail
    [[ ! -e "${RUNTIME_TMP}/origin-header" ]] || precheck=fail
    [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]] || precheck=fail
    [[ -z "${AWS_ACCESS_KEY_ID:-}" ]] || precheck=fail
    [[ -z "${AWS_SECRET_ACCESS_KEY:-}" ]] || precheck=fail
    printf '%s\n' "${precheck}" >"${CONFIRM_PRECHECK}"
    kill -"${CONFIRM_SIGNAL}" $$
    : >"${CONFIRM_AFTER}"
}
mkdir -p "${RUNTIME_TMP}"
printf 'Authorization: Bearer sentinel-token\n' >"${RUNTIME_TMP}/cloudflare-api-headers"
printf 'payload\n' >"${RUNTIME_TMP}/cloudflare-api-payload"
printf 'origin-header\n' >"${RUNTIME_TMP}/origin-header"
CLOUDFLARE_API_TOKEN=not-a-real-token
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
INSTALL_ROLLBACK_ON_EXIT=1
exit 1
SCRIPT
    confirm_status=0
    EASY_ALL_TEST_ROOT="${ROOT_DIR}" \
    CONFIRM_SIGNAL="${confirm_signal}" \
    CONFIRM_READY="${confirm_case}/ready" \
    CONFIRM_PRECHECK="${confirm_case}/precheck" \
    CONFIRM_AFTER="${confirm_case}/after" \
    CONFIRM_PERFORM="${confirm_case}/perform" \
    RUNTIME_TMP="${confirm_case}/runtime" \
    EASY_ALL_STATE_DIR_OVERRIDE="${confirm_case}/state" \
    EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${confirm_case}/subs" \
        bash "${confirm_case}/confirm.sh" >"${confirm_case}/output.log" 2>&1 \
        || confirm_status=$?
    confirm_result="STATUS=${confirm_status} READY=$([[ -e "${confirm_case}/ready" ]] \
        && echo yes || echo no) PRECHECK=$(cat "${confirm_case}/precheck" 2>/dev/null || true) \
        AFTER=$([[ -e "${confirm_case}/after" ]] && echo yes || echo no) \
        PERFORM=$([[ -e "${confirm_case}/perform" ]] && echo yes || echo no)"
    assert_contains "确认阶段 ${confirm_signal} 以 ${confirm_expected} 退出" \
        "${confirm_result}" "STATUS=${confirm_expected}"
    assert_contains "确认阶段 ${confirm_signal} 确实到达确认入口" "${confirm_result}" "READY=yes"
    assert_contains "确认阶段 ${confirm_signal} 进入确认前凭据已清除" "${confirm_result}" "PRECHECK=ok"
    assert_contains "确认阶段 ${confirm_signal} 跳过后续清理" "${confirm_result}" "AFTER=no"
    assert_contains "确认阶段 ${confirm_signal} 不执行回滚" "${confirm_result}" "PERFORM=no"
done

# 29e. verify-cores 临时目录：自建的成功/失败路径回收，外部注入的不删除。
verify_stub_repo="${TMP_DIR}/verify-cores-repo"
mkdir -p "${verify_stub_repo}"
cp -R "${ROOT_DIR}/lib" "${ROOT_DIR}/profiles" "${ROOT_DIR}/scripts" \
    "${ROOT_DIR}/templates" "${verify_stub_repo}/"
cat >"${verify_stub_repo}/lib/singbox-core.sh" <<'STUB'
EASY_ALL_SINGBOX_CORE_LOADED=1
SINGBOX_VERSION=1.14.4
singbox_version() { printf '%s\n' "${SINGBOX_VERSION}"; }
singbox_binary_version() { [[ -x "$1" ]] && printf '%s\n' "${SINGBOX_VERSION}"; }
singbox_installed_version() { singbox_binary_version "${SINGBOX_BIN}"; }
download_singbox() {
    install -d -m 0755 "$(dirname "${SINGBOX_BIN}")"
    printf '#!/bin/sh\nexit 0\n' >"${SINGBOX_BIN}"
    chmod 0755 "${SINGBOX_BIN}"
}
install_singbox_service() { :; }
STUB
cat >"${verify_stub_repo}/lib/caddy-core.sh" <<'STUB'
EASY_ALL_CADDY_CORE_LOADED=1
CADDY_VERSION=2.11.9
caddy_version() { printf '%s\n' "${CADDY_VERSION}"; }
caddy_binary_version() { [[ -x "$1" ]] && printf 'v%s\n' "${CADDY_VERSION}"; }
caddy_installed_version() { caddy_binary_version "${CADDY_BIN}"; }
download_caddy() {
    install -d -m 0755 "$(dirname "${CADDY_BIN}")"
    printf '#!/bin/sh\nexit 0\n' >"${CADDY_BIN}"
    chmod 0755 "${CADDY_BIN}"
}
install_caddy_service() { :; }
STUB
verify_success_tmp="${TMP_DIR}/verify-success-tmp"
mkdir -p "${verify_success_tmp}"
verify_success_output=$(
    TMPDIR="${verify_success_tmp}" \
    RUNTIME_TMP= \
    EASY_ALL_DOWNLOAD_CORES=1 \
    SINGBOX_BIN="${TMP_DIR}/verify-core-bin/sing-box" \
    CADDY_BIN="${TMP_DIR}/verify-core-bin/caddy" \
        bash "${verify_stub_repo}/scripts/verify-cores.sh" 2>&1
) || fail "verify-cores 成功路径未通过：${verify_success_output}"
assert_contains "verify-cores 成功完成" "${verify_success_output}" "ok - verify-cores 完成"
[[ -z "$(find "${verify_success_tmp}" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
    || fail "verify-cores 成功退出必须回收自建临时目录"

verify_fail_tmp="${TMP_DIR}/verify-fail-tmp"
mkdir -p "${verify_fail_tmp}" "${TMP_DIR}/verify-fake-bin"
printf '#!/usr/bin/env bash\nexit 6\n' >"${TMP_DIR}/verify-fake-bin/curl"
chmod 0755 "${TMP_DIR}/verify-fake-bin/curl"
verify_fail_output=$(
    TMPDIR="${verify_fail_tmp}" \
    RUNTIME_TMP= \
    EASY_ALL_DOWNLOAD_CORES=1 \
    PATH="${TMP_DIR}/verify-fake-bin:${PATH}" \
        bash "${ROOT_DIR}/scripts/verify-cores.sh" 2>&1
) || true
assert_contains "verify-cores 下载失败如实报错" "${verify_fail_output}" "下载 sing-box 归档失败"
[[ -z "$(find "${verify_fail_tmp}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)" ]] \
    || fail "verify-cores 下载失败退出必须回收自建临时目录"

verify_external="${TMP_DIR}/verify-external-runtime"
mkdir -p "${verify_external}"
verify_external_output=$(
    TMPDIR="${verify_fail_tmp}" \
    RUNTIME_TMP="${verify_external}" \
    EASY_ALL_DOWNLOAD_CORES=1 \
    PATH="${TMP_DIR}/verify-fake-bin:${PATH}" \
        bash "${ROOT_DIR}/scripts/verify-cores.sh" 2>&1
) || true
assert_contains "verify-cores 外部注入失败仍如实报错" "${verify_external_output}" \
    "下载 sing-box 归档失败"
[[ -d "${verify_external}" ]] || fail "verify-cores 不得删除外部注入的 RUNTIME_TMP"

# 29f. bootstrap SIGTERM 回收暂存目录（e2e）。
# register-command 的 TERM 回收需要 root 且会替换 /usr/local/lib，非 root CI 无法 e2e；
# 这里只做静态核对，并在交付证据中说明限制，不写成已验证。
if command -v python3 >/dev/null 2>&1; then
    bootstrap_dir="${TMP_DIR}/bootstrap-term"
    mkdir -p "${bootstrap_dir}/tmp-root" "${bootstrap_dir}/bin"
    cat >"${bootstrap_dir}/bin/id" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then printf '0\n'; exit 0; fi
exec /usr/bin/id "$@"
STUB
    cat >"${bootstrap_dir}/bin/mktemp" <<'STUB'
#!/usr/bin/env bash
dir="${BOOTSTRAP_TMP_ROOT}/tmp.$$.${RANDOM}"
mkdir -p "${dir}" || exit 1
printf '%s\n' "${dir}"
STUB
    cat >"${bootstrap_dir}/bin/git" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$$" >"${BOOTSTRAP_GIT_PID}"
printf 'ready\n' >"${BOOTSTRAP_READY}"
sleep 30
STUB
    chmod 0755 "${bootstrap_dir}/bin/id" "${bootstrap_dir}/bin/mktemp" \
        "${bootstrap_dir}/bin/git"
    bootstrap_result=$(
        BOOTSTRAP_TMP_ROOT="${bootstrap_dir}/tmp-root" \
        BOOTSTRAP_GIT_PID="${bootstrap_dir}/git.pid" \
        BOOTSTRAP_READY="${bootstrap_dir}/ready" \
        BOOTSTRAP_LOG="${bootstrap_dir}/bootstrap.log" \
        EASY_ALL_STATE_FILE_OVERRIDE="${bootstrap_dir}/no-state" \
        EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE="${bootstrap_dir}/no-marker" \
        PATH="${bootstrap_dir}/bin:${PATH}" \
            python3 - "${ROOT_DIR}/bootstrap.sh" <<'PY'
import os, signal, sys, time
pid = os.fork()
if pid == 0:
    log = os.open(os.environ["BOOTSTRAP_LOG"], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.dup2(log, 1)
    os.dup2(log, 2)
    os.setsid()
    os.execvpe("bash", ["bash", sys.argv[1], "help"], os.environ)
deadline = time.time() + 10
while time.time() < deadline and not os.path.exists(os.environ["BOOTSTRAP_READY"]):
    time.sleep(0.05)
if not os.path.exists(os.environ["BOOTSTRAP_READY"]):
    os.kill(pid, signal.SIGKILL)
    print("READY-TIMEOUT")
    sys.exit(3)
os.killpg(os.getpgid(pid), signal.SIGTERM)
_, status = os.waitpid(pid, 0)
code = os.WEXITSTATUS(status) if os.WIFEXITED(status) else 128 + os.WTERMSIG(status)
print("STATUS=%d" % code)
PY
    ) || fail "bootstrap SIGTERM e2e 驱动失败"
    assert_contains "bootstrap 收到 SIGTERM 以 143 退出" "${bootstrap_result}" "STATUS=143"
    [[ -z "$(find "${bootstrap_dir}/tmp-root" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
        || fail "bootstrap 收到 SIGTERM 必须回收临时目录"
else
    printf 'skip - 缺少 python3，无法验证 bootstrap SIGTERM 回收\n' >&2
fi
register_static=$(sed -n \
    '/if \[\[ "\${command}" == "register-command" \]\]/,/unified_register_easy_all_command/p' \
    "${ROOT_DIR}/easy_all")
assert_contains "register-command 保留 EXIT 清理" "${register_static}" "trap cleanup EXIT"
assert_contains "register-command 显式处理 SIGTERM" "${register_static}" "trap 'exit 143' TERM"
assert_contains "register-command 显式处理 SIGINT" "${register_static}" "trap 'exit 130' INT"

# 30. 旧 cdn/combined 标记：launcher 不加载已删除的 Profile，只保留新键路由
legacy_route=$(bash -c '
    source "$1"
    for mode in cdn combined combined-cloudflare reality; do
        # launcher_die 直接退出进程：每个模式必须在独立子 shell 里探测。
        if ( profile_file "${mode}" >/dev/null 2>&1 ); then
            printf "%s=loaded\n" "${mode}"
        else
            printf "%s=rejected\n" "${mode}"
        fi
    done
    printf "combined-cloudfront=%s\n" "$(basename "$(profile_file combined-cloudfront)")"
' _ "${ROOT_DIR}/easy_all" 2>&1)
for legacy in cdn combined combined-cloudflare reality; do
    assert_contains "旧模式 ${legacy} 不加载 Profile" "${legacy_route}" "${legacy}=rejected"
done
assert_contains "模式 4 路由到 combined.sh" "${legacy_route}" "combined-cloudfront=combined.sh"
[[ ! -e "${ROOT_DIR}/profiles/cdn.sh" ]] || fail "旧 profiles/cdn.sh 必须已删除"

# 新链路清理删除自有 certbot lineage，且不调用云端 API
core_cleanup_body=$(awk '/^cleanup_partial_install\(\)/,/^}/' "${ROOT_DIR}/lib/cloudfront-mode.sh")
assert_contains "新链路清理删除自有 certbot lineage" "${core_cleanup_body}" \
    "certificate_remove_lineage"
assert_not_contains "本机清理不调用 AWS" "${core_cleanup_body}" "aws_cli"
assert_not_contains "本机清理不调用 Cloudflare API" "${core_cleanup_body}" \
    "cloudflare_api_request"
lineage_body=$(awk '/^certificate_remove_lineage\(\)/,/^}/' "${ROOT_DIR}/lib/runtime-core.sh")
assert_contains "lineage 删除只用固定自有名称" "${lineage_body}" "CERTBOT_LINEAGE_NAME"

# 运行时清单完整性：漏登的文件不会随 install/self-update 安装，已安装机器上直接缺模块。
missing_from_manifest=""
for runtime_file in "${ROOT_DIR}"/lib/*.sh "${ROOT_DIR}"/profiles/*.sh "${ROOT_DIR}"/templates/*; do
    runtime_relative=${runtime_file#"${ROOT_DIR}/"}
    grep -qxF -- "${runtime_relative}" "${ROOT_DIR}/runtime.manifest" \
        || missing_from_manifest+=" ${runtime_relative}"
done
assert_equal "runtime.manifest 覆盖全部运行时文件" "" "${missing_from_manifest}"
assert_contains "manifest 包含 AnyTLS 模式库" "$(<"${ROOT_DIR}/runtime.manifest")" \
    "lib/anytls-mode.sh"

printf 'ok - install guard\n'
