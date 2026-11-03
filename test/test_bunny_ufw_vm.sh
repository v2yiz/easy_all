#!/usr/bin/env bash
# Real UFW integration; dedicated disposable Linux VM only. Never run on a host.
set -Eeuo pipefail
[[ "${EASY_ALL_DEDICATED_TEST_VM:-}" == 1 && "$(uname -s)" == Linux && "$(id -u)" == 0 ]] \
    || { printf '%s\n' 'Requires root in a dedicated disposable Linux VM and EASY_ALL_DEDICATED_TEST_VM=1' >&2; exit 1; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [[ "${1:-}" != --isolated ]]; then
    export EASY_ALL_UFW_PARENT_NETNS
    EASY_ALL_UFW_PARENT_NETNS=$(readlink /proc/self/ns/net)
    exec unshare --mount --net --pid --fork --mount-proc bash "$0" --isolated
fi
[[ "$(readlink /proc/self/ns/net)" != "${EASY_ALL_UFW_PARENT_NETNS:-}" ]] \
    || { printf '%s\n' 'Network namespace isolation was not established' >&2; exit 1; }

mount --make-rprivate /
sandbox=$(mktemp -d)
sshd_pid=""
stop_sshd() {
    [[ -z "${sshd_pid}" ]] || kill "${sshd_pid}" 2>/dev/null || true
    [[ -z "${sshd_pid}" ]] || wait "${sshd_pid}" 2>/dev/null || true
    sshd_pid=""
}
cleanup() {
    stop_sshd
    umount /etc/ssh 2>/dev/null || true
    umount /etc/default 2>/dev/null || true
    umount /etc/ufw 2>/dev/null || true
    rm -rf -- "${sandbox}"
}
trap cleanup EXIT
cp -a /etc/ufw "${sandbox}/ufw"
cp -a /etc/ssh "${sandbox}/ssh"
mkdir "${sandbox}/default"
cp /etc/default/ufw "${sandbox}/default/ufw"
mount --bind "${sandbox}/ufw" /etc/ufw
mount --bind "${sandbox}/ssh" /etc/ssh
mount --bind "${sandbox}/default" /etc/default

ip link set lo up
ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/easy_all_test_key
start_sshd() {
    local port
    stop_sshd
    {
        printf 'HostKey /etc/ssh/easy_all_test_key\n'
        printf 'PidFile %s/sshd.pid\n' "${sandbox}"
        printf 'PasswordAuthentication no\nPermitRootLogin no\nUsePAM no\n'
        for port in "$@"; do
            printf 'Port %s\nListenAddress 0.0.0.0:%s\n' "${port}" "${port}"
        done
    } > /etc/ssh/sshd_config
    /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config 2>"${sandbox}/sshd.log" &
    sshd_pid=$!
    for _ in {1..50}; do
        if (($(ss -H -ltn | awk '$4 ~ /:(22|2222)$/ {count++} END {print count+0}') == $#)); then
            return 0
        fi
        kill -0 "${sshd_pid}" 2>/dev/null || break
        sleep 0.1
    done
    cat "${sandbox}/sshd.log" >&2
    return 1
}

# Only the external Bunny API response is replaced. sshd -T uses the real binary
# and the sshd listeners seen by the CLI are real processes in this namespace.
curl() {
    local output="" arg
    while (($#)); do
        arg=$1
        shift
        if [[ "${arg}" == "-o" ]]; then
            output=$1
            shift
        fi
    done
    [[ -n "${output}" ]] || return 1
    printf '["192.0.2.1"]\n' >"${output}"
}
sshd() {
    if [[ "${1:-}" == "-T" ]]; then
        command /usr/sbin/sshd -T -f /etc/ssh/sshd_config
    else
        command /usr/sbin/sshd "$@"
    fi
}
export -f curl sshd

mkdir -p "${sandbox}/state"
cat >"${sandbox}/state/state.env" <<EOF
STATE_VERSION="0"
PROTOCOL="bunny-ws"
OWNER_TOKEN="test-owner-token"
EOF
cp /etc/ufw/before.rules "${sandbox}/before.rules"
export EASY_ALL_STATE_FILE_OVERRIDE="${sandbox}/state/state.env"
export STATE_DIR="${sandbox}/state" STATE_FILE="${sandbox}/state/state.env"
export BUNNY_RECOVERY_DIR="${sandbox}/recovery"
export BUNNY_EDGE_IP_FILE="${sandbox}/bunny-edge-ips"
export UFW_BEFORE_RULES="${sandbox}/before.rules"

run_cli() {
    bash "${root}/easy_all" refresh-origin-ips
}
reset_firewall() {
    ufw --force reset >/dev/null
    sleep 1
    ufw default deny incoming >/dev/null
    rm -f -- "${STATE_DIR}/runtime-write.lock" "${BUNNY_EDGE_IP_FILE}"
}
activate_firewall() {
    [[ "$1" == no ]] || ufw --force enable >/dev/null
}
rules() {
    if [[ "$(ufw status | head -n 1)" == 'Status: active' ]]; then
        ufw status numbered
    else
        ufw show added
    fi
}

reset_firewall
start_sshd 2222
ufw allow 2200/tcp comment easy_all-managed >/dev/null
activate_firewall yes
run_cli
run_cli
rules | grep -E '^\[[[:space:]]*[0-9]+\][[:space:]]+2222/tcp[[:space:]]+ALLOW[[:space:]]+IN[[:space:]]+Anywhere[[:space:]]+#[[:space:]]+easy_all-managed' >/dev/null
! rules | grep -F '65533/tcp' >/dev/null
printf 'ok - CLI installs and refreshes a real UFW SSH policy\n'

reset_firewall
start_sshd 22
ufw deny in on lo to any port 22 proto tcp comment third-party >/dev/null
activate_firewall yes
printf 'unchanged\n' >"${BUNNY_EDGE_IP_FILE}"
before_state=$(sha256sum "${STATE_FILE}")
before_rules=$(rules)
before_defaults=$(ufw status verbose | sed -n '/^Default:/p')
before_config=$(sha256sum /etc/default/ufw)
before_edge=$(sha256sum "${BUNNY_EDGE_IP_FILE}")
if run_cli >"${sandbox}/cli.log" 2>&1; then
    printf 'Expected third-party interface-limited SSH DENY to fail\n' >&2
    exit 1
fi
if [[ "$(sha256sum "${STATE_FILE}")" != "${before_state}" \
    || "$(rules)" != "${before_rules}" \
    || "$(ufw status verbose | sed -n '/^Default:/p')" != "${before_defaults}" \
    || "$(sha256sum /etc/default/ufw)" != "${before_config}" \
    || "$(sha256sum "${BUNNY_EDGE_IP_FILE}")" != "${before_edge}" ]]; then
    printf 'Failure for third-party interface-limited SSH DENY changed firewall or installation state\n' >&2
    cat "${sandbox}/cli.log" >&2
    exit 1
fi
printf 'ok - CLI rejects a third-party interface-limited SSH DENY before changing state\n'
