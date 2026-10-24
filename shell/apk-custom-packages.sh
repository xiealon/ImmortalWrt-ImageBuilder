#!/bin/bash
# 【v.108.73】固件版本标记 —— 与 crowdsec-lxc-bootstrap.sh 的 SCRIPT_VER 同步，每次改脚本一起改

# 【v.108.73】本文件的版本号，由 build25.sh 打进构建日志（理由同 24.10 线）。
APK_PKGS_VER="2026-10-24.108.73"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-partexp luci-i18n-partexp-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES bandix luci-app-bandix luci-i18n-bandix-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-rtp2httpd luci-i18n-rtp2httpd-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-lucky lucky luci-i18n-lucky-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-daed-zh-cn"
# 【v.108.72】清掉 ssr-plus 的遗留内核：hysteria / xray-core / naiveproxy（与 24.10 线同一依据）。
# 核实方式：拆 luci-app-clashoo 的 ipk 扫界面代码 —— 内核只认 mihomo/clash-meta/clash
# 与 /usr/bin/sing-box；"xray" 与 "naive" 各 0 处命中，"hysteria" 那 1 处是 sing-box
# 配置里的 outbound 类型串，不调用系统二进制。
# 保留 sing-box（clashoo 双内核之一）与 geoview（独立工具）。
CUSTOM_PACKAGES="$CUSTOM_PACKAGES geoview sing-box luci-compat kmod-tun kmod-inet-diag kmod-nft-tproxy kmod-nft-socket bash curl lua unzip"
# 【v.108.71】代理面板 luci-app-ssr-plus → clashoo（上游 kenzok8/openwrt-clashoo）。
# 25.12 用 apk 格式，包源是 wukongdaily/apk（build25.sh 里 clone 的就是它）——
# 不是 store：store 里只有 ipk，而 apk-prepare-packages.sh 只捞 *.apk，两边不能混。
# run/x86/clashoo/ 下三个文件，深度正好是 2，命中 apk-prepare-packages.sh 的
# `find "$BASE_DIR" -mindepth 2 -maxdepth 2 -name '*.apk'`：
#   clashoo-2026.05.27~38cb06d-r1.apk              17,584,594 B（自带 mihomo 内核）
#   luci-app-clashoo-1.24.6-r1.apk                    380,759 B
#   luci-i18n-clashoo-zh-cn-1.24.6-r1.apk               8,124 B
# 依赖按 clashoo 的 control 补齐：yq / kmod-dummy / ca-bundle
# （libc / firewall4 / ip-full / kmod-inet-diag / kmod-nft-socket / kmod-nft-tproxy /
#   kmod-tun 上面这行本来就有）。
CUSTOM_PACKAGES="$CUSTOM_PACKAGES clashoo luci-app-clashoo luci-i18n-clashoo-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES yq kmod-dummy ca-bundle"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-taskplan luci-i18n-taskplan-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-mosdns luci-i18n-mosdns-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-openvpn-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-zerotier-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-proto-wireguard"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-tailscale-community luci-i18n-tailscale-community-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-ddns-go-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-xfrpc-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-timewol-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-3ginfo-lite-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-acme-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-adblock-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-aria2-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-banip-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-cifs-mount-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-cloudflared-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-email-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-eoip-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-hd-idle-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-ksmbd-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-keepalived-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-nfs-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-ngrokc-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-nps-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-p910nd-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-sqm-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-ttyd-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-uhttpd-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-upnp-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-usb-printer-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-wechatpush-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES liblxc lxc lxc-common lxc-configs lxc-auto lxc-init "
CUSTOM_PACKAGES="$CUSTOM_PACKAGES lxc-create lxc-start lxc-stop lxc-destroy lxc-freeze lxc-unfreeze lxc-autostart"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES lxc-ls lxc-info lxc-monitor lxc-top lxc-snapshot lxc-checkconfig lxc-config"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES lxc-attach lxc-console lxc-execute lxc-device lxc-copy lxc-cgroup"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES lxc-unshare lxc-usernsexec lxc-wait"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-lxc rpcd-mod-lxc luci-i18n-lxc-zh-cn"

# Docker 常驻（v.99-bp.2）：纯 X86 平台，不再提供「要不要 docker」的开关。
# 原来 Include Docker 只往 PACKAGES 里加了一个中文语言包，dockerd 本身没进固件。
CUSTOM_PACKAGES="$CUSTOM_PACKAGES dockerd luci-app-dockerman luci-i18n-dockerman-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES crowdsec-firewall-bouncer"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-crowdsec-firewall-bouncer"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-crowdsec-firewall-bouncer-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES xz tar ip-full"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES kmod-veth kmod-ikconfig"
# docker 桥接过滤（v.99-bp.3）：不在 dockerd 的 DEPENDS 里，但 docker 的 sysctl drop-in
# （/etc/sysctl.d/12-br-netfilter-ip.conf）明确要求排在 kmod-br-netfilter 的 11-br-netfilter.conf 之后。
# 注意：imm.config 里的 kmod-br-netfilter=m 对 ImageBuilder 无效，包必须写在 PACKAGES 里。
CUSTOM_PACKAGES="$CUSTOM_PACKAGES kmod-br-netfilter"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES glib2 crconf davici swanmon kmod-crypto-chacha20poly1305"
