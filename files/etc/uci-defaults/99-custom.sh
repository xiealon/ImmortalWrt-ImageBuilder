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

    

    # 设置路由器管理后台地址
#     IP_VALUE_FILE="/etc/config/custom_router_ip.txt"
#     if [ -f "$IP_VALUE_FILE" ]; then
#         CUSTOM_IP=$(cat "$IP_VALUE_FILE")
        # 用户在UI上设置的路由器后台管理地址
#         uci set network.lan.ipaddr=$CUSTOM_IP
#         echo "custom router ip is $CUSTOM_IP" >> $LOGFILE
#     else
         uci set network.lan.ipaddr='10.1.1.200'
         echo "default router ip is 10.1.1.200" >> $LOGFILE
#     fi

# 禁用wan接口  
  uci set network.wan.disable='1'
  uci set network.wan6.disable='1'

  
# 所有接口添加为lan
  uci set network.lan.ifname='eth0 eth1 eth2 eth3 eth4 eth5'

# LAN口设置静态IP
  uci set network.lan.proto='static'
  
# netmask子网掩码
   uci set network.lan.netmask='255.255.255.0'

# 网关设置
  uci set network.lan.gateway='10.1.1.1'
  
# dns 设置
  uci set network.lan.dns='10.1.1.1'
  
# 阿里云公共 DNS 223.5.5.5 223.6.6.6
# 腾讯 DNSPod 119.29.29.29 182.254.116.116
# 百度公共 DNS 180.76.76.76
# 华为云 DNS 122.112.208.1 139.9.23.90
# Google Public DNS 8.8.8.8 8.8.4.4
# Cloudflare DNS

# 关闭DHCP与DHCPV6以及RA 
# 关闭dnsmasq强制DHCP服务器
  
  uci set network.lan.type='bridge'
  uci set dhcp.lan.ignore='1'
  uci set dhcp.lan.dhcpv4='disabled'
  uci set dhcp.lan.ra='disabled'
  uci set dhcp.lan.dhcpv6='disabled'
  uci set dhcp.lan.ndp='disabled'
  uci del dhcp.cfg01411c.authoritative
  uci commit network
  uci commit dhcp

# 设置主题为argon(其他主题不好用 进阶设置那个看了没什么用）
# 语言为auto 开启表格筛选器
  uci set luci.main.mediaurlbase="/luci-static/argon"
  uci set luci.main.lang='auto'
  uci set luci.main.tablefilter='1'
  uci commit luci

# 默认开启qbittorrent服务//种子下载
  uci set qbittorrent.config.enabled='1'
  uci commit qbittorrent

    # PPPoE设置
#     echo "enable_pppoe value: $enable_pppoe" >>$LOGFILE
#     if [ "$enable_pppoe" = "yes" ]; then
#         echo "PPPoE enabled, configuring..." >>$LOGFILE
#         uci set network.wan.proto='pppoe'
#         uci set network.wan.username="$pppoe_account"
#         uci set network.wan.password="$pppoe_password"
#         uci set network.wan.peerdns='1'
#         uci set network.wan.auto='1'
#         uci set network.wan6.proto='none'
#         echo "PPPoE config done." >>$LOGFILE
#     else
#         echo "PPPoE not enabled." >>$LOGFILE
#     fi
#
#     uci commit network
# fi

# 设置所有网口可访问网页终端
  uci delete ttyd.@ttyd[0].interface

# 设置所有网口可连接 SSH
  uci set dropbear.@dropbear[0].Interface=''
  uci commit

# 设置编译作者信息
FILE_PATH="/etc/openwrt_release"
NEW_DESCRIPTION="Packaged by wukongdaily"
sed -i "s/DISTRIB_DESCRIPTION='[^']*'/DISTRIB_DESCRIPTION='$NEW_DESCRIPTION'/" "$FILE_PATH"

# 若luci-app-advancedplus (进阶设置)已安装 则去除zsh的调用 防止命令行报 /usb/bin/zsh: not found的提示
if [ -f /usr/lib/lua/luci/controller/advancedplus.lua ]; then
    sed -i '/\/usr\/bin\/zsh/d' /etc/profile
    sed -i '/\/bin\/zsh/d' /etc/init.d/advancedplus
    sed -i '/\/usr\/bin\/zsh/d' /etc/init.d/advancedplus
    echo "fix ttyd show msg: /usb/bin/zsh: not found" >>$LOGFILE
fi

# 只有安装了 luci-app-quickfile 才执行
if [ -f /usr/bin/quickfile ]; then
    uci set nginx.global.uci_enable='true'
    uci del nginx._lan 2>/dev/null
    uci del nginx._redirect2ssl 2>/dev/null

    uci add nginx server
    uci rename nginx.@server[-1]='_lan'

    uci set nginx._lan.server_name='_lan'
    uci add_list nginx._lan.listen='80 default_server'
    uci add_list nginx._lan.listen='[::]:80 default_server'
    uci add_list nginx._lan.include='conf.d/*.locations'
    uci set nginx._lan.access_log='off; # logd openwrt'

    uci commit nginx
    echo "fix quickfile nginx config" >>$LOGFILE
fi

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
