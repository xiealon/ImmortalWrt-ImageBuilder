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
    elif [ "$PKG_MGR" = "apk" ] && ! grep -qF "file://$PKG_CACHE_ACT/packages.adb" "$PKG_CACHE_CONF" 2>/dev/null; then
        # 只写目录的旧写法也走这里：apk 对 repository 类型会去找
        # <目录>/<arch>/Packages.adb，而我们没有 arch 子目录，等于没挂。
        echo "源未挂载（应为 ndx file://$PKG_CACHE_ACT/packages.adb）"
    elif [ "$PKG_MGR" != "apk" ] && ! grep -qF "file://$PKG_CACHE_ACT" "$PKG_CACHE_CONF" 2>/dev/null; then
        echo "源未挂载（应指向 file://$PKG_CACHE_ACT）"
    else
        echo "源重复：$PKG_CACHE_CONF 里有不止一条 pkgcache 行"
    fi
    exit 1
fi

# ---- 依赖查询表 ----
# apk 没有 lists 中转层：索引（packages.adb）直接躺在源目录里，被删就是被删，
# 没有第二份。这里必须自己查，否则探针会一直报「一切正常」，而装包时全是
# not available from any configured src。这段必须排在 pcl_lists_ok 之前，
# 否则提示会变成「缺 /var/opkg-lists/pkgcache」—— apk 根本没有这个目录。
if [ "$PKG_MGR" = "apk" ]; then
    _pcc_adb="$PKG_CACHE_ACT/packages.adb"
    if [ ! -f "$_pcc_adb" ]; then
        echo "依赖查询表缺失：$_pcc_adb（$PKG_CACHE_ACT 里有 apk 但没有索引）"
        exit 1
    fi
    _pcc_sz=$(wc -c < "$_pcc_adb" 2>/dev/null | tr -d ' ')
    [ -n "$_pcc_sz" ] || _pcc_sz=0
    # 空索引比没有更坏：apk 会把它当合法的空库，不报错、只是什么都查不到
    if [ "$_pcc_sz" -lt 64 ]; then
        echo "依赖查询表是空索引（${_pcc_sz} 字节）：$_pcc_adb"
        exit 1
    fi
    # 魔数校验：apk 索引是 ADB 二进制库，头部固定 "ADB"（apk v3 见 ADBd）；
    # 个别版本会整体 gzip。头部对不上说明这文件是被别的东西覆盖/拷错的，
    # 光看字节数是看不出来的 —— 一个 500KB 的错文件同样能骗过大小检查。
    _pcc_magic=$(od -An -tx1 -N3 "$_pcc_adb" 2>/dev/null | tr -d ' \n')
    case "$_pcc_magic" in
    414442 | 1f8b*) ;;
    *)
        echo "依赖查询表格式异常（头部=${_pcc_magic:-不可读}）：$_pcc_adb"
        exit 1
        ;;
    esac
fi

if ! pcl_lists_ok; then
    if [ "$PKG_MGR" = "apk" ]; then
        echo "索引未铺设（缺 $PKG_CACHE_ACT/packages.adb）"
    else
        echo "索引未铺设（缺 $(pcl_lists_dir)/pkgcache）"
    fi
    exit 1
fi

# 索引文件是 0 字节、或里面一条 Package 都没有，也算坏：opkg 会当成空源，
# 装什么都 not available。这里按条目数判，不按字节数 —— 字节阈值是拍出来的，
# 小库（比如只带几个包的精简镜像）会被误报成异常。
#
# 【v.180.144】按魔数分两支数条目。
# 真机实测：opkg 对 file:// 源【不重写、不解压】list，直接把 Packages.gz 原样
# 复制成 /var/opkg-lists/pkgcache —— 16881 字节、头部 1f8b，与源目录里的
# Packages.gz 字节数完全一致。opkg 自己读得懂（16.8 KB 的 gz 解析出 164 条目，
# 装包时 Downloading file:///rom/root/pkg-cache/xxx.ipk 正常），但这里用
# grep 数明文永远数出 0，于是「源能用、包能装」的同时探针报 rc=1。
# 这种假告警比没有判据更坏：喊久了真出问题时没人信。
if [ "$PKG_MGR" = "opkg" ]; then
    _pcc_l="$(pcl_lists_dir)/pkgcache"
    _pcc_n=0
    if [ -f "$_pcc_l" ]; then
        _pcc_m=$(od -An -tx1 -N2 "$_pcc_l" 2>/dev/null | tr -d ' \n')
        if [ "$_pcc_m" = "1f8b" ]; then
            _pcc_n=$(gzip -dc "$_pcc_l" 2>/dev/null | grep -c '^Package: ')
        else
            _pcc_n=$(grep -c '^Package: ' "$_pcc_l" 2>/dev/null)
        fi
        [ -n "$_pcc_n" ] || _pcc_n=0
    fi
    if [ "$_pcc_n" -lt 1 ]; then
        echo "索引里没有任何包条目（$_pcc_l，魔数=${_pcc_m:-无}）"
        exit 1
    fi
fi

echo "ok"
exit 0
