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
    # die 的调用点（文件:行）：跳过 die 的实现文件与参数层包装，指向真正出错的业务代码。
    # 直接用 BASH_SOURCE[1] 会把 params_die 内部的 die 调用当成失败位置。
    easy_all_error_source() {
        local index=1 source
        while (( index < ${#BASH_SOURCE[@]} )); do
            source=${BASH_SOURCE[index]}
            case "${source}" in
            *lib/log.sh | *lib/params.sh)
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
strip_terminal_input() {
    local esc=$'\033'
    printf '%s' "$1" | sed -e "s/${esc}\[[0-9;?]*[A-Za-z]//g" -e "s/${esc}O[A-Za-z]//g" \
        | tr -d '\000-\010\013\014\016-\037\177'
}

read_prompt() {
    local prompt=$1 variable=$2 silent=${3:-0} value
    if [[ "${silent}" == "1" ]]; then
        IFS= read -r -s -p "${prompt}" value
    else
        IFS= read -r -e -p "${prompt}" value
    fi
    printf -v "${variable}" '%s' "$(strip_terminal_input "${value}")"
}
