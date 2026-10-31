import assert from 'node:assert/strict';
import {mkdtempSync, readFileSync, writeFileSync, mkdirSync} from 'node:fs';
import {resolve, dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
// Explicit isolated root: no runner changes to HOME/TMPDIR or host service calls.
const fixtures = process.env.EASY_ALL_SSH_TEST_TMP || '/tmp/easy-all-ssh-fixtures';
mkdirSync(fixtures, {recursive: true});
const cases = [];
function test(name, body, expected = 0) {
  const fixture = mkdtempSync(`${fixtures}/case-`);
  const script = `source "$ROOT/test/fixtures/ssh-commands.sh"\n${body}\n`;
  const run = spawnSync('bash', ['-c', script], {env: {...process.env, ROOT: root, FIXTURE: fixture}, encoding: 'utf8', timeout: 15000});
  const ok = expected === 0 ? run.status === 0 : run.status !== 0 && run.status !== null;
  cases.push({name, ok, status: run.status, fixture});
  console.log(`${ok ? 'ok' : 'not ok'} - ${name}`);
  if (!ok) console.log(run.stdout, run.stderr, run.error || '');
  return {run, fixture};
}
const converge = 'ensure_ssh_boot_service';
test('effective Port22 alone does not override explicit ListenAddress65533', `
extra_port_entry=yes
${converge}
[[ "$(cat "$FIXTURE/listeners")" == 0.0.0.0:65533 ]]
`);
test('mixed nonSSH/SSH target listeners are rejected', `
printf '0.0.0.0:65533\\n' > "$FIXTURE/listeners"
mixed_occupancy=yes
if (${converge}); then exit 9; fi
[[ ! -e "$EASY_ALL_SSH_PORT_CONFIG" ]]
`);
test('systemd socket retaining22 fails exclusive listener check', `
${converge}
listener_process=systemd
echo '0.0.0.0:22' >> "$FIXTURE/listeners"
actual_conflict=yes
if (${converge}); then exit 9; fi
`);

test('sshd ownership is accepted when systemd is listed first on a shared socket', `
shared_socket=yes
${converge}
[[ "$(cat "$FIXTURE/listeners")" == 0.0.0.0:65533 ]]
`);
test('default22 converges to only65533 despite old connection/preserve input; Fail2ban only65533', `
${converge}
[[ "$(cat "$FIXTURE/listeners")" == 0.0.0.0:65533 ]]
[[ "$(grep '^Port ' "$EASY_ALL_SSH_PORT_CONFIG")" == 'Port 65533' ]]
ensure_ssh_fail2ban
grep -qx 'port = 65533' "$EASY_ALL_FAIL2BAN_CONFIG"
`);
test('custom old SSH port is removed', `
printf 'Port 2222\\nListenAddress 0.0.0.0:2222\\n' > "$EASY_ALL_SSH_PORT_CONFIG"
printf '0.0.0.0:2222\\n' > "$FIXTURE/listeners"
${converge}
[[ "$(cat "$FIXTURE/listeners")" == 0.0.0.0:65533 ]]
`);
for (const injection of ['effective_conflict=yes', 'actual_conflict=yes', 'reload_failure=always', 'syntax_failure=candidate', 'missing_target=yes']) {
  test(`SSH failure ${injection} restores managed-file absence`, `
${injection}
if (${converge}); then exit 9; fi
[[ ! -e "$EASY_ALL_SSH_PORT_CONFIG" ]]
`);
}
for (const injection of ['reload_failure=always', 'syntax_failure=candidate']) {
  test(`SSH failure ${injection} preserves an existing managed file`, `
printf '# original fixture\\nPort 2222\\nListenAddress 0.0.0.0:2222\\n' > "$EASY_ALL_SSH_PORT_CONFIG"
cp "$EASY_ALL_SSH_PORT_CONFIG" "$FIXTURE/original.conf"
printf '0.0.0.0:2222\\n' > "$FIXTURE/listeners"
${injection}
if (${converge}); then exit 9; fi
cmp "$FIXTURE/original.conf" "$EASY_ALL_SSH_PORT_CONFIG"
[[ "$(cat "$FIXTURE/listeners")" == 0.0.0.0:2222 ]]
`);
}
test('nonSSH target occupancy fails without changes', `
printf '0.0.0.0:65533\\n' > "$FIXTURE/listeners"
occupied=yes
if (${converge}); then exit 9; fi
[[ ! -e "$EASY_ALL_SSH_PORT_CONFIG" ]]
`);
test('idempotent path rechecks actual exclusivity', `
${converge}
echo '0.0.0.0:22' >> "$FIXTURE/listeners"
actual_conflict=yes
if (${converge}); then exit 9; fi
`);
test('UFW65533 first, deny22 precedes unmanaged OpenSSH, idempotence and cleanup', `
apply_ssh_ufw_policy '65533 443'
[[ "$(head -1 "$FIXTURE/rules")" == '22|DENY|easy_all-managed' ]]
grep -qx '22|ALLOW|OpenSSH' "$FIXTURE/rules"
a=$(awk '/allow 65533/ {print NR;exit}' "$FIXTURE/ufw.log")
d=$(awk '/insert 1 deny 22/ {print NR;exit}' "$FIXTURE/ufw.log")
[[ $a -lt $d ]]
apply_ssh_ufw_policy '65533 443'
[[ $(grep -c '22|DENY' "$FIXTURE/rules") == 1 ]]
remove_managed_ufw_rules
[[ "$(cat "$FIXTURE/rules")" == '22|ALLOW|OpenSSH' ]]
`);
test('UFW earlier65533 deny prevents closing22', `
printf '65533|DENY|user-rule\\n22|ALLOW|OpenSSH\\n' > "$FIXTURE/rules"
if (apply_ssh_ufw_policy '65533'); then exit 9; fi
! grep -q '22|DENY' "$FIXTURE/rules"
`);
test('R3 early interface-qualified deny65533 blocks closing22', `
printf '65533|DENY|user-rule|eth0\\n22|ALLOW|OpenSSH\\n' > "$FIXTURE/rules"
if (apply_ssh_ufw_policy '65533'); then exit 9; fi
! grep -q '22|DENY' "$FIXTURE/rules"
`);
test('interface-only allow65533 cannot replace a global allow', `
printf '65533|ALLOW|user-rule|eth0\\n22|ALLOW|OpenSSH\\n' > "$FIXTURE/rules"
ufw_skip_allow=yes
if (apply_ssh_ufw_policy '65533'); then exit 9; fi
! grep -q '22|DENY' "$FIXTURE/rules"
`);
test('UFW false allow success never inserts deny22', `
ufw_skip_allow=yes
if (apply_ssh_ufw_policy '65533'); then exit 9; fi
! grep -q '22|DENY' "$FIXTURE/rules"
`);
test('UFW moves its own deny ahead of another tool while preserving other rules', `
printf '22|ALLOW|OpenSSH\\n22|DENY|easy_all-managed\\n22|DENY|debian-init-managed\\n9999|ALLOW|user-rule\\n' > "$FIXTURE/rules"
apply_ssh_ufw_policy '65533'
[[ "$(head -1 "$FIXTURE/rules")" == '22|DENY|easy_all-managed' ]]
[[ $(grep -c '22|DENY|easy_all-managed' "$FIXTURE/rules") == 1 ]]
remove_managed_ufw_rules
grep -qx '22|DENY|debian-init-managed' "$FIXTURE/rules"
grep -qx '9999|ALLOW|user-rule' "$FIXTURE/rules"
`);
for (const injection of ['ufw_skip_allow=yes', 'ufw_skip_deny=yes']) test(`UFW false success rejected: ${injection}`, `${injection}\napply_ssh_ufw_policy '65533'`, 1);
for (const profile of ['reality', 'xhttp-cloudflare-streamup']) {
  test(`${profile} actual firewall caller ignores old SSH port; actual Fail2ban`, `
load_profile_functions ${profile}
snapshot_ufw_state() { :; }
write_ufw_nat_rules() { :; }
subscription_enabled() { return 1; }
reality_cloudflare_remove_subscription_firewall_rules() { :; }
cloudflare_configure_origin_firewall() { :; }
SERVICE_PORT=443
${profile === 'reality' ? 'configure_ufw' : 'xhttp_configure_ufw'}
[[ "$(cat "$FIXTURE/listeners")" == 0.0.0.0:65533 ]]
[[ "$(head -1 "$FIXTURE/rules")" == '22|DENY|easy_all-managed' ]]
! grep -q '22|ALLOW|easy_all-managed' "$FIXTURE/rules"
grep -qx 'port = 65533' "$EASY_ALL_FAIL2BAN_CONFIG"
`);
  for (const timing of ['existing', 'after-reload']) {
    test(`R1 ${profile}: unrelated systemd65533 socket ${timing} cannot authorize deny22`, `
load_profile_functions ${profile}
snapshot_ufw_state() { :; }; write_ufw_nat_rules() { :; }
subscription_enabled() { return 1; }; reality_cloudflare_remove_subscription_firewall_rules() { :; }
cloudflare_configure_origin_firewall() { :; }
SERVICE_PORT=443
${timing === 'existing' ? ': > "$FIXTURE/non-ssh-socket"' : 'socket_after_reload=yes'}
if (${profile === 'reality' ? 'configure_ufw' : 'xhttp_configure_ufw'}); then exit 9; fi
[[ ! -e "$EASY_ALL_SSH_PORT_CONFIG" ]]
[[ "$(cat "$FIXTURE/listeners")" == 0.0.0.0:22 ]]
! grep -q '22|DENY' "$FIXTURE/rules"
`);
  }
  for (const caller of ['uninstall_all', 'rollback_fresh_install', 'cleanup']) for (const failure of ['restore', 'actual', 'syntax', 'systemd-original22', 'deny-delete-error', 'deny-delete-skip', 'none']) {
    test(`${profile} ${caller}: SSH restore ${failure}`, `
snapshot_platform_security_state
${converge}
apply_ssh_ufw_policy '65533'
load_profile_functions ${profile}
# Boundaries outside SSH/UFW restoration have no business services in this fixture.
require_root() { :; }; load_state() { :; }; stop_maintenance_services() { :; }
acquire_runtime_write_lock() { :; }; stop_protocol_services() { :; }; stop_services() { :; }
remove_quota_timer() { :; }; remove_globalping_refresh_timer() { :; }
cloudflare_remove_origin_firewall_rules() { :; }; reality_cloudflare_remove_subscription_firewall_rules() { :; }
purge_cloudflare_resources_before_uninstall() { :; }
restore_bbr_tcp_install_state() { :; }; restore_preinstall_ipv6() { :; }; restore_preinstall_crontab() { :; }
remove_daily_reboot_schedule() { :; }; remove_dynamic_port_rotation() { :; }; cloudflare_clear_api_token() { :; }
success() { echo SUCCESS > "$FIXTURE/success"; }
# Exercise the real EXIT handler with its conditional rollback invocation.
eval "$(sed -n '/^cleanup() {$/,/^}/p' "$ROOT/lib/runtime-core.sh")"
end_quota_maintenance() { :; }
INSTALL_ROLLBACK_ON_EXIT=1
FORCE=1
COMMAND_PATH="$FIXTURE/command"; COMMAND_INSTALL_DIR="$FIXTURE/install"; WEB_ROOT="$FIXTURE/web"; XRAY_DIR="$FIXTURE/xray"
XRAY_SERVICE_FILE="$FIXTURE/xray.service"; NGINX_CONFIG="$FIXTURE/nginx"; REALITY_SUBSCRIPTION_JS="$FIXTURE/sub.js"
printf '' > "$BACKUP_DIR/pre-install-ufw.active"
${failure === 'restore' ? 'reload_failure=restore' : failure === 'actual' ? 'actual_failure=restore' : failure === 'syntax' ? 'syntax_failure=always' : failure === 'systemd-original22' ? 'original_socket_on_restore=yes' : failure === 'deny-delete-error' ? 'ufw_delete_deny_mode=error' : failure === 'deny-delete-skip' ? 'ufw_delete_deny_mode=skip' : ':'}
if (${caller === 'cleanup' ? 'trap cleanup EXIT; exit 1' : caller}); then status=0; else status=$?; fi
${failure === 'none' ? `
[[ $status == ${caller === 'cleanup' ? 1 : 0} && ! -e "$STATE_DIR" ]]
[[ "$(cat "$FIXTURE/listeners")" == 0.0.0.0:22 ]]
[[ "$(cat "$FIXTURE/rules")" == '22|ALLOW|OpenSSH' ]]
` : `
[[ $status != 0 && -f "$STATE_FILE" && -d "$BACKUP_DIR" && ! -e "$FIXTURE/success" ]] || exit 1
grep -qx 'Port 65533' "$EASY_ALL_SSH_PORT_CONFIG" || exit 1
grep -qx '65533|ALLOW|easy_all-managed' "$FIXTURE/rules" || exit 1
grep -qx '22|DENY|easy_all-managed' "$FIXTURE/rules" || exit 1
${failure === 'systemd-original22' ? `
[[ -f "$BACKUP_DIR/pre-install-ssh-port.conf.missing" && -e "$FIXTURE/non-ssh-original-socket" ]] || exit 1
[[ "$(cat "$FIXTURE/listeners")" == 0.0.0.0:65533 ]] || exit 1
ssh_managed_port_is_listening 65533 || exit 1
# The conflicting unknown22 socket remains visible after recovery to65533.
if ssh_listeners_match "$(ssh_effective_listeners sshd)"; then exit 9; fi
` : ''}
${failure.startsWith('deny-delete') ? `
[[ "$(cat "$FIXTURE/listeners")" == 0.0.0.0:65533 ]]
! grep -q 'delete-rule 65533|ALLOW' "$FIXTURE/ufw-delete.log"
# A subsequent retry uses the same saved state and succeeds once the external failure clears.
ufw_delete_deny_mode=''
if (${caller === 'cleanup' ? 'trap cleanup EXIT; exit 1' : caller}); then retry_status=0; else retry_status=$?; fi
[[ $retry_status == ${caller === 'cleanup' ? 1 : 0} && ! -e "$STATE_DIR" ]]
[[ "$(cat "$FIXTURE/listeners")" == 0.0.0.0:22 ]]
[[ "$(cat "$FIXTURE/rules")" == '22|ALLOW|OpenSSH' ]]
` : `! grep -q -- '--force delete' "$FIXTURE/ufw.log"`}
`}
`);
  }
}
const initializerSource = readFileSync(`${root}/scripts/debian-init.sh`, 'utf8');
const remoteScript = initializerSource.match(/cat > "\$local_script" <<'REMOTE'\n([\s\S]*?)\nREMOTE/)[1];
const remoteFunctions = ['log', 'collect_allowed_ports', 'configure_ufw'].map(name => remoteScript.match(new RegExp(`^${name}\\(\\) \\{[\\s\\S]*?^\\}`, 'm'))[0]).join('\n');
const remoteTail = remoteScript.slice(remoteScript.lastIndexOf('"$sshd_bin" -t'), remoteScript.indexOf('"$sshd_bin" -T |'));
test('generated Debian remote firewall and final SSH/F2B policy use only65533', `
${remoteFunctions}
UFW_RULE_COMMENT=debian-init-managed
extra_tcp_ports='443'
sshd_bin=sshd
${remoteTail}
[[ "$(cat "$FIXTURE/listeners")" == 0.0.0.0:65533 ]]
[[ "$(head -1 "$FIXTURE/rules")" == '22|DENY|debian-init-managed' ]]
! grep -q '22|ALLOW|debian-init-managed' "$FIXTURE/rules"
grep -qx 'port = 65533' "$EASY_ALL_FAIL2BAN_CONFIG"
`);
test('R1 generated Debian tail refuses nonSSH systemd socket after successful reload', `
${remoteFunctions}
UFW_RULE_COMMENT=debian-init-managed
extra_tcp_ports=''
sshd_bin=sshd
socket_after_reload=yes
run_generated_policy() {
${remoteTail}
}
if (run_generated_policy); then exit 9; fi
[[ ! -e "$EASY_ALL_SSH_PORT_CONFIG" ]]
[[ "$(cat "$FIXTURE/listeners")" == 0.0.0.0:22 ]]
! grep -q '22|DENY' "$FIXTURE/rules"
`);
// Actual initializer main, with only input/SSH/SCP/key command boundaries replaced.
const initializer = readFileSync(`${root}/scripts/debian-init.sh`, 'utf8').replace(/^main "\$@"$/m, '');
for (const port of [22, 65533]) for (const [remoteStatus, keyStatus] of [[0, 0], [42, 0], [255, 0], [0, 1]]) {
  const fixture = mkdtempSync(`${fixtures}/init-`);
  writeFileSync(`${fixture}/initializer.sh`, initializer);
  mkdirSync(`${fixture}/keys`);
  writeFileSync(`${fixture}/keys/id.pub`, 'fixture-public-key\n');
  writeFileSync(`${fixture}/keys/id`, 'fixture-private-key\n');
  const run = spawnSync('bash', ['-c', `
source "$FIXTURE/initializer.sh"
SSH_DIR="$FIXTURE/keys"; SSH_CONFIG="$FIXTURE/config"
# Route all mktemp allocations explicitly to this fixture.
mktemp() { command mktemp "$FIXTURE/temp.XXXXXX"; }
read_bilingual() {
 local answer=''
 case "$1" in
 '服务器 IP/域名:'*) answer=192.0.2.2;;
 '初始 SSH 登录用户 '*) answer=root;;
 '最终 SSH 登录的普通用户名:'*) answer=deploy;;
 '普通用户 deploy 的 sudo 密码:'*|'再次输入普通用户 deploy 的 sudo 密码:'*) answer=fixture;;
 '本地 ssh_config Host 别名 '*) answer=node;;
 '服务器当前 SSH 端口 '*) answer=${port};;
 '请选择 '*) answer=1;;
 esac
 printf -v "$2" '%s' "$answer"
}
ssh-copy-id() { :; }; scp() { :; }
ssh() {
 echo "$*" >> "$FIXTURE/ssh.log"
 case "$*" in
 *'mktemp -d -p /tmp'*) echo /tmp/easy_all_init.fixture;;
 *'sudo bash '*) return ${remoteStatus};;
 *'deploy@192.0.2.2'*) return ${keyStatus};;
 esac
 return 0
}
main
`], {env: {...process.env, FIXTURE: fixture, EASY_ALL_PLATFORM_MODULE_SOURCE: `${root}/lib/platform.sh`}, encoding: 'utf8', timeout: 15000});
  const wrote = (() => {try {return readFileSync(`${fixture}/config`, 'utf8');} catch {return '';}})();
  const log = readFileSync(`${fixture}/ssh.log`, 'utf8');
  const ok = remoteStatus === 0 && keyStatus === 0 ? run.status === 0 && wrote.includes('Port 65533') && log.includes('-p 65533 deploy@192.0.2.2') && run.stdout.includes('完成。') : run.status !== 0 && !wrote && !run.stdout.includes('完成。');
  const name = `initializer main current${port} remote${remoteStatus}, key${keyStatus}`;
  cases.push({name, ok, status: run.status, fixture});
  console.log(`${ok ? 'ok' : 'not ok'} - ${name}`);
  if (!ok) console.log(run.stdout, run.stderr);
}
for (const extra of ['22', '022']) test(`initializer rejects EXTRA${extra} but accepts CURRENT22`, `
eval "$(sed '$d' "$ROOT/scripts/debian-init.sh")"
SERVER_HOST=192.0.2.2; SERVER_USER=root; NORMAL_USER=deploy; HOST_ALIAS=node
CURRENT_PORT=22; FINAL_PORT=65533; CHANGE_PORT=yes; EXTRA_TCP_PORTS='${extra} 443'
validate_collected_inputs
`, 1);
console.log(JSON.stringify(cases, null, 2));
assert(cases.every(c => c.ok), `${cases.filter(c => !c.ok).length} SSH behavior checks failed`);
