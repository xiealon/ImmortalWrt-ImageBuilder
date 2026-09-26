#!/bin/sh
# 99-custom.sh 就是immortalwrt固件首次启动时运行的脚本 位于固件内的/etc/uci-defaults/99-custom.sh
# Log file for debugging
LOGFILE="/etc/config/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >>$LOGFILE
# 设置默认防火墙规则，方便单网口虚拟机首次访问 WebUI 
# 因为本项目中 单网口模式是dhcp模式 直接就能上网并且访问web界面 避免新手每次都要修改/etc/config/network中的静态ip
# 当你刷机运行后 都调整好了 你完全可以在web页面自行关闭 wan口防火墙的入站数据
# 具体操作方法：网络——防火墙 在wan的入站数据 下拉选项里选择 拒绝 保存并应用即可。
uci set firewall.@zone[1].input='ACCEPT'

# 设置主机名映射，解决安卓原生 TV 无法联网的问题
uci add dhcp domain
uci set "dhcp.@domain[-1].name=time.android.com"
uci set "dhcp.@domain[-1].ip=203.107.6.88"

# 检查配置文件pppoe-settings是否存在 该文件由build.sh动态生成
SETTINGS_FILE="/etc/config/pppoe-settings"
if [ ! -f "$SETTINGS_FILE" ]; then
    echo "PPPoE settings file not found. Skipping." >>$LOGFILE
else
    # 读取pppoe信息($enable_pppoe、$pppoe_account、$pppoe_password)
    . "$SETTINGS_FILE"
fi

BPS_IP='10.1.1.201'    #IP地址
BPS_GW='10.1.1.1'      #网关
BPS_DN='10.1.1.1'      #DNS
LXC_IP='10.0.0.1'      #LXC地址
LSC_IP='10.0.0.0/24'   #LXC NAT转发IP


# 禁用WAN口
uci set network.wan.disabled='1'
uci set network.wan6.disabled='1'

# 使lan接口为未指定状态
# 删除系统内的br_lan接口
uci del network.lan.device
uci del network.br_lan

# 创建一个br_lan接口 命名为br-lan
uci set network.br_lan=device
uci set network.br_lan.name='br-lan'
uci set network.br_lan.type='bridge'
uci set network.br_lan.bridge_empty='1'

# lxc
#----------网络：lxcbr0 网桥 + lxc 接口----------
uci set network.lxcbr0=device
uci set network.lxcbr0.name='lxcbr0'
uci set network.lxcbr0.type='bridge'
uci set network.lxcbr0.bridge_empty='1'
uci set network.lxc=interface
uci set network.lxc.device='lxcbr0'
uci set network.lxc.proto='static'
uci set network.lxc.ipaddr="${LXC_IP}"
uci set network.lxc.netmask='255.255.255.0'
#----------DHCP：容器网段发 IP----------
uci set dhcp.lxc=dhcp
uci set dhcp.lxc.interface='lxc'
uci set dhcp.lxc.start='100'
uci set dhcp.lxc.limit='150'
uci set dhcp.lxc.leasetime='1h'
#----------防火墙：独立 lxc 区 ＆ 双向转发 ----------
uci set firewall.lxczone=zone
uci set firewall.lxczone.name='lxc'
uci set firewall.lxczone.network='lxc'
uci set firewall.lxczone.input='ACCEPT'
uci set firewall.lxczone.output='ACCEPT'
uci set firewall.lxczone.forward='ACCEPT'
# 容器 -> 内网/外网
uci set firewall.lxc2lan=forwarding
uci set firewall.lxc2lan.src='lxc'
uci set firewall.lxc2lan.dest='lan'
# 容器 -> docker 区（访问宿主 Docker 网段 172.16.0.0/12）
uci set firewall.lxc2docker=forwarding
uci set firewall.lxc2docker.src='lxc'
uci set firewall.lxc2docker.dest='docker'
# 容器 -> vpn 区（tun0，走 VPN 隧道出网）
uci set firewall.lxc2vpn=forwarding
uci set firewall.lxc2vpn.src='lxc'
uci set firewall.lxc2vpn.dest='vpn'
# 内网 -> 容器（局域网设备能直接访问容器）
uci set firewall.lan2lxc=forwarding
uci set firewall.lan2lxc.src='lan'
uci set firewall.lan2lxc.dest='lxc'
# 创建端口转发[nat]
uci set firewall.lxcsnat=nat
uci set firewall.lxcsnat.name='lxc-snat'
uci add_list firewall.lxcsnat.proto='all'
uci set firewall.lxcsnat.src='lan'
uci set firewall.lxcsnat.src_ip="${LSC_IP}"
uci set firewall.lxcsnat.target='SNAT'
uci set firewall.lxcsnat.snat_ip="${BPS_IP}"
# 提交
uci commit

# 删除br_lan的所有接口
# 查看设备上所有名称为eth，en，lan的接口
# 将查看到的接口添加进入br-lan接口
uci -q del network.br_lan.ports

for port in $(ls /sys/class/net/ | grep -E '^(eth|en|lan)' | grep -v -E '(lo|docker|veth|br-|tun|tap)'); do
    uci add_list network.br_lan.ports="$port"
done

# 将br-lan添加进入lan口并设置ip，掩码，网关，dns
uci set network.lan.device='br-lan'
uci set network.lan.proto='static'
uci set network.lan.ipaddr="${BPS_IP}"
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.gateway="${BPS_GW}"
uci set network.lan.dns="${BPS_DN}"

# 忽略lan口的dhcp
uci set dhcp.lan.ignore='1'
# 禁用RA路由通告
uci del dhcp.lan.ra
uci del dhcp.lan.max_preferred_lifetime
uci del dhcp.lan.max_valid_lifetime
# 禁用DHCPv6
uci del dhcp.lan.dhcpv6
# 忽略接口的NDP
uci del dhcp.lan.ndp

# 关闭dhcp页面的强制dhcp客户端（唯一客户端））
uci -q del dhcp.@dnsmasq[0].authoritative

# 提交
uci commit

# 已知修复在新建br_lan接口情况下会出现一个默认名称的br-lan接口cfg030f15
# 请确定好该项数值
# 提交
uci del network.cfg030f15
uci commit

# 输出信息
echo "default router ip is ${BPS_IP}" >> $LOGFILE

# 设置主题为Bootstrap
# 语言为auto 开启表格筛选器
  uci set luci.main.mediaurlbase="/luci-static/bootstrap"
  uci set luci.main.lang='auto'
  uci set luci.main.tablefilters='1'
  uci commit

# qbittorrent服务//种子下载
  # uci set qbittorrent.config.enabled='1'
  # uci commit

# 设置所有网口可访问网页终端
  uci del ttyd.@ttyd[0].interface

# 设置所有网口可连接 SSH
  uci set dropbear.@dropbear[0].Interface=''
  uci commit

# 设置编译作者信息
FILE_PATH="/etc/openwrt_release"
NEW_DESCRIPTION="Packaged by wukongdaily"
sed -i "s/DISTRIB_DESCRIPTION='[^']*'/DISTRIB_DESCRIPTION='$NEW_DESCRIPTION'/" "$FILE_PATH"

# 若安装了dockerd 则设置docker的防火墙规则
# 扩大docker涵盖的子网范围 '172.16.0.0/12'
# 方便各类docker容器的端口顺利通过防火墙 
if command -v dockerd >/dev/null 2>&1; then
    echo "检测到 Docker，正在配置防火墙规则..."
    FW_FILE="/etc/config/firewall"

    # 删除所有名为 docker 的 zone
    uci delete firewall.docker

    # 先获取所有 forwarding 索引，倒序排列删除
    for idx in $(uci show firewall | grep "=forwarding" | cut -d[ -f2 | cut -d] -f1 | sort -rn); do
        src=$(uci get firewall.@forwarding[$idx].src 2>/dev/null)
        dest=$(uci get firewall.@forwarding[$idx].dest 2>/dev/null)
        echo "Checking forwarding index $idx: src=$src dest=$dest"
        if [ "$src" = "docker" ] || [ "$dest" = "docker" ]; then
            echo "Deleting forwarding @forwarding[$idx]"
            uci delete firewall.@forwarding[$idx]
        fi
    done
    # 提交删除
    uci commit firewall

# 追加新的 zone + forwarding 配置
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

exit 0
