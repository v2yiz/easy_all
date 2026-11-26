#!/usr/bin/env bash
# 直连 TCP 443 主动探测日志（design v3 §8.2）：
#   1. unit 与 journald drop-in 的内容与幂等
#   2. 内核规则形态（默认网卡 / ! -i lo 回退）、查询失败不盲插、重放后恰一条
#   3. 模式矩阵：1/3/5/6 apply，2/4 remove，cloudfront 守卫不接受其他协议
#   4. 窄锚点：apply/install 中探测同步在最后一次 UFW reload 之后
#   5. rule-only 内部入口不写 unit、不取 runtime 锁；unit 缺失时仍清理历史规则
#   6. 全局保留上限失败与卸载恢复失败都可见，不假报成功
#   7. 清理保守性：缺 iptables / 查询失败不得当成「已清理」
#   8. 分析前规则快照校验（同一 `-A INPUT` 行同时含 DPT 443 与固定 LOG 前缀）
#   9. 分析样本：参照、关联窗口、低频候选、窗口外、WARN/ERROR、畸形记录
#  10. 直接 source（set -u、无 EASY_ALL_ROOT）与帮助/前置检查文案区分
#
# 所有外部特权与防火墙命令（ip / iptables / systemctl / journalctl / ufw / sshd /
# fail2ban-client / crontab / ss / curl）都经 PATH stub；stub 记录每次调用，未预设的
# 调用直接失败并写入 unstubbed.log。本文件不接触真实 /etc、真实 systemd、真实
# iptables 或真实 journal。
set -Eeuo pipefail

TESTS_ASSERTED=0
SKIPPED_ITEMS=()
skip_case() { # $1=用例名 $2=原因
    SKIPPED_ITEMS+=("$1：$2")
    printf 'skip - %s：%s\n' "$1" "$2"
}

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
TMP_DIR=$(mktemp -d 2>/dev/null || true)
if [[ -z "${TMP_DIR}" ]]; then
    TMP_DIR=$(mktemp -d "${TMP_ROOT_FALLBACK:-/tmp}/easy_all_probe_log.XXXXXX")
fi
cleanup_test() { rm -rf -- "${TMP_DIR}"; }
trap cleanup_test EXIT

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}
assert_equal() {
    TESTS_ASSERTED=$((TESTS_ASSERTED + 1))
    local label=$1 expected=$2 actual=$3
    [[ "${expected}" == "${actual}" ]] \
        || fail "${label}: expected <${expected}> but got <${actual}>"
}
assert_nonzero() {
    TESTS_ASSERTED=$((TESTS_ASSERTED + 1))
    local label=$1 status=$2
    [[ "${status}" != "0" ]] || fail "${label}: 期望非零退出，实际为 0"
}
assert_contains() {
    TESTS_ASSERTED=$((TESTS_ASSERTED + 1))
    local label=$1 text=$2 expected=$3
    [[ "${text}" == *"${expected}"* ]] \
        || fail "${label}: missing <${expected}> in <${text}>"
}
assert_not_contains() {
    TESTS_ASSERTED=$((TESTS_ASSERTED + 1))
    local label=$1 text=$2 unexpected=$3
    [[ "${text}" != *"${unexpected}"* ]] \
        || fail "${label}: unexpected <${unexpected}> in <${text}>"
}
assert_file_exists() {
    TESTS_ASSERTED=$((TESTS_ASSERTED + 1))
    [[ -f "$2" ]] || fail "$1: 期望文件存在，但未找到：$2"
}
assert_file_absent() {
    TESTS_ASSERTED=$((TESTS_ASSERTED + 1))
    [[ ! -e "$2" ]] || fail "$1: 期望文件已删除：$2"
}

# --- 语法校验（本次新增/修改的 shell 脚本） -----------------------------------
for syntax_file in "${ROOT_DIR}/lib/probe-log.sh" "${ROOT_DIR}/lib/runtime-core.sh" \
    "${ROOT_DIR}/lib/reality-cloudflare-mode.sh" "${ROOT_DIR}/lib/cloudfront-mode.sh" \
    "${ROOT_DIR}/lib/cloudflare-mode.sh" "${ROOT_DIR}/easy_all"; do
    bash -n "${syntax_file}" || fail "语法校验失败：${syntax_file}"
done
TESTS_ASSERTED=$((TESTS_ASSERTED + 1))

# --- PATH stub：全部外部特权/防火墙命令 ---------------------------------------
BIN_DIR="${TMP_DIR}/bin"
CALLS_LOG="${TMP_DIR}/calls.log"
TAB=$'\t'
mkdir -p "${BIN_DIR}" "${TMP_DIR}/empty-bin"
: >"${CALLS_LOG}"

stub_start() { # $1=命令名
    cat >"${BIN_DIR}/$1" <<STUB
#!/usr/bin/env bash
set -uo pipefail
name=\$(basename -- "\$0")
printf '%s\t%s\n' "\${name}" "\$*" >>"${CALLS_LOG}"
unstubbed() {
    printf '未 stub 的 %s 调用：%s\n' "\${name}" "\$*" >&2
    printf '%s\t%s\n' "\${name}" "\$*" >>"\${STUB_STATE}/unstubbed.log"
    exit 99
}
STUB
    chmod 0755 "${BIN_DIR}/$1"
}

stub_start ip
cat >>"${BIN_DIR}/ip" <<STUB
case "\$*" in
"-4 route show default")
    [[ ! -s "\${STUB_STATE}/ip-route" ]] || cat "\${STUB_STATE}/ip-route"
    ;;
*) unstubbed "\$@" ;;
esac
STUB

stub_start iptables
cat >>"${BIN_DIR}/iptables" <<STUB
state="\${STUB_STATE}/iptables.input"
: >>"\${state}"
args=("\$@")
if [[ "\${args[0]:-}" == "-w" ]]; then args=("\${args[@]:2}"); fi
op="\${args[0]:-}"
if [[ -e "\${STUB_STATE}/iptables.query-fail" && "\${op}" == "-S" ]]; then
    printf 'iptables: Resource temporarily unavailable\n' >&2
    exit 1
fi
# 把参数规格规范成 iptables -S 的展示形式（LOG 前缀带引号）。
normalize() {
    local out="" token prev=""
    for token in "\$@"; do
        if [[ "\${token}" == "GFW_CHK: " && "\${prev}" == "--log-prefix" ]]; then
            out+=' "GFW_CHK: "'
        else
            out+=" \${token}"
        fi
        prev=\${token}
    done
    printf '%s' "\${out}"
}
case "\${op}" in
-S)
    [[ "\${args[1]:-INPUT}" == "INPUT" ]] || unstubbed "\$@"
    [[ ! -s "\${state}" ]] || cat "\${state}"
    ;;
-I)
    [[ "\${args[1]:-}" == "INPUT" && "\${args[2]:-}" == "1" ]] || unstubbed "\$@"
    line="-A INPUT\$(normalize "\${args[@]:3}")"
    { printf '%s\n' "\${line}"; [[ ! -s "\${state}" ]] || cat "\${state}"; } >"\${state}.new"
    mv -f -- "\${state}.new" "\${state}"
    ;;
-D)
    [[ "\${args[1]:-}" == "INPUT" ]] || unstubbed "\$@"
    line="-A INPUT\$(normalize "\${args[@]:2}")"
    grep -Fxq -- "\${line}" "\${state}" || {
        printf 'iptables: No chain/target/match by that name.\n' >&2
        exit 1
    }
    awk -v drop="\${line}" '\$0 != drop' "\${state}" >"\${state}.new"
    mv -f -- "\${state}.new" "\${state}"
    ;;
*) unstubbed "\$@" ;;
esac
STUB

stub_start systemctl
cat >>"${BIN_DIR}/systemctl" <<STUB
last=""
for arg in "\$@"; do last=\${arg}; done
if [[ -e "\${STUB_STATE}/systemctl-fail" ]] && grep -Fqx -- "\$*" "\${STUB_STATE}/systemctl-fail"; then
    exit 1
fi
# 模拟 unit 的 ExecStop / ExecStart：restart 强制先删自有规则再重放。
unit_hook() {
    (
        source "${ROOT_DIR}/lib/probe-log.sh"
        probe_log_rules_remove >/dev/null 2>&1 || true
        [[ "\${1}" == "restart" ]] || exit 0
        probe_log_rules_replay >/dev/null 2>&1
    )
}
case "\${1:-}" in
daemon-reload) ;;
enable) [[ "\${last}" == "easy_all-probe-log.service" ]] || unstubbed "\$@" ;;
disable | stop)
    [[ "\${last}" == "easy_all-probe-log.service" ]] || exit 0
    unit_hook stop || exit 1
    ;;
restart)
    # 只有探测 unit 的 restart 才模拟 ExecStop/ExecStart；systemd-journald 不重放规则。
    [[ "\${last}" == "easy_all-probe-log.service" ]] || exit 0
    unit_hook restart || exit 1
    ;;
is-active)
    [[ "\${last}" == "ssh.socket" ]] && exit 3
    [[ "\${last}" == "easy_all-probe-log.service" || "\${last}" == "ssh.service" ]] || unstubbed "\$@"
    ;;
is-enabled)
    [[ "\${last}" == "ssh.socket" ]] && exit 1
    unstubbed "\$@"
    ;;
show) ;;
cat) exit 1 ;;
*) unstubbed "\$@" ;;
esac
exit 0
STUB

stub_start ufw
cat >>"${BIN_DIR}/ufw" <<STUB
rules="\${STUB_STATE}/ufw.rules"
: >>"\${rules}"
args=("\$@")
while [[ "\${args[0]:-}" == --* ]]; do args=("\${args[@]:1}"); done
cmd="\${args[0]:-}"
upper() { printf '%s' "\$1" | tr '[:lower:]' '[:upper:]'; }
display() {
    local i=0 line
    printf 'Status: active\n'
    while IFS= read -r line; do
        i=\$((i + 1))
        if [[ "\${1:-}" == numbered ]]; then
            printf '[%2d] %s\n' "\${i}" "\${line}"
        else
            printf '%s\n' "\${line}"
        fi
    done <"\${rules}"
}
add_rule() {
    local line=\$1
    grep -Fxq -- "\${line}" "\${rules}" && return 0
    if [[ "\${2:-append}" == prepend ]]; then
        { printf '%s\n' "\${line}"; cat "\${rules}"; } >"\${rules}.new"
        mv -f -- "\${rules}.new" "\${rules}"
    else
        printf '%s\n' "\${line}" >>"\${rules}"
    fi
}
case "\${cmd}" in
status) display "\${args[1]:-}" ;;
show) cat "\${rules}" ;;
enable | reload | default) ;;
allow)
    endpoint=\${args[1]:-}
    comment=""
    [[ "\${args[2]:-}" != comment ]] || comment=\${args[3]:-}
    add_rule "\${endpoint} ALLOW IN Anywhere\${comment:+ # \${comment}}" append
    ;;
insert)
    action=\$(upper "\${args[2]:-}")
    endpoint=\${args[3]:-}
    comment=""
    [[ "\${args[4]:-}" != comment ]] || comment=\${args[5]:-}
    add_rule "\${endpoint} \${action} IN Anywhere\${comment:+ # \${comment}}" prepend
    ;;
delete)
    action=\$(upper "\${args[1]:-}")
    endpoint=\${args[2]:-}
    comment=""
    [[ "\${args[3]:-}" != comment ]] || comment=\${args[4]:-}
    line="\${endpoint} \${action} IN Anywhere\${comment:+ # \${comment}}"
    grep -Fxq -- "\${line}" "\${rules}" || exit 1
    awk -v drop="\${line}" '\$0 != drop' "\${rules}" >"\${rules}.new"
    mv -f -- "\${rules}.new" "\${rules}"
    ;;
*) unstubbed "\$@" ;;
esac
STUB

stub_start sshd
cat >>"${BIN_DIR}/sshd" <<'STUB'
case "${1:-}" in
-t) exit "${FAKE_SSHD_T_STATUS:-0}" ;;
-T)
    [[ "${FAKE_SSHD_T_STATUS:-0}" == "0" ]] || exit 1
    if [[ -f "${EASY_ALL_SSH_PORT_CONFIG:-/nonexistent}" ]] \
        && grep -qx 'Port 22222' "${EASY_ALL_SSH_PORT_CONFIG}" 2>/dev/null; then
        printf 'port 22222\nlistenaddress 0.0.0.0:22222\n'
    else
        printf 'port 22\nlistenaddress 0.0.0.0:22\n'
    fi
    ;;
*) unstubbed "$@" ;;
esac
STUB

stub_start ss
cat >>"${BIN_DIR}/ss" <<'STUB'
printf 'LISTEN 0 128 0.0.0.0:%s 0.0.0.0:* users:(("sshd",pid=42,fd=3))\n' "${FAKE_SSH_LISTEN_PORT:-22}"
STUB

for trivial in fail2ban-client crontab; do
    stub_start "${trivial}"
    printf 'exit 0\n' >>"${BIN_DIR}/${trivial}"
done

# journalctl 与 curl 必须显式失败：本测试一律用离线样本与 stub，真实调用即漏网。
for forbidden in journalctl curl; do
    stub_start "${forbidden}"
    printf 'unstubbed "$@"\n' >>"${BIN_DIR}/${forbidden}"
done

stub_start flock
printf 'exit 0\n' >>"${BIN_DIR}/flock"

# 缺 iptables 的隔离 PATH：只去掉 iptables，其余 stub 保留。
mkdir -p "${TMP_DIR}/bin-noiptables"
for stub in "${BIN_DIR}"/*; do
    [[ "$(basename -- "${stub}")" == "iptables" ]] && continue
    ln -sfn "${stub}" "${TMP_DIR}/bin-noiptables/$(basename -- "${stub}")"
done

assert_equal "iptables 解析到 stub" "${BIN_DIR}/iptables" \
    "$(PATH="${BIN_DIR}:${PATH}" command -v iptables)"
assert_equal "缺 iptables 的 PATH 确实没有 iptables" "" \
    "$(PATH="${TMP_DIR}/bin-noiptables:/usr/bin:/bin" command -v iptables 2>/dev/null || true)"

# --- 用例运行器 ---------------------------------------------------------------
new_case() { # $1=名字 → 打印目录
    local dir="${TMP_DIR}/cases/$1"
    rm -rf -- "${dir}"
    mkdir -p "${dir}/systemd" "${dir}/journald.conf.d" "${dir}/state" \
        "${dir}/runtime" "${dir}/stub" "${dir}/bin" "${dir}/subs/subscriptions" \
        "${dir}/ssh/sshd_config.d" "${dir}/fail2ban" "${dir}/units" "${dir}/core" \
        "${dir}/tmp" "${dir}/home"
    : >"${dir}/stub/ufw.rules"
    : >"${dir}/stub/iptables.input"
    : >"${dir}/stub/unstubbed.log"
    printf 'default via 192.0.2.1 dev eth0 proto dhcp src 198.51.100.7 metric 100\n' \
        >"${dir}/stub/ip-route"
    printf 'IPV6=yes\nDEFAULT_INPUT_POLICY="DROP"\n' >"${dir}/ufw-default"
    printf 'Include %s\nPort 22\nPasswordAuthentication no\n' \
        "${dir}/ssh/sshd_config.d/*.conf" >"${dir}/ssh/sshd_config"
    printf 'PasswordAuthentication no\n' >"${dir}/ssh/sshd_config.d/50-cloud-init.conf"
    printf '22/tcp ALLOW IN Anywhere # easy_all-managed\n' >"${dir}/stub/ufw.rules"
    printf '%s\n' "${dir}"
}

run_case() { # $1=目录 $2=snippet [额外 VAR=值 ...]
    local dir=$1 snippet=$2
    shift 2
    env PATH="${BIN_DIR}:${PATH}" \
        STUB_STATE="${dir}/stub" \
        SYSTEMD_SYSTEM_DIR="${dir}/systemd" \
        JOURNALD_CONF_DIR="${dir}/journald.conf.d" \
        EASY_ALL_STATE_DIR_OVERRIDE="${dir}/state" \
        EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${dir}/subs/subscriptions" \
        EASY_ALL_INSTALL_DIR_OVERRIDE="${dir}/install" \
        EASY_ALL_COMMAND_PATH_OVERRIDE="${dir}/bin/easy_all" \
        EASY_ALL_SSHD_CONFIG="${dir}/ssh/sshd_config" \
        EASY_ALL_SSHD_CONFIG_DIR="${dir}/ssh/sshd_config.d" \
        EASY_ALL_SSH_PORT_CONFIG="${dir}/ssh/sshd_config.d/00-easy-all-ports.conf" \
        EASY_ALL_TARGET_SSH_PORT=22222 \
        EASY_ALL_FAIL2BAN_CONFIG="${dir}/fail2ban/99-easy-all-sshd.local" \
        EASY_ALL_FAIL2BAN_ACTION_CONFIG="${dir}/fail2ban/easy-all-ufw-cidr.conf" \
        EASY_ALL_FAIL2BAN_CIDR_HELPER="${dir}/bin/fail2ban-ufw-cidr.sh" \
        EASY_ALL_FAIL2BAN_CIDR_STATE_DIR="${dir}/fail2ban-state" \
        EASY_ALL_CERTBOT_LIVE_DIR_OVERRIDE="${dir}/certs" \
        EASY_ALL_CERTBOT_HOOK_FILE_OVERRIDE="${dir}/hooks/deploy.sh" \
        EASY_ALL_CLOUDFLARE_CREDENTIALS_OVERRIDE="${dir}/cloudflare.ini" \
        RUNTIME_TMP="${dir}/runtime" \
        RUNTIME_WRITE_LOCK_FILE_OVERRIDE="${dir}/runtime/write.lock" \
        SINGBOX_BIN="${dir}/core/sing-box" \
        XRAY_BIN="${dir}/core/xray" \
        CADDY_BIN="${dir}/core/caddy" \
        SINGBOX_SERVICE="easy_all-singbox.service" \
        XRAY_SERVICE="easy_all-xray.service" \
        CADDY_SERVICE="easy_all-caddy.service" \
        SINGBOX_SERVICE_FILE="${dir}/units/easy_all-singbox.service" \
        XRAY_SERVICE_FILE="${dir}/units/easy_all-xray.service" \
        CADDY_SERVICE_FILE="${dir}/units/easy_all-caddy.service" \
        UFW_DEFAULT_CONFIG="${dir}/ufw-default" \
        FAKE_SSHD_T_STATUS=0 \
        FAKE_SSH_LISTEN_PORT=22 \
        HOME="${dir}/home" \
        TMPDIR="${dir}/tmp" \
        "$@" \
        bash -c "${snippet}" _ "${ROOT_DIR}" 2>&1
}

LAST_STATUS=0
LAST_OUTPUT=""
capture() { # 与 run_case 同参数；结果写入 LAST_OUTPUT / LAST_STATUS
    : >"${CALLS_LOG}"
    LAST_OUTPUT=$(run_case "$@") && LAST_STATUS=0 || LAST_STATUS=$?
}

assert_no_unstubbed() { # $1=目录
    TESTS_ASSERTED=$((TESTS_ASSERTED + 1))
    local log="$1/stub/unstubbed.log"
    [[ ! -s "${log}" ]] || fail "$1: 出现未 stub 的外部命令调用：$(<"${log}")"
}

PROBE_LIB_SNIPPET='source "$1/lib/log.sh"; source "$1/lib/probe-log.sh"'

# --- 1. unit 与 drop-in 的内容、幂等 -----------------------------------------
unit_case=$(new_case unit-content)
capture "${unit_case}" "
${PROBE_LIB_SNIPPET}
COMMAND_PATH=/usr/local/bin/easy_all
probe_log_enable_and_replay
"
assert_equal "启用探测日志退出 0" "0" "${LAST_STATUS}"
unit_file="${unit_case}/systemd/easy_all-probe-log.service"
dropin_file="${unit_case}/journald.conf.d/99-easy_all-probe-retention.conf"
assert_file_exists "生成 systemd unit" "${unit_file}"
assert_file_exists "生成 journald drop-in" "${dropin_file}"
unit_text=$(<"${unit_file}")
assert_contains "unit 是 oneshot" "${unit_text}" "Type=oneshot"
assert_contains "unit 保持 active" "${unit_text}" "RemainAfterExit=yes"
assert_contains "unit 依赖 network-online 与 ufw" "${unit_text}" \
    "After=network-online.target ufw.service"
assert_contains "unit ExecStart 走内部入口" "${unit_text}" \
    "ExecStart=/usr/local/bin/easy_all internal-probe-log-apply"
assert_contains "unit ExecStop 走内部入口" "${unit_text}" \
    "ExecStop=/usr/local/bin/easy_all internal-probe-log-remove-rules"
assert_contains "unit 随 multi-user 启用" "${unit_text}" "WantedBy=multi-user.target"
dropin_text=$(<"${dropin_file}")
assert_equal "drop-in 只有 [Journal] 与 MaxRetentionSec" \
    "[Journal]
MaxRetentionSec=30day" "${dropin_text}"
assert_not_contains "drop-in 不写 SystemMaxUse" "${dropin_text}" "SystemMaxUse"
assert_contains "提示写明全局保留上限影响主机全部 journal" "${LAST_OUTPUT}" \
    "systemd-journald 的全局保留上限"
assert_contains "提示写明超出上限的历史日志无法恢复" "${LAST_OUTPUT}" "无法恢复"
unit_calls=$(<"${CALLS_LOG}")
assert_contains "重放走 restart 而不是 enable --now" "${unit_calls}" \
    "systemctl${TAB}restart easy_all-probe-log.service"
assert_contains "显式重启 journald" "${unit_calls}" "systemctl${TAB}restart systemd-journald"
assert_contains "启用 unit" "${unit_calls}" "systemctl${TAB}enable easy_all-probe-log.service"
assert_equal "默认路由存在时用 -i eth0" \
    '-A INPUT -i eth0 -p tcp --dport 443 --syn -m limit --limit 30/min --limit-burst 60 -j LOG --log-prefix "GFW_CHK: " --log-level 4' \
    "$(<"${unit_case}/stub/iptables.input")"
assert_not_contains "启用路径不取 runtime 写锁" "${unit_calls}" "flock"
# 重复 apply 不追加配置、规则仍恰一条。
capture "${unit_case}" "
${PROBE_LIB_SNIPPET}
COMMAND_PATH=/usr/local/bin/easy_all
probe_log_enable_and_replay
"
assert_equal "重复 apply 退出 0" "0" "${LAST_STATUS}"
assert_equal "重复 apply 不追加 drop-in 行" "2" "$(awk 'END {print NR}' "${dropin_file}")"
assert_equal "重复 apply 后规则仍恰一条" "1" \
    "$(grep -c -- '^\-A INPUT .*--dport 443 .*--log-prefix "GFW_CHK: "' \
        "${unit_case}/stub/iptables.input" || true)"
assert_no_unstubbed "${unit_case}"

# --- 2. 规则形态与查询失败 ---------------------------------------------------
shape_case=$(new_case rule-shape)
: >"${shape_case}/stub/ip-route"
capture "${shape_case}" "
${PROBE_LIB_SNIPPET}
probe_log_rules_replay
"
assert_equal "无默认路由时回退重放成功" "0" "${LAST_STATUS}"
assert_equal "无默认路由时用 ! -i lo（不退化成不限接口）" \
    '-A INPUT ! -i lo -p tcp --dport 443 --syn -m limit --limit 30/min --limit-burst 60 -j LOG --log-prefix "GFW_CHK: " --log-level 4' \
    "$(<"${shape_case}/stub/iptables.input")"
assert_not_contains "回退形式不含 -i eth0" "$(<"${shape_case}/stub/iptables.input")" "-i eth0"
assert_no_unstubbed "${shape_case}"

fail_case=$(new_case rule-query-fail)
: >"${fail_case}/stub/ip-route"
: >"${fail_case}/stub/iptables.input"
: >"${fail_case}/stub/iptables.query-fail"
capture "${fail_case}" "
${PROBE_LIB_SNIPPET}
probe_log_rules_replay
"
assert_equal "查询失败时重放非零" "1" "${LAST_STATUS}"
assert_equal "查询失败不得盲插规则" "" "$(<"${fail_case}/stub/iptables.input")"

dup_case=$(new_case rule-duplicate)
cat >"${dup_case}/stub/iptables.input" <<'RULES'
-A INPUT -i eth0 -p tcp --dport 443 --syn -m limit --limit 30/min --limit-burst 60 -j LOG --log-prefix "GFW_CHK: " --log-level 4
-A INPUT ! -i lo -p tcp --dport 443 --syn -m limit --limit 30/min --limit-burst 60 -j LOG --log-prefix "GFW_CHK: " --log-level 4
-A INPUT -p tcp --dport 8443 -j LOG --log-prefix "GFW_CHK: " --log-level 4
-A INPUT -p tcp --dport 4435 -j LOG --log-prefix "GFW_CHK: " --log-level 4
RULES
capture "${dup_case}" "
${PROBE_LIB_SNIPPET}
probe_log_rules_replay
"
assert_equal "历史重复规则重放成功" "0" "${LAST_STATUS}"
assert_equal "重放后自有规则恰一条" "1" \
    "$(grep -c -- '^\-A INPUT .*--dport 443 .*--log-prefix "GFW_CHK: "' \
        "${dup_case}/stub/iptables.input" || true)"
assert_equal "非 443 的自有前缀规则不被当成本工具规则" "1" \
    "$(grep -c -- '--dport 8443' "${dup_case}/stub/iptables.input" || true)"
assert_equal "--dport 4435 不被 443 子串误匹配（不误删）" "1" \
    "$(grep -c -- '--dport 4435' "${dup_case}/stub/iptables.input" || true)"
assert_no_unstubbed "${dup_case}"

# --- 3. 模式矩阵 -------------------------------------------------------------
for spec in "reality-cloudflare:reality-cloudflare.sh:probe_log_enable_and_replay" \
    "reality-cloudflare-xhttp:reality-cloudflare-xhttp.sh:probe_log_enable_and_replay" \
    "reality-cloudfront:reality-cloudfront.sh:cloudfront_probe_log_sync"; do
    name=${spec%%:*}
    rest=${spec#*:}
    profile=${rest%%:*}
    call=${rest#*:}
    dir=$(new_case "${name}")
    capture "${dir}" "source \"\$1/profiles/${profile}\"; ${call}"
    assert_equal "${name} 探测同步退出 0" "0" "${LAST_STATUS}"
    assert_file_exists "${name} 启用 unit" "${dir}/systemd/easy_all-probe-log.service"
    assert_file_exists "${name} 写入 drop-in" \
        "${dir}/journald.conf.d/99-easy_all-probe-retention.conf"
    assert_equal "${name} 恰一条采集规则" "1" \
        "$(grep -c -- '^\-A INPUT .*--dport 443 .*--log-prefix "GFW_CHK: "' \
            "${dir}/stub/iptables.input" || true)"
    assert_contains "${name} restart 强制重放" "$(<"${CALLS_LOG}")" \
        "systemctl${TAB}restart easy_all-probe-log.service"
    assert_no_unstubbed "${dir}"
done

for spec in "mode2:cloudflare.sh:remove_probe_log" \
    "mode4:cloudfront.sh:cloudfront_probe_log_sync"; do
    name=${spec%%:*}
    rest=${spec#*:}
    profile=${rest%%:*}
    call=${rest#*:}
    dir=$(new_case "${name}")
    : >"${dir}/systemd/easy_all-probe-log.service"
    printf '[Journal]\nMaxRetentionSec=30day\n' \
        >"${dir}/journald.conf.d/99-easy_all-probe-retention.conf"
    printf '%s\n' \
        '-A INPUT -i eth0 -p tcp --dport 443 --syn -m limit --limit 30/min --limit-burst 60 -j LOG --log-prefix "GFW_CHK: " --log-level 4' \
        >"${dir}/stub/iptables.input"
    capture "${dir}" "source \"\$1/profiles/${profile}\"; ${call}"
    assert_equal "${name} 收敛退出 0" "0" "${LAST_STATUS}"
    assert_file_absent "${name} 清除 unit" "${dir}/systemd/easy_all-probe-log.service"
    assert_file_absent "${name} 清除 drop-in" \
        "${dir}/journald.conf.d/99-easy_all-probe-retention.conf"
    assert_equal "${name} 清除采集规则" "" "$(<"${dir}/stub/iptables.input")"
    assert_not_contains "${name} 不重放采集规则" "$(<"${CALLS_LOG}")" \
        "systemctl${TAB}restart easy_all-probe-log.service"
    assert_no_unstubbed "${dir}"
done

assert_contains "cloudfront 守卫只接受 reality-cloudfront" \
    "$(<"${ROOT_DIR}/lib/cloudfront-mode.sh")" \
    'if [[ "${PROTOCOL}" == "reality-cloudfront" ]]; then'

# --- 4. 窄锚点：最后一次 UFW reload 之后才同步探测 ---------------------------
function_body() { # $1=file $2=函数名
    awk -v fn="$2() {" '$0 == fn {flag=1} flag {print} flag && /^}$/ {exit}' "$1"
}
assert_line_before() { # $1=label $2=body $3=更早 $4=更晚
    TESTS_ASSERTED=$((TESTS_ASSERTED + 1))
    local label=$1 body=$2 earlier=$3 later=$4 e l
    e=$(awk -v pat="$earlier" 'index($0, pat) {print NR; exit}' <<<"${body}")
    l=$(awk -v pat="$later" 'index($0, pat) {print NR; exit}' <<<"${body}")
    if [[ -z "${e}" || -z "${l}" || "${e}" -ge "${l}" ]]; then
        fail "${label}: 期望 <${earlier}>（行 ${e:-缺失}）早于 <${later}>（行 ${l:-缺失}）"
    fi
}
last_reload_line() {
    awk -F'\t' '$1 == "ufw" && $2 == "reload" {n = NR} END {print n + 0}' "${CALLS_LOG}"
}
probe_restart_line() {
    awk -F'\t' '$1 == "systemctl" && $2 == "restart easy_all-probe-log.service" {n = NR} END {print n + 0}' \
        "${CALLS_LOG}"
}
reload_after() { # $1=起始行
    awk -v after="$1" -F'\t' 'NR > after && $1 == "ufw" && $2 == "reload"' "${CALLS_LOG}"
}

direct_body_apply=$(function_body "${ROOT_DIR}/lib/reality-cloudflare-mode.sh" apply_easy_all)
direct_body_cloud=$(function_body "${ROOT_DIR}/lib/reality-cloudflare-mode.sh" apply_cloud_resources)
direct_body_install=$(function_body "${ROOT_DIR}/lib/reality-cloudflare-mode.sh" install_all)
cf_body_apply=$(function_body "${ROOT_DIR}/lib/cloudfront-mode.sh" apply_easy_all)
cf_body_cloud=$(function_body "${ROOT_DIR}/lib/cloudfront-mode.sh" apply_cloud_resources)
cf_body_install=$(function_body "${ROOT_DIR}/lib/cloudfront-mode.sh" install_all)
flare_body_apply=$(function_body "${ROOT_DIR}/lib/cloudflare-mode.sh" apply_easy_all)
flare_body_cloud=$(function_body "${ROOT_DIR}/lib/cloudflare-mode.sh" apply_cloud_resources)
flare_body_install=$(function_body "${ROOT_DIR}/lib/cloudflare-mode.sh" install_all)

assert_line_before "模式 4 apply 同步在提交之后" "${direct_body_apply}" \
    "commit_subscription_update" "probe_log_enable_and_replay"
assert_line_before "模式 4 apply 同步在 success 之前" "${direct_body_apply}" \
    "probe_log_enable_and_replay" 'success "本机配置与订阅已应用'
assert_line_before "模式 4 apply-cloud 同步在提交之后" "${direct_body_cloud}" \
    "commit_subscription_update" "probe_log_enable_and_replay"
assert_line_before "模式 4 安装同步在 SSH/UFW 收尾之后" "${direct_body_install}" \
    "configure_post_install_ssh_port" "probe_log_enable_and_replay"
assert_line_before "模式 4 安装同步仍在回滚钩子内" "${direct_body_install}" \
    "probe_log_enable_and_replay" "INSTALL_ROLLBACK_ON_EXIT=0"

assert_line_before "模式 2/3 apply 同步在提交之后" "${cf_body_apply}" \
    "commit_subscription_update" "cloudfront_probe_log_sync"
assert_line_before "模式 2/3 apply 同步在 success 之前" "${cf_body_apply}" \
    "cloudfront_probe_log_sync" 'success "本机配置与订阅已应用'
assert_line_before "模式 2/3 apply-cloud 同步在提交之后" "${cf_body_cloud}" \
    "commit_subscription_update" "cloudfront_probe_log_sync"
assert_line_before "模式 2/3 安装同步在 SSH/UFW 收尾之后" "${cf_body_install}" \
    "configure_post_install_ssh_port" "cloudfront_probe_log_sync"
assert_line_before "模式 2/3 安装同步仍在回滚钩子内" "${cf_body_install}" \
    "cloudfront_probe_log_sync" "INSTALL_ROLLBACK_ON_EXIT=0"

assert_line_before "模式 1 apply 收敛在提交之后" "${flare_body_apply}" \
    "commit_subscription_update" "remove_probe_log"
assert_line_before "模式 1 apply 收敛在 success 之前" "${flare_body_apply}" \
    "remove_probe_log" 'success "本机配置与订阅已应用'
assert_line_before "模式 1 apply-cloud 收敛在提交之后" "${flare_body_cloud}" \
    "commit_subscription_update" "remove_probe_log"
assert_line_before "模式 1 安装收敛在 SSH/UFW 收尾之后" "${flare_body_install}" \
    "configure_post_install_ssh_port" "remove_probe_log"
assert_line_before "模式 1 安装收敛仍在回滚钩子内" "${flare_body_install}" \
    "remove_probe_log" "INSTALL_ROLLBACK_ON_EXIT=0"

incomplete_body=$(function_body "${ROOT_DIR}/lib/runtime-core.sh" uninstall_incomplete)
assert_line_before "不完整状态清理回收探测资源" "${incomplete_body}" \
    "restore_preinstall_firewall" "remove_probe_log"
assert_line_before "不完整状态在删命令/状态前回收探测资源" "${incomplete_body}" \
    "remove_probe_log" 'rm -f -- "${SINGBOX_SERVICE_FILE}"'

# 宿主边界替身：这些函数会写 /etc/default/ufw、读 /etc/ssh 与 /etc/fail2ban，或访问网络；
# 本节的窄锚点只验证 UFW 与探测重放的相对顺序。
HOST_BOUNDARY_STUBS='
snapshot_ufw_state() { :; }
snapshot_platform_security_state() { :; }
ensure_ssh_boot_service() { :; }
configure_ufw_ip_family() { :; }
ensure_ssh_fail2ban() { :; }
cloudflare_configure_origin_firewall() { :; }
'

# 4b. apply 锚点：真实 configure_runtime_ufw → probe_log_enable_and_replay
ufw_case=$(new_case ufw-order-apply)
capture "${ufw_case}" "
source \"\$1/profiles/reality-cloudflare.sh\"
${HOST_BOUNDARY_STUBS}
detect_ssh_ports() { SSH_PORTS=22222; }
SUBSCRIPTION_MODE=deploy
configure_runtime_ufw
probe_log_enable_and_replay
"
assert_equal "apply 窄锚点退出 0" "0" "${LAST_STATUS}"
ufw_last_reload=$(last_reload_line)
probe_after_reload=$(probe_restart_line)
TESTS_ASSERTED=$((TESTS_ASSERTED + 1))
((ufw_last_reload > 0)) || fail "apply 窄锚点未见 UFW reload"
TESTS_ASSERTED=$((TESTS_ASSERTED + 1))
((probe_after_reload > ufw_last_reload)) \
    || fail "探测重放（行 ${probe_after_reload}）必须晚于最后一次 UFW reload（行 ${ufw_last_reload}）"
TESTS_ASSERTED=$((TESTS_ASSERTED + 1))
[[ -z "$(reload_after "${probe_after_reload}")" ]] \
    || fail "探测重放之后不得再有 UFW reload"
assert_no_unstubbed "${ufw_case}"

# 4c. 安装锚点：configure_runtime_ufw → configure_post_install_ssh_port → 探测同步
install_case=$(new_case ufw-order-install)
capture "${install_case}" "
source \"\$1/profiles/reality-cloudfront.sh\"
${HOST_BOUNDARY_STUBS}
detect_ssh_ports() { SSH_PORTS=22; }
configure_runtime_ufw
configure_post_install_ssh_port
cloudfront_probe_log_sync
"
assert_equal "安装窄锚点退出 0" "0" "${LAST_STATUS}"
install_last_reload=$(last_reload_line)
install_restart=$(probe_restart_line)
TESTS_ASSERTED=$((TESTS_ASSERTED + 1))
((install_restart > install_last_reload)) \
    || fail "安装收尾后探测重放（行 ${install_restart}）必须晚于最后一次 UFW reload（行 ${install_last_reload}）"
TESTS_ASSERTED=$((TESTS_ASSERTED + 1))
[[ -z "$(reload_after "${install_restart}")" ]] \
    || fail "安装收尾的探测重放之后不得再有 UFW reload"
assert_no_unstubbed "${install_case}"

# 4d. 纯 CDN 分支：同序列最后改为 remove_probe_log
cdn_case=$(new_case ufw-order-cdn)
: >"${cdn_case}/systemd/easy_all-probe-log.service"
printf '[Journal]\nMaxRetentionSec=30day\n' \
    >"${cdn_case}/journald.conf.d/99-easy_all-probe-retention.conf"
printf '%s\n' \
    '-A INPUT -i eth0 -p tcp --dport 443 --syn -m limit --limit 30/min --limit-burst 60 -j LOG --log-prefix "GFW_CHK: " --log-level 4' \
    >"${cdn_case}/stub/iptables.input"
capture "${cdn_case}" "
source \"\$1/profiles/cloudflare.sh\"
${HOST_BOUNDARY_STUBS}
detect_ssh_ports() { SSH_PORTS=22; }
configure_runtime_ufw
configure_post_install_ssh_port
remove_probe_log
"
assert_equal "纯 CDN 窄锚点退出 0" "0" "${LAST_STATUS}"
assert_file_absent "纯 CDN 分支清除 unit" "${cdn_case}/systemd/easy_all-probe-log.service"
assert_file_absent "纯 CDN 分支清除 drop-in" \
    "${cdn_case}/journald.conf.d/99-easy_all-probe-retention.conf"
assert_equal "纯 CDN 分支清除规则" "" "$(<"${cdn_case}/stub/iptables.input")"
assert_not_contains "纯 CDN 分支不重放" "$(<"${CALLS_LOG}")" \
    "systemctl${TAB}restart easy_all-probe-log.service"
assert_no_unstubbed "${cdn_case}"

# --- 5. rule-only 内部入口：不写 unit、不取 runtime 锁、清理历史网卡形式 ------
internal_body=$(awk '/internal-probe-log-apply/ {flag=1} /internal-traffic-prepare/ {flag=0} flag' \
    "${ROOT_DIR}/easy_all")
assert_not_contains "内部入口不取 runtime 写锁" "${internal_body}" "acquire_runtime_write_lock"
assert_not_contains "内部入口不写 unit/drop-in" "${internal_body}" "probe_log_write_file"
assert_contains "内部 apply 走 rule-only 重放" "${internal_body}" "probe_log_rules_replay"
assert_contains "内部 remove 走 rule-only 清理" "${internal_body}" "probe_log_rules_remove"

stop_case=$(new_case rule-only-stop)
cat >"${stop_case}/stub/iptables.input" <<'RULES'
-A INPUT -i eth0 -p tcp --dport 443 --syn -m limit --limit 30/min --limit-burst 60 -j LOG --log-prefix "GFW_CHK: " --log-level 4
-A INPUT ! -i lo -p tcp --dport 443 --syn -m limit --limit 30/min --limit-burst 60 -j LOG --log-prefix "GFW_CHK: " --log-level 4
RULES
capture "${stop_case}" "
${PROBE_LIB_SNIPPET}
probe_log_rules_replay
"
assert_equal "rule-only 重放退出 0" "0" "${LAST_STATUS}"
assert_file_absent "rule-only 重放不写 unit" "${stop_case}/systemd/easy_all-probe-log.service"
assert_file_absent "rule-only 重放不写 drop-in" \
    "${stop_case}/journald.conf.d/99-easy_all-probe-retention.conf"
assert_file_absent "rule-only 重放不创建 runtime 锁" "${stop_case}/runtime/write.lock"
assert_not_contains "rule-only 重放不取 runtime 锁" "$(<"${CALLS_LOG}")" "flock"
capture "${stop_case}" "
${PROBE_LIB_SNIPPET}
probe_log_rules_remove
"
assert_equal "unit 不存在时仍清理历史网卡形式" "0" "${LAST_STATUS}"
assert_equal "两种历史形式都被清除" "" "$(<"${stop_case}/stub/iptables.input")"
assert_no_unstubbed "${stop_case}"

if [[ "$(id -u)" -ne 0 ]]; then
    launcher_case=$(new_case launcher-internal)
    launcher_status=0
    launcher_out=$(EASY_ALL_STATE_FILE_OVERRIDE="${launcher_case}/state/state.env" \
        EASY_ALL_INSTALL_DIR_OVERRIDE="${launcher_case}/install" \
        EASY_ALL_COMMAND_PATH_OVERRIDE="${launcher_case}/bin/easy_all" \
        RUNTIME_WRITE_LOCK_FILE_OVERRIDE="${launcher_case}/runtime/write.lock" \
        TMPDIR="${launcher_case}/tmp" \
        bash "${ROOT_DIR}/easy_all" internal-probe-log-remove-rules 2>&1) || launcher_status=$?
    assert_equal "内部 remove 非 root 非零" "1" "${launcher_status}"
    assert_contains "内部 remove 非 root 提示 root" "${launcher_out}" "请使用 root 用户运行此脚本"
    assert_file_absent "非 root 未创建 runtime 锁" "${launcher_case}/runtime/write.lock"
    assert_file_absent "非 root 未写 unit" "${launcher_case}/systemd/easy_all-probe-log.service"
else
    skip_case "内部入口 root 门禁" "以 root 运行，真实规则重放属特权边界"
fi

# --- 5b. 失败必须传播：探测同步/清理失败不得被吞掉 ---------------------------
# 真实函数层：cloudfront_probe_log_sync 在 enable 与 remove 失败时都必须非零，
# 否则调用点的 `|| return 1` / `|| die` 永远不会触发。
sync_apply_fail=$(new_case sync-apply-fail)
rmdir "${sync_apply_fail}/journald.conf.d"
: >"${sync_apply_fail}/journald.conf.d"
capture "${sync_apply_fail}" 'source "$1/profiles/reality-cloudfront.sh"; cloudfront_probe_log_sync'
assert_equal "模式 3 启用失败时 cloudfront_probe_log_sync 非零" "1" "${LAST_STATUS}"
assert_contains "启用失败写明全局保留未生效" "${LAST_OUTPUT}" \
    "systemd-journald 全局 30 天保留上限未生效"
assert_not_contains "启用失败不输出启用成功文案" "${LAST_OUTPUT}" "已启用直连 TCP 443 探测日志"

sync_remove_fail=$(new_case sync-remove-fail)
mkdir -p "${sync_remove_fail}/systemd/easy_all-probe-log.service"
printf '[Journal]\nMaxRetentionSec=30day\n' \
    >"${sync_remove_fail}/journald.conf.d/99-easy_all-probe-retention.conf"
printf '%s\n' \
    '-A INPUT -i eth0 -p tcp --dport 443 --syn -m limit --limit 30/min --limit-burst 60 -j LOG --log-prefix "GFW_CHK: " --log-level 4' \
    >"${sync_remove_fail}/stub/iptables.input"
capture "${sync_remove_fail}" 'source "$1/profiles/cloudfront.sh"; cloudfront_probe_log_sync'
assert_equal "模式 2 清理失败时 cloudfront_probe_log_sync 非零" "1" "${LAST_STATUS}"
assert_contains "清理失败点名删除失败" "${LAST_OUTPUT}" "删除"
assert_contains "清理失败保留重试依据" "${LAST_OUTPUT}" "失败"
assert_no_unstubbed "${sync_remove_fail}"

# 静态层：九个调用点都必须显式传播，且不得留下裸调用（裸调用只能依赖 set -e）。
assert_no_bare_call() { # $1=label $2=body $3=函数名
    TESTS_ASSERTED=$((TESTS_ASSERTED + 1))
    if awk -v bad="$3" '$0 ~ ("^[[:space:]]*" bad "[[:space:]]*$") {found=1} END {exit !found}' \
        <<<"$2"; then
        fail "$1：仍存在裸调用 <$3>（失败会被吞掉）"
    fi
}
assert_contains "模式 4 apply 传播失败" "${direct_body_apply}" \
    "probe_log_enable_and_replay || return 1"
assert_contains "模式 4 apply-cloud 传播失败" "${direct_body_cloud}" \
    "probe_log_enable_and_replay || return 1"
assert_contains "模式 4 安装失败触发回滚" "${direct_body_install}" \
    "probe_log_enable_and_replay || die "
assert_no_bare_call "模式 4 apply 无裸调用" "${direct_body_apply}" \
    "probe_log_enable_and_replay"
assert_no_bare_call "模式 4 apply-cloud 无裸调用" "${direct_body_cloud}" \
    "probe_log_enable_and_replay"
assert_no_bare_call "模式 4 安装无裸调用" "${direct_body_install}" \
    "probe_log_enable_and_replay"

assert_contains "模式 2/3 apply 传播失败" "${cf_body_apply}" \
    "cloudfront_probe_log_sync || return 1"
assert_contains "模式 2/3 apply-cloud 传播失败" "${cf_body_cloud}" \
    "cloudfront_probe_log_sync || return 1"
assert_contains "模式 2/3 安装失败触发回滚" "${cf_body_install}" \
    "cloudfront_probe_log_sync || die "
assert_no_bare_call "模式 2/3 apply 无裸调用" "${cf_body_apply}" "cloudfront_probe_log_sync"
assert_no_bare_call "模式 2/3 apply-cloud 无裸调用" "${cf_body_cloud}" \
    "cloudfront_probe_log_sync"
assert_no_bare_call "模式 2/3 安装无裸调用" "${cf_body_install}" "cloudfront_probe_log_sync"
sync_helper_body=$(function_body "${ROOT_DIR}/lib/cloudfront-mode.sh" cloudfront_probe_log_sync)
assert_contains "守卫内启用分支传播失败" "${sync_helper_body}" \
    "probe_log_enable_and_replay || return 1"
assert_contains "守卫内清理分支传播失败" "${sync_helper_body}" "remove_probe_log || return 1"

assert_contains "模式 1 apply 传播失败" "${flare_body_apply}" "remove_probe_log || return 1"
assert_contains "模式 1 apply-cloud 传播失败" "${flare_body_cloud}" "remove_probe_log || return 1"
assert_contains "模式 1 安装失败触发回滚" "${flare_body_install}" "remove_probe_log || die "
assert_no_bare_call "模式 1 apply 无裸调用" "${flare_body_apply}" "remove_probe_log"
assert_no_bare_call "模式 1 apply-cloud 无裸调用" "${flare_body_cloud}" "remove_probe_log"
assert_no_bare_call "模式 1 安装无裸调用" "${flare_body_install}" "remove_probe_log"

# disable/stop 失败不得静默：告警后仍完成规则清理，不依赖 ExecStop 成功。
disable_warn_case=$(new_case disable-warn)
: >"${disable_warn_case}/systemd/easy_all-probe-log.service"
printf '%s\n' \
    '-A INPUT -i eth0 -p tcp --dport 443 --syn -m limit --limit 30/min --limit-burst 60 -j LOG --log-prefix "GFW_CHK: " --log-level 4' \
    >"${disable_warn_case}/stub/iptables.input"
printf 'disable --now easy_all-probe-log.service\nstop easy_all-probe-log.service\n' \
    >"${disable_warn_case}/stub/systemctl-fail"
capture "${disable_warn_case}" "
${PROBE_LIB_SNIPPET}
remove_probe_log
"
assert_equal "disable/stop 失败仍完成清理" "0" "${LAST_STATUS}"
assert_contains "disable 失败不再静默" "${LAST_OUTPUT}" \
    "停用 easy_all-probe-log.service 失败"
assert_contains "stop 失败不再静默" "${LAST_OUTPUT}" \
    "停止 easy_all-probe-log.service 失败"
assert_equal "disable/stop 失败后规则仍被清除" "" \
    "$(<"${disable_warn_case}/stub/iptables.input")"

# unit 文件已缺失时仍尝试 disable，清掉可能残留的 enable 符号链接。
stale_enable_case=$(new_case stale-enable-link)
printf '%s\n' \
    '-A INPUT ! -i lo -p tcp --dport 443 --syn -m limit --limit 30/min --limit-burst 60 -j LOG --log-prefix "GFW_CHK: " --log-level 4' \
    >"${stale_enable_case}/stub/iptables.input"
capture "${stale_enable_case}" "
${PROBE_LIB_SNIPPET}
remove_probe_log
"
assert_equal "无 unit 文件时仍清理规则" "0" "${LAST_STATUS}"
assert_contains "无 unit 文件时仍尝试 disable" "$(<"${CALLS_LOG}")" \
    "systemctl${TAB}disable --now easy_all-probe-log.service"
assert_equal "残留规则已清除" "" "$(<"${stale_enable_case}/stub/iptables.input")"
assert_no_unstubbed "${stale_enable_case}"

# --- 6. 全局保留上限：写入/生效/恢复失败都可见 --------------------------------
dropin_fail_case=$(new_case dropin-write-fail)
rmdir "${dropin_fail_case}/journald.conf.d"
: >"${dropin_fail_case}/journald.conf.d"
capture "${dropin_fail_case}" "
${PROBE_LIB_SNIPPET}
probe_log_enable_and_replay
"
assert_equal "drop-in 写入失败非零" "1" "${LAST_STATUS}"
assert_contains "写入失败点名 systemd-journald 全局" "${LAST_OUTPUT}" "systemd-journald 全局"
assert_contains "写入失败明确未生效" "${LAST_OUTPUT}" "未生效"

journald_fail_case=$(new_case journald-restart-fail)
printf 'restart systemd-journald\n' >"${journald_fail_case}/stub/systemctl-fail"
capture "${journald_fail_case}" "
${PROBE_LIB_SNIPPET}
probe_log_enable_and_replay
"
assert_equal "journald restart 失败非零" "1" "${LAST_STATUS}"
assert_contains "journald restart 失败指出可能尚未生效" "${LAST_OUTPUT}" "可能尚未生效"

active_fail_case=$(new_case service-active-fail)
printf 'is-active --quiet easy_all-probe-log.service\n' >"${active_fail_case}/stub/systemctl-fail"
capture "${active_fail_case}" "
${PROBE_LIB_SNIPPET}
probe_log_enable_and_replay
"
assert_equal "service 非 active 非零" "1" "${LAST_STATUS}"
assert_contains "service 非 active 时点名" "${LAST_OUTPUT}" "未处于 active 状态"

remove_fail_case=$(new_case journald-restore-fail)
: >"${remove_fail_case}/systemd/easy_all-probe-log.service"
printf '[Journal]\nMaxRetentionSec=30day\n' \
    >"${remove_fail_case}/journald.conf.d/99-easy_all-probe-retention.conf"
printf '%s\n' \
    '-A INPUT -i eth0 -p tcp --dport 443 --syn -m limit --limit 30/min --limit-burst 60 -j LOG --log-prefix "GFW_CHK: " --log-level 4' \
    >"${remove_fail_case}/stub/iptables.input"
printf 'restart systemd-journald\n' >"${remove_fail_case}/stub/systemctl-fail"
capture "${remove_fail_case}" "
${PROBE_LIB_SNIPPET}
remove_probe_log
"
assert_equal "删除 drop-in 后 journald 恢复失败非零" "1" "${LAST_STATUS}"
assert_contains "恢复失败明确运行配置可能仍保留上限" "${LAST_OUTPUT}" \
    "可能仍在沿用全局保留上限"
assert_equal "恢复失败仍清除了采集规则" "" "$(<"${remove_fail_case}/stub/iptables.input")"

# --- 7. 清理保守性 -----------------------------------------------------------
cons_case=$(new_case cleanup-no-iptables)
printf 'STATE_VERSION=1\nPROTOCOL=reality-cloudflare\n' >"${cons_case}/state/state.env"
: >"${cons_case}/systemd/easy_all-probe-log.service"
printf '[Journal]\nMaxRetentionSec=30day\n' \
    >"${cons_case}/journald.conf.d/99-easy_all-probe-retention.conf"
no_ipt_status=0
no_ipt_out=$(env PATH="${TMP_DIR}/bin-noiptables:/usr/bin:/bin" \
    STUB_STATE="${cons_case}/stub" \
    SYSTEMD_SYSTEM_DIR="${cons_case}/systemd" \
    JOURNALD_CONF_DIR="${cons_case}/journald.conf.d" \
    EASY_ALL_STATE_DIR_OVERRIDE="${cons_case}/state" \
    bash -c 'source "$1/lib/log.sh"; source "$1/lib/probe-log.sh"; remove_probe_log' \
    _ "${ROOT_DIR}" 2>&1) || no_ipt_status=$?
assert_equal "缺 iptables 且有证据时非零" "1" "${no_ipt_status}"
assert_contains "缺 iptables 提示保留状态与命令" "${no_ipt_out}" "已保留本机状态与 easy_all 命令"
assert_file_exists "缺 iptables 不删 state" "${cons_case}/state/state.env"
assert_file_exists "缺 iptables 不删 unit" "${cons_case}/systemd/easy_all-probe-log.service"
assert_file_exists "缺 iptables 不删 drop-in" \
    "${cons_case}/journald.conf.d/99-easy_all-probe-retention.conf"

early_case=$(new_case cleanup-early)
early_status=0
early_out=$(env PATH="${TMP_DIR}/bin-noiptables:/usr/bin:/bin" \
    STUB_STATE="${early_case}/stub" \
    SYSTEMD_SYSTEM_DIR="${early_case}/systemd" \
    JOURNALD_CONF_DIR="${early_case}/journald.conf.d" \
    EASY_ALL_STATE_DIR_OVERRIDE="${early_case}/state" \
    bash -c 'source "$1/lib/log.sh"; source "$1/lib/probe-log.sh"; remove_probe_log' \
    _ "${ROOT_DIR}" 2>&1) || early_status=$?
assert_equal "无任何相关资源时缺 iptables 放行" "0" "${early_status}"
assert_equal "早期清理无输出噪音" "" "${early_out}"

query_fail_case=$(new_case cleanup-query-fail)
printf 'STATE_VERSION=1\nPROTOCOL=reality-cloudflare\n' >"${query_fail_case}/state/state.env"
: >"${query_fail_case}/stub/iptables.query-fail"
capture "${query_fail_case}" "
${PROBE_LIB_SNIPPET}
remove_probe_log
"
assert_equal "iptables 查询失败不得当成无规则" "1" "${LAST_STATUS}"
assert_contains "查询失败提示保留命令" "${LAST_OUTPUT}" "已保留本机状态与 easy_all 命令"
assert_file_exists "查询失败不删 state" "${query_fail_case}/state/state.env"

# --- 8. 分析前规则快照校验 ---------------------------------------------------
sample_kernel="${TMP_DIR}/kernel.log"
sample_singbox="${TMP_DIR}/singbox.log"
cat >"${sample_kernel}" <<'LOG'
2024-05-01T12:00:00+0000 host kernel: GFW_CHK: IN=eth0 OUT= MAC=aabb SRC=203.0.113.10 DST=198.51.100.7 LEN=60 PROTO=TCP SPT=50000 DPT=443 WINDOW=64240 RES=0x00 SYN URGP=0
2024-05-01T12:00:30+0000 host kernel: GFW_CHK: IN=eth0 OUT= MAC=aabb SRC=203.0.113.10 DST=198.51.100.7 LEN=60 PROTO=TCP SPT=50001 DPT=443 WINDOW=64240 RES=0x00 SYN URGP=0
2024-05-01T12:01:00+0000 host kernel: GFW_CHK: IN=eth0 OUT= MAC=aabb SRC=203.0.113.10 DST=198.51.100.7 LEN=60 PROTO=TCP SPT=50002 DPT=443 WINDOW=64240 RES=0x00 SYN URGP=0
2024-05-01T12:02:00+0000 host kernel: GFW_CHK: IN=eth0 OUT= MAC=aabb SRC=203.0.113.10 DST=198.51.100.7 LEN=60 PROTO=TCP SPT=50003 DPT=443 WINDOW=64240 RES=0x00 SYN URGP=0
2024-05-01T12:03:00+0000 host kernel: GFW_CHK: IN=eth0 OUT= MAC=aabb SRC=203.0.113.10 DST=198.51.100.7 LEN=60 PROTO=TCP SPT=50004 DPT=443 WINDOW=64240 RES=0x00 SYN URGP=0
2024-05-01T12:00:00+0000 host kernel: GFW_CHK: IN=eth0 OUT= MAC=aabb SRC=198.51.100.20 DST=198.51.100.7 LEN=60 PROTO=TCP SPT=50100 DPT=443 WINDOW=64240 RES=0x00 SYN URGP=0
2024-05-01T12:00:40+0000 host kernel: GFW_CHK: IN=eth0 OUT= MAC=aabb SRC=198.51.100.20 DST=198.51.100.7 LEN=60 PROTO=TCP SPT=50101 DPT=443 WINDOW=64240 RES=0x00 SYN URGP=0
2024-05-01T12:01:30+0000 host kernel: GFW_CHK: IN=eth0 OUT= MAC=aabb SRC=198.51.100.20 DST=198.51.100.7 LEN=60 PROTO=TCP SPT=50102 DPT=443 WINDOW=64240 RES=0x00 SYN URGP=0
2024-05-01T12:02:30+0000 host kernel: GFW_CHK: IN=eth0 OUT= MAC=aabb SRC=198.51.100.20 DST=198.51.100.7 LEN=60 PROTO=TCP SPT=50103 DPT=443 WINDOW=64240 RES=0x00 SYN URGP=0
2024-05-01T12:00:05+0000 host kernel: GFW_CHK: IN=eth0 OUT= MAC=aabb SRC=192.0.2.66 DST=198.51.100.7 LEN=60 PROTO=TCP SPT=40000 DPT=443 WINDOW=64240 RES=0x00 SYN URGP=0
2024-05-01T12:00:01+0000 host kernel: GFW_CHK: IN=eth0 OUT= MAC=aabb SRC=192.0.2.55 DST=198.51.100.7 LEN=60 PROTO=TCP SPT=40005 DPT=443 WINDOW=64240 RES=0x00 SYN URGP=0
2024-05-01T12:00:20+0000 host kernel: GFW_CHK: IN=eth0 OUT= MAC=aabb SRC=192.0.2.77 DST=198.51.100.7 LEN=60 PROTO=TCP SPT=40006 DPT=443 WINDOW=64240 RES=0x00 SYN URGP=0
2024-05-01T12:00:25+0000 host kernel: GFW_CHK: IN=eth0 OUT= MAC=aabb SRC=192.0.2.77 DST=198.51.100.7 LEN=60 PROTO=TCP SPT=40007 DPT=443 WINDOW=64240 RES=0x00 SYN URGP=0
2024-05-01T12:00:28+0000 host kernel: GFW_CHK: IN=eth0 OUT= MAC=aabb SRC=192.0.2.77 DST=198.51.100.7 LEN=60 PROTO=TCP SPT=40008 DPT=443 WINDOW=64240 RES=0x00 SYN URGP=0
2024-05-01T12:00:09+0000 host kernel: GFW_CHK: IN=eth0 OUT= MAC=aabb SRC=192.0.2.88 DST=198.51.100.7 LEN=60 PROTO=TCP SPT=40009 DPT=8443 WINDOW=64240 RES=0x00 SYN URGP=0
2024-05-01T06:00:00+0000 host kernel: GFW_CHK: IN=eth0 OUT= MAC=aabb SRC=192.0.2.44 DST=198.51.100.7 LEN=60 PROTO=TCP SPT=40010 DPT=443 WINDOW=64240 RES=0x00 SYN URGP=0
LOG
cat >"${sample_singbox}" <<'LOG'
2024-05-01T12:00:00+0000 host easy_all-singbox[1]: INFO inbound connection
2024-05-01T12:00:01+0000 host easy_all-singbox[1]: WARN inbound: something
2024-05-01T12:00:02+0000 host easy_all-singbox[1]: ERROR dial failed
LOG

rules_ok="${TMP_DIR}/iptables-input.nft"
cat >"${rules_ok}" <<'RULES'
-P INPUT DROP
-A INPUT -i eth0 -p tcp --dport 443 --syn -m limit --limit 30/min --limit-burst 60 -j LOG --log-prefix "GFW_CHK: " --log-level 4
-A INPUT -p tcp --dport 443 -j ACCEPT
RULES
rules_legacy="${TMP_DIR}/iptables-input.legacy"
cat >"${rules_legacy}" <<'RULES'
-A INPUT -p tcp -m tcp --dport 443 --syn -m limit --limit 30/min --limit-burst 60 -j LOG --log-prefix "GFW_CHK: " --log-level 4
RULES
rules_cross_line="${TMP_DIR}/iptables-input.cross"
cat >"${rules_cross_line}" <<'RULES'
-A INPUT -p tcp --dport 443 -j ACCEPT
-A INPUT -j LOG --log-prefix "GFW_CHK: " --log-level 4
RULES
rules_prefix_only="${TMP_DIR}/iptables-input.prefix"
cat >"${rules_prefix_only}" <<'RULES'
-A INPUT -p tcp --dport 8443 -j LOG --log-prefix "GFW_CHK: " --log-level 4
RULES
# 端口前缀相同但不是 443：按 token 边界不得通过前置校验。
rules_port_prefix="${TMP_DIR}/iptables-input.4435"
cat >"${rules_port_prefix}" <<'RULES'
-A INPUT -p tcp --dport 4435 -j LOG --log-prefix "GFW_CHK: " --log-level 4
RULES
: >"${TMP_DIR}/iptables-input.empty"

RUN_HELLOGFW_SNIPPET='
source "$1/lib/probe-log.sh"
shift
run_hellogfw "$@"
'
analyze() { # $1=规则快照文件 $2=内核日志样本 额外参数...
    local rules=$1 kernel=$2
    shift 2
    HELLOGFW_IPTABLES_RULES_FILE="${rules}" \
        HELLOGFW_KERNEL_LOG_FILE="${kernel}" \
        HELLOGFW_SINGBOX_LOG_FILE="${sample_singbox}" \
        bash -c "${RUN_HELLOGFW_SNIPPET}" _ "${ROOT_DIR}" "$@" 2>&1
}

for variant in "${rules_ok}" "${rules_legacy}"; do
    analysis_status=0
    analysis=$(analyze "${variant}" "${sample_kernel}" --since "24 hours ago") \
        || analysis_status=$?
    assert_equal "$(basename "${variant}") 规则快照通过前置校验" "0" "${analysis_status}"
    assert_contains "$(basename "${variant}") 输出时间窗" "${analysis}" "--since 24 hours ago"
done

for broken in "${TMP_DIR}/iptables-input.missing" "${TMP_DIR}/iptables-input.empty" \
    "${rules_cross_line}" "${rules_prefix_only}" "${rules_port_prefix}"; do
    broken_status=0
    broken_out=$(analyze "${broken}" "${sample_kernel}") || broken_status=$?
    assert_equal "$(basename "${broken}") 缺采集规则时非零" "1" "${broken_status}"
    assert_contains "$(basename "${broken}") 点名无法确认采集规则" "${broken_out}" \
        "无法确认采集规则"
    assert_contains "$(basename "${broken}") 给出修复命令" "${broken_out}" \
        "sudo easy_all apply"
    assert_not_contains "$(basename "${broken}") 不得输出清洁的零探测结论" "${broken_out}" \
        "该时间窗没有匹配记录"
done

# --- 9. 分析结果 -------------------------------------------------------------
auto_status=0
auto_out=$(analyze "${rules_ok}" "${sample_kernel}" --since "24 hours ago") || auto_status=$?
assert_equal "自动分析退出 0" "0" "${auto_status}"
assert_contains "总匹配 SYN 数不含 DPT=8443" "${auto_out}" "内核日志匹配 SYN 记录：15 条"
assert_contains "独立来源数" "${auto_out}" "独立来源 IP：6 个"
assert_contains "自动识别两个正常客户端参照" "${auto_out}" \
    "正常客户端参照：203.0.113.10（5 次）、198.51.100.20（4 次）"
assert_contains "同期 WARN/ERROR 统计" "${auto_out}" "sing-box 同期 WARN/ERROR：2 条"
assert_not_contains "无 Reality 回落日志时不输出回落拆分" "${auto_out}" "其中 Reality 非授权回落"
assert_contains "候选含 5 秒后出现的低频陌生来源" "${auto_out}" "192.0.2.66  全窗 1 次"
assert_contains "候选给出与参照连接的时间差" "${auto_out}" "5.0 秒"
assert_contains "候选含 1 秒后出现的低频陌生来源" "${auto_out}" "192.0.2.55"
assert_not_contains "全窗 3 次的陌生高频来源不是候选" "${auto_out}" "192.0.2.77"
assert_not_contains "DPT=8443 的记录被忽略" "${auto_out}" "192.0.2.88"
assert_not_contains "窗口外记录不产生候选" "${auto_out}" "192.0.2.44"
assert_contains "输出解释边界" "${auto_out}" "不构成 GFW 归因证明"

# 模式 3 单 443 回落拆分：sing-box 含 REALITY: processed invalid connection 时单独计数。
sample_singbox_reality="${TMP_DIR}/singbox-reality.log"
cat >"${sample_singbox_reality}" <<'LOG'
2024-05-01T12:00:00+0000 host easy_all-singbox[1]: INFO inbound connection
2024-05-01T12:00:01+0000 host easy_all-singbox[1]: WARN inbound/vless[vless-reality-in]: REALITY: processed invalid connection from 198.51.100.1
2024-05-01T12:00:02+0000 host easy_all-singbox[1]: ERROR inbound/vless[vless-reality-in]: REALITY: processed invalid connection from 198.51.100.2
2024-05-01T12:00:03+0000 host easy_all-singbox[1]: ERROR dial failed
LOG
reality_fb_out=$(
    HELLOGFW_IPTABLES_RULES_FILE="${rules_ok}" \
    HELLOGFW_KERNEL_LOG_FILE="${sample_kernel}" \
    HELLOGFW_SINGBOX_LOG_FILE="${sample_singbox_reality}" \
        bash -c "${RUN_HELLOGFW_SNIPPET}" _ "${ROOT_DIR}" --since "24 hours ago" 2>&1
)
assert_contains "含 Reality 回落日志时拆分统计回落条数" "${reality_fb_out}" \
    "sing-box 同期 WARN/ERROR：3 条（其中 Reality 非授权回落：2 条，含主动探测及模式 3/5 回源流量）"

# 模式 5：Xray 日志形态（[Warning]/[Error]）计入 WARN/ERROR；回落特征行不需要先有 WARN/ERROR。
sample_xray="${TMP_DIR}/xray-core.log"
cat >"${sample_xray}" <<'LOG'
2026/11/26 10:00:00 [Info] transport/internet: XHTTP accepted
2026/11/26 10:00:01 [Warning] transport/internet/reality: REALITY: processed invalid connection from 198.51.100.3
2026/11/26 10:00:02 [Error] app/proxyman/outbound: failed to process outbound traffic
2026/11/26 10:00:03 [Info] REALITY: processed invalid connection from 198.51.100.4
LOG
xray_fb_out=$(
    HELLOGFW_IPTABLES_RULES_FILE="${rules_ok}" \
    HELLOGFW_KERNEL_LOG_FILE="${sample_kernel}" \
    HELLOGFW_CORE_LOG_FILE="${sample_xray}" \
    HELLOGFW_CORE_LABEL="xray" \
        bash -c "${RUN_HELLOGFW_SNIPPET}" _ "${ROOT_DIR}" --since "24 hours ago" 2>&1
) || true
assert_contains "Xray [Warning]/[Error] 计入 WARN/ERROR" "${xray_fb_out}" \
    "xray 同期 WARN/ERROR：2 条"
assert_contains "Xray 回落特征不依赖 ALERT_RE 前缀" "${xray_fb_out}" \
    "其中 Reality 非授权回落：2 条"

# 兼容口径：HELLOGFW_SINGBOX_LOG_FILE 仍被读取（无 HELLOGFW_CORE_LOG_FILE 时）。
legacy_alias_out=$(
    HELLOGFW_IPTABLES_RULES_FILE="${rules_ok}" \
    HELLOGFW_KERNEL_LOG_FILE="${sample_kernel}" \
    HELLOGFW_SINGBOX_LOG_FILE="${sample_xray}" \
        bash -c "${RUN_HELLOGFW_SNIPPET}" _ "${ROOT_DIR}" --since "24 hours ago" 2>&1
) || true
assert_contains "HELLOGFW_SINGBOX_LOG_FILE 兼容别名仍生效" "${legacy_alias_out}" \
    "sing-box 同期 WARN/ERROR：2 条"

# 后端分派：BACKEND=xray 时读取 easy_all-xray 单元，否则 easy_all-singbox。
fake_journal_bin="${TMP_DIR}/journal-bin-xray"
mkdir -p "${fake_journal_bin}"
cat >"${fake_journal_bin}/journalctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_JOURNAL_LOG}"
case " $* " in
*" -u "*) cat "${FAKE_JOURNAL_STDOUT}" ;;
esac
exit 0
STUB
chmod 0755 "${fake_journal_bin}/journalctl"
: >"${TMP_DIR}/journal-xray.log"
backend_unit_out=$(
    PATH="${fake_journal_bin}:${PATH}" \
    FAKE_JOURNAL_LOG="${TMP_DIR}/journal-xray.log" \
    FAKE_JOURNAL_STDOUT="${sample_xray}" \
    BACKEND=xray \
    HELLOGFW_IPTABLES_RULES_FILE="${rules_ok}" \
    HELLOGFW_KERNEL_LOG_FILE="${sample_kernel}" \
        bash -c "${RUN_HELLOGFW_SNIPPET}" _ "${ROOT_DIR}" --since "24 hours ago" 2>&1
) || true
assert_contains "BACKEND=xray 时标签为 xray" "${backend_unit_out}" "xray 同期 WARN/ERROR"
assert_contains "BACKEND=xray 时读取 easy_all-xray 单元" \
    "$(<"${TMP_DIR}/journal-xray.log")" "-u easy_all-xray"
: >"${TMP_DIR}/journal-singbox.log"
backend_singbox_out=$(
    PATH="${fake_journal_bin}:${PATH}" \
    FAKE_JOURNAL_LOG="${TMP_DIR}/journal-singbox.log" \
    FAKE_JOURNAL_STDOUT="${sample_xray}" \
    HELLOGFW_IPTABLES_RULES_FILE="${rules_ok}" \
    HELLOGFW_KERNEL_LOG_FILE="${sample_kernel}" \
        bash -c "${RUN_HELLOGFW_SNIPPET}" _ "${ROOT_DIR}" --since "24 hours ago" 2>&1
) || true
assert_contains "默认后端读取 easy_all-singbox 单元" \
    "$(<"${TMP_DIR}/journal-singbox.log")" "-u easy_all-singbox"

manual_out=$(analyze "${rules_ok}" "${sample_kernel}" --my-ip 203.0.113.10)
assert_contains "显式 --my-ip 覆盖自动识别" "${manual_out}" \
    "正常客户端参照：203.0.113.10（5 次）"
assert_not_contains "显式参照不再自动加第二个" "${manual_out}" "198.51.100.20（4 次）"

cat >"${TMP_DIR}/kernel-thin.log" <<'LOG'
2024-05-01T12:00:00+0000 host kernel: GFW_CHK: IN=eth0 SRC=203.0.113.10 DST=198.51.100.7 PROTO=TCP SPT=50000 DPT=443 SYN
2024-05-01T12:00:10+0000 host kernel: GFW_CHK: IN=eth0 SRC=203.0.113.99 DST=198.51.100.7 PROTO=TCP SPT=50001 DPT=443 SYN
LOG
thin_out=$(analyze "${rules_ok}" "${TMP_DIR}/kernel-thin.log")
assert_contains "参照样本不足时明确说明" "${thin_out}" "参照样本不足"
assert_contains "参照不足不做无依据关联" "${thin_out}" "没有可比对的正常客户端参照"

: >"${TMP_DIR}/kernel-none.log"
none_out=$(analyze "${rules_ok}" "${TMP_DIR}/kernel-none.log")
assert_contains "零记录才输出没有匹配记录" "${none_out}" "该时间窗没有匹配记录"
assert_contains "零记录时提示限速与保留策略" "${none_out}" "30 天保留上限"

cat >"${TMP_DIR}/kernel-refs-only.log" <<'LOG'
2024-05-01T12:00:00+0000 host kernel: GFW_CHK: IN=eth0 SRC=203.0.113.10 DST=198.51.100.7 PROTO=TCP SPT=50000 DPT=443 SYN
2024-05-01T12:00:30+0000 host kernel: GFW_CHK: IN=eth0 SRC=203.0.113.10 DST=198.51.100.7 PROTO=TCP SPT=50001 DPT=443 SYN
2024-05-01T12:02:00+0000 host kernel: GFW_CHK: IN=eth0 SRC=203.0.113.10 DST=198.51.100.7 PROTO=TCP SPT=50002 DPT=443 SYN
LOG
refs_out=$(analyze "${rules_ok}" "${TMP_DIR}/kernel-refs-only.log")
assert_contains "无候选时明确说明启发式无命中" "${refs_out}" "没有低频陌生连接候选"
assert_contains "无候选不宣称未发生探测" "${refs_out}" "不代表未发生主动探测"

cat >"${TMP_DIR}/kernel-malformed.log" <<'LOG'
2024-05-01T12:00:00+0000 host kernel: GFW_CHK: IN=eth0 SRC=203.0.113.10 DST=198.51.100.7 PROTO=TCP SPT=50000 DPT=443 SYN
2024-05-01T12:00:05+0000 host kernel: GFW_CHK: IN=eth0 DST=198.51.100.7 PROTO=TCP SPT=40000 DPT=443 SYN
LOG
malformed_out=$(analyze "${rules_ok}" "${TMP_DIR}/kernel-malformed.log")
assert_contains "畸形关键记录标为不完整" "${malformed_out}" "本结果不完整"
assert_contains "匹配行总数仍按 2 条统计" "${malformed_out}" "内核日志匹配 SYN 记录：2 条"

cat >"${TMP_DIR}/kernel-all-malformed.log" <<'LOG'
2024-05-01T12:00:05+0000 host kernel: GFW_CHK: IN=eth0 DST=198.51.100.7 PROTO=TCP SPT=40000 DPT=443 SYN
LOG
all_bad_status=0
all_bad_out=$(analyze "${rules_ok}" "${TMP_DIR}/kernel-all-malformed.log") || all_bad_status=$?
assert_equal "全部记录畸形时非零" "1" "${all_bad_status}"
assert_contains "全部记录畸形时明确未得出结论" "${all_bad_out}" "未得出结论"

unreadable_status=0
unreadable_out=$(analyze "${rules_ok}" "${TMP_DIR}/does-not-exist.log") || unreadable_status=$?
assert_equal "样本不可读时非零" "1" "${unreadable_status}"
assert_contains "样本不可读时点名文件" "${unreadable_out}" "无法读取内核日志样本文件"

for bad_args in "--port 8443" "--my-ip 999.1.1.1" "--since" "--unknown"; do
    bad_status=0
    # shellcheck disable=SC2086
    bad_out=$(analyze "${rules_ok}" "${sample_kernel}" ${bad_args}) || bad_status=$?
    assert_nonzero "非法参数（${bad_args}）非零" "${bad_status}"
    assert_not_contains "非法参数（${bad_args}）不做分析" "${bad_out}" "内核日志匹配 SYN 记录"
done

# --- 10. 直接 source、帮助与前置检查文案 --------------------------------------
help_status=0
help_out=$(env -u EASY_ALL_ROOT \
    bash -c 'set -u; source "$1/lib/probe-log.sh"; run_hellogfw --help' \
    _ "${ROOT_DIR}" 2>&1) || help_status=$?
assert_equal "无 EASY_ALL_ROOT 且 set -u 时帮助退出 0" "0" "${help_status}"
assert_contains "帮助给出用法" "${help_out}" \
    "easy_all hellogfw [--since <时间范围>] [--my-ip <IPv4> ...]"
assert_contains "帮助说明固定 443" "${help_out}" "443"
assert_not_contains "帮助不宣传 --port" "${help_out}" "--port"

help_short_status=0
help_short_out=$(env -u EASY_ALL_ROOT \
    bash -c 'set -u; source "$1/lib/probe-log.sh"; run_hellogfw -h' _ "${ROOT_DIR}" 2>&1) \
    || help_short_status=$?
assert_equal "-h 同样退出 0" "0" "${help_short_status}"
assert_contains "-h 输出同一帮助" "${help_short_out}" "easy_all hellogfw [--since <时间范围>]"

nopy_status=0
nopy_out=$(env -u EASY_ALL_ROOT \
    bash -c 'set -u; source "$1/lib/probe-log.sh"; PATH="$2"; run_hellogfw --help' \
    _ "${ROOT_DIR}" "${TMP_DIR}/empty-bin" 2>&1) || nopy_status=$?
assert_equal "缺 python3 时帮助非零" "1" "${nopy_status}"
assert_contains "缺 python3 文案" "${nopy_out}" "缺少 python3（请先安装 python3）"
assert_not_contains "缺 python3 不得误报运行时损坏" "${nopy_out}" "运行时"

nopy_script_status=0
nopy_script_out=$(env -u EASY_ALL_ROOT \
    bash -c 'set -u; source "$1/lib/probe-log.sh"; PROBE_LOG_HELLOGFW_PY="$2/missing.py"; run_hellogfw --help' \
    _ "${ROOT_DIR}" "${TMP_DIR}" 2>&1) || nopy_script_status=$?
assert_equal "分析脚本缺失时帮助非零" "1" "${nopy_script_status}"
assert_contains "分析脚本缺失文案" "${nopy_script_out}" "运行时脚本缺失："
assert_not_contains "脚本缺失不误报缺 python3" "${nopy_script_out}" "缺少 python3"

run_body=$(function_body "${ROOT_DIR}/lib/probe-log.sh" run_hellogfw)
assert_not_contains "run_hellogfw 不调用 die" "${run_body}" "die "
assert_not_contains "run_hellogfw 不调用 warn" "${run_body}" "warn "

# 运行时缺 lib/probe-log.sh 时，launcher 的免 root 帮助必须报「运行时文件不完整」。
fake_root="${TMP_DIR}/fake-root"
mkdir -p "${fake_root}/lib"
cp "${ROOT_DIR}/easy_all" "${fake_root}/easy_all"
cp "${ROOT_DIR}/lib/state.sh" "${fake_root}/lib/state.sh"
missing_lib_status=0
missing_lib_out=$(EASY_ALL_STATE_FILE_OVERRIDE="${TMP_DIR}/no-state.env" \
    bash "${fake_root}/easy_all" hellogfw --help 2>&1) || missing_lib_status=$?
assert_equal "缺 probe-log 库时帮助非零" "1" "${missing_lib_status}"
assert_contains "缺 probe-log 库时点名运行时文件不完整" "${missing_lib_out}" \
    "easy_all 运行时文件不完整"
assert_not_contains "缺 probe-log 库时不输出帮助正文" "${missing_lib_out}" \
    "easy_all hellogfw [--since"

complete_help_status=0
complete_help_out=$(EASY_ALL_STATE_FILE_OVERRIDE="${TMP_DIR}/no-state.env" \
    bash "${ROOT_DIR}/easy_all" hellogfw --help 2>&1) || complete_help_status=$?
assert_equal "无安装状态时 help 退出 0" "0" "${complete_help_status}"
assert_contains "无安装状态时 help 正常输出" "${complete_help_out}" \
    "easy_all hellogfw [--since <时间范围>]"
assert_not_contains "launcher 帮助不宣传 --port" "${complete_help_out}" "--port"

# --- 收尾 ---------------------------------------------------------------------
TESTS_ASSERTED=$((TESTS_ASSERTED + 1))
((TESTS_ASSERTED > 100)) || fail "断言数量异常（${TESTS_ASSERTED}）：疑似用例大面积空跑"

if ((${#SKIPPED_ITEMS[@]} > 0)); then
    printf '未验证项：\n'
    printf '  - %s\n' "${SKIPPED_ITEMS[@]}"
fi
printf 'ok - 探测日志资源、模式收敛、失败清理、CLI 前置校验与日志分析测试通过（%s 个断言）\n' \
    "${TESTS_ASSERTED}"
