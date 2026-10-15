#!/bin/sh
# =============================================================================
# /usr/sbin/crowdsec-lxc-bootstrap.sh
# 由 /etc/rc.local 后台拉起，每次开机跑一遍，幂等安全。
#
# 步骤（线性，每步包在 if 内只验证自己的前置条件）：
#   前置  容器 config 校验（缺失或与模板不一致才 reconcile）
#   步骤1 解压镜像（仅首次）→ 生成配置 → 启动容器 → 注册 bouncer（本地，不联网）
#   步骤2 控制台绑定 enroll（远程，联网；仅 console status 异常时才做）
#   收尾  检查 nft 表
#
# 纯净镜像原则：镜像编译期只 apt 装 crowdsec，不写定制配置；
# 网络/解析器/listen_uri/trusted_ips 等全部在本脚本运行期生成。
# =============================================================================
SCRIPT_VER="2026-10-16.30"

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

# ---------- 网桥 / 防火墙 ----------
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

# ---------- 宿主机系统日志 → 容器 CrowdSec 转发 ----------
# 问题背景：CrowdSec 在容器内通过 acquis.d/router.yaml 监听 0.0.0.0:514/udp
# 收 syslog，但宿主机 OpenWrt 的 logd 默认只写本地环形缓冲，不会主动把
# dropbear 等日志推给容器，导致 CrowdSec 采集不到 ssh 暴力破解日志，
# 检测完全失效（之前 logread 一直报 "Failed to send log data to 10.0.0.10:514"）。
#
# 解决：配置 OpenWrt logd 的远程日志转发，把系统日志经 UDP 514 发到容器。
#   system.@system[0].log_ip     = 容器 IP
#   system.@system[0].log_port   = 514
#   system.@system[0].log_proto  = udp
#   system.@system[0].log_remote = 1
setup_log_forward() {
    [ -n "$CONTAINER_IP" ] || { log "[日志] 无容器 IP，跳过转发配置"; return 1; }

    _sys=$(uci show system 2>/dev/null | grep '=system$' | head -n1 | cut -d= -f1)
    if [ -z "$_sys" ]; then
        uci add system system >/dev/null 2>&1
        _sys=$(uci show system 2>/dev/null | grep '=system$' | head -n1 | cut -d= -f1)
    fi
    [ -n "$_sys" ] || { log "[日志] 无 system 段，无法配置远程日志"; return 1; }

    # 幂等：仅当目标/端口/协议/开关任一项不匹配时才写入并重载
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

# ---------- 容器 config ----------
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

# ---------- 镜像解压（仅首次） ----------
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

# ---------- 运行期生成配置 ----------
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

# 关键：LAPI 启动前必须关掉 online_client，否则 crowdsec 启动时会强制
# authenticate watcher 去 api.crowdsec.net 登录；容器 DNS 一旦不通（走
# 宿主网桥 dnsmasq），就会 FATAL 崩溃循环，8080 永远起不来。
# 注释掉 online_client 块后，本地 LAPI 独立工作；远程 enroll 用
# cscli console enroll 单独建立凭据，二者互不影响。
#
# 注意（重要教训）：config.yaml 里有两处 credentials_path，语义完全不同：
#   api.client.credentials_path  -> 指向 local_api_credentials.yaml（本地 LAPI，
#                                    bouncer 靠它连，绝不能被注释，否则报
#                                   "no API client section" 起不来）
#   api.server.online_client.credentials_path -> 指向 online_api_credentials.yaml
#                                   （中央 API，才是我们要关的）
#
# 正确做法：注释 online_client: 这一行 + 它下面缩进更深的 credentials_path
# 子行（两者必须一起注释，否则子行悬空导致 YAML "value is not allowed"）。
# 绝不去动 api.client 段（缩进较浅的）的 credentials_path。
ensure_online_client_off() {
    [ -f "$CROWDSEC_CFG" ] || { log "[配置] config.yaml 缺失"; return 1; }

    # 用 sed 精确处理 online_client 块（busybox sed 支持 \1 反向引用）：
    #   1) 注释 online_client 行本身
    #   2) 注释紧随其后的 credentials_path 子行（缩进比 online_client 更深）。
    #      用 \1 保留原有缩进，只把行首的 "credentials_path:" 改成
    #      "# credentials_path:"，这样无论原文件是 4/6 空格还是 tab 都能正确
    #      注释，且不会改变缩进风格。
    # 只动这两行，绝不影响 api.client 段（其 credentials_path 缩进较浅）。
    sed -i -E \
        -e "s|^([[:space:]]*)online_client:.*|\\1# online_client: # Central API credentials disabled by bootstrap|" \
        -e "s|^([[:space:]]*)credentials_path:.*online_api_credentials.yaml.*|\\1# credentials_path: /etc/crowdsec/online_api_credentials.yaml|" \
        "$CROWDSEC_CFG" 2>/dev/null

    # 反向修复：若 api.client 段的 credentials_path 被历史坏 sed 误注释，
    # 必须恢复，否则 crowdsec 报 "no API client section" 起不来。
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

setup_crowdsec_config() {
    setup_acquis || return 1
    ensure_listen_uri || return 1
    ensure_trusted_ip || return 1
    ensure_online_client_off || return 1
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

# ---------- 本地 bouncer 注册 ----------
# 注意：_ct_env 内部已经是 sh -c '...'，这里不能再给 $BOUNCER_NAME 加
# 转义引号，否则名字会被多层 shell 剥离，cscli 收不到 name 参数，
# 注册出来的 bouncer 名字会变成 "1"（-o raw 输出的 id 被误当名字）。
# BOUNCER_NAME 默认 openwrt-fw，无空格/特殊字符，直接拼接是安全的。
_bouncer_register_once() {
    # 先清理：删掉名字为 $BOUNCER_NAME 的旧记录，再删掉名字非法的残留记录
    # （历史上引号 bug 会注册出 name="1" 的坏记录，若不清理会一直干扰）。
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

# 读取 LAPI 侧 bouncer 状态（cscli bouncers list -o json），判断本地
# bouncer 是否真的拉取成功。返回 0 表示链路通，非 0 表示需要重注册。
# 判据：存在 name == $BOUNCER_NAME 的记录，且该记录的 last_pull 非空。
# 实现：cscli 的 json 输出每个 bouncer 对象是连续的多行，name 与 last_pull
# 各自独占一行（缩进固定），因此用「遇到 name 行锁定当前对象 → 后续遇到
# last_pull 行判断是否非空」的逐行状态机来匹配，避免同行贪婪匹配的坑。
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

# 判断 LAPI 侧是否存在名为 $BOUNCER_NAME 的 bouncer（不管 last_pull）。
bouncer_exists() {
    _ct_env "$CSCLI bouncers list -o json" 2>/dev/null | grep -q "\"name\":[[:space:]]*\"$BOUNCER_NAME\""
}

# 本地 bouncer 注册 + 服务拉起 + 拉取验证的完整闭环。
# 返回 0 表示 bouncer 已能正常拉取，非 0 表示重试后仍失败。
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

# ---------- 远程 console enroll ----------
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
    _ct_env '/usr/bin/cscli console enable --all >/dev/null 2>&1' || true

    _i=0
    while [ "$_i" -lt 6 ]; do
        _i=$((_i+1))
        if console_enroll_ok; then
            log "[自愈] re-enroll 成功，console 状态恢复正常"
            return 0
        fi
        sleep 5
    done

    [ -n "$_bak" ] && mv -f "$_bak" "$_cred_file"
    log "[自愈] re-enroll 复检未通过，已回滚旧凭据"
    return 1
}

# ---------- 主流程 ----------
main() {
    log "===== crowdsec-lxc-bootstrap v$SCRIPT_VER 开始（容器 $LXC_NAME）====="

    # 旧镜像路径迁移
    if [ ! -f "$TARBALL" ] && [ -f "$LEGACY_TARBALL" ]; then
        mkdir -p "$CS_HOME" 2>/dev/null && mv -f "$LEGACY_TARBALL" "$TARBALL" 2>/dev/null \
            && log "镜像已从 $LEGACY_TARBALL 迁移到 $TARBALL"
    fi

    # 无镜像且无 rootfs，本机不带 CrowdSec，跳过
    if [ ! -f "$TARBALL" ] && [ ! -f "$CROWDSEC_CFG" ]; then
        log "无镜像且无 rootfs，本机不带 CrowdSec，跳过"
        exit 0
    fi

    # 步骤0：config 就绪（缺失才写）
    mkdir -p "$LXC_PATH/$LXC_NAME" 2>/dev/null
    if [ ! -f "$CFG" ]; then
        write_cfg
        log "已写入容器 config"
    fi
    apply_cfg || { log "config 无法解析，放弃"; exit 1; }

    # 步骤1：解压镜像（仅首次，rootfs 无 crowdsec 时）
    if [ ! -f "$CROWDSEC_CFG" ]; then
        log "rootfs 未就绪，从镜像解压"
        rebuild_from_image || { log "镜像解压失败"; exit 1; }
    fi

    # 步骤1：生成配置（运行期，幂等）
    setup_bridge
    prepare_container || { log "配置生成失败"; exit 1; }

    # 步骤1：启动容器（每次开机都拉起，already running 容错）
    log "启动容器 $LXC_NAME"
    lxc-start -P "$LXC_PATH" -n "$LXC_NAME" -d 2>/dev/null || true
    _wait_ct_running || { log "容器起不来"; exit 1; }
    log "容器已启动"

    # 步骤1.5：配置宿主机系统日志 → 容器 CrowdSec（514/udp）
    setup_log_forward

    # 步骤1：注册 bouncer（以「LAPI 侧 last_pull 是否成功」为判据，
    # 而不是只看本地 UCI 有没有 key。避免 LAPI 侧记录错位/名字错成"1"
    # 或 key 失配时，本地有 key 就盲目跳过，导致 bouncer 一直拉不到数据）
    _sec=$(uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
    if [ -z "$_sec" ]; then
        uci add crowdsec bouncer >/dev/null 2>&1
        _sec=$(uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
    fi
    if [ -z "$_sec" ]; then
        log "/etc/config/crowdsec 无 bouncer 段，bouncer 包未装进固件"
    else
        # 先固化 bouncer 的 api_url 等基础字段（幂等）
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

        # 判据：LAPI 侧 bouncer 能否正常拉取（last_pull 有值）
        if bouncer_pulling; then
            log "本地 bouncer 链路已通（last_pull 有效），跳过注册"
        else
            log "bouncer 链路未通（name 错位或 last_pull 空），执行重注册"
            _bouncer_heal 3 || { log "bouncer 重注册 3 轮仍失败，请检查 LAPI/8080"; exit 1; }
        fi
        _ensure_bouncer_service
    fi

    # 步骤2：enroll（仅 console status 异常时）
    if console_enroll_ok; then
        log "console 状态正常，跳过 enroll"
    else
        re_enroll || log "console 自愈未成功（无注册码或 enroll 失败），下次开机再试"
    fi

    # 收尾：nft 表检查
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
