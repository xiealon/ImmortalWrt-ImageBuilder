#!/bin/bash
# 【v.180.79】固件版本标记 —— 与 crowdsec-lxc-bootstrap.sh 的 SCRIPT_VER 同步，每次改脚本一起改


CUSTOM_PACKAGES="$CUSTOM_PACKAGES aria2 luci-app-aria2 luci-i18n-aria2-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES banip luci-app-banip luci-i18n-banip-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES ca-certificates acme luci-app-acme luci-i18n-acme-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES clashoo luci-app-clashoo luci-i18n-clashoo-zh-cn geoview kmod-tun kmod-inet-diag kmod-nft-tproxy kmod-nft-socket luci-compat bash curl ip-full unzip"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES cloudflared luci-app-cloudflared luci-i18n-cloudflared-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES crowdsec-firewall-bouncer luci-app-crowdsec-firewall-bouncer luci-i18n-crowdsec-firewall-bouncer-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES ddns-go luci-app-ddns-go luci-i18n-ddns-go-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES dockerd luci-app-dockerman luci-i18n-dockerman-zh-cn cgroup-tools kmod-veth"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES easytier luci-app-easytier"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES eoip luci-app-eoip luci-i18n-eoip-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES etherwake luci-app-timewol luci-i18n-timewol-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES geoview sing-box luci-compat kmod-tun kmod-inet-diag kmod-nft-tproxy kmod-nft-socket bash curl ip-full lua unzip"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES hd-idle luci-app-hd-idle luci-i18n-hd-idle-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES keepalived luci-app-keepalived luci-i18n-keepalived-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES kmod-fs-cifs cifsmount luci-app-cifs-mount luci-i18n-cifs-mount-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES kmod-nft-tproxy kmod-nft-socket xray-core naiveproxy luci-app-ssr-plus luci-i18n-ssr-plus-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES kmod-usb-printer luci-app-usb-printer luci-i18n-usb-printer-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES ksmbd-server kmod-fs-ksmbd kmod-fs-smbfs-common luci-app-ksmbd luci-i18n-ksmbd-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES liblxc lxc lxc-common lxc-templates lxc-attach lxc-auto lxc-autostart lxc-cgroup lxc-checkconfig lxc-config lxc-configs lxc-console lxc-copy lxc-create lxc-destroy lxc-device lxc-execute lxc-freeze lxc-hooks lxc-info lxc-init lxc-ls lxc-monitor lxc-monitord lxc-snapshot lxc-start lxc-stop lxc-top lxc-unfreeze lxc-unprivileged lxc-unshare lxc-user-nic lxc-usernsexec lxc-wait luci-app-lxc rpcd-mod-lxc luci-i18n-lxc-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-3ginfo-lite luci-i18n-3ginfo-lite-zh-cn usb-modeswitch usbutils"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-acl luci-i18n-acl-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-openvpn luci-i18n-openvpn-zh-cn openvpn-openssl"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-partexp luci-i18n-partexp-zh-cn e2fsprogs tune2fs blkid kmod-fs-ext4 kmod-fs-vfat"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-rtp2httpd luci-i18n-rtp2httpd-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-strongswan-swanctl strongswan-swanctl strongswan-mod-vici strongswan-charon strongswan-mod-aes strongswan-mod-attr strongswan-mod-connmark strongswan-mod-constraints strongswan-mod-des strongswan-mod-dnskey strongswan-mod-fips-prf strongswan-mod-gmp strongswan-mod-hmac strongswan-mod-openssl strongswan-mod-kernel-netlink strongswan-mod-md5 strongswan-mod-mgf1 strongswan-mod-pem strongswan-mod-pgp strongswan-mod-pkcs1 strongswan-mod-pubkey strongswan-mod-random strongswan-mod-rc2 strongswan-mod-resolve strongswan-mod-revocation strongswan-mod-sha1 strongswan-mod-sha2 strongswan-mod-socket-default strongswan-mod-sshkey strongswan-mod-updown strongswan-mod-x509 strongswan-mod-xauth-generic strongswan-mod-xcbc swanmon davici crconf libjson-c5 glib2 kmod-ipsec kmod-ipsec4 kmod-ipsec6 kmod-crypto-manager kmod-crypto-aead kmod-crypto-authenc kmod-crypto-cbc kmod-crypto-des kmod-crypto-echainiv kmod-crypto-hmac kmod-crypto-md5 kmod-crypto-sha1 kmod-lib-zlib-inflate kmod-lib-zlib-deflate"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-taskplan luci-i18n-taskplan-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-wechatpush luci-i18n-wechatpush-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-proto-wireguard kmod-wireguard wireguard-tools"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES lucky luci-app-lucky yq kmod-dummy ca-bundle"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES miniupnpd-nftables luci-app-upnp luci-i18n-upnp-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES msmtp luci-app-email luci-i18n-email-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES nfs-kernel-server nfs-utils kmod-fs-nfs kmod-fs-nfsd luci-app-nfs luci-i18n-nfs-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES ngrokc luci-app-ngrokc luci-i18n-ngrokc-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES nps luci-app-nps luci-i18n-nps-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES openssh-sftp-server udp2raw"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES p910nd kmod-usb-printer luci-app-p910nd luci-i18n-p910nd-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES smartdns luci-app-smartdns luci-i18n-smartdns-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES sqm-scripts luci-app-sqm luci-i18n-sqm-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES tailscale luci-app-tailscale-community luci-i18n-tailscale-community-zh-cn kmod-tun"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES uhttpd luci-app-uhttpd luci-i18n-uhttpd-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES xfrpc luci-app-xfrpc luci-i18n-xfrpc-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES xz tar liblzma gnupg getopt cgroup-tools ip-full kmod-ikconfig kmod-veth kmod-br-netfilter"
