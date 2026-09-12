#!/bin/bash
# ============= imm仓库外的第三方插件==============
# 启用 则打开注释 但此文件也可以处理仓库内的软件去留 本质上是做了一个PACKAGES字符串的拼接
# 目前已将集成store的操作放置在 工作流的UI 选项 用户自行勾选 则集成  不勾选则不集成 以减少修改此文件的次数
# 高级卸载 by YT Vedio Talk
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-uninstall"
# 去广告adghome
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-adguardhome"
# 代理相关
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-openvpn-server luci-i18n-openvpn-server-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-openvpn-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-dae-zh-cn"
# 已更新到daed 1.28.0 版本
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-daed-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES geoview xray-core sing-box hysteria luci-i18n-passwall-zh-cn"
# passwall2 已更新到26.5.1
CUSTOM_PACKAGES="$CUSTOM_PACKAGES geoview xray-core sing-box hysteria kmod-nft-socket kmod-nft-tproxy luci-app-passwall2 luci-i18n-passwall2-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-openclash luci-compat kmod-tun kmod-inet-diag kmod-nft-tproxy bash curl ip-full unzip"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-homeproxy-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES momo luci-app-momo luci-i18n-momo-zh-cn"
# 新增 clashoo by kenzok8 注意若集成clashoo 则不能集成nikki 目前它们俩配置冲突
CUSTOM_PACKAGES="$CUSTOM_PACKAGES clashoo luci-app-clashoo luci-i18n-clashoo-zh-cn"
# VPN
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-proto-wireguard"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-tailscale-community luci-i18n-tailscale-community-zh-cn"
# 分区扩容 by sirpdboy 
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-partexp luci-i18n-partexp-zh-cn"
# MosDNS
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-mosdns luci-i18n-mosdns-zh-cn"
# Lucky大吉 
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-lucky lucky"
# 任务设置
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-taskplan luci-i18n-taskplan-zh-cn"
# Easytier
CUSTOM_PACKAGES="$CUSTOM_PACKAGES easytier luci-app-easytier"
# IPSec VPN 服务器
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-ipsec-vpnd-zh-cn"
# Bandix流量监控 by timsaya
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-bandix luci-i18n-bandix-zh-cn"
# IPTV 流媒体转发服务器 - rtp2httpd by stackia
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-rtp2httpd luci-i18n-rtp2httpd-zh-cn"
# 静态文件服务器dufs
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-dufs-zh-cn"

#===========================以下imm仓库内的软件==============================↓
CUSTOM_PACKAGES="$CUSTOM_PACKAGES openssh-sftp-server"
# usb无线网卡+随身WiFi
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-3ginfo-lite-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES usb-modeswitch usbutils"
# banip
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-banip-zh-cn"
# crowd
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-crowdsec-firewall-bouncer-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES crowdsec-firewall-bouncer crowdsec"
# luci-app-categorize
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-acl-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-acme-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-adblock-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-aria2-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-cloudflared-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-ddns-go-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-email-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-eoip-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-filebrowser-go-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-frpc-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-frps-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-hd-idle-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-ipsec-vpnd-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-keepalived-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-lxc-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-openlist-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-qbittorrent-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-rustdesk-server-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-smartdns-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-sqm-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-statistics-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-syncthing-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-timewol-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-ttyd-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-udpxy-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-uhttpd-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-upnp-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-usb-printer-zh-cn"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-watchcat-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-wechatpush-zh-cn"
