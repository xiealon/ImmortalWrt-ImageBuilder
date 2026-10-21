#!/bin/sh
# crowdsec-guard：核心脚本防篡改，以 /rom（squashfs 只读分区）为不可变基准
#
# 为什么不用 chattr +i：/usr/sbin 下的文件在 overlayfs 的合并视图里。还没被写过时，
#   chattr 的 ioctl 会打到下层 squashfs → Operation not supported（这就是实测报的那个错）；
#   先 copy-up 再设也能成功，但 flag 只落在 upper 的 ext4 上，刷机重建 overlay 就丢，
#   而且挡不住直接删 /overlay/upper/... 把上层实体整个拿掉。
#   squashfs 挂载点 /rom 反倒是内核级只读（mount -o remount,rw 直接失败，驱动不支持写），
#   原件既改不掉也删不掉 —— 拿它当基准比任何文件 flag 都硬。
#
# 本脚本只做一件事：运行副本与只读基准不一致（内容变了 / 被删了 / 丢了执行位）就复原。
# 三个调用点互为看门狗，任意一个还活着就能把另外几个补回来：
#   rc.local（开机）· crowdsec-lxc-probe（每轮）· init.d/crowdsec-lxc-probe（起服务）
# 非 squashfs 平台（ext4 单分区镜像）没有 /rom，整体跳过，不做任何假设。
#
# 用法：crowdsec-guard.sh [quiet]     quiet = 不往 stderr 输出（探针每轮调用用）
#
# 保护范围只含「必须原样运行的核心脚本」。action 注入的 /etc/config/*.txt、运行期 uci
# 配置、容器 rootfs 一律不进来 —— bootstrap 的 _drop_enroll_key 绑定成功后会删 enroll
# key，纳进来只会被本脚本反复"复原"回去，把安全清理变成死循环。
#
# /etc/init.d/lxc-auto 纳进来（v.108.6）：容器常驻走它的 boot()——先挂 systemd
# cgroup 再 lxc-start。这个脚本被改坏时（例如把 /proc/mounts 判据改回「目录存在」）
# 不会有任何报错，只会让容器静默起不来，正是最该被只读基准兜住的那类文件。
#
# /etc/config/lxc-auto **不进**清单（v.108.8 撤回 v.108.7 的做法）：
#   v.108.7 假定「容器名由镜像 files/etc/config/lxc-auto 固定、bootstrap 只校验不 commit」，
#   这个前提是错的 —— workflow 把 custom/ bind mount 到 files/etc/config，整体遮蔽，
#   那份文件从未进过镜像；镜像里是 lxc-auto 包自带的注释模板
#   （#config container / #option name container1 / ...），一行有效配置都没有。
#   于是：bootstrap 每轮补写 → guard 每轮按 /rom 的模板复原 → 死循环，容器随机起不来。
#   现在它是运行期 uci 配置，由 uci-defaults/98-lxc-auto.sh 首启写入 +
#   _ensure_lxc_auto 每轮自愈，跟 network / firewall 同性质，不进 guard。
# 其余 /etc/config/*（custom_router_*.txt、network、firewall）同样不进：它们是
# action 注入或 bootstrap 每轮都要写的运行期配置。

# 可测化：测试用 CS_GUARD_ROM / CS_GUARD_ROOT / CS_GUARD_LOG 把三个根重定向到临时目录，
# 生产环境全部走默认值（CS_GUARD_ROOT 为空 = 直接操作真实路径）。
ROM_DIR="${CS_GUARD_ROM:-/rom}"
ROOT="${CS_GUARD_ROOT:-}"
GLOG="${CS_GUARD_LOG:-/root/crowdsec-guard.log}"
GUARD_FILES="${CS_GUARD_FILES:-
/usr/sbin/crowdsec-lxc-bootstrap.sh
/usr/sbin/crowdsec-lxc-probe.sh
/usr/sbin/crowdsec-guard.sh
/etc/rc.local
/etc/init.d/crowdsec-lxc-probe
/etc/init.d/lxc-auto
}"

QUIET=0
[ "$1" = "quiet" ] && QUIET=1

# 日志 64KB 封顶：正常情况一条都不写；被反复篡改时每轮一行，不封顶会一直涨下去。
# 超限就只留最后 200 行（约 20KB），封顶之后长期占用不再增长。
_rotate_log() {
    [ -f "$GLOG" ] || return 0
    _sz=$(wc -c <"$GLOG" 2>/dev/null)
    [ -n "$_sz" ] || return 0
    [ "$_sz" -gt 65536 ] || return 0
    tail -n 200 "$GLOG" >"$GLOG.tmp" 2>/dev/null || return 0
    mv -f "$GLOG.tmp" "$GLOG" 2>/dev/null
    return 0
}

_glog() {
    _rotate_log
    echo "[$(date '+%F %T')] $*" >>"$GLOG" 2>/dev/null
    [ "$QUIET" = "1" ] || echo "crowdsec-guard: $*" >&2
}

# 没有 cmp 就比不了基准。不能默认"一致"（那等于静默失效），也不能默认"不一致"
# （那会每轮无谓覆盖），只能明确报告一次然后让开。
command -v cmp >/dev/null 2>&1 || {
    _glog "【完整性】缺少 cmp，无法与只读基准比对，本次跳过"
    exit 0
}

for _rel in $GUARD_FILES; do
    _src="$ROM_DIR$_rel"
    _f="$ROOT$_rel"
    # 基准里没有这个文件 = 该平台没这个组件，不臆造
    [ -f "$_src" ] || continue
    # 权限以基准为准：脚本是 755，配置文件是 644。原先这里硬判 `[ -x ]`，
    # 只适合全是脚本的情况；一旦清单里出现 644 的 /etc/config/*，它会认为
    # 「不可执行 = 不一致」，每轮都复原一次，反而把配置文件搅进死循环。
    _src_mode=$(stat -c '%a' "$_src" 2>/dev/null)
    [ -n "$_src_mode" ] || _src_mode=755
    # 内容一致且权限一致 → 正常路径，零动作
    if [ -f "$_f" ] && cmp -s "$_src" "$_f" \
       && [ "$(stat -c '%a' "$_f" 2>/dev/null)" = "$_src_mode" ]; then
        continue
    fi
    _had=0
    _bak=""
    if [ -f "$_f" ]; then
        _had=1
        # 留一份被改过的原文当证据；只留最近一份，避免 /etc 下的备份随刷机越积越多
        rm -f "$_f".user-* 2>/dev/null
        _bak="$_f.user-$(date '+%Y%m%d%H%M%S')"
        cp -f "$_f" "$_bak" 2>/dev/null || _bak=""
    fi
    # 必须先删再拷：文件被删过时这里是 overlay 的 whiteout，不清掉副本建不出来
    rm -f "$_f" 2>/dev/null
    if cp -f "$_src" "$_f" 2>/dev/null; then
        chmod "$_src_mode" "$_f" 2>/dev/null
        if [ "$_had" = "1" ]; then
            _glog "【完整性】$_f 与只读基准不一致，已复原${_bak:+（原内容另存 $_bak）}"
        else
            _glog "【完整性】$_f 被删除，已从只读基准复原"
        fi
    else
        _glog "【完整性】$_f 复原失败：只读基准不可读或目标不可写"
    fi
done

exit 0
