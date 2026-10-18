#!/bin/sh
SCRIPT_VER="2026-10-18.75"

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

# 容器网段（/24）唯一推导处：由 CONTAINER_IP 取前三段，SNAT src_ip 等处统一调用
_lxc_net() {
    echo "$CONTAINER_IP" | awk -F. '{print $1"."$2"."$3".0/24"}'
}

# 出口 IP 唯一取值处：先 uci lan.ipaddr，再 custom_router_ip.txt，最后兜底
_lan_ip() {
    _si=$(uci -q get network.lan.ipaddr 2>/dev/null)
    [ -n "$_si" ] || { [ -f /etc/config/custom_router_ip.txt ] && _si=$(head -n1 /etc/config/custom_router_ip.txt | tr -d ' \t\r\n'); }
    [ -n "$_si" ] || _si='192.168.3.201'
    echo "$_si"
}

# 读取 custom_*.txt 首行（编译期 Actions 写入 /etc/config，运行时可改文件免重编译）
_read_netconf() {
    [ -f "/etc/config/$1" ] || return 0
    head -n1 "/etc/config/$1" | tr -d ' \t\r\n'
}

# 管理地址期望值唯一推导处（自 99-custom.sh 同源搬迁，v.75 起由 bootstrap 每次开机按需校准）
# 输出一行四值：IP NETMASK GATEWAY DNS；推导规则与原 99-custom.sh 完全一致：
#   默认 10.1.1.201/24（网关 DNS 按 /24 推 .1）；自定义 IP + /24 → 同规则推导；
#   自定义 IP + 非 /24 → 不推导网关（保持默认，提示显式填 custom_router_gateway）；
#   custom_router_gateway/dns.txt 显式传入时优先级最高
_lan_static_conf() {
    _ls_ip='10.1.1.201'
    _ls_nm="$(_read_netconf custom_router_netmask.txt)"
    [ -n "$_ls_nm" ] || _ls_nm='255.255.255.0'
    _ls_gw='10.1.1.1'
    _ls_dn='10.1.1.1'
    _ls_uip="$(_read_netconf custom_router_ip.txt)"
    if [ -n "$_ls_uip" ]; then
        _ls_ip="$_ls_uip"
        if [ "$_ls_nm" = "255.255.255.0" ]; then
            _ls_gw="$(echo "$_ls_ip" | awk -F. '{print $1"."$2"."$3".1"}')"
            _ls_dn="$_ls_gw"
        fi
    fi
    _ls_ugw="$(_read_netconf custom_router_gateway.txt)"
    if [ -n "$_ls_ugw" ]; then
        _ls_gw="$_ls_ugw"
        [ -n "$(_read_netconf custom_router_dns.txt)" ] || _ls_dn="$_ls_ugw"
    fi
    _ls_udn="$(_read_netconf custom_router_dns.txt)"
    [ -n "$_ls_udn" ] && _ls_dn="$_ls_udn"
    echo "$_ls_ip $_ls_nm $_ls_gw $_ls_dn"
}

# 物理网口列表：排除 lo/虚拟/桥接，规则与 99-custom.sh 组桥同源（唯一出处）
# 用于 WAN-input 放行定责：单网口才需放行，多网口必有一个在 LAN，无需放行
_phys_ports() {
    ls /sys/class/net/ 2>/dev/null | grep -E '^(eth|en|lan)' | grep -v -E '(lo|docker|veth|br-|tun|tap)'
}
_phys_port_count() { _phys_ports | wc -l | tr -d ' '; }

# 按职责(name)定位 firewall zone 的 section 名，不赌 @zone[N] 索引
# （索引会因其他包 insert zone / 定制改序而漂移，name 才是稳定职责标识）
_zone_sec() {
    for _z in $(uci show firewall 2>/dev/null | grep -E '=zone$' | cut -d. -f2 | cut -d= -f1); do
        [ "$(uci -q get firewall.$_z.name 2>/dev/null)" = "$1" ] && { echo "$_z"; return 0; }
    done
    return 1
}

# 网络模式唯一取值处：custom_router_mode.txt（编译期 Actions 写入，运行时可改文件）
# gw=主路由 / bypass=旁路单臂 / 缺省或非法值=auto（按物理网口数推定）
_router_mode() {
    _m=""
    [ -f /etc/config/custom_router_mode.txt ] && _m=$(head -n1 /etc/config/custom_router_mode.txt | tr -d ' \t\r\n')
    case "$_m" in
        gw|bypass) echo "$_m"; return 0 ;;
    esac
    if [ "$(_phys_port_count)" -ge 2 ]; then echo gw; else echo bypass; fi
}

# lxc 防火墙区独立验证（5 项）
verify_lxc_zone() {
    [ "$(uci -q get firewall.lxczone.name)" = "lxc" ] || return 1
    [ "$(uci -q get firewall.lxczone.network)" = "lxc" ] || return 1
    [ "$(uci -q get firewall.lxczone.input)" = "ACCEPT" ] || return 1
    [ "$(uci -q get firewall.lxczone.output)" = "ACCEPT" ] || return 1
    [ "$(uci -q get firewall.lxczone.forward)" = "ACCEPT" ] || return 1
}

# lxc 转发规则独立验证（8 项：lxc2lan/lxc2docker/lxc2vpn/lan2lxc）
verify_fwd_rules() {
    [ "$(uci -q get firewall.lxc2lan.src)" = "lxc" ] || return 1
    [ "$(uci -q get firewall.lxc2lan.dest)" = "lan" ] || return 1
    [ "$(uci -q get firewall.lxc2docker.src)" = "lxc" ] || return 1
    [ "$(uci -q get firewall.lxc2docker.dest)" = "docker" ] || return 1
    [ "$(uci -q get firewall.lxc2vpn.src)" = "lxc" ] || return 1
    [ "$(uci -q get firewall.lxc2vpn.dest)" = "vpn" ] || return 1
    [ "$(uci -q get firewall.lan2lxc.src)" = "lan" ] || return 1
    [ "$(uci -q get firewall.lan2lxc.dest)" = "lxc" ] || return 1
}

# SNAT 规则独立验证（6 项：src_ip=容器网段、snat_ip=出口IP，期望值现场推导比对）
verify_snat_rule() {
    [ "$(uci -q get firewall.lxcsnat.name)" = "lxc-snat" ] || return 1
    [ "$(uci -q get firewall.lxcsnat.proto)" = "all" ] || return 1
    [ "$(uci -q get firewall.lxcsnat.src)" = "lan" ] || return 1
    [ "$(uci -q get firewall.lxcsnat.target)" = "SNAT" ] || return 1
    [ "$(uci -q get firewall.lxcsnat.src_ip)" = "$(_lxc_net)" ] || return 1
    [ "$(uci -q get firewall.lxcsnat.snat_ip)" = "$(_lan_ip)" ] || return 1
}

# 内核 IPv4 转发开关独立验证
verify_ip_forward() {
    [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = "1" ] || return 1
}

# 网桥就绪独立验证：设备在 + uci static + 实际 IP 与 BRIDGE_IP 一致
verify_bridge() {
    _vb=$(ip -4 addr show lxcbr0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -n1)
    ip link show lxcbr0 >/dev/null 2>&1 \
       && [ "$(uci -q get network.lxc.proto 2>/dev/null)" = "static" ] \
       && [ -n "$_vb" ] && [ "$_vb" = "$BRIDGE_IP" ]
}

# WAN zone input 放行独立验证（定责 name=wan，不赌索引）
# 单网口设备：必须 ACCEPT——否则唯一的口若被划为 WAN，input=REJECT 会连不上 luci
# 多网口设备：不得 ACCEPT——必有一个口在 LAN zone(input 本就 ACCEPT)，从 LAN 进 luci；
#             路由模式下 WAN 口应保持收紧
# 无 name=wan 的 zone（纯旁路由未建 WAN 区）：不涉及，跳过
verify_wan_input() {
    _wz=$(_zone_sec wan) || return 0
    _cur=$(uci -q get firewall.$_wz.input 2>/dev/null)
    if [ "$(_phys_port_count)" -ge 2 ]; then
        [ "$_cur" = "ACCEPT" ] && return 1
        return 0
    fi
    [ "$_cur" = "ACCEPT" ] || return 1
    return 0
}

# LAN zone 放行独立验证（定责 name=lan）：input/forward 必须 ACCEPT
# （放开内网：可进管理界面、可被转发到其他 zone）
verify_lan_input() {
    _lz=$(_zone_sec lan) || return 0
    [ "$(uci -q get firewall.$_lz.input 2>/dev/null)" = "ACCEPT" ] || return 1
    [ "$(uci -q get firewall.$_lz.forward 2>/dev/null)" = "ACCEPT" ] || return 1
    return 0
}

# ---- 旁路由网络基线（v.75 起自 99-custom.sh 同源搬迁，bypass 模式每次开机按需校准）----

# 桥接口验证：br-lan bridge 设备 + ports 与 /sys 实际枚举物理口集合一致 + 无残留 cfg030f15
# 枚举为空（开机早期网口驱动未就绪）→ 跳过不误建空桥（防外网断）
verify_br_lan_ports() {
    _vp=$(_phys_ports)
    [ -n "$_vp" ] || return 0
    [ "$(uci -q get network.br_lan.type 2>/dev/null)" = "bridge" ] || return 1
    [ "$(uci -q get network.br_lan.name 2>/dev/null)" = "br-lan" ] || return 1
    [ "$(uci -q get network.lan.device 2>/dev/null)" = "br-lan" ] || return 1
    uci show network.cfg030f15 >/dev/null 2>&1 && return 1
    [ "$(printf '%s\n' "$_vp" | sort)" = "$(uci -q get network.br_lan.ports 2>/dev/null | sort)" ]
}

# LAN 静态地址验证：proto/device/ipaddr/netmask/gateway/dns 与 _lan_static_conf 推导值一致
verify_lan_static() {
    set -- $(_lan_static_conf)
    [ "$(uci -q get network.lan.proto 2>/dev/null)" = "static" ] || return 1
    [ "$(uci -q get network.lan.device 2>/dev/null)" = "br-lan" ] || return 1
    [ "$(uci -q get network.lan.ipaddr 2>/dev/null)" = "$1" ] || return 1
    [ "$(uci -q get network.lan.netmask 2>/dev/null)" = "$2" ] || return 1
    [ "$(uci -q get network.lan.gateway 2>/dev/null)" = "$3" ] || return 1
    [ "$(uci -q get network.lan.dns 2>/dev/null)" = "$4" ] || return 1
    return 0
}

# DHCP 让权验证：lan ignore=1（旁路由不提供 DHCP，上游光猫发）+ IPv6 RA 项清净 + 无权威 DNS
verify_dhcp_ignore() {
    [ "$(uci -q get dhcp.lan.ignore 2>/dev/null)" = "1" ] || return 1
    [ -z "$(uci -q get dhcp.lan.ra 2>/dev/null)" ] || return 1
    [ -z "$(uci -q get dhcp.lan.max_preferred_lifetime 2>/dev/null)" ] || return 1
    [ -z "$(uci -q get dhcp.lan.max_valid_lifetime 2>/dev/null)" ] || return 1
    [ -z "$(uci -q get dhcp.lan.dhcpv6 2>/dev/null)" ] || return 1
    [ -z "$(uci -q get dhcp.lan.ndp 2>/dev/null)" ] || return 1
    for _dm in $(uci show dhcp 2>/dev/null | grep -E '=dnsmasq$' | cut -d. -f2 | cut -d= -f1); do
        [ -z "$(uci -q get dhcp.$_dm.authoritative 2>/dev/null)" ] || return 1
    done
    return 0
}

# WAN 禁用验证（仅 bypass 语义）：wan/wan6 disabled=1——旁路由不抢拨号，出口走上游网关
verify_wan_disabled() {
    [ "$(uci -q get network.wan.disabled 2>/dev/null)" = "1" ] || return 1
    [ "$(uci -q get network.wan6.disabled 2>/dev/null)" = "1" ] || return 1
    return 0
}

# DNS 劫持验证：存在 time.android.com → 203.107.6.88 的 dhcp domain（安卓 NTP 走国内源）
verify_dns_domain() {
    for _dd in $(uci show dhcp 2>/dev/null | grep -E '=domain$' | cut -d. -f2 | cut -d= -f1); do
        [ "$(uci -q get dhcp.$_dd.name 2>/dev/null)" = "time.android.com" ] || continue
        [ "$(uci -q get dhcp.$_dd.ip 2>/dev/null)" = "203.107.6.88" ] || return 1
        return 0
    done
    return 1
}

# docker 防火墙验证：zone（ACCEPT + 172.16.0.0/12）+ docker↔lan/wan 三向 forwarding
# 无 dockerd → 不涉及，跳过
verify_docker_fw() {
    command -v dockerd >/dev/null 2>&1 || return 0
    [ "$(uci -q get firewall.docker.name 2>/dev/null)" = "docker" ] || return 1
    [ "$(uci -q get firewall.docker.input 2>/dev/null)" = "ACCEPT" ] || return 1
    [ "$(uci -q get firewall.docker.output 2>/dev/null)" = "ACCEPT" ] || return 1
    [ "$(uci -q get firewall.docker.forward 2>/dev/null)" = "ACCEPT" ] || return 1
    uci -q get firewall.docker.subnet 2>/dev/null | grep -qx '172.16.0.0/12' || return 1
    [ "$(uci -q get firewall.docker2lan.src 2>/dev/null)" = "docker" ] || return 1
    [ "$(uci -q get firewall.docker2lan.dest 2>/dev/null)" = "lan" ] || return 1
    [ "$(uci -q get firewall.docker2wan.src 2>/dev/null)" = "docker" ] || return 1
    [ "$(uci -q get firewall.docker2wan.dest 2>/dev/null)" = "wan" ] || return 1
    [ "$(uci -q get firewall.lan2docker.src 2>/dev/null)" = "lan" ] || return 1
    [ "$(uci -q get firewall.lan2docker.dest 2>/dev/null)" = "docker" ] || return 1
    return 0
}

# lxc 防火墙区+转发规则 builder（zone 5 项 + forwarding 4 组）
build_lxc_zone_fwd() {
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
}

# SNAT 规则 builder：proto 整项规范化 + src_ip/snat_ip 现场推导
build_snat() {
    uci -q set firewall.lxcsnat=nat
    uci -q set firewall.lxcsnat.name='lxc-snat'
    uci -q delete firewall.lxcsnat.proto
    uci -q add_list firewall.lxcsnat.proto='all'
    uci -q set firewall.lxcsnat.src='lan'
    uci -q set firewall.lxcsnat.src_ip="$(_lxc_net)"
    uci -q set firewall.lxcsnat.target='SNAT'
    uci -q set firewall.lxcsnat.snat_ip="$(_lan_ip)"
}

# WAN zone input 放行 builder：按网口数定责设/收紧（作用于 name=wan 的 zone）
build_wan_input() {
    _wz=$(_zone_sec wan) || { log "[防火墙] 无 name=wan 的 zone，跳过 WAN input 管理"; return 0; }
    if [ "$(_phys_port_count)" -ge 2 ]; then
        uci -q set firewall.$_wz.input='REJECT'
        log "[防火墙] 多网口设备，WAN zone($_wz) input 收紧为 REJECT（LAN 口可进 luci）"
    else
        uci -q set firewall.$_wz.input='ACCEPT'
        log "[防火墙] 单网口设备，WAN zone($_wz) input 放行 ACCEPT（保 luci 可达）"
    fi
}

# LAN zone 放行 builder：input/forward 锁定 ACCEPT
build_lan_input() {
    _lz=$(_zone_sec lan) || { log "[防火墙] 无 name=lan 的 zone，跳过 LAN 放行管理"; return 0; }
    uci -q set firewall.$_lz.input='ACCEPT'
    uci -q set firewall.$_lz.forward='ACCEPT'
    log "[防火墙] LAN zone($_lz) input/forward 已放开（ACCEPT）"
}

# ---- 旁路由网络基线 builder（v.75，与原 99-custom.sh 同值同规则搬迁）----

# 桥接口 builder：清旧引用重建 br-lan，ports=当前枚举到的全部物理口
build_br_lan_ports() {
    uci -q delete network.lan.device
    uci -q delete network.br_lan
    uci -q delete network.cfg030f15
    uci -q set network.br_lan=device
    uci -q set network.br_lan.name='br-lan'
    uci -q set network.br_lan.type='bridge'
    uci -q set network.br_lan.bridge_empty='1'
    uci -q delete network.br_lan.ports
    for _p in $(_phys_ports); do
        uci -q add_list network.br_lan.ports="$_p"
    done
    uci -q set network.lan.device='br-lan'
}

# LAN 静态地址 builder：按 _lan_static_conf 推导值写 proto/ipaddr/netmask/gateway/dns
build_lan_static() {
    set -- $(_lan_static_conf)
    uci -q set network.lan.proto='static'
    uci -q set network.lan.device='br-lan'
    uci -q set network.lan.ipaddr="$1"
    uci -q set network.lan.netmask="$2"
    uci -q set network.lan.gateway="$3"
    uci -q set network.lan.dns="$4"
}

# DHCP 让权 builder：ignore=1 + 清 IPv6 RA 项 + 遍历所有 dnsmasq 段删 authoritative
build_dhcp_ignore() {
    uci -q set dhcp.lan.ignore='1'
    uci -q delete dhcp.lan.ra
    uci -q delete dhcp.lan.max_preferred_lifetime
    uci -q delete dhcp.lan.max_valid_lifetime
    uci -q delete dhcp.lan.dhcpv6
    uci -q delete dhcp.lan.ndp
    for _dm in $(uci show dhcp 2>/dev/null | grep -E '=dnsmasq$' | cut -d. -f2 | cut -d= -f1); do
        uci -q delete dhcp.$_dm.authoritative
    done
}

# WAN 禁用 builder（bypass）：wan/wan6 disabled=1
build_wan_disabled() {
    uci -q set network.wan.disabled='1'
    uci -q set network.wan6.disabled='1'
}

# DNS 劫持 builder：幂等补/改 time.android.com → 203.107.6.88
build_dns_domain() {
    for _dd in $(uci show dhcp 2>/dev/null | grep -E '=domain$' | cut -d. -f2 | cut -d= -f1); do
        if [ "$(uci -q get dhcp.$_dd.name 2>/dev/null)" = "time.android.com" ]; then
            uci -q set dhcp.$_dd.ip='203.107.6.88'
            return 0
        fi
    done
    uci -q add dhcp domain >/dev/null 2>&1
    _dd=$(uci show dhcp 2>/dev/null | grep -E '=domain$' | cut -d. -f2 | cut -d= -f1 | tail -n1)
    [ -n "$_dd" ] || return 1
    uci -q set "dhcp.$_dd.name=time.android.com"
    uci -q set "dhcp.$_dd.ip=203.107.6.88"
    return 0
}

# docker 防火墙 builder：按段名定责清含 docker 的 forwarding（不赌 @forwarding[idx] 索引，
# 标准 uci show 输出的是 cfgXXX=forwarding 段名）→ 重建 zone + 三向 forwarding
build_docker_fw() {
    uci -q delete firewall.docker
    for _fw in $(uci show firewall 2>/dev/null | grep -E '=forwarding$' | cut -d. -f2 | cut -d= -f1); do
        _src=$(uci -q get firewall.$_fw.src 2>/dev/null)
        _dest=$(uci -q get firewall.$_fw.dest 2>/dev/null)
        if [ "$_src" = "docker" ] || [ "$_dest" = "docker" ]; then
            uci -q delete firewall.$_fw
        fi
    done
    uci -q set firewall.docker=zone
    uci -q set firewall.docker.name='docker'
    uci -q set firewall.docker.input='ACCEPT'
    uci -q set firewall.docker.output='ACCEPT'
    uci -q set firewall.docker.forward='ACCEPT'
    uci -q add_list firewall.docker.subnet='172.16.0.0/12'
    uci -q set firewall.docker2lan=forwarding
    uci -q set firewall.docker2lan.src='docker'
    uci -q set firewall.docker2lan.dest='lan'
    uci -q set firewall.docker2wan=forwarding
    uci -q set firewall.docker2wan.src='docker'
    uci -q set firewall.docker2wan.dest='wan'
    uci -q set firewall.lan2docker=forwarding
    uci -q set firewall.lan2docker.src='lan'
    uci -q set firewall.lan2docker.dest='docker'
}

# 防火墙修复入口：四分项独立预检，哪项不符只重建哪项
# 全对 -> 不 commit 不 reload 直接跳过；只有 ip_forward 被关 -> 只 echo 1；
# 其余按需重建，一次 commit + 一次 reload
setup_lxc_firewall() {
    _ok_z=0; _ok_f=0; _ok_s=0; _ok_i=0; _ok_w=0; _ok_l=0
    verify_lxc_zone || _ok_z=1
    verify_fwd_rules || _ok_f=1
    verify_snat_rule || _ok_s=1
    verify_ip_forward || _ok_i=1
    verify_wan_input || _ok_w=1
    verify_lan_input || _ok_l=1
    [ "$_ok_z$_ok_f$_ok_s$_ok_i$_ok_w$_ok_l" = "000000" ] && { log "[防火墙] lxc 区/转发/SNAT/ip_forward/WAN-input/LAN-input 已就绪，跳过重建"; return 0; }
    if [ "$_ok_z" = 1 ] || [ "$_ok_f" = 1 ]; then
        build_lxc_zone_fwd
        log "[防火墙] lxc 区/转发规则已重建（input/output/forward=ACCEPT，8080/tcp、514/udp 可达）"
    fi
    if [ "$_ok_s" = 1 ]; then
        build_snat
        log "[防火墙] SNAT 已重建（src_ip=$(_lxc_net) snat_ip=$(_lan_ip)）"
    fi
    if [ "$_ok_w" = 1 ]; then
        build_wan_input
    fi
    if [ "$_ok_l" = 1 ]; then
        build_lan_input
    fi
    if [ "$_ok_z" = 1 ] || [ "$_ok_f" = 1 ] || [ "$_ok_s" = 1 ] || [ "$_ok_w" = 1 ] || [ "$_ok_l" = 1 ]; then
        uci -q commit firewall
        /etc/init.d/firewall reload >/dev/null 2>&1
    fi
    if [ "$_ok_i" = 1 ]; then
        echo 1 >/proc/sys/net/ipv4/ip_forward 2>/dev/null
        log "[防火墙] ip_forward 已置 1"
    fi
    return 0
}

# enroll 前校验 SNAT：容器上外网（拉黑名单、连 app.crowdsec.net）依赖 lxcsnat
# 按需调用 verify_snat_rule（6 项）+ ip_forward，任一不符 → setup_lxc_firewall
# 重建并补 ip_forward（不阻断）
verify_snat() {
    _vs_tgt=$(uci -q get firewall.lxcsnat.target 2>/dev/null)
    _vs_sip=$(uci -q get firewall.lxcsnat.snat_ip 2>/dev/null)
    _vs_src=$(uci -q get firewall.lxcsnat.src_ip 2>/dev/null)
    _vs_zone=$(uci -q get firewall.lxcsnat.src 2>/dev/null)
    _vs_fwd=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)
    if verify_snat_rule && [ "$_vs_fwd" = "1" ]; then
        log "[SNAT] 就位（zone=${_vs_zone} src=${_vs_src} → ${_vs_sip}）"
        return 0
    fi
    log "[SNAT] 缺失/不符，重建（zone=${_vs_zone:-空} target=${_vs_tgt:-空} snat_ip=${_vs_sip:-空} src_ip=${_vs_src:-空} ip_forward=${_vs_fwd:-空}）"
    setup_lxc_firewall
    echo 1 >/proc/sys/net/ipv4/ip_forward 2>/dev/null
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

# 旁路由网络基线入口（v.75）：按 _router_mode 分流，仅 bypass 校准——
#   桥接口 / LAN 静态 / DHCP 让权 / WAN 禁用 / DNS 劫持 五对象独立预检按需重建，
#   任一 network/dhcp 对象重建 → 一次 commit + network/dnsmasq reload 生效
# 必须在 setup_bridge/setup_lxc_firewall 之前跑：SNAT 的 snat_ip 取 _lan_ip()，
# 需先确保 network.lan.ipaddr 已校准就位（否则首启会读到固件默认地址）
setup_bypass_net() {
    if [ "$(_router_mode)" != "bypass" ]; then
        log "[旁路基线] 模式 $(_router_mode) 非 bypass，跳过旁路由网络校准（主路由适配后续版本）"
        setup_docker_fw
        return 0
    fi
    _ok_b=0; _ok_p=0; _ok_d=0; _ok_w=0; _ok_n=0
    verify_br_lan_ports || _ok_b=1
    verify_lan_static   || _ok_p=1
    verify_dhcp_ignore  || _ok_d=1
    verify_wan_disabled || _ok_w=1
    verify_dns_domain   || _ok_n=1
    if [ "$_ok_b$_ok_p$_ok_d$_ok_w$_ok_n" = "00000" ]; then
        log "[旁路基线] br-lan/LAN 静态/DHCP 让权/WAN 禁用/DNS 劫持 已就绪，跳过"
        setup_docker_fw
        return 0
    fi
    [ "$_ok_b" = 1 ] && { build_br_lan_ports; log "[旁路基线] br-lan 桥接口已重建（口：$(_phys_ports | tr '\n' ' ')）"; }
    [ "$_ok_p" = 1 ] && { build_lan_static; log "[旁路基线] LAN 静态已重建 $(_lan_static_conf | tr ' ' '/')"; }
    [ "$_ok_d" = 1 ] && { build_dhcp_ignore; log "[旁路基线] DHCP 已让权（ignore=1，IPv6 RA 清净）"; }
    [ "$_ok_w" = 1 ] && { build_wan_disabled; log "[旁路基线] WAN/WAN6 已禁用（出口走上游网关）"; }
    [ "$_ok_n" = 1 ] && { build_dns_domain; log "[旁路基线] DNS 劫持已就位（time.android.com → 203.107.6.88）"; }
    uci -q commit network
    uci -q commit dhcp
    /etc/init.d/network reload >/dev/null 2>&1
    /etc/init.d/dnsmasq reload >/dev/null 2>&1
    log "[旁路基线] network/dhcp 已提交并 reload"
    setup_docker_fw
    return 0
}

# docker 防火墙入口（无条件，与模式无关）：装了 dockerd 就要保证容器网络与防火墙互通
setup_docker_fw() {
    command -v dockerd >/dev/null 2>&1 || { log "[docker] 未检测到 dockerd，跳过防火墙配置"; return 0; }
    if verify_docker_fw; then
        log "[docker] zone + docker↔lan/wan forwarding 已就绪，跳过"
        return 0
    fi
    build_docker_fw
    uci -q commit firewall
    /etc/init.d/firewall reload >/dev/null 2>&1
    log "[docker] zone + docker↔lan/wan forwarding 已重建"
    return 0
}

setup_bridge() {
    if verify_bridge; then
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
    log "[网桥] lxcbr0=${BRIDGE_IP}/24 容器=${CONTAINER_IP} 网段=$(_lxc_net)"
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

# 开机判定：只看 Enrolled。cscli capi status 在 IsEnrolled() 为真时打印
# "Your instance is enrolled in the console"（JWT 带 organization_id claim，
# 即服务端已注册；网页端 Accept 前该 claim 可能缺失，属正常过程）。
# 注意：不能用 cscli console status——它只打印控制台选项表
# （SEND_*/console_management 的启用态），任何输出模式都不含 enrolled
# 字样（v1.6.5~v1.6.11 源码实锤），v.64 及更早查错命令导致复检必然失败
console_enroll_ok() {
    _out="$(_ct_env "$CSCLI capi status" 2>&1)"
    [ -n "$_out" ] || return 1
    _line="$(printf '%s\n' "$_out" | grep -i 'enrolled' | head -n1)"
    [ -n "$_line" ] || return 1
    printf '%s\n' "$_line" | grep -qiE 'not enrolled|(^|[^[:alnum:]_])false' && return 1
    return 0
}

# 等容器内能解析 api.crowdsec.net：开机时 DNS/mosdns 未就绪会让 enroll 秒退
# 墙钟上限 _wn_max 秒（就绪即止，每次探测容器内 timeout 2 封顶）；容器停了立即失败
_wait_capi_net() {
    _wn_max="${1:-30}"
    _wn_dl=$(( $(date +%s) + _wn_max ))
    while [ "$(date +%s)" -lt "$_wn_dl" ]; do
        ct_running || { log "[enroll] 容器已停止，放弃等待 DNS 就绪"; return 1; }
        _ct_env "timeout 2 getent hosts api.crowdsec.net" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

re_enroll() {
    log "[enroll] console 未注册，用注册码 enroll（注册码固定有效，可反复使用，不消耗）"

    _enroll_key=""
    [ -f "$ENROLL_KEY_FILE" ] && _enroll_key="$(head -n1 "$ENROLL_KEY_FILE" | tr -d ' \t\r\n')"
    if [ -z "$_enroll_key" ]; then
        log "[enroll] 无注册码（$ENROLL_KEY_FILE 缺失或为空），放弃 enroll"
        return 1
    fi

    verify_snat

    # CAPI 起不来 enroll 必败：先等 DNS/网络就绪（≤30s，就绪即止）
    if ! _wait_capi_net 30; then
        log "[enroll] 30 秒内仍无法解析 api.crowdsec.net（容器 DNS 未就绪），放弃本次 enroll"
        return 1
    fi

    _cred_file="$ROOTFS/etc/crowdsec/online_api_credentials.yaml"

    # cscli console enroll 的加载前提：online_api_credentials.yaml 必须已存在
    # （由 cscli capi register 创建）。v.62 及更早先把它 mv 走再 enroll，
    # 文件不在场 → enroll 在配置加载阶段就秒退，脚本 enroll 从来不可能成功
    if [ ! -s "$_cred_file" ]; then
        log "[enroll] online_api_credentials.yaml 缺失，先 cscli capi register 注册 CAPI 凭据"
        if ! _capi_reg_out="$(_ct_env "$CSCLI capi register" 2>&1)"; then
            log "[enroll] capi register 失败：$(printf '%s' "$_capi_reg_out" | tr '\n' ' ' | cut -c1-300)"
            return 1
        fi
        log "[enroll] capi register 成功，凭据已写入 online_api_credentials.yaml"
    fi

    # v.65 起不做任何凭据备份/回滚：enroll 命令返回成功即代表服务端已注册
    # （watcher 已创建），此时用户只需到网页点 Accept 即完成。回滚会把已注册
    # 状态破坏掉（disable --all + 恢复旧凭据），用户 Accept 后无法收场
    if ! _enroll_out="$(_ct_env "/usr/bin/cscli console enroll \"$_enroll_key\"" 2>&1)"; then
        log "[enroll] enroll 执行失败：$(printf '%s' "$_enroll_out" | tr '\n' ' ' | cut -c1-300)"
        log "[enroll] 注册码未消耗，下次开机重试"
        return 1
    fi
    log "[enroll] enroll 命令返回成功：$(printf '%s' "$_enroll_out" | tr '\n' ' ' | cut -c1-200)"

    # 推送开关：1.6.9+ enrolled 后自动全开；低版本补开，失败不阻断（未 Accept 前也可能被拒）
    _ct_env '/usr/bin/cscli console enable --all' >/dev/null 2>&1 \
        || log "[enroll] console enable --all 失败（不影响注册；新版本 enrolled 后自动全开）"

    _ct_env 'systemctl restart crowdsec >/dev/null 2>&1' || true

    # 重启后把 CAPI 真实状态写进日志（CAPI 起不来 enroll 白搭，这里留证据）
    _capi_out="$(_ct_env "$CSCLI capi status" 2>&1)"
    [ -n "$_capi_out" ] && log "[enroll] capi status：$(printf '%s' "$_capi_out" | tr '\n' ' ' | cut -c1-200)"

    # 复检只看 Enrolled：enroll 已成功，这里只是等本地状态可见。
    # 网页端 Accept 前 JWT 可能还没有 organization_id claim（显示未 enrolled），
    # 属正常过程——不回滚、不阻止使用，等满 60s 直接放行并提示去网站 Accept；
    # 未及时 Accept 前 CAPI 侧可能持续报错，Accept 后自动恢复
    _i=0
    while [ "$_i" -lt 2 ]; do
        _i=$((_i+1))
        if console_enroll_ok; then
            log "[enroll] 已注册（Enrolled）；网页端 Accept 后 CAPI 才 authenticated，无需脚本干预"
            return 0
        fi
        sleep 5
    done

    log "[enroll] enroll 已成功，60 秒内本地未显示 Enrolled"
    log "[enroll] 需要前往网站确认接受：请访问 https://app.crowdsec.net 接受该实例（Accept）"
    log "[enroll] 未及时 Accept 前 CAPI 侧可能有报错，属正常过程；Accept 后自动恢复"
    return 0
}

_try_enroll() {
    if console_enroll_ok; then
        log "[enroll] 已注册（Enrolled），跳过 enroll"
        return 0
    fi
    re_enroll || log "[enroll] 本次 enroll 未成功，下次开机再试（注册码固定有效，不消耗）"
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
    log "网络模式: $(_router_mode)（WAN-input/LAN-input 按 name 定责；旁路基线由 bootstrap 每次开机校准，v.75）"

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

    # 先校准旁路由 LAN 静态地址（SNAT snat_ip 依赖 network.lan.ipaddr 就位），再建 lxcbr0
    setup_bypass_net
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
