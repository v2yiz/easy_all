#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

# 初始化流程：
# 1. 收集连接信息、最终登录用户和 SSH key。
# 2. 先把公钥写入初始登录用户，并验证密钥登录可用。
# 3. 远端完成系统初始化、普通用户、sudo、uv/Python、防火墙和 sshd 加固。
# 4. 本地 ssh_config 改为使用普通用户登录，并做最终验证。

SSH_DIR="${HOME}/.ssh"
SSH_CONFIG="${SSH_DIR}/config"
SSH_PUBLIC_KEY_ONLY_OPTS=(
  -o PreferredAuthentications=publickey
  -o PasswordAuthentication=no
  -o KbdInteractiveAuthentication=no
)

die() {
  echo "错误: $*" >&2
  exit 1
}

print_step() {
  local step="$1"
  local title="$2"
  echo
  echo "==> [${step}] ${title}"
}

prompt() {
  local label="$1"
  local default="${2:-}"
  local value
  if [[ -n "$default" ]]; then
    read -r -p "${label} [${default}]: " value
    printf '%s' "${value:-$default}"
  else
    read -r -p "${label}: " value
    [[ -n "$value" ]] || die "${label} 不能为空"
    printf '%s' "$value"
  fi
}

prompt_secret() {
  local label="$1"
  local value
  read -r -s -p "${label}: " value
  echo >&2
  printf '%s' "$value"
}

prompt_required_secret() {
  local label="$1"
  local value
  value="$(prompt_secret "$label")"
  [[ -n "$value" ]] || die "${label} 不能为空"
  printf '%s' "$value"
}

prompt_confirmed_secret() {
  local label="$1"
  local value confirm
  value="$(prompt_required_secret "$label")"
  confirm="$(prompt_required_secret "再次输入${label}")"
  [[ "$value" == "$confirm" ]] || die "两次输入的${label}不一致"
  printf '%s' "$value"
}

expand_path() {
  local path="$1"
  case "$path" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s/%s' "$HOME" "${path#"~/"}" ;;
    *) printf '%s' "$path" ;;
  esac
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || die "端口必须是数字: $port"
  (( port >= 1 && port <= 65535 )) || die "端口范围必须是 1-65535: $port"
}

validate_host_alias() {
  local alias="$1"
  [[ "$alias" =~ ^[A-Za-z0-9._-]+$ ]] || die "Host 名称只能包含字母、数字、点、下划线和短横线: $alias"
  [[ "$alias" != -* ]] || die "Host 名称不能以短横线开头: $alias"
}

validate_server_host() {
  local host="$1"
  [[ -n "$host" ]] || die "服务器 IP/域名不能为空"
  [[ "$host" =~ ^[^[:space:][:cntrl:]]+$ ]] || die "服务器 IP/域名不能包含空白或控制字符: $host"
}

validate_server_user() {
  local user="$1"
  [[ "$user" =~ ^[A-Za-z_][A-Za-z0-9_.-]*[$]?$ ]] || die "服务器用户名格式不合法: $user"
}

validate_linux_user() {
  local user="$1"
  [[ "$user" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "普通用户名格式不合法: $user"
  ((${#user} <= 32)) || die "普通用户名不能超过 32 个字符: $user"
}

sanitize_alias() {
  local raw="$1"
  raw="${raw// /-}"
  raw="${raw//[^A-Za-z0-9._-]/-}"
  while [[ "$raw" == -* ]]; do
    raw="${raw#-}"
  done
  [[ -n "$raw" ]] || raw="server"
  printf '%s' "$raw"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

# ================= SSH 连接与本地配置 =================

host_alias_exists_outside_managed_block() {
  local alias="$1"
  local begin="# >>> managed by setup_debian_ssh_key_only: ${alias}"
  local end="# <<< managed by setup_debian_ssh_key_only: ${alias}"

  [[ -f "$SSH_CONFIG" ]] || return 1

  awk -v alias="$alias" -v begin="$begin" -v end="$end" '
    $0 == begin { managed = 1; next }
    $0 == end { managed = 0; next }
    managed == 1 { next }
    /^[[:space:]]*Host[[:space:]]+/ {
      for (i = 2; i <= NF; i++) {
        if ($i == alias) {
          found = 1
        }
      }
    }
    END { exit found ? 0 : 1 }
  ' "$SSH_CONFIG"
}

ssh_with_password_if_possible() {
  local port="$1"
  shift
  if [[ -n "${SERVER_PASSWORD:-}" ]] && command -v sshpass >/dev/null 2>&1; then
    SSHPASS="$SERVER_PASSWORD" sshpass -e ssh \
      -p "$port" \
      -o StrictHostKeyChecking=accept-new \
      "$@"
  else
    ssh \
      -p "$port" \
      -o StrictHostKeyChecking=accept-new \
      "$@"
  fi
}

scp_with_password_if_possible() {
  local port="$1"
  shift
  if [[ -n "${SERVER_PASSWORD:-}" ]] && command -v sshpass >/dev/null 2>&1; then
    SSHPASS="$SERVER_PASSWORD" sshpass -e scp \
      -P "$port" \
      -o StrictHostKeyChecking=accept-new \
      "$@"
  else
    scp \
      -P "$port" \
      -o StrictHostKeyChecking=accept-new \
      "$@"
  fi
}

copy_public_key() {
  local public_key="$1"
  local target="$2"
  local port="$3"

  if command -v ssh-copy-id >/dev/null 2>&1; then
    if [[ -n "${SERVER_PASSWORD:-}" ]] && command -v sshpass >/dev/null 2>&1; then
      SSHPASS="$SERVER_PASSWORD" sshpass -e ssh-copy-id -i "$public_key" -p "$port" "$target"
    else
      ssh-copy-id -i "$public_key" -p "$port" "$target"
    fi
  else
    ssh_with_password_if_possible "$port" "$target" '
      set -eu
      umask 077
      mkdir -p ~/.ssh
      touch ~/.ssh/authorized_keys
      key="$(cat)"
      grep -qxF "$key" ~/.ssh/authorized_keys || printf "%s\n" "$key" >> ~/.ssh/authorized_keys
      chmod 700 ~/.ssh
      chmod 600 ~/.ssh/authorized_keys
    ' < "$public_key"
  fi
}

select_or_create_key() {
  mkdir -p "$SSH_DIR"

  echo
  echo "==> 选择 SSH key"
  echo "可复用现有公钥，也可以为本服务器生成新的 ed25519 key。"

  local pub_keys=()
  local file
  while IFS= read -r file; do
    pub_keys+=("$file")
  done < <(find "$SSH_DIR" -maxdepth 1 -type f -name "*.pub" | sort)

  local i=1
  for file in "${pub_keys[@]}"; do
    echo "  ${i}) $file"
    i=$((i + 1))
  done
  echo "  g) 生成新的 ed25519 key"
  echo "  m) 手动输入密钥路径"

  local choice
  read -r -p "请选择 [g]: " choice
  choice="${choice:-g}"

  if [[ "$choice" == "g" ]]; then
    local key_name
    key_name="$(prompt "新 key 文件名" "id_ed25519_${HOST_ALIAS}")"
    [[ "$key_name" != */* ]] || die "生成新密钥时请输入文件名，不要输入路径"
    [[ "$key_name" =~ ^[A-Za-z0-9._-]+$ ]] || die "密钥文件名只能包含字母、数字、点、下划线和短横线: $key_name"
    [[ "$key_name" != -* ]] || die "密钥文件名不能以短横线开头: $key_name"

    PRIVATE_KEY="${SSH_DIR}/${key_name}"
    PUBLIC_KEY="${PRIVATE_KEY}.pub"
    [[ ! -e "$PRIVATE_KEY" && ! -e "$PUBLIC_KEY" ]] || die "密钥已存在: $PRIVATE_KEY"

    echo "建议为人工登录设置 passphrase；如需完全免交互，直接回车使用空 passphrase。"
    local passphrase passphrase_confirm
    passphrase="$(prompt_secret "新私钥 passphrase，回车为空")"
    if [[ -n "$passphrase" ]]; then
      passphrase_confirm="$(prompt_secret "再次输入 passphrase")"
      [[ "$passphrase" == "$passphrase_confirm" ]] || die "两次输入的 passphrase 不一致"
    fi

    ssh-keygen -t ed25519 -f "$PRIVATE_KEY" -C "${HOST_ALIAS}@${SERVER_HOST}" -N "$passphrase"
    return
  fi

  if [[ "$choice" == "m" ]]; then
    local input_path
    input_path="$(prompt "私钥路径或公钥路径")"
    input_path="$(expand_path "$input_path")"
    if [[ "$input_path" == *.pub ]]; then
      PUBLIC_KEY="$input_path"
      PRIVATE_KEY="${input_path%.pub}"
    else
      PRIVATE_KEY="$input_path"
      PUBLIC_KEY="${input_path}.pub"
    fi
  elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#pub_keys[@]} )); then
    PUBLIC_KEY="${pub_keys[$((choice - 1))]}"
    PRIVATE_KEY="${PUBLIC_KEY%.pub}"
  else
    die "无效选择: $choice"
  fi

  [[ -f "$PUBLIC_KEY" ]] || die "公钥不存在: $PUBLIC_KEY"
  [[ -f "$PRIVATE_KEY" ]] || die "私钥不存在: $PRIVATE_KEY"
}

write_ssh_config() {
  local alias="$1"
  local host="$2"
  local user="$3"
  local port="$4"
  local identity_file="$5"

  mkdir -p "$SSH_DIR"
  touch "$SSH_CONFIG"
  chmod 600 "$SSH_CONFIG"

  local begin="# >>> managed by setup_debian_ssh_key_only: ${alias}"
  local end="# <<< managed by setup_debian_ssh_key_only: ${alias}"
  local tmp_file
  tmp_file="$(mktemp)"

  awk -v begin="$begin" -v end="$end" '
    $0 == begin { skip = 1; next }
    $0 == end { skip = 0; next }
    skip != 1 { print }
  ' "$SSH_CONFIG" > "$tmp_file"

  {
    cat "$tmp_file"
    echo
    echo "$begin"
    echo "Host $alias"
    echo "  HostName $host"
    echo "  User $user"
    echo "  Port $port"
    echo "  IdentityFile $identity_file"
    echo "  IdentitiesOnly yes"
    echo "$end"
  } > "$SSH_CONFIG"

  rm -f "$tmp_file"
  chmod 600 "$SSH_CONFIG"
}

# ================= 远端初始化脚本 =================

run_remote_initialization() {
  local target="$1"
  local current_port="$2"
  local final_port="$3"
  local keep_current_port="$4"
  local normal_user="$5"
  local normal_user_password="$6"
  local public_key="$7"
  local remote_script="/tmp/setup_debian_ssh_key_only_$$.sh"
  local remote_password_file="/tmp/setup_debian_normal_user_password_$$.txt"
  local remote_public_key_file="/tmp/setup_debian_normal_user_authorized_key_$$.pub"
  local local_script
  local local_password_file
  local_script="$(mktemp)"
  local_password_file="$(mktemp)"
  # 普通用户 sudo 密码只走临时文件：不写入脚本正文，也不落入 ssh 命令参数。
  printf '%s' "$normal_user_password" >"$local_password_file"

  cat > "$local_script" <<'REMOTE'
#!/bin/sh
set -eu

current_port="$1"
final_port="$2"
keep_current_port="$3"
normal_user="$4"
normal_user_password_file="$5"
normal_user_public_key_file="$6"

config_dir="/etc/ssh/sshd_config.d"
config_file="${config_dir}/99-key-only.conf"
sysctl_config="/etc/sysctl.d/99-bbrv3.conf"
xanmod_keyring="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
xanmod_repo="/etc/apt/sources.list.d/xanmod-release.list"

cleanup_sensitive_files() {
  rm -f "$normal_user_password_file" "$normal_user_public_key_file"
}
trap cleanup_sensitive_files EXIT INT TERM

log() {
  printf '%s\n' "$*"
}

validate_normal_user() {
case "$normal_user" in
  ''|[!abcdefghijklmnopqrstuvwxyz_]*|*[!abcdefghijklmnopqrstuvwxyz0123456789_-]*)
      printf '%s\n' "错误: 普通用户名格式不合法: $normal_user" >&2
      exit 1
      ;;
  esac
  if [ "${#normal_user}" -gt 32 ]; then
    printf '%s\n' "错误: 普通用户名不能超过 32 个字符: $normal_user" >&2
    exit 1
  fi
}

install_base_packages() {
  log "[remote 1/7] 更新 apt 索引并升级系统包"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get -y upgrade

  log "[remote 2/7] 安装基础包"
  apt-get install -y \
    vim tmux curl wget ca-certificates gnupg lsb-release sudo git build-essential \
    openssh-server ufw systemd-timesyncd kmod procps
}

configure_xanmod_bbrv3_and_tcp() {
  temp_dir="$(mktemp -d)"
  key_file="${temp_dir}/archive.key"
  keyring_file="${temp_dir}/archive.gpg"
  repo_file="${temp_dir}/xanmod.list"

  if [ ! -r /etc/os-release ]; then
    printf '%s\n' "错误: 无法识别操作系统" >&2
    exit 1
  fi
  . /etc/os-release
  if [ "${ID:-}" != "debian" ]; then
    printf '%s\n' "错误: XanMod BBRv3 初始化仅支持 Debian" >&2
    exit 1
  fi
  if [ "$(dpkg --print-architecture)" != "amd64" ]; then
    printf '%s\n' "错误: XanMod BBRv3 初始化仅支持 amd64" >&2
    exit 1
  fi
  if command -v systemd-detect-virt >/dev/null 2>&1 \
    && systemd-detect-virt --container >/dev/null 2>&1; then
    printf '%s\n' "错误: 容器不能更换宿主机内核" >&2
    exit 1
  fi
  if [ -z "${VERSION_CODENAME:-}" ]; then
    printf '%s\n' "错误: 无法识别 Debian 发行版代号" >&2
    exit 1
  fi

  log "[remote 3/7] 安装 XanMod LTS 并配置 BBRv3 / TCP 优化"
  install -d -m 0755 /etc/apt/keyrings
  wget -qO "$key_file" https://dl.xanmod.org/archive.key
  gpg --batch --yes --dearmor --output "$keyring_file" "$key_file"
  install -m 0644 "$keyring_file" "$xanmod_keyring"
  printf 'deb [signed-by=%s] http://deb.xanmod.org %s main\n' \
    "$xanmod_keyring" "$VERSION_CODENAME" >"$repo_file"
  install -m 0644 "$repo_file" "$xanmod_repo"
  apt-get update
  apt-get install -y linux-xanmod-lts-x64v1

  if [ -f "$sysctl_config" ] && [ ! -f "${sysctl_config}.debian_init.bak" ]; then
    cp -a "$sysctl_config" "${sysctl_config}.debian_init.bak"
  fi

  cat >"$sysctl_config" <<'SYSCTL'
net.core.default_qdisc = fq
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 4096
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
SYSCTL

  modprobe tcp_bbr 2>/dev/null || true
  sysctl -p "$sysctl_config" >/dev/null
  if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf unknown)" != "bbr" ]; then
    printf '%s\n' "错误: 拥塞控制算法未成功设置为 bbr" >&2
    exit 1
  fi

  rm -rf "$temp_dir"
  log "[remote 3/7] BBRv3 / TCP 优化配置完成；如刚安装 XanMod 内核，重启后生效"
}

configure_timezone_and_time_sync() {
  log "[remote 4/7] 设置时区为 Asia/Shanghai 并启用时间同步"
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-timezone Asia/Shanghai
    timedatectl set-ntp true || true
  else
    ln -snf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
    printf '%s\n' Asia/Shanghai >/etc/timezone
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true
  fi
}

configure_sudo_user() {
  normal_user_password="$(cat "$normal_user_password_file")"
  sudoers_file="/etc/sudoers.d/${normal_user}"

  validate_normal_user
  if [ -z "$normal_user_password" ]; then
    printf '%s\n' "错误: 普通用户 sudo 密码不能为空" >&2
    exit 1
  fi
  log "[remote 5/7] 创建或更新普通用户 ${normal_user} 并配置 sudo 权限"
  if ! id "$normal_user" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "$normal_user"
    log "[remote 5/7] 用户 ${normal_user} 已创建"
  else
    log "[remote 5/7] 用户 ${normal_user} 已存在，跳过创建；将按本次输入更新密码"
  fi

  printf '%s:%s\n' "$normal_user" "$normal_user_password" | chpasswd
  usermod -aG sudo "$normal_user"
  printf '%s\n' "${normal_user} ALL=(ALL:ALL) ALL" >"$sudoers_file"
  chmod 440 "$sudoers_file"
  if command -v visudo >/dev/null 2>&1; then
    visudo -cf "$sudoers_file" >/dev/null
  fi
  log "[remote 5/7] 用户 ${normal_user} sudo 权限配置完成"
}

install_uv_for_normal_user() {
  user_home="$(getent passwd "$normal_user" | awk -F: '{print $6}')"
  if [ -z "$user_home" ]; then
    printf '%s\n' "错误: 无法读取用户 ${normal_user} 的 home 目录" >&2
    exit 1
  fi

  log "[remote 6/7] 为普通用户 ${normal_user} 安装 uv 与 Python 3.12"
  su - "$normal_user" -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
  su - "$normal_user" -c '"${HOME}/.local/bin/uv" python install 3.12'
}

install_normal_user_authorized_key() {
  user_home="$(getent passwd "$normal_user" | awk -F: '{print $6}')"
  if [ -z "$user_home" ]; then
    printf '%s\n' "错误: 无法读取用户 ${normal_user} 的 home 目录" >&2
    exit 1
  fi

  normal_group="$(id -gn "$normal_user")"
  log "[remote 6/7] 写入普通用户 ${normal_user} 的 authorized_keys"
  install -d -m 0700 -o "$normal_user" -g "$normal_group" "${user_home}/.ssh"
  touch "${user_home}/.ssh/authorized_keys"
  if ! grep -qxF -f "$normal_user_public_key_file" "${user_home}/.ssh/authorized_keys"; then
    if [ -s "${user_home}/.ssh/authorized_keys" ] \
      && [ "$(tail -c 1 "${user_home}/.ssh/authorized_keys" | od -An -tx1 | tr -d ' ')" != "0a" ]; then
      printf '\n' >>"${user_home}/.ssh/authorized_keys"
    fi
    cat "$normal_user_public_key_file" >>"${user_home}/.ssh/authorized_keys"
    printf '\n' >>"${user_home}/.ssh/authorized_keys"
  fi
  chown "$normal_user:$normal_group" "${user_home}/.ssh/authorized_keys"
  chmod 0600 "${user_home}/.ssh/authorized_keys"
}

collect_allowed_ports() {
  sshd_bin="$1"
  {
    printf '%s\n' 80 443 8080 8443 8888
    printf '%s\n' "$current_port" "$final_port"
    "$sshd_bin" -T 2>/dev/null | awk '/^port[[:space:]]+/ {print $2}' || true
  } | awk '
    /^[0-9]+$/ && $1 >= 1 && $1 <= 65535 && !seen[$1]++ { print $1 }
  '
}

allow_ufw_ports() {
  ports="$1"
  command -v ufw >/dev/null 2>&1 || return 1
  log "[remote 7/7] 写入 ufw 放行规则"
  for port in $ports; do
    ufw allow "${port}/tcp" >/dev/null || true
  done
  return 0
}

allow_firewalld_ports() {
  ports="$1"
  command -v firewall-cmd >/dev/null 2>&1 || return 1
  firewall-cmd --state >/dev/null 2>&1 || return 1
  log "[remote 7/7] 写入 firewalld 放行规则"
  for port in $ports; do
    firewall-cmd --add-port="${port}/tcp" >/dev/null || true
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null || true
  done
  firewall-cmd --reload >/dev/null || true
  return 0
}

allow_nftables_ports() {
  ports="$1"
  command -v nft >/dev/null 2>&1 || return 1
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl is-active --quiet nftables 2>/dev/null || return 1

  input_chains="$(nft -a list ruleset | awk '
    /^table[[:space:]]+/ {
      family = $2
      table = $3
      next
    }
    /^[[:space:]]*chain[[:space:]]+/ {
      chain = $2
      in_chain = 1
      next
    }
    in_chain && /hook[[:space:]]+input/ {
      print family, table, chain
    }
    in_chain && /^[[:space:]]*}/ {
      in_chain = 0
    }
  ')"
  [ -n "$input_chains" ] || return 0

  log "[remote 7/7] 写入 nftables 实际 input base chain 放行规则"
  printf '%s\n' "$input_chains" | while read -r family table chain; do
    [ -n "$family" ] && [ -n "$table" ] && [ -n "$chain" ] || continue
    for port in $ports; do
      if ! nft list chain "$family" "$table" "$chain" 2>/dev/null \
        | grep -Eq "tcp dport ${port} accept.*setup_debian_ssh_key_only"; then
        nft insert rule "$family" "$table" "$chain" tcp dport "$port" accept comment "setup_debian_ssh_key_only"
      fi
    done
  done
  return 0
}

configure_firewall_ports() {
  sshd_bin="$1"
  ports="$(collect_allowed_ports "$sshd_bin")"
  [ -n "$ports" ] || return 0

  log "[remote 7/7] 放行 TCP 端口: $(printf '%s' "$ports" | tr '\n' ' ')"
  allow_ufw_ports "$ports" || true
  allow_firewalld_ports "$ports" || true
  allow_nftables_ports "$ports" || true
}

# SSH 加固放在最后执行：只有包安装、普通用户、公钥、防火墙都完成后，才关闭密码登录。
mkdir -p "$config_dir"
install_base_packages
configure_xanmod_bbrv3_and_tcp
configure_timezone_and_time_sync
configure_sudo_user
install_uv_for_normal_user
install_normal_user_authorized_key

if [ -f "$config_file" ]; then
  cp "$config_file" "${config_file}.bak.$(date +%Y%m%d%H%M%S)"
fi

# 使用 sshd_config.d 独立片段管理本脚本配置，便于审计和回滚。
{
  echo "PubkeyAuthentication yes"
  echo "PasswordAuthentication no"
  echo "KbdInteractiveAuthentication no"
  echo "ChallengeResponseAuthentication no"
  echo "PermitRootLogin prohibit-password"
  if [ "$keep_current_port" = "yes" ] && [ "$current_port" != "$final_port" ]; then
    echo "Port $current_port"
    echo "Port $final_port"
  elif [ "$current_port" != "$final_port" ]; then
    echo "Port $final_port"
  fi
} > "$config_file"

if [ "$current_port" != "$final_port" ] && command -v ufw >/dev/null 2>&1; then
  if ufw status 2>/dev/null | grep -qi "Status: active"; then
    ufw allow "${final_port}/tcp" >/dev/null || true
  fi
fi

if [ -x /usr/sbin/sshd ]; then
  sshd_bin="/usr/sbin/sshd"
else
  sshd_bin="$(command -v sshd)"
fi

"$sshd_bin" -t
configure_firewall_ports "$sshd_bin"
systemctl reload ssh 2>/dev/null || systemctl reload sshd

"$sshd_bin" -T | grep -E '^(pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication|permitrootlogin|port) '
REMOTE

  scp_with_password_if_possible "$current_port" "$local_script" "${target}:${remote_script}"
  scp_with_password_if_possible "$current_port" "$local_password_file" "${target}:${remote_password_file}"
  scp_with_password_if_possible "$current_port" "$public_key" "${target}:${remote_public_key_file}"
  rm -f "$local_script"
  rm -f "$local_password_file"

  if [[ -n "${SERVER_PASSWORD:-}" && $(command -v sshpass || true) ]]; then
    printf '%s\n' "$SERVER_PASSWORD" | SSHPASS="$SERVER_PASSWORD" sshpass -e ssh \
      -p "$current_port" \
      -o StrictHostKeyChecking=accept-new \
      "$target" \
      "sudo -S sh '$remote_script' '$current_port' '$final_port' '$keep_current_port' '$normal_user' '$remote_password_file' '$remote_public_key_file'; rc=\$?; rm -f '$remote_script' '$remote_password_file' '$remote_public_key_file'; exit \$rc"
  else
    ssh \
      -tt \
      -p "$current_port" \
      -o StrictHostKeyChecking=accept-new \
      "$target" \
      "sudo sh '$remote_script' '$current_port' '$final_port' '$keep_current_port' '$normal_user' '$remote_password_file' '$remote_public_key_file'; rc=\$?; rm -f '$remote_script' '$remote_password_file' '$remote_public_key_file'; exit \$rc"
  fi
}

verify_key_login() {
  local target="$1"
  local port="$2"

  ssh \
    -o StrictHostKeyChecking=accept-new \
    "${SSH_PUBLIC_KEY_ONLY_OPTS[@]}" \
    -i "$PRIVATE_KEY" \
    -p "$port" \
    "$target" \
    'echo "密钥登录验证成功"'
}

verify_final_host_login() {
  ssh "${SSH_PUBLIC_KEY_ONLY_OPTS[@]}" "$HOST_ALIAS" 'echo "最终 Host 配置验证成功"'
}

print_intro() {
  echo "Debian 服务器初始化与 SSH 密钥登录配置脚本"
  echo
  echo "将执行以下操作："
  echo "  1. 使用初始 SSH 用户连接服务器，默认 root。"
  echo "  2. 安装基础包、XanMod BBRv3/TCP 优化、uv 和 Python 3.12。"
  echo "  3. 创建或更新普通用户，并把同一把 SSH 公钥写入该用户。"
  echo "  4. 禁用 SSH 密码登录，最终本地 ssh_config 使用普通用户登录。"
  echo
  echo "敏感信息说明：服务器当前密码和普通用户 sudo 密码只在本次执行中使用。"
  if ! command -v sshpass >/dev/null 2>&1; then
    echo "提示：未检测到 sshpass，首次登录和 sudo 可能需要按 ssh 提示手动输入密码。"
  fi
  echo
}

collect_inputs() {
  print_step "输入" "服务器与用户信息"

  SERVER_HOST="$(prompt "服务器 IP/域名")"
  validate_server_host "$SERVER_HOST"

  SERVER_USER="$(prompt "初始 SSH 登录用户" "root")"
  validate_server_user "$SERVER_USER"

  SERVER_PASSWORD="$(prompt_secret "初始 SSH 登录用户当前密码，回车则使用交互式输入")"

  NORMAL_USER="$(prompt "最终 SSH 登录的普通用户名")"
  validate_linux_user "$NORMAL_USER"
  NORMAL_USER_PASSWORD="$(prompt_confirmed_secret "普通用户 ${NORMAL_USER} 的 sudo 密码")"

  local default_alias
  default_alias="$(sanitize_alias "${NORMAL_USER}-${SERVER_HOST}")"
  HOST_ALIAS="$(prompt "本地 ssh_config Host 别名" "$default_alias")"
  validate_host_alias "$HOST_ALIAS"
  if host_alias_exists_outside_managed_block "$HOST_ALIAS"; then
    die "本地 $SSH_CONFIG 已存在非本脚本管理的 Host $HOST_ALIAS，请换一个名称或手动处理旧配置"
  fi

  CURRENT_PORT="$(prompt "服务器当前 SSH 端口" "22")"
  validate_port "$CURRENT_PORT"

  local change_port_answer
  change_port_answer="$(prompt "是否同时修改 SSH 端口？仅输入 yes 才修改" "no")"
  CHANGE_PORT="no"
  FINAL_PORT="$CURRENT_PORT"
  if [[ "$change_port_answer" == "yes" ]]; then
    FINAL_PORT="$(prompt "新的 SSH 端口" "2222")"
    validate_port "$FINAL_PORT"
    CHANGE_PORT="yes"
  fi
}

configure_remote_stage() {
  local target="$1"

  if [[ "$CHANGE_PORT" == "yes" ]]; then
    echo "端口迁移：先同时监听旧端口 $CURRENT_PORT 和新端口 $FINAL_PORT，验证成功后再询问是否移除旧端口。"
    run_remote_initialization "$target" "$CURRENT_PORT" "$FINAL_PORT" "yes" "$NORMAL_USER" "$NORMAL_USER_PASSWORD" "$PUBLIC_KEY"
    echo "验证新端口 $FINAL_PORT 可用"
    ssh \
      -o StrictHostKeyChecking=accept-new \
      "${SSH_PUBLIC_KEY_ONLY_OPTS[@]}" \
      -i "$PRIVATE_KEY" \
      -p "$FINAL_PORT" \
      "$target" \
      'echo "新端口验证成功"'
  else
    run_remote_initialization "$target" "$CURRENT_PORT" "$FINAL_PORT" "no" "$NORMAL_USER" "$NORMAL_USER_PASSWORD" "$PUBLIC_KEY"
  fi
}

maybe_remove_old_ssh_port() {
  local target="$1"

  [[ "$CHANGE_PORT" == "yes" && "$CURRENT_PORT" != "$FINAL_PORT" ]] || return 0

  echo
  local remove_old_port
  remove_old_port="$(prompt "是否移除服务器旧 SSH 端口 $CURRENT_PORT 的监听? 输入 yes 才移除" "no")"
  if [[ "$remove_old_port" == "yes" ]]; then
    echo "移除旧端口前再次确认新端口可登录。"
    verify_final_host_login
    run_remote_initialization "$target" "$FINAL_PORT" "$FINAL_PORT" "no" "$NORMAL_USER" "$NORMAL_USER_PASSWORD" "$PUBLIC_KEY"
    verify_final_host_login
  else
    echo "已保留旧端口 $CURRENT_PORT 监听；确认新端口长期稳定后，可再次运行脚本或手动移除。"
  fi
}

# ================= 主流程 =================

main() {
  require_cmd ssh
  require_cmd scp
  require_cmd ssh-keygen

  print_intro
  collect_inputs
  select_or_create_key

  local target="${SERVER_USER}@${SERVER_HOST}"

  print_step "1/5" "写入公钥到初始登录用户"
  copy_public_key "$PUBLIC_KEY" "$target" "$CURRENT_PORT"

  print_step "2/5" "验证初始用户密钥登录"
  verify_key_login "$target" "$CURRENT_PORT"

  print_step "3/5" "执行远端初始化并加固 SSH"
  if ! configure_remote_stage "$target"; then
    echo "第 3 步 SSH 连接中断或远端命令返回失败，尝试验证最终普通用户登录是否已经可用..."
    verify_key_login "${NORMAL_USER}@${SERVER_HOST}" "$FINAL_PORT" \
      || die "远端初始化未确认完成；请检查上方远端日志，或通过 VPS 控制台确认 SSH、公钥和防火墙状态后重试"
    echo "最终普通用户密钥登录已可用，继续写入本地 ssh_config。"
  fi

  print_step "4/5" "写入本地 ssh_config"
  echo "目标：ssh ${HOST_ALIAS} 将以普通用户 ${NORMAL_USER} 登录。"
  write_ssh_config "$HOST_ALIAS" "$SERVER_HOST" "$NORMAL_USER" "$FINAL_PORT" "$PRIVATE_KEY"

  print_step "5/5" "验证最终 SSH Host 配置"
  verify_final_host_login
  maybe_remove_old_ssh_port "$target"

  echo
  echo "完成。以后可直接登录："
  echo "  ssh $HOST_ALIAS"
  echo
  echo "本地配置位置："
  echo "  $SSH_CONFIG"
  echo
  echo "注意：请保留当前会话，另开终端确认 ssh $HOST_ALIAS 可登录后再关闭。"
}

main "$@"
