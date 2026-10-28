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
# 两条装法，按顺序试：
#   ① 绝对路径直装 —— 不走源、不读索引、不联网，快且稳
#   ② 走本地源 —— 依赖由包管理器自己解（直装不解依赖）
#
# 退出码：0 成功 / 1 失败 / 2 用法错误

set -u

_pcr_dir=$(dirname "$0")
_pcr_lib=/usr/sbin/pkg-cache-lib.sh
[ -f "$_pcr_lib" ] || _pcr_lib="$_pcr_dir/pkg-cache-lib.sh"
if [ ! -f "$_pcr_lib" ]; then
    echo "找不到 pkg-cache-lib.sh" >&2
    exit 1
fi
. "$_pcr_lib"

if [ -z "$PKG_MGR" ]; then
    pcl_log "既没有 apk 也没有 opkg"
    exit 1
fi

_pcr_fix=/usr/sbin/pkg-cache-fix.sh
[ -x "$_pcr_fix" ] || _pcr_fix="$_pcr_dir/pkg-cache-fix.sh"

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

    # ① 绝对路径直装
    if [ "$PKG_MGR" = "apk" ]; then
        # [0-9] 卡住版本号起点：lxc-6.0.5-r1.apk 命中，lxc-attach-*.apk 不会误命中
        _pcr_f=$(ls "$PKG_CACHE_ACT/$_pcr_p"-[0-9]*.apk 2>/dev/null | head -n1)
        if [ -n "$_pcr_f" ] && apk add --allow-untrusted --no-network "$_pcr_f" >/dev/null 2>&1; then
            pcl_log "直装成功：$_pcr_p"
            return 0
        fi
        # ② 走本地源
        if apk add --allow-untrusted --no-network \
                --repository "file://$PKG_CACHE_ACT" "$_pcr_p" >/dev/null 2>&1; then
            pcl_log "源装成功：$_pcr_p"
            return 0
        fi
        return 1
    fi

    _pcr_f=$(ls "$PKG_CACHE_ACT/${_pcr_p}"_*.ipk 2>/dev/null | head -n1)
    if [ -n "$_pcr_f" ] && "$OPKG_BIN" install --force-reinstall "$_pcr_f" >/dev/null 2>&1; then
        pcl_log "直装成功：$_pcr_p"
        return 0
    fi
    # --no-check-signature：老固件（无 Packages.sig、无公钥）不跳过就装不上；
    # 新固件签了名，带上也无害 —— 包来自本机只读 squashfs，来源可信。
    if "$OPKG_BIN" --help 2>&1 | grep -q 'no-check-signature'; then
        "$OPKG_BIN" --no-check-signature install --force-reinstall "$_pcr_p" >/dev/null 2>&1 \
            && { pcl_log "源装成功：$_pcr_p"; return 0; }
    else
        "$OPKG_BIN" install --force-reinstall "$_pcr_p" >/dev/null 2>&1 \
            && { pcl_log "源装成功：$_pcr_p"; return 0; }
    fi
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
