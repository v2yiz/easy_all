#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly REPOSITORY_URL="${EASY_ALL_REPOSITORY_URL_OVERRIDE:-https://github.com/v2yiz/easy_all.git}"
readonly DEFAULT_BRANCH="main"
BRANCH="${EASY_ALL_BRANCH:-${DEFAULT_BRANCH}}"

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

if [[ "$(id -u)" -eq 0 ]]; then
    SUDO=()
else
    command -v sudo >/dev/null 2>&1 || die "本机缺少 sudo；请使用 root 执行"
    SUDO=(sudo)
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
if (($# == 0)); then
    "${SUDO[@]+"${SUDO[@]}"}" bash "${REPO_DIR}/easy_all" install
else
    "${SUDO[@]+"${SUDO[@]}"}" bash "${REPO_DIR}/easy_all" "$@"
fi
