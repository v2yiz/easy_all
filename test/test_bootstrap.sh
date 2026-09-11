#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
SCRIPT="${ROOT_DIR}/bootstrap.sh"

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

bash -n "${SCRIPT}"
content=$(<"${SCRIPT}")

[[ "${content}" == *'apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends git ca-certificates'* ]] \
    || fail "bootstrap must install git before cloning"
[[ "${content}" == *'git clone --depth 1 --branch "${BRANCH}"'* ]] \
    || fail "bootstrap must shallow-clone configured branch"
[[ "${content}" == *'readonly DEFAULT_BRANCH="main"'* ]] \
    || fail "bootstrap must install main by default"
[[ "${content}" == *'-f "${REPO_DIR}/runtime.manifest"'* \
    && "${content}" == *'"${REPO_DIR}/easy_all" verify-release'* \
    && "${content}" != *'lib/xhttp-runtime.sh'* ]] \
    || fail "bootstrap must delegate manifest validation to the target release"
[[ "${content}" == *'"${SUDO[@]}" "${REPO_DIR}/easy_all" install'* ]] \
    || fail "bootstrap must preserve interactive stdin when starting installation"
[[ "${content}" != *'archive/refs/heads/main.tar.gz'* ]] \
    || fail "bootstrap must use git rather than a source archive"

install_line=$(grep -n 'apt-get .*install -y' "${SCRIPT}" | cut -d: -f1)
clone_line=$(grep -n 'git clone --depth 1' "${SCRIPT}" | cut -d: -f1)
((install_line < clone_line)) || fail "git installation must precede git clone"

printf 'ok - bootstrap shell tests passed\n'
