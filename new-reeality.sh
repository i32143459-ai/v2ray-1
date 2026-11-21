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
