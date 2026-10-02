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

# 说明：原来这里有一段读取 /etc/config/pppoe-settings 的代码，
#       但全文再无任何地方引用 $enable_pppoe —— 属于只读不用的死代码，已移除。
#       如果你哪天真要做拨号，在下面 IP 段之后加逻辑即可（记住：uci-defaults 阶段网络还没起，
#       只能写 uci 配置，不能在这里测试拨号是否成功）。

# IP/网关/DNS设置（附带LXC）
BPS_IP='10.1.1.201'    #IP地址/LAN
BPS_GW='10.1.1.1'      #网关/LAN
BPS_DN='10.1.1.1'      #DNS/LAN
LXC_IP='10.0.0.1'      #LXC地址
LSC_IP='10.0.0.0/24'   #LXC NAT转发IP

# ============================================================================
# 读取 GitHub Actions 界面里填的网络参数
#
# 数据链路是这样走的（以 x86-64/25.12 为例，24.10 同理）：
#   1.  Actions UI 填 custom_router_ip / custom_router_gateway / custom_router_dns
#   2.  workflow 把它们各自 echo 成 ${{ github.workspace }}/custom/*.txt
#   3.  运行 done 时 -v $PWD/custom:/home/build/immortalwrt/files/etc/config
#       把整个 custom/ 目录挂成固件里的 /etc/config/
#   4.  于是固化到固件里就是 /etc/config/custom_router_ip.txt 等等
#   5.  本脚本（uci-defaults，首开机早期）在这里 cat 出来用
#
# 注意第 3 步是挂载「整个目录」到 /etc/config，所以文件名不能改，
# 且 uci 自己的 /etc/config 目录在 overlayfs 里仍然存在（挂的是临时 binding）。
#
# 网关 / DNS 留空时不强求：会自动按「IP 的前三段 + .1」推导，
# 99% 的家宽场景（192.168.x.1 / 10.x.x.1）都对。
# ============================================================================
_read_netconf() {   # $1=文件名 -> stdout 首行，去空白；文件不存在就输出空
    [ -f "/etc/config/$1" ] || return 0
    head -n1 "/etc/config/$1" | tr -d ' \t\r\n'
}

# ---- 0. 子网掩码（选填，默认 /24）----
#      下面 1 的网关自动推导只对 /24 成立，掩码不是 24 位时脚本会拒绝推导，
#      要求你在 workflow 里显式填 custom_router_gateway。
NETMASK="$(_read_netconf custom_router_netmask.txt)"
[ -n "$NETMASK" ] || NETMASK='255.255.255.0'

# ---- 1. 管理 IP（必填，workflow 里 required: true）----
# 不覆盖的话 SNAT 的 snat_ip 会和实际 LAN IP 不一致，容器就出不了网（CrowdSec 拉不到 CAPI）
_UIP=$(_read_netconf custom_router_ip.txt)
if [ -n "$_UIP" ]; then
    BPS_IP="$_UIP"
    if [ "$NETMASK" = "255.255.255.0" ]; then
        # 默认网关：/24 网段的首个地址
        BPS_GW="$(echo "$BPS_IP" | awk -F. '{print $1"."$2"."$3".1"}')"
        BPS_DN="$BPS_GW"
        echo "使用自定义管理地址 ${BPS_IP}（网关按 /24 推导）" >>$LOGFILE
    else
        # 非 /24 时「前三段 + .1」不再成立（比如 /22 的网关可能在别的三段里），
        # 硬推只会得到一个不存在的地址，导致旁路由自己都上不了网且毫无报错。
        echo "!! 掩码为 ${NETMASK}（非 /24），跳过网关自动推导" >>$LOGFILE
        echo "   请在 Actions 的 custom_router_gateway 里显式填写网关" >>$LOGFILE
        echo "使用自定义管理地址 ${BPS_IP}（网关待填）" >>$LOGFILE
    fi
else
    echo "未传入 custom_router_ip.txt，使用默认 ${BPS_IP}" >>$LOGFILE
fi

# ---- 2. 网关（选填；不填就用上面自动推导的那个）----
_UGW=$(_read_netconf custom_router_gateway.txt)
if [ -n "$_UGW" ]; then
    BPS_GW="$_UGW"
    # 没单独填 DNS 时，DNS 默认跟网关走（大多数家用网关本身就是 DNS 转发器）
    [ -n "$(_read_netconf custom_router_dns.txt)" ] || BPS_DN="$_UGW"
    echo "使用自定义网关 ${BPS_GW}" >>$LOGFILE
fi

# ---- 3. DNS（选填；优先级最高，单独覆盖）----
_UDN=$(_read_netconf custom_router_dns.txt)
[ -n "$_UDN" ] && BPS_DN="$_UDN"

echo "最终网络配置: IP=${BPS_IP}/${NETMASK} 网关=${BPS_GW} DNS=${BPS_DN}" >>$LOGFILE


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
uci set network.lan.netmask="${NETMASK}"      # 由 custom_router_netmask.txt 传入，默认 /24
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

# =============================================================================
# CrowdSec + LXC 容器：开机自动对接
# 说明：本脚本处在 first boot 的早期（uci-defaults），此时网络还没起来，
#       所以这里只做「零网络依赖」的配置；真正拉容器、装软件、取 key 的事
#       交给 /etc/rc.local 后台调用的 /usr/sbin/crowdsec-lxc-bootstrap.sh。
# =============================================================================
CS_CT_IP='10.0.0.10'    # 容器固定 IP（编译期已写进容器的 systemd-networkd）
CS_LAPI_PORT='8080'

# ---------- 0. cgroup2 挂载兜底（替代 cgroupfs-mount / cgroup-tools 两个包） ----------
# 25.12(apk) 的源里没有这两个包（它们只在 24.x 的第三方 opkg 源里），而 kernel 6.12
# 本身默认就是 cgroup v2 unified hierarchy，这里显式确认一次即可，不需要额外装包。
# 顺带把 cgroup 的 controllers 打开，容器里的 systemd 才能正常管进程。
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

# ---------- 1. 路由器把系统日志外发到容器：整条检测链路的数据源头 ----------
uci set system.@system[0].log_ip="${CS_CT_IP}"
uci set system.@system[0].log_port='514'
uci set system.@system[0].log_proto='udp'
uci -q set system.@system[0].log_remote='1'
uci -q set system.@system[0].cronloglevel='5'
uci commit system
echo "系统日志外发至 ${CS_CT_IP}:514" >>$LOGFILE

# ---------- 2. 容器开机自启（兜底） ----------
# ⚠️ START 必须是 99 而不是 95：容器正常情况下由 rc.local(S95) 拉起的
#    bootstrap 脚本负责启；这里只作兜底，跑在它之后。
#    两处同优先级会同时 lxc-start 同一个容器，日志刷 "already running"，
#    偶发竞态还会让容器状态卡住。
# start() 里三重判空也很重要：首次开机时 rootfs 还没解压，
# 直接 lxc-start 会因为容器目录不存在而报错。
if [ -d /srv/lxc/ubuntu/rootfs ] || [ -f /opt/lxc-ubuntu.tar.gz ]; then
cat > /etc/init.d/lxc-autostart <<'EOF'
#!/bin/sh /etc/rc.common
START=99
STOP=10
CT_NAME=ubuntu
CT_PATH=/srv/lxc

_running() { lxc-ls -P "$CT_PATH" --running 2>/dev/null | grep -qw "$CT_NAME"; }

start() {
    # 已经跑着就别重复拉
    if _running; then
        logger -t lxc-autostart "容器 $CT_NAME 已在运行，跳过"
        return 0
    fi
    # 容器还没由 bootstrap 解压出来时，悄悄跳过，不刷报错
    if [ ! -d "$CT_PATH/$CT_NAME/rootfs" ]; then
        logger -t lxc-autostart "rootfs 尚未就绪，跳过（等待 bootstrap 解压）"
        return 0
    fi
    logger -t lxc-autostart "拉起容器 $CT_NAME"
    lxc-start -P "$CT_PATH" -n "$CT_NAME" -d
}

stop() {
    _running && lxc-stop -P "$CT_PATH" -n "$CT_NAME"
    return 0
}
EOF
    chmod +x /etc/init.d/lxc-autostart
    /etc/init.d/lxc-autostart enable
    echo "已安装 lxc-autostart (START=99)" >>$LOGFILE
fi

# ---------- 3. 预填 bouncer 配置（api_key 留空，由引导脚本补上） ----------
#       bouncer 是匿名段，必须用 @bouncer[n]，不能写 crowdsec.bouncer.xxx
if [ -f /etc/config/crowdsec ]; then
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
        echo "已预填 bouncer 段: $CS_SEC" >>$LOGFILE
    fi
else
    echo "未发现 /etc/config/crowdsec：bouncer 包没打进固件，跳过预填" >>$LOGFILE
fi

# ---------- 4. 引导脚本兜底授权 ----------
chmod +x /usr/sbin/crowdsec-lxc-bootstrap.sh 2>/dev/null
chmod +x /etc/rc.local 2>/dev/null
echo "CrowdSec 引导已就绪" >>$LOGFILE

exit 0
