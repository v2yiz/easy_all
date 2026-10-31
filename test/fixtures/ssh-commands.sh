#!/usr/bin/env bash
# External command fixtures only; all file paths belong to the Node-created fixture.
set -Eeuo pipefail
source "$ROOT/lib/platform.sh"
source "$ROOT/lib/firewall.sh"
RUNTIME_TMP="$FIXTURE/runtime"
BACKUP_DIR="$FIXTURE/state/backups"
STATE_DIR="$FIXTURE/state"
STATE_FILE="$STATE_DIR/state.env"
EASY_ALL_SSH_PORT_CONFIG="$FIXTURE/ssh/ports.conf"
EASY_ALL_FAIL2BAN_CONFIG="$FIXTURE/f2b/jail.conf"
EASY_ALL_FAIL2BAN_ACTION_CONFIG="$FIXTURE/f2b/action.conf"
EASY_ALL_FAIL2BAN_CIDR_HELPER="$FIXTURE/f2b/helper.sh"
EASY_ALL_FAIL2BAN_CIDR_STATE_DIR="$FIXTURE/f2b/state"
UFW_DEFAULT_CONFIG="$FIXTURE/ufw/default"
UFW_BEFORE_RULES="$FIXTURE/ufw/before.rules"
UFW_BEFORE6_RULES="$FIXTURE/ufw/before6.rules"
UFW_RULE_COMMENT=easy_all-managed
cleanup_files=()
mkdir -p "$RUNTIME_TMP" "$BACKUP_DIR" "$FIXTURE/ssh" "$FIXTURE/f2b" "$FIXTURE/ufw"
printf 'IPV6=no\n' > "$UFW_DEFAULT_CONFIG"
printf '22|ALLOW|OpenSSH\n' > "$FIXTURE/rules"
printf '0.0.0.0:22\n' > "$FIXTURE/listeners"
printf 'installed\n' > "$STATE_FILE"
: > "$FIXTURE/ufw-delete.log"
SSH_CONNECTION='192.0.2.1 1000 192.0.2.2 22'
EASY_ALL_SSH_PRESERVE_PORTS='22 2222'
info() { echo "$*"; }
warn() { echo "$*" >&2; }
die() { echo "$*" >&2; exit 1; }
sleep() { :; }
apt-get() { die "unexpected package install in isolated SSH fixture"; }
ssh() { die "unexpected network call in isolated SSH fixture"; }
scp() { die "unexpected network call in isolated SSH fixture"; }
sshd() {
    if [[ "$1" == -t ]]; then
        [[ "${syntax_failure:-}" != always ]] || return 1
        if [[ "${syntax_failure:-}" == candidate ]] && grep -qx 'Port 65533' "$EASY_ALL_SSH_PORT_CONFIG" 2>/dev/null; then return 1; fi
        return 0
    fi
    echo 'addressfamily any'
    if [[ -f "$EASY_ALL_SSH_PORT_CONFIG" ]]; then
        awk 'tolower($1)=="port" {print "port " $2} tolower($1)=="listenaddress" {print "listenaddress " $2}' "$EASY_ALL_SSH_PORT_CONFIG"
    else
        echo 'port 22'; echo 'listenaddress 0.0.0.0:22'
    fi
    [[ "${effective_conflict:-}" != yes ]] || echo 'listenaddress 0.0.0.0:22'
    [[ "${extra_port_entry:-}" != yes ]] || echo 'port 22'
    return 0
}
ss() {
    local endpoint port filter="${*: -1}" process=${listener_process:-sshd}
    [[ "${occupied:-}" != yes ]] || process=nginx
    while read -r endpoint; do
        port=${endpoint##*:}
        [[ "$filter" != 'sport = '* || "$filter" == "sport = :$port" ]] || continue
        if [[ "${shared_socket:-}" == yes ]]; then
            printf 'LISTEN 0 128 %s 0.0.0.0:* users:(("systemd",pid=1,fd=3),("sshd",pid=12,fd=3))\n' "$endpoint"
        else
            printf 'LISTEN 0 128 %s 0.0.0.0:* users:(("%s",pid=12,fd=3))\n' "$endpoint" "$process"
        fi
    done < "$FIXTURE/listeners"
    if [[ -e "$FIXTURE/non-ssh-original-socket" && ( "$filter" != 'sport = '* || "$filter" == 'sport = :22' ) ]]; then
        echo 'LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("systemd",pid=1,fd=5))'
    fi
    if [[ -e "$FIXTURE/non-ssh-socket" && ( "$filter" != 'sport = '* || "$filter" == 'sport = :65533' ) ]]; then
        echo 'LISTEN 0 128 0.0.0.0:65533 0.0.0.0:* users:(("systemd",pid=1,fd=4))'
    fi
    if [[ "${mixed_occupancy:-}" == yes && ( "$filter" != 'sport = '* || "$filter" == 'sport = :65533' ) ]]; then
        echo 'LISTEN 0 128 192.0.2.2:65533 0.0.0.0:* users:(("nginx",pid=13,fd=3))'
    fi
}
systemctl() {
    echo "$*" >> "$FIXTURE/systemctl.log"
    if [[ "$1" == reload && "$2" == ssh* ]]; then
        if [[ "${reload_failure:-}" == always || ( "${reload_failure:-}" == restore && ! -f "$EASY_ALL_SSH_PORT_CONFIG" ) ]]; then return 1; fi
        if [[ "${actual_failure:-}" == restore && ! -f "$EASY_ALL_SSH_PORT_CONFIG" ]]; then return 0; fi
        if [[ "${original_socket_on_restore:-}" == yes && ! -f "$EASY_ALL_SSH_PORT_CONFIG" ]]; then
            : > "$FIXTURE/non-ssh-original-socket"
            : > "$FIXTURE/listeners"
            return 0
        fi
        if [[ "${socket_after_reload:-}" == yes && -f "$EASY_ALL_SSH_PORT_CONFIG" ]]; then
            : > "$FIXTURE/non-ssh-socket"
            : > "$FIXTURE/listeners"
            return 0
        fi
        sshd -T | awk '$1=="listenaddress" {print $2}' > "$FIXTURE/listeners"
        [[ "${actual_conflict:-}" != yes ]] || echo '0.0.0.0:22' >> "$FIXTURE/listeners"
        [[ "${missing_target:-}" != yes ]] || : > "$FIXTURE/listeners"
    fi
    return 0
}
dpkg-query() { printf 'ii '; }
fail2ban-client() { return 0; }
ufw() {
    local line port action comment number
    if [[ "$1" == status ]]; then
        echo 'Status: active'
        awk -F'|' '{printf "[ %d] %s/tcp%s %s IN Anywhere # %s\n", NR,$1,($4 == "" ? "" : " on " $4),$2,$3}' "$FIXTURE/rules"
        local status_rc=$?
        # Return explicitly: a bare `return` can inherit an unrelated status and
        # make `pipefail` callers misread a successful `ufw status`.
        return "${status_rc}"
    fi
    echo "$*" >> "$FIXTURE/ufw.log"
    if [[ "$1" == allow ]]; then
        [[ "${ufw_skip_allow:-}" != yes ]] || return 0
        line="${2%/tcp}|ALLOW|$4"
        grep -Fxq "$line" "$FIXTURE/rules" || echo "$line" >> "$FIXTURE/rules"
    elif [[ "$1" == insert ]]; then
        [[ "${ufw_skip_deny:-}" != yes ]] || return 0
        [[ "$2 $3 $4" == '1 deny 22/tcp' ]] || die 'unexpected insert'
        { echo "22|DENY|$6"; cat "$FIXTURE/rules"; } > "$FIXTURE/rules.next"
        mv "$FIXTURE/rules.next" "$FIXTURE/rules"
    elif [[ "$1 ${2:-}" == '--force delete' ]]; then
        [[ "$3" =~ ^[0-9]+$ ]] || die 'fixture only supports numbered deletes'
        line=$(sed -n "${3}p" "$FIXTURE/rules")
        printf 'delete-rule %s\n' "$line" >> "$FIXTURE/ufw-delete.log"
        if [[ "$line" == '22|DENY|easy_all-managed' ]]; then
            case "${ufw_delete_deny_mode:-}" in
                error) return 1 ;;
                skip) return 0 ;;
            esac
        fi
        awk -v n="$3" 'NR!=n' "$FIXTURE/rules" > "$FIXTURE/rules.next"
        mv "$FIXTURE/rules.next" "$FIXTURE/rules"
    fi
    return 0
}
# Load the actual named profile functions, without sourcing their fixed host paths.
load_profile_functions() {
    local name definitions source_file="$ROOT/profiles/$1.sh"
    for name in xhttp_configure_ufw configure_ufw uninstall_all rollback_fresh_install restore_preinstall_firewall; do
        definitions=$(awk -v name="$name" '$0 == name "() {" {inside=1} inside {print} inside && $0 == "}" {inside=0}' "$source_file")
        eval "$definitions"
    done
    if [[ "$1" == xhttp-cloudflare-streamup ]]; then
        eval "$(sed -n '/^restore_preinstall_firewall() {$/,/^}/p' "$ROOT/lib/xhttp-runtime.sh")"
    fi
}
