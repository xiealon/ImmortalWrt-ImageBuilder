#!/bin/sh
# pkg-restore.sh — 从本地包库把包装回来
#
# 一条判据：包管理器认不认（opkg list-installed / apk info -e）。
# 刻意不按文件清单逐条比对 —— 三个理由：
#   ① .list 的内容随包版本变化，判据会跟着版本漂，越写越复杂；
#   ② 文件缺失 ≠ 功能缺失，那不是「该不该装包」能回答的问题，是服务侧探针的事
#      （smartdns 用 pidof + 53 端口，见 verify_sd_serve）；
#   ③ 两个判据混用会死循环：端口不通 -> 判缺 -> 装包 -> 端口还是不通（配置错）
#      -> 再判缺 -> 再装，永远修不好。
#
# 上面三条管的是「该不该装」。另有一层「已装了、关键文件却被删」——
# 由 _pr_files_ok 在「已装在册」之后补一刀（v.180.161 起）：文件缺就走
# PCR_FORCE 按包内清单覆盖回来，不卸载、不联网。它只扫 /usr/bin、/usr/sbin、
# /etc/init.d、/lib/*.so* 这类可执行与库，数据文件与 /etc/config 一概不碰 ——
# 所以不会退化成「逐文件比对」。
#
# 用法：
#   pkg-restore.sh <包名>              装回（已装则跳过）
#   pkg-restore.sh --tree <包名>       连同 Depends 递归（最多 3 层）
#   pkg-restore.sh --lxc               lxc 全家桶（applet 是各自独立的包）
#   pkg-restore.sh --lxc-missing       列出「不在册」的 lxc 包（判包）
#   pkg-restore.sh --lxc-files         列出「在册但关键文件被删」的 lxc 包（判文件）
#   pkg-restore.sh --host              宿主机侧全部：lxc 全家桶 + bouncer + nftables
#   pkg-restore.sh --force <包名>      强制重装（记账说有、文件其实缺了）
#   pkg-restore.sh --installed <包名>  只判记账，0=在册 1=不在册
#
# 环境变量：
#   ROMDIR  只读基座，默认 /rom
#   PKGROOT 写入根，默认空（= /）。夹具指向临时目录
#
# 退出码：0 成功 / 1 失败 / 2 用法错误
# 例外：--lxc-files 走三态（0 齐全 / 1 有缺并列出包名 / 2 只读基底没有 lxc 清单）

set -u
ROMDIR="${ROMDIR:-/rom}"
PKGROOT="${PKGROOT:-}"

# 【2026-10-31.0256】包级安装脚本路径写死（用户 2026-10-31 定：能写死的都写死）。
# 固件里就在 /usr/sbin；「同目录兜底」那条分支在真机上从未走到过，删掉。
RESTORE_BIN="${RESTORE_BIN:-/usr/sbin/pkg-cache-restore.sh}"

log() { printf '[PKG] %s\n' "$*"; }

# 已装包名表缓存（v.180.148）。一次 lxc 恢复要判三十多个包，
# 每次跑一遍 opkg list-installed 是三十多次全表扫描；缓存后只跑一次。
# 装完清空 —— 刚装上的包必须体现在下一次判定里。
_PR_CACHE=""

_pr_installed() {
    # 24.10 只有 opkg：一次全表扫描后缓存，判三十多个包不再重复扫。
    if [ -z "$_PR_CACHE" ]; then
        _PR_CACHE=$(opkg list-installed 2>/dev/null | sed -n 's/ - .*//p')
    fi
    printf '%s\n' "$_PR_CACHE" | grep -qx "$1"
}

# 记账说已装、文件却不在的情形（手删二进制，包仍在册）。
#   判据只覆盖「可执行 / init / 共享库」这几类 —— 它们缺了包一定跑不起来；
#   /usr/share、/etc/config 一律不看：conffiles 允许用户改动，缺失不等于包坏，
#   拿它当判据会把「用户改过配置」误判成「包坏了」，每轮重装一次、刷 flash。
#   工具：opkg 的安装清单 /rom/usr/lib/opkg/info/<pkg>.list 是文本，逐行可读；
#   apk（25.12）的清单在二进制 installed.adb 里，取不到 → 直接放行，维持原行为。
#   取 /rom 侧而不是运行侧：opkg remove 会把运行侧的 .list 一起删掉，
#   而 /rom 是只读基底，固件原始清单永远在。
_pr_files_ok() {
    # 【v.180.188】双通路：24.10 的 opkg 清单 与 25.12 的 apk 清单。
    # 原来只认 /rom/usr/lib/opkg/info/<包>.list。25.12 上这个目录整个不存在，
    # 于是每个包都在下一行 return 0（判「文件齐」），强制重装那条路永远走不到 ——
    # 而 _lxc_missing_deps 判出「二进制被删」也没用，恢复动作在这句上静默失效。
    # 2026-10-29 真机复现（192.168.1.201）：
    #   rm /usr/bin/lxc-info
    #   pkg-restore.sh --lxc-missing → 输出空（包还在册，判据看不见）
    #   pkg-restore.sh --lxc         → 34 个包全「已安装，跳过」，文件没补回来
    # apk 的清单在 /rom/lib/apk/packages/<包>.list，同样一行一个绝对路径。
    _pfo_l="$ROMDIR/usr/lib/opkg/info/$1.list"
    [ -f "$_pfo_l" ] || return 0
    while IFS= read -r _pfo_f; do
        case "$_pfo_f" in
            /usr/bin/*|/usr/sbin/*|/etc/init.d/*|/lib/*.so*|/usr/lib/*.so*) ;;
            *) continue ;;
        esac
        [ -e "$PKGROOT$_pfo_f" ] || return 1
    done < "$_pfo_l"
    return 0
}

# 单包：装回。第二个参数为 1 时强制重装（跳过「已装」判定）。
_pr_pkg() {
    _p1="$1"
    _pf="${2:-0}"
    [ -n "$_p1" ] || return 2
    if [ "$_pf" != "1" ] && _pr_installed "$_p1"; then
        if _pr_files_ok "$_p1"; then
            log "已安装，跳过：$_p1"
            return 0
        fi
        # 【v.180.161】记账在、文件缺：pkg-cache-restore.sh 的「已装就跳过」会在这里
        # 把整条恢复链静默断掉（返回 0、看上去装好了、实际什么都没做）。
        # 只能走 PCR_FORCE=1：不卸载、不联网，只按包内清单覆盖文件。
        log "记账说已装但关键文件缺失，改强制重装：$_p1"
        _pf=1
    fi
    [ -x "$RESTORE_BIN" ] || {
        log "找不到包级安装脚本：$RESTORE_BIN"
        return 1
    }
    if [ "$_pf" = "1" ]; then
        # 【v.180.193】装完必须复检文件，不能只看下层退出码。25.12 实测
        # （apk-tools 3.0.5）：包不在本地库时 apk fix 打一句
        #   (1/1) [APK unavailable, skipped] Reinstalling xxx
        # 然后返回 0，一个字节都没写，上层却报了「强制重装完成」。
        # 24.10 的 opkg 走 --force-reinstall，找不到包一般返回非 0，
        # 但这个复检对两边都成立，成本只是一次清单比对。
        if PCR_FORCE=1 "$RESTORE_BIN" "$_p1" >/dev/null 2>&1 && _pr_files_ok "$_p1"; then
            log "强制重装完成：$_p1"
            _PR_CACHE=""
            return 0
        fi
        log "强制重装失败：$_p1（本地库没有它，或装完文件仍缺）"
        return 1
    fi
    if "$RESTORE_BIN" "$_p1" >/dev/null 2>&1; then
        log "包级装回：$_p1（包管理器记账已同步）"
        _PR_CACHE=""
        return 0
    fi
    log "恢复失败：$_p1（本地包库没有它，或包管理器不可用）"
    return 1
}

# 连依赖一起恢复（最多三层，防止环）。
# libc / libpthread / busybox / kernel / kmod-* 一律跳过：动它们不是恢复是砸系统。
_pr_tree() {
    _rrt_d="${2:-0}"
    [ "$_rrt_d" -le 2 ] || return 0
    _pr_pkg "$1"
    _rrt_ctl="$ROMDIR/usr/lib/opkg/info/$1.control"
    [ -f "$_rrt_ctl" ] || return 0
    for _rrt_x in $(sed -n 's/^Depends:[[:space:]]*//p' "$_rrt_ctl" 2>/dev/null | head -n1 | tr ',' ' '); do
        case "$_rrt_x" in
            libc|libpthread|libgcc*|librt|libm|kernel|kmod-*|busybox*) continue ;;
        esac
        [ -f "$ROMDIR/usr/lib/opkg/info/$_rrt_x.list" ] || continue
        _pr_tree "$_rrt_x" $((_rrt_d + 1))
    done
    return 0
}

# lxc 全家桶：/rom 里装了哪些 lxc-* 就恢复哪些（applet 是独立包，不会互相拉）
#
# 【v.180.159】枚举改成双来源，否则 apk（25.12）上一个都扫不到：
#   ① opkg 安装清单 /rom/usr/lib/opkg/info/lxc-*.list —— 24.10
#   ② apk 包库 /rom/root/apk-cache/lxc-*.apk + liblxc*.apk —— 25.12
#      apk-tools 3.x 的已安装信息是二进制 installed.adb，没有文本清单可扫，
#      所以退回「基座自带包库里有谁」。多列出来的只是候选：_pr_pkg 自带
#      --installed 判据，已经装着的直接跳过，不会重复装。
#      版本号必须从尾部按 -<数字...>-r<name> 正则剥：lxc-auto-6.0.5-r1.apk 的
#      包名自己就带连字符，按最后一段截会得到 "lxc"（见 build25.sh 的同款提醒）。
#      剥完 lxc-6.0.5-r1 → lxc，主包也一并覆盖，不再依赖 _pr_tree 兜。
#      文件名格式已实测（2026-10-29，官方 25.12.2 源 packages/x86_64/packages/）：
#        lxc-6.0.5-r1.apk            200
#        lxc-auto-6.0.5-r1.apk       200
#        liblxc-6.0.5-r1.apk         200
#        lxc-6.0.5-r1.x86_64.apk     404  ← 不带架构后缀
#      即 index.json 里的 "包名":"版本" 直接拼成 包名-版本.apk，与 build25.sh
#      来源 B 的拼法一致。
#      另外三个同属 lxc 体系、名字却不以 lxc- 开头的包由 _pr_lxc_extra 点名：
#      rpcd-mod-lxc（LuCI 的 rpcd 模块）、luci-app-lxc、luci-i18n-lxc-zh-cn。
#      两条扫描通路都捞不到它们；两版固件的白名单（build24.sh 的 _PC_WANT、
#      build25.sh 的 _AK_WANT）都列了这三个，也都打进了 /rom 包库。
# 点名包：同属 lxc 体系但名字不以 lxc- 开头，opkg 的 lxc-*.list 与 apk 的
# lxc-*.apk 两条通路都匹配不到，只能在这里写死名字。
# 取向和上面一致：包里真有才输出。更老的固件没有这三个包时不会硬装，
# 也不会因为它们缺席而把整条 lxc 恢复判成失败。
_pr_lxc_extra() {
    # 【v.180.164】lxc 元包也点名，两条线对称：
    #   · apk 通路能剥出它（lxc-6.0.5-r1.apk -> lxc），opkg 通路剥不出
    #     （lxc-*.list 通配要求连字符，而主包清单是 lxc.list）；
    #   · 它是零文件元包（opkg files lxc 输出为空、lxc.list 0 字节），
    #     装回来只补 opkg world 一条记账，不动任何文件。删掉的后果不是功能坏了，
    #     而是 LuCI 软件包页面显示「未安装」、依赖 lxc 的包重装时撞 broken dependency。
    for _lx_n in lxc rpcd-mod-lxc luci-app-lxc luci-i18n-lxc-zh-cn; do
        if [ -f "$ROMDIR/usr/lib/opkg/info/$_lx_n.list" ]; then
            printf '%s\n' "$_lx_n"
        fi
    done
}

_pr_lxc_names() {
    for _pl_l in "$ROMDIR"/usr/lib/opkg/info/lxc-*.list; do
        [ -f "$_pl_l" ] || continue
        _pl_n="${_pl_l##*/}"
        printf '%s\n' "${_pl_n%.list}"
    done
    _pr_lxc_extra
}

_pr_lxc() {
    _rl_any=0
    for _rl_p in $(_pr_lxc_names | sort -u); do
        [ -n "$_rl_p" ] || continue
        _pr_pkg "$_rl_p"
        _rl_any=1
    done
    [ "$_rl_any" = 1 ] || {
        log "只读基座里没有 lxc 的 opkg 清单（$ROMDIR/usr/lib/opkg/info/lxc-*.list）"
        return 1
    }
    _pr_tree liblxc
    return 0
}

# 输出「/rom 里带过、但当前不在册」的 lxc 全家桶包名（空格分隔，无前导空格）。
# 【v.180.164】给 bootstrap 的 pkg_base 当第二判据用，C 方案：
#   · bootstrap 的 _lxc_missing_deps 只查五个核心 applet（能不能跑）——
#     防「记账在、二进制被删」；五个都在就放过，看不见 snapshot/monitor 之类。
#   · 本条查全体在不在册（含元包 lxc、liblxc、全部 applet）—— 防「整包被删」。
# 两条并行，任一不过都要走恢复。
# 枚举刻意复用 _pr_lxc_names：与 --lxc 的恢复清单是同一份，
# 在这里再写一遍通配的话，加包时漏一处就会出现「判得出、装不回」。
_pr_lxc_missing() {
    _plm_m=""
    # liblxc 单独补一条，和 _pr_lxc() 末尾的 _pr_tree liblxc 对齐 ——
    # 恢复侧保它、判定侧也必须判它，否则「liblxc 被删」永远发现不了。
    # 原因同元包 lxc：opkg 通路的 lxc-*.list 通配要求连字符，匹配不到 liblxc.list；
    # apk 通路已被 _pr_lxc_names 里的 liblxc*.apk 覆盖。sort -u 去重，两边都安全。
    for _plm_p in $( { _pr_lxc_names; printf '%s\n' liblxc; } | sort -u ); do
        [ -n "$_plm_p" ] || continue
        _pr_installed "$_plm_p" || _plm_m="$_plm_m $_plm_p"
    done
    printf '%s\n' "$_plm_m" | sed 's/^ *//'
}

# 输出「在册、但关键文件被删」的 lxc 包名（v.180.189）。
# 与 _pr_lxc_missing 互补，各看不见一半：
#   · _pr_lxc_missing 判「包在不在册」—— 包在册、二进制被删时它输出空；
#   · 本函数判「文件在不在位」—— 拎出来的是「记账说有、文件没有」的那些。
# 2026-10-29 真机实测（25.12）：rm /usr/bin/lxc-info 之后
#   --lxc-missing → 输出空、rc=0（看不见）
#   本函数        → lxc-info（看得见）
# 恢复仍走包级 --lxc（apk fix 按包内清单覆盖），不做文件级 cp ——
# 包级带记账与依赖树，逐字节盖回会留下「文件是盖的、记账说没装」的分裂状态。
# 成本：34 个包 / 23 条关键路径 ≈ 6.2 ms（只读清单 + [ -e ]，全程不调 apk）。
_pr_lxc_files() {
    _plf_m=""
    for _plf_f in "$ROMDIR"/usr/lib/opkg/info/lxc-*.list \
                  "$ROMDIR"/usr/lib/opkg/info/liblxc.list; do
        [ -f "$_plf_f" ] || continue
        _plf_p="${_plf_f##*/}"
        _plf_p="${_plf_p%.list}"
        _pr_files_ok "$_plf_p" || _plf_m="$_plf_m $_plf_p"
    done
    printf '%s\n' "$_plf_m" | sed 's/^ *//'
}

# 宿主机侧全家桶（v.180.150）：lxc + crowdsec 的 nftables 守门人。
# bouncer 和 lxc 一样是「宿主机该有的包」，一起走本地包安装，不再单独拷文件。
# 它的配置不在这里管 —— 出厂版本身是坏的（enabled=0 / api_url 指向 localhost），
# 由 bootstrap 的 _bouncer_uci_apply 从零重建。
_pr_host() {
    _pr_lxc || return 1
    _pr_tree crowdsec-firewall-bouncer
    _pr_tree nftables-json
    return 0
}

# ---- 应用依赖的文件级恢复（v.180.181：排除 /etc/config，见下）----
# 保护「应用跑起来必需、但包管理器修不回来」的那些文件。两类对象：
#   ① 9 个 kmod 包 —— 固件出厂的已安装库里有（P:kmod-tun 命中），但
#      /rom/root/apk-cache 里 116 个 apk 一个 kmod 都没有，apk add 无处可装；
#      而且「包在册、文件被 whiteout」这种形态 apk info -e 照样返回成功。
#   ② 7 个基础件 —— ca-bundle / libcap / yq / ip-full / firewall4 /
#      coreutils-nohup / libopenssl3，同样固件自带、包库无 apk。
#      clashoo 要 ca-bundle + yq + coreutils-nohup + firewall4 + ip-full，
#      lxc 要 libcap，全在这七个里。
#
# 文件清单**不写死**，直接读只读基底里的 /rom/lib/apk/packages/<包>.list
# （实测 764 份，每个包都有一份，绝对路径一行一个）。包升级换了文件名也不用改
# 脚本，跟着基底走。也不用像上一版那样手写 26 个 .ko 与 9 个 modules.d 名字。
#
# 为什么这样能修（2026-10-29 真机实测）：
#   /rom 是 squashfs ro，文件实体删不掉。rm 只是在 /overlay/upper 写一个
#   c--------- 的 whiteout 把下层遮住，所以从 /rom 拷回即可复活：
#     rm -f /usr/bin/yq           → 上层出现 whiteout
#     /rom/usr/bin/yq             13,797,752 字节原样还在
#     cp /rom/usr/bin/yq /usr/bin/yq  → md5 与基底完全一致
#   同理 netlink_diag.ko 删掉后 --check 报缺、--repair 补回、md5 一致（实测过）。
#
# 判据只判「在不在且非空」：
#   不比内容、不比 md5 —— 包升级本来就会换文件，按内容判会把人拽回旧版；
#   用 -s 而不是 -f —— 被截断成 0 字节也算缺失。
#
# 范围刻意不含内核本体（/boot/vmlinuz 与其余 275 个模块）：内核坏了重刷固件。
#
# 【v.180.181】/etc/config/ 整目录排除（用户 2026-10-29 定）。
# 例：firewall4.list 的第一行就是 /etc/config/firewall —— 那是 UCI 配置，
# 不是程序文件，而且正是 bootstrap 的工作对象（uci set/commit + firewall
# reload，往里加 lxc zone / docker zone / SNAT / 三条 forwarding，删 wan 段）。
# 运行侧实测 2774 字节，基底 /rom 侧 2283 字节，差的全是 bootstrap 加的。
# 所以这里绝不能碰它，理由三条：
#   ① 判据是「存在且非空」，正常情况永远不触发，也永远补不了 bootstrap 写的东西；
#   ② 真触发（文件被删/被清空）时拷回来的是**出厂基底**，lxc zone 不在里面 ——
#      而 cp 完不跑 firewall reload，磁盘与运行中的 nft 表就此不一致，
#      下一次 reload 会让容器网段整个掉出去，bouncer 拉不到 LAPI（10.1.0.10:8080），
#      last_pull 停滞，探针还得靠重跑 bootstrap 才修得回来 ——
#      保护动作本身制造了它要防的故障；
#   ③ 这个文件本来就有专人管：bootstrap 的 _fw_*_ok 判据 + build 补齐每轮 ensure，
#      比「拷个出厂版本」强得多。
# 归纳成一条规则：/etc/config/ 下的一切归 bootstrap，文件级保护只管程序文件。
# 【v.180.193】双路径：25.12 是 apk（/rom/lib/apk/packages/<包>.list），
# 24.10 是 opkg（/rom/usr/lib/opkg/info/<包>.list）。两边清单格式一致
# （一行一个绝对路径），只是目录不同，所以只换目录、不换逻辑。
# 原来只认 apk 目录：24.10 上 --deps --check 恒返回 2（判不了），
# 探针每分钟打一行「只读基底里没有包文件清单」—— 这条通道在 24.10 上是空的。
# 实测（24.10.6 / r33869）：/rom/lib/apk/packages 不存在，
# /rom/usr/lib/opkg/info 有 692 份 .list，18 个保护包一份都不少。
_DEPS_ROM_LIST="$ROMDIR/usr/lib/opkg/info"

# 【v.180.182】补 v2ray-geoip / v2ray-geosite（用户 2026-10-29 定）。
# 这两个是 daed 的规则来源：daed 不直接读它们，读的是两条软链接
#   /usr/share/daed/geoip.dat   -> ../v2ray/geoip.dat
#   /usr/share/daed/geosite.dat -> ../v2ray/geosite.dat
# 所以真正会「没」的是 /usr/share/v2ray/ 下这两个实体文件（各 19MB / 10MB）。
# 为什么放在文件级而不是包级：
#   包级判据（_pa_data_ok 的软链接可读）能发现断链，但恢复动作是装 daed-geoip ——
#   包本来就已装，装包是空操作，修不好。实测过这个组合：能发现、修不了。
# 为什么不会锁版本（这是最初不肯纳入的理由）：
#   判据只判「存在且非空」，不比内容、不比 md5、不比大小。用户从 clashoo 或
#   手动换了新版 → 文件非空 → 判据恒真 → 一个字都不动。只有被删/被清空
#   （whiteout 那种）才从 /rom 拷回出厂版救急，拷完用户自己再更新即可。
# 不纳入 daed-geoip / daed-geosite 这两个包：它们的 list 里就是上面那两条软链接，
# 而 cp 会跟随软链接，把 19MB 实体写进链接、绕开包结构 —— 交给 v2ray 那两个
# 实体文件去管，软链接自然跟着好。
_DEPS_PKGS="kmod-dummy kmod-nft-socket kmod-nft-tproxy kmod-sched-bpf
kmod-sched-core kmod-veth kmod-inet-diag kmod-tun kmod-netlink-diag
ca-bundle libcap yq ip-full firewall4 coreutils-nohup libopenssl3
v2ray-geoip v2ray-geosite"

# 输出「基底有、运行侧缺或为空」的绝对路径。返回 2 = 基底里一份清单都没有。
# 用 while read 而不是 for 展开：清单里可能出现带空格的路径。
_deps_missing() {
    _dp_found=0
    for _dp_p in $_DEPS_PKGS; do
        _dp_l="$_DEPS_ROM_LIST/$_dp_p.list"
        [ -f "$_dp_l" ] || continue
        _dp_found=1
        while IFS= read -r _dp_f; do
            [ -n "$_dp_f" ] || continue
            # /etc/config/ 归 bootstrap 管（见上方 v.180.181），不在这里判也不在这里补
            case "$_dp_f" in /etc/config/*) continue ;; esac
            [ -f "$ROMDIR$_dp_f" ] || continue
            [ -s "$_dp_f" ] || printf '%s\n' "$_dp_f"
        done < "$_dp_l"
    done
    [ "$_dp_found" = 1 ] || return 2
    return 0
}

_deps_repair() {
    _dp_tmp="${TMPDIR:-/tmp}/.pkg-restore-deps.$$"
    _deps_missing > "$_dp_tmp" 2>/dev/null
    _dp_rc=$?
    if [ "$_dp_rc" = 2 ]; then
        rm -f "$_dp_tmp"
        log "基底里找不到包文件清单（$_DEPS_ROM_LIST），判不了"
        return 1
    fi
    _dp_n=0
    while IFS= read -r _dp_f; do
        [ -n "$_dp_f" ] || continue
        _dp_n=$((_dp_n + 1))
        _dp_d="${_dp_f%/*}"
        [ -d "$_dp_d" ] || mkdir -p "$_dp_d" 2>/dev/null
        if cp -f "$ROMDIR$_dp_f" "$_dp_f" 2>/dev/null; then
            log "补回 $_dp_f"
        else
            log "补回失败 $_dp_f（基底不可读或目标不可写）"
        fi
    done < "$_dp_tmp"
    rm -f "$_dp_tmp"
    [ "$_dp_n" -gt 0 ] || log "无需补回（清单内文件齐全）"
    [ -z "$(_deps_missing)" ]
}

_deps_list() {
    printf '基底清单   %s\n' "$_DEPS_ROM_LIST"
    printf '保护包数   %s\n' "$(printf '%s\n' $_DEPS_PKGS | wc -l)"
    _dp_nt=0
    _dp_nm=0
    for _dp_p in $_DEPS_PKGS; do
        _dp_l="$_DEPS_ROM_LIST/$_dp_p.list"
        [ -f "$_dp_l" ] || continue
        while IFS= read -r _dp_f; do
            [ -n "$_dp_f" ] || continue
            case "$_dp_f" in /etc/config/*) continue ;; esac
            [ -f "$ROMDIR$_dp_f" ] || continue
            _dp_nt=$((_dp_nt + 1))
            [ -s "$_dp_f" ] || _dp_nm=$((_dp_nm + 1))
        done < "$_dp_l"
    done
    printf '文件总数   %s（缺失 %s）\n' "$_dp_nt" "$_dp_nm"
    _dp_out="$(_deps_missing)"
    if [ -n "$_dp_out" ]; then
        printf '缺失清单   %s\n' "$(printf '%s' "$_dp_out" | tr '\n' ' ')"
    else
        printf '缺失清单   无\n'
    fi
    return 0
}

case "${1:-}" in
"")
    echo "用法：$0 <包名> | --tree <包名> | --lxc | --lxc-missing | --lxc-files | --host | --force <包名> | --installed <包名> | --deps --check|--repair|--list" >&2
    exit 2
    ;;
--deps)
    case "${2:-}" in
    --check)
        _dp_out="$(_deps_missing)"
        _dp_rc=$?
        [ "$_dp_rc" = 2 ] && exit 2
        [ -n "$_dp_out" ] || exit 0
        printf '%s\n' "$_dp_out"
        exit 1
        ;;
    --repair)
        _deps_repair && exit 0 || exit 1
        ;;
    --list)
        _deps_list
        exit 0
        ;;
    *)
        echo "--deps 需要 --check | --repair | --list" >&2
        exit 2
        ;;
    esac
    ;;
--installed)
    _pr_installed "${2:-}" && exit 0 || exit 1
    ;;
--lxc-missing)
    _pr_lxc_missing
    exit 0
    ;;
--lxc-files)
    # 三态，与 --deps --check 同一约定：
    #   0 = 文件齐全   1 = 有缺（输出缺文件包名）   2 = 判不了（一张清单都没有）
    _plf_n=0
    for _plf_x in "$ROMDIR"/usr/lib/opkg/info/lxc-*.list \
                  "$ROMDIR"/usr/lib/opkg/info/liblxc.list; do
        [ -f "$_plf_x" ] && _plf_n=$((_plf_n + 1))
    done
    if [ "$_plf_n" = "0" ]; then
        echo "只读基底里没有 lxc 的 opkg 清单（$ROMDIR/usr/lib/opkg/info/lxc-*.list）" >&2
        exit 2
    fi
    _plf_out="$(_pr_lxc_files)"
    if [ -n "$_plf_out" ]; then
        printf '%s\n' "$_plf_out"
        exit 1
    fi
    exit 0
    ;;
--force)
    _pr_pkg "${2:-}" 1 && exit 0 || exit 1
    ;;
--tree)
    _pr_tree "${2:-}" && exit 0 || exit 1
    ;;
--lxc)
    _pr_lxc && exit 0 || exit 1
    ;;
--host)
    _pr_host && exit 0 || exit 1
    ;;
-*)
    echo "未知选项：$1" >&2
    exit 2
    ;;
*)
    _pr_pkg "$1" && exit 0 || exit 1
    ;;
esac
