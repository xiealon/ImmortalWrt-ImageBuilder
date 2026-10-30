#!/bin/sh
# 【2026-10-31.0256】固件版本标记 —— 与 crowdsec-lxc-bootstrap.sh 的 SCRIPT_VER 同步，每次改脚本一起改
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
# 【v.108.60】把容器里「能固定的都固定」，重点是通信 / 日志 / 网络这三条链路：
#   · acquis.yaml（日志入口，config 的 acquisition_path 指着它）进第一层清单 ——
#     以前它被删只能等 _structurally_broken 判「容器损坏」→ 整盘重装；现在一次原子 cp。
#   · /etc/crowdsec 从整目录白名单收窄（见 _ovl_audit）：hub/、config.yaml、两本凭据、
#     *.db 仍放过；其余（profiles / simulation / scenarios / postoverflows /
#     notifications / acquis.d）由审计段按只读基底复原。新增文件不动 ——
#     cscli 自己装的规则是新文件，不该被当成篡改。
#   · config.yaml 单列 _cs_cfg_audit：它有设计内会变的 online_client 两行，
#     逐字节比必然互斗，只判 daemonize / listen_uri 这两条「两态相同」的结构行。
#   · profiles.yaml / simulation.yaml 进第一层清单：它们在 upper 里被改坏，crowdsec
#     启动就在解析阶段失败 —— 那不是「配置不合适」，是 LAPI 已经死了。
#   · 同类但无法逐文件列举的（scenarios / parsers / postoverflows / notifications /
#     acquis.d），在审计段里豁免单轮上限 OVL_FIX_MAX：那个上限是防「白名单漏了大目录
#     被整层推回出厂态」，不该拦「动了就死」的配置。
# 代价（明确写下，不藏在实现里）：容器里手改 profiles.yaml 这类文件会被 60 秒内盖回；
# 要改就改 rootfs-skel/ 重新构建。这是「半不可变」的取舍，与那 3 个解析器一致。
# 时机上的一个事实：v.108.56 起 prebuilt 包解压成 /rom/.../base 后即删，固件里不再有
# tarball —— 也就是说 base 是设备上唯一的容器基线，而它在 squashfs 里只读、改不掉。
# 所以这套「抹 upper = 回基底」的恢复路径不依赖任何可写副本。
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
# 【v.180.78】固件版本号。五个脚本统一用 SCRIPT_VER 一个名字，
# 一条命令就能全查出来：
#   grep -H -m1 '^SCRIPT_VER=' /usr/sbin/crowdsec-*.sh /etc/rc.local \
#        /etc/init.d/crowdsec-lxc-probe
# 只有 crowdsec-lxc-bootstrap.sh 的那一份参与 CFG_SHA_FILE 指纹判定；
# 这里这份纯标记，改它不会触发任何重写。
SCRIPT_VER="2026-10-31.0256"
# 【v.180.152】补进 v.180.146~151 新增的 6 个恢复脚本。
# 【v.180.162】再加 pkg-restore-apps.sh（应用主程序恢复），共 7 个。
# 增删恢复脚本时必须同步这张清单 —— 漏一个是「脚本自己也会被删掉」的静默失效：
# 探针那一轮只会报「装不上」，而能把脚本补回来的东西当时已经不在了。
# 之前只保护了 bootstrap / probe / guard 三个 crowdsec-*.sh，pkg 这套是裸奔的：
# 被 opkg remove 连带删掉、或被手滑 rm 掉之后，探针那一轮只会报「装不上」，
# 没有任何东西能把脚本本身补回来 —— 恰恰是这套保护最该覆盖的对象。
# 它们是纯脚本（最大 6.3KB），六份加起来 ≈33KB，比容器 rootfs 里任何一个文件都小，
# 每轮 cmp 的代价可以忽略；纳入之后探针 60 秒内自动复原，与 bootstrap 同一套机制。
# 注意：lxc 的二进制**不**进这份清单，但**不是**因为没人保护它 ——
# 它归 pkg_base 的包级恢复，两条判据并行，各防一种故障：
#   · _lxc_missing_deps：5 个核心 applet（lxc-start/stop/ls/info/attach）可执行
#     + lxc-start --version 冒烟（抓 liblxc 加载失败）→ 防「记账在、二进制被删」
#   · _lxc_missing_pkgs：pkg-restore.sh --lxc-missing 判全家桶在不在册
#     → 防「整包被删」（opkg remove --force-depends 的典型结果）
# 为什么不逐字节 cmp：**不是因为它大**。2026-10-29 真机实测：20 个 applet 合计
# 1.3MB、liblxc.so.1.8.0 936KB，全量 cmp 也就几毫秒 —— 先前这里写「14MB 量级」，
# 是把量级估错了十倍，并因此给了一条不成立的理由。真正的原因是包级恢复自带
# 记账与依赖树：逐字节盖回二进制会绕开包管理器，留下「文件是 guard 盖的、
# 记账说没装」的状态，LuCI 与后续 apk/opkg 操作都会读错。
GUARD_FILES="${CS_GUARD_FILES:-
/usr/sbin/crowdsec-lxc-bootstrap.sh
/usr/sbin/crowdsec-lxc-probe.sh
/usr/sbin/crowdsec-guard.sh
/usr/sbin/pkg-restore.sh
/usr/sbin/pkg-restore-smartdns.sh
/usr/sbin/pkg-restore-apps.sh
/usr/sbin/pkg-cache-lib.sh
/usr/sbin/pkg-cache-fix.sh
/usr/sbin/pkg-cache-restore.sh
/etc/rc.local
/etc/init.d/crowdsec-lxc-probe
/etc/init.d/lxc-auto
/etc/init.d/cgroup2-guard
}"
# 【v.180.163】cgroup2-guard 是这三个 init.d 里唯一没有 .sh 后缀的，
# 所以按后缀扫的两个通道（本清单早期也是手写枚举、build24/25 的 chmod 列表）
# 都漏了它。它被删之后不会立刻出事 —— 只在下次重启时 dockerd 起不来
# （devices cgroup 没挂 → docker0 不建），这种「重启才炸」的缺口最难查。
# 【v.180.120】目录级保护：固件自带的自检脚本。
# repo/tests/ 在构建期被铺到 /usr/share/crowdsec-tests/（build24/25.sh 负责），
# 刷机后 /rom 里就有同一份，于是这里能拿它当基准。
#
# 为什么不让这批文件逐条列进 GUARD_FILES：
#   · 新增一个测试就得回来补一条，早晚漏；
#   · 逐文件那一套会为每个文件留一份 .user-<时间戳> 备份，几十份备份在 flash 上太浪费。
# 整目录做一次清单比对，不一致就整目录换回，一处逻辑管到底。
#
# 旧固件 /rom 里没有这个目录 —— 下面循环第一行判 -d 就跳过，零动作、零日志。
GUARD_DIRS="${CS_GUARD_DIRS:-/usr/share/crowdsec-tests}"

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
# 清单里全部文件，guard_rc 仍是 0、日志一个字不写，看起来「一切正常」。
GUARD_CT_BASE="${CS_GUARD_CT_BASE:-/srv/lxc/ubuntu/base}"
# 可写层（overlay upperdir）。审计段用它枚举「哪些文件被碰过」。
GUARD_CT_UPPER="${CS_GUARD_CT_UPPER:-/overlay/lxc-upper}"

# 【v.108.57】LAPI 持续监测。引导时 bootstrap 只在建容器那一轮探一次 8080，
# 运行期没人管 —— 而 crowdsec 挂了、被禁、决策库被清，都不会让容器状态异常。
# 白名单里的 /etc/crowdsec/* 不设防，但它们的「效果」可以观测：
#   /health 通不通 + bouncer 还在不在拉 + 决策数有没有被清零。
GUARD_LAPI_URL="${CS_GUARD_LAPI_URL:-http://10.1.0.10:8080}"
GUARD_LXC_PATH="${CS_GUARD_LXC_PATH:-/srv/lxc}"
GUARD_LXC_NAME="${CS_GUARD_LXC_NAME:-ubuntu}"
# bouncer 名与 bootstrap 的 BOUNCER_NAME 默认值必须一致：
# 不一致的表现是「列表里没有这个 bouncer」，而真实原因是查错了名字。
GUARD_BOUNCER="${CS_GUARD_BOUNCER:-openwrt-fw}"
GUARD_TS_RE='[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]'
GUARD_LAPI_AUDIT="${CS_GUARD_LAPI_AUDIT:-1}"
# 300s：guard 本身被探针每 60s 调一次，而 LAPI 检查每次要 attach 两回。
# 心跳是 10s 一次，60s 阈值下 300s 的采样间隔足够抓到真停滞，又不至于把
# 「一次网络抖动」放大成日志洪水。
GUARD_LAPI_INTERVAL="${CS_GUARD_LAPI_INTERVAL:-300}"
GUARD_LAPI_STATE="${CS_GUARD_LAPI_STATE:-/root/.crowdsec-guard-lapi}"

# last_pull 新鲜度：常量必须与 bootstrap 的 _BP_PULL_* 同版（当前 10s × 6 = 60s）。
# 为什么不是 600s：bouncer 心跳 10s，连续丢 6 个周期已经是强信号；防抖由探针的
# CS_PROBE_STALL_ROUNDS（连续 3 轮才动手）负责，guard 这边只做「看见」。
# 两处常量写错一处的后果很隐蔽：日志写着 60s、实际按别的数判 —— 正是本脚本一直在防的
# 那类「不报错、只给错误答案」。改这里之前先看 bootstrap 的 _BP_PULL_INTERVAL/_MISS。
GUARD_PULL_INTERVAL=10
GUARD_PULL_MISS=6
GUARD_PULL_MAX_AGE="${CS_GUARD_PULL_MAX_AGE:-$((GUARD_PULL_INTERVAL * GUARD_PULL_MISS))}"
GUARD_CT_FILES="${CS_GUARD_CT_FILES:-
/etc/passwd
/etc/group
/etc/nsswitch.conf
/etc/hosts
/etc/resolv.conf
/etc/crowdsec-net.conf
/etc/crowdsec/acquis.yaml
/etc/crowdsec/acquis.d/router.yaml
/etc/crowdsec/parsers/s01-parse/openwrt-dropbear.yaml
/etc/crowdsec/parsers/s02-enrich/openwrt-whitelist.yaml
/etc/crowdsec/profiles.yaml
/etc/crowdsec/simulation.yaml
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

# 【v.108.70】单轮耗时自报。以前只有「超时」才有日志，于是「一直是 9s、但还没到
# 10s」这种余量在收窄的状态完全看不见 —— 要么没事，出事就是一次硬超时。
# 两个落点，各管一件事：
#   · 每轮把「时间戳 + 本轮秒数」**覆盖写**进 $GUARD_TIMING（默认 /run，tmpfs：
#     不磨损 flash，也不占 GLOG 那 64KB / 200 行的预算）。想看余量 cat 一次即可。
#   · 超过 $GUARD_SLOW_WARN（默认 2s）才额外往 GLOG 写一行。那条是「要留意」，
#     不是「出事了」，所以措辞是「余量在收窄」而不是「超时」。
# 毫秒级用 /proc/uptime（两位小数）算，全程纯 shell + 一次 sed，**不依赖 awk** ——
# 本固件 busybox 不一定编了 awk，而「没有 awk 就静默不记」等于把观测能力悄悄关掉。
GUARD_TIMING="${CS_GUARD_TIMING:-/run/crowdsec-guard.timing}"
GUARD_SLOW_WARN="${CS_GUARD_SLOW_WARN:-2}"
case "$GUARD_SLOW_WARN" in ''|*[!0-9]*) GUARD_SLOW_WARN=2 ;; esac
# 时钟源。抽成变量只为测试能注入假 uptime（本机 busybox-w32 没有 /proc/uptime，
# 读不到就只能静默跳过，而这段最该被测的正是「浮点→百分之一秒」的换算）。
_GUARD_UPTIME="${CS_GUARD_UPTIME:-/proc/uptime}"
_GUARD_T0=""

# /proc/uptime -> 百分之一秒整数：「12345.67」→「1234567」，「0.07」→「7」。
# 放在 $( ) 里跑，read 的中间变量不会污染外层。
_guard_nowcs() {
    _gn_u=""
    _gn_rest=""
    read _gn_u _gn_rest 2>/dev/null <"$_GUARD_UPTIME"
    [ -n "$_gn_u" ] || return 1
    _gn_u=$(printf '%s' "$_gn_u" | sed 's/\.//; s/^0*//')
    [ -n "$_gn_u" ] || _gn_u=0
    case "$_gn_u" in *[!0-9]*) return 1 ;; esac
    printf '%s' "$_gn_u"
}
_GUARD_T0="$(_guard_nowcs)"

_gt_report() {
    [ -n "$_GUARD_T0" ] || return 0
    _gt1="$(_guard_nowcs)" || return 0
    case "$_gt1" in ''|*[!0-9]*) return 0 ;; esac
    _gt_dcs=$(( _gt1 - _GUARD_T0 ))
    [ "$_gt_dcs" -ge 0 ] 2>/dev/null || return 0
    _gt_v="$(( _gt_dcs / 100 )).$(printf '%02d' "$(( _gt_dcs % 100 ))")"
    printf '%s 本轮 %ss\n' "$(date '+%F %T')" "$_gt_v" >"$GUARD_TIMING" 2>/dev/null
    if [ "$_gt_dcs" -ge $(( GUARD_SLOW_WARN * 100 )) ] 2>/dev/null; then
        _glog "【计时】本轮 ${_gt_v}s（告警线 ${GUARD_SLOW_WARN}s）—— 余量在收窄：/health 的 wget 5s、3 处 attach 各 ${GUARD_CT_TIMEOUT}s，哪一环变慢都会先在这里显形"
    fi
    return 0
}

# 没有 cmp 就比不了基准。不能默认"一致"（那等于静默失效），也不能默认"不一致"
# （那会每轮无谓覆盖），只能明确报告一次然后让开。
# 【v.108.56】第二段：可写层白名单审计（只报不杀）。
# 第一段盯清单里那几个关键文件、不一致就原子复原，可它永远追不上 rootfs 里的全部文件。
# overlay 给了一个现成的可观测面：任何落到 base 之上的写入都会在 upper 留副本，
# 于是「upper 里有哪些文件」就是「哪些文件被动过」的完整清单 —— 不用遍历几万个文件。
#
# 但「进过 upper」不等于「被改坏」：真机实测 chmod/utime 也会 copy-up，
# 容器还会自己写 hostname / machine-id。所以判据不是「有没有」，而是「内容是否仍等于 base」。
# base 里没有这个文件 = 容器新增的（machine-id 就是），不算篡改，跳过。
#
# v.108.57 起改为自动复原：容器在这里被定义成「半不可变系统」—— base 里存在的文件
# 只要不在白名单，任何修改都会在下一轮被盖回去。代价是无法再在容器里临时调配置，
# 这是有意的取舍（固定文件不可变 > 现场可调）。
# 三道刹车：① base 里没有的新文件一律不动；② 单轮复原上限 OVL_FIX_MAX，超出只记录；
# ③ 每次复原都回读 cmp，失败单独记账，绝不在没修好时报「已复原」。
OVL_FIX_MAX="${CS_GUARD_OVL_FIX_MAX:-20}"

# 容器内执行：单条命令形式（cscli 之类），路径由调用方给全。
# 【v.108.66】10s 上限。guard 每 60s 跑一轮，若容器卡住让 lxc-attach 挂住不退，
# procd 不会 respawn（进程还在、没退出），整条保护链路就静默停摆 —— 正是
# 「看起来在跑、其实什么都没做」的那种坏法。与 bootstrap 的 CT_TIMEOUT 同口径。
GUARD_CT_TIMEOUT="${CS_GUARD_CT_TIMEOUT:-10}"

# 【v.108.67】/health 探测的硬顶。wget 的 --timeout=3 只覆盖「读/等对端回包」那一段，
# 建连与名字解析卡住时它不生效；而 guard 一旦挂在这一句上，procd 同样看到「进程还在」，
# 不会 respawn —— 与上面两处 attach 是同一种静默停摆。目标写的是 IP、正常 1s 内返回，
# 5s 只兜「卡死」这一种，不改变任何正常路径的判定。
GUARD_WGET_TIMEOUT="${CS_GUARD_WGET_TIMEOUT:-5}"
_ct_run() {
    timeout "$GUARD_CT_TIMEOUT" lxc-attach -P "$GUARD_LXC_PATH" -n "$GUARD_LXC_NAME" -- "$@" 2>/dev/null
}

# 容器内执行：带一个参数的小脚本。
# 用 sh -c '...' -- "$1" 而不是把参数拼进脚本文本 —— 时间串里有空格和冒号，
# 拼进去就要处理引号，而引号在这里出错的后果是「判不了」，且只在某些时间值上出现。
_ct_shell() {
    timeout "$GUARD_CT_TIMEOUT" lxc-attach -P "$GUARD_LXC_PATH" -n "$GUARD_LXC_NAME" -- /bin/sh -c "$1" -- "$2" 2>/dev/null
}

# 【v.108.57】last_pull 新鲜度：封禁到底有没有下发到防火墙，只有这一条能证明。
# 与 bootstrap 的 bouncer_pulling 判定同一口径，但**自己算一遍**，不复用那套输出：
# 探针拿 rc 当「在拉」直接清零停滞计数，它判不了时会放过（R12 有意为之）；
# guard 的处境不同 —— 它不修任何东西，所以「判不了」必须写进日志，否则就真的没人知道了。
# 时间比较全部在容器内完成（date +%s 与 date -d 都走容器）：设备时钟偏过 8 小时，
# 一边用宿主时钟、一边用容器时间戳，算出来的「年龄」会是任意值。
_lapi_pull_check() {
    _def=$((GUARD_PULL_INTERVAL * GUARD_PULL_MISS))
    _max="$GUARD_PULL_MAX_AGE"
    case "$_max" in
    ''|*[!0-9]*)
        _glog "【LAPI】CS_GUARD_PULL_MAX_AGE='$_max' 不是数字，回落默认 ${_def}s"
        _max="$_def"
        ;;
    esac
    if [ "$_max" -le 0 ]; then
        _glog "【LAPI】last_pull 新鲜度检查已按配置关闭（阈值 $_max，这是放行，不是判定为新鲜）"
        return 0
    fi

    _list="$(_ct_run /usr/bin/cscli bouncers list)"
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        _glog "【LAPI】lxc-attach 执行 cscli bouncers list 失败（rc=$_rc：容器未运行 / cscli 缺失）—— last_pull 判不了，这不是「新鲜」"
        return 0
    fi
    if [ -z "$_list" ]; then
        _glog "【LAPI】cscli bouncers list 回显为空 —— last_pull 判不了，这不是「新鲜」"
        return 0
    fi
    if ! printf '%s\n' "$_list" | grep -qE "^[[:space:]]*${GUARD_BOUNCER}[[:space:]]"; then
        _glog "【LAPI】bouncer 列表里没有 ${GUARD_BOUNCER}（未注册 / 被删 / 名字写错）—— 封禁不会下发，请核查"
        return 0
    fi

    _lp="$(printf '%s\n' "$_list" | grep -E "^[[:space:]]*${GUARD_BOUNCER}[[:space:]]" | grep -oE "${GUARD_TS_RE}Z?" | head -n 1)"
    if [ -z "$_lp" ]; then
        _glog "【LAPI】bouncer ${GUARD_BOUNCER} 的行里取不到 last_pull 时间列（cscli 输出格式变了？）—— 判不了，这不是「新鲜」"
        return 0
    fi

    # busybox 的 date -d 不吃带 T/Z 的 ISO8601（bootstrap v.108.44 的真机事故：
    # 格式没规整 → _at 恒空 → 检查从上线起就没真正执行过，日志还写着「判不了」）。
    # 这里同样先规整：T 换空格、去掉尾部 Z。容器无 tzdata、本地即 UTC，两种写法等价。
    _norm="$(printf '%s' "$_lp" | sed -e 's/T/ /' -e 's/Z$//')"
    _times="$(_ct_shell 'date +%s; date -u -d "$1" +%s 2>/dev/null || date -d "$1" +%s' "$_norm")"
    _now="$(printf '%s\n' "$_times" | sed -n '1p')"
    _at="$(printf '%s\n' "$_times" | sed -n '2p')"
    # 两种失败分开报：「容器内 date 回显为空」和「格式不认」是两件事，
    # 混成一句会把排查方向带偏（真机日志就这么误导过：now=[…] at=[] 被写成「date 不可用」）。
    case "$_now" in
    ''|*[!0-9]*)
        _glog "【LAPI】last_pull 判不了（容器内 date +%s 回显异常：[$_now]），这不是「新鲜」"
        return 0
        ;;
    esac
    case "$_at" in
    ''|*[!0-9]*)
        _glog "【LAPI】last_pull 判不了（容器内 date 解析不了 [$_lp]，规整后 [$_norm]），这不是「新鲜」"
        return 0
        ;;
    esac

    _age=$((_now - _at))
    # 年龄为负 = last_pull 在「未来」。这既不是新鲜也不是停滞，是时钟不可信，
    # 按任何一种判都会得出错误结论，所以单独报一句。
    if [ "$_age" -lt 0 ]; then
        _glog "【LAPI】last_pull 在 ${_age#-}s 之后（容器时钟被回拨？）—— 判不了，这不是「新鲜」"
        return 0
    fi
    if [ "$_age" -gt "$_max" ]; then
        _glog "【LAPI】bouncer ${GUARD_BOUNCER} last_pull 停滞 ${_age}s（最后一次 $_lp，阈值 ${_max}s）—— 封禁未下发，请核查 bouncer 进程与 ${GUARD_LAPI_URL} 的连通性"
    fi
    return 0
}

# 【v.108.57】LAPI 旁证：白名单里的文件不设防，但它们的「效果」可以观测。
# 三个判据，按可信度排序：
#   ① /health 必须从宿主探 —— 容器内 curl 127.0.0.1 永远通，即使 LAPI 只听回环；
#   ② last_pull 必须新鲜 —— 「封禁有没有真的下发」只有这一条能证明；
#   ③ 决策数从 >0 归零要报 —— 清库最典型的特征。
# ③ 有误报可能：封禁都有 duration，全部自然到期也会归零。所以措辞是「请核查」，
# 不是「已被篡改」。宁可让人去查一次，也不要假装没看见。
# 降频：每 GUARD_LAPI_INTERVAL 秒（默认 300）才探一次，避免每 60 秒 attach 一次。
# 这里只记录、不修：修是探针的活（重跑引导 + 冷却 + 连续失败记账），
# guard 抢着修会和它各跑一次引导，反而制造并发问题。
_lapi_audit() {
    [ "$GUARD_LAPI_AUDIT" = "1" ] || return 0
    # 容器没就位（overlay 未挂）时，LAPI 探测只会产出一堆「不可达」噪声。
    [ "$_CT_OK" = "1" ] || return 0
    command -v wget >/dev/null 2>&1 || return 0
    # 【2026-10-31.0256】lxc-attach 必在（容器就是 LXC），写死不探测（用户 2026-10-31 定）。
    _lnow="$(date +%s 2>/dev/null)"
    case "$_lnow" in ''|*[!0-9]*) return 0 ;; esac
    _llast=0
    [ -s "$GUARD_LAPI_STATE.ts" ] && _llast="$(cat "$GUARD_LAPI_STATE.ts" 2>/dev/null)"
    case "$_llast" in ''|*[!0-9]*) _llast=0 ;; esac
    [ $((_lnow - _llast)) -ge "$GUARD_LAPI_INTERVAL" ] || return 0
    printf '%s\n' "$_lnow" >"$GUARD_LAPI_STATE.ts" 2>/dev/null

    # ① 健康：从宿主探 10.1.0.10:8080。不通就到此为止 —— 链路本身断了，
    # 再报 last_pull 停滞只是把同一个原因说两遍。
    if ! timeout "$GUARD_WGET_TIMEOUT" wget -qO- --timeout=3 "$GUARD_LAPI_URL/health" 2>/dev/null | grep -q '"status"'; then
        _glog "【LAPI】$GUARD_LAPI_URL/health 不可达 —— 容器未跑 / crowdsec 已停 / 8080 未对外开放"
        return 0
    fi

    # ② last_pull
    _lapi_pull_check

    # ③ 决策数：cscli 是事实来源，DB 只是缓存
    _out="$(_ct_run /usr/bin/cscli decisions list -o json)"
    if [ $? -ne 0 ]; then
        _glog "【LAPI】cscli decisions list 执行失败（容器内 cscli 被破坏 / LAPI 拒绝该凭据）—— 请人工核查"
        return 0
    fi
    _cur="$(printf '%s\n' "$_out" | grep -c '"id"')"
    case "$_cur" in ''|*[!0-9]*) _cur=0 ;; esac
    _prev=""
    [ -s "$GUARD_LAPI_STATE" ] && _prev="$(cat "$GUARD_LAPI_STATE" 2>/dev/null)"
    case "$_prev" in ''|*[!0-9]*) _prev="" ;; esac
    if [ -n "$_prev" ] && [ "$_prev" -gt 0 ] && [ "$_cur" -eq 0 ]; then
        _glog "【LAPI】决策数从 $_prev 归零（可能是封禁全部到期，也可能是 decisions.db 被清空）—— 请核查"
    fi
    printf '%s\n' "$_cur" >"$GUARD_LAPI_STATE" 2>/dev/null
    return 0
}

_ovl_audit() {
    _ab="$ROM_DIR$GUARD_CT_BASE"
    [ -d "$_ab" ] || return 0
    [ -d "$GUARD_CT_UPPER" ] || return 0
    _n=0
    _fixed=0
    _bad=0
    _skip=0
    for _u in $(find "$GUARD_CT_UPPER" -type f 2>/dev/null); do
        _r="${_u#"$GUARD_CT_UPPER"}"
        case "$_r" in
        # 自身元数据与备份
        /.base-fingerprint|*.user-*|*.guard-tmp) continue ;;
        # bootstrap 每轮重写 / 容器运行时正常写入
        /etc/resolv.conf|/etc/crowdsec-net.conf|/etc/hostname|/etc/machine-id) continue ;;
        # 【v.108.60】/etc/crowdsec 从「整目录放过」收窄成「只放过运行期必然变的几份」。
        # 以前一句 `/etc/crowdsec/*` 把通信、日志、规则全交出去了：acquis.yaml 被删、
        # profiles.yaml 被清空、scenarios/ 被替换，全都没人发现也没人修，只能靠
        # last_pull 停滞间接看出不对（而那时已经晚了）。现在按判据分三类：
        #   ① 运行期会变，必须放过：
        #      hub/                    cscli hub update 整仓重写，按 base 盖回=永久冻结规则库
        #      config.yaml             capi_block / capi_release 每轮按设计改 online_client 两行
        #                              （改由 _cs_cfg_audit 的结构判据管，见下）
        #      online_api_credentials  enroll 会写；local_api_credentials 是 LAPI 密码
        #      *.db                    决策缓存（实际在 /var，这里只是兜底）
        #   ② 构建期固定、运行期不该变 → 交给本段按 base 复原（新增的文件不在此列：
        #      下面 `[ -f "$_ab$_r" ] || continue` 保证「容器自己加的」不被动）
        #   ③ 其余全是运行数据，照旧放过
        /etc/crowdsec/hub/*|/etc/crowdsec/config.yaml) continue ;;
        /etc/crowdsec/online_api_credentials.yaml|/etc/crowdsec/local_api_credentials.yaml) continue ;;
        /etc/crowdsec/*.db|/etc/config/*|/var/*|/tmp/*|/root/*|/run/*|/dev/*|/proc/*|/sys/*) continue ;;
        esac
        # base 里没有 = 容器自己新增的（ld.so.cache、machine-id 之类）。
        # 不删不改：删了容器可能起不来，而「新增」本身不构成篡改证据。
        [ -f "$_ab$_r" ] || continue
        cmp -s "$_ab$_r" "$_u" && continue
        _n=$((_n + 1))
        # 单轮上限：正常 upper 里只有几十个文件，某一轮突然冒出上百个不一致，
        # 多半是白名单漏了某个目录（某个包在写 /usr/lib 之类）。这时全量复原
        # 等于把整个 rootfs 推回出厂状态，必须先停下来只记录。
        #
        # 【v.108.60】但 /etc/crowdsec 下的一切不吃这个上限：profiles / simulation /
        # scenarios / parsers / postoverflows 被改坏，crowdsec 启动就在解析阶段失败，
        # LAPI 直接死 —— 那不是「某个包在批量写」那种可疑迹象，是已经在流血的伤口。
        # 上限存在的目的是防误伤陌生路径，不该拦「动了就死」的配置。
        case "$_r" in
        /etc/crowdsec/*) ;;
        *)
            if [ "$_fixed" -ge "$OVL_FIX_MAX" ]; then
                _skip=$((_skip + 1))
                continue
            fi
            ;;
        esac
        _f="$ROOT$GUARD_CT_PREFIX$_r"
        # 备份只留最近一份，避免 /etc 下 .user-* 随轮次堆积
        rm -f "$_u".user-* 2>/dev/null
        _bak="$_u.user-$(date '+%Y%m%d%H%M%S')"
        cp -f "$_u" "$_bak" 2>/dev/null || _bak=""
        # 写入走挂载点（$ROOT$GUARD_CT_PREFIX...），**不直接写 upperdir**：
        # 绕过 overlay 改上层会留下「孤立 inode」，合并视图读不到新内容，
        # 真机踩过两次（日志说复原了、回读还是脏的、upper 里连文件都没有）。
        if cp -f "$_ab$_r" "$_f" 2>/dev/null && cmp -s "$_ab$_r" "$_f"; then
            _fixed=$((_fixed + 1))
            _glog "【审计】$_r 与只读基底不一致，已自动复原${_bak:+（原内容另存 $_bak）}"
        else
            _bad=$((_bad + 1))
            _glog "【审计】$_r 与只读基底不一致，自动复原失败（不可写或回读仍不同），需人工介入"
        fi
    done
    if [ "$_skip" -gt 0 ]; then
        _glog "【审计】本轮 $_n 处不一致：已复原 $_fixed、失败 $_bad、超出上限 $_skip（上限 $OVL_FIX_MAX，未处理）"
    fi
    return 0
}

# 【v.108.60】容器主配置的结构判据（config.yaml 刻意不进 GUARD_CT_FILES，也不走 _ovl_audit）。
# 为什么不能逐字节比：它有两行是设计内会变的 —— capi_block 把 online_client 注释掉、
# capi_release 再放开（bootstrap:3197-3217）。跟 base 逐字节比 → 每轮都判「不一致」→
# 盖回 base → bootstrap 下一轮又改 → 死循环，且每轮往 /etc/crowdsec 塞一个 .user-* 备份。
# 所以只判「两种状态下取值相同」的那两行。它们任一被改坏，后果都是静默失效：
#   daemonize 不是 false → crowdsec 自己 fork 到后台、父进程秒退，supervise 的 wait
#     立刻返回 → 每 5 秒重拉一次的假循环，还留孤儿进程（prepare:263-270 同一个判据）
#   listen_uri 不是 0.0.0.0:8080 → 路由器侧 bouncer 永远连不上，而容器内 LAPI 一切正常
#     （bootstrap ensure_listen_uri 同一个正则）
# 判据三处必须同期：prepare-crowdsec-minimal.sh（构建期写定）、bootstrap ensure_listen_uri、
# 本函数。改一处不改另两处，就会出现「构建说对了、引导说对了、guard 说不对」的互斗。
_cs_cfg_audit() {
    _cc_rel="/etc/crowdsec/config.yaml"
    _cc_src="$ROM_DIR$GUARD_CT_BASE$_cc_rel"
    _cc_f="$ROOT$GUARD_CT_PREFIX$_cc_rel"
    # 基准里没有 = 这台机器不归我管，不臆造一个 config.yaml 出来
    [ -f "$_cc_src" ] || return 0
    _cc_lapi=8080
    if [ -f "$_cc_f" ] \
       && grep -qE '^[[:space:]]*daemonize:[[:space:]]*false' "$_cc_f" 2>/dev/null \
       && grep -qE "^[[:space:]]*listen_uri:[[:space:]]*['\"]?0\.0\.0\.0:${_cc_lapi}['\"]?[[:space:]]*$" "$_cc_f" 2>/dev/null; then
        return 0
    fi
    if [ -f "$_cc_f" ]; then
        _cc_why="daemonize/listen_uri 判据不符"
    else
        _cc_why="被删除"
    fi
    _cc_bak=""
    if [ -f "$_cc_f" ]; then
        rm -f "$_cc_f".user-* 2>/dev/null
        _cc_bak="$_cc_f.user-$(date '+%Y%m%d%H%M%S')"
        cp -f "$_cc_f" "$_cc_bak" 2>/dev/null || _cc_bak=""
    fi
    # 原子替换走同目录 .guard-tmp + rename，理由与主循环容器分支完全一致：
    # 容器随时可能读到半个 config.yaml，而 crowdsec 读不懂 YAML 就直接退出。
    _cc_tmp="$_cc_f.guard-tmp"
    if cp -f "$_cc_src" "$_cc_tmp" 2>/dev/null && chmod 0644 "$_cc_tmp" 2>/dev/null; then
        if ! mv -f "$_cc_tmp" "$_cc_f" 2>/dev/null; then
            cp -f "$_cc_tmp" "$_cc_f" 2>/dev/null
            rm -f "$_cc_tmp" 2>/dev/null
        fi
        if ! cmp -s "$_cc_src" "$_cc_f"; then
            _glog "【配置】/etc/crowdsec/config.yaml 已复原，但回读与基准不一致（疑似 overlay 孤立 inode / 缓存未刷新，多因绕过挂载点直接改 upperdir）—— 需重启或 umount 重挂"
        else
            _glog "【配置】/etc/crowdsec/config.yaml $_cc_why，已从只读基底复原${_cc_bak:+（原内容另存 $_cc_bak）}—— 容器内 crowdsec 进程读的仍是旧配置，重启容器或 crowdsec 后生效"
        fi
    else
        rm -f "$_cc_tmp" 2>/dev/null
        _glog "【配置】/etc/crowdsec/config.yaml 复原失败：只读基底不可读或目标不可写"
    fi
    return 0
}

# 【2026-10-31.0256】cmp 是 busybox 基础 applet，写死不探测（用户 2026-10-31 定）。

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
# 于是这一组从头到尾都在「拿固件版覆盖宿主版」，容器里那批文件一次都没比过。
# 而且 case "$GUARD_CT_PREFIX"/* 永远不匹配，_ct_gate 的两道门形同虚设（算了不用）。
# 真机 2026-10-22 11:02:22 那两条「/etc/passwd、/etc/group 与只读基准不一致，已复原」
# 就是宿主被误伤，不是容器。
# 两个后果都是静默的，所以从 v.108.45 到 v.108.46 一直没被发现：
#   · 容器里的 rcS 被改坏 → 不复原、不报警（用户实测确认）；
#   · 宿主被改 → 复原一次后 cmp 就相等了，从此安静，日志只留一条看不出规模。
# 【v.180.120】目录签名：相对路径 + 校验和，排序拼成一串。
# 只比内容，**不比 mtime** —— 刷机后 /rom 与运行副本的时间戳必然不同，
# 比时间会变成「每轮都判定不一致、每轮重写整目录」，正是 v.108.44 踩过的坑。
# 文件名也进签名：少一个、多一个都算不一致。
#
# 【v.180.192】校验和工具从 cksum 换成 md5sum。原因：25.12 的 busybox 里
# **没有 cksum 这个 applet**（真机实测 `cksum: applet not found`；
# imm25.config 里 CONFIG_PACKAGE_coreutils-cksum 也是 not set）。
# 于是 `cksum <"$f"` 在 25.12 上恒为空，签名只剩路径 —— 文件内容被改
# 完全发现不了，只有增删文件才算「不一致」。注释写着「路径 + 校验和」，
# 实际只做了路径，属于静默失效（v.180.120 起就一直在）。
# md5sum 两版固件都带；万一某个固件连它也没有，退回字节数（比空好）。
_dir_sig() {
    ( cd "$1" 2>/dev/null || exit 1
      find . -type f 2>/dev/null | sort | while read -r _ds_f; do
          printf '%s %s\n' "$_ds_f" "$(_ds_sum "$_ds_f")"
      done ) 2>/dev/null
}

_ds_sum() {
    _ds_p="$1"
    _dsm=$(md5sum <"$_ds_p" 2>/dev/null)
    # 不用 awk 取第一列：guard 里那条「计时不依赖 awk」的约定（busybox 不一定编了）
    # 同样适用于这里，能少一个外部依赖就少一个。
    set -- $_dsm
    _dsm=${1:-}
    [ -n "$_dsm" ] || _dsm="size$(wc -c <"$_ds_p" 2>/dev/null)"
    printf '%s' "$_dsm"
}

# ---- 【v.180.128】本地包源守护：只清死源，不覆盖文件 ----
# customfeeds.conf 刻意不进 GUARD_FILES：那是用户可能合法改动的文件（自己加第三方源），
# 拿 /rom 基准盖回去等于删他的源。这里只做一件不越界的事 —— 把指向已不存在目录的
# pkgcache 行摘掉。死源会让 `opkg update` 整体报错退出，用户装任何包都先撞这个错，
# 而错误信息只说「某个源取不到」，看不出是本机缓存目录没了。
# 【v.180.130】两种包管理器各有一套源文件与索引名，先分流再走同一套逻辑：
#   opkg(24.10)：/etc/opkg/customfeeds.conf 里 "src/gz pkgcache file://..." + Packages.gz
#               （opkg 的 file:// 源只认 .gz：给裸 Packages 一律 update 失败，
#                24.10.6 真机实证 copy_file: .../Packages.gz: No such file or directory）
#   apk (25.12)：/etc/apk/repositories 里一行 "file://..."                  + packages.adb
_pkgcache_feed_audit() {
    # 【v.180.133】优先交给 pkg-cache-fix.sh（它按 源->索引 的顺序修，可单独跑）。
    # 只在 ROOT 为空或 / 时调用：那个脚本写的是绝对路径，若 ROOT 指向某个
    # 待改的 rootfs（离线修镜像），交给它就等于去改宿主机，静默改错地方。
    case "${ROOT:-}" in
    "" | "/")
        if [ -x /usr/sbin/pkg-cache-fix.sh ] \
            && /usr/sbin/pkg-cache-fix.sh >/dev/null 2>&1; then
            return 0
        fi
        ;;
    esac
        _pfa_conf="$ROOT/etc/opkg/customfeeds.conf"
        _pfa_pat='^src/gz[[:space:]]*pkgcache[[:space:]]'
        # 判据必须与 opkg 的真实要求对齐：opkg 只吃 Packages.gz，不认裸 Packages。
        # 用 Packages 当判据的话，guard 会把源指到一个「有索引但 opkg 读不了」的目录，
        # update 照样失败 —— v.180.133 之前的真机故障就是这么来的。
        _pfa_idx=Packages.gz
        _pfa_ro="${PKG_CACHE_RO:-$ROM_DIR/root/pkg-cache}"
        _pfa_ov="${PKG_CACHE:-$ROOT/root/pkg-cache}"
        _pfa_what="pkgcache 源"
        _pfa_fmt='src/gz pkgcache file://%s\n'
        # opkg 侧保持原行为，不跟 apk 一起删。理由三条：
        #   ① opkg 没有签名问题 —— 装包时用 --no-check-signature，本地源照常可用；
        #   ② opkg 没有 apk 的 --repository 参数，源只能写在 conf 里，
        #      删掉就等于断了「源装」这条路，连带依赖也解析不出来；
        #   ③ 24.10 线没有真机可测，动它等于盲改。
        _pfa_write=1
    [ -f "$_pfa_conf" ] || return 0
    # 【v.180.133】原来这里还有一句
    #   grep -qE "$_pfa_pat" "$_pfa_conf" 2>/dev/null || return 0
    # 意思是 conf 里没有 pkgcache 行就直接退出，等于永不补写。而
    # customfeeds.conf 出厂只有三行注释，_pkgcache_feed_ensure 又只在
    # 「要装包」时才被调用 —— 两条路都不写，本地包库在真机上等于不存在，
    # opkg 根本不会去读它。现在不管有没有这一行都往下走：
    # 有就纠正指向（目录变了/被删了），没有就补写。
    _pfa_live=""
    for _pfa_d in "$_pfa_ro" "$_pfa_ov"; do
        [ -n "$_pfa_d" ] || continue
        [ -f "$_pfa_d/$_pfa_idx" ] && { _pfa_live="$_pfa_d"; break; }
    done
    # 可用目录在、且已经挂着它：零动作（刷机后的常态，一分钟一轮也不写 flash）
    # apk 侧必须看到 <目录>/packages.adb：只写目录的旧行在真机上读不到索引，
    # 但字面上包含 "file://<目录>"，不收紧就会被当成「已挂好」而永不纠正。
    # 【v.180.165】整行匹配，_pfa_need 现在是完整源行而不是地址片段。
    # 用子串时，被注释掉的 `# ndx file://...` 照样命中，guard 会认为「已挂好」
    # 而不再校正。整行匹配才能把「被注释 / 源名被改 / 行尾被追加」都判成需修。
    if [ "$_pfa_idx" = "packages.adb" ]; then
        _pfa_need="ndx file://$_pfa_live/packages.adb"
    else
        _pfa_need="src/gz pkgcache file://$_pfa_live"
    fi
    if [ "$_pfa_write" = "0" ]; then
        # apk：这行本就不该在。已经干净就零动作（一分钟一轮，不写 flash）。
        grep -qE "$_pfa_pat" "$_pfa_conf" 2>/dev/null || return 0
    elif [ -n "$_pfa_live" ] && grep -qxF "$_pfa_need" "$_pfa_conf" 2>/dev/null; then
        return 0
    fi
    _pfa_tmp="$_pfa_conf.tmp.$$"
    grep -vE "$_pfa_pat" "$_pfa_conf" > "$_pfa_tmp" 2>/dev/null
    if [ ! -f "$_pfa_tmp" ]; then
        return 0
    fi
    if [ "$_pfa_write" = "1" ] && [ -n "$_pfa_live" ]; then
        # 格式跟着包管理器走：opkg 要带 "src/gz pkgcache" 前缀，apk 只要裸 URL
        printf "$_pfa_fmt" "$_pfa_live" >> "$_pfa_tmp" 2>/dev/null
    fi
    if cat "$_pfa_tmp" > "$_pfa_conf" 2>/dev/null; then
        if [ "$_pfa_write" = "0" ]; then
            _glog "【包源】$(basename "$_pfa_conf") 已摘除本地包源（索引无签名，apk 会跳过它、只换来 UNTRUSTED 警告；恢复改用显式 --repository + --allow-untrusted）"
        elif [ -n "$_pfa_live" ]; then
            _glog "【包源】$(basename "$_pfa_conf") 的 $_pfa_what 已校正为 $_pfa_live"
        else
            _glog "【包源】本地包库已不可用（$_pfa_ro 与 overlay 都没有 $_pfa_idx），已摘除死源 —— 被卸的包只能用 /rom 拷文件兜底"
        fi
    else
        _glog "【包源】$(basename "$_pfa_conf") 校正失败（不可写）"
    fi
    rm -f "$_pfa_tmp"
    return 0
}

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
# 顺序：先修主配置（能不能被路由器连上全看它），再做整层审计 —— 主配置修好之后，
# 审计段看到的 online_client 两行才是「这一轮的真实形态」，不会被误判成不一致。
# ---- 【v.180.120】目录级保护：固件自带自检脚本 ----
# 逐文件那套走完再走这里。顺序无关，但放在后面便于日志连着看。
for _gd in $GUARD_DIRS; do
    # 护栏：只认绝对路径，且不许是根。下面有 rm -rf，路径校验不能省。
    case "$_gd" in
    /*) ;;
    *)
        _glog "【完整性】GUARD_DIRS 里 '$_gd' 不是绝对路径，已跳过（不执行 rm -rf）"
        continue
        ;;
    esac
    [ "$_gd" = "/" ] && continue
    # 只读基座里没有 = 这台固件没带这批脚本，跳过。旧固件永远走这条。
    [ -d "$ROM_DIR$_gd" ] || continue
    _gd_run="$ROOT$_gd"
    # 内容完全一致 → 零动作（刷机后的常态）
    if [ -d "$_gd_run" ] && [ "$(_dir_sig "$ROM_DIR$_gd")" = "$(_dir_sig "$_gd_run")" ]; then
        continue
    fi
    _gd_had=0
    [ -d "$_gd_run" ] && _gd_had=1
    # 留一份跑偏现场再覆盖；只留最近一份，否则每轮一次能堆满 flash
    if [ "$_gd_had" = "1" ]; then
        rm -rf "$_gd_run".user-* 2>/dev/null
        mv -f "$_gd_run" "$_gd_run.user-$(date '+%Y%m%d%H%M%S')" 2>/dev/null
    fi
    if cp -a "$ROM_DIR$_gd" "$_gd_run" 2>/dev/null; then
        _gd_n=$(find "$_gd_run" -type f 2>/dev/null | wc -l)
        if [ "$_gd_had" = "1" ]; then
            _glog "【完整性】$_gd 与只读基座不一致，已整目录复原（$_gd_n 个文件；原内容另存 ${_gd_run}.user-*）"
        else
            _glog "【完整性】$_gd 整个目录不见了，已从只读基座复原（$_gd_n 个文件）"
        fi
        # 复读完回读一次：cp -a 返回成功不等于真的在了（overlay 白out 之类的老问题）
        if [ "$(_dir_sig "$ROM_DIR$_gd")" != "$(_dir_sig "$_gd_run")" ]; then
            _glog "【完整性】$_gd 已执行整目录复原，但回读仍与基准不一致 —— 需人工介入"
        fi
    else
        _glog "【完整性】$_gd 复原失败：只读基座不可读或目标不可写"
    fi
done

[ "$_CT_OK" = "1" ] && _cs_cfg_audit
[ "$_CT_OK" = "1" ] && _ovl_audit

# 包源与容器无关：容器没起来时反而更需要它（靠它把包装回来）
_pkgcache_feed_audit

# LAPI 段自带降频（默认 300s），所以这里无条件调用；容器未就位时函数内部直接返回。
_lapi_audit

# 【v.108.70】最后一步：记本轮耗时（覆盖写 timing 文件；超阈值才额外进日志）。
# 放在 exit 前面而不是每段各自记：要的是「整轮」的数，单段耗时对判断余量没意义。
_gt_report

exit 0
