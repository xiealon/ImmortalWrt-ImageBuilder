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
# 用法：
#   pkg-restore.sh <包名>              装回（已装则跳过）
#   pkg-restore.sh --tree <包名>       连同 Depends 递归（最多 3 层）
#   pkg-restore.sh --lxc               lxc 全家桶（applet 是各自独立的包）
#   pkg-restore.sh --host              宿主机侧全部：lxc 全家桶 + bouncer + nftables
#   pkg-restore.sh --force <包名>      强制重装（记账说有、文件其实缺了）
#   pkg-restore.sh --installed <包名>  只判记账，0=在册 1=不在册
#
# 环境变量：
#   ROMDIR  只读基座，默认 /rom
#   PKGROOT 写入根，默认空（= /）。夹具指向临时目录
#
# 退出码：0 成功 / 1 失败 / 2 用法错误

set -u
ROMDIR="${ROMDIR:-/rom}"
PKGROOT="${PKGROOT:-}"

# 包级安装脚本的查找顺序（v.180.147）：
#   ① 显式 RESTORE_BIN
#   ② /usr/sbin/pkg-cache-restore.sh —— 固件里的正式位置
#   ③ 与本脚本同目录 —— 脚本被拷到 /tmp 单独验时的情况
RESTORE_BIN="${RESTORE_BIN:-}"
if [ -z "$RESTORE_BIN" ]; then
    if [ -x /usr/sbin/pkg-cache-restore.sh ]; then
        RESTORE_BIN=/usr/sbin/pkg-cache-restore.sh
    else
        RESTORE_BIN="$(dirname "$0")/pkg-cache-restore.sh"
    fi
fi

log() { printf '[PKG] %s\n' "$*"; }

# 已装包名表缓存（v.180.148）。一次 lxc 恢复要判三十多个包，
# 每次跑一遍 opkg list-installed 是三十多次全表扫描；缓存后只跑一次。
# 装完清空 —— 刚装上的包必须体现在下一次判定里。
_PR_CACHE=""

_pr_installed() {
    if command -v opkg >/dev/null 2>&1; then
        if [ -z "$_PR_CACHE" ]; then
            _PR_CACHE=$(opkg list-installed 2>/dev/null | sed -n 's/ - .*//p')
        fi
        printf '%s\n' "$_PR_CACHE" | grep -qx "$1"
        return $?
    fi
    if command -v apk >/dev/null 2>&1; then
        apk info -e "$1" >/dev/null 2>&1
        return $?
    fi
    return 1
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
        PCR_FORCE=1 "$RESTORE_BIN" "$_p1" >/dev/null 2>&1 \
            && { log "强制重装完成：$_p1"; _PR_CACHE=""; return 0; }
        log "强制重装失败：$_p1"
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
            continue
        fi
        for _lx_f in "$ROMDIR"/root/apk-cache/"$_lx_n"-*.apk; do
            [ -f "$_lx_f" ] || continue
            printf '%s\n' "$_lx_n"
            break
        done
    done
}

_pr_lxc_names() {
    for _pl_l in "$ROMDIR"/usr/lib/opkg/info/lxc-*.list; do
        [ -f "$_pl_l" ] || continue
        _pl_n="${_pl_l##*/}"
        printf '%s\n' "${_pl_n%.list}"
    done
    for _pl_a in "$ROMDIR"/root/apk-cache/lxc-*.apk "$ROMDIR"/root/apk-cache/liblxc*.apk; do
        [ -f "$_pl_a" ] || continue
        _pl_n="${_pl_a##*/}"
        _pl_n="${_pl_n%.apk}"
        printf '%s\n' "$_pl_n" | sed -n 's/-[0-9][0-9.]*-r[0-9][0-9]*$//p'
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
        log "只读基座里既没有 lxc-*.list 也没有 apk-cache 里的 lxc 包（$ROMDIR）"
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

case "${1:-}" in
"")
    echo "用法：$0 <包名> | --tree <包名> | --lxc | --lxc-missing | --host | --force <包名> | --installed <包名>" >&2
    exit 2
    ;;
--installed)
    _pr_installed "${2:-}" && exit 0 || exit 1
    ;;
--lxc-missing)
    _pr_lxc_missing
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
