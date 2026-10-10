#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "${TMP_DIR}"' EXIT
die() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
info() { :; }
warn() { :; }

for profile in xhttp-cloudflare-streamup reality; do
    (
        source "${ROOT_DIR}/lib/firewall.sh"
        # Load only the firewall functions; no system paths or services are touched.
        eval "$(sed -n '/^xhttp_configure_ufw()/,/^}/p; /^cloudflare_configure_origin_firewall()/,/^}/p; /^configure_ufw()/,/^}/p; /^reality_cloudflare_configure_subscription_firewall()/,/^}/p' "${ROOT_DIR}/profiles/${profile}.sh")"
        RUNTIME_TMP="${TMP_DIR}/${profile}"
        mkdir -p "${RUNTIME_TMP}"
        CLOUDFLARE_ORIGIN_IPS_FILE="${RUNTIME_TMP}/ranges"
        UFW_RULE_COMMENT=easy_all-managed
        CLOUDFLARE_UFW_COMMENT=easy_all-cloudflare-origin
        CLOUDFLARE_SUBSCRIPTION_UFW_COMMENT=easy_all-cloudflare-subscription
        SERVICE_PORT=443
        SUBSCRIPTION_HTTPS_PORT=8443
        origin_port=443
        [[ "${profile}" != reality ]] || origin_port=8443
        state="${RUNTIME_TMP}/rules"
        log="${RUNTIME_TMP}/calls"
        reset_rules() {
            printf '22|Anywhere\n%s|198.51.100.0/24\n' "${origin_port}" >"${state}"
            printf '198.51.100.0/24\n' >"${CLOUDFLARE_ORIGIN_IPS_FILE}"
            : >"${log}"
        }
        snapshot_ufw_state() { :; }
        ensure_ssh_boot_service() { :; }
        ensure_ssh_fail2ban() { :; }
        detect_ssh_ports() { SSH_PORTS=22; }
        configure_ufw_ip_family() { :; }
        write_ufw_nat_rules() { :; }
        systemctl() { :; }
        subscription_enabled() { return 0; }
        cloudflare_fetch_origin_ipv4_ranges() { printf '203.0.113.0/24\n192.0.2.0/24\n'; }
        reality_cloudflare_fetch_origin_ipv4_ranges() { cloudflare_fetch_origin_ipv4_ranges; }
        ufw() {
            local port source rule
            if [[ "$1" == status ]]; then
                printf 'Status: active\n'
                awk -F'|' -v managed="${UFW_RULE_COMMENT}" '{printf "[ %d] %s/tcp ALLOW IN %s # %s\n", NR, $1, $2, ($2 == "Anywhere" ? managed : "cloudflare")}' "${state}"
                return 0
            fi
            printf '%s\n' "$*" >>"${log}"
            if [[ "$1" == allow ]]; then
                if [[ "$2" == proto ]]; then
                    port=$9; source=$5
                    if [[ "${source}" == 192.0.2.0/24 ]]; then
                        case "${failure:-}" in
                            error) return 1 ;;
                            kill) command bash -c 'kill -KILL "$PPID"' ;;
                            skip) return 0 ;;
                        esac
                    fi
                else
                    port=${2%/tcp}; source=Anywhere
                fi
                rule="${port}|${source}"
                grep -Fxq "${rule}" "${state}" || printf '%s\n' "${rule}" >>"${state}"
            elif [[ "$1 ${2:-}" == '--force enable' ]]; then
                grep -Fxq '22|Anywhere' "${state}" || die "UFW enabled before SSH was protected"
            elif [[ "$1 ${2:-}" == '--force delete' ]]; then
                rule="${11}|$7"
                awk -v rule="${rule}" '$0 != rule' "${state}" >"${state}.next"
                mv "${state}.next" "${state}"
            fi
        }
        run_refresh() {
            if [[ "${profile}" == reality ]]; then configure_ufw; else xhttp_configure_ufw; fi
        }
        assert_restricted() {
            if grep -Fxq "${origin_port}|Anywhere" "${state}" \
                || grep -Fq "allow ${origin_port}/tcp comment" "${log}"; then
                die "${profile}: refresh opened the origin to the Internet"
            fi
        }
        reset_rules
        run_refresh
        assert_restricted
        ! grep -Fq '198.51.100.0/24' "${state}" || die "${profile}: stale source remained"
        ufw_tcp_port_is_allowed "${origin_port}" 192.0.2.0/24 || die "New source missing"
        if ufw_tcp_port_is_allowed "${origin_port}" 198.51.100.0/24; then die "Stale source still allowed"; fi
        added=$(awk '/allow proto tcp from 192.0.2.0/ {print NR; exit}' "${log}")
        removed=$(awk '/--force delete allow/ {print NR; exit}' "${log}")
        [[ -n "${added}" && -n "${removed}" && "${added}" -lt "${removed}" ]] \
            || die "${profile}: old sources removed before new sources"
        for failure in error skip kill; do
            reset_rules
            if (run_refresh) >/dev/null 2>&1; then
                die "${profile}: ${failure} injection unexpectedly succeeded"
            else
                status=$?
                [[ "${failure}" != kill || "${status}" == 137 ]] || die "SIGKILL injection failed"
            fi
            assert_restricted
            grep -Fxq "${origin_port}|198.51.100.0/24" "${state}" || die "${profile}: failure removed old source"
            grep -Fxq '198.51.100.0/24' "${CLOUDFLARE_ORIGIN_IPS_FILE}" || die "Failure overwrote cached sources"
        done
        printf 'ok - %s firewall refresh remains restricted and preserves old sources on failure\n' "${profile}"
    )
done
