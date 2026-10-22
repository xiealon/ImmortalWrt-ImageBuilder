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
# 【v.108.44】权限判据原来用 `stat -c '%a'`，本固件的 busybox **没有编 stat**
#   （真机实测 `-ash: stat: not found`）。后果是一串连锁：
#     · 基准侧取到空串 → 兜底成 755
#     · 运行侧取到空串 → `"" = "755"` 恒假
#     · 于是每一次调用都判「不一致」，连内容一模一样的 5 个文件也被 rm+cp 重写一遍
#     · 探针每 60 秒调一次 → 每分钟写 ≈246KB overlay，一天 ≈354MB，且每次 rm+cp
#       都新建 inode，FTL 磨损集中在同一批块上
#   真机日志（08:28–08:33）每分钟 6 条、连续 6 轮，就是这么来的；而同一个文件
#   `cmp` 明明返回 0。判据坏了却没人报错，这类"永远为假"的条件比功能缺失更难发现。
#   现在不再依赖 stat：只看有没有执行位（squashfs 会保留权限位，-x 判足够），
#   而且**内容一致时只 chmod、绝不重写文件** —— 权限漂移不该付出重写 246KB 的代价。
#
# 【v.108.46】再扩 5 个静态配置（net.conf / resolv.conf / hosts /
#   acquis.d/router.yaml / parsers 两个），共「宿主 6 + 容器内 15」= 21 个。
#
# 【v.108.47】真机抓到的路径 bug：容器组从 v.108.45 起就没生效过。
#   GUARD_CT_FILES 存的是容器内路径（/etc/passwd），主循环却直接拿它拼
#   $ROM_DIR$_rel 与 $ROOT$_rel —— 拼出来是「/rom/etc/passwd 对 /etc/passwd」，
#   也就是拿固件里宿主自己的 passwd 当基准，去覆盖宿主自己的 passwd。
#   真机日志（2026-10-22 11:02:22）两条复原记录都是宿主的 /etc/passwd、/etc/group；
#   而用户实测「改坏 /srv/lxc/ubuntu/rootfs/etc/init.d/rcS 后 70 秒无人复原」，
#   因为 guard 从头到尾没看过那个文件（它比的是宿主 /etc/init.d/rcS）。
#   修法：进循环前给容器组补上 GUARD_CT_PREFIX（见 _CT_LIST），_src/_f 就都对了；
#   _ct_gate 也从「在循环里 case 判断」变成「决定要不要拼这批条目」，语义更直白。
#   这 5 个以前由 bootstrap 每轮重写（所以进不了 guard），v.108.46 起改为构建期固定：
#   IP / DNS 写死在 rootfs-skel 里，acquis/parsers 本来就是纯静态 YAML。
#   注意 hosts 也在此列 —— 它含 `10.1.0.10 crowdsec`，改坏了容器内解析自己都成问题。
#
# 【v.108.45】保护范围从宿主侧 6 个扩展到「宿主 6 + 容器内 9」= 15 个：
#   容器内那批（inittab / init.d/{rcS,crowdsec,netconf,syslogd} / usr/sbin/crowdsec-supervise
#   / etc/{passwd,group,nsswitch.conf}）以前只有「存在且非空」这一档判据，内容被改坏
#   既不自愈也查不出来，只能靠 last_pull 停滞间接发现，且发现后唯一手段是整盘重解压 288MB。
#   现在固件里（squashfs）带同一批文件的副本，guard 用同路径比对 + 原子替换，
#   恢复代价降到几十 KB。三处清单必须始终同版：rootfs-skel/（唯一来源）、
#   build24/25.sh（拷进固件）、本文件（比对清单）；单一来源写错就退化成
#   「每分钟把 6 个文件盖一遍」，正是 v.108.44 那个事故的形态。
#   配套改动：_structurally_broken 不再把 inittab / init.d/crowdsec 当「缺失即损坏」
#   的判据（固件里有副本，判据会恒真），改用固件里没有的那批文件兜底。
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

# 【v.108.45】容器内脚本也纳入保护，但单独一组：它们的目标在容器 rootfs 里，
# 恢复动作必须多两道门（见 _ct_gate），不能和宿主侧混在一个循环里无条件执行。
# 路径与 /rom 严格同构（/rom/srv/lxc/ubuntu/rootfs/etc/init.d/rcS 对
# /srv/lxc/ubuntu/rootfs/etc/init.d/rcS），靠 build24/25.sh 在出镜像前把
# rootfs-skel/ 里那 6 个文件拷进 files/srv/lxc/ubuntu/rootfs/。
#
# 为什么值得做：这些脚本决定容器能不能起来（inittab 是 PID1 的启动表，rcS 是
# 服务序列，crowdsec-supervise 是退避重拉）。以前它们只有「存在且非空」这一档判据，
# 内容被改坏既不会重装也查不出来，只能靠 last_pull 停滞间接发现、且发现后也修不好。
# 纳入之后：改坏 → 60 秒内被 /rom 副本盖回，恢复代价是几十 KB 而不是整盘重解压 288MB。
#
# 代价与风险（都已在构建侧挡住）：
#   · 两份内容必须始终同版 —— prepare 与 guard 的基准都来自 rootfs-skel/，单一来源；
#   · rootfs 还没解压时不能写 —— 会污染 verify_rootfs 的就绪判断（门①）；
#   · systemd 版 rootfs（legacy lxc-ubuntu.tar.gz）语义完全不同 —— 不能碰（门②）。
GUARD_CT_PREFIX="/srv/lxc/ubuntu/rootfs"
# 【v.108.56】基准落在 /rom 的哪一份。
# 从前基准与运行期同路径（/rom/srv/lxc/ubuntu/rootfs），容器基底改成「整份摊进 squashfs」
# 之后，基底在 /rom/srv/lxc/ubuntu/base，基准必须跟着搬。
# 不搬的后果很隐蔽：_src 指向不存在的路径 → 下面 `[ -f "$_src" ] || continue` 静默跳过
# 全部 15 个文件，guard_rc 仍是 0、日志一个字不写，看起来「一切正常」。
GUARD_CT_BASE="${CS_GUARD_CT_BASE:-/srv/lxc/ubuntu/base}"
# 可写层（overlay upperdir）。审计段用它枚举「哪些文件被碰过」。
GUARD_CT_UPPER="${CS_GUARD_CT_UPPER:-/overlay/lxc-upper}"
GUARD_CT_FILES="${CS_GUARD_CT_FILES:-
/etc/passwd
/etc/group
/etc/nsswitch.conf
/etc/hosts
/etc/resolv.conf
/etc/crowdsec-net.conf
/etc/crowdsec/acquis.d/router.yaml
/etc/crowdsec/parsers/s01-parse/openwrt-dropbear.yaml
/etc/crowdsec/parsers/s02-enrich/openwrt-whitelist.yaml
/etc/inittab
/etc/init.d/rcS
/etc/init.d/crowdsec
/etc/init.d/netconf
/etc/init.d/syslogd
/usr/sbin/crowdsec-supervise
}"
ROOTFS="${CS_GUARD_ROOTFS:-$ROOT$GUARD_CT_PREFIX}"

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
# 【v.108.56】第二段：可写层白名单审计（只报不杀）。
# 第一段盯 15 个关键文件、不一致就原子复原，可它永远追不上 rootfs 里的全部文件。
# overlay 给了一个现成的可观测面：任何落到 base 之上的写入都会在 upper 留副本，
# 于是「upper 里有哪些文件」就是「哪些文件被动过」的完整清单 —— 不用遍历几万个文件。
#
# 但「进过 upper」不等于「被改坏」：真机实测 chmod/utime 也会 copy-up，
# 容器还会自己写 hostname / machine-id。所以判据不是「有没有」，而是「内容是否仍等于 base」。
# base 里没有这个文件 = 容器新增的（machine-id 就是），不算篡改，跳过。
#
# 只报不杀：运行时写入与篡改在字节上不可区分，先观察误报率再决定要不要升级成复原。
# 单个文件不一致就让整盘回滚，代价远大于收益。
_ovl_audit() {
    _ab="$ROM_DIR$GUARD_CT_BASE"
    [ -d "$_ab" ] || return 0
    [ -d "$GUARD_CT_UPPER" ] || return 0
    _n=0
    _shown=0
    for _u in $(find "$GUARD_CT_UPPER" -type f 2>/dev/null); do
        _r="${_u#"$GUARD_CT_UPPER"}"
        case "$_r" in
        # 我们自己的元数据与 guard 备份
        /.base-fingerprint|*.user-*|*.guard-tmp) continue ;;
        # bootstrap 每轮重写 / 容器运行时正常写入
        /etc/resolv.conf|/etc/crowdsec-net.conf|/etc/hostname|/etc/machine-id) continue ;;
        /etc/crowdsec/*|/etc/config/*|/var/*|/tmp/*|/root/*|/run/*|/dev/*|/proc/*|/sys/*) continue ;;
        esac
        [ -f "$_ab$_r" ] || continue
        cmp -s "$_ab$_r" "$_u" && continue
        _n=$((_n + 1))
        if [ "$_shown" -lt 10 ]; then
            _shown=$((_shown + 1))
            _glog "【审计】$_r 的可写层副本与只读基底不一致（只报不杀，请人工确认）"
        fi
    done
    [ "$_n" -gt 10 ] && _glog "【审计】另有 $((_n - 10)) 处不一致未列出（本轮共 $_n 处）"
    return 0
}

command -v cmp >/dev/null 2>&1 || {
    _glog "【完整性】缺少 cmp，无法与只读基准比对，本次跳过"
    exit 0
}

# 容器侧两道门（v.108.45）。任一不满足 → 这一组整体跳过，一个字节都不碰。
_ct_gate() {
    # ① rootfs 必须已经就位。判据仍是 os-release，但它的来源变了：
    #    v.108.56 起容器基底整份在 squashfs，os-release 由 lower 提供 —— 也就是说，
    #    overlay 没挂上时这个文件不存在（挂载点是空目录），挂了才有。判据依旧成立，
    #    只是含义从「解压完了」变成「overlay 就位了」。未就位时写文件同样会提前
    #    造出 etc/ 这些路径，把就绪判断搅浑，所以这道门必须留着。
    [ -s "$ROOTFS/etc/os-release" ] || return 1
    # ② 必须是极简 init 的 rootfs。systemd 版（legacy /opt/lxc-ubuntu.tar.gz）里
    #    这些路径语义完全不同，把 busybox 的 inittab / rcS 盖进去等于直接把容器毁掉。
    #    这条不是优化，是硬门：宁可不管，也不能管错对象。
    [ -f "$ROOTFS/etc/inittab" ] || return 1
    [ -e "$ROOTFS/lib/systemd/systemd" ] && return 1
    return 0
}

_CT_OK=0
_ct_gate && _CT_OK=1

# 【v.108.47】容器组必须先补前缀再进循环，这是真机抓到的 bug。
# GUARD_CT_FILES 里写的是「容器内绝对路径」（/etc/passwd），而循环用 _rel 直接拼
# $ROM_DIR$_rel / $ROOT$_rel。不补前缀就变成：
#     _src=/rom/etc/passwd    ← 固件里宿主自己的 passwd
#     _f=/etc/passwd          ← 宿主自己的 passwd
# 于是这一组从头到尾都在「拿固件版覆盖宿主版」，容器里那 15 个文件一次都没比过。
# 而且 case "$GUARD_CT_PREFIX"/* 永远不匹配，_ct_gate 的两道门形同虚设（算了不用）。
# 真机 2026-10-22 11:02:22 那两条「/etc/passwd、/etc/group 与只读基准不一致，已复原」
# 就是宿主被误伤，不是容器。
# 两个后果都是静默的，所以从 v.108.45 到 v.108.46 一直没被发现：
#   · 容器里的 rcS 被改坏 → 不复原、不报警（用户实测确认）；
#   · 宿主被改 → 复原一次后 cmp 就相等了，从此安静，日志只留一条看不出规模。
_CT_LIST=""
if [ "$_CT_OK" = "1" ]; then
    for _rel in $GUARD_CT_FILES; do
        _CT_LIST="$_CT_LIST $GUARD_CT_PREFIX$_rel"
    done
fi

for _rel in $GUARD_FILES $_CT_LIST; do
    case "$_rel" in
    "$GUARD_CT_PREFIX"/*)
        # 容器组：目标读挂载点（overlay 合并视图），基准读 /rom 只读基底
        _src="$ROM_DIR$GUARD_CT_BASE${_rel#"$GUARD_CT_PREFIX"}"
        ;;
    *)
        _src="$ROM_DIR$_rel"
        ;;
    esac
    _f="$ROOT$_rel"
    # 基准里没有这个文件 = 该平台没这个组件，不臆造。
    # 容器组走到这里时 _rel 已带 GUARD_CT_PREFIX，_src 就是 /rom/srv/lxc/... 的副本。
    [ -f "$_src" ] || continue
    # 权限只比「有没有执行位」这一维：squashfs 保留权限位，清单里脚本是 755、配置是 644，
    # -x 判足够。**不要用 stat -c %a** —— 本固件 busybox 没编 stat，取到空串就会让
    # 下面的比较恒假（v.108.44 的真机事故：每分钟把 6 个文件全重写一遍）。
    _src_mode=644
    [ -x "$_src" ] && _src_mode=755
    # 内容一致 → 正常路径。权限漂移只 chmod，绝不 rm+cp：
    # 重写一个 226KB 的脚本只为改一个权限位，在 flash 上是纯损耗。
    if [ -f "$_f" ] && cmp -s "$_src" "$_f"; then
        _run_mode=644
        [ -x "$_f" ] && _run_mode=755
        if [ "$_run_mode" != "$_src_mode" ]; then
            chmod "$_src_mode" "$_f" 2>/dev/null
            _glog "【完整性】$_f 权限变成 $_run_mode，已按基准改回 $_src_mode（内容未动）"
        fi
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
    case "$_rel" in
    "$GUARD_CT_PREFIX"/*)
        # 容器侧必须原子替换：容器随时可能在启动，读到半个 rcS / inittab 会让
        # sh 解析失败、容器直接起不来。做法是「同目录写临时文件 + rename」。
        # 不用 rm+cp：那条路径中间有一段「文件不存在」的窗口，正好撞上就是事故。
        _tmp="$_f.guard-tmp"
        if cp -f "$_src" "$_tmp" 2>/dev/null && chmod "$_src_mode" "$_tmp" 2>/dev/null; then
            if ! mv -f "$_tmp" "$_f" 2>/dev/null; then
                # overlayfs 上 rename 下层文件理论上会先 copy-up 再 rename；
                # 万一内核拒绝（EXDEV），退回 cp 覆盖（有窗口但总比不修好）。
                cp -f "$_tmp" "$_f" 2>/dev/null
                rm -f "$_tmp" 2>/dev/null
            fi
            # 【v.108.56】复原动作「返回成功」不等于「真的修好了」。真机抓到过：
            # 绕过挂载点 rm 掉 upperdir 里的文件之后，overlay 的 dentry 仍指向已 unlink
            # 的孤立 inode，mv 失败走 fallback cp，cp 也写进那个孤立 inode ——
            # 日志写着「已原子复原」，回读却还是脏内容，而 upperdir 里连文件都没有。
            # guard 是最后一道防线，它要是也会撒谎，整套保护就只剩心理安慰。
            # 所以回读一次：657 字节的 cmp，成本可以忽略。
            if ! cmp -s "$_src" "$_f"; then
                _glog "【完整性】$_f 已执行复原，但回读仍与基准不一致（疑似 overlay 孤立 inode / 缓存未刷新，多因绕过挂载点直接改 upperdir）—— 需重启或 umount 重挂"
            elif [ "$_had" = "1" ]; then
                _glog "【完整性】$_f 与只读基准不一致，已原子复原${_bak:+（原内容另存 $_bak）}"
            else
                _glog "【完整性】$_f 被删除，已从只读基准复原（容器脚本）"
            fi
        else
            rm -f "$_tmp" 2>/dev/null
            _glog "【完整性】$_f 复原失败（容器脚本）：只读基准不可读或目标不可写"
        fi
        ;;
    *)
        # 必须先删再拷：文件被删过时这里是 overlay 的 whiteout，不清掉副本建不出来
        rm -f "$_f" 2>/dev/null
        if cp -f "$_src" "$_f" 2>/dev/null; then
            chmod "$_src_mode" "$_f" 2>/dev/null
            if ! cmp -s "$_src" "$_f"; then
                _glog "【完整性】$_f 已执行复原，但回读仍与基准不一致 —— 需人工介入"
            elif [ "$_had" = "1" ]; then
                _glog "【完整性】$_f 与只读基准不一致，已复原${_bak:+（原内容另存 $_bak）}"
            else
                _glog "【完整性】$_f 被删除，已从只读基准复原"
            fi
        else
            _glog "【完整性】$_f 复原失败：只读基准不可读或目标不可写"
        fi
        ;;
    esac
done

# 只在容器组通过前置门（rootfs 已就位）时审计，否则 upper 内容没有参照意义。
[ "$_CT_OK" = "1" ] && _ovl_audit

exit 0
