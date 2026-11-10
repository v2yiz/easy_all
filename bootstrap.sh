#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly REPOSITORY_URL="${EASY_ALL_REPOSITORY_URL_OVERRIDE:-https://github.com/v2yiz/easy_all.git}"
readonly DEFAULT_BRANCH="main"
BRANCH="${EASY_ALL_BRANCH:-${DEFAULT_BRANCH}}"
# 命令注册目标与运行时写锁与 easy_all 一致；_OVERRIDE 只给测试把正式路径映射到临时目录。
# 不用 readonly 与同名环境变量共存：bootstrap 必须按自己的 override/默认值行事，
# 不能因为外层环境中已有同名变量而指向别处。
INSTALL_DIR="${EASY_ALL_INSTALL_DIR_OVERRIDE:-/usr/local/lib/easy_all}"
COMMAND_PATH="${EASY_ALL_COMMAND_PATH_OVERRIDE:-/usr/local/bin/easy_all}"
RUNTIME_WRITE_LOCK_FILE="${RUNTIME_WRITE_LOCK_FILE_OVERRIDE:-/var/lib/easy_all/runtime-write.lock}"

die() {
    printf '错误: %s\n' "$*" >&2
    exit 1
}

command -v curl >/dev/null 2>&1 || die "本机缺少 curl"
if (($# == 0)); then
    [[ -t 0 ]] || die "安装必须在交互终端中执行；不要使用 curl | bash"
fi

TEMP_DIR=$(mktemp -d)
REPO_DIR="${TEMP_DIR}/easy_all"
cleanup() {
    rm -rf -- "${TEMP_DIR}"
}
trap cleanup EXIT
# SIGINT 会执行 EXIT 钩子，但 SIGTERM 不会：两者都显式转成 EXIT 清理。
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "$(id -u)" -eq 0 ]]; then
    SUDO=()
else
    command -v sudo >/dev/null 2>&1 || die "本机缺少 sudo；请使用 root 执行"
    SUDO=(sudo)
fi

# --- 覆盖代码前的 schema 门禁（design §5） ----------------------------------
# schema 0 的 state/marker 只能由写它的旧版本卸载。bootstrap 与 register 会整体替换
# /usr/local/lib/easy_all；覆盖后旧版本就不存在了，同大版本回退也无从执行。
require_current_schema() {
    local state_file=${EASY_ALL_STATE_FILE_OVERRIDE:-/etc/easy_all/state.env}
    local marker_file=${EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE:-/var/lib/easy_all/install-progress.env}
    local version marker_schema
    if [[ -f "${state_file}" ]]; then
        version=$(sed -n 's/^STATE_VERSION=//p' "${state_file}" | tail -n 1 || true)
        # 与 lib/state.sh 的 state_file_value 对齐：' 与 " 两种引号都要剥。
        version=${version#\'}
        version=${version%\'}
        version=${version#\"}
        version=${version%\"}
        # 缺行说明文件被截断或改坏：旧版本 loader 同样要求版本行，必须按原安装
        # 版本补回，而不是让用户拿旧版本直接卸载。行存在但值为空仍归旧 schema 提示。
        if ! grep -Eq '^STATE_VERSION=' "${state_file}" 2>/dev/null; then
            die "检测到状态文件缺少 STATE_VERSION（easy_all 各版本都会写这一行；缺失说明文件被截断或改坏）：${state_file}。请先确认本机原来的安装版本再处置：5.x 安装 → 备份后在该文件首行补回 STATE_VERSION=1，再执行 sudo easy_all uninstall；4.x 安装 → 补回 STATE_VERSION=0 后用 4.x 的 sudo easy_all uninstall（两代 loader 都要求版本行，不能直接卸载）；原版本不明时请保留现场核实，不要修改该文件。"
        fi
        [[ "${version}" == "1" ]] \
            || die "检测到旧版（schema ${version:-缺失}）easy_all 状态；当前版本只支持 schema 1。请先用安装该状态的旧版本执行 sudo easy_all uninstall（必要时 --purge-cloud），再重新安装。"
    fi
    if [[ -f "${marker_file}" ]]; then
        marker_schema=$(sed -n 's/^SCHEMA=//p' "${marker_file}" | tail -n 1 || true)
        [[ "${marker_schema:-}" == "1" ]] \
            || die "检测到旧版本的中断安装标记（SCHEMA=${marker_schema:-缺失}）；请用安装它的旧版本执行 cleanup-partial 或 uninstall 后再重装。"
    fi
}

# --- 中断注册自愈 -----------------------------------------------------------
# register-command 用两次相邻 mv 换代码（旧目录 -> .previous.*、stage -> 正式目录）。
# 两次之间掉线会留下「正式目录缺失 + 命令链接悬空 + .previous.* 还在」的残缺机器，
# 此时 `easy_all` 命令已不可用，只能靠重跑 bootstrap 用本次克隆重新注册。
# 布局不变，不做版本目录迁移；也不猜哪份 .previous.* 该执行。

# 纯 bash 路径规范化：处理 . / .. / 重复斜杠，不解析符号链接链，也不要求路径存在。
# 相对链接补全后是 /usr/local/bin/../lib/easy_all/easy_all，必须规范化后才能和正式入口比较。
normalize_install_path() {
    local rest=$1 part result="" count=0
    local -a parts=()
    while [[ -n "${rest}" ]]; do
        case "${rest}" in
        */*)
            part=${rest%%/*}
            rest=${rest#*/}
            ;;
        *)
            part=${rest}
            rest=""
            ;;
        esac
        case "${part}" in
        '' | .) continue ;;
        ..)
            if ((count > 0)) && [[ "${parts[count - 1]}" != ".." ]]; then
                count=$((count - 1))
                unset "parts[${count}]"
            else
                parts[count]=".."
                count=$((count + 1))
            fi
            ;;
        *)
            parts[count]=${part}
            count=$((count + 1))
            ;;
        esac
    done
    local i
    for ((i = 0; i < count; i++)); do
        result+="/${parts[i]}"
    done
    printf '%s\n' "${result:-/}"
}

# 原始目标（补全为绝对后）的中间组件只要有一个是符号链接，`..` 的文本折叠就不等于内核
# 解析结果：例如 /usr/local/other -> /srv/vendor/sub 时，/usr/local/bin/../other/../lib
# 折叠成 /usr/local/lib，实际却落在 /srv/vendor/lib。这种链接从未指向本项目，必须拒绝自愈。
# 逐前缀检查且保留 .. 段，让内核按真实路径解析；末组件（easy_all 入口本身）不要求存在。
install_target_has_symlink_component() {
    local rest=$1 part prefix="" count=0 i
    local -a parts=()
    while [[ -n "${rest}" ]]; do
        case "${rest}" in
        */*)
            part=${rest%%/*}
            rest=${rest#*/}
            ;;
        *)
            part=${rest}
            rest=""
            ;;
        esac
        parts[count]=${part}
        count=$((count + 1))
    done
    for ((i = 0; i < count - 1; i++)); do
        prefix+="/${parts[i]}"
        [[ -n "${parts[i]}" ]] || continue
        [[ ! -L "${prefix}" ]] || return 0
    done
    return 1
}

# 只读判定、不写任何东西：普通 bootstrap 进程用它决定要不要自愈，持锁后的特权 shell 用它复核。
interrupted_install_needs_repair() {
    local target expected backup
    [[ ! -e "${INSTALL_DIR}" && ! -L "${INSTALL_DIR}" ]] || return 1
    [[ -L "${COMMAND_PATH}" ]] || return 1
    target=$(readlink -- "${COMMAND_PATH}" 2>/dev/null) || return 1
    [[ -n "${target}" ]] || return 1
    # 只解析这一层链接：相对目标按命令所在目录补全，不跟随第三方链接链。
    [[ "${target}" == /* ]] || target="${COMMAND_PATH%/*}/${target}"
    install_target_has_symlink_component "${target}" && return 1
    target=$(normalize_install_path "${target}")
    expected=$(normalize_install_path "${INSTALL_DIR}/easy_all")
    [[ "${target}" == "${expected}" ]] || return 1
    for backup in "${INSTALL_DIR}".previous.*; do
        [[ -d "${backup}" ]] && return 0
    done
    return 1
}

# 残缺但条件不齐时只提示人工处理；健康安装（正式目录仍在）保持安静。
interrupted_install_warning() {
    [[ ! -e "${INSTALL_DIR}" && ! -L "${INSTALL_DIR}" ]] || return 0
    [[ -L "${COMMAND_PATH}" ]] || return 0
    interrupted_install_needs_repair && return 0
    printf '警告: %s 缺失但 %s 仍存在；自愈条件不满足，未自动接管。请人工核实 %s.previous.* 后重试\n' \
        "${INSTALL_DIR}" "${COMMAND_PATH}" "${INSTALL_DIR}" >&2
}

# 取锁、复核与重新注册必须在同一个特权 shell 内：锁是 FD，随该 shell 退出才释放，
# 而 sudo 每次调用都是独立进程，无法跨调用持锁。
repair_interrupted_install_locked() {
    local repo_dir=$1 target
    command -v flock >/dev/null 2>&1 || die "缺少 flock；无法保护 easy_all 运行时更新"
    install -d -m 0700 "$(dirname -- "${RUNTIME_WRITE_LOCK_FILE}")" \
        || die "无法创建 easy_all 运行时锁目录"
    exec 9>"${RUNTIME_WRITE_LOCK_FILE}" \
        || die "无法打开 easy_all 运行时锁：${RUNTIME_WRITE_LOCK_FILE}"
    flock -w 30 9 || die "另一个 easy_all 配置或运行时任务正在运行，请稍后重试"
    # 等锁期间可能已经有人修好或重新安装：取锁后必须复核，不能照着旧判断覆盖。
    interrupted_install_needs_repair \
        || die "easy_all 安装目录状态在等待运行时锁期间已变化；未自动接管，请人工核实 ${INSTALL_DIR}.previous.* 后重试"
    bash "${repo_dir}/easy_all" register-command \
        || die "重新注册 easy_all 命令失败；已保留 ${INSTALL_DIR}.previous.* 与业务状态，请检查后重试"
    target=$(readlink -- "${COMMAND_PATH}" 2>/dev/null) || target=""
    [[ "${target}" == "${INSTALL_DIR}/easy_all" && -x "${INSTALL_DIR}/easy_all" ]] \
        || die "重新注册 easy_all 命令后入口仍不可用：${COMMAND_PATH}"
    # 必须显式关闭：原请求（如 install）随后要自己取同一把写锁。
    exec 9>&-
}

repair_interrupted_install() {
    local repo_dir=$1 script
    if ! interrupted_install_needs_repair; then
        interrupted_install_warning
        return 0
    fi
    printf '检测到上次更新中断（%s 缺失、%s 悬空）；正在用本次克隆恢复 easy_all 命令\n' \
        "${INSTALL_DIR}" "${COMMAND_PATH}" >&2
    # 特权 shell 只拿到判定与修复函数，判定逻辑不复制一份。
    script='set -Eeuo pipefail'$'\n'
    script+=$(declare -f die normalize_install_path install_target_has_symlink_component \
        interrupted_install_needs_repair repair_interrupted_install_locked)
    script+=$'\n'"INSTALL_DIR=$(printf '%q' "${INSTALL_DIR}")"$'\n'
    script+="COMMAND_PATH=$(printf '%q' "${COMMAND_PATH}")"$'\n'
    script+="RUNTIME_WRITE_LOCK_FILE=$(printf '%q' "${RUNTIME_WRITE_LOCK_FILE}")"$'\n'
    script+='repair_interrupted_install_locked "$@"'$'\n'
    "${SUDO[@]+"${SUDO[@]}"}" bash -c "${script}" repair-interrupted-install "${repo_dir}" \
        || die "无法恢复 easy_all 命令；已保留 ${INSTALL_DIR}.previous.* 与业务状态，未执行本次请求"
    printf '已恢复 easy_all 命令：%s\n' "${COMMAND_PATH}"
}

# /etc/easy_all 是 0700：非 root 读不到状态文件，必须在提权后的上下文里做门禁。
if ((${#SUDO[@]} > 0)); then
    # sudo 默认 env_reset 会清掉命令前的前缀变量：用 env 显式带入门禁路径，否则提权
    # 子 shell 会回落到真实路径（隔离覆盖/测试夹具失效）。
    "${SUDO[@]}" env \
        EASY_ALL_STATE_FILE_OVERRIDE="${EASY_ALL_STATE_FILE_OVERRIDE:-/etc/easy_all/state.env}" \
        EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE="${EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE:-/var/lib/easy_all/install-progress.env}" \
        bash -c "$(declare -f die require_current_schema); require_current_schema"
else
    require_current_schema
fi

if ! command -v git >/dev/null 2>&1; then
    command -v apt-get >/dev/null 2>&1 || die "仅支持使用 APT 安装 git"
    # 非交互环境必须显式声明。`env` 让空 SUDO 与 sudo 两条路径都执行同一个真实命令；
    # `${SUDO[@]+...}` 避免空数组在 `set -u` 下展开报错（bash 3.2）。
    apt_noninteractive() {
        "${SUDO[@]+"${SUDO[@]}"}" env DEBIAN_FRONTEND=noninteractive apt-get "$@"
    }
    apt_noninteractive -o DPkg::Lock::Timeout=300 update
    apt_noninteractive -o DPkg::Lock::Timeout=300 install -y --no-install-recommends git ca-certificates
fi

git clone --depth 1 --branch "${BRANCH}" "${REPOSITORY_URL}" "${REPO_DIR}" \
    || die "克隆 easy_all 仓库失败"

[[ -f "${REPO_DIR}/easy_all" && -f "${REPO_DIR}/runtime.manifest" ]] \
    || die "下载的 easy_all 项目不完整"
chmod 0700 "${REPO_DIR}/easy_all"
# 用 bash 显式执行：仓库拉在 mktemp 目录（通常 /tmp），/tmp 被挂为 noexec 时直接执行
# 会 EACCES。
bash "${REPO_DIR}/easy_all" verify-release \
    || die "下载的 easy_all 项目不完整"
# 只有在 clone 与完整性校验都成功之后、用户原请求之前才自愈：残缺机器上的原请求
# 会因命令链接悬空而无法执行。
repair_interrupted_install "${REPO_DIR}"
if (($# == 0)); then
    "${SUDO[@]+"${SUDO[@]}"}" bash "${REPO_DIR}/easy_all" install
else
    "${SUDO[@]+"${SUDO[@]}"}" bash "${REPO_DIR}/easy_all" "$@"
fi
