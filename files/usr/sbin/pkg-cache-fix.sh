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

# 【v.180.199】路径写死：固件里就在 /usr/sbin，不再做「同目录兜底」分支。
_pcf_lib=/usr/sbin/pkg-cache-lib.sh
if [ ! -f "$_pcf_lib" ]; then
    echo "找不到 $_pcf_lib" >&2
    exit 1
fi
. "$_pcf_lib"

# 【v.180.164】正常轮次的心跳节流。背景见 pkg-cache-lib.sh 的 pcl_log_q 注释：
# guard 每 60 秒调一次本脚本，若全程写 syslog 就是每分钟 4 条、一天 5760 条。
# 改法：零信息量的「跳过了」走 pcl_log_q（只 stdout），syslog 只留
# 一条每 _PCF_BEAT 秒的心跳 —— 没有心跳就完全看不出这条链路还在工作。
# 真动作（挂源 / 铺索引 / 重建依赖表 / 任何失败）不受节流，立即写。
_PCF_HB="${PKG_CACHE_HB:-/tmp/.pkgcache-fix.hb}"
_PCF_BEAT="${PKG_CACHE_BEAT:-1800}"
# 非数字会让下面的算术展开直接报错（set -u 配 dash/ash 无兜底），回落默认值。
case "$_PCF_BEAT" in '' | *[!0-9]*) _PCF_BEAT=1800 ;; esac

# 距上次心跳够久就记一笔并返回 0（该写 syslog）；否则返回 1（只走 stdout）。
_pcf_beat() {
    _pcf_now=$(date +%s 2>/dev/null)
    case "$_pcf_now" in '' | *[!0-9]*) _pcf_now=0 ;; esac
    [ "$_pcf_now" -gt 0 ] || return 1
    _pcf_last=$(cat "$_PCF_HB" 2>/dev/null)
    case "$_pcf_last" in '' | *[!0-9]*) _pcf_last=0 ;; esac
    if [ $((_pcf_now - _pcf_last)) -ge "$_PCF_BEAT" ]; then
        printf '%s\n' "$_pcf_now" > "$_PCF_HB" 2>/dev/null
        return 0
    fi
    return 1
}

# 【v.180.199】opkg 是 24.10 的系统包管理器，必然在位，不再 command -v 探测。

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
    # 【v.180.198】原来这里还分 apk（只删不写，避免刷 UNTRUSTED 警告）和 opkg
    # （追加 src/gz 一行）两路。本仓库固定 opkg，apk 那路删除。
    printf 'src/gz pkgcache file://%s\n' "$PKG_CACHE_ACT" >> "$_pcf_tmp" || return 1
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
    # 【v.180.198】原来这里还有一整段 apk 索引重建（mkndx/index → packages.adb）。
    # 本仓库固定 opkg，apk 那段删除，只留下面这条。
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
pcl_log_q "包库目录：$PKG_CACHE_ACT"

# ② feed
if pcl_feed_ok; then
    pcl_log_q "源已正确（file://$PKG_CACHE_ACT），跳过"
else
    _pcf_feed_ensure || {
        pcl_log "源配置整理失败：$PKG_CACHE_CONF 不可写"
        exit 1
    }
    pcl_log "已挂载本地源：file://$PKG_CACHE_ACT"
fi

# ③ index
if pcl_lists_ok; then
    pcl_log_q "索引已在位（$(pcl_lists_dir)/pkgcache），跳过"
else
    if _pcf_lists_ensure; then
        pcl_log "索引已铺设：$(pcl_lists_dir)/pkgcache"
    else
        pcl_log "索引铺设失败（源仍可用，可改走 opkg update 补救）"
    fi
fi

# ④ 复检
if pcl_feed_ok && pcl_lists_ok; then
    if _pcf_beat; then
        pcl_log "修复完成"
    else
        pcl_log_q "修复完成"
    fi
    exit 0
fi
pcl_log "修复后复检未通过"
exit 1
