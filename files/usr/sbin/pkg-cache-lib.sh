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
    # 【2026-10-31.0256】logger 是 busybox 自带 applet，写死不探测。
    logger -t pkg-cache "$*" 2>/dev/null
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

# ---- 包管理器：本仓库固定 opkg（24.10）----
# 【v.180.198】不再运行时判断 apk / opkg（用户 2026-10-31 定）。
# 两个发行版早已拆成两个独立仓库：这个仓库只编 24.10，包管理器就是 opkg；
# apk 那一套完整地活在自己的 25.12 仓库里，两边各管各的。
# 留着 `if [ "$PKG_MGR" = "apk" ]` 的结果是「一半分支永远不可达」——
# 判据名义上存在，实际上谁也走不到，改起来还得多想一层。
#
# 【2026-10-31.0256】连 OPKG_BIN 变量也删了：直接写 `opkg`，命令名不再走一层间接。
# 需要假的 opkg 时放 PATH 前面即可，不必再造一个环境变量入口。

PKG_CACHE_RO="${PKG_CACHE_RO:-$ROM_DIR/root/pkg-cache}"
PKG_CACHE="${PKG_CACHE:-$ROOT_DIR/root/pkg-cache}"
# 判据必须是 Packages.gz：opkg 的 file:// 源只认 .gz，给裸 Packages 一律
# copy_file: .../Packages.gz: No such file or directory（24.10.6 真机实证）
PKG_IDX="Packages.gz"
PKG_EXT="ipk"
PKG_CACHE_CONF="${PKG_CACHE_CONF:-/etc/opkg/customfeeds.conf}"

# 源配置里「我们那一行」的行首特征
PCR_PAT='^src/gz[[:space:]]*pkgcache[[:space:]]'

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
    # 【v.180.198】原来这里还有一轮「包都在、只缺索引的目录也算可用」，那是 apk
    # 专属的补救（apk 的索引就躺在源目录里，构建时 apk index 失败就会「有包没索引」）。
    # opkg 的索引是单独的 Packages.gz，没有那种形态；判据写死成 opkg 后整段删除。
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
    # 【v.180.183】apk 侧那条反向判据（源行不该存在）只对 apk 有效，
    # 24.10 这里是「源行必须精确指向当前目录、且只有一条」，判据写死成 opkg 后
    # apk 那段整块删除。
    grep -qxF "src/gz pkgcache file://$PKG_CACHE_ACT" "$PKG_CACHE_CONF" 2>/dev/null || return 1
    _pcl_n=$(grep -cE "$PCR_PAT" "$PKG_CACHE_CONF" 2>/dev/null)
    [ "${_pcl_n:-0}" -le 1 ] || return 1
    return 0
}

# 索引是否已铺设：opkg 要的是 lists_dir 里那份 pkgcache。
# 【v.180.198】apk 那条判据（源目录里的 packages.adb 存在且非空）随分支一起删除。
pcl_lists_ok() {
    [ -f "$(pcl_lists_dir)/pkgcache" ]
}

pcl_installed() {
    opkg list-installed 2>/dev/null | grep -q "^$1 "
}
