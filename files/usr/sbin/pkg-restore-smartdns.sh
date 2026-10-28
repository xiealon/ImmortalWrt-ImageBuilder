#!/bin/sh
# pkg-restore-smartdns.sh — smartdns 专用恢复
#
# 为什么单独一份：通用恢复只管「包在不在」，smartdns 还多两块状态，通用路径修不了。
#
#   ① /etc/smartdns/ 下的规则文件
#      address.conf / blacklist-ip.conf / custom.conf / domain-block.list /
#      domain-forwarding.list —— 它们在 conffiles 里，通用恢复按「不覆盖用户配置」
#      一律跳过。可文件真没了的时候，那条保护就退化成「永远不修」：
#      真机 2026-10-28 就是这么挂的 —— smartdns: open config file
#      '/etc/smartdns/address.conf' failed -> procd 记 crash loop -> 53 端口全空 ->
#      探针判进程不在 -> 重跑 bootstrap -> 再挂，死循环。
#      这里单独开口子，判据是「不存在才补」：存在就一律不动，哪怕被清成 0 字节。
#
#   ② LuCI 界面 luci-app-smartdns（menu.d + smartdns-call）
#      纯前端包，无二进制、无 init。只调单包恢复、不递归 —— 它的 Depends 里有
#      luci-base，递归会一路碰 rpcd / ubus / ucode 一大片基础系统，那是砸系统。
#
# 用法：
#   pkg-restore-smartdns.sh          全量：本体 + 依赖 + /etc/smartdns + 界面
#   pkg-restore-smartdns.sh --check  只判在位（0 在位 / 1 缺失）
#   pkg-restore-smartdns.sh --pkg    只装本体（含依赖树）
#   pkg-restore-smartdns.sh --conf   只补 /etc/smartdns/ 规则文件
#   pkg-restore-smartdns.sh --luci   只补界面
#
# 环境变量：ROMDIR（默认 /rom）、PKGROOT（默认空）、RESTORE_BIN（默认 pkg-restore.sh）
#
# 退出码：0 成功或本来就不缺 / 1 失败 / 2 用法错误

set -u
ROMDIR="${ROMDIR:-/rom}"
PKGROOT="${PKGROOT:-}"
RESTORE_BIN="${RESTORE_BIN:-/usr/sbin/pkg-restore.sh}"

log() { printf '[PKG] %s\n' "$*"; }

# /etc/smartdns/ 下必须存在的规则文件（与构建期固化进固件的那批一致）
SD_CONF_FILES="address.conf blacklist-ip.conf custom.conf domain-block.list domain-forwarding.list"

# 在位判据：二进制 + init 缺一不可；再加一次冒烟，因为 opkg remove libopenssl3
# 之后两个 -x 判断依然为真，只有真跑才看得见动态库缺口。
# 取向：只有明确的加载错误才判「不在位」，其余异常一律放过 —— 误判成缺会把整轮引导带走。
_sd_check() {
    [ -x "$PKGROOT/usr/sbin/smartdns" ] && [ -x "$PKGROOT/etc/init.d/smartdns" ] || return 1
    case "$("$PKGROOT/usr/sbin/smartdns" -v 2>&1)" in
        *"Error loading"*|*"No such file"*|*"not found"*|*"cannot open shared object"*)
            return 1 ;;
    esac
    return 0
}

# 本体：走通用恢复的依赖树，两个依赖都是普通包，递归即可
_sd_pkg() {
    [ -x "$RESTORE_BIN" ] || { log "找不到 $RESTORE_BIN"; return 1; }
    "$RESTORE_BIN" --tree smartdns
}

# 规则文件：不存在才补，存在一律不动
_sd_conf() {
    _n=0
    for _f in $SD_CONF_FILES; do
        [ -e "$PKGROOT/etc/smartdns/$_f" ] && continue
        [ -e "$ROMDIR/etc/smartdns/$_f" ] || continue
        mkdir -p "$PKGROOT/etc/smartdns" 2>/dev/null
        cp -a "$ROMDIR/etc/smartdns/$_f" "$PKGROOT/etc/smartdns/$_f" 2>/dev/null \
            && _n=$((_n + 1))
    done
    [ "$_n" -gt 0 ] && log "从只读基座恢复 smartdns 规则文件：$_n 个（/etc/smartdns/）"
    return 0
}

# 界面是否可用。固件压根没编界面（只读基座里没安装清单）算「本来就没有」，
# 返回 0 不报警 —— 老固件就是这个情形，每轮白恢复一次没有意义。
_sd_luci_ok() {
    if [ -f "$PKGROOT/usr/share/luci/menu.d/luci-app-smartdns.json" ] \
       && [ -f "$PKGROOT/usr/libexec/smartdns-call" ]; then
        return 0
    fi
    [ -f "$ROMDIR/usr/lib/opkg/info/luci-app-smartdns.list" ] || return 0
    return 1
}

_sd_luci() {
    _sd_luci_ok && return 0
    [ -x "$RESTORE_BIN" ] || return 1
    "$RESTORE_BIN" luci-app-smartdns || return 1
    return 0
}

case "${1:-}" in
"")
    _rc=0
    _sd_pkg || _rc=1
    _sd_conf
    if _sd_luci_ok; then
        :
    else
        log "界面 luci-app-smartdns 缺失 —— 单独补，不影响本体"
        _sd_luci || log "界面未恢复（只读基座里没有它的安装清单，只影响网页配置）"
    fi
    exit $_rc
    ;;
--check)
    _sd_check && exit 0 || exit 1
    ;;
--pkg)
    _sd_pkg && exit 0 || exit 1
    ;;
--conf)
    _sd_conf && exit 0 || exit 1
    ;;
--luci)
    _sd_luci && exit 0 || exit 1
    ;;
*)
    echo "用法：$0 [--check|--pkg|--conf|--luci]" >&2
    exit 2
    ;;
esac
