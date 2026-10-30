#!/bin/sh
# pkg-cache-restore.sh — 从本地包库装回包
#
# 用法：
#   pkg-cache-restore.sh <包名>    装回单个包
#   pkg-cache-restore.sh --all     按 manifest.txt 补齐所有缺失
#
# 【顺序】装之前一定先跑 pkg-cache-fix.sh（resolve → 挂源 → 铺索引）：
#   没有源行，opkg 不认本地库；没有索引，按包名装必然
#   "not available from any configured src"。所以本脚本在装之前自己调 fix，
#   而不是指望调用方记得 —— 顺序错了的代价是「装不上还查不出原因」。
#
# 装法按包管理器分开（两边的可用路径完全不同，别混着看）：
#   opkg（24.10）：① 绝对路径直装 —— 不走源、不读索引，快且稳
#                 ② 走本地源 —— 依赖由包管理器自己解
#   apk （25.12）：repositories 文件里写 `file://<目录>/packages.adb`，
#                 用 --repositories-file 只喂本地这一个源（等效离线）；
#                 「记账有、文件被删」走 apk fix，不是 apk add。
#                 详见 _pcr_install 里 v.180.184 的实测记录。
#
# 退出码：0 成功 / 1 失败 / 2 用法错误

set -u

# 【2026-10-31.0256】路径全部写死：固件里就在 /usr/sbin，不再做「同目录兜底」分支。
_pcr_lib=/usr/sbin/pkg-cache-lib.sh
if [ ! -f "$_pcr_lib" ]; then
    echo "找不到 $_pcr_lib" >&2
    exit 1
fi
. "$_pcr_lib"

# 【2026-10-31.0256】opkg 是 24.10 的系统包管理器，必然在位，不再 command -v 探测。

_pcr_fix=/usr/sbin/pkg-cache-fix.sh

# 装之前的最小前置：源与索引都健康才跳过 fix
_pcr_prepare() {
    if pcl_feed_ok && pcl_lists_ok; then
        return 0
    fi
    pcl_log "源或索引不健康，先跑 pkg-cache-fix.sh"
    [ -x "$_pcr_fix" ] || {
        pcl_log "找不到 pkg-cache-fix.sh，无法保证先后顺序"
        return 1
    }
    "$_pcr_fix"
}

_pcr_install() {
    _pcr_p="$1"
    [ -n "$_pcr_p" ] || return 2
    # 【v.180.148】PCR_FORCE=1 时不做「已装就跳过」判定。
    # opkg 只认 /usr/lib/opkg/info 的记账，不校验文件在不在：包记在册上、
    # 二进制却被删了，pcl_installed 照样返回真，整条恢复链在这里断掉。
    # 强制模式直接走 install --force-reinstall —— 不卸载、不联网、只覆盖文件，
    # 是「记账说有、实际没有」这种情况唯一能修的手段。
    if [ "${PCR_FORCE:-0}" != "1" ] && pcl_installed "$_pcr_p"; then
        pcl_log "已安装，跳过：$_pcr_p"
        return 0
    fi

    # 【v.180.198】这里原本是一整段 apk 装回逻辑（临时 repositories 文件 +
    # apk add / apk fix，2026-10-29 真机实测得来）。本仓库固定 opkg，整段删除。

    # 【v.180.194】2026-10-30 24.10.6 真机实测，两个坑，都会让恢复比不恢复更糟：
    #   ① 本地库没有这个包时，按包名 install --force-reinstall 不是「装不上」，
    #      而是**把已经装好的包卸掉**：pkg-restore.sh yq（yq 不在 pkg-cache）之后，
    #      /usr/lib/opkg/status 从 "install ok installed" 变成
    #      "install user not-installed"，/usr/lib/opkg/info/yq.list 被删，
    #      记账 692 → 691。本来只是「文件缺」，一修变「整包没了」。
    #   ② 多版本 ipk 不能盲取 head -n1：pkg-cache 里同时有 mosdns_5.3.3-r1 与
    #      mosdns_5.3.3-r4，head 拿到 r1（旧版），降级失败同样把包卸掉
    #      （实测 692 → 690）。
    # 所以：先按「已装版本」精确匹配，找不到退回最后一个；本地一个都没有时
    # 绝不拿已装的包去试包管理器 —— 只有「本来就未装」才按包名从源里装。
    _pcr_ver=$(opkg list-installed "$_pcr_p" 2>/dev/null | awk '{print $3}')
    _pcr_f=""
    if [ -n "$_pcr_ver" ]; then
        _pcr_f=$(ls "$PKG_CACHE_ACT/${_pcr_p}_${_pcr_ver}"_*.ipk 2>/dev/null | head -n1)
    fi
    [ -n "$_pcr_f" ] || _pcr_f=$(ls "$PKG_CACHE_ACT/${_pcr_p}"_*.ipk 2>/dev/null | tail -n1)
    if [ -n "$_pcr_f" ] && opkg install --force-reinstall "$_pcr_f" >/dev/null 2>&1; then
        pcl_log "直装成功：$_pcr_p（$(basename "$_pcr_f")）"
        return 0
    fi
    # --no-check-signature：老固件（无 Packages.sig、无公钥）不跳过就装不上；
    # 新固件签了名，带上也无害 —— 包来自本机只读 squashfs，来源可信。
    _pcr_sign=""
    opkg --help 2>&1 | grep -q 'no-check-signature' && _pcr_sign="--no-check-signature"
    if [ -n "$_pcr_f" ] && pcl_installed "$_pcr_p"; then
        opkg $_pcr_sign install --force-reinstall "$_pcr_p" >/dev/null 2>&1 \
            && { pcl_log "源装成功：$_pcr_p"; return 0; }
        pcl_log "重装失败：$_pcr_p（本地有包但没装上）"
        return 1
    fi
    if pcl_installed "$_pcr_p"; then
        pcl_log "本地库没有 $_pcr_p 的 ipk，且它已在册：不动包管理器（避免掉记账）"
        return 1
    fi
    # 未装 + 本地没有：按包名从系统源装。离线环境会失败，但不会破坏已有包。
    opkg $_pcr_sign install "$_pcr_p" >/dev/null 2>&1 \
        && { pcl_log "源装成功：$_pcr_p"; return 0; }
    pcl_log "恢复失败：$_pcr_p（本地库与系统源都没有可用包）"
    return 1
}

# 按 manifest 补齐。manifest 由构建生成，只列宿主机该有的包 ——
# 刻意不含容器内组件（crowdsec 本体在 LXC 容器里由 tarball 提供），
# 否则会天天报「crowdsec 缺失」，而它其实在容器里跑得好好的。
_pcr_restore_all() {
    _pcr_man="$PKG_CACHE_ACT/manifest.txt"
    if [ ! -f "$_pcr_man" ]; then
        pcl_log "没有 manifest.txt（$PKG_CACHE_ACT），只能单包恢复"
        return 1
    fi
    _pcr_miss=""
    _pcr_n=0
    while IFS= read -r _pcr_p; do
        case "$_pcr_p" in
        "" | \#*) continue ;;
        esac
        _pcr_p=${_pcr_p%% *}
        _pcr_n=$((_pcr_n + 1))
        pcl_installed "$_pcr_p" || _pcr_miss="$_pcr_miss $_pcr_p"
    done < "$_pcr_man"
    if [ -z "$_pcr_miss" ]; then
        pcl_log "清单 $_pcr_n 个包全部在位"
        return 0
    fi
    pcl_log "检测到缺失：$_pcr_miss"
    _pcr_prepare || return 1
    _pcr_bad=0
    for _pcr_p in $_pcr_miss; do
        _pcr_install "$_pcr_p" || {
            _pcr_bad=$((_pcr_bad + 1))
            pcl_log "补回失败：$_pcr_p"
        }
    done
    # 装完清 LuCI 索引缓存，否则软件包页看不到新装的包
    rm -f /tmp/luci-indexcache* 2>/dev/null
    [ "$_pcr_bad" -eq 0 ]
}

case "${1:-}" in
"")
    echo "用法：$0 <包名> | $0 --all" >&2
    exit 2
    ;;
--all)
    pcl_resolve || {
        pcl_log "包库目录不可用：$PKG_CACHE_RO 与 $PKG_CACHE"
        exit 1
    }
    _pcr_restore_all
    exit $?
    ;;
*)
    pcl_resolve || {
        pcl_log "包库目录不可用：$PKG_CACHE_RO 与 $PKG_CACHE"
        exit 1
    }
    _pcr_prepare || exit 1
    _pcr_install "$1"
    exit $?
    ;;
esac
