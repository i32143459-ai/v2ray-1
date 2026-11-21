#!/usr/bin/env bash
# Xray VLESS + Reality installer (systemd Linux)
set -Eeuo pipefail
umask 027

XRAY_BIN=/usr/local/bin/xray
XRAY_DIR=/usr/local/etc/xray
XRAY_CONFIG="$XRAY_DIR/config.json"
CLIENT_CONFIG="$XRAY_DIR/reclient.json"
INSTALL_LOG_DIR=/var/log/reality
XRAY_LOG_DIR=/var/log/xray
INSTALL_LOG="$INSTALL_LOG_DIR/install.log"
INSTALL_ERROR_LOG="$INSTALL_LOG_DIR/error.log"
XRAY_ACCESS_LOG="$XRAY_LOG_DIR/access.log"
XRAY_ERROR_LOG="$XRAY_LOG_DIR/error.log"
BACKUP_DIR=""
INSTALLER_SCRIPT=""
CONFIG_CHANGED=0
SERVICE_WAS_ACTIVE=0
SUCCESS=0

if (( EUID != 0 )); then echo '错误：请以 root 用户运行。' >&2; exit 1; fi
mkdir -p "$INSTALL_LOG_DIR" "$XRAY_LOG_DIR"
chmod 750 "$INSTALL_LOG_DIR"
touch "$INSTALL_LOG" "$INSTALL_ERROR_LOG"
chmod 640 "$INSTALL_LOG" "$INSTALL_ERROR_LOG"

now() { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '[%s] %s\n' "$(now)" "$*" | tee -a "$INSTALL_LOG"; }
warn() { log "警告：$*"; }
error() { printf '[%s] 错误：%s\n' "$(now)" "$*" | tee -a "$INSTALL_LOG" "$INSTALL_ERROR_LOG" >&2; }
die() { error "$*"; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

on_error() {
  local code=$? line=${1:-unknown}
  trap - ERR
  error "执行失败（行 $line，退出码 $code）。"
  exit "$code"
}
on_exit() {
  local code=$?
  trap - EXIT
  if (( code != 0 )) && (( CONFIG_CHANGED == 1 )); then
    if [[ -n "$BACKUP_DIR" && -f "$BACKUP_DIR/config.json" ]]; then
      cp -p "$BACKUP_DIR/config.json" "$XRAY_CONFIG" || true
      log "已恢复原 Xray 配置：$BACKUP_DIR/config.json"
      if (( SERVICE_WAS_ACTIVE == 1 )); then systemctl restart xray.service || true; fi
    else
      warn '本次安装前不存在旧配置；未自动删除新配置。'
    fi
  fi
  [[ -z "$INSTALLER_SCRIPT" ]] || rm -f "$INSTALLER_SCRIPT"
  if (( code != 0 )); then error "安装未完成；详细信息见 $INSTALL_LOG"; fi
}
trap 'on_error "$LINENO"' ERR
trap on_exit EXIT
trap 'die "安装被中断"' INT TERM

require_systemd() {
  command_exists systemctl || die '当前脚本仅支持 systemd 系统。'
  [[ -d /run/systemd/system ]] || die 'systemd 未作为系统服务管理器运行。'
}

PKG_MANAGER=""
detect_package_manager() {
  if command_exists apt-get; then PKG_MANAGER=apt
  elif command_exists dnf; then PKG_MANAGER=dnf
  elif command_exists yum; then PKG_MANAGER=yum
  elif command_exists zypper; then PKG_MANAGER=zypper
  elif command_exists pacman; then PKG_MANAGER=pacman
  else die '未检测到受支持的包管理器。'; fi
  log "包管理器：$PKG_MANAGER"
}

retry() {
  local attempt=1
  until "$@"; do
    if (( attempt >= 3 )); then return 1; fi
    warn "命令失败，5 秒后重试（$attempt/3）：$1"
    sleep 5
    ((attempt+=1))
  done
}

install_dependencies() {
  log '更新软件包索引并安装依赖...'
  case "$PKG_MANAGER" in
    apt)
      retry env DEBIAN_FRONTEND=noninteractive apt-get update || die 'apt 更新失败。'
      retry env DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates unzip openssl python3 util-linux || die 'apt 依赖安装失败。'
      ;;
    dnf) retry dnf install -y curl ca-certificates unzip openssl python3 util-linux || die 'dnf 依赖安装失败。' ;;
    yum) retry yum install -y curl ca-certificates unzip openssl python3 util-linux || die 'yum 依赖安装失败。' ;;
    zypper) retry zypper --non-interactive install curl ca-certificates unzip openssl python3 util-linux || die 'zypper 依赖安装失败。' ;;
    pacman) retry pacman -Sy --noconfirm curl ca-certificates unzip openssl python util-linux || die 'pacman 依赖安装失败。' ;;
  esac
  command_exists curl && command_exists python3 || die '缺少 curl 或 python3。'
}

validate_port() {
  [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}
validate_domain() {
  local d=$1 label
  [[ ${#d} -le 253 && "$d" == *.* ]] || return 1
  [[ "$d" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
  local IFS=.
  read -r -a labels <<< "$d"
  for label in "${labels[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 && "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
}

read_settings() {
  local answer=""
  read -r -t 15 -p '监听端口（回车或等待15秒默认443）：' answer || true
  PORT_NUMBER=${answer:-443}
  validate_port "$PORT_NUMBER" || die "无效端口：$PORT_NUMBER"
  answer=""
  read -r -t 30 -p 'Reality SNI（回车或等待30秒默认www.amazon.com）：' answer || true
  SERVER_SNI=${answer:-www.amazon.com}
  validate_domain "$SERVER_SNI" || die "无效域名：$SERVER_SNI"
  UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)
  [[ "$UUID" =~ ^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$ ]] || die 'UUID 生成失败。'
  log "端口：$PORT_NUMBER；SNI：$SERVER_SNI"
}

get_public_ip() {
  local endpoint ip
  for endpoint in https://api.ipify.org https://ipv4.icanhazip.com https://checkip.amazonaws.com; do
    ip=$(curl -4fsS --connect-timeout 5 --max-time 10 "$endpoint" 2>/dev/null | tr -d '\r\n' || true)
    if python3 - "$ip" <<'PY' >/dev/null 2>&1
import ipaddress,sys
x=ipaddress.ip_address(sys.argv[1]); assert x.version==4 and x.is_global
PY
    then printf '%s' "$ip"; return 0; fi
  done
  for endpoint in https://api64.ipify.org https://ipv6.icanhazip.com; do
    ip=$(curl -6fsS --connect-timeout 5 --max-time 10 "$endpoint" 2>/dev/null | tr -d '\r\n' || true)
    if python3 - "$ip" <<'PY' >/dev/null 2>&1
import ipaddress,sys
x=ipaddress.ip_address(sys.argv[1]); assert x.version==6 and x.is_global
PY
    then printf '%s' "$ip"; return 0; fi
  done
  return 1
}

backup_existing() {
  BACKUP_DIR="/var/backups/reality/$(date +%Y%m%d-%H%M%S)-$$"
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  if [[ -f "$XRAY_CONFIG" ]]; then
    cp -p "$XRAY_CONFIG" "$BACKUP_DIR/config.json"
    log "原配置已备份到：$BACKUP_DIR/config.json"
  fi
  if systemctl is-active --quiet xray.service 2>/dev/null; then SERVICE_WAS_ACTIVE=1; fi
}

install_xray() {
  log '下载官方 Xray 安装脚本...'
  INSTALLER_SCRIPT=$(mktemp /tmp/xray-install.XXXXXXXX.sh)
  retry curl -fL --connect-timeout 15 --max-time 120 -o "$INSTALLER_SCRIPT" \
    'https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh' || die '下载安装脚本失败。'
  [[ -s "$INSTALLER_SCRIPT" ]] && head -n 1 "$INSTALLER_SCRIPT" | grep -q '^#!' || die '安装脚本内容异常。'
  log '执行 Xray 官方安装脚本（输出写入独立安装日志）...'
  if ! timeout 600 bash "$INSTALLER_SCRIPT" install >>"$INSTALL_LOG" 2>>"$INSTALL_ERROR_LOG"; then
    die 'Xray 官方安装脚本执行失败，请查看安装日志。'
  fi
  [[ -x "$XRAY_BIN" ]] && "$XRAY_BIN" version >>"$INSTALL_LOG" 2>>"$INSTALL_ERROR_LOG" || die 'Xray 安装验证失败。'
  log 'Xray 安装成功。'
}

generate_keys() {
  local raw
  raw=$("$XRAY_BIN" x25519) || die 'Reality 密钥生成失败。'
  RE_PRIVATE_KEY=$(printf '%s\n' "$raw" | sed -nE 's/^[[:space:]]*Private[[:space:]]*key:[[:space:]]*([^[:space:]]+).*/\1/Ip' | head -n 1)
  RE_PUBLIC_KEY=$(printf '%s\n' "$raw" | sed -nE 's/^[[:space:]]*(Password|Public[[:space:]]*key):[[:space:]]*([^[:space:]]+).*/\2/Ip' | head -n 1)
  [[ "$RE_PRIVATE_KEY" =~ ^[A-Za-z0-9_-]{43}$ && "$RE_PUBLIC_KEY" =~ ^[A-Za-z0-9_-]{43}$ ]] || die '无法解析 Xray x25519 密钥。'
  SHORT_ID=$(openssl rand -hex 4) || die 'shortId 生成失败。'
  log 'Reality 密钥及 shortId 生成成功（私钥不写入日志）。'
}

# Official Xray service commonly runs as User=nobody, but detect the effective user.
setup_xray_log_permissions() {
  local service_user service_group
  service_user=$(systemctl show xray.service -p User --value 2>/dev/null || true)
  service_group=$(systemctl show xray.service -p Group --value 2>/dev/null || true)
  service_user=${service_user:-root}
  id "$service_user" >/dev/null 2>&1 || die "Xray 服务用户不存在：$service_user"
  if [[ -z "$service_group" ]]; then service_group=$(id -gn "$service_user"); fi
  getent group "$service_group" >/dev/null 2>&1 || die "Xray 服务组不存在：$service_group"
  mkdir -p "$XRAY_LOG_DIR"
  touch "$XRAY_ACCESS_LOG" "$XRAY_ERROR_LOG"
  chown "$service_user:$service_group" "$XRAY_LOG_DIR" "$XRAY_ACCESS_LOG" "$XRAY_ERROR_LOG"
  chmod 750 "$XRAY_LOG_DIR"
  chmod 640 "$XRAY_ACCESS_LOG" "$XRAY_ERROR_LOG"
  log "Xray 日志权限：$service_user:$service_group"
  XRAY_SERVICE_USER=$service_user
  XRAY_SERVICE_GROUP=$service_group
}

write_config() {
  local tmp
  mkdir -p "$XRAY_DIR"
  tmp=$(mktemp "$XRAY_DIR/.config.XXXXXXXX")
  # JSON strings are generated with Python to prevent quoting issues.
  python3 - "$tmp" "$PORT_NUMBER" "$UUID" "$SERVER_SNI" "$RE_PRIVATE_KEY" "$SHORT_ID" "$XRAY_ACCESS_LOG" "$XRAY_ERROR_LOG" <<'PY'
import json,sys
_,path,port,uid,sni,private,sid,access,error=sys.argv
cfg={
 "log":{"loglevel":"warning","access":access,"error":error},
 "inbounds":[{"listen":"0.0.0.0","port":int(port),"protocol":"vless",
   "settings":{"clients":[{"id":uid,"flow":"xtls-rprx-vision"}],"decryption":"none"},
   "streamSettings":{"network":"tcp","security":"reality",
      "realitySettings":{"show":False,"dest":sni+":443","xver":0,
         "serverNames":[sni],"privateKey":private,"shortIds":[sid]}}}],
 "outbounds":[{"protocol":"freedom","tag":"direct"},{"protocol":"blackhole","tag":"blocked"}]
}
with open(path,'w') as f: json.dump(cfg,f,indent=2); f.write('\n')
PY
  chmod 640 "$tmp"
  # Xray needs read permission for config, regardless of the service account.
  chown "root:$XRAY_SERVICE_GROUP" "$tmp"
  chmod 750 "$XRAY_DIR"
  chown "root:$XRAY_SERVICE_GROUP" "$XRAY_DIR"
  log '验证 Xray 配置...'
  if ! "$XRAY_BIN" run -test -config "$tmp" >>"$INSTALL_LOG" 2>>"$INSTALL_ERROR_LOG"; then
    rm -f "$tmp"
    die 'Xray 配置测试失败。'
  fi
  CONFIG_CHANGED=1
  mv -f "$tmp" "$XRAY_CONFIG"
  log "服务端配置：$XRAY_CONFIG"
}

# Configure journald routing of stdout/stderr separately; Xray application logs go to files.
configure_systemd_output() {
  local dropin=/etc/systemd/system/xray.service.d/20-reality-logging.conf
  mkdir -p "$(dirname "$dropin")"
  cat > "$dropin" <<'EOF'
[Service]
StandardOutput=null
StandardError=null
SyslogIdentifier=xray
EOF
  systemctl daemon-reload
  log '已将 Xray 标准输出和标准错误从 syslog/journal 常规流中分离。'
}

configure_logrotate() {
  command_exists logrotate || { warn '未检测到 logrotate，跳过日志自动轮转。'; return; }
  cat > /etc/logrotate.d/reality-xray <<EOF
$INSTALL_LOG $INSTALL_ERROR_LOG {
    weekly
    rotate 8
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
$XRAY_ACCESS_LOG $XRAY_ERROR_LOG {
    daily
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF
  log '日志轮转规则：/etc/logrotate.d/reality-xray'
}

write_client_config() {
  local endpoint="$SERVER_IP"
  [[ "$SERVER_IP" == *:* ]] && endpoint="[$SERVER_IP]"
  local link="vless://${UUID}@${endpoint}:${PORT_NUMBER}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SERVER_SNI}&fp=chrome&pbk=${RE_PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#reality"
  python3 - "$CLIENT_CONFIG" "$SERVER_IP" "$PORT_NUMBER" "$UUID" "$RE_PUBLIC_KEY" "$SERVER_SNI" "$SHORT_ID" "$link" <<'PY'
import json,sys
_,path,ip,port,uid,pbk,sni,sid,link=sys.argv
obj={"配置参数":{"代理模式":"vless","地址":ip,"端口":int(port),"UUID":uid,"流控":"xtls-rprx-vision","传输协议":"tcp","公钥":pbk,"底层传输":"reality","SNI":sni,"shortId":sid},"连接链接":link}
with open(path,'w') as f: json.dump(obj,f,ensure_ascii=False,indent=2); f.write('\n')
PY
  chown root:root "$CLIENT_CONFIG"
  chmod 600 "$CLIENT_CONFIG"
  CLIENT_LINK=$link
}

start_service() {
  systemctl enable xray.service >>"$INSTALL_LOG" 2>>"$INSTALL_ERROR_LOG" || die '无法设置 Xray 开机自启。'
  if ! systemctl restart xray.service >>"$INSTALL_LOG" 2>>"$INSTALL_ERROR_LOG"; then
    systemctl status xray.service --no-pager >>"$INSTALL_ERROR_LOG" 2>&1 || true
    journalctl -u xray.service -n 30 --no-pager >>"$INSTALL_ERROR_LOG" 2>&1 || true
    die 'Xray 服务启动失败，请查看 /var/log/reality/error.log。'
  fi
  sleep 2
  systemctl is-active --quiet xray.service || die 'Xray 服务未保持运行。'
  log 'Xray 服务已正常运行。'
}

main() {
  log '开始安装 Xray VLESS + Reality（独立日志版）。'
  require_systemd
  detect_package_manager
  read_settings
  install_dependencies
  SERVER_IP=$(get_public_ip) || die '无法检测公网 IP，请检查服务器网络。'
  log "公网 IP：$SERVER_IP"
  backup_existing
  install_xray
  generate_keys
  setup_xray_log_permissions
  write_config
  configure_systemd_output
  configure_logrotate
  start_service
  write_client_config
  SUCCESS=1
  printf '\n========== Reality 安装成功 ==========\n'
  printf '地址：%s\n端口：%s\nUUID：%s\nSNI：%s\n公钥：%s\nshortId：%s\n' "$SERVER_IP" "$PORT_NUMBER" "$UUID" "$SERVER_SNI" "$RE_PUBLIC_KEY" "$SHORT_ID"
  printf '\n客户端连接链接：\n%s\n' "$CLIENT_LINK"
  printf '\n配置文件：%s\n安装日志：%s\n安装错误：%s\nXray 访问：%s\nXray 错误：%s\n' "$CLIENT_CONFIG" "$INSTALL_LOG" "$INSTALL_ERROR_LOG" "$XRAY_ACCESS_LOG" "$XRAY_ERROR_LOG"
  printf '======================================\n'
  log '安装成功完成。'
}
main "$@"
