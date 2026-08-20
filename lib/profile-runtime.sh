#!/usr/bin/env bash

# Shared profile plumbing. The unified launcher overrides command registration
# during normal dispatch; the fallback keeps direct Profile execution complete.

make_temp_dir() {
    mktemp -d "${RUNTIME_TMP}/part.XXXXXX"
}

prompt_value() {
    local label=$1 default=${2:-} value
    if [[ -n "${default}" ]]; then
        read -r -p "${label} [${default}]（直接回车使用默认值）: " value
        printf '%s' "${value:-${default}}"
    else
        read -r -p "${label}: " value
        printf '%s' "${value}"
    fi
}

register_easy_all_command() {
    local launcher="${SCRIPT_DIR}/../easy_all"
    [[ -f "${launcher}" ]] \
        || die "缺少统一入口，Profile 不能独立注册：${launcher}"
    bash "${launcher}" register-command
}
