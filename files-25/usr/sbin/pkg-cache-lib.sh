#!/bin/sh
# pkg-cache-lib.sh — 本地包库公共函数库
#
# 【不单独执行】只被 pkg-cache-fix.sh / pkg-cache-restore.sh
# 用 `. /usr/sbin/pkg-cache-lib.sh` 引入。
# 【v.180.165】pkg-cache-check.sh 已删除：探针的源检查早在 v.180.133 就内联进
# _pkgcache_probe（那份 check 看不见「死源」与「0 个包」两种坏法），旧脚本从
# 上线起没被任何代码调用，判据也从没在真机验证过 —— 留着就是两套标准。
# 这里只定义常量和函数，不做任何动作 —— 引入即产生副作用的话，
# 三个入口脚本的顺序就不可控了。
#
# 顺序约定（调用方负责）：
#   fix（resolve → feed → index） → restore（装回）
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

# 【v.180.164】只写 stdout、不进 syslog。给「这一轮什么都没动」的正常轮次用。
#
# 为什么需要这一档：guard 每 60 秒调一次 pkg-cache-fix.sh，调用处写的是
# `>/dev/null 2>&1` —— 那只挡得住 echo，挡不住 logger。于是 logread 里
# 每分钟固定 4 条（包库目录 / 源已正确跳过 / 索引已在位跳过 / 修复完成），
# 一天 5760 条，128KB 的 ring buffer 被压到只剩约 5 小时可回溯窗口，
# 探针自己的【体检】和告警全被挤到看不见（2026-10-29 真机实证）。
#
# 分档原则：真动作（挂源、铺索引、重建依赖表、各类失败）仍走 pcl_log 立即写；
# 只有「检查了一遍、什么都没需要改」这种零信息量的轮次走这里。
# stdout 保留原样 —— 手动跑、重定向到 BOOT_LOG、以及 tests/ 里的断言都靠它。
pcl_log_q() {
    echo "[PKG] $*"
    return 0
}

# ---- 包管理器：25.12 起 apk，24.10 及以前 opkg ----
# PKG_MGR_OVERRIDE 只给夹具用：生产环境为空，仍按真实二进制判断。
# 没有它的话，在一台两个包管理器都没有的机器上，四个脚本里三条分支都测不到。
PKG_MGR="${PKG_MGR_OVERRIDE:-apk}"    # 25.12 固定 apk；override 保留给夹具
OPKG_BIN="${OPKG_BIN:-opkg}"
# apk 二进制同理：生产环境就是 apk，夹具里可以指到一个假的，
# 好在没有真实 apk 的机器上验「索引重建」这条分支。
APK_BIN="${APK_BIN:-apk}"

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
    # 【v.180.141】要同时匹配两种写法：升级前固件里可能残留旧的
    # `file://<目录>`（那种写法 apk 会去 <目录>/<arch>/Packages.adb 找索引，
    # 永远找不到），升级后要能被识别并替换掉，不能留两条源。
    PCR_PAT='^(ndx[[:space:]]+)?file://.*/(apk|pkg)-cache(/packages\.adb)?/?$'
else
    PCR_PAT='^src/gz[[:space:]]*pkgcache[[:space:]]'
fi

PKG_CACHE_ACT=""

# 解析可用目录，只读基座优先。
# 为什么 /rom 优先：squashfs 删不掉（overlay 里 rm -rf 只写 whiteout，从此该路径
# 永久读不到，而 /rom 那份一个字节没少），也不占 overlay 空间、不会混进旧固件的包。
pcl_resolve() {
    # 第一轮：索引在位就直接用（正常情况，也是最快的一条路）
    for _pcl_d in "$PKG_CACHE_RO" "$PKG_CACHE"; do
        [ -n "$_pcl_d" ] || continue
        [ -f "$_pcl_d/$PKG_IDX" ] || continue
        PKG_CACHE_ACT="$_pcl_d"
        return 0
    done
    # 第二轮（仅 apk）：包都在、只缺索引的目录也算可用。
    # 为什么要有这一轮：apk 没有 lists 中转层，索引就躺在源目录里，构建时
    # `apk index` 一旦失败，镜像里就是「118 个包 + 没有 packages.adb」。
    # 如果只在有索引时才算可用，这种情况会被判成「包库不可用」，而事实是
    # 包全在、只差一份能现场重建的索引 —— 判死等于让人只能重刷固件。
    # 只挑可写的那个：/rom 是 squashfs，重建写不进去。
    if [ "$PKG_MGR" = "apk" ]; then
        for _pcl_d in "$PKG_CACHE" "$PKG_CACHE_RO"; do
            [ -n "$_pcl_d" ] || continue
            [ -d "$_pcl_d" ] || continue
            [ -n "$(ls "$_pcl_d"/*.apk 2>/dev/null)" ] || continue
            [ -w "$_pcl_d" ] || continue
            PKG_CACHE_ACT="$_pcl_d"
            return 0
        done
    fi
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
    # 【v.180.165】判据必须是**整行**（grep -x），不是子串。原来只查
    # "file://<目录>" 有没有出现过，于是这三种坏法全被判成「源已正确」：
    #   ① 整行被注释：`# ndx file:///rom/root/apk-cache/packages.adb`
    #      子串仍在 → 命中；^ndx 计数为 0 → 也过。判定通过，包管理器却读不到源。
    #   ② 源名前缀被改：`src/gz othername file:///rom/root/pkg-cache`
    #      子串命中，但 opkg 按源名去 lists/othername 找索引，而铺的是 lists/pkgcache。
    #   ③ 行尾被追加东西：同样命中。
    # 2026-10-29 在 25.12 真机实测过 ①：把源行改成注释后 pkg-cache-fix.sh
    # 明确输出「源已正确…跳过」，一个字节都没修。
    if [ "$PKG_MGR" = "apk" ]; then
        # 【v.180.183】apk 侧判据反过来：源行**不该存在**（用户 2026-10-29 定）。
        # 真机实测 apk update 每次都打
        #   WARNING: opening file:///rom/root/apk-cache/packages.adb: UNTRUSTED signature
        # 因为这份索引是 `apk mkndx --allow-untrusted` 生成的，没有可信签名，
        # apk-tools 3.x 把整条源跳过。`apk policy daed` 实测：官方源一条、
        # installed 一条，没有任何一条来自 file:///rom/root/apk-cache ——
        # 源挂着但等于不存在，唯一效果是刷警告、让 update 输出里混进「错误」。
        # 【v.180.184】补一条实测修正，免得把「源无效」当成结论：
        #   `apk --allow-untrusted policy hysteria` 能列出 file:// 的 2.9.2-r1 /
        #   2.9.3-r1 —— 这份索引不是不能用，只是**不带 --allow-untrusted 时被跳过**。
        #   所以真正的问题是「全局挂一条不可信源，每次 apk 操作都刷警告」，不是源无效。
        # 装包也不靠全局这条：pkg-cache-restore.sh 自己写一个临时 repositories 文件
        #   （一行 file://<目录>/packages.adb），用 --repositories-file 只喂本地源，
        #   并显式 --allow-untrusted。
        # 所以这里的「健康」= 配置里没有我们那一行；有就返回 1，交给 feed_ensure 清掉。
        grep -qE "$PCR_PAT" "$PKG_CACHE_CONF" 2>/dev/null && return 1
        return 0
    else
        grep -qxF "src/gz pkgcache file://$PKG_CACHE_ACT" "$PKG_CACHE_CONF" 2>/dev/null || return 1
    fi
    _pcl_n=$(grep -cE "$PCR_PAT" "$PKG_CACHE_CONF" 2>/dev/null)
    [ "${_pcl_n:-0}" -le 1 ] || return 1
    return 0
}

# 索引是否已铺设。
# apk 没有中间层：索引就是源目录里的 packages.adb，所以「铺设」等于「它存在且非空」。
# 【v.180.137】这里原来对 apk 直接 return 0，后果是 fix 第③步永远判定「已在位」、
# 永远跳过 _pcf_lists_ensure，apk 缺索引时没有任何修复动作 —— 判据恒真比没有判据更坏。
pcl_lists_ok() {
    if [ "$PKG_MGR" = "apk" ]; then
        [ -n "$PKG_CACHE_ACT" ] || return 1
        [ -s "$PKG_CACHE_ACT/packages.adb" ] || return 1
        return 0
    fi
    [ -f "$(pcl_lists_dir)/pkgcache" ]
}

pcl_installed() {
    if [ "$PKG_MGR" = "apk" ]; then
        apk info -e "$1" >/dev/null 2>&1
    else
        "$OPKG_BIN" list-installed 2>/dev/null | grep -q "^$1 "
    fi
}
