#!/bin/bash
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-openvpn-server luci-i18n-openvpn-server-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES openvpn-openssl  luci-i18n-openvpn-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES easytier luci-app-easytier"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-proto-wireguard"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-tailscale-community luci-i18n-tailscale-community-zh-cn"
# 【v.108.72】清掉 ssr-plus 的遗留内核：hysteria / xray-core / naiveproxy。
# 依据不是「看起来没人用」，是翻了 luci-app-clashoo 的界面代码（ucode + js 共 21 个文件）：
#   · 内核路径只认 BINARY_PATHS[ mihomo / clash-meta / clash ] 与
#     SINGBOX_BINARY_PATHS[ /usr/bin/sing-box, /usr/local/bin/sing-box ]
#   · "xray"      命中 0 处
#   · "naive"     命中 0 处
#   · "hysteria"  命中 1 处，而且是 sing-box 配置里判断 `outbound/hysteria` 的类型串，
#                 不调用系统 hysteria 二进制
# 这三个包原本只为 luci-app-ssr-plus 提供备用内核，ssr-plus 已换成 clashoo，
# 留着就是几百 MB 分区里的一段死重量 + 三个永远不会被执行的 init 脚本。
# 保留：sing-box（clashoo 的第二内核，/usr/bin/sing-box 是它的首选路径）、
#       geoview（独立的 geo 数据工具，不属 ssr-plus 依赖链）。
CUSTOM_PACKAGES="$CUSTOM_PACKAGES geoview sing-box luci-compat kmod-tun kmod-inet-diag kmod-nft-tproxy kmod-nft-socket bash curl lua unzip"
# 【v.108.71】代理面板 luci-app-ssr-plus → clashoo（上游 kenzok8/openwrt-clashoo）。
# 三个包名逐字取自 wukongdaily/store 的 run/x86/clashoo_2026.05.15_x86_64.run 里实际打的 ipk：
#   clashoo_2026.05.15.d2acf45-r3_x86_64.ipk        （自带 mihomo 内核，Provides: mihomo, clash-meta）
#   luci-app-clashoo_1.23.12-r3_all.ipk
#   luci-i18n-clashoo-zh-cn_1.23.12-r3_all.ipk
# 依赖按其 control 的 Depends 逐条对齐：
#   libc, ca-bundle, yq, firewall4, ip-full, kmod-inet-diag, kmod-nft-socket,
#   kmod-nft-tproxy, kmod-tun, kmod-dummy
#   其中 libc / firewall4 / ip-full / kmod-inet-diag / kmod-nft-socket / kmod-nft-tproxy /
#   kmod-tun 上面这行已经有了；剩下三个在这里补齐：
#   · yq         —— 24.10.6 packages feed 4.45.1-r1（镜像与官方 downloads 双向核实）
#   · kmod-dummy —— clashoo 建透明代理用的 dummy 网卡
#   · ca-bundle  —— base feed 20260601-r1
# 为什么要显式写：ImageBuilder 虽然会解依赖，但它的解析只认 feeds 索引；一旦某个依赖只是
# 「本固件里应该有」而索引对不上，报错会落在 make image 的 Unknown/Missing package 上，
# 看不出缺的是哪一个。显式写在这里，缺哪个就是哪一行，一眼能定位。
CUSTOM_PACKAGES="$CUSTOM_PACKAGES clashoo luci-app-clashoo luci-i18n-clashoo-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES yq kmod-dummy ca-bundle"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES bandix luci-app-bandix luci-i18n-bandix-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-partexp luci-i18n-partexp-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-lucky lucky"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-taskplan luci-i18n-taskplan-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-rtp2httpd luci-i18n-rtp2httpd-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES openssh-sftp-server udp2raw"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-3ginfo-lite-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES usb-modeswitch usbutils"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-banip-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES crowdsec-firewall-bouncer"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-crowdsec-firewall-bouncer "
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-crowdsec-firewall-bouncer-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-acl-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES ca-certificates acme luci-app-acme luci-i18n-acme-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-adblock-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-aria2-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-cifs-mount-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-cloudflared-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-daed-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-ddns-go-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-email-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-eoip-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-hd-idle-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-ksmbd-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-keepalived-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-mosdns luci-i18n-mosdns-zh-cn v2ray-geoip v2ray-geosite"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-nfs-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-ngrokc-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-nps-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-sqm-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-timewol-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-uhttpd-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-upnp-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-usb-printer-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-p910nd-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-wechatpush-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-xfrpc-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES xz tar liblzma gnupg getopt"
# v.108.42：**不再装 cgroupfs-mount**。
# 它的 boot() 第一件事就是把 procd 已经挂好的 cgroup2 卸掉（官方脚本原文注释：
#   "Procd mounts non-hierarchical cgroupfs so unmount first before cgroupfs-mount"），
# 然后按 /proc/cgroups 逐条挂 cgroup v1。而本固件内核是
#   # CONFIG_CGROUP_DEVICE is not set
# 实测 /proc/cgroups 只有 8 个控制器（cpuset cpu cpuacct blkio memory net_cls
# pids rdma），没有 devices；`mount -t cgroup -o devices none ...` 直接回
#   cgroup: Unknown subsys name 'devices'.   (rc=32)
# 于是 dockerd 用 statfs("/sys/fs/cgroup") 判到 tmpfs → 走 v1 → 找 devices
# 控制器 → 必然 `failed to start daemon: Devices cgroup isn't mounted` 退出，
# docker0 永远不建，LuCI「Docker → 网络」页因此全空。
# 删包后 procd 的 cgroup2 保住，dockerd 判到 cgroup2fs → 走 v2，设备控制改由
# BPF 负责（CONFIG_CGROUP_BPF=y），不再需要那个控制器。
# cgroup-tools 保留：libcgroup 2.x 在 v2 下仍可用，且无副作用。
CUSTOM_PACKAGES="$CUSTOM_PACKAGES cgroup-tools"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES ip-full"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES kmod-ikconfig kmod-veth"
# docker 的桥接过滤（v.99-bp.3）：dockerd 的官方 DEPENDS 里**没有**它
# （只有 containerd/runc/tini/iptables/iptables-mod-extra/kmod-ipt-nat/kmod-ipt-physdev/kmod-nf-ipvs/kmod-veth/
#  ca-certificates/uci-firewall），但 docker 自己的 Makefile 会装 /etc/sysctl.d/12-br-netfilter-ip.conf，
# 注释写明「Must be after 11-br-netfilter.conf from kmod-br-netfilter」——没有这个 kmod，
# 那条 sysctl 落不到任何东西上，容器端口映射/桥接过滤就是残的。
# 另外：imm.config 里写着 kmod-br-netfilter=m，但 ImageBuilder 只认 PACKAGES，.config 里的 =m 不进固件。
CUSTOM_PACKAGES="$CUSTOM_PACKAGES kmod-br-netfilter"
# Docker 常驻（v.99-bp.2）：纯 X86 平台，不再提供「要不要 docker」的开关。
# 原来 Include Docker 只往 PACKAGES 里加了一个中文语言包（luci-i18n-dockerman-zh-cn），
# dockerd 本身从来没进过固件（imm.config 里 CONFIG_PACKAGE_dockerd 是 not set），
# 也就是说「带 docker 编译」这个开关一直是空转的。
CUSTOM_PACKAGES="$CUSTOM_PACKAGES dockerd luci-app-dockerman luci-i18n-dockerman-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES liblxc lxc lxc-common lxc-templates"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES lxc-attach lxc-auto lxc-autostart lxc-cgroup lxc-checkconfig"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES lxc-config lxc-configs lxc-console lxc-copy lxc-create lxc-destroy"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES lxc-device lxc-execute lxc-freeze lxc-hooks lxc-info lxc-init"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES lxc-ls lxc-monitor lxc-monitord lxc-snapshot lxc-start lxc-stop"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES lxc-top lxc-unfreeze lxc-unprivileged lxc-unshare lxc-user-nic lxc-usernsexec lxc-wait"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-lxc rpcd-mod-lxc luci-i18n-lxc-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-strongswan-swanctl"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES strongswan-swanctl strongswan-mod-vici strongswan-charon"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES strongswan-mod-aes strongswan-mod-attr strongswan-mod-connmark strongswan-mod-constraints strongswan-mod-des strongswan-mod-dnskey"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES strongswan-mod-fips-prf strongswan-mod-gmp strongswan-mod-hmac strongswan-mod-openssl strongswan-mod-kernel-netlink strongswan-mod-md5"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES strongswan-mod-mgf1 strongswan-mod-pem strongswan-mod-pgp strongswan-mod-pkcs1 strongswan-mod-pubkey strongswan-mod-random"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES strongswan-mod-rc2 strongswan-mod-resolve strongswan-mod-revocation strongswan-mod-sha1 strongswan-mod-sha2 strongswan-mod-socket-default"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES strongswan-mod-sshkey strongswan-mod-updown strongswan-mod-x509 strongswan-mod-xauth-generic strongswan-mod-xcbc"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES swanmon davici libjson-c glib2"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES kmod-ipsec kmod-ipsec4 kmod-ipsec6"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES kmod-crypto-manager kmod-crypto-aead kmod-crypto-authenc kmod-crypto-cbc kmod-crypto-des kmod-crypto-echainiv"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES kmod-crypto-hmac kmod-crypto-md5 kmod-crypto-sha1 kmod-lib-zlib-inflate kmod-lib-zlib-deflate"
