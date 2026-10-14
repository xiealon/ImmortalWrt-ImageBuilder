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


uci set network.wan.disabled='1'
uci set network.wan6.disabled='1'

uci del network.lan.device
uci del network.br_lan

uci set network.br_lan=device
uci set network.br_lan.name='br-lan'
uci set network.br_lan.type='bridge'
uci set network.br_lan.bridge_empty='1'

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

CS_HOME='/etc/crowdsec'
if [ -d "$CS_HOME" ] || [ -f "$CS_HOME/lxc-ubuntu.tar.gz" ] || [ -d /srv/lxc/ubuntu/rootfs ]; then
    mkdir -p "$CS_HOME" 2>/dev/null
    for _keep in "$CS_HOME/baseline" "$CS_HOME/lxc-ubuntu.tar.gz"; do
        grep -q "^$_keep" /etc/sysupgrade.conf 2>/dev/null \
            || echo "$_keep" >> /etc/sysupgrade.conf 2>/dev/null
    done
fi

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
