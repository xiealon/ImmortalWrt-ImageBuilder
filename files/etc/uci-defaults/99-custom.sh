#!/bin/sh
LOGFILE="/etc/config/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >>$LOGFILE
# WAN/LAN zone input 改由 crowdsec-lxc-bootstrap 按 name 定责管理
#（单网口放行 WAN / 多网口收紧 WAN + LAN 放开），不再在此硬设 @zone[N] 索引
# v.78-bp 起网络基线（桥/地址/DHCP 让权/WAN 禁用/DNS/docker 防火墙/服务监听面）
# 全部由 bootstrap 每次开机按需校准；本文件只做非网络的一次性首启设置

  uci set luci.main.mediaurlbase="/luci-static/bootstrap"
  uci set luci.main.lang='auto'
  uci set luci.main.tablefilters='1'
  uci commit

FILE_PATH="/etc/openwrt_release"
NEW_DESCRIPTION="Packaged by DeepSeek"
sed -i "s/DISTRIB_DESCRIPTION='[^']*'/DISTRIB_DESCRIPTION='$NEW_DESCRIPTION'/" "$FILE_PATH"

CS_HOME='/etc/crowdsec'
if [ -d "$CS_HOME" ] || [ -f "$CS_HOME/lxc-crowdsec.tar.gz" ] || [ -f "$CS_HOME/lxc-ubuntu.tar.gz" ] || [ -d /srv/lxc/ubuntu/rootfs ]; then
    mkdir -p "$CS_HOME" 2>/dev/null
    # 保留清单要覆盖两种镜像名：极简版 lxc-crowdsec.tar.gz 与历史 systemd 版 lxc-ubuntu.tar.gz。
    # 少了它，sysupgrade 之后镜像被抹掉、rc.local 走 --net-only，容器再也起不来。
    for _keep in "$CS_HOME/lxc-crowdsec.tar.gz" "$CS_HOME/lxc-ubuntu.tar.gz"; do
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
