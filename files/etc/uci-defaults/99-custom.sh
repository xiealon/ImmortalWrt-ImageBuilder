#!/bin/sh
LOGFILE="/etc/config/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >>$LOGFILE
uci set firewall.@zone[1].input='ACCEPT'

uci add dhcp domain
uci set "dhcp.@domain[-1].name=time.android.com"
uci set "dhcp.@domain[-1].ip=203.107.6.88"


BPS_IP='10.1.1.201'
BPS_GW='10.1.1.1'
BPS_DN='10.1.1.1'

_read_netconf() {
    [ -f "/etc/config/$1" ] || return 0
    head -n1 "/etc/config/$1" | tr -d ' \t\r\n'
}

NETMASK="$(_read_netconf custom_router_netmask.txt)"
[ -n "$NETMASK" ] || NETMASK='255.255.255.0'

_UIP=$(_read_netconf custom_router_ip.txt)
if [ -n "$_UIP" ]; then
    BPS_IP="$_UIP"
    if [ "$NETMASK" = "255.255.255.0" ]; then
        BPS_GW="$(echo "$BPS_IP" | awk -F. '{print $1"."$2"."$3".1"}')"
        BPS_DN="$BPS_GW"
        echo "使用自定义管理地址 ${BPS_IP}（网关按 /24 推导）" >>$LOGFILE
    else
        echo "!! 掩码为 ${NETMASK}（非 /24），跳过网关自动推导" >>$LOGFILE
        echo "   请在 Actions 的 custom_router_gateway 里显式填写网关" >>$LOGFILE
        echo "使用自定义管理地址 ${BPS_IP}（网关待填）" >>$LOGFILE
    fi
else
    echo "未传入 custom_router_ip.txt，使用默认 ${BPS_IP}" >>$LOGFILE
fi

_UGW=$(_read_netconf custom_router_gateway.txt)
if [ -n "$_UGW" ]; then
    BPS_GW="$_UGW"
    [ -n "$(_read_netconf custom_router_dns.txt)" ] || BPS_DN="$_UGW"
    echo "使用自定义网关 ${BPS_GW}" >>$LOGFILE
fi

_UDN=$(_read_netconf custom_router_dns.txt)
[ -n "$_UDN" ] && BPS_DN="$_UDN"

echo "最终网络配置: IP=${BPS_IP}/${NETMASK} 网关=${BPS_GW} DNS=${BPS_DN}" >>$LOGFILE

CS_CT_IP="$(_read_netconf custom_container_ip.txt)"
[ -n "$CS_CT_IP" ] || CS_CT_IP='10.0.0.10'
CS_BRIDGE_IP="$(_read_netconf custom_bridge_ip.txt)"
[ -n "$CS_BRIDGE_IP" ] || CS_BRIDGE_IP='10.0.0.1'
LSC_IP="$(echo "$CS_CT_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')"
echo "容器网络: IP=${CS_CT_IP} 网关/DNS=${CS_BRIDGE_IP} 掩码=255.255.255.0 NAT=${LSC_IP}" >>$LOGFILE


uci set network.wan.disabled='1'
uci set network.wan6.disabled='1'

uci del network.lan.device
uci del network.br_lan

uci set network.br_lan=device
uci set network.br_lan.name='br-lan'
uci set network.br_lan.type='bridge'
uci set network.br_lan.bridge_empty='1'

uci set network.lxcbr0=device
uci set network.lxcbr0.name='lxcbr0'
uci set network.lxcbr0.type='bridge'
uci set network.lxcbr0.bridge_empty='1'
uci set network.lxc=interface
uci set network.lxc.device='lxcbr0'
uci set network.lxc.proto='static'
uci set network.lxc.ipaddr="${CS_BRIDGE_IP}"
uci set network.lxc.netmask='255.255.255.0'
uci set dhcp.lxc=dhcp
uci set dhcp.lxc.interface='lxc'
uci set dhcp.lxc.start='100'
uci set dhcp.lxc.limit='150'
uci set dhcp.lxc.leasetime='1h'
uci set firewall.lxczone=zone
uci set firewall.lxczone.name='lxc'
uci set firewall.lxczone.network='lxc'
uci set firewall.lxczone.input='ACCEPT'
uci set firewall.lxczone.output='ACCEPT'
uci set firewall.lxczone.forward='ACCEPT'
uci set firewall.lxc2lan=forwarding
uci set firewall.lxc2lan.src='lxc'
uci set firewall.lxc2lan.dest='lan'
uci set firewall.lxc2docker=forwarding
uci set firewall.lxc2docker.src='lxc'
uci set firewall.lxc2docker.dest='docker'
uci set firewall.lxc2vpn=forwarding
uci set firewall.lxc2vpn.src='lxc'
uci set firewall.lxc2vpn.dest='vpn'
uci set firewall.lan2lxc=forwarding
uci set firewall.lan2lxc.src='lan'
uci set firewall.lan2lxc.dest='lxc'
uci set firewall.lxcsnat=nat
uci set firewall.lxcsnat.name='lxc-snat'
uci add_list firewall.lxcsnat.proto='all'
uci set firewall.lxcsnat.src='lan'
uci set firewall.lxcsnat.src_ip="${LSC_IP}"
uci set firewall.lxcsnat.target='SNAT'
uci set firewall.lxcsnat.snat_ip="${BPS_IP}"
uci commit

uci -q del network.br_lan.ports

for port in $(ls /sys/class/net/ | grep -E '^(eth|en|lan)' | grep -v -E '(lo|docker|veth|br-|tun|tap)'); do
    uci add_list network.br_lan.ports="$port"
done

uci set network.lan.device='br-lan'
uci set network.lan.proto='static'
uci set network.lan.ipaddr="${BPS_IP}"
uci set network.lan.netmask="${NETMASK}"
uci set network.lan.gateway="${BPS_GW}"
uci set network.lan.dns="${BPS_DN}"

uci set dhcp.lan.ignore='1'
uci del dhcp.lan.ra
uci del dhcp.lan.max_preferred_lifetime
uci del dhcp.lan.max_valid_lifetime
uci del dhcp.lan.dhcpv6
uci del dhcp.lan.ndp

uci -q del dhcp.@dnsmasq[0].authoritative

uci set mosdns.config.enabled='1'
uci set mosdns.config.redirect='1'
uci set mosdns.config.local_dns_redirect='1'
uci set mosdns.config.geo_auto_update='1'
uci set mosdns.config.custom_local_dns='1'
uci set mosdns.config.apple_optimization='1'
uci add_list mosdns.config.local_dns='223.5.5.5'
uci add_list mosdns.config.local_dns='119.29.29.29'

uci commit

uci del network.cfg030f15
uci commit

echo "default router ip is ${BPS_IP}" >> $LOGFILE

  uci set luci.main.mediaurlbase="/luci-static/bootstrap"
  uci set luci.main.lang='auto'
  uci set luci.main.tablefilters='1'
  uci commit


  uci del ttyd.@ttyd[0].interface

  uci set dropbear.@dropbear[0].Interface=''
  uci commit

FILE_PATH="/etc/openwrt_release"
NEW_DESCRIPTION="Packaged by wukongdaily"
sed -i "s/DISTRIB_DESCRIPTION='[^']*'/DISTRIB_DESCRIPTION='$NEW_DESCRIPTION'/" "$FILE_PATH"

if command -v dockerd >/dev/null 2>&1; then
    echo "检测到 Docker，正在配置防火墙规则..."
    FW_FILE="/etc/config/firewall"

    uci delete firewall.docker

    for idx in $(uci show firewall | grep "=forwarding" | cut -d[ -f2 | cut -d] -f1 | sort -rn); do
        src=$(uci get firewall.@forwarding[$idx].src 2>/dev/null)
        dest=$(uci get firewall.@forwarding[$idx].dest 2>/dev/null)
        echo "Checking forwarding index $idx: src=$src dest=$dest"
        if [ "$src" = "docker" ] || [ "$dest" = "docker" ]; then
            echo "Deleting forwarding @forwarding[$idx]"
            uci delete firewall.@forwarding[$idx]
        fi
    done
    uci commit firewall

cat <<EOF >>"$FW_FILE"

config zone 'docker'
  option input 'ACCEPT'
  option output 'ACCEPT'
  option forward 'ACCEPT'
  option name 'docker'
  list subnet '172.16.0.0/12'

config forwarding
  option src 'docker'
  option dest 'lan'

config forwarding
  option src 'docker'
  option dest 'wan'

config forwarding
  option src 'lan'
  option dest 'docker'
EOF

else
    echo "未检测到 Docker，跳过防火墙配置。"
fi

CS_LAPI_PORT='8080'

if ! mountpoint -q /sys/fs/cgroup 2>/dev/null; then
    mkdir -p /sys/fs/cgroup
    if mount -t cgroup2 none /sys/fs/cgroup 2>/dev/null; then
        echo "cgroup2 已挂载到 /sys/fs/cgroup" >>$LOGFILE
    else
        echo "cgroup2 挂载失败（可能内核已挂载或不支持）" >>$LOGFILE
    fi
else
    echo "cgroup 已挂载，跳过" >>$LOGFILE
fi

uci set system.@system[0].log_ip="${CS_CT_IP}"
uci set system.@system[0].log_port='514'
uci set system.@system[0].log_proto='udp'
uci -q set system.@system[0].log_remote='1'
uci -q set system.@system[0].cronloglevel='5'
uci commit system
echo "系统日志外发至 ${CS_CT_IP}:514" >>$LOGFILE

# ---------------------------------------------------------------- CrowdSec 引导
# 归拢目录：容器镜像 + 稳定态配置备份统一放 /etc/crowdsec/
CS_HOME='/etc/crowdsec'
CS_TARBALL="$CS_HOME/lxc-ubuntu.tar.gz"
CS_ROOTFS='/srv/lxc/ubuntu/rootfs'
# 兼容旧固件：把 /opt 下的镜像挪进 /etc/crowdsec/
if [ ! -f "$CS_TARBALL" ] && [ -f /opt/lxc-ubuntu.tar.gz ]; then
    mkdir -p "$CS_HOME" 2>/dev/null
    mv -f /opt/lxc-ubuntu.tar.gz "$CS_TARBALL" 2>/dev/null \
        && echo "容器镜像已迁移到 $CS_TARBALL" >>$LOGFILE
fi
if [ -d "$CS_HOME" ] || [ -f "$CS_TARBALL" ] || [ -d "$CS_ROOTFS" ]; then
    mkdir -p "$CS_HOME" 2>/dev/null
    echo "CrowdSec 工作目录 $CS_HOME（镜像 $CS_TARBALL，备份 $CS_HOME/baseline）" >>$LOGFILE
    # 快照目录要跟 sysupgrade 一起保留，否则升级后要重建一次备份窗口
    grep -q "^${CS_HOME}/baseline" /etc/sysupgrade.conf 2>/dev/null \
        || echo "${CS_HOME}/baseline" >> /etc/sysupgrade.conf 2>/dev/null
fi

# 容器自启统一交给 bootstrap（它内部有幂等拉起 + 重建逻辑）。
# 这里不再装 lxc-autostrt 之类的并行自启服务 —— 两套自启抢同一个容器
# 会造成「bootstrap 正在解压 rootfs，lxc-autostart 看到目录存在就来拉起半解压的容器」的竞态。
# bootstrap 的 write_cfg 里已写 lxc.start.auto = 1，LXC 自身的 autostart 机制负责兜底自启。

if { [ -f "$CS_TARBALL" ] || [ -d "$CS_ROOTFS" ]; } && [ -f /etc/config/crowdsec ]; then
    CS_SEC=$(uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
    if [ -z "$CS_SEC" ]; then
        uci add crowdsec bouncer >/dev/null 2>&1
        CS_SEC=$(uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
    fi
    if [ -n "$CS_SEC" ]; then
        uci set "$CS_SEC.enabled=1"
        uci set "$CS_SEC.api_url=http://${CS_CT_IP}:${CS_LAPI_PORT}/"
        uci set "$CS_SEC.ipv4=1"
        uci set "$CS_SEC.ipv6=0"
        uci set "$CS_SEC.deny_action=drop"
        uci set "$CS_SEC.filter_input=1"
        uci set "$CS_SEC.filter_forward=1"
        uci -q del "$CS_SEC.interface"
        uci add_list "$CS_SEC.interface=br-lan"
        uci commit crowdsec
        echo "已预填 bouncer 段: $CS_SEC（api_key 由开机引导自动获取填入）" >>$LOGFILE
    else
        echo "!! /etc/config/crowdsec 存在但建不出 bouncer 段，检查 crowdsec-firewall-bouncer 包" >>$LOGFILE
    fi
else
    echo "跳过 bouncer 预填（无容器镜像/rootfs，或无 /etc/config/crowdsec）" >>$LOGFILE
fi

echo "CrowdSec 引导已就绪（rc.local → crowdsec-lxc-bootstrap.sh）" >>$LOGFILE

if [ -d /aria2 ] && [ -f /etc/config/aria2 ]; then
    uci set aria2.main.dir='/aria2'
    uci set aria2.main.seed_time='0'
    uci set aria2.main.max_overall_upload_limit='50k'
    uci set aria2.main.max_upload_limit='50k'
    uci set aria2.main.enabled='1'
    uci commit
    uci set aria2.main.enabled='0'
    uci commit
    echo "aria2 下载目录已设为 /aria2" >>$LOGFILE
else
    echo "跳过 aria2：未检测到 /aria2 目录或 aria2 未安装" >>$LOGFILE
fi

exit 0
