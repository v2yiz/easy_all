#!/usr/bin/env bash

# Shared cron-backed optional reboot maintenance.

filter_managed_reboot_cron() {
    awk -v marker="${CRON_REBOOT_MARKER}" 'index($0, marker) == 0'
}

read_root_crontab() {
    local output status
    if output=$(LC_ALL=C crontab -l 2>&1); then
        printf '%s\n' "${output}"
        return 0
    else
        status=$?
    fi
    [[ "${output}" == "no crontab for "* ]] || \
        die "读取 root crontab 失败（退出码 ${status}）：${output:-无错误信息}"
}

# cron 行只调用本入口：vixie-cron/cronie 把单行命令限制在 1000 字节内（crontab
# MAX_COMMAND，超了直接 "command too long" 拒装），把预命令、抢锁与流量复核整段内联
# 进 crontab 会随逻辑增长迟早装不进去。下面的顺序与条件逐条对应旧内联行：
#   ( pre ) && if exec 8>lock && flock -n 8; then { check; } && reboot || logger …
#                else logger …; fi
internal_scheduled_reboot() {
    local pre_command="" locked_check="" reboot_bin
    local reboot_skip_message="easy_all 定时重启已跳过：运行时写锁不可用或正被占用"
    local locked_skip_message="easy_all 定时重启已跳过：CDN 流量保护处于停机/pending 或统计不可读"
    # *_OVERRIDE 是仓库既有的测试注入惯例（见 RUNTIME_WRITE_LOCK_FILE_OVERRIDE）。
    reboot_bin=${EASY_ALL_REBOOT_BIN_OVERRIDE:-/usr/sbin/reboot}
    if declare -F scheduled_reboot_profile_pre_command >/dev/null 2>&1; then
        pre_command=$(scheduled_reboot_profile_pre_command)
    fi
    # 预命令失败即短路：与旧行的 `( pre ) &&` 一致，既不记 logger 也不重启；
    # 但退出码也要与旧行一致 —— 旧行的失败码就是 pre 的码，所以显式传播它：
    # 写成 `|| return 0` 会把预命令失败谎报成成功，掩盖 cron 侧的故障。
    if [[ -n "${pre_command}" ]]; then
        sh -c "${pre_command}" || return $?
    fi
    if declare -F scheduled_reboot_profile_locked_check_command >/dev/null 2>&1; then
        locked_check=$(scheduled_reboot_profile_locked_check_command)
    fi
    # 抢不到写锁（安装/更新正在写运行时）时本轮不重启，只用 logger 留痕；
    # FD 8 是本进程独立打开的描述符，与 easy_all 进程持有的 FD 9 无关。
    # 不能在子 shell 里抢锁：子 shell 退出即释放，reboot 时已无锁可守。
    # 锁文件打不开（状态目录缺失/不可写）与抢不到锁共用同一条 skip 审计消息；
    # 只把「打开锁文件」这一步的 stderr 静默掉（{ …; } 2>/dev/null 作用域仅限该组），
    # 否则 cron 侧每次触发都会收到一封 "No such file or directory" 邮件。
    # 不能写成 `exec 8>lock 2>/dev/null`：`exec` 的 stderr 重定向会永久作用于本进程
    # （成功时把后续 reboot/日志的 stderr 一并吞掉），且打开失败的错误在 2>/dev/null
    # 生效之前就已输出，等于没静默。
    if ! { { exec 8>"${RUNTIME_WRITE_LOCK_FILE}"; } 2>/dev/null && flock -n 8; }; then
        logger -t easy_all "${reboot_skip_message}"
        return 0
    fi
    # 可选钩子：cron 最终取得写锁后只读复核保护状态，覆盖 pre-command 之后
    # 再次进入停机/pending 的竞态。旧行里 reboot 本身失败也会落到同一条 logger
    # 消息，这里保持同样语义，不另加区分。
    { [[ -z "${locked_check}" ]] || sh -c "${locked_check}"; } \
        && "${reboot_bin}" \
        || logger -t easy_all "${locked_skip_message}"
}

configure_daily_reboot() {
    local mode=${REBOOT_SCHEDULE_MODE:-} hour=${REBOOT_HOUR:-} job current filtered
    # 空标记会让 awk 过滤退化成“删掉所有行”，从而抹除管理员全部定时任务。
    [[ -n "${CRON_REBOOT_MARKER:-}" ]] \
        || die "CRON_REBOOT_MARKER 为空，已拒绝改写 root crontab"
    if [[ -z "${mode}" && -t 0 ]]; then
        printf '请选择定时重启策略：\n'
        printf '  1. 每天凌晨 4 点重启（默认）\n'
        printf '  2. 自定义每天几点重启（0-23）\n'
        printf '  3. 不配置定时重启\n'
        read_bilingual '请选择 [1]（直接回车使用默认值）:' mode
    fi
    mode=${mode:-1}
    case "${mode}" in
    1 | default)
        SCHEDULED_REBOOT_ENABLED=1
        SCHEDULED_REBOOT_HOUR="${DEFAULT_REBOOT_HOUR}"
        ;;
    2 | custom)
        [[ -n "${hour}" ]] || hour=$(prompt_value "每天重启小时（0-23）" "")
        [[ "${hour}" =~ ^[0-9]+$ ]] && ((10#${hour} <= 23)) \
            || die "重启小时无效：${hour}"
        SCHEDULED_REBOOT_ENABLED=1
        SCHEDULED_REBOOT_HOUR="${hour}"
        ;;
    3 | none | off | disabled)
        SCHEDULED_REBOOT_ENABLED=0
        SCHEDULED_REBOOT_HOUR=""
        ;;
    *) die "定时重启选项无效：${mode}" ;;
    esac
    # 内部入口 internal_scheduled_reboot 在 reboot 前需要非阻塞抢同一把运行时写锁；
    # 缺 flock 时 cron 行本身仍能装进 crontab，但每次触发都会在 `flock -n 8` 处
    # 找不到命令（127）→ 记一条「写锁不可用」skip 日志后返回 0，即每次触发都跳过重启
    # （有 syslog 留痕，不再静默），因此安装期仍然要在这里直接报错。
    if [[ "${SCHEDULED_REBOOT_ENABLED}" == "1" ]] && ! command -v flock >/dev/null 2>&1; then
        die "缺少 flock；无法生成可靠的定时重启任务（重启前需要非阻塞获取运行时写锁）"
    fi
    current=$(read_root_crontab) || return 1
    if [[ "${SCHEDULED_REBOOT_ENABLED}" == "1" ]]; then
        # 整行只有一句对本工具内部入口的调用：抢占运行时写锁、模式 2/4 的流量复核
        # 与跳过审计都在 internal_scheduled_reboot 里，行长度不再随逻辑增长
        # （crontab 单行 1000 字节上限，超了报 "command too long" 拒装）。
        job="0 ${SCHEDULED_REBOOT_HOUR} * * * ${COMMAND_PATH}"
        job+=" internal-scheduled-reboot ${CRON_REBOOT_MARKER}"
    fi
    # 与 remove_daily_reboot_schedule 一致：先确认过滤成功再提交，管道中途失败时
    # crontab - 会收到截断输入并覆写整份 crontab。
    filtered=$(printf '%s\n' "${current}" | filter_managed_reboot_cron) \
        || die "过滤 root crontab 失败，已取消写入以免清空 crontab"
    { printf '%s\n' "${filtered}"; \
        [[ -z "${job:-}" ]] || printf '%s\n' "${job}"; } | crontab - \
        || die "写入 root crontab 失败"
}

refresh_saved_daily_reboot_schedule() {
    if [[ "${SCHEDULED_REBOOT_ENABLED:-0}" == "1" ]]; then
        REBOOT_SCHEDULE_MODE=custom
        REBOOT_HOUR="${SCHEDULED_REBOOT_HOUR}"
    else
        REBOOT_SCHEDULE_MODE=none
        REBOOT_HOUR=""
    fi
    configure_daily_reboot
}

remove_daily_reboot_schedule() {
    local current filtered
    # 没有该标记的 Profile 不应走到这里：空标记会让过滤退化成“删掉所有行”。
    [[ -n "${CRON_REBOOT_MARKER:-}" ]] || return 0
    current=$(read_root_crontab) || return 1
    # 先确认过滤成功，再提交给 crontab：管道中途失败时 crontab - 会收到空输入并清空整份 crontab。
    filtered=$(printf '%s\n' "${current}" | filter_managed_reboot_cron) \
        || { warn "过滤 root crontab 失败，已取消写入以免清空 crontab"; return 1; }
    printf '%s\n' "${filtered}" | crontab - \
        || { warn "移除 easy_all 定时重启任务失败，请手动检查 root crontab"; return 1; }
}

restore_preinstall_crontab() {
    if [[ -f "${BACKUP_DIR}/pre-install-crontab" ]]; then
        crontab "${BACKUP_DIR}/pre-install-crontab" >/dev/null 2>&1 \
            || warn "恢复安装前 root crontab 失败"
    elif [[ -f "${BACKUP_DIR}/pre-install-crontab.missing" ]]; then
        crontab -r >/dev/null 2>&1 || true
    fi
}
