#!/bin/sh
# pkg-cache-fix.sh — 本地包库修复：挂源 + 铺索引
#
# 【顺序写死，不能颠倒】
#   ① resolve  找到真正可用的包库目录（/rom 优先）
#   ② feed     在源配置里写一条指向它的 file:// 行（且只留一条）
#   ③ index    把索引铺到 opkg 的 lists 目录
#   ④ 复检     三步都过了才返回 0
#
# 为什么是这个顺序：
#   · 没有①，②不知道该指向哪（会把源写成 /rom 一个不存在的路径，opkg update 全线失败）；
#   · 没有②，③铺好的索引没有任何源会去读（opkg 只加载配置里声明过的源）；
#   · 没有③，②挂上去也是个空源 —— 按包名装必然
#     "not available from any configured src"。
#
# 幂等：重复跑不会产生第二条源行、不会重复堆索引。探针冷却后可能反复调。
#
# 退出码：0 成功 / 1 失败

set -u

_pcf_lib=/usr/sbin/pkg-cache-lib.sh
[ -f "$_pcf_lib" ] || _pcf_lib="$(dirname "$0")/pkg-cache-lib.sh"
if [ ! -f "$_pcf_lib" ]; then
    echo "找不到 pkg-cache-lib.sh" >&2
    exit 1
fi
. "$_pcf_lib"

if [ -z "$PKG_MGR" ]; then
    pcl_log "既没有 apk 也没有 opkg，无法修复"
    exit 1
fi

# ② 挂源：按前缀删掉旧行再追加，其余源一个字不碰
_pcf_feed_ensure() {
    _pcf_dir=$(dirname "$PKG_CACHE_CONF")
    mkdir -p "$_pcf_dir" 2>/dev/null
    _pcf_tmp="$PKG_CACHE_CONF.tmp.$$"
    if [ -f "$PKG_CACHE_CONF" ]; then
        # 不能用 `grep ... || return 1`：conf 里只有我们那一行时，过滤后无输出，
        # grep 退出码就是 1，于是「挂源失败」—— 而这恰恰是最该成功的场景。
        # 判据只看临时文件有没有产出，不看 grep 有没有匹配。
        grep -vE "$PCR_PAT" "$PKG_CACHE_CONF" > "$_pcf_tmp" 2>/dev/null
        [ -f "$_pcf_tmp" ] || return 1
    else
        : > "$_pcf_tmp" || return 1
    fi
    if [ "$PKG_MGR" = "apk" ]; then
        # 必须写成 ndx <索引文件>：只写目录的话 apk 会去 <目录>/<arch>/Packages.adb
        # 找索引（apk-repositories(5) 的 repository 类型规则），而我们的索引
        # 就在包目录里、没有 arch 子目录，结果就是「源挂着、索引读不到」。
        printf 'ndx file://%s/packages.adb\n' "$PKG_CACHE_ACT" >> "$_pcf_tmp" || return 1
    else
        printf 'src/gz pkgcache file://%s\n' "$PKG_CACHE_ACT" >> "$_pcf_tmp" || return 1
    fi
    # 不能用 mv 覆盖：conf 若是单文件 bind mount 会报 Device or resource busy
    if ! cat "$_pcf_tmp" > "$PKG_CACHE_CONF" 2>/dev/null; then
        rm -f "$_pcf_tmp"
        return 1
    fi
    rm -f "$_pcf_tmp"
    return 0
}

# ③ 铺索引：绕过 opkg update（它会连所有远程源，离线时白等几十秒）
_pcf_lists_ensure() {
    if [ "$PKG_MGR" = "apk" ]; then
        _pcf_adb="$PKG_CACHE_ACT/packages.adb"
        [ -s "$_pcf_adb" ] && return 0
        # apk 的索引没有 lists 中转层，只能原地重建 —— 源目录必须可写。
        # 重建用的是包库自己那堆 apk，不联网、不依赖任何远程源。
        if [ ! -w "$PKG_CACHE_ACT" ]; then
            pcl_log "依赖查询表缺失，且源目录只读（$PKG_CACHE_ACT），只能刷带索引的固件"
            return 1
        fi
        _pcf_n=$(ls "$PKG_CACHE_ACT"/*.apk 2>/dev/null | wc -l)
        [ "$_pcf_n" -gt 0 ] || return 1
        # 【v.180.141】必须用 mkndx，不能用 index。
        # apk 有两个建索引的 applet，作用完全不同（apk-mkndx(8) / apk-index(8)）：
        #   index -> v2 的 APKINDEX.tar.gz，只吃 tar.gz 包
        #   mkndx -> apkv3 的 packages.adb，25.12 要的就是这个
        # 用 index 读 ADB 包，每个包都会报 "file format not supported
        # (in this applet)" —— 构建脚本栽在这上面，删过 114 个包。
        # 仍然两个都试：万一某个版本的 apk 只有 index，也别直接放弃。
        # --allow-untrusted 是全局选项，必须放在 applet 前面。
        for _pcf_ap in mkndx index; do
            if ( cd "$PKG_CACHE_ACT" && "$APK_BIN" --allow-untrusted "$_pcf_ap" -o packages.adb ./*.apk ) \
                    >/dev/null 2>&1 && [ -s "$_pcf_adb" ]; then
                pcl_log "已重建依赖查询表：$_pcf_adb（$_pcf_n 个包，apk $_pcf_ap）"
                return 0
            fi
        done
        pcl_log "依赖查询表重建失败（apk index 退出非 0）"
        return 1
    fi
    _pcf_lists=$(pcl_lists_dir)
    mkdir -p "$_pcf_lists" 2>/dev/null || return 1
    # 落盘名必须是源名本身（pkgcache），不是 pkgcache_Packages ——
    # opkg 按 `src/gz <名字>` 的名字去 lists_dir 找文件。
    cp -f "$PKG_CACHE_ACT/Packages" "$_pcf_lists/pkgcache" 2>/dev/null || return 1
    # 验签开着时 opkg 按 <名字>.sig 找签名，找不到会丢弃整份索引
    if [ -f "$PKG_CACHE_ACT/Packages.sig" ]; then
        cp -f "$PKG_CACHE_ACT/Packages.sig" "$_pcf_lists/pkgcache.sig" 2>/dev/null
    fi
    return 0
}

# ① resolve
if ! pcl_resolve; then
    pcl_log "包库目录不可用：$PKG_CACHE_RO 与 $PKG_CACHE 都没有 $PKG_IDX"
    exit 1
fi
pcl_log "包库目录：$PKG_CACHE_ACT"

# ② feed
if pcl_feed_ok; then
    pcl_log "源已正确（file://$PKG_CACHE_ACT），跳过"
else
    _pcf_feed_ensure || {
        pcl_log "挂源失败：$PKG_CACHE_CONF 不可写"
        exit 1
    }
    pcl_log "已挂载本地源：file://$PKG_CACHE_ACT"
fi

# ③ index
if pcl_lists_ok; then
    pcl_log "索引已在位（$(pcl_lists_dir)/pkgcache），跳过"
else
    if _pcf_lists_ensure; then
        pcl_log "索引已铺设：$(pcl_lists_dir)/pkgcache"
    else
        pcl_log "索引铺设失败（源仍可用，可改走 opkg update 补救）"
    fi
fi

# ④ 复检
if pcl_feed_ok && pcl_lists_ok; then
    pcl_log "修复完成"
    exit 0
fi
pcl_log "修复后复检未通过"
exit 1
