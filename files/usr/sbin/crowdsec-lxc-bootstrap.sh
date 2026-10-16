#!/bin/sh
SCRIPT_VER="2026-10-16.62"

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

ct_force_stop() {
    ct_running || return 0
    _r=0
    while [ "$_r" -lt 3 ]; do
        _r=$((_r+1))
        lxc-stop -P "$LXC_PATH" -n "$LXC_NAME" -k >/dev/null 2>&1
        _i=0
        while ct_running; do
            _i=$((_i+1))
            if [ "$_i" -ge 12 ]; then
                _pid="$(ct_pid)"
                [ -n "$_pid" ] && kill -9 "$_pid" 2>/dev/null
                sleep 1
            fi
            [ "$_i" -ge 24 ] && break
            sleep 2
        done
        ct_running || return 0
        [ "$_r" -ge 3 ] && break
        log "第 $_r 轮强制停止未成功，继续停止（最多 3 轮）"
        sleep 2
    done
    log "容器 3 轮强制停止仍未停止"
    return 1
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
        _dns=$(tr -d '\r' < /etc/config/custom_router_dns.txt | tr '\n' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
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

_bouncer_uci_apply() {
    _sec=$(uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
    if [ -z "$_sec" ]; then
        uci add crowdsec bouncer >/dev/null 2>&1
        _sec=$(uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
    fi
    [ -n "$_sec" ] || { log "/etc/config/crowdsec 无 bouncer 段，bouncer 包未装进固件"; return 1; }
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
    return 0
}

_wait_lapi_ready() {
    _lw_max="${1:-90}"
    _lw_i=0
    while [ "$_lw_i" -lt "$_lw_max" ]; do
        _lw_i=$((_lw_i+1))
        ct_running || { log "容器已停止，LAPI 等待中止"; return 1; }
        _ct_env "$CSCLI bouncers list -o json" >/dev/null 2>&1 && return 0
        [ $((_lw_i % 15)) -eq 0 ] && log "等待容器内 crowdsec LAPI 就绪（已等 ${_lw_i}s）"
        sleep 1
    done
    return 1
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

_TS_RE='[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]'

bouncer_pulling() {
    _lp="$(_ct_env "$CSCLI bouncers list" 2>/dev/null \
        | grep -E "^[[:space:]]*${BOUNCER_NAME}[[:space:]]" \
        | grep -oE "${_TS_RE}Z?" | head -n 1)"
    [ -n "$_lp" ] || return 1

    _max_age="${BOUNCER_PULL_MAX_AGE:-600}"
    case "$_max_age" in ''|*[!0-9]*) return 0 ;; esac
    [ "$_max_age" -gt 0 ] || return 0

    _now="$(_ct_env "date +%s" 2>/dev/null)"
    _at="$(_ct_env "date -d '$_lp' +%s" 2>/dev/null)"
    [ -n "$_now" ] && [ -n "$_at" ] || return 0
    if [ $(( _now - _at )) -gt "$_max_age" ]; then
        log "[bouncer] last_pull 停滞（$_lp，超过 ${_max_age}s），判定失效"
        return 1
    fi
    return 0
}

bouncer_exists() {
    _ct_env "$CSCLI bouncers list" 2>/dev/null | grep -qE "^[[:space:]]*${BOUNCER_NAME}[[:space:]]"
}

_restart_bouncer_service() {
    service crowdsec-firewall-bouncer enable 2>/dev/null
    service crowdsec-firewall-bouncer restart 2>/dev/null
    sleep 12
    return 0
}

_bouncer_heal() {
    _max="${1:-2}"
    _i=0
    while [ "$_i" -lt "$_max" ]; do
        _i=$((_i+1))
        _wait_lapi_ready 90 || true
        _bouncer_register_once || { log "[bouncer] 第 $_i/$_max 轮注册未拿到 key"; continue; }
        log "[bouncer] 新 key 已写入，刷新容器内 crowdsec 与路由器 bouncer 状态"
        _ct_env 'systemctl restart crowdsec >/dev/null 2>&1' || true
        _wait_lapi_ready 90 || true
        _restart_bouncer_service
        _ensure_bouncer_service
        _j=0
        while [ "$_j" -lt 12 ]; do
            _j=$((_j+1))
            bouncer_pulling && { log "[bouncer] 已恢复拉取（第 $_i 轮注册）"; return 0; }
            sleep 5
        done
        log "[bouncer] 第 $_i/$_max 轮注册后 last_pull 仍为空（已等 60s）"
    done
    return 1
}

_crowdsec_repair() {
    log "[修复] last pull 失败，开始修复：容器级施救 → 验证文件 → 对齐 bouncer → 刷新两端 → 重验"

    if ! ct_running; then
        log "[修复] 容器未运行，先做启动施救（不重建，失败交回上层）"
        _ct_revive 0 || { log "[修复] 容器起不来，放弃本条修复"; return 1; }
    elif ! _ct_env 'hostname -I 2>/dev/null' | grep -q "$CONTAINER_IP"; then
        log "[修复] 容器在运行但无 IP $CONTAINER_IP，重写网络配置并重启容器"
        setup_container_network || true
        setup_resolv || true
        ct_force_stop || true
        lxc-start -P "$LXC_PATH" -n "$LXC_NAME" -d >/dev/null 2>&1 || true
        _wait_ct_running || { log "[修复] 重启后容器未起来，放弃本条修复"; return 1; }
    fi

    setup_crowdsec_config || log "[修复] 容器侧配置校验未完全通过，继续后续步骤"
    _bouncer_uci_apply || log "[修复] 路由器侧 bouncer 配置异常，继续后续步骤"

    _wait_lapi_ready 90 || log "[修复] LAPI 未就绪，仍尝试注册"
    _bouncer_register_once || { log "[修复] 重新注册 bouncer 失败（拿不到 key）"; return 1; }

    _ct_env 'systemctl restart crowdsec >/dev/null 2>&1' || true
    service crowdsec-firewall-bouncer enable 2>/dev/null
    service crowdsec-firewall-bouncer restart 2>/dev/null

    _i=0
    while [ "$_i" -lt 6 ]; do
        _i=$((_i+1))
        bouncer_pulling && { log "[修复] last_pull 已恢复，链路修复成功"; return 0; }
        sleep 5
    done
    log "[修复] 重验后 last_pull 仍为空，修复无效"
    return 1
}

_crowdsec_rebuild() {
    if [ "${CS_REBUILT:-0}" = "1" ]; then
        log "[重装] 本次开机已重建过一次，不再重建（防止重启循环）"
        return 1
    fi
    [ -n "$_SELF" ] || { log "[重装] 拿不到脚本自身路径，放弃重建"; return 1; }
    log "[重装] 判定容器文件损坏：强制停止容器 → 删除容器 → 从脚本第一步重新开始"
    ct_force_stop || { log "[重装] 容器 3 轮强制停止仍失败，放弃重建"; return 1; }
    rm -rf "$ROOTFS" 2>/dev/null
    if [ -f "$CROWDSEC_CFG" ]; then
        log "[重装] rootfs 删除不彻底，强制删除残留文件"
        ct_force_stop || true
        if ct_running; then
            _pid="$(ct_pid)"
            if [ "$_pid" -gt 0 ] 2>/dev/null; then kill -9 "$_pid" 2>/dev/null; fi
        fi
        for _m in $(mount 2>/dev/null | awk -v r="$ROOTFS" '$3 ~ "^"r {print $3}'); do
            umount -l "$_m" 2>/dev/null
        done
        rm -rf "$ROOTFS" 2>/dev/null
    fi
    if [ -f "$CROWDSEC_CFG" ]; then
        log "[重装] rootfs 仍有残留，放弃重建（避免重跑误判为后续重启）"
        return 1
    fi
    export CS_REBUILT=1
    log "[重装] rootfs 已删除，重新执行脚本（走首次/恢复流程重装）"
    exec /bin/sh "$_SELF"
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

_try_enroll() {
    if console_enroll_ok; then
        log "[enroll] console 已注册且正常，跳过 enroll"
        return 0
    fi
    re_enroll || log "[enroll] 自愈未成功（无注册码或 enroll 失败），下次开机再试"
}

_mount_systemd_cgroup() {
    grep -q ' /sys/fs/cgroup/systemd ' /proc/mounts 2>/dev/null && return 0
    mkdir -p /sys/fs/cgroup/systemd 2>/dev/null
    if mount -t cgroup -o rw,nosuid,nodev,noexec,relatime,none,name=systemd cgroup /sys/fs/cgroup/systemd 2>/dev/null; then
        log "[cgroup] 已挂载 systemd 命名层级（容器内 systemd 需要）"
    else
        log "[cgroup] systemd 层级挂载失败，容器内 systemd 可能异常"
    fi
}

_ct_revive() {
    _rb="${1:-1}"
    log "[施救] 容器启动修复链（补挂 cgroup → 重写 config 重启 → 验活）"

    _mount_systemd_cgroup

    log "[施救] 强停残留 → 重写容器 config → 重启"
    ct_force_stop || true
    write_cfg || true
    lxc-start -P "$LXC_PATH" -n "$LXC_NAME" -d >/dev/null 2>&1 || true
    if _wait_ct_running; then
        log "[施救] 重写 config 后容器已拉起"
        return 0
    fi

    if [ "$_rb" = "1" ]; then
        log "[施救] 重写 config 仍无效，判定 rootfs 损坏，重建重装"
        _crowdsec_rebuild || { log "[施救] 重建失败，引导终止"; return 1; }
        return 0
    fi
    return 1
}

main() {
    log "===== crowdsec-lxc-bootstrap v$SCRIPT_VER 开始（容器 $LXC_NAME）====="

    if [ ! -f "$TARBALL" ] && [ -f "$LEGACY_TARBALL" ]; then
        mkdir -p "$CS_HOME" 2>/dev/null && mv -f "$LEGACY_TARBALL" "$TARBALL" 2>/dev/null \
            && log "镜像已从 $LEGACY_TARBALL 迁移到 $TARBALL"
    fi

    if [ ! -f "$TARBALL" ] && [ ! -f "$CROWDSEC_CFG" ]; then
        log "无镜像且无 rootfs，本机不带 CrowdSec，跳过"
        exit 0
    fi

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

    if [ "$_recovering" = true ]; then
        ensure_online_client_off || log "[CAPI] 屏蔽(off)失败，继续"
    fi

    if [ -x /etc/init.d/lxc-auto ]; then
        /etc/init.d/lxc-auto disable >/dev/null 2>&1 || true
        log "已禁用 lxc-auto 开机自启（容器启动由本脚本直接负责，v.56 起弃用 lxc-auto）"
    fi

    log "启动容器 $LXC_NAME"
    _mount_systemd_cgroup
    lxc-start -P "$LXC_PATH" -n "$LXC_NAME" -d >/dev/null 2>&1 || true
    if ! _wait_ct_running; then
        log "首启未拉起，重试 lxc-start -d"
        lxc-start -P "$LXC_PATH" -n "$LXC_NAME" -d >/dev/null 2>&1 || true
        if ! _wait_ct_running; then
            _ct_revive || { log "容器启动修复链无效，引导失败"; exit 1; }
        fi
    fi
    log "容器已启动"

    log "等待容器内 crowdsec LAPI 就绪"
    _wait_lapi_ready 90 || log "警告：LAPI 90 秒未就绪，bouncer 注册可能失败"

    setup_log_forward

    if _bouncer_uci_apply; then
        if bouncer_pulling; then
            log "本地 bouncer 链路已通（last_pull 有效），跳过注册"
        else
            log "bouncer 链路未通（name 错位或 last_pull 空），执行重注册"
            _bouncer_heal 2 || log "bouncer 重注册 2 轮未全通，随下方 CAPI 段修复处理"
        fi
        _ensure_bouncer_service
    fi

    if bouncer_pulling; then
        ensure_online_client_on || log "[CAPI] 放出失败，CAPI 维持屏蔽"
        log "[CAPI] LAPI 健康（last_pull 有效），已放出 online_client"
        _try_enroll
    else
        ensure_online_client_off || true
        log "[CAPI] last pull 失败，已屏蔽 online_client"
        if _crowdsec_repair; then
            ensure_online_client_on || log "[CAPI] 放出失败，CAPI 维持屏蔽"
            log "[CAPI] 修复成功，LAPI 链路恢复，已放出 online_client"
            _try_enroll
        else
            log "[CAPI] 修复无效，重建容器"
            _crowdsec_rebuild || { log "[CAPI] 重建未执行/失败，放弃"; exit 1; }
            log "[CAPI] 重建后脚本未重跑（异常），保持屏蔽"; exit 1
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
