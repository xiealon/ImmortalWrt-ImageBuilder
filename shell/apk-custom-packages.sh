#!/bin/bash
# ============================================================================
# 25.12（apk）第三方 + 官方软件包清单
# 移植自 24.10 的 shell/custom-packages.sh
#
# 【核对依据】每一个包都对着下面这三处真实源核过，确认存在才启用：
#   1) wukongdaily/apk @ master 的 run/x86/ 目录（58 个文件）——第三方 apk 源
#   2) immortalwrt/packages @ master ——官方 net/ libs/ utils/ 包
#   3) immortalwrt/luci    @ master ——官方 luci-app-* / luci-compat 等
#
# 【本文件遵循的原则】
#   · 确认存在 → 启用
#   · 源里没有、或官方注释明确说别装的 → 保持注释，并在原地写明原因
#   · 已在 build25.sh 里装过的（curl / openssh-sftp-server）→ 不重复写
#
# 货源（两处，缺一不可）：
#   1) 官方 apk 源      —— ImmortalWrt 25.12 自带，make image 直接可装
#   2) 第三方 apk 源    —— https://github.com/wukongdaily/apk 的 run/x86/
#                          （由 build25.sh 第 21 行 clone，再经
#                           shell/apk-prepare-packages.sh 解压收集成 .apk）
#                          ⚠️ 只有 CUSTOM_PACKAGES 非空时才会去 clone 这个仓库
# ============================================================================

# ============= imm 25.12.x 仓库外的第三方插件 apk =============
# ============= 但此文件也可以处理仓库内的软件去留 本质上是做了一个PACKAGES字符串的拼接 ================

# 各位注意 如果你构建的固件是硬路由 此文件的注释要酌情考虑是否打开 因为硬路由的闪存空间有限
# 若构建出来过大或者构建失败 记得调整本文件的注释


# ============================================================================
# 一、第三方 apk（wukongdaily/apk 的 run/x86，均已确认存在）
# ============================================================================

# ---- 分区扩容 by sirpdboy ----
# 源：run/x86/partexp/{luci-app-partexp-2.0.5,luci-i18n-partexp-zh-cn} ✅
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-partexp luci-i18n-partexp-zh-cn"

# ---- Lucky大吉 by gdy666 & sirpdboy ----
# 源：run/x86/lucky/{lucky-2.27.2,luci-app-lucky-3.0.3,luci-i18n-lucky-zh-cn} ✅
# 注：24.10 只装了 luci-app-lucky lucky（无中文包），25.12 源里中文包确认存在，一并补上
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-lucky lucky luci-i18n-lucky-zh-cn"

# ---- 任务设置 by sirpdboy ----
# 源：run/x86/taskplan/{luci-app-taskplan-3.0.0,luci-i18n-taskplan-zh-cn} ✅
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-taskplan luci-i18n-taskplan-zh-cn"

# ---- Bandix 流量监控 by timsaya ----
# 源：run/x86/bandix/{bandix-0.12.8,luci-app-bandix-0.12.8,luci-i18n-bandix-zh-cn} ✅
CUSTOM_PACKAGES="$CUSTOM_PACKAGES bandix luci-app-bandix luci-i18n-bandix-zh-cn"

# ---- IPTV 流媒体转发服务器 - rtp2httpd by stackia ----
# 源：run/x86/rtp2httpd/{rtp2httpd-3.12.2,luci-app-rtp2httpd-3.12.2,luci-i18n-rtp2httpd-zh-cn-3.12.2} ✅
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-rtp2httpd luci-i18n-rtp2httpd-zh-cn"

# ---- 代理工具 clashoo by kenzok8 ----
# 源：run/x86/clashoo/{clashoo,luci-app-clashoo-1.24.6,luci-i18n-clashoo-zh-cn} ✅
# ⚠️ 注意：若集成 clashoo 则不能集成 nikki，两者配置冲突
CUSTOM_PACKAGES="$CUSTOM_PACKAGES clashoo luci-app-clashoo luci-i18n-clashoo-zh-cn"

# ---- passwall2 ----
# 源：run/x86/passwall2/{luci-app-passwall2-26.5.1,luci-i18n-passwall2-zh-cn} ✅
#      run/x86/pwcore/{geoview-0.2.6,hysteria-2.9.3} ✅
# ⚠️ 关键差异：xray-core / sing-box 在 25.12 的第三方源里**没有**，
#    但它们存在于 ImmortalWrt 官方 packages（net/xray-core、net/sing-box），
#    所以下面能装上是靠官方源。若以后官方源也拿掉，把这两个名字删掉即可。
CUSTOM_PACKAGES="$CUSTOM_PACKAGES geoview xray-core sing-box hysteria kmod-nft-socket kmod-nft-tproxy luci-app-passwall2 luci-i18n-passwall2-zh-cn"

# ---- openclash 那套通用依赖（24.10 一并装了，此处保留，但未开 openclash 本体）----
# luci-compat 已在 immortalwrt/luci 的 modules/luci-compat/Makefile 确认存在 ✅
# ⚠️ curl 已在 build25.sh 第 40 行装过，这里**不重复写**（去重）
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-compat kmod-tun kmod-inet-diag bash lua unzip"

# ---- VPN：WireGuard 协议支持 ----
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-proto-wireguard"

# ---- Tailscale ----
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-tailscale-community luci-i18n-tailscale-community-zh-cn"


# ============================================================================
# 二、imm 官方仓库（ImmortalWrt 25.12 官方源，均已确认存在）
#     统一用 luci-i18n-*-zh-cn 写法：i18n 包会自动依赖并带出对应的 luci-app-* 本体，
#     最省事也最不容易踩 "package not found"。
# ============================================================================

# usb无线网卡+随身WiFi（usbutils 在官方 packages/utils/usbutils ✅）
CUSTOM_PACKAGES="$CUSTOM_PACKAGES usb-modeswitch usbutils"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-3ginfo-lite-zh-cn"

# banip（配合容器 crowdsec 增强安全性，官方 net/banip ✅）
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-banip-zh-cn"

# 访问控制 / 证书
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-acl-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES ca-certificates luci-i18n-acme-zh-cn"

# 广告过滤 / 下载 / 内网穿透 / 杂项
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-adblock-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-aria2-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-cloudflared-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-ddns-go-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-email-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-eoip-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-hd-idle-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-keepalived-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-sqm-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-statistics-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-wol-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-timewol-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-udpxy-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-uhttpd-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-upnp-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-wechatpush-zh-cn"

# udp2raw（官方 net/udp2raw ✅）
# ⚠️ openssh-sftp-server 已在 build25.sh 第 49 行装过，这里**不重复写**（去重）
CUSTOM_PACKAGES="$CUSTOM_PACKAGES udp2raw"

# ---- OpenVPN 主程序（官方 net/openvpn ✅）----
# ⚠️ 只装主程序，不装 luci-app-openvpn-server —— 官方注释明确说它配置文件有 bug，
#    集成了会报错。24.10 那份装了它，属于历史遗留，25.12 不跟随。
# ⚠️ luci-i18n-openvpn-zh-cn 也不装：immortalwrt/luci 里没有 luci-app-openvpn，
#    对应的中文包自然也不存在，写了会 package not found。
CUSTOM_PACKAGES="$CUSTOM_PACKAGES openvpn-openssl"

# ---- dufs 静态文件服务器（官方 net/dufs ✅ + luci 仓库 applications/luci-app-dufs ✅）----
CUSTOM_PACKAGES="$CUSTOM_PACKAGES dufs luci-i18n-dufs-zh-cn"

# ---- SmartDNS（对齐 24.10：24.10 装的就是它）----
# 官方 net/smartdns ✅
# ⚠️ 不要和 MosDNS 同时启用，两边都要抢 53 端口。想换 MosDNS 就把下面这行注释掉，
#    再去「五、MosDNS」那一段打开。
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-smartdns-zh-cn"


# ============================================================================
# 三、CrowdSec + LXC 一体化（开机自动对接）—— 原 25.12 内容，原样保留，勿动
# ============================================================================
# 版本归属（重要）：
#   24.x  (opkg) → 走 shell/custom-packages.sh，由 build24.sh / build23.sh 等 source
#   25.12 (apk)  → 走本文件，由 build25.sh source
#   两个文件互不干扰，本文件里绝不能出现只在 24.x 第三方 opkg 源里才有的包
#   （典型如 cgroupfs-mount / cgroup-tools —— 已确认不在 apk 源里，会导致构建失败）。
#
# 路由器侧只装 bouncer，不要装 crowdsec 主包（主程序跑在容器里，路由器上没有 cscli）

# bouncer：拉封禁名单写进 nftables
CUSTOM_PACKAGES="$CUSTOM_PACKAGES crowdsec-firewall-bouncer"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-crowdsec-firewall-bouncer"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-crowdsec-firewall-bouncer-zh-cn"

# LXC 依赖工具（tar 用于开机解压 rootfs，必装）
CUSTOM_PACKAGES="$CUSTOM_PACKAGES xz tar liblzma gnupg getopt"
# ip-full：引导脚本用 `ip link show lxcbr0` 等网桥就绪，busybox 的 ip-tiny 功能不全
CUSTOM_PACKAGES="$CUSTOM_PACKAGES ip-full"

# ---- cgroup 相关：25.12 不建议再装，已在系统层面替代 ----
# 原来 24.10 能装上 cgroupfs-mount / cgroup-tools，靠的是加挂的 opkg 第三方源；
# 25.12 换成 apk 后那些源失效，这两个包会直接让 make image 失败。
# 实测结论：它们都可以不装，理由和替代做法如下——
#
#   cgroupfs-mount  → 作用是挂载 cgroup v1 各子系统。
#                     25.12 用的是 kernel 6.12，默认就是 cgroup v2 unified hierarchy，
#                     procd 开机已把 cgroup2 挂到 /sys/fs/cgroup，不需要这个包。
#   cgroup-tools    → 只是 cgcreate/cgexec/lssubsys 之类的**用户态管理命令**，
#                     LXC 拉起容器走的是 liblxc 直接操作 cgroupfs，压根不调用它。
#
# 替代：已在 files/etc/uci-defaults/99-custom.sh 里加了 cgroup2 挂载兜底（三行，零依赖）。
# 如果你确实想装回来（比如要手工 cgcreate 调资源限额），就取消下面注释，
# 并同时在 shell/extra-apk-repos.conf 里配好能提供这两个包的 apk 源。
# ⛔ 不要照搬 24.10 那两行，会直接构建失败
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES cgroupfs-mount cgroup-tools"

# 内核模块（veth 必须有，否则容器起不来）
# kmod-veth 已在 immortalwrt 主仓库 netsupport.mk 中确认存在：KernelPackage/veth
CUSTOM_PACKAGES="$CUSTOM_PACKAGES kmod-veth"
# kmod-ikconfig 仅供 lxc-checkconfig 诊断用，缺失不影响容器运行，25.12 源里未确认到
# ⛔ 24.10 装了它，但 25.12 源里未能确认存在，保持注释以免构建失败
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES kmod-ikconfig"
# LXC 核心
# 已核对 immortalwrt/packages 的 utils/lxc/Makefile（PKG_VERSION 7.0.0）：
#   - lxc 主包的 install 是 `true`，本身不装任何文件，真正的命令都在 lxc-* 子包里
#   - lxc-common  提供 /etc/lxc/default.conf、/etc/lxc/lxc.conf、/srv/lxc 目录
#   - lxc-configs 提供 /usr/share/lxc/config/common.conf —— 容器 config 里
#                 `lxc.include = /usr/share/lxc/config/common.conf` 依赖它，必装
#   - 下面这些 lxc-* 全部由 Makefile 的 GenPlugin 模板生成，确实存在：
#     attach autostart cgroup copy config console create destroy device execute
#     freeze info monitor snapshot start stop unfreeze unshare usernsexec wait
#     top ls monitord user-nic checkconfig
# 排错时若必须瘦身，最小集是：liblxc lxc lxc-common lxc-configs lxc-attach
#   lxc-start lxc-stop lxc-ls（我们的引导脚本只用到这几个命令）
CUSTOM_PACKAGES="$CUSTOM_PACKAGES liblxc lxc lxc-common lxc-templates"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES lxc-attach lxc-auto lxc-autostart lxc-cgroup lxc-checkconfig"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES lxc-config lxc-configs lxc-console lxc-copy lxc-create lxc-destroy"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES lxc-device lxc-execute lxc-freeze lxc-hooks lxc-info lxc-init"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES lxc-ls lxc-monitor lxc-monitord lxc-snapshot lxc-start lxc-stop"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES lxc-top lxc-unfreeze lxc-unprivileged lxc-unshare lxc-user-nic lxc-usernsexec lxc-wait"
# LuCI 网页管理（服务 → LXC 容器）
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-lxc rpcd-mod-lxc luci-i18n-lxc-zh-cn"


# ============================================================================
# 四、⛔ strongSwan / IPsec —— 实测不可用，整段停用，勿打开
# ============================================================================
# 【实测结论】25.12.1 的官方 apk 源里**根本没有发布 strongswan 系列包**。
# 已拿实际源目录核对过：
#   · https://downloads.immortalwrt.org/releases/25.12.1/packages/x86_64/packages/
#     里搜不到任何 strongswan-*.apk（25.12.0 同样没有）
#   · 真机 make image 报错如下（2026-10-06 实测）：
#       ERROR: unable to select packages:
#         strongswan-charon (no such package)
#         strongswan-mod-aes (no such package)
#         ... 共 33 个 strongswan-* 全部 no such package
#
# 【为什么之前判断错了】net/strongswan/Makefile 确实存在于 immortalwrt/packages
# 仓库的源码里，我据此认为包一定能装。但源码存在 ≠ 官方源编译发布了该包：
# 25.12 的构建系统没有把 strongswan 编进 packages feed，所以源里一个都没有。
# 这条教训也适用于其他包：**以源目录里的实际 .apk 为准，不以仓库源码为准**。
#
# 【有意思的对照】同一份报错里 luci-app-strongswan-swanctl-26.236.50544~cb5d434
# 是被成功解析到的（luci feed 里有它），缺的只是 strongswan 本体。
# 这也解释了为什么报错只列 strongswan 一项——其余 114 个包都通过了依赖解析。
#
# 【想要 IPsec 怎么办】
#   1) 加挂第三方 apk 源：把能提供方 strongswan 的源 URL 通过 EXTRA_APK_REPOS 传入，
#      并把该源签名公钥放进 shell/apk-keys/（缺公钥会 UNTRUSTED signature 拒绝安装）
#   2) 或者等官方源重新编译 strongswan 后再启用
#   启用前先用这条命令确认源里到底有没有：
#      apk update && apk list 2>/dev/null | grep -i strongswan
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-strongswan-swanctl"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES strongswan-swanctl strongswan-mod-vici strongswan-charon"
# strongswan 核心插件集（29 个 mod，源里同样没有，一并停用）
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES strongswan-mod-aes strongswan-mod-attr strongswan-mod-connmark strongswan-mod-constraints strongswan-mod-des strongswan-mod-dnskey"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES strongswan-mod-fips-prf strongswan-mod-gmp strongswan-mod-hmac strongswan-mod-openssl strongswan-mod-kernel-netlink strongswan-mod-md5"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES strongswan-mod-mgf1 strongswan-mod-pem strongswan-mod-pgp strongswan-mod-pkcs1 strongswan-mod-pubkey strongswan-mod-random"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES strongswan-mod-rc2 strongswan-mod-resolve strongswan-mod-revocation strongswan-mod-sha1 strongswan-mod-sha2 strongswan-mod-socket-default"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES strongswan-mod-sshkey strongswan-mod-updown strongswan-mod-x509 strongswan-mod-xauth-generic strongswan-mod-xcbc"
# swanmon / davici / libjson-c / glib2：没有 strongswan 就没有意义，一并停用
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES swanmon davici libjson-c glib2"
# 内核 XFRM / IPsec 转发：同上
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES kmod-ipsec kmod-ipsec4 kmod-ipsec6"
# ⛔ 下面这 7 个 24.10 装了，但 24.10 的原注释已写明「25.12 已不需要，别往 apk 那份搬」
#    照办，不搬。
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES kmod-crypto-manager kmod-crypto-aead kmod-crypto-authenc kmod-crypto-cbc kmod-crypto-des kmod-crypto-echainiv"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES kmod-crypto-hmac kmod-crypto-md5 kmod-crypto-sha1 kmod-lib-zlib-inflate kmod-lib-zlib-deflate"


# ============================================================================
# 五、MosDNS（可选，与上面 SmartDNS 二选一，别同时开）
# ============================================================================
# 25.12 源：run/x86/25-mosdns_v5.3.4-r5_x86_64.run ✅（是 .run，会被自动解压成 .apk）
# 依赖（来自 sbwml/luci-app-mosdns 的 Makefile）：
#   mosdns          → DEPENDS:  $(GO_ARCH_DEPENDS) +ca-bundle
#   luci-app-mosdns → LUCI_DEPENDS: +mosdns +uclient-fetch +v2ray-geoip +v2ray-geosite
#                                    +geo2txt +ucode
# 其中 v2ray-geoip / v2ray-geosite 由第三方源 run/x86/daed/ 目录提供 ✅
# 依赖会被自动解出，所以**只写这两个包名就够了**，不要重复写 mosdns / geo2txt 等。
# ⚠️ 启用前先把上面「二」里的 luci-i18n-smartdns-zh-cn 那行注释掉，否则 53 端口打架。
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-mosdns luci-i18n-mosdns-zh-cn"


# ============================================================================
# 六、⛔ 24.10 有、但 25.12 装不了 —— 保持注释，勿擅自打开
# ============================================================================

# ---- easytier + luci-app-easytier ----
# ⛔ 25.12 两边都没有：
#      · wukongdaily/apk 的 run/x86 里无 easytier 目录
#      · immortalwrt/packages 里也无 net/easytier
#    强行写上会 "package not found" 直接构建失败。
#    若确实需要，先往 shell/apk-keys/ 放好第三方源公钥、在 EXTRA_APK_REPOS 里加源，
#    确认源里有 easytier 后再打开。
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES easytier luci-app-easytier"

# ---- luci-app-openvpn-server / luci-i18n-openvpn-server-zh-cn ----
# ⛔ 官方注释明确说：该插件配置文件存在 bug，请勿集成，避免报错。
#    24.10 装了它，属于历史遗留，25.12 不跟随。
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-openvpn-server luci-i18n-openvpn-server-zh-cn"
# ⛔ luci-i18n-openvpn-zh-cn 也别开：immortalwrt/luci 里没有 luci-app-openvpn，
#    对应的中文包不存在，开了会 package not found
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-openvpn-zh-cn"

# ---- openclash（含 luci-compat 那套）----
# ⚠️ luci-compat 已在「一」里单独装了，这里整行只在你确实要开 openclash 时才打开
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-openclash luci-compat kmod-tun kmod-inet-diag bash curl ip-full unzip"


# ============================================================================
# 七、可选软件库（默认全部关闭，需要哪个就把注释打开）
#     以下均为 imm 25.12 官方仓库内的 luci-i18n 中文包，包名已核过。
# ============================================================================
# 首页和网络向导（注意此插件依赖 istore 商店，若集成它则连同集成了 istore 商店）
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-quickstart-zh-cn"
# Run 安装器（⚠️ 与 quickfile 的 nginx 配置冲突，请勿同时集成 quickfile）
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-run"
# 文件管理器 by sbwml
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES bash quickfile luci-app-quickfile luci-i18n-quickfile-zh-cn"
# 极光主题 by eamonxg
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-theme-aurora luci-app-aurora-config luci-i18n-aurora-config-zh-cn"
# 代理工具（⚠️ nikki 与 clashoo 配置冲突，二选一）
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-nikki-zh-cn"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-daed-zh-cn"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-homeproxy-zh-cn"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-dae-zh-cn"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES geoview xray-core sing-box hysteria luci-i18n-passwall-zh-cn"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES kmod-nft-tproxy kmod-nft-socket xray-core naiveproxy luci-app-ssr-plus luci-i18n-ssr-plus-zh-cn"
# 内网穿透 / VPN
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-zerotier-zh-cn"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-frpc-zh-cn"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-frps-zh-cn"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-ngrokc-zh-cn"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-nps-zh-cn"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-xfrpc-zh-cn"
# DDNS
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-ddns-zh-cn"
# 网盘聚合
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-openlist-zh-cn"
# 文件管理
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-filebrowser-go-zh-cn"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-filebrowser-zh-cn"
# 自定义命令
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-commands-zh-cn"
# 系统杂项
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-advanced-reboot-zh-cn"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-autoreboot-zh-cn"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-cpulimit-zh-cn"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-diskman-zh-cn"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-eqos-zh-cn"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-irqbalance-zh-cn"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-nft-qos-zh-cn"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-nlbwmon-zh-cn"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-pbr-zh-cn"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-ramfree-zh-cn"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-samba4-zh-cn"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-unbound-zh-cn"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-vnstat2-zh-cn"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-watchcat-zh-cn"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-mwan3-zh-cn"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-minidlna-zh-cn"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-qbittorrent-zh-cn"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-transmission-zh-cn"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-ksmbd-zh-cn"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-attendedsysupgrade-zh-cn"
