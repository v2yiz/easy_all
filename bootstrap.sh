#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly REPOSITORY_URL="https://github.com/v2yiz/easy_all.git"

die() {
    printf '错误: %s\n' "$*" >&2
    exit 1
}

command -v curl >/dev/null 2>&1 || die "本机缺少 curl"
[[ -t 0 ]] || die "安装必须在交互终端中执行；不要使用 curl | bash"

TEMP_DIR=$(mktemp -d)
REPO_DIR="${TEMP_DIR}/easy_all"
cleanup() {
    rm -rf -- "${TEMP_DIR}"
}
trap cleanup EXIT

if [[ "$(id -u)" -eq 0 ]]; then
    SUDO=()
else
    command -v sudo >/dev/null 2>&1 || die "本机缺少 sudo；请使用 root 执行"
    SUDO=(sudo)
fi

if ! command -v git >/dev/null 2>&1; then
    command -v apt-get >/dev/null 2>&1 || die "仅支持使用 APT 安装 git"
    "${SUDO[@]}" apt-get update
    "${SUDO[@]}" apt-get install -y --no-install-recommends git ca-certificates
fi

git clone --depth 1 --branch main "${REPOSITORY_URL}" "${REPO_DIR}" \
    || die "克隆 easy_all 仓库失败"

[[ -f "${REPO_DIR}/easy_all" \
    && -f "${REPO_DIR}/lib/reality.sh" \
    && -f "${REPO_DIR}/lib/xhttp.sh" \
    && -f "${REPO_DIR}/sample-mihomo.yaml" ]] \
    || die "下载的 easy_all 项目不完整"

chmod 0700 "${REPO_DIR}/easy_all"
"${SUDO[@]}" "${REPO_DIR}/easy_all" install
