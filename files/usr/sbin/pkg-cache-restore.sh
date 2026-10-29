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

    # 【v.180.184】apk 分支按 25.12 真机实测重写（apk-tools 3.0.5，2026-10-29）。
    # 旧写法两条路都是死的，日志却像「都试过了」：
    #   ① `apk add <绝对路径.apk>`：包能读、依赖能算出来，但依赖必须「从源里取」，
    #      --no-network 一句 "masked in: --no-network" 把包括 file:// 在内的所有源
    #      一起屏蔽 → 必然失败（实测 rc=17，bandix 一次列出 7 个被 mask 的依赖）。
    #   ② `--repository file://<目录>`：apk 按 v2 布局只找 <目录>/<arch>/APKINDEX.tar.gz，
    #      我们的索引是 <目录>/packages.adb → 报 "APKINDEX.tar.gz: No such file"。
    # 正解是 repositories 文件语法：一行 `file://<目录>/packages.adb`（写索引文件
    # 本身，不带 ndx 前缀、也不写目录），再用 --repositories-file 指到只含这一行的
    # 临时文件 —— 唯一源是本地，等效离线，于是不需要 --no-network，也就不会被 mask。
    #
    # 另一条必须分开：apk add 对已装包是 no-op。「记账有、文件被删」用 add 永远修不
    # 回来（实测 rc=0、什么都没做），只有 apk fix 会按校验和重装（实测删掉
    # /usr/bin/dns2socks 后 fix 打出 "Reinstalling dns2socks (2.1-r2)" 并真的补回）。
    # 退出码实测：fix 包不在库=1；fix 有包但未装=0 且静默跳过；add 依赖不全=4；
    # 成功=0。所以 fix 只在「确实已装」时用，不会出现假成功。
    if [ "$PKG_MGR" = "apk" ]; then
        _pcr_repos="${TMPDIR:-/tmp}/pkg-cache-restore.repos"
        printf 'file://%s/%s\n' "$PKG_CACHE_ACT" "$PKG_IDX" > "$_pcr_repos" 2>/dev/null || {
            pcl_log "写不出临时源文件：$_pcr_repos"
            return 1
        }
        _pcr_use_fix=0
        if [ "${PCR_FORCE:-0}" = "1" ] && pcl_installed "$_pcr_p"; then
            _pcr_use_fix=1
        fi
        if [ "$_pcr_use_fix" = "1" ]; then
            if apk fix --allow-untrusted --repositories-file "$_pcr_repos" "$_pcr_p" >/dev/null 2>&1; then
                pcl_log "强制重装成功：$_pcr_p（按校验和复检文件）"
                rm -f "$_pcr_repos"
                return 0
            fi
            pcl_log "强制重装失败：$_pcr_p（本地库没有它，或索引读不了）"
            rm -f "$_pcr_repos"
            return 1
        fi
        if apk add --allow-untrusted --repositories-file "$_pcr_repos" "$_pcr_p" >/dev/null 2>&1; then
            pcl_log "本地源装回：$_pcr_p"
            rm -f "$_pcr_repos"
            return 0
        fi
        # 本地库只收应用包（实测 114 个），系统依赖（conntrack / iw / zoneinfo-all
        # 这类）不在里面，只能走系统已配置的全部源补 —— 这一句会联网，日志写清楚，
        # 免得事后把「恢复时连过网」当成异常。
        pcl_log "本地库解不了 $_pcr_p 的依赖，改走系统源（会联网）"
        if apk add --allow-untrusted "$_pcr_p" >/dev/null 2>&1; then
            pcl_log "系统源装回：$_pcr_p"
            rm -f "$_pcr_repos"
            return 0
        fi
        rm -f "$_pcr_repos"
        pcl_log "恢复失败：$_pcr_p（本地库与系统源都没有它）"
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
