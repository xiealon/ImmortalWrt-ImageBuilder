#!/bin/sh
SCRIPT_VER="2026-10-16.39"

LXC_NAME="${LXC_NAME:-ubuntu}"
CS_HOME="${CS_HOME:-/etc/crowdsec}"
LXC_PATH="${LXC_PATH:-/srv/lxc}"
ROOTFS="$LXC_PATH/$LXC_NAME/rootfs"
CFG="$LXC_PATH/$LXC_NAME/config"
TARBALL="${TARBALL:-$CS_HOME/lxc-ubuntu.tar.gz}"
LEGACY_TARBALL="/opt/lxc-ubuntu.tar.gz"
LAPI_PORT="${LAPI_PORT:-8080}"
BOUNCER_NAME="${BOUNCER_NAME:-openwrt-fw}"
ENROLL_KEY_FILE="${ENROLL_KEY_FILE:-/etc/config/crowdsec_enroll_key.txt}"
MAX_WAIT="${MAX_WAIT:-60}"
SLEEP=5
CROWDSEC_CFG="$ROOTFS/etc/crowdsec/config.yaml"
CSCLI=/usr/bin/cscli

if [ -z "${CONTAINER_IP:-}" ] && [ -f /etc/config/custom_container_ip.txt ]; then
    CONTAINER_IP="$(head -n1 /etc/config/custom_container_ip.txt | tr -d ' \t\r\n')"
fi
CONTAINER_IP="${CONTAINER_IP:-10.0.0.10}"
if [ -z "${BRIDGE_IP:-}" ] && [ -f /etc/config/custom_bridge_ip.txt ]; then
    BRIDGE_IP="$(head -n1 /etc/config/custom_bridge_ip.txt | tr -d ' \t\r\n')"
fi
BRIDGE_IP="${BRIDGE_IP:-10.0.0.1}"

log() { echo "[$(date '+%F %T')] $*"; }

case "$0" in
    /*) _SELF="$0" ;;
    */*) _SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")" ;;
    *) _SELF="$(command -v "$0" 2>/dev/null)" ;;
esac
[ -n "$_SELF" ] && chmod +x "$_SELF" 2>/dev/null
chmod +x /etc/rc.local 2>/dev/null

ct() { timeout 30 lxc-attach -P "$LXC_PATH" -n "$LXC_NAME" -- "$@"; }
ct_running() { lxc-ls -P "$LXC_PATH" --running 2>/dev/null | grep -qw "$LXC_NAME"; }
ct_exists() { lxc-info -P "$LXC_PATH" -n "$LXC_NAME" >/dev/null 2>&1; }
ct_pid() { lxc-info -P "$LXC_PATH" -n "$LXC_NAME" 2>/dev/null | sed -n 's/^PID:[[:space:]]*//p' | head -n1; }
_pgrep_bouncer() { pgrep -f "crowdsec-firewall-bouncer" >/dev/null 2>&1; }
_ct_env() { ct sh -c 'export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; '"$1"; }

cs_active_on_host() { _pgrep_bouncer; }
nft_table_ready() { nft list table ip crowdsec >/dev/null 2>&1; }

_protect_file() {
    [ -f "$1" ] || return 0
    if command -v chattr >/dev/null 2>&1; then
        chattr +i "$1" 2>/dev/null || true
    fi
}
_unprotect_file() {
    [ -f "$1" ] || return 0
    if command -v chattr >/dev/null 2>&1; then
        chattr -i "$1" 2>/dev/null || true
    fi
}
protect_key_files() {
    _protect_file "$TARBALL"
    _protect_file "$ENROLL_KEY_FILE"
}


ct_force_stop() {
    ct_running || return 0
    lxc-stop -P "$LXC_PATH" -n "$LXC_NAME" -k >/dev/null 2>&1
    _i=0
    while ct_running; do
        _i=$((_i+1))
        if [ "$_i" -ge 12 ]; then
            _pid="$(ct_pid)"
            [ -n "$_pid" ] && kill -9 "$_pid" 2>/dev/null
            sleep 1
        fi
        [ "$_i" -ge 24 ] && { log "容器无法停止，跳过重建"; return 1; }
        sleep $SLEEP
    done
    return 0
}

_wait() {
    _wf="$1"; _wn="${2:-$MAX_WAIT}"
    _wi=0
    until "$_wf"; do
        _wi=$((_wi+1))
        [ "$_wi" -ge "$_wn" ] && return 1
        sleep $SLEEP
    done
    return 0
}
_wait_ct_running() { _wait ct_running 12; }

setup_lxc_firewall() {
    _lsc_net=$(echo "$CONTAINER_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')
    _lan_ip=$(uci -q get network.lan.ipaddr 2>/dev/null)
    if [ -z "$_lan_ip" ] && [ -f /etc/config/custom_router_ip.txt ]; then
        _lan_ip=$(head -n1 /etc/config/custom_router_ip.txt | tr -d ' \t\r\n')
    fi
    [ -n "$_lan_ip" ] || _lan_ip='192.168.3.201'

    uci -q set firewall.lxczone=zone
    uci -q set firewall.lxczone.name='lxc'
    uci -q set firewall.lxczone.network='lxc'
    uci -q set firewall.lxczone.input='ACCEPT'
    uci -q set firewall.lxczone.output='ACCEPT'
    uci -q set firewall.lxczone.forward='ACCEPT'
    uci -q set firewall.lxc2lan=forwarding
    uci -q set firewall.lxc2lan.src='lxc'
    uci -q set firewall.lxc2lan.dest='lan'
    uci -q set firewall.lxc2docker=forwarding
    uci -q set firewall.lxc2docker.src='lxc'
    uci -q set firewall.lxc2docker.dest='docker'
    uci -q set firewall.lxc2vpn=forwarding
    uci -q set firewall.lxc2vpn.src='lxc'
    uci -q set firewall.lxc2vpn.dest='vpn'
    uci -q set firewall.lan2lxc=forwarding
    uci -q set firewall.lan2lxc.src='lan'
    uci -q set firewall.lan2lxc.dest='lxc'
    uci -q set firewall.lxcsnat=nat
    uci -q set firewall.lxcsnat.name='lxc-snat'
    uci -q del_list firewall.lxcsnat.proto='all'
    uci -q add_list firewall.lxcsnat.proto='all'
    uci -q set firewall.lxcsnat.src='lan'
    uci -q set firewall.lxcsnat.src_ip="${_lsc_net}"
    uci -q set firewall.lxcsnat.target='SNAT'
    uci -q set firewall.lxcsnat.snat_ip="${_lan_ip}"
    uci -q commit firewall
    /etc/init.d/firewall reload >/dev/null 2>&1
    log "[防火墙] lxc 区 input/output/forward=ACCEPT（8080/tcp、514/udp 可达）"
    return 0
}

setup_log_forward() {
    [ -n "$CONTAINER_IP" ] || { log "[日志] 无容器 IP，跳过转发配置"; return 1; }

    _sys=$(uci show system 2>/dev/null | grep '=system$' | head -n1 | cut -d= -f1)
    if [ -z "$_sys" ]; then
        uci add system system >/dev/null 2>&1
        _sys=$(uci show system 2>/dev/null | grep '=system$' | head -n1 | cut -d= -f1)
    fi
    [ -n "$_sys" ] || { log "[日志] 无 system 段，无法配置远程日志"; return 1; }

    _want_ip="$CONTAINER_IP"
    _cur_ip=$(uci -q get "$_sys.log_ip" 2>/dev/null)
    _cur_port=$(uci -q get "$_sys.log_port" 2>/dev/null)
    _cur_proto=$(uci -q get "$_sys.log_proto" 2>/dev/null)
    _cur_remote=$(uci -q get "$_sys.log_remote" 2>/dev/null)

    if [ "$_cur_ip" = "$_want_ip" ] && [ "$_cur_port" = "514" ] \
       && [ "$_cur_proto" = "udp" ] && [ "$_cur_remote" = "1" ]; then
        log "[日志] 远程日志已指向容器 ${_want_ip}:514/udp，跳过"
        return 0
    fi

    uci -q set "$_sys.log_ip=$_want_ip"
    uci -q set "$_sys.log_port=514"
    uci -q set "$_sys.log_proto=udp"
    uci -q set "$_sys.log_remote=1"
    uci commit system

    /etc/init.d/log reload >/dev/null 2>&1 || /etc/init.d/logd reload >/dev/null 2>&1 || true
    log "[日志] 宿主机系统日志已转发到容器 ${_want_ip}:514/udp"
    return 0
}

setup_bridge() {
    _lsc_net=$(echo "$CONTAINER_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')
    _br=$(ip -4 addr show lxcbr0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -n1)
    if ip link show lxcbr0 >/dev/null 2>&1 \
       && [ "$(uci -q get network.lxc.proto 2>/dev/null)" = "static" ] \
       && [ -n "$_br" ] && [ "$_br" = "$BRIDGE_IP" ]; then
        log "[网桥] 已就绪 lxcbr0=${BRIDGE_IP}/24，跳过重建"
        setup_lxc_firewall
        return 0
    fi

    uci -q set network.lxcbr0=device
    uci -q set network.lxcbr0.name='lxcbr0'
    uci -q set network.lxcbr0.type='bridge'
    uci -q set network.lxcbr0.bridge_empty='1'
    uci -q set network.lxc=interface
    uci -q set network.lxc.device='lxcbr0'
    uci -q set network.lxc.proto='static'
    uci -q set network.lxc.ipaddr="${BRIDGE_IP}"
    uci -q set network.lxc.netmask='255.255.255.0'
    uci -q set dhcp.lxc=dhcp
    uci -q set dhcp.lxc.interface='lxc'
    uci -q set dhcp.lxc.start='100'
    uci -q set dhcp.lxc.limit='150'
    uci -q set dhcp.lxc.leasetime='1h'
    uci -q commit network
    uci -q commit dhcp

    /etc/init.d/network reload >/dev/null 2>&1

    if ! ip link show lxcbr0 >/dev/null 2>&1; then
        ip link add lxcbr0 type bridge 2>/dev/null
    fi
    ip addr add "${BRIDGE_IP}/24" dev lxcbr0 2>/dev/null
    ip link set lxcbr0 up 2>/dev/null
    echo 1 >/proc/sys/net/ipv4/ip_forward 2>/dev/null

    BRIDGE_IP=$(ip -4 addr show lxcbr0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -n1)
    log "[网桥] lxcbr0=${BRIDGE_IP}/24 容器=${CONTAINER_IP} 网段=${_lsc_net}"
    setup_lxc_firewall
}

write_cfg() {
    _dst="${1:-$CFG}"
    cat > "$_dst" <<EOF
lxc.arch = amd64
lxc.include = /usr/share/lxc/config/common.conf
lxc.rootfs.path = dir:$ROOTFS
lxc.init.cmd = /sbin/init
lxc.autodev = 1
lxc.net.0.type = veth
lxc.net.0.link = lxcbr0
lxc.net.0.flags = up
lxc.net.0.hwaddr = 10:66:6A:7C:05:9A
lxc.tty.max = 4
lxc.pty.max = 1024
EOF
}

apply_cfg() {
    write_cfg "$CFG.tmp0"
    if [ -f "$CFG" ] && [ ! -f /usr/share/lxc/config/common.conf ]; then
        grep -v '^[[:space:]]*lxc.include' "$CFG.tmp0" > "$CFG" 2>/dev/null \
            && rm -f "$CFG.tmp0" || { rm -f "$CFG.tmp0"; return 1; }
    else
        mv -f "$CFG.tmp0" "$CFG" 2>/dev/null || return 1
    fi
    _trim=0
    while [ "$_trim" -lt 20 ]; do
        _err=$(lxc-info -P "$LXC_PATH" -n "$LXC_NAME" 2>&1) && return 0
        _bad=$(printf '%s\n' "$_err" | sed -n 's/.*at line "\([^"]*\)".*/\1/p' | head -n1)
        [ -n "$_bad" ] || break
        grep -v -F "$_bad" "$CFG" > "$CFG.tmp1" 2>/dev/null && mv -f "$CFG.tmp1" "$CFG" || break
        _trim=$((_trim+1))
    done
    ct_exists
}

rebuild_from_image() {
    log "尝试从镜像解压 rootfs：$TARBALL"
    [ -f "$TARBALL" ] || { log "镜像文件不存在，无法解压"; return 1; }
    ct_force_stop || return 1
    rm -rf "$ROOTFS" 2>/dev/null
    mkdir -p "$ROOTFS" || return 1
    if ( set -C; : > "$ROOTFS/.extracting" ) 2>/dev/null; then
        if tar -xzf "$TARBALL" -C "$ROOTFS"; then
            rm -f "$ROOTFS/.extracting"
            log "解压完成（$(du -sh "$ROOTFS" 2>/dev/null | cut -f1)）"
            return 0
        fi
        rm -f "$ROOTFS/.extracting"
        log "解压失败"
        return 1
    fi
    log "另一实例正在解压，等待完成"
    _i=0
    while [ -f "$ROOTFS/.extracting" ]; do
        _i=$((_i+1)); [ "$_i" -ge $MAX_WAIT ] && break; sleep $SLEEP
    done
    [ -f "$CROWDSEC_CFG" ]
}

ensure_trusted_ip() {
    [ -f "$CROWDSEC_CFG" ] || return 1
    [ -n "$BRIDGE_IP" ] || return 1
    grep -qE "^[[:space:]]*-[[:space:]]*${BRIDGE_IP}([[:space:]]|$)" "$CROWDSEC_CFG" 2>/dev/null \
        && { log "[配置] trusted_ips 已含 $BRIDGE_IP"; return 0; }
    awk -v tip="$BRIDGE_IP" '
        BEGIN { in_ti=0; indent="      " }
        /^[[:space:]]*trusted_ips:/ { in_ti=1; print; next }
        in_ti && /^[[:space:]]*-[[:space:]]/ { print; next }
        in_ti && /^[[:space:]]*#/ { print indent "- " tip; in_ti=0; print; next }
        in_ti && /^[[:space:]]*$/ { print; next }
        in_ti { print indent "- " tip; in_ti=0; print; next }
        { print }
        END { if (in_ti) print indent "- " tip }
    ' "$CROWDSEC_CFG" > "$CROWDSEC_CFG.tmp" 2>/dev/null \
        && mv -f "$CROWDSEC_CFG.tmp" "$CROWDSEC_CFG" 2>/dev/null \
        && { log "[配置] trusted_ips 已补上 $BRIDGE_IP"; return 0; }
    rm -f "$CROWDSEC_CFG.tmp" 2>/dev/null
    log "[配置] 补 trusted_ips 失败"
    return 1
}

_container_dns() {
    _dns=""
    if [ -f /etc/config/custom_router_dns.txt ]; then
        _dns=$(cat /etc/config/custom_router_dns.txt | tr '\n' ' ' | tr -d '\r')
    fi
    [ -n "$_dns" ] || _dns="$BRIDGE_IP"
    [ -n "$_dns" ] || _dns='10.0.0.1'
    printf '%s' "$_dns"
}

setup_container_network() {
    [ -d "$ROOTFS" ] || { log "[网络] rootfs 未就绪"; return 1; }
    _dns="$(_container_dns)"
    _netfile="$ROOTFS/etc/systemd/network/10-eth0.network"
    mkdir -p "$(dirname "$_netfile")" 2>/dev/null
    cat > "$_netfile" <<EOF
[Match]
Name=eth0

[Network]
Address=${CONTAINER_IP}/24
Gateway=${BRIDGE_IP}
DNS=${_dns}
EOF
    log "[网络] 容器静态 IP ${CONTAINER_IP}/24 网关 ${BRIDGE_IP} DNS ${_dns}"
    return 0
}

setup_container_boot() {
    [ -d "$ROOTFS" ] || { log "[自启] rootfs 未就绪"; return 1; }
    _wants="$ROOTFS/etc/systemd/system/multi-user.target.wants"
    mkdir -p "$_wants" 2>/dev/null
    [ -f "$ROOTFS/lib/systemd/system/systemd-networkd.service" ] \
        && ln -sf /lib/systemd/system/systemd-networkd.service "$_wants/systemd-networkd.service" 2>/dev/null
    [ -f "$ROOTFS/lib/systemd/system/crowdsec.service" ] \
        && ln -sf /lib/systemd/system/crowdsec.service "$_wants/crowdsec.service" 2>/dev/null
    echo "crowdsec" > "$ROOTFS/etc/hostname" 2>/dev/null
    : > "$ROOTFS/etc/machine-id" 2>/dev/null
    log "[自启] networkd + crowdsec 软链已建，hostname/machine-id 已初始化"
    return 0
}

setup_resolv() {
    [ -d "$ROOTFS" ] || { log "[DNS] rootfs 未就绪"; return 1; }
    _dns="$(_container_dns)"
    _resolv="$ROOTFS/etc/resolv.conf"
    rm -f "$_resolv" 2>/dev/null
    echo "nameserver ${_dns}" > "$_resolv" 2>/dev/null
    chmod 644 "$_resolv" 2>/dev/null
    log "[DNS] 容器 resolv.conf → ${_dns}"
    return 0
}

setup_acquis() {
    [ -d "$ROOTFS/etc/crowdsec" ] || { log "[配置] rootfs 内无 crowdsec"; return 1; }
    mkdir -p "$ROOTFS/etc/crowdsec/acquis.d" \
             "$ROOTFS/etc/crowdsec/parsers/s01-parse" \
             "$ROOTFS/etc/crowdsec/parsers/s02-enrich" 2>/dev/null

    _acq="$ROOTFS/etc/crowdsec/acquis.d/router.yaml"
    cat > "$_acq" <<'EOF'
source: syslog
listen_addr: 0.0.0.0
listen_port: 514
protocol: udp
labels:
  type: syslog
EOF

    _par="$ROOTFS/etc/crowdsec/parsers/s01-parse/openwrt-dropbear.yaml"
    cat > "$_par" <<'EOF'
name: openwrt/dropbear-logs
description: Parse OpenWrt non-PAM dropbear logs
filter: evt.Parsed.program == 'dropbear'
onsuccess: next_stage
nodes:
  - grok:
      pattern: "Bad password attempt for '?%{DATA:username}'? from %{IP:source_ip}:%{INT:source_port}"
      apply_on: message
    statics:
      - meta: log_type
        value: ssh_failed-auth
  - grok:
      pattern: "Login attempt for nonexistent user %{GREEDYDATA:username} from %{IP:source_ip}:%{INT:source_port}"
      apply_on: message
    statics:
      - meta: log_type
        value: ssh_failed-auth
  - grok:
      pattern: "Exit before auth from <%{IP:source_ip}:%{INT:source_port}>"
      apply_on: message
    statics:
      - meta: log_type
        value: ssh_failed-auth
  - grok:
      pattern: "Password auth succeeded for '?%{DATA:username}'? from %{IP:source_ip}:%{INT:source_port}"
      apply_on: message
    statics:
      - meta: log_type
        value: ssh_auth_success
  - grok:
      pattern: "Pubkey auth succeeded for '?%{DATA:username}'? with key %{DATA:key_type} from %{IP:source_ip}:%{INT:source_port}"
      apply_on: message
    statics:
      - meta: log_type
        value: ssh_auth_success
statics:
  - meta: service
    value: ssh
  - meta: source_ip
    expression: evt.Parsed.source_ip
  - meta: username
    expression: evt.Parsed.username
EOF

    _wl="$ROOTFS/etc/crowdsec/parsers/s02-enrich/openwrt-whitelist.yaml"
    cat > "$_wl" <<'EOF'
name: openwrt/my-whitelist
description: 'No whitelist configured - placeholder only'
whitelist:
  reason: placeholder, nothing is whitelisted
  ip:
    - 127.0.0.1
  cidr:
    - 240.0.0.0/4
EOF
    log "[配置] 解析器 + 日志源 + 白名单已写入"
    return 0
}

ensure_listen_uri() {
    [ -f "$CROWDSEC_CFG" ] || { log "[配置] config.yaml 缺失"; return 1; }
    grep -qE "^[[:space:]]*listen_uri:[[:space:]]*['\"]?0\.0\.0\.0:${LAPI_PORT}" "$CROWDSEC_CFG" 2>/dev/null \
        && { log "[配置] listen_uri 已就绪 0.0.0.0:${LAPI_PORT}"; return 0; }
    sed -i -E "s|^([[:space:]]*listen_uri:)[[:space:]]*.*|\\1 0.0.0.0:${LAPI_PORT}|" "$CROWDSEC_CFG" 2>/dev/null
    grep -qE "^[[:space:]]*listen_uri:[[:space:]]*['\"]?0\.0\.0\.0:${LAPI_PORT}" "$CROWDSEC_CFG" 2>/dev/null \
        && { log "[配置] listen_uri 已改为 0.0.0.0:${LAPI_PORT}"; return 0; }
    log "[配置] listen_uri 覆盖失败"
    return 1
}

ensure_online_client_off() {
    [ -f "$CROWDSEC_CFG" ] || { log "[配置] config.yaml 缺失"; return 1; }

    sed -i -E \
        -e "s|^([[:space:]]*)online_client:.*|\\1# online_client: # Central API credentials disabled by bootstrap|" \
        -e "s|^([[:space:]]*)credentials_path:.*online_api_credentials.yaml.*|\\1# credentials_path: /etc/crowdsec/online_api_credentials.yaml|" \
        "$CROWDSEC_CFG" 2>/dev/null

    sed -i -E \
        -e "/^[[:space:]]*client:/,/^[[:space:]]*server:/ s|^([[:space:]]*)#[[:space:]]*credentials_path:.*|\1credentials_path: /etc/crowdsec/local_api_credentials.yaml|" \
        "$CROWDSEC_CFG" 2>/dev/null

    if grep -qE "^[[:space:]]*# online_client:" "$CROWDSEC_CFG" 2>/dev/null; then
        log "[配置] online_client 已注释，LAPI 不再强依赖中央 API 认证"
        return 0
    fi
    log "[配置] online_client 注释失败"
    return 1
}

ensure_online_client_on() {
    [ -f "$CROWDSEC_CFG" ] || { log "[配置] config.yaml 缺失"; return 1; }

    sed -i -E \
        -e "s|^([[:space:]]*)# online_client:.*|\1online_client:|" \
        -e "s|^([[:space:]]*)# credentials_path: /etc/crowdsec/online_api_credentials.yaml.*|\1credentials_path: /etc/crowdsec/online_api_credentials.yaml|" \
        "$CROWDSEC_CFG" 2>/dev/null

    if grep -qE "^[[:space:]]*online_client:" "$CROWDSEC_CFG" 2>/dev/null; then
        log "[配置] online_client 已放出（取消注释），CAPI 可经 LAPI 后启用"
        return 0
    fi
    log "[配置] online_client 放出失败"
    return 1
}

setup_crowdsec_config() {
    setup_acquis || return 1
    ensure_listen_uri || return 1
    ensure_trusted_ip || return 1
    # 注意：CAPI(online_client) 的「屏蔽/放出」不再在配置生成阶段无脑执行，
    # 改由 main 按「首次/恢复 vs 后续重启」两种模式显式控制（见 main 末尾）。
    return 0
}

prepare_container() {
    setup_container_network || return 1
    setup_container_boot || return 1
    setup_resolv || return 1
    setup_crowdsec_config || return 1
    apply_cfg || return 1
    return 0
}

_bouncer_register_once() {
    _ct_env "$CSCLI bouncers delete $BOUNCER_NAME" >/dev/null 2>&1 || true
    _junk="$(_ct_env "$CSCLI bouncers list -o json" 2>/dev/null \
             | grep -oE '"name":[[:space:]]*"[^"]*"' \
             | sed -E 's/.*"name":[[:space:]]*"([^"]*)"/\1/' \
             | grep -vx "$BOUNCER_NAME")"
    for _jn in $_junk; do
        _ct_env "$CSCLI bouncers delete \"$_jn\"" >/dev/null 2>&1 || true
        log "[bouncer] 已清理残留坏记录 name=$_jn"
    done

    _raw=$(_ct_env "$CSCLI bouncers add $BOUNCER_NAME -o raw" 2>&1)
    _key=$(printf '%s\n' "$_raw" | sed -e 's/\r$//' \
           | grep -Eo '^[A-Za-z0-9+/=_-]{16,}$' | tail -n1)
    [ -n "$_key" ] || return 1
    _sec=$(uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
    [ -n "$_sec" ] || return 1
    uci set "$_sec.api_key=$_key"
    uci commit crowdsec
    return 0
}

_ensure_bouncer_service() {
    if cs_active_on_host && nft_table_ready; then
        return 0
    fi
    service crowdsec-firewall-bouncer enable 2>/dev/null
    service crowdsec-firewall-bouncer restart 2>/dev/null
    sleep 3
    if cs_active_on_host && nft_table_ready; then
        log "[bouncer] 已生效"
    else
        log "[bouncer] 重启后仍未就绪"
    fi
    return 0
}

bouncer_pulling() {
    _json="$(_ct_env "$CSCLI bouncers list -o json" 2>/dev/null)"
    [ -n "$_json" ] || return 1

    printf '%s\n' "$_json" | awk -v want="$BOUNCER_NAME" '
        /"name":/ {
            cur = $0
            sub(/.*"name":[[:space:]]*"/, "", cur)
            sub(/".*/, "", cur)
            in_obj = (cur == want)
        }
        in_obj && /"last_pull":/ {
            lp = $0
            sub(/.*"last_pull":[[:space:]]*"/, "", lp)
            sub(/".*/, "", lp)
            if (lp != "") found = 1
        }
        END { exit (found ? 0 : 1) }
    '
}

bouncer_exists() {
    _ct_env "$CSCLI bouncers list -o json" 2>/dev/null | grep -q "\"name\":[[:space:]]*\"$BOUNCER_NAME\""
}

_bouncer_heal() {
    _max="${1:-3}"
    _i=0
    while [ "$_i" -lt "$_max" ]; do
        _i=$((_i+1))
        _bouncer_register_once || { log "[bouncer] 第 $_i/$_max 轮注册未拿到 key"; continue; }
        _ensure_bouncer_service
        _j=0
        while [ "$_j" -lt 3 ]; do
            _j=$((_j+1))
            bouncer_pulling && { log "[bouncer] 已恢复拉取（第 $_i 轮注册）"; return 0; }
            sleep 5
        done
        log "[bouncer] 第 $_i/$_max 轮注册后 last_pull 仍为空"
    done
    return 1
}

_crowdsec_diagnose() {
    if _ct_env "crowdsec -c /etc/crowdsec/config.yaml -t >/dev/null 2>&1"; then
        :
    else
        log "[诊断] config.yaml 校验失败（status≠0），判定文件/配置损坏，需重装"
        return 0
    fi

    _log="$(_ct_env "tail -n 200 /var/log/crowdsec.log 2>/dev/null")"
    [ -z "$_log" ] && _log="$(_ct_env "journalctl -u crowdsec --no-pager -n 100 2>/dev/null")"
    if [ -z "$_log" ]; then
        log "[诊断] 无 crowdsec 日志可取，保守判定为不重装"
        return 1
    fi

    if printf '%s\n' "$_log" | grep -qiE "no API client section|no such file|malformed|yaml.*error|sqlite|corrupt|invalid config|credentials.*not found"; then
        log "[诊断] 日志命中文件损坏类关键词，判定需重装"
        return 0
    fi

    if printf '%s\n' "$_log" | grep -qiE "connection refused|lookup|DNS|authenticate watcher|timeout|dial"; then
        log "[诊断] 日志命中网络/连接类关键词，判定为网络问题，不重装"
        return 1
    fi

    log "[诊断] 无法明确判定根因，保守不重装"
    return 1
}

_crowdsec_rebuild() {
    log "[重装] 判定容器文件损坏，执行 rootfs 重装"
    if ! rebuild_from_image; then
        log "[重装] rootfs 重装失败"
        return 1
    fi
    prepare_container || { log "[重装] 重装后配置生成失败"; return 1; }
    log "[重装] rootfs 重装完成，配置已重建"
    return 0
}

console_enroll_ok() {
    _out="$(_ct_env "$CSCLI console status" 2>&1)"
    [ -n "$_out" ] \
        && printf '%s\n' "$_out" | grep -qiE "authenticated" \
        && printf '%s\n' "$_out" | grep -qiE "enrolled" \
        && ! printf '%s\n' "$_out" | grep -qiE "not registered|not enrolled|unauthorized|forbidden|invalid|revoked"
}

re_enroll() {
    log "[自愈] console 状态异常，尝试用注册码重新 enroll"

    _enroll_key=""
    [ -f "$ENROLL_KEY_FILE" ] && _enroll_key="$(head -n1 "$ENROLL_KEY_FILE" | tr -d ' \t\r\n')"
    if [ -z "$_enroll_key" ]; then
        log "[自愈] 无注册码，放弃 re-enroll"
        return 1
    fi

    _cred_file="$ROOTFS/etc/crowdsec/online_api_credentials.yaml"
    _bak=""
    if [ -s "$_cred_file" ]; then
        _bak="$_cred_file.bak"
        mv -f "$_cred_file" "$_bak" 2>/dev/null || true
    fi

    if ! _ct_env "/usr/bin/cscli console enroll $_enroll_key >/dev/null 2>&1"; then
        [ -n "$_bak" ] && mv -f "$_bak" "$_cred_file"
        log "[自愈] re-enroll 执行失败（注册码未消耗），下次开机重试"
        return 1
    fi
    _ct_env 'systemctl restart crowdsec >/dev/null 2>&1' || true

    if ! _ct_env '/usr/bin/cscli console enable --all >/dev/null 2>&1'; then
        log "[自愈] console enable 失败，回滚凭据，不放出 CAPI"
        [ -n "$_bak" ] && mv -f "$_bak" "$_cred_file"
        return 1
    fi

    _i=0
    while [ "$_i" -lt 6 ]; do
        _i=$((_i+1))
        if console_enroll_ok; then
            if _ct_env "crowdsec -c /etc/crowdsec/config.yaml -t >/dev/null 2>&1"; then
                log "[自愈] re-enroll 成功，console 状态正常，CAPI 已放出，配置校验(-t)通过"
                return 0
            fi
            log "[自愈] re-enroll 复检通过但配置校验(-t)报错，收回 CAPI 放出并回滚凭据"
            _ct_env '/usr/bin/cscli console disable --all >/dev/null 2>&1' || true
            [ -n "$_bak" ] && mv -f "$_bak" "$_cred_file"
            return 1
        fi
        sleep 5
    done

    log "[自愈] re-enroll 复检未通过，收回 CAPI 放出并回滚凭据"
    _ct_env '/usr/bin/cscli console disable --all >/dev/null 2>&1' || true
    [ -n "$_bak" ] && mv -f "$_bak" "$_cred_file"
    return 1
}

# 统一 enroll 入口：仅在 CAPI 已「放出」（online_client 取消注释）后调用，
# 满足「enroll 的步骤在放出屏蔽之后」。若 console 已正常则跳过。
_try_enroll() {
    if console_enroll_ok; then
        log "[enroll] console 已注册且正常，跳过 enroll"
        return 0
    fi
    re_enroll || log "[enroll] 自愈未成功（无注册码或 enroll 失败），下次开机再试"
}

main() {
    log "===== crowdsec-lxc-bootstrap v$SCRIPT_VER 开始（容器 $LXC_NAME）====="

    if [ ! -f "$TARBALL" ] && [ -f "$LEGACY_TARBALL" ]; then
        _unprotect_file "$TARBALL"
        mkdir -p "$CS_HOME" 2>/dev/null && mv -f "$LEGACY_TARBALL" "$TARBALL" 2>/dev/null \
            && log "镜像已从 $LEGACY_TARBALL 迁移到 $TARBALL"
    fi

    protect_key_files

    if [ ! -f "$TARBALL" ] && [ ! -f "$CROWDSEC_CFG" ]; then
        log "无镜像且无 rootfs，本机不带 CrowdSec，跳过"
        exit 0
    fi

    # 模式判定：此刻 rootfs 内 config.yaml 不存在 → 本次为「首次 / 恢复」
    # （含彻底删除容器后重建）。已存在则为「后续重启」。
    _recovering=false
    [ -f "$CROWDSEC_CFG" ] || _recovering=true

    mkdir -p "$LXC_PATH/$LXC_NAME" 2>/dev/null
    if [ ! -f "$CFG" ]; then
        write_cfg
        log "已写入容器 config"
    fi
    apply_cfg || { log "config 无法解析，放弃"; exit 1; }

    if [ ! -f "$CROWDSEC_CFG" ]; then
        log "rootfs 未就绪，从镜像解压"
        rebuild_from_image || { log "镜像解压失败"; exit 1; }
    fi

    setup_bridge
    prepare_container || { log "配置生成失败"; exit 1; }

    # 首次 / 恢复容器：安装前「直接屏蔽」CAPI（online_client off，使用屏蔽相同代码），
    # 让 LAPI 干净独立启动，避免中央 API 认证导致崩溃循环。
    # 后续重启模式不在此屏蔽——重启仅在 last pull 验证失败后才屏蔽（见末尾 CAPI 段）。
    if [ "$_recovering" = true ]; then
        ensure_online_client_off || log "[CAPI] 屏蔽(off)失败，继续"
    fi

    if [ -x /etc/init.d/lxc-auto ]; then
        /etc/init.d/lxc-auto enable >/dev/null 2>&1 || true
        if ! uci -q get lxc-auto.@container[0] >/dev/null 2>&1; then
            uci -q add lxc-auto container >/dev/null 2>&1 || true
            uci -q set lxc-auto.@container[-1].name="$LXC_NAME" >/dev/null 2>&1 || true
            uci -q set lxc-auto.@container[-1].timeout='300' >/dev/null 2>&1 || true
            uci -q commit lxc-auto >/dev/null 2>&1 || true
            log "已补写 lxc-auto UCI 配置（自启 $LXC_NAME）"
        fi
    fi

    log "启动容器 $LXC_NAME（经 lxc-auto）"
    if [ -x /etc/init.d/lxc-auto ]; then
        /etc/init.d/lxc-auto start >/dev/null 2>&1 || true
    fi
    if ! _wait_ct_running; then
        log "lxc-auto 首启未拉起，重试 lxc-auto"
        if [ -x /etc/init.d/lxc-auto ]; then
            /etc/init.d/lxc-auto start >/dev/null 2>&1 || true
        fi
        _wait_ct_running || { log "容器起不来"; exit 1; }
    fi
    log "容器已启动"

    setup_log_forward

    # ---------- bouncer 注册（安装步骤的一部分，幂等） ----------
    _sec=$(uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
    if [ -z "$_sec" ]; then
        uci add crowdsec bouncer >/dev/null 2>&1
        _sec=$(uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
    fi
    if [ -z "$_sec" ]; then
        log "/etc/config/crowdsec 无 bouncer 段，bouncer 包未装进固件"
    else
        uci -q set "$_sec.api_url=http://${CONTAINER_IP}:${LAPI_PORT}/"
        uci -q set "$_sec.enabled=1"
        uci -q set "$_sec.ipv4=1"
        uci -q set "$_sec.ipv6=0"
        uci -q set "$_sec.deny_action=drop"
        uci -q set "$_sec.filter_input=1"
        uci -q set "$_sec.filter_forward=1"
        uci -q del "$_sec.interface"
        uci add_list "$_sec.interface=br-lan"
        uci commit crowdsec

        if bouncer_pulling; then
            log "本地 bouncer 链路已通（last_pull 有效），跳过注册"
        else
            log "bouncer 链路未通（name 错位或 last_pull 空），执行重注册"
            _bouncer_heal 3 || log "bouncer 重注册 3 轮未全通，随下方 CAPI/LAPI 判定处理"
        fi
        _ensure_bouncer_service
    fi

    # ===================== CAPI 屏蔽 / 放出 + enroll =====================
    # 判据：LAPI 侧 bouncer 的 last_pull 是否有数据（bouncer_pulling）。
    if bouncer_pulling; then _lapi_ok=true; else _lapi_ok=false; fi

    if [ "$_recovering" = true ]; then
        # 首次 / 恢复容器：安装前已「直接屏蔽」(online_client off)。
        # 安装结束验证 LAPI Last Pull 有数据 → 解除屏蔽（放出，使用屏蔽相同代码）。
        if [ "$_lapi_ok" = true ]; then
            ensure_online_client_on || log "[CAPI] 放出失败，CAPI 维持屏蔽"
            log "[CAPI] 安装完成且 LAPI 健康，已解除屏蔽（放出 online_client）"
            _try_enroll
        else
            # 首次就拉不通：保持屏蔽，按流程诊断根因，损坏则重建
            ensure_online_client_off || true
            log "[CAPI] 首次安装后 LAPI 无 last pull，保持屏蔽并诊断"
            if _crowdsec_diagnose; then
                _crowdsec_rebuild || { log "[CAPI] rootfs 重装失败，放弃"; exit 1; }
                if bouncer_pulling; then
                    ensure_online_client_on || true
                    _try_enroll
                else
                    log "[CAPI] 重建后 LAPI 仍无 last pull，保持屏蔽"; exit 1
                fi
            else
                log "[CAPI] 诊断为非文件损坏（网络/服务），保持屏蔽，请检查 LAPI/8080"; exit 1
            fi
        fi
    else
        # 后续重启：都会验证 last pull；只有失败后 才屏蔽
        if [ "$_lapi_ok" = true ]; then
            # 正常：不屏蔽。放出 CAPI（幂等）后按需 enroll（enroll 在放出之后）
            ensure_online_client_on || true
            _try_enroll
        else
            # last pull 验证失败 → 屏蔽（使用屏蔽相同代码）
            ensure_online_client_off || true
            log "[CAPI] 重启检测到 last pull 失败，已屏蔽 online_client"
            # 按照流程查看日志等
            if _crowdsec_diagnose; then
                # 文件损坏 → 重建：确定重建则不再额外放出，重装后重新走验证/放出
                log "[CAPI] 诊断判定损坏，重建容器"
                _crowdsec_rebuild || { log "[CAPI] rootfs 重装失败，放弃"; exit 1; }
                if bouncer_pulling; then
                    ensure_online_client_on || true
                    _try_enroll
                else
                    log "[CAPI] 重建后 LAPI 仍无 last pull，保持屏蔽"; exit 1
                fi
            else
                # 网络/服务问题 → 放出屏蔽 + enroll（enroll 在放出之后）
                ensure_online_client_on || true
                log "[CAPI] 判定网络/服务问题，已放出屏蔽"
                _try_enroll
            fi
        fi
    fi

    sleep 3
    if nft_table_ready; then
        log "nftables crowdsec 表已建立，链路打通"
    else
        log "未看到 nft crowdsec 表，检查 bouncer 日志"
    fi
    log "引导结束"
    exit 0
}

main "$@"
