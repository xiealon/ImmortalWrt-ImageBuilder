#!/bin/sh
# pkg-cache-check.sh — 本地包库只读体检（探针调这个）
#
# 【严格只读】不写任何文件、不装任何包。探针每轮都会调，必须便宜且无副作用：
# 只做两三个 test -f 和一次 grep。
#
# 退出码：0 健康 / 1 需修复 / 2 包管理器缺失
# stdout：健康时打印 ok；不健康时打印一句原因（探针直接写进日志）
#
# 顺序：本脚本只判断，不修。修交给 pkg-cache-fix.sh。
# 把判断和修改分成两个脚本，是为了让探针的「连续 N 轮坏才动手」有意义 ——
# 如果检查自己就顺手修了，那 N 轮判定、冷却、失败计数全都失效。

_pcc_lib=/usr/sbin/pkg-cache-lib.sh
[ -f "$_pcc_lib" ] || _pcc_lib="$(dirname "$0")/pkg-cache-lib.sh"
if [ ! -f "$_pcc_lib" ]; then
    echo "找不到 pkg-cache-lib.sh"
    exit 2
fi
. "$_pcc_lib"

case "$PKG_MGR" in
"" )
    echo "既没有 apk 也没有 opkg"
    exit 2
    ;;
esac

if ! pcl_resolve; then
    echo "包库目录不可用：$PKG_CACHE_RO 与 $PKG_CACHE 都没有 $PKG_IDX"
    exit 1
fi

if ! pcl_feed_ok; then
    if [ ! -f "$PKG_CACHE_CONF" ]; then
        echo "源配置不存在：$PKG_CACHE_CONF"
    elif ! grep -qF "file://$PKG_CACHE_ACT" "$PKG_CACHE_CONF" 2>/dev/null; then
        echo "源未挂载（应指向 file://$PKG_CACHE_ACT）"
    else
        echo "源重复：$PKG_CACHE_CONF 里有不止一条 pkgcache 行"
    fi
    exit 1
fi

if ! pcl_lists_ok; then
    echo "索引未铺设（缺 $(pcl_lists_dir)/pkgcache）"
    exit 1
fi

# 索引文件是 0 字节也算坏：opkg 会当成空源，装什么都 not available
if [ "$PKG_MGR" = "opkg" ]; then
    _pcc_sz=$(wc -c < "$(pcl_lists_dir)/pkgcache" 2>/dev/null | tr -d ' ')
    if [ -z "$_pcc_sz" ] || [ "$_pcc_sz" -lt 1024 ]; then
        echo "索引文件异常（${_pcc_sz:-0} 字节）"
        exit 1
    fi
fi

echo "ok"
exit 0
