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

# 单包：装回。第二个参数为 1 时强制重装（跳过「已装」判定）。
_pr_pkg() {
    _p1="$1"
    _pf="${2:-0}"
    [ -n "$_p1" ] || return 2
    if [ "$_pf" != "1" ] && _pr_installed "$_p1"; then
        log "已安装，跳过：$_p1"
        return 0
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
    echo "用法：$0 <包名> | --tree <包名> | --lxc | --host | --force <包名> | --installed <包名>" >&2
    exit 2
    ;;
--installed)
    _pr_installed "${2:-}" && exit 0 || exit 1
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
