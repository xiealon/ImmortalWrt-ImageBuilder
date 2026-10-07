#!/bin/bash
# ============= imm仓库外的第三方插件==============
# 启用 则打开注释 但此文件也可以处理仓库内的软件去留 本质上是做了一个PACKAGES字符串的拼接
# 目前已将集成store的操作放置在 工作流的UI 选项 用户自行勾选 则集成  不勾选则不集成 以减少修改此文件的次数
# 代理相关
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-openvpn-server luci-i18n-openvpn-server-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES openvpn-openssl  luci-i18n-openvpn-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES easytier luci-app-easytier"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES geoview xray-core sing-box hysteria kmod-nft-socket kmod-nft-tproxy luci-app-passwall2 luci-i18n-passwall2-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-openclash luci-compat kmod-tun kmod-inet-diag bash curl lua unzip"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-proto-wireguard"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-tailscale-community luci-i18n-tailscale-community-zh-cn"
# 新增 clashoo by kenzok8 注意若集成clashoo 则不能集成nikki （nikki不好用））
CUSTOM_PACKAGES="$CUSTOM_PACKAGES clashoo luci-app-clashoo luci-i18n-clashoo-zh-cn"
# 分区扩容 by sirpdboy 
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-partexp luci-i18n-partexp-zh-cn"
# Lucky大吉 
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-lucky lucky"
# 任务设置
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-taskplan luci-i18n-taskplan-zh-cn"
# Bandix流量监控 by timsaya
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-bandix luci-i18n-bandix-zh-cn"
# IPTV 流媒体转发服务器 - rtp2httpd by stackia
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-rtp2httpd luci-i18n-rtp2httpd-zh-cn"
# 静态文件服务器dufs
CUSTOM_PACKAGES="$CUSTOM_PACKAGES dufs"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-dufs-zh-cn"

#===========================以下imm仓库内的软件==============================↓
# sftp+udp2raw
CUSTOM_PACKAGES="$CUSTOM_PACKAGES openssh-sftp-server udp2raw"
# usb无线网卡+随身WiFi
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-3ginfo-lite-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES usb-modeswitch usbutils"
# banip//crowdsec-firewall-bouncer 配合容器crowdsec增强安全性
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-banip-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES crowdsec-firewall-bouncer"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-crowdsec-firewall-bouncer "
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-crowdsec-firewall-bouncer-zh-cn"
#
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-acl-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES ca-certificates acme luci-app-acme luci-i18n-acme-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-adblock-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-aria2-zh-cn"
#
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-cifs-mount-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-cloudflared-zh-cn"
#
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-daed-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-ddns-go-zh-cn"
#
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-email-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-eoip-zh-cn"
#
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-frpc-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-frps-zh-cn"
#
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-hd-idle-zh-cn"
#
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-ksmbd-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-keepalived-zh-cn"
# smart＆mosdns
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-smartdns-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-mosdns luci-i18n-mosdns-zh-cn v2ray-geoip v2ray-geosite"
#
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-nfs-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-ngrokc-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-nps-zh-cn"
#
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-sqm-zh-cn"
# wol
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-wol-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-timewol-zh-cn"
#
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-udpxy-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-uhttpd-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-upnp-zh-cn"
# print
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-usb-printer-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-p910nd-zh-cn"
#
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-wechatpush-zh-cn"

# ######
# lxc
# 依赖工具与 cgroup
CUSTOM_PACKAGES="$CUSTOM_PACKAGES xz tar liblzma gnupg getopt"
# ⚠️ 仅 24.x（opkg）可用：这两个包不在 ImmortalWrt 官方源里，靠的是你加挂的第三方 opkg 源。
#    25.12 走的是 shell/apk-custom-packages.sh（apk 版），那边不含这两行，别往那边搬——
#    apk 源里没有它们，会让 make image 直接失败。25.12 改用 99-custom.sh 里的 cgroup2 挂载兜底。
CUSTOM_PACKAGES="$CUSTOM_PACKAGES cgroupfs-mount cgroup-tools"
# ip-full：引导脚本用 `ip link show lxcbr0` 等网桥，busybox 的 ip-tiny 功能不全
CUSTOM_PACKAGES="$CUSTOM_PACKAGES ip-full"
# 内核模块
CUSTOM_PACKAGES="$CUSTOM_PACKAGES kmod-ikconfig kmod-veth"
# LXC 核心
CUSTOM_PACKAGES="$CUSTOM_PACKAGES liblxc lxc lxc-common lxc-templates"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES lxc-attach lxc-auto lxc-autostart lxc-cgroup lxc-checkconfig"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES lxc-config lxc-configs lxc-console lxc-copy lxc-create lxc-destroy"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES lxc-device lxc-execute lxc-freeze lxc-hooks lxc-info lxc-init"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES lxc-ls lxc-monitor lxc-monitord lxc-snapshot lxc-start lxc-stop"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES lxc-top lxc-unfreeze lxc-unprivileged lxc-unshare lxc-user-nic lxc-usernsexec lxc-wait"
# LuCI 网页管理（服务 → LXC 容器，含中文）
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-lxc rpcd-mod-lxc luci-i18n-lxc-zh-cn"
# ---- strongSwan / IPsec（swanctl 后端，24.10 / opkg）----
# 注意：luci-app-strongswan-swanctl 只声明了 +strongswan-swanctl +swanmon，
# 而 strongswan 主包里**不含 charon 守护进程**，必须显式装 strongswan-charon
# （或直接用元包 strongswan-default），否则编译能过、LuCI 页面能开，但 swanctl 跑不起来
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-strongswan-swanctl"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES strongswan-swanctl strongswan-mod-vici strongswan-charon"
# strongswan 核心插件集（名单与 strongswan-default 的 29 个 mod 完全一致）
CUSTOM_PACKAGES="$CUSTOM_PACKAGES strongswan-mod-aes strongswan-mod-attr strongswan-mod-connmark strongswan-mod-constraints strongswan-mod-des strongswan-mod-dnskey"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES strongswan-mod-fips-prf strongswan-mod-gmp strongswan-mod-hmac strongswan-mod-openssl strongswan-mod-kernel-netlink strongswan-mod-md5"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES strongswan-mod-mgf1 strongswan-mod-pem strongswan-mod-pgp strongswan-mod-pkcs1 strongswan-mod-pubkey strongswan-mod-random"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES strongswan-mod-rc2 strongswan-mod-resolve strongswan-mod-revocation strongswan-mod-sha1 strongswan-mod-sha2 strongswan-mod-socket-default"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES strongswan-mod-sshkey strongswan-mod-updown strongswan-mod-x509 strongswan-mod-xauth-generic strongswan-mod-xcbc"
# LuCI 页面状态源：swanmon 把 charon 的 vici 输出转成 JSON 喂给前端
# 缺了它页面能开但一片空白；swanmon 依赖 davici + libjson-c（24.10 还额外依赖 glib2）
CUSTOM_PACKAGES="$CUSTOM_PACKAGES swanmon davici libjson-c glib2"
# 内核：XFRM / IPsec 转发
CUSTOM_PACKAGES="$CUSTOM_PACKAGES kmod-ipsec kmod-ipsec4 kmod-ipsec6"
# 24.10 的 strongswan 主包还要这 5 个 kmod-crypto + 2 个 kmod-lib-zlib（25.12 已不需要，别往 apk 那份搬）
CUSTOM_PACKAGES="$CUSTOM_PACKAGES kmod-crypto-manager kmod-crypto-aead kmod-crypto-authenc kmod-crypto-cbc kmod-crypto-des kmod-crypto-echainiv"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES kmod-crypto-hmac kmod-crypto-md5 kmod-crypto-sha1 kmod-lib-zlib-inflate kmod-lib-zlib-deflate"
