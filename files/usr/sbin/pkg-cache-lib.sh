#!/bin/sh
# pkg-cache-lib.sh — 本地包库公共函数库
#
# 【不单独执行】只被 pkg-cache-check.sh / pkg-cache-fix.sh /
# pkg-cache-restore.sh 用 `. /usr/sbin/pkg-cache-lib.sh` 引入。
# 这里只定义常量和函数，不做任何动作 —— 引入即产生副作用的话，
# 三个入口脚本的顺序就不可控了。
#
# 顺序约定（调用方负责）：
#   check（只读） → fix（resolve → feed → index） → restore（装回）
#
# 环境变量（探针/夹具用，生产环境全空）：
#   PKG_CACHE_RO / PKG_CACHE / PKG_CACHE_CONF / PKG_CACHE_LISTS
#   ROM_DIR / ROOT_DIR  夹具用根，生产为空（等效 /rom 与 /）

ROM_DIR="${ROM_DIR:-/rom}"
ROOT_DIR="${ROOT_DIR:-}"
PKG_CACHE_CONF="${PKG_CACHE_CONF:-}"
PKG_CACHE_LISTS="${PKG_CACHE_LISTS:-}"
ROM_DIR="${ROM_DIR%/}"
ROOT_DIR="${ROOT_DIR%/}"

pcl_log() {
    echo "[PKG] $*"
    command -v logger >/dev/null 2>&1 && logger -t pkg-cache "$*" 2>/dev/null
    return 0
}

# ---- 包管理器：25.12 起 apk，24.10 及以前 opkg ----
# PKG_MGR_OVERRIDE 只给夹具用：生产环境为空，仍按真实二进制判断。
# 没有它的话，在一台两个包管理器都没有的机器上，四个脚本里三条分支都测不到。
PKG_MGR="${PKG_MGR_OVERRIDE:-}"
if [ -z "$PKG_MGR" ]; then
    if command -v apk >/dev/null 2>&1; then
        PKG_MGR="apk"
    elif command -v opkg >/dev/null 2>&1; then
        PKG_MGR="opkg"
    fi
fi
OPKG_BIN="${OPKG_BIN:-opkg}"

case "$PKG_MGR" in
apk)
    PKG_CACHE_RO="${PKG_CACHE_RO:-$ROM_DIR/root/apk-cache}"
    PKG_CACHE="${PKG_CACHE:-$ROOT_DIR/root/apk-cache}"
    PKG_IDX="packages.adb"
    PKG_EXT="apk"
    PKG_CACHE_CONF="${PKG_CACHE_CONF:-/etc/apk/repositories}"
    ;;
opkg)
    PKG_CACHE_RO="${PKG_CACHE_RO:-$ROM_DIR/root/pkg-cache}"
    PKG_CACHE="${PKG_CACHE:-$ROOT_DIR/root/pkg-cache}"
    # 判据必须是 Packages.gz：opkg 的 file:// 源只认 .gz，给裸 Packages 一律
    # copy_file: .../Packages.gz: No such file or directory（24.10.6 真机实证）
    PKG_IDX="Packages.gz"
    PKG_EXT="ipk"
    PKG_CACHE_CONF="${PKG_CACHE_CONF:-/etc/opkg/customfeeds.conf}"
    ;;
esac

# 源配置里「我们那一行」的行首特征
if [ "$PKG_MGR" = "apk" ]; then
    PCR_PAT='^file://.*/(apk|pkg)-cache/?$'
else
    PCR_PAT='^src/gz[[:space:]]*pkgcache[[:space:]]'
fi

PKG_CACHE_ACT=""

# 解析可用目录，只读基座优先。
# 为什么 /rom 优先：squashfs 删不掉（overlay 里 rm -rf 只写 whiteout，从此该路径
# 永久读不到，而 /rom 那份一个字节没少），也不占 overlay 空间、不会混进旧固件的包。
pcl_resolve() {
    for _pcl_d in "$PKG_CACHE_RO" "$PKG_CACHE"; do
        [ -n "$_pcl_d" ] || continue
        [ -f "$_pcl_d/$PKG_IDX" ] || continue
        PKG_CACHE_ACT="$_pcl_d"
        return 0
    done
    PKG_CACHE_ACT=""
    return 1
}

pcl_lists_dir() {
    if [ -n "$PKG_CACHE_LISTS" ]; then
        printf '%s' "$PKG_CACHE_LISTS"
        return 0
    fi
    _pcl_ld=$(sed -n 's/^lists_dir[[:space:]]*[a-z]*[[:space:]]*\(.*\)/\1/p' \
        /etc/opkg.conf 2>/dev/null | head -n1)
    [ -n "$_pcl_ld" ] || _pcl_ld=/var/opkg-lists
    printf '%s' "$_pcl_ld"
}

# 源行是否已正确指向当前可用目录（且同名源只有一条）
pcl_feed_ok() {
    [ -n "$PKG_CACHE_ACT" ] || return 1
    [ -f "$PKG_CACHE_CONF" ] || return 1
    grep -qF "file://$PKG_CACHE_ACT" "$PKG_CACHE_CONF" 2>/dev/null || return 1
    _pcl_n=$(grep -cE "$PCR_PAT" "$PKG_CACHE_CONF" 2>/dev/null)
    [ "${_pcl_n:-0}" -le 1 ] || return 1
    return 0
}

# 索引是否已铺设（apk 没有中间层，直接读源目录里的 packages.adb）
pcl_lists_ok() {
    [ "$PKG_MGR" = "apk" ] && return 0
    [ -f "$(pcl_lists_dir)/pkgcache" ]
}

pcl_installed() {
    if [ "$PKG_MGR" = "apk" ]; then
        apk info -e "$1" >/dev/null 2>&1
    else
        "$OPKG_BIN" list-installed 2>/dev/null | grep -q "^$1 "
    fi
}
