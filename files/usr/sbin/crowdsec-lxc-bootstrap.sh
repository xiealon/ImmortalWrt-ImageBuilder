#!/bin/sh
SCRIPT_VER="2026-10-15.23"

LXC_NAME="${LXC_NAME:-ubuntu}"
CS_HOME="${CS_HOME:-/etc/crowdsec}"
LXC_PATH="${LXC_PATH:-/srv/lxc}"
ROOTFS="$LXC_PATH/$LXC_NAME/rootfs"
CFG="$LXC_PATH/$LXC_NAME/config"
TARBALL="${TARBALL:-$CS_HOME/lxc-ubuntu.tar.gz}"
LEGACY_TARBALL="/opt/lxc-ubuntu.tar.gz"
BASELINE="$CS_HOME/baseline"
STATE_FILE="$BASELINE/STATE"
LAPI_PORT="${LAPI_PORT:-8080}"
BOUNCER_NAME="${BOUNCER_NAME:-openwrt-fw}"
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
ct_force_stop() {
    _pid="$(ct_pid)"
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
        [ "$_i" -ge 24 ] && { log "[步骤1] 容器无法停止，跳过重建"; return 1; }
        sleep $SLEEP
    done
    return 0
}
_pgrep_bouncer() { pgrep -f "crowdsec-firewall-bouncer" >/dev/null 2>&1; }
_ct_env() { ct sh -c 'export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; '"$1"; }

cs_active_on_host() { _pgrep_bouncer; }
nft_table_ready() { nft list table ip crowdsec >/dev/null 2>&1; }

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
lxc.start.auto = 1
lxc.start.order = 10
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
    log "[步骤1] 尝试从镜像重建 rootfs：$TARBALL"
    [ -f "$TARBALL" ] || { log "[步骤1] 镜像文件不存在，无法重建"; return 1; }
    ct_force_stop || return 1
    rm -rf "$ROOTFS" 2>/dev/null
    mkdir -p "$ROOTFS" || return 1
    if ( set -C; : > "$ROOTFS/.extracting" ) 2>/dev/null; then
        if tar -xzf "$TARBALL" -C "$ROOTFS"; then
            rm -f "$ROOTFS/.extracting"
            log "[步骤1] 重建完成（$(du -sh "$ROOTFS" 2>/dev/null | cut -f1)）"
            return 0
        fi
        rm -f "$ROOTFS/.extracting"
        log "[步骤1] 解压失败"
        return 1
    fi
    log "[步骤1] 另一实例正在解压，等待完成"
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

bouncer_last_pull() {
    _ct_env "$CSCLI bouncers inspect \"$BOUNCER_NAME\" -o json" 2>/dev/null \
        | sed -n 's/.*"last_pull"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -n1
}

bouncer_pulling() {
    _lp="$(bouncer_last_pull)"
    [ -n "$_lp" ] && [ "$_lp" != "null" ]
}

host_bouncer_ok() {
    _yaml="/tmp/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml"
    _log="/tmp/log/crowdsec-firewall-bouncer.log"
    [ -f "$_yaml" ] || { log "[bouncer] 宿主机 bouncer 配置文件缺失: $_yaml"; return 1; }
    grep -qE '^[[:space:]]*api_key:[[:space:]]*[A-Za-z0-9+/=_-]{16,}' "$_yaml" || { log "[bouncer] 宿主机 bouncer api_key 为空或非明文"; return 1; }
    if [ -f "$_log" ]; then
        grep -qiE "forbidden|unauthorized|connection refused|dial tcp|401|403" "$_log" && { log "[bouncer] 宿主机 bouncer 日志存在认证/连接错误"; return 1; }
    fi
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

write_state_mark() {
    _sec=$(uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
    _key=""
    [ -n "$_sec" ] && _key="$(uci -q get "$_sec.api_key" 2>/dev/null)"
    [ -n "$_key" ] || { log "[标记] api_key 为空，不写稳定态标记"; return 1; }

    mkdir -p "$BASELINE" 2>/dev/null || { log "[标记] 无法创建 $BASELINE"; return 1; }
    cat > "$STATE_FILE" <<EOF
VER=$SCRIPT_VER
TIME=$(date '+%F %T')
CONTAINER=$LXC_NAME
CONTAINER_IP=$CONTAINER_IP
BRIDGE_IP=$BRIDGE_IP
LAPI_PORT=$LAPI_PORT
API_URL=$(uci -q get "$_sec.api_url" 2>/dev/null)
UCI_SECTION=$_sec
EOF
    log "[标记] 稳定态标记已写入 $STATE_FILE"
    return 0
}

mount_cgroup() {
    if mountpoint -q /sys/fs/cgroup 2>/dev/null; then
        log "[准备] cgroup 已挂载"
        return 0
    fi
    mkdir -p /sys/fs/cgroup
    if mount -t cgroup2 none /sys/fs/cgroup 2>/dev/null; then
        log "[准备] cgroup2 已挂载"
    else
        log "[准备] cgroup2 挂载失败（可能内核已挂载或不支持）"
    fi
    return 0
}

setup_syslog_forward() {
    [ -n "$CONTAINER_IP" ] || return 0
    uci set system.@system[0].log_ip="${CONTAINER_IP}"
    uci set system.@system[0].log_port='514'
    uci set system.@system[0].log_proto='udp'
    uci -q set system.@system[0].log_remote='1'
    uci -q set system.@system[0].cronloglevel='5'
    uci commit system
    /etc/init.d/log restart >/dev/null 2>&1
    log "[日志] 宿主 syslog 已外发至 ${CONTAINER_IP}:514/udp"
    return 0
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

baseline_valid() {
    [ -f "$STATE_FILE" ] || return 1
    grep -q '^VER=' "$STATE_FILE" 2>/dev/null || return 1
    return 0
}


_bouncer_register_once() {
    _ct_env "$CSCLI bouncers delete \"$BOUNCER_NAME\"" >/dev/null 2>&1 || true
    _raw=$(_ct_env "$CSCLI bouncers add \"$BOUNCER_NAME\" -o raw" 2>&1)
    _key=$(printf '%s\n' "$_raw" | sed -e 's/\r$//' \
           | grep -Eo '^[A-Za-z0-9+/=_-]{16,}$' | tail -n1)
    [ -n "$_key" ] || return 1
    _sec=$(uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
    [ -n "$_sec" ] || return 1
    uci set "$_sec.api_key=$_key"
    uci commit crowdsec
    return 0
}

_bouncer_heal() {
    _max="${1:-5}"
    _i=0
    while [ "$_i" -lt "$_max" ]; do
        _i=$((_i+1))
        if _bouncer_register_once; then
            _ensure_bouncer_service
            _j=0
            while [ "$_j" -lt 3 ]; do
                _j=$((_j+1))
                bouncer_pulling && { log "[自愈] bouncer 已恢复拉取（第 $_i 轮注册）"; return 0; }
                sleep 5
            done
            log "[自愈] 第 $_i/$_max 轮重注册后 last_pull 仍为空"
        else
            log "[自愈] 第 $_i/$_max 轮注册未拿到 key"
        fi
    done
    return 1
}

diag_bouncer() {
    log "[诊断] ---- bouncer 异常排查 ----"

    log "[诊断] 1) 解析器："
    _ct_env "$CSCLI parsers list -o json 2>/dev/null | grep -c '\"name\"'" 2>/dev/null \
        | sed 's/^/  parsers 数量: /'
    _ct_env "[ -f /etc/crowdsec/parsers/s01-parse/openwrt-dropbear.yaml ] && echo '  openwrt-dropbear.yaml 在位' || echo '  openwrt-dropbear.yaml 缺失'" 2>/dev/null

    log "[诊断] 2) 宿主机（openwrt）网络："
    if ip link show lxcbr0 >/dev/null 2>&1; then
        echo "  lxcbr0 存在: $(ip -4 addr show lxcbr0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -n1)"
    else
        echo "  lxcbr0 缺失"
    fi

    log "[诊断] 3) LXC 容器网络："
    _ct_env "ip -4 addr show eth0 2>/dev/null | sed -n 's/.*inet \\([0-9.]*\\)\\/.*/  eth0: \\1/p'" 2>/dev/null

    log "[诊断] 4) LAPI 端口 $LAPI_PORT："
    if _ct_env "timeout 5 bash -c '</dev/tcp/${CONTAINER_IP}/${LAPI_PORT}'" 2>/dev/null; then
        echo "  ${CONTAINER_IP}:${LAPI_PORT} 可连"
    else
        echo "  ${CONTAINER_IP}:${LAPI_PORT} 不通"
    fi

    log "[诊断] 5) bouncer 状态："
    _ct_env "$CSCLI bouncers list" 2>/dev/null | sed 's/^/  /'

    log "[诊断] 6) 宿主机 bouncer 配置文件："
    _yaml="/tmp/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml"
    if [ -f "$_yaml" ]; then
        grep -E '^[[:space:]]*(api_url|api_key):' "$_yaml" | sed 's/^/  /'
    else
        echo "  缺失: $_yaml"
    fi

    log "[诊断] 7) 宿主机 bouncer 日志（末 5 行）："
    _log="/tmp/log/crowdsec-firewall-bouncer.log"
    if [ -f "$_log" ]; then
        tail -5 "$_log" | sed 's/^/  /'
    else
        echo "  缺失: $_log"
    fi
    log "[诊断] ---- 排查结束 ----"
}

self_check() {
    SELF_CT=0; SELF_PULL=0; SELF_ALL=0

    ct_running && SELF_CT=1
    bouncer_pulling && SELF_PULL=1

    [ "$SELF_CT" = "1" ] && [ "$SELF_PULL" = "1" ] && SELF_ALL=1

    log "[自检] 容器=$([ "$SELF_CT" = "1" ] && echo 运行 || echo 停止)"
    log "[自检] bouncer last_pull=$([ "$SELF_PULL" = "1" ] && echo 正常 || echo 空)"
    return 0
}

main() {
    log "===== crowdsec-lxc-bootstrap v$SCRIPT_VER 开始（容器 $LXC_NAME）====="

    if [ ! -f "$TARBALL" ] && [ -f "$LEGACY_TARBALL" ]; then
        mkdir -p "$CS_HOME" 2>/dev/null && mv -f "$LEGACY_TARBALL" "$TARBALL" 2>/dev/null \
            && log "镜像已从 $LEGACY_TARBALL 迁移到 $TARBALL"
    fi

    mount_cgroup
    setup_syslog_forward

    if baseline_valid; then
        FIRST_BOOT=0
        log "判定文件齐全，非首次开机"
    else
        FIRST_BOOT=1
        log "判定文件缺失，认定为第一次开机"
    fi

    if [ ! -f "$TARBALL" ] && [ ! -f "$CROWDSEC_CFG" ]; then
        log "无镜像且无 rootfs，本机不带 CrowdSec，跳过"
        exit 0
    fi

    if ! ct_exists || [ ! -f "$CROWDSEC_CFG" ]; then
        log "容器或 rootfs 未就绪，从镜像重建"
        rebuild_from_image || { log "镜像重建失败"; exit 1; }
    fi

    if ! ct_running; then
        setup_bridge
        prepare_container || true
        if ! lxc-start -P "$LXC_PATH" -n "$LXC_NAME" -d 2>/dev/null || ! _wait_ct_running; then
            log "容器起不来，用镜像重建后重试"
            rebuild_from_image && prepare_container || true
            lxc-start -P "$LXC_PATH" -n "$LXC_NAME" -d 2>/dev/null
            _wait_ct_running || { log "重建后仍起不来"; exit 1; }
        fi
        log "容器已启动"
    fi

    prepare_container || true

    if [ -f /etc/config/crowdsec ]; then
        _sec=$(uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
        if [ -z "$_sec" ]; then
            uci add crowdsec bouncer >/dev/null 2>&1
            _sec=$(uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
        fi
        if [ -n "$_sec" ]; then
            uci set "$_sec.enabled=1"
            uci set "$_sec.api_url=http://${CONTAINER_IP}:${LAPI_PORT}/"
            uci set "$_sec.ipv4=1"
            uci set "$_sec.ipv6=0"
            uci set "$_sec.deny_action=drop"
            uci set "$_sec.filter_input=1"
            uci set "$_sec.filter_forward=1"
            uci -q del "$_sec.interface"
            uci add_list "$_sec.interface=br-lan"
            uci commit crowdsec
            log "[配置] bouncer 段已预填（api_url=http://${CONTAINER_IP}:${LAPI_PORT}/）"
        fi
    else
        log "[配置] /etc/config/crowdsec 不存在，bouncer 包未装进固件"
    fi

    self_check

    if [ "$SELF_ALL" = "1" ]; then
        log "两项自检全部通过，跳过修复流程"
        R1=0
    else
        if [ "$SELF_CT" = "0" ]; then
            log "容器仍未运行，重建"
            rebuild_from_image && prepare_container || true
            lxc-start -P "$LXC_PATH" -n "$LXC_NAME" -d 2>/dev/null
            _wait_ct_running || { log "重建后仍起不来"; exit 1; }
        fi

        if [ "$SELF_PULL" = "0" ]; then
            log "bouncer 未拉取，进入自愈"
            diag_bouncer
            if host_bouncer_ok; then
                log "宿主机 bouncer 配置/日志正常，仅重注册恢复"
                if _bouncer_heal 5; then
                    :
                else
                    log "重注册 5 轮仍失败，判定本地 API 链路损坏，用镜像重建"
                    rebuild_from_image && prepare_container || true
                    lxc-start -P "$LXC_PATH" -n "$LXC_NAME" -d 2>/dev/null
                    _wait_ct_running || { log "重建后仍起不来"; exit 1; }
                    _bouncer_register_once || true
                    _ensure_bouncer_service
                fi
            else
                log "宿主机 bouncer 配置/日志异常，用镜像重建"
                rebuild_from_image && prepare_container || true
                lxc-start -P "$LXC_PATH" -n "$LXC_NAME" -d 2>/dev/null
                _wait_ct_running || { log "重建后仍起不来"; exit 1; }
                _bouncer_register_once || true
                _ensure_bouncer_service
            fi
        fi

        self_check
        [ "$SELF_CT" = "1" ] && [ "$SELF_PULL" = "1" ] && R1=0 || R1=1
    fi

    if [ "$R1" = "0" ] && [ "$FIRST_BOOT" = "1" ]; then
        write_state_mark; R3=$?
    elif [ "$R1" = "0" ]; then
        log "已有稳定态标记，跳过"
        R3=0
    else
        R3=1
    fi

    log "----- 汇总 -----"
    log "容器+本地=$R1 标记=$R3"

    _final_key=""
    _final_sec=$(uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
    [ -n "$_final_sec" ] && _final_key="$(uci -q get "$_final_sec.api_key" 2>/dev/null)"
    if [ -z "$_final_key" ]; then
        log "终局检查失败：api_key 仍为空"
        exit 1
    fi
    log "终局检查通过：api_key 已就绪（$R1$R3）"
    exit 0
}

main "$@"
