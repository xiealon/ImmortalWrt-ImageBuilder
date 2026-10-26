#!/bin/bash
# 【v.180.79】固件版本标记 —— 与 crowdsec-lxc-bootstrap.sh 的 SCRIPT_VER 同步，每次改脚本一起改

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-ssr-plus luci-i18n-ssr-plus-zh-cn naiveproxy v2ray-geoip v2ray-geosite shadowsocksr-libev-ssr-check shadowsocksr-libev-ssr-local shadowsocksr-libev-ssr-nat shadowsocksr-libev-ssr-redir shadowsocksr-libev-ssr-server dns2tcp ipt2socks lua-neturl kmod-nft-tproxy kmod-nft-socket"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES clashoo luci-app-clashoo luci-i18n-clashoo-zh-cn geoview kmod-tun kmod-inet-diag kmod-nft-tproxy kmod-nft-socket luci-compat bash curl ip-full unzip"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES geoview sing-box luci-compat kmod-tun kmod-inet-diag kmod-nft-tproxy kmod-nft-socket bash curl ip-full lua unzip"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-openvpn luci-i18n-openvpn-zh-cn openvpn-openssl"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-zerotier luci-i18n-zerotier-zh-cn zerotier"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-proto-wireguard kmod-wireguard wireguard-tools"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES tailscale luci-app-tailscale-community luci-i18n-tailscale-community-zh-cn kmod-tun"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-partexp luci-i18n-partexp-zh-cn e2fsprogs tune2fs blkid kmod-fs-ext4 kmod-fs-vfat"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES lucky luci-app-lucky luci-i18n-lucky-zh-cn yq kmod-dummy ca-bundle"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-taskplan luci-i18n-taskplan-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-rtp2httpd luci-i18n-rtp2httpd-zh-cn rtp2httpd"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-ddns-go luci-i18n-ddns-go-zh-cn ddns-go"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-xfrpc luci-i18n-xfrpc-zh-cn xfrpc"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-timewol luci-i18n-timewol-zh-cn etherwake"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-acme luci-i18n-acme-zh-cn ca-certificates acme-acmesh acme-common"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-aria2 luci-i18n-aria2-zh-cn aria2"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-banip luci-i18n-banip-zh-cn banip"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-cifs-mount luci-i18n-cifs-mount-zh-cn kmod-fs-cifs cifsmount"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-cloudflared luci-i18n-cloudflared-zh-cn cloudflared"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-email luci-i18n-email-zh-cn msmtp"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-eoip luci-i18n-eoip-zh-cn eoip"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-hd-idle luci-i18n-hd-idle-zh-cn hd-idle"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-ksmbd luci-i18n-ksmbd-zh-cn ksmbd-server kmod-fs-ksmbd kmod-fs-smbfs-common"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-keepalived luci-i18n-keepalived-zh-cn keepalived"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-nfs luci-i18n-nfs-zh-cn nfs-kernel-server nfs-utils kmod-fs-nfs kmod-fs-nfsd"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-ngrokc luci-i18n-ngrokc-zh-cn ngrokc"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-nps luci-i18n-nps-zh-cn nps"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-p910nd luci-i18n-p910nd-zh-cn p910nd kmod-usb-printer"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-sqm luci-i18n-sqm-zh-cn sqm-scripts"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-ttyd luci-i18n-ttyd-zh-cn ttyd"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-uhttpd luci-i18n-uhttpd-zh-cn uhttpd"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-upnp luci-i18n-upnp-zh-cn miniupnpd-nftables"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-usb-printer luci-i18n-usb-printer-zh-cn kmod-usb-printer"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-wechatpush luci-i18n-wechatpush-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-crowdsec-firewall-bouncer luci-i18n-crowdsec-firewall-bouncer-zh-cn crowdsec-firewall-bouncer"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-dockerman luci-i18n-dockerman-zh-cn dockerd cgroup-tools kmod-veth"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES liblxc lxc lxc-common lxc-configs lxc-auto lxc-init lxc-create lxc-start lxc-stop lxc-destroy lxc-freeze lxc-unfreeze lxc-autostart lxc-ls lxc-info lxc-monitor lxc-top lxc-snapshot lxc-checkconfig lxc-config lxc-attach lxc-console lxc-execute lxc-device lxc-copy lxc-cgroup lxc-unshare lxc-usernsexec lxc-wait luci-app-lxc rpcd-mod-lxc luci-i18n-lxc-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES xz tar ip-full kmod-veth kmod-ikconfig kmod-br-netfilter glib2 crconf davici swanmon kmod-crypto-chacha20poly1305"
