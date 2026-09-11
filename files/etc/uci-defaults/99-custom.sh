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

# 禁用WAN口
uci set network.wan.disabled='1'
uci set network.wan6.disabled='1'

# 创建一个br_lan接口 命名为br-lan
uci set network.br_lan=device
uci set network.br_lan.name='br-lan'
uci set network.br_lan.type='bridge'
uci set network.br_lan.bridge_empty='1'

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
uci set network.lan.ipaddr='10.1.1.200'
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.gateway='10.1.1.1'
uci set network.lan.dns='10.1.1.1'

# 忽略lan口的dhcp/v6
uci set dhcp.lan.ignore='1'
uci set dhcp.lan.dhcpv4='disabled'
uci set dhcp.lan.ra='disabled'
uci set dhcp.lan.dhcpv6='disabled'
uci set dhcp.lan.ndp='disabled'

# 关闭dhcp页面的强制dhcp客户端（唯一客户端））
uci -q del dhcp.@dnsmasq[0].authoritative

# 提交
uci commit

# 已知修复在新建br_lan接口情况下会出现一个默认的br-lan接口cfg030f15
# 提交
# uci del network.cfg030f15
# uci commit

# 输出信息
echo "default router ip is 10.1.1.200" >> $LOGFILE

# 设置主题为argon(其他主题不好用 进阶设置那个看了没什么用）
# 语言为auto 开启表格筛选器
  uci set luci.main.mediaurlbase="/luci-static/argon"
  uci set luci.main.lang='auto'
  uci set luci.main.tablefilter='1'
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
# 扩大docker涵盖的子网范围 '172.16.0.0/12'以及'10.16.0.0/12'
# 方便各类docker容器的端口顺利通过防火墙 
if command -v dockerd >/dev/null 2>&1; then
    echo "检测到 Docker，正在配置防火墙规则..."
    FW_FILE="/etc/config/firewall"

    # 1. 安全删除所有名为 'docker' 的 zone（正确遍历匿名段）
    for idx in $(uci show firewall | grep "=zone" | cut -d[ -f2 | cut -d] -f1 | sort -rn); do
        name=$(uci get firewall.@zone[$idx].name 2>/dev/null)
        if [ "$name" = "docker" ]; then
            echo "Deleting zone @zone[$idx] (name=docker)"
            uci delete firewall.@zone[$idx]
        fi
    done

    # 2. 安全删除所有涉及 'docker' 的 forwarding
    for idx in $(uci show firewall | grep "=forwarding" | cut -d[ -f2 | cut -d] -f1 | sort -rn); do
        src=$(uci get firewall.@forwarding[$idx].src 2>/dev/null)
        dest=$(uci get firewall.@forwarding[$idx].dest 2>/dev/null)
        if [ "$src" = "docker" ] || [ "$dest" = "docker" ]; then
            echo "Deleting forwarding @forwarding[$idx] (src=$src, dest=$dest)"
            uci delete firewall.@forwarding[$idx]
        fi
    done

    # 3. 提交删除操作
    uci commit firewall

    # 4. 追加新配置（EOF 必须顶格，device 必须启用）
    cat >> "$FW_FILE" << 'EOF'
config zone
    option name 'docker'
    option input 'ACCEPT'
    option output 'ACCEPT'
    option forward 'ACCEPT'
    list network 'docker0'
    list network 'docker'
    list network '172.17.0.0/16'

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

    # 5. 禁用 Docker 自动 iptables 管理（防止规则被覆盖）
    # 如果 jq 不存在则尝试安装；安装失败则跳过 jq 方案
    if ! command -v jq >/dev/null 2>&1; then
        opkg update >/dev/null 2>&1 && opkg install jq >/dev/null 2>&1
    fi

    DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
    mkdir -p /etc/docker

    if [ ! -s "$DOCKER_DAEMON_JSON" ]; then
        echo '{}' > "$DOCKER_DAEMON_JSON"
    fi

    tmp=$(mktemp)
    if command -v jq >/dev/null 2>&1 && jq '.iptables = false' "$DOCKER_DAEMON_JSON" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$DOCKER_DAEMON_JSON"
    else
    # jq 不可用或解析失败，安全降级
        echo '{"iptables": false}' > "$DOCKER_DAEMON_JSON"
        rm -f "$tmp"
    fi
    # 6. 重载防火墙使配置生效
    /etc/init.d/firewall restart
    echo "✅ Docker 防火墙规则配置完成并已生效"
else
    echo "未检测到 Docker，跳过防火墙配置。"
fi

exit 0
