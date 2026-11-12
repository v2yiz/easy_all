#!/usr/bin/env bash

# Shared logging primitives for easy_all runtime modules.

if [[ "${EASY_ALL_LOG_LOADED:-0}" != "1" ]]; then
    EASY_ALL_LOG_LOADED=1
    RED='\033[31m'
    GREEN='\033[32m'
    YELLOW='\033[33m'
    CYAN='\033[1;36m'
    RESET='\033[0m'

    info() { printf '%b%s%b\n' "${CYAN}" "$*" "${RESET}"; }
    success() { printf '%b%s%b\n' "${GREEN}" "$*" "${RESET}"; }
    warn() { printf '%b%s%b\n' "${YELLOW}" "$*" "${RESET}"; }
    fail() { printf '%b%s%b\n' "${RED}" "$*" "${RESET}" >&2; return 1; }
    # 最后一次错误文案：安装失败报告会用它说明“哪里出错”（die 的消息已经打印过，
    # 这里只是留存一份给退出时的统一诊断）。
    EASY_ALL_LAST_ERROR=""
    EASY_ALL_LAST_ERROR_SOURCE=""
    # die 的调用点（文件:行）：跳过 die 的实现文件，指向真正出错的业务代码。
    easy_all_error_source() {
        local index=1 source
        while (( index < ${#BASH_SOURCE[@]} )); do
            source=${BASH_SOURCE[index]}
            case "${source}" in
            *lib/log.sh)
                index=$((index + 1))
                continue
                ;;
            esac
            printf '%s:%s\n' "${source}" "${BASH_LINENO[index - 1]}"
            return 0
        done
        return 1
    }
    die() {
        EASY_ALL_LAST_ERROR="$*"
        EASY_ALL_LAST_ERROR_SOURCE=$(easy_all_error_source || true)
        fail "$*"
        exit 1
    }
fi

# Interactive prompts: readline 编辑（方向键/Ctrl-U）+ 清理被当成普通字符的转义序列。
# CSI 的终止符除了字母还有 '~'：括号粘贴标记 ESC[200~ / ESC[201~ 不带字母，
# 漏掉就会把 "[200~<值>[201~" 当成用户输入（Token 直接判格式无效）。
strip_terminal_input() {
    local esc=$'\033'
    printf '%s' "$1" | sed -e "s/${esc}\[[0-9;?]*[~A-Za-z]//g" -e "s/${esc}O[A-Za-z]//g" \
        | tr -d '\000-\010\013-\037\177'
}

read_prompt() {
    # 内部累加器叫 raw：避开调用方常见的 value 变量（同名时 -v 会改到内部局部变量）。
    local prompt=$1 variable=$2 silent=${3:-0} raw="" char
    if [[ "${silent}" == "1" ]]; then
        # 静默输入不走 readline：会话 pty 被留在 raw 模式（浏览器控制台、跳板机）时
        # 回车只送来 \r，等 \n 的 read 会永久挂住。这里逐字符读到 \r 或 \n 为止，
        # 不修改终端设置（回显由 -s 关闭），canonical 与 raw 两种模式都能结束。
        printf '%s' "${prompt}" >&2
        while IFS= read -r -s -n 1 char; do
            case "${char}" in
            $'\r' | $'\n') break ;;
            # raw 模式下 Ctrl+C 只是普通字节，不会变成信号。
            $'\x03') return 130 ;;
            # -n 让 bash 以非 canonical 模式读，行规程不再处理编辑键：自己实现
            # 退格、^U（清行）、^W（删词），否则残留前缀会静默混进凭据。
            $'\x7f' | $'\b') raw=${raw%?} ;;
            $'\x15') raw="" ;;
            $'\x17') while [[ -n "${raw}" && "${raw: -1}" != ' ' ]]; do raw=${raw%?}; done ;;
            *) raw+=${char} ;;
            esac
        done
    else
        IFS= read -r -e -p "${prompt}" raw
    fi
    printf -v "${variable}" '%s' "$(strip_terminal_input "${raw}")"
}
