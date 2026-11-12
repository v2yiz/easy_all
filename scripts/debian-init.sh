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
LOCAL_TEMP_FILES=()
# 与 bootstrap.sh / easy_all 一致：允许用 EASY_ALL_BRANCH 指定拉取分支（开发分支测试用），
# 也可用 EASY_ALL_PLATFORM_MODULE_URL / EASY_ALL_FIREWALL_MODULE_URL 指定镜像或完整 URL。
readonly EASY_ALL_BRANCH="${EASY_ALL_BRANCH:-main}"
if [[ ! "${EASY_ALL_BRANCH}" =~ ^[A-Za-z0-9._/-]+$ ]]; then
  printf '错误: EASY_ALL_BRANCH 含非法字符: %s\n' "${EASY_ALL_BRANCH}" >&2
  exit 1
fi
readonly DEFAULT_PLATFORM_MODULE_URL="${EASY_ALL_PLATFORM_MODULE_URL:-https://raw.githubusercontent.com/v2yiz/easy_all/${EASY_ALL_BRANCH}/lib/platform.sh}"
readonly DEFAULT_FIREWALL_MODULE_URL="${EASY_ALL_FIREWALL_MODULE_URL:-https://raw.githubusercontent.com/v2yiz/easy_all/${EASY_ALL_BRANCH}/lib/firewall.sh}"
PLATFORM_MODULE_FILE=""
FIREWALL_MODULE_FILE=""

cleanup_local_temp_files() {
  local file
  for file in "${LOCAL_TEMP_FILES[@]:-}"; do
    [[ -n "$file" ]] && rm -f -- "$file"
  done
  return 0
}
trap cleanup_local_temp_files EXIT INT TERM

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

strip_terminal_input() {
  local esc=$'\033'
  # 终止符包含 '~'：括号粘贴标记 ESC[200~ / ESC[201~ 不带字母。
  printf '%s' "$1" | sed -e "s/${esc}\[[0-9;?]*[~A-Za-z]//g" -e "s/${esc}O[A-Za-z]//g" \
    | tr -d '\000-\010\013-\037\177'
}

read_bilingual() {
  local label="$1"
  local variable="$2"
  local silent="${3:-0}"
  local input
  printf '%s\n' "$label" >&2
  if [[ "$silent" == "1" ]]; then
    # 一次性读整行：回显由 -s 关闭，行编辑与 ^C 交给行规程；-t 是挂死兜底。
    IFS= read -r -s -t 300 -p '> ' input || die "没有读到输入（300 秒超时或输入已关闭）"
    echo >&2
  else
    IFS= read -r -e -p '> ' input
  fi
  printf -v "$variable" '%s' "$(strip_terminal_input "$input")"
}

prompt() {
  local label="$1"
  local default="${2:-}"
  local value
  if [[ -n "$default" ]]; then
    read_bilingual "${label} [${default}]（直接回车使用默认值）:" value
    printf '%s' "${value:-$default}"
  else
    read_bilingual "${label}:" value
    [[ -n "$value" ]] || die "${label} 不能为空"
    printf '%s' "$value"
  fi
}

# 静默读进目标变量：在调用方当前 shell 里直接读，不包进 $( )：
# 子 shell 里的终端读会不等输入就返回空（easy_all 的 Token/AWS 提示同理）。
read_secret_into() {
  local variable="$1"
  local label="$2"
  read_bilingual "${label}:" "$variable" 1
}

prompt_required_secret_into() {
  local variable="$1"
  local label="$2"
  read_secret_into "$variable" "$label"
  [[ -n "${!variable}" ]] || die "${label} 不能为空"
}

prompt_confirmed_secret_into() {
  local variable="$1"
  local label="$2"
  local confirm
  read_secret_into "$variable" "$label"
  [[ -n "${!variable}" ]] || die "${label} 不能为空"
  read_secret_into confirm "再次输入${label}"
  [[ "${!variable}" == "$confirm" ]] || die "两次输入的${label}不一致"
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
  local port="$1" zeros value
  [[ "$port" =~ ^[0-9]+$ ]] || die "端口必须是数字: $port"
  # 剥掉前导零后再按十进制比较：`080` 是 80，不是八进制报错（必须用 10#）。
  zeros="${port%%[!0]*}"
  value="${port#"${zeros}"}"
  [[ -n "$value" && ${#value} -le 5 ]] || die "端口范围必须是 1-65535: $port"
  (( 10#${value} <= 65535 )) || die "端口范围必须是 1-65535: $port"
}

# 端口在后续 ssh -p / sshd / UFW 实参里必须是规范十进制，否则 `080` 会被当成八进制。
normalize_port() {
  local port="$1"
  validate_port "$port"
  printf '%s' "$((10#${port}))"
}

normalize_port_list() {
  local raw="${1//,/ }"
  local port normalized=""
  for port in $raw; do
    # 子命令替换不继承 errexit：不显式传播校验失败会吞掉非法端口。
    port="$(normalize_port "$port")" || return 1
    case " ${normalized} " in
      *" ${port} "*) ;;
      *) normalized="${normalized:+${normalized} }${port}" ;;
    esac
  done
  printf '%s' "$normalized"
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

validate_collected_inputs() {
  [[ -n "${SERVER_HOST:-}" ]] || die "内部错误：服务器地址未设置"
  [[ -n "${SERVER_USER:-}" ]] || die "内部错误：初始 SSH 登录用户未设置"
  [[ -n "${NORMAL_USER:-}" ]] || die "内部错误：最终 SSH 登录用户未设置"
  [[ -n "${HOST_ALIAS:-}" ]] || die "内部错误：SSH Host 别名未设置"
  [[ -n "${CURRENT_PORT:-}" ]] || die "内部错误：服务器当前 SSH 端口未设置"
  [[ -n "${FINAL_PORT:-}" ]] || die "内部错误：服务器最终 SSH 端口未设置"
  [[ "${CHANGE_PORT:-}" == "yes" || "${CHANGE_PORT:-}" == "no" ]] \
    || die "内部错误：SSH 端口修改状态无效"

  validate_port "$CURRENT_PORT"
  validate_port "$FINAL_PORT"
  CURRENT_PORT="$(normalize_port "$CURRENT_PORT")"
  FINAL_PORT="$(normalize_port "$FINAL_PORT")"
  EXTRA_TCP_PORTS="$(normalize_port_list "${EXTRA_TCP_PORTS:-}")" \
    || die "额外 TCP 端口列表无效：${EXTRA_TCP_PORTS:-}"
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

load_platform_module() {
  local script_dir candidate downloaded firewall_candidate firewall_downloaded
  [[ -z "${PLATFORM_MODULE_FILE}" || -z "${FIREWALL_MODULE_FILE}" ]] || return 0

  if [[ -n "${EASY_ALL_PLATFORM_MODULE_SOURCE:-}" ]]; then
    candidate="${EASY_ALL_PLATFORM_MODULE_SOURCE}"
  else
    script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
    candidate="${script_dir}/../lib/platform.sh"
  fi
  if [[ -r "${candidate}" ]]; then
    PLATFORM_MODULE_FILE="${candidate}"
  else
    downloaded="$(mktemp)"
    LOCAL_TEMP_FILES+=("${downloaded}")
    curl -fsSL --retry 3 --connect-timeout 10 --max-time 60 \
        "${DEFAULT_PLATFORM_MODULE_URL}" -o "${downloaded}" \
      || die "下载公共平台模块失败：${DEFAULT_PLATFORM_MODULE_URL}"
    PLATFORM_MODULE_FILE="${downloaded}"
  fi
  bash -n "${PLATFORM_MODULE_FILE}" || die "公共平台模块语法校验失败"
  # shellcheck source=lib/platform.sh
  source "${PLATFORM_MODULE_FILE}"
  declare -F ensure_ssh_boot_service >/dev/null \
    && declare -F ensure_ssh_fail2ban >/dev/null \
    || die "公共平台模块缺少 SSH 服务或 Fail2ban 实现"

  if [[ -n "${EASY_ALL_FIREWALL_MODULE_SOURCE:-}" ]]; then
    firewall_candidate="${EASY_ALL_FIREWALL_MODULE_SOURCE}"
  elif [[ -n "${EASY_ALL_PLATFORM_MODULE_SOURCE:-}" ]]; then
    firewall_candidate="$(dirname -- "${EASY_ALL_PLATFORM_MODULE_SOURCE}")/firewall.sh"
  else
    firewall_candidate="${script_dir}/../lib/firewall.sh"
  fi
  if [[ -r "${firewall_candidate}" ]]; then
    FIREWALL_MODULE_FILE="${firewall_candidate}"
  else
    firewall_downloaded="$(mktemp)"
    LOCAL_TEMP_FILES+=("${firewall_downloaded}")
    curl -fsSL --retry 3 --connect-timeout 10 --max-time 60 \
        "${DEFAULT_FIREWALL_MODULE_URL}" -o "${firewall_downloaded}" \
      || die "下载公共防火墙模块失败：${DEFAULT_FIREWALL_MODULE_URL}"
    FIREWALL_MODULE_FILE="${firewall_downloaded}"
  fi
  bash -n "${FIREWALL_MODULE_FILE}" || die "公共防火墙模块语法校验失败"
  # shellcheck source=lib/firewall.sh
  source "${FIREWALL_MODULE_FILE}"
  declare -F apply_managed_ufw_tcp_ports >/dev/null \
    || die "公共防火墙模块缺少受管 UFW 实现"
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
      SSHPASS="$SERVER_PASSWORD" sshpass -e ssh-copy-id \
        -o StrictHostKeyChecking=accept-new \
        -i "$public_key" -p "$port" "$target"
    else
      ssh-copy-id -o StrictHostKeyChecking=accept-new -i "$public_key" -p "$port" "$target"
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
  for file in "${pub_keys[@]:-}"; do
    echo "  ${i}) $file"
    i=$((i + 1))
  done
  echo "  g) 生成新的 ed25519 key"
  echo "  m) 手动输入密钥路径"

  local choice
  read_bilingual '请选择 [g]（直接回车使用默认值）:' choice
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

    echo "新密钥的 passphrase 由 ssh-keygen 直接交互设置；如需完全免交互，在提示处直接回车使用空 passphrase。"
    ssh-keygen -t ed25519 -f "$PRIVATE_KEY" -C "${HOST_ALIAS}@${SERVER_HOST}"
    return
  fi

  if [[ "$choice" == "m" ]]; then
    local input_path
    input_path="$(prompt "私钥路径或公钥路径" "")"
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
  local quoted_identity_file

  # CR/LF 无法写成单行 SSH 配置，也不能留在管理区块里：必须在改写配置前拒绝。
  case "${identity_file}" in
    *$'\r'* | *$'\n'*)
      die "私钥路径包含换行符（CR/LF），无法写入 SSH 配置；请改用单行路径"
      ;;
  esac
  # OpenSSH 配置参数用双引号包裹，反斜杠与双引号必须按其规则转义（先反斜杠、后引号，
  # 避免自己加的转义符再被转义）。shell 的 %q 产生的是 shell 语法，不是 SSH 配置语法。
  quoted_identity_file=${identity_file//\\/\\\\}
  quoted_identity_file="\"${quoted_identity_file//\"/\\\"}\""

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
    # 路径含空格/引号/反斜杠：用 printf 输出参数，避免 echo 把 -n/-e 或反斜杠当选项与转义。
    printf '  IdentityFile %s\n' "${quoted_identity_file}"
    echo "  IdentitiesOnly yes"
    echo "  ConnectTimeout 10"
    echo "  ConnectionAttempts 3"
    echo "  ServerAliveInterval 30"
    echo "  ServerAliveCountMax 3"
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
  local normal_user="$4"
  local normal_user_password="$5"
  local public_key="$6"
  local extra_tcp_ports="$7"
  local remote_dir remote_script remote_password_file remote_public_key_file
  local remote_platform_module remote_firewall_module
  local local_script local_password_file remote_privilege
  # 初始登录用户是 root 时不能加 sudo 前缀：sudo 要到远端 install_base_packages 才安装，
  # 精简镜像直接 `sudo: command not found`（127）。非 root 保留原有 sudo 提权路径。
  remote_privilege=""
  if [[ "${target%%@*}" != "root" ]]; then
    remote_privilege="sudo "
    if [[ -n "${SERVER_PASSWORD:-}" ]] && command -v sshpass >/dev/null 2>&1; then
      remote_privilege="sudo -S "
    fi
  fi
  local_script="$(mktemp)"
  local_password_file="$(mktemp)"
  LOCAL_TEMP_FILES+=("$local_script" "$local_password_file")
  # 普通用户 sudo 密码只走临时文件：不写入脚本正文，也不落入 ssh 命令参数。
  printf '%s' "$normal_user_password" >"$local_password_file"

  cat > "$local_script" <<'REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail

current_port="$1"
final_port="$2"
normal_user="$3"
normal_user_password_file="$4"
normal_user_public_key_file="$5"
extra_tcp_ports="$6"
platform_module="$7"
firewall_module="$8"

config_dir="/etc/ssh/sshd_config.d"
config_file="${config_dir}/00-debian-init-hardening.conf"
sysctl_config="/etc/sysctl.d/99-debian-init-tcp.conf"

cleanup_sensitive_files() {
  rm -f "$normal_user_password_file" "$normal_user_public_key_file" \
    "$platform_module" "$firewall_module"
}
trap cleanup_sensitive_files EXIT INT TERM

log() {
  printf '%s\n' "$*"
}

die() {
  printf '%s\n' "错误: $*" >&2
  exit 1
}

# 被 source 的 lib/platform.sh 与 lib/firewall.sh 都会调用 warn：远端脚本必须自带实现，
# 否则 set -e 下 warn: command not found 会中断整个远端初始化。
warn() {
  printf '%s\n' "警告: $*" >&2
}

info() {
  log "$*"
}

# shellcheck source=lib/platform.sh
source "$platform_module"
UFW_RULE_COMMENT="debian-init-managed"
UFW_DEFAULT_CONFIG="/etc/default/ufw"
# shellcheck source=lib/firewall.sh
source "$firewall_module"
# 与 easy_all 共用同一份平台校验：发行版/代号/架构/容器限制只在这里定义。
check_platform
[[ "$final_port" =~ ^[0-9]+$ ]] && ((10#$final_port >= 1 && 10#$final_port <= 65535)) \
  || die "远端最终 SSH 端口无效: $final_port"

if [[ -n "$extra_tcp_ports" ]]; then
  extra_tcp_ports=$(normalize_ufw_tcp_ports "$extra_tcp_ports") || die "额外 TCP 端口列表无效"
fi

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
  apt-get -o DPkg::Lock::Timeout=300 update
  apt-get -o DPkg::Lock::Timeout=300 -y upgrade

  log "[remote 2/7] 安装基础包"
  apt-get -o DPkg::Lock::Timeout=300 install -y \
    vim tmux curl wget ca-certificates sudo git build-essential \
    openssh-server ufw fail2ban python3-systemd systemd-timesyncd kmod procps
}

configure_tcp_tuning() {
  log "[remote 3/7] 配置 TCP 调优参数"
  if [ -f "$sysctl_config" ] && [ ! -f "${sysctl_config}.debian_init.bak" ]; then
    cp -a "$sysctl_config" "${sysctl_config}.debian_init.bak"
  fi

  cat >"$sysctl_config" <<'SYSCTL'
# TCP tuning only; easy_all attaches skyline_cc when it is installed.
net.core.default_qdisc = fq

# TCP buffer
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432
net.ipv4.tcp_moderate_rcvbuf = 1

# PMTU
net.ipv4.tcp_mtu_probing = 1

# Idle connection
net.ipv4.tcp_slow_start_after_idle = 0

# Defaults for applications that enable SO_KEEPALIVE
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# Outbound TCP/UDP source ports; leave common service and high SSH ports free
net.ipv4.ip_local_port_range = 13000 60999
SYSCTL

  # GRUB 开了 ipv6.disable=1 的内核没有 /proc/sys/net/ipv6：写入这些键会让下面的 sysctl -p
  # 直接失败，在 set -e 下终止远端初始化（半安装现场）。
  if [ -d "${EASY_ALL_PROC_IPV6_DIR:-/proc/sys/net/ipv6}" ]; then
    cat >>"$sysctl_config" <<'SYSCTL'

# Disable IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
SYSCTL
  fi

  cat >>"$sysctl_config" <<'SYSCTL'

# HTTP/2 & gRPC anti-bufferbloat: limit unsent bytes in write queue
net.ipv4.tcp_notsent_lowat = 32768

# Fast dead connection failure (Skyline recommended tuning)
net.ipv4.tcp_retries2 = 8

# High-concurrency socket recycling & queue optimization
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
SYSCTL

  sysctl -p "$sysctl_config" >/dev/null

  log "[remote 3/7] TCP 调优参数配置完成"
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

  local uv_version=0.13.7 uv_installer uv_version_output
  log "[remote 6/7] 为普通用户 ${normal_user} 安装 uv ${uv_version} 与 Python 3.12"
  # 供应链：只接受 astral.sh 的版本化安装脚本，并把 curl 的协议与重定向都限制在 HTTPS。
  # 剩余信任边界是 astral.sh 站点本身与其 TLS 证书：官方没有可离线验证的固定校验和清单，
  # 因此这里不比对摘要，靠版本化 URL + 仅 HTTPS 传输 + 安装后版本断言收敛风险。
  uv_installer=$(mktemp "${TMPDIR:-/tmp}/uv-install.XXXXXX") \
    || die "无法创建 uv 安装脚本临时文件"
  # mktemp 默认 0600；显式再设一次，不依赖实现细节。文件归普通用户，由该用户执行。
  chmod 0600 "$uv_installer"
  chown "$normal_user" "$uv_installer"
  if ! su - "$normal_user" -c \
    "curl --proto '=https' --proto-redir '=https' -fLsS 'https://astral.sh/uv/${uv_version}/install.sh' -o '$uv_installer'"; then
    rm -f -- "$uv_installer"
    die "下载 uv ${uv_version} 安装脚本失败"
  fi
  if [ ! -s "$uv_installer" ]; then
    rm -f -- "$uv_installer"
    die "下载的 uv ${uv_version} 安装脚本为空"
  fi
  if ! su - "$normal_user" -c "sh '$uv_installer'"; then
    rm -f -- "$uv_installer"
    die "安装 uv ${uv_version} 失败"
  fi
  rm -f -- "$uv_installer"
  uv_version_output=$(su - "$normal_user" -c '"${HOME}/.local/bin/uv" --version' 2>/dev/null || true)
  [[ "${uv_version_output}" == "uv ${uv_version}"* ]] \
    || die "uv 版本校验失败：期望以 uv ${uv_version} 开头，实际为 ${uv_version_output:-无输出}"
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
  {
    printf '%s\n' "$final_port"
    [ -z "$extra_tcp_ports" ] || printf '%s\n' $extra_tcp_ports
  } | awk '
    /^[0-9]+$/ && $1 >= 1 && $1 <= 65535 && !seen[$1]++ { print $1 }
  '
}

# 加固片段写盘不等于运行中的 sshd 已生效：先断言有效配置，再显式 reload。
# reload 不断开现有会话；restart 会断开，因此 reload 失败必须终止而不是回退重启。
apply_ssh_hardening_runtime() {
  local effective unit reload_output expected

  effective="$("$sshd_bin" -T)" || die "sshd 有效配置读取失败；加固配置无法确认生效"
  for expected in \
    "passwordauthentication no" \
    "kbdinteractiveauthentication no" \
    "addressfamily inet" \
    "pubkeyauthentication yes"; do
    grep -qxF -- "$expected" <<<"$effective" \
      || die "sshd 有效配置缺少 '$expected'；检查 /etc/ssh/sshd_config 与 ${config_dir}/ 下其他片段是否覆盖 ${config_file##*/}"
  done

  for unit in ssh.service sshd.service; do
    systemctl cat "$unit" >/dev/null 2>&1 || continue
    systemctl is-active --quiet "$unit" \
      || die "SSH 服务未运行，无法重载加固配置：${unit}"
    if ! reload_output=$(systemctl reload "$unit" 2>&1); then
      printf '%s\n' "$reload_output" >&2
      die "重载 SSH 服务失败，加固配置未应用到运行中的 sshd：${unit}"
    fi
    log "SSH 加固配置已重载到运行中的服务：${unit}"
    return 0
  done
  die "未找到 ssh.service 或 sshd.service；无法重载 SSH 加固配置"
}

configure_ufw() {
  ports="$(collect_allowed_ports)"
  [ -n "$ports" ] || return 0

  command -v ufw >/dev/null 2>&1 || {
    printf '%s\n' "错误: UFW 安装后不可用" >&2
    exit 1
  }
  log "[remote 7/7] 配置 UFW，放行 TCP 端口: $(printf '%s' "$ports" | tr '\n' ' ')"
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw default deny routed >/dev/null
  # 真实 SSH 端口也必须被校验：一参数形式会回落到 SSH_PORTS（此处未检测，默认 22），
  # 非 22 端口的主机会在校验 22 时 die。
  apply_ssh_ufw_policy "$ports" "$final_port"
  systemctl enable ufw >/dev/null 2>&1
  LC_ALL=C ufw status | awk '/^Status: active$/ {found=1} END {exit !found}' || {
    printf '%s\n' "错误: UFW 未处于 active 状态" >&2
    exit 1
  }
}

# SSH 配置放在最后执行：只有包安装、普通用户、公钥和防火墙准备完成后才重载服务。
mkdir -p "$config_dir"
install_base_packages
if [ -x /usr/sbin/sshd ]; then
  sshd_bin="/usr/sbin/sshd"
else
  sshd_bin="$(command -v sshd)"
fi
configure_tcp_tuning
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
  echo "LoginGraceTime 30"
  echo "MaxAuthTries 6"
  echo "MaxStartups 20:30:100"
  echo "PerSourceMaxStartups 3"
  echo "PerSourceNetBlockSize 32:64"
  echo "AddressFamily inet"
} > "$config_file"
log "已关闭 IPv6 SSH（产品仅支持 IPv4）：AddressFamily inet"

"$sshd_bin" -t
ensure_ssh_boot_service
configure_ufw
ensure_ssh_fail2ban
apply_ssh_hardening_runtime

"$sshd_bin" -T | grep -E '^(pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication|permitrootlogin|logingracetime|maxauthtries|maxstartups|persourcemaxstartups|persourcenetblocksize|port|listenaddress) ' || true
REMOTE

  # 远端临时目录由远端 mktemp 创建，避免固定 /tmp 路径被抢占或残留。
  if ! remote_dir=$(ssh_with_password_if_possible "$current_port" "$target" \
    'mktemp -d -p /tmp easy_all_init.XXXXXXXX'); then
    printf '%s\n' "错误: 无法在远端创建临时目录" >&2
    return 1
  fi
  # 远端镜像可能把 MOTD/rc 输出混进命令 stdout：只取最后一行并裁掉 CR，再做严格校验。
  remote_dir=${remote_dir##*$'\n'}
  remote_dir=${remote_dir%$'\r'}
  if [[ ! "$remote_dir" =~ ^/tmp/easy_all_init\.[A-Za-z0-9]+$ ]]; then
    printf '%s\n' "错误: 远端返回的临时目录无效: $remote_dir" >&2
    return 1
  fi
  remote_script="${remote_dir}/setup_debian_ssh_key_only.sh"
  remote_password_file="${remote_dir}/normal_user_password.txt"
  remote_public_key_file="${remote_dir}/normal_user_authorized_key.pub"
  remote_platform_module="${remote_dir}/platform.sh"
  remote_firewall_module="${remote_dir}/firewall.sh"

  if ! scp_with_password_if_possible "$current_port" "$local_script" "${target}:${remote_script}"; then
    ssh_with_password_if_possible "$current_port" "$target" \
      "rm -rf '$remote_dir'" >/dev/null 2>&1 || true
    return 1
  fi
  if ! scp_with_password_if_possible "$current_port" "$PLATFORM_MODULE_FILE" "${target}:${remote_platform_module}"; then
    ssh_with_password_if_possible "$current_port" "$target" \
      "rm -rf '$remote_dir'" >/dev/null 2>&1 || true
    return 1
  fi
  if ! scp_with_password_if_possible "$current_port" "$FIREWALL_MODULE_FILE" "${target}:${remote_firewall_module}"; then
    ssh_with_password_if_possible "$current_port" "$target" \
      "rm -rf '$remote_dir'" >/dev/null 2>&1 || true
    return 1
  fi
  if ! scp_with_password_if_possible "$current_port" "$local_password_file" "${target}:${remote_password_file}"; then
    ssh_with_password_if_possible "$current_port" "$target" \
      "rm -rf '$remote_dir'" >/dev/null 2>&1 || true
    return 1
  fi
  if ! scp_with_password_if_possible "$current_port" "$public_key" "${target}:${remote_public_key_file}"; then
    ssh_with_password_if_possible "$current_port" "$target" \
      "rm -rf '$remote_dir'" >/dev/null 2>&1 || true
    return 1
  fi
  rm -f "$local_script"
  rm -f "$local_password_file"

  if [[ -n "${SERVER_PASSWORD:-}" && $(command -v sshpass || true) ]]; then
    printf '%s\n' "$SERVER_PASSWORD" | SSHPASS="$SERVER_PASSWORD" sshpass -e ssh \
      -p "$current_port" \
      -o StrictHostKeyChecking=accept-new \
      "$target" \
      "${remote_privilege}bash '$remote_script' '$current_port' '$final_port' '$normal_user' '$remote_password_file' '$remote_public_key_file' '$extra_tcp_ports' '$remote_platform_module' '$remote_firewall_module'; rc=\$?; rm -rf '$remote_dir'; exit \$rc"
  else
    ssh \
      -tt \
      -p "$current_port" \
      -o StrictHostKeyChecking=accept-new \
      "$target" \
      "${remote_privilege}bash '$remote_script' '$current_port' '$final_port' '$normal_user' '$remote_password_file' '$remote_public_key_file' '$extra_tcp_ports' '$remote_platform_module' '$remote_firewall_module'; rc=\$?; rm -rf '$remote_dir'; exit \$rc"
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
  echo "服务器初始化与 SSH 密钥登录配置脚本"
  echo "适用：Debian 12/13、Ubuntu 22.04/24.04/26.04 LTS（amd64/arm64，systemd，非容器）"
  echo
  echo "将执行以下操作："
  echo "  1. 使用初始 SSH 用户连接服务器，默认 root。"
  echo "  2. 安装基础包、配置 TCP 调优参数、UFW、uv 和 Python 3.12。"
  echo "  3. 创建或更新普通用户，并把同一把 SSH 公钥写入该用户。"
  echo "  4. 验证密钥后关闭 SSH 密码登录，仅允许密钥认证，UFW 放行 SSH 端口。"
  echo
  echo "提示：请保留当前会话直到新连接验证成功。"
  echo "敏感信息说明：服务器当前密码和普通用户 sudo 密码只在本次执行中使用。"
  if ! command -v sshpass >/dev/null 2>&1; then
    echo "提示：未检测到 sshpass，首次登录和 sudo 可能需要按 ssh 提示手动输入密码。"
  fi
  echo
}

collect_inputs() {
  print_step "输入" "服务器与用户信息"

  SERVER_HOST="$(prompt "服务器 IP/域名" "")"
  validate_server_host "$SERVER_HOST"

  SERVER_USER="$(prompt "初始 SSH 登录用户" "root")"
  validate_server_user "$SERVER_USER"

  read_secret_into SERVER_PASSWORD "初始 SSH 登录用户当前密码，回车则使用交互式输入"

  NORMAL_USER="$(prompt "最终 SSH 登录的普通用户名" "")"
  validate_linux_user "$NORMAL_USER"
  prompt_confirmed_secret_into NORMAL_USER_PASSWORD "普通用户 ${NORMAL_USER} 的 sudo 密码"

  local default_alias
  default_alias="$(sanitize_alias "${NORMAL_USER}-${SERVER_HOST}")"
  HOST_ALIAS="$(prompt "本地 ssh_config Host 别名" "$default_alias")"
  validate_host_alias "$HOST_ALIAS"
  if host_alias_exists_outside_managed_block "$HOST_ALIAS"; then
    die "本地 $SSH_CONFIG 已存在非本脚本管理的 Host $HOST_ALIAS，请换一个名称或手动处理旧配置"
  fi

  CURRENT_PORT="$(prompt "服务器当前 SSH 端口" "22")"
  CURRENT_PORT="$(normalize_port "$CURRENT_PORT")"
  FINAL_PORT="$CURRENT_PORT"
  CHANGE_PORT="no"
  echo "SSH 端口将保持当前端口 ${CURRENT_PORT}。"

  local extra_tcp_ports_raw
  read_bilingual \
    'UFW 额外放行 TCP 端口（逗号或空格分隔，留空则仅放行 SSH）:' \
    extra_tcp_ports_raw || true
  EXTRA_TCP_PORTS="$(normalize_port_list "${extra_tcp_ports_raw:-}")" \
    || die "额外 TCP 端口列表无效：${extra_tcp_ports_raw:-}"
}

configure_remote_stage() {
  local target="$1"

  echo "SSH 将保持监听 ${FINAL_PORT}。"
  run_remote_initialization "$target" "$CURRENT_PORT" "$FINAL_PORT" \
    "$NORMAL_USER" "$NORMAL_USER_PASSWORD" "$PUBLIC_KEY" "$EXTRA_TCP_PORTS" \
    || return 1
  verify_key_login "${NORMAL_USER}@${SERVER_HOST}" "$FINAL_PORT"
}

# ================= 主流程 =================

main() {
  require_cmd ssh
  require_cmd scp
  require_cmd ssh-keygen
  require_cmd curl
  load_platform_module

  print_intro
  collect_inputs
  validate_collected_inputs
  select_or_create_key

  local target="${SERVER_USER}@${SERVER_HOST}"

  print_step "1/5" "写入公钥到初始登录用户"
  copy_public_key "$PUBLIC_KEY" "$target" "$CURRENT_PORT"

  print_step "2/5" "验证初始用户密钥登录"
  verify_key_login "$target" "$CURRENT_PORT"

  print_step "3/5" "执行远端初始化并加固 SSH"
  configure_remote_stage "$target" \
    || die "远端初始化未确认完成；请检查远端日志或 VPS 控制台，修正后重试"

  print_step "4/5" "写入本地 ssh_config"
  echo "目标：ssh ${HOST_ALIAS} 将以普通用户 ${NORMAL_USER} 登录。"
  write_ssh_config "$HOST_ALIAS" "$SERVER_HOST" "$NORMAL_USER" "$FINAL_PORT" "$PRIVATE_KEY"

  print_step "5/5" "验证最终 SSH Host 配置"
  verify_final_host_login

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
