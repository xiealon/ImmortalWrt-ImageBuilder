#!/bin/sh
# pkg-restore.sh — 从只读基座 / 本地包库恢复一个包（含依赖树、lxc 全家桶）
#
# 恢复两条路，顺序固定，不能反：
#   ① 包级：交给 pkg-cache-restore.sh 装回
#      好处是 opkg/apk 的记账同步了 —— opkg list-installed 查得到、
#      LuCI 软件包页看得见、别的包按 Depends 能找得到它。
#   ② 文件级：从 $ROMDIR/usr/lib/opkg/info/<包>.list 逐条拷回
#      只在包级装不上时走。它修不了记账，但对「包没被动过、只是文件被删」
#      这种情况零依赖、零联网，连 opkg 坏了都能救。
#      两条硬规矩：/etc/config/* 一律跳过；conffiles 里列的路径也跳过
#      —— 恢复出厂配置等于删用户的配置。
#
# 用法：
#   pkg-restore.sh <包名>            单包
#   pkg-restore.sh --tree <包名>     连同 Depends 递归（最多 3 层，防环）
#   pkg-restore.sh --lxc             lxc 全家桶（applet 是各自独立的包）
#   pkg-restore.sh --files <包名>    只走文件级（不碰包管理器）
#   pkg-restore.sh --installed <包名>  只判在位，0=在 1=不在
#
# 环境变量：
#   ROMDIR   只读基座，默认 /rom
#   PKGROOT  写入根，默认空（= /）。夹具指向临时目录，避免动真机
#   RESTORE_BIN  包级安装脚本，默认 /usr/sbin/pkg-cache-restore.sh
#
# 退出码：0 已恢复或本来就在 / 1 失败 / 2 用法错误

set -u
ROMDIR="${ROMDIR:-/rom}"
PKGROOT="${PKGROOT:-}"

# 包级安装脚本的查找顺序（v.180.147）：
#   ① 显式 RESTORE_BIN
#   ② /usr/sbin/pkg-cache-restore.sh —— 固件里的正式位置
#   ③ 与本脚本同目录 —— 脚本被拷到 /tmp 单独验时的情况，
#      不这么找的话「从 /tmp 跑」就永远只能走文件级兜底，测不到包级那条路。
RESTORE_BIN="${RESTORE_BIN:-}"
if [ -z "$RESTORE_BIN" ]; then
    if [ -x /usr/sbin/pkg-cache-restore.sh ]; then
        RESTORE_BIN=/usr/sbin/pkg-cache-restore.sh
    else
        RESTORE_BIN="$(dirname "$0")/pkg-cache-restore.sh"
    fi
fi

log() { printf '[PKG] %s\n' "$*"; }

# 包管理器认不认这个包（不是「文件在不在」——文件级恢复修不了记账）
_pr_installed() {
    if command -v opkg >/dev/null 2>&1; then
        opkg list-installed 2>/dev/null | grep -q "^$1 "
        return $?
    fi
    if command -v apk >/dev/null 2>&1; then
        apk info -e "$1" >/dev/null 2>&1
        return $?
    fi
    return 1
}

# 文件级恢复：只补「运行时不存在、只读基座存在」的文件
_pr_files() {
    _rrp_base="$ROMDIR/usr/lib/opkg/info"
    [ -f "$_rrp_base/$1.list" ] || return 1
    _rrp_n=0
    while IFS= read -r _rrp_f; do
        case "$_rrp_f" in
            /etc/config/*) continue ;;
            /?*) ;;
            *) continue ;;
        esac
        # conffiles 不动：那是用户的配置，恢复出厂值等于删他的东西
        if [ -f "$_rrp_base/$1.conffiles" ] \
           && grep -qxF "$_rrp_f" "$_rrp_base/$1.conffiles" 2>/dev/null; then
            continue
        fi
        [ -e "$PKGROOT$_rrp_f" ] && continue
        [ -e "$ROMDIR$_rrp_f" ] || continue
        mkdir -p "$PKGROOT${_rrp_f%/*}" 2>/dev/null
        cp -a "$ROMDIR$_rrp_f" "$PKGROOT$_rrp_f" 2>/dev/null && _rrp_n=$((_rrp_n + 1))
    done < "$_rrp_base/$1.list"
    [ "$_rrp_n" -gt 0 ] && log "文件级恢复 $1：$_rrp_n 个文件"
    return 0
}

# 单包：包级优先 → 文件级兜底
_pr_pkg() {
    _p1="$1"
    [ -n "$_p1" ] || return 2
    if _pr_installed "$_p1"; then
        log "已安装，跳过：$_p1"
        return 0
    fi
    if [ -x "$RESTORE_BIN" ] && "$RESTORE_BIN" "$_p1" >/dev/null 2>&1; then
        log "包级装回：$_p1（包管理器记账已同步）"
        return 0
    fi
    if _pr_files "$_p1"; then
        return 0
    fi
    log "恢复失败：$_p1（包级装不上，只读基座也没有它的安装清单）"
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
_pr_lxc() {
    _rl_any=0
    for _rl_l in "$ROMDIR"/usr/lib/opkg/info/lxc-*.list; do
        [ -f "$_rl_l" ] || continue
        _rl_p="${_rl_l##*/}"
        _pr_pkg "${_rl_p%.list}"
        _rl_any=1
    done
    [ "$_rl_any" = 1 ] || {
        log "只读基座里没有 lxc-*.list（$ROMDIR/usr/lib/opkg/info/）"
        return 1
    }
    _pr_tree liblxc
    return 0
}

case "${1:-}" in
"")
    echo "用法：$0 <包名> | --tree <包名> | --lxc | --files <包名> | --installed <包名>" >&2
    exit 2
    ;;
--installed)
    _pr_installed "${2:-}" && exit 0 || exit 1
    ;;
--files)
    _pr_files "${2:-}" && exit 0 || exit 1
    ;;
--tree)
    _pr_tree "${2:-}" && exit 0 || exit 1
    ;;
--lxc)
    _pr_lxc && exit 0 || exit 1
    ;;
-*)
    echo "未知选项：$1" >&2
    exit 2
    ;;
*)
    _pr_pkg "$1" && exit 0 || exit 1
    ;;
esac
