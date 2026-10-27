#!/bin/sh
# 【v.180.92】固件版本标记 —— 与 crowdsec-lxc-bootstrap.sh 的 SCRIPT_VER 同步，每次改脚本一起改
# crowdsec-lxc-bootstrap（旁路由版）
# 适用拓扑：单臂旁路由——所有物理网口桥进 br-lan，WAN/WAN6 一律禁用，
#   出口走上游网关，本机不拨号、不跑 DHCP 服务（lan.ignore=1）。
# 八组链：PREP → INSTALL → CAPIBLOCK → BOOT → LOGCONF → LAPI → BOUNCERVERIFY → ENROLL，
#   每组执行前校验所有前置组已置位，全通才置位，失败不置位。
#   唯一真实的硬顺序：PREP + INSTALL + CAPIBLOCK → BOOT → (LOGCONF | LAPI) → BOUNCERVERIFY → ENROLL
#   （config.yaml / acquis / resolv.conf / 网络文件都是 crowdsec 与 systemd 启动时读一次，
#     所以「改静态配置」必须排在开机之前；LOGCONF 与 LAPI 之间没有依赖）。
# 【网络侧：验证 + 修改】v.95 起，网络/防火墙节点不再"只验不写"：verify 不符就 build 改回来，
#   然后 uci commit + 按组 reload 让改动真正生效（commit 只落盘，reload 才生效）。
#   不设回滚：改完复核仍不过 → ensure 判 hard，引导终止。
#   分组 reload：network → network reload；dhcp → dnsmasq restart；
#                firewall → firewall reload（fw4 重建整张 nft 表）。
#   脚本会写的东西（按配置面分）：
#     · /etc/config/network   桥端口 / lan 静态地址 / 删 wan+wan6 段 / lxcbr0 段与地址
#     · /etc/config/dhcp      lan.ignore（关 DHCP / RA / authoritative）
#                             + 所有 dnsmasq 段 port=0（DNS 让给 smartdns）+ bind_device=0（全接口监听）
#     · 必备组件            lxc / smartdns：NETBASE 里只配不装；缺的收在末尾 DEPS 节点，
#                             先探网络（网关/公网/DNS），通了才 apk/opkg 安装，装完立刻把
#                             smartdns 配好；不通只记日志，下次引导重试（柔性，不中止）
#     · /etc/config/smartdns  主段 enabled/port=53/cache_size/serve_expired/prefetch_domain；13 个上游
#                             （国内 9 UDP 走 Cn 组、境外 4 DoT 走 Out 组）
#     · /etc/config/firewall  lxc zone + 3 条 forwarding / wan·lan input / SNAT /
#                             docker zone + 3 条 rule（仅装了 dockerd 时）
#     · /proc/sys/net/ipv4/ip_forward  置 1（写完必须回读，读不回来判失败）
#     · /etc/config/dropbear  服务绑定接口（局部 commit + reload）
#     · /etc/config/system    log_ip/log_port（日志推送到容器）
#     · /etc/config/crowdsec  api_url/api_key（bouncer 注册）
#   改网络前有「不自杀」保护（_net_write_guard + SSH 来源判定），但仍需自担风险：
#   把 br-lan 或 lan 地址改错，本会话可能直接失联。
#   WAN 段：必须整段删除（不是 disabled=1）——新 nft 后台不认可 disabled 标志，
#   段只要还在就会按 proto/device 起接口并挂 WAN zone，旁路由就名不副实。
#   你要恢复拨号在 LuCI 新建 WAN 即可，脚本下次引导会再删（旁路由语义闭环）。
# 【退出即恢复】v.98 起，脚本无论怎么退出（正常 return / exit N / Ctrl-C / kill /
#   SSH 断线），都会走同一套恢复逻辑，不留半截置位：
#     ① 进程内变量 GSET_<组> / _done_<节点> / _dirty_<节点> / _failed ← 归零
#     ② 内核态 ip_forward ← 若本轮由脚本从 0 改成 1、且最终没写 installed 标记，
#        则还原为原值（引导成功则保留 1，那是期望稳态）
#     ③ 磁盘标记 reinstall_pending ← 刻意不清（它就是靠"崩溃后残留"计失败次数），
#        只在日志里交代它现在的状态
#   实现要点：EXIT + INT + TERM + HUP 四个 trap 都装；信号处理里必须把 EXIT trap
#   也摘掉，否则 exit 会二次触发 EXIT、恢复逻辑跑两遍（这个坑踩过一次）。
#   顺序：先做重装失败计数、再做恢复——反了的话计数会读到已被清空的状态。

SCRIPT_VER="2026-10-27.180.106"

LXC_NAME="${LXC_NAME:-ubuntu}"
CS_HOME="${CS_HOME:-/etc/crowdsec}"
LXC_PATH="${LXC_PATH:-/srv/lxc}"
ROOTFS="$LXC_PATH/$LXC_NAME/rootfs"
CFG="$LXC_PATH/$LXC_NAME/config"
TARBALL="${TARBALL:-$CS_HOME/lxc-crowdsec.tar.gz}"
LEGACY_TARBALL="/opt/lxc-ubuntu.tar.gz"
# 【v.108.56】容器固定文件常驻 /rom 只读基底，可变部分走 overlay 可写层。
# upper/work 必须在 /overlay（f2fs）：overlay 的 upperdir 不能是另一个 overlayfs，
# 而 /srv 就叠在 rootfs overlay 上（真机实测 rc=32 "not supported as upperdir"）。
ROM_BASE="${CS_ROM_BASE:-/rom/srv/lxc/ubuntu/base}"
OVL_UPPER="${CS_OVL_UPPER:-/overlay/lxc-upper}"
OVL_WORK="${CS_OVL_WORK:-/overlay/lxc-work}"
LAPI_PORT="${LAPI_PORT:-8080}"
BOUNCER_NAME="${BOUNCER_NAME:-openwrt-fw}"
ENROLL_KEY_FILE="${ENROLL_KEY_FILE:-/etc/config/crowdsec_enroll_key.txt}"
# 【v.108.52】注册码「保险柜」：注册成功后不再 rm 掉 key，而是移到同名 .keep（600）。
# 为什么改：v.99 起「注册成功即删」是为了不让明文 key 留在公开固件上，但 key 同时也是
# 设备唯一的自愈凭据 —— 网页端手滑关闭实例后 re_enroll 读不到 key，只能重刷固件。
# 折中：留在 /etc/config（sysupgrade 默认保留 → 升级后自愈能力不丢），但不参与固件分发，
# 且日志里只出现路径不出现内容。
ENROLL_KEY_KEEP="${ENROLL_KEY_KEEP:-${ENROLL_KEY_FILE}.keep}"
# 【v.108.54】「已提交、等网页 Accept」的判定改成「按开机计」。
# 演进过程：
#   v.108.52：未注册就判失败 → 每次复验都重新提交，网页堆 pending；
#   v.108.53：落盘标记 + 永不自动重试 → 网页误点「拒绝」后永久失联，只能 SSH 删文件；
#   v.108.54：**每次开机允许尝试一次**。同一开机内靠进程变量 _ENROLL_TRIED 只提交一次，
#             重启即刷新状态 —— 误点拒绝/误删后重启一次就自动回来，不需要任何手工命令。
# 落盘文件仍保留，但只用于「记录上次提交时间、便于排查」，不再当闸门。
ENROLL_SUBMIT_FILE="${ENROLL_SUBMIT_FILE:-/etc/config/crowdsec_enroll_submitted}"
_ENROLL_TRIED=0
_ENROLL_WAIT_LOGGED=0
MAX_WAIT="${MAX_WAIT:-60}"
SLEEP=5
CROWDSEC_CFG="$ROOTFS/etc/crowdsec/config.yaml"
CSCLI=/usr/bin/cscli
# 【v.108.28】lxc-auto 的服务脚本与配置文件路径。抽成变量不是为了可配，
# 而是为了让「配置空了会不会被补」这件事能被真的跑出来验（指到临时文件）。
LXC_AUTO_INIT="${CS_LXC_AUTO_INIT:-/etc/init.d/lxc-auto}"
LXC_AUTO_CFG="${CS_LXC_AUTO_CFG:-/etc/config/lxc-auto}"
# 只读基准：guard 拿它当"原样"的比对源，这里拿它当"服务脚本被删了去哪捞回来"。
LXC_AUTO_ROM="${CS_LXC_AUTO_ROM:-/rom}"

# ---- 重装自愈（escalation tier 3）持久状态 ----
# 唯一持久位 installed：本流程曾完整跑通（online_client 放出步之后置位；
# enroll 需网站人工 Accept，不算安装成功判据）。_done_* 保持内存语义不变。
# STATE_DIR 落在 rootfs 同级：tier-3 抹 rootfs 不波及；删容器才随之消失。
STATE_DIR="${CS_BOOTSTRAP_STATE:-$LXC_PATH/$LXC_NAME/.bootstrap}"
STAMP_FILE="$STATE_DIR/installed"
REINSTALL_FAIL_FILE="$STATE_DIR/reinstall_fail"
REINSTALL_PENDING_FILE="$STATE_DIR/reinstall_pending"
CRED_BACKUP_DIR="$STATE_DIR/cred-backup"
# 【v.108.51】凭据的「活过刷机」那一份：/srv/lxc 既不 /etc/sysupgrade.conf，也不在
# 任何 /lib/upgrade/keep.d 里 —— 刷机时整个容器连同凭据一起消失（真机核对 2026-10-22：
# sysupgrade.conf 只有 /etc/crowdsec/lxc-crowdsec.tar.gz 与 lxc-ubuntu.tar.gz 两条，
# keep.d 33 项全是包名，没有一个覆盖 /srv）。
# 而 /etc/config 由 base-files-essential 保留，所以持久副本放这里：
# 刷机后 rootfs 重解压、凭据为空时由 _cred_restore 放回去，console 侧实例身份不变，
# 不用重新 register/enroll，也不会在 console 里多出一条 offline 记录。
CRED_KEEP_FILE="${CS_BOOTSTRAP_CRED_KEEP:-/etc/config/crowdsec_credentials_keep.yaml}"
# 【v.108.25】静态配置的 sha 基线：只覆盖脚本自己写的那几份文件（主配置 / 采集源 /
# 两个解析器）。跑完一轮后记下它们长什么样，之后每次 verify 重算比对 ——
# 「文件在、结构对」不等于「内容还是我写的那份」，被人改过一个字符也算不符。
# 不比整目录指纹：目录里多一个用户自己加的解析器，不该被判定为不符。
CFG_SHA_FILE="$STATE_DIR/cfg_sha"
# 【v.108.18】「重启之后才重置，一次」的判据：boot_id 认「本次开机的首跑」。
# 开机首跑允许重置；探针在运行期重跑 bootstrap 时 boot_id 不变、标记已写好 →
# 不是首跑 → 只修不重置（运行期抹 rootfs 会中断正在跑的容器，多半也只需修）。
# 首次安装（从未有 installed 标记）由 _stamp_present 那道门挡住，同样不重置。
BOOT_ID_FILE="$STATE_DIR/boot_id"
# 【v.108.19】重置额度记账：内容 = 上一次「用掉重置权」时的 boot_id。
# 与 boot_id 不同 = 本次开机还没用过额度 → 可以重置一次；相同 = 已用过 → 拒绝。
RESET_BOOT_FILE="$STATE_DIR/reset_boot"
# 【v.108.20】「抹盘后断电」的续做计数：rootfs 已经没了，重建是唯一恢复途径，
# 不能把它当成「又一次失败」拒掉；但真遇到每解压必断电的环境，也要有个上限收口。
INTR_FILE="$STATE_DIR/reinstall_intr"
INTR_MAX="${CS_BOOTSTRAP_INTR_MAX:-3}"
# 【v.108.61】LAPI 自愈第三档（丢可写层）的记账：一行 = <boot_id> <次数> <上次时刻> <诊断签名>
# 三个门缺一不可，理由见 _l3_gate：
#   次数 —— 锚在 boot_id 上，只有「重启设备」才归零；**「恢复」不归零**。
#           若拿「恢复正常」当重置条件，就会变成「坏→丢层→好→再坏→再丢」的周期性抹盘。
#   时间 —— 两次丢层至少隔 6 小时，挡的是「重启循环里每次开机都白得一次机会」。
#   签名 —— 同一个根因上次丢完没好，再丢一次不会有不同结果（v.106 那条原则的延伸）。
L3_STATE="$STATE_DIR/reinstall_l3"
L3_MAX="${CS_BOOTSTRAP_L3_MAX:-1}"
L3_GAP="${CS_BOOTSTRAP_L3_GAP:-21600}"
# 【v.108.21】柔性节点：build 修不回来时只记账、不中止引导。
# 只给「差一点点时机」的节点用，不能拿来掩盖真故障：
#   bouncer_verify 要的是「bouncer 已经成功拉过一次 LAPI」，而首次心跳有 10s 周期延迟，
#   60s 窗口内拉不到就把整轮引导判死、连 installed 都不写 → 探针永远 wait-install。
#   LAPI 是否对外开放已经由 verify_lapi_fetch（宿主侧探测）硬性把关，这里再卡一次
#   只会把「还没到时候」变成「永久停摆」。长期监视本来就是探针的职责。
#   【v.108.49】enroll 加进来：它是「网站侧人工 Accept」这一段外部流程，本地只能
#   把注册码交上去，是否 authenticated 由用户在 console 里点确认决定。注册码错的
#   时候不该让整轮引导死掉、连 installed 都不写（那会让探针每 5 分钟重跑全量）。
SOFT_NODES="${CS_BOOTSTRAP_SOFT_NODES:-bouncer_verify enroll deps}"
# 【v.108.33】本轮 build 过的节点（flush 清脏标记前记一笔），收尾复核要用。
_built_nodes=""
_BS_FIRST_RUN=0
REINSTALL_MAX="${CS_BOOTSTRAP_REINSTALL_MAX:-1}"   # 连续重装失败达到即停机转人工；0=总开关
# 【v.108.17】默认从 2 收到 1：口径是「运行期只重置一次」。重装跑的是同一套脚本、
# 同一份镜像，第二次只是在同样的前提下再失败一遍，还要多抹一次现场。一次不成即停。
# 同一次运行内的「只重置一次」另由 CS_BOOTSTRAP_REINSTALL 那道防递归门保证
# （重装 exec 出来的进程不会再触发重装）。
_CRED_REL="etc/crowdsec/online_api_credentials.yaml"
_bs_stamped=0

# 【v.108.46】IP / 网关固定，唯一来源是容器 rootfs 里的 net.conf —— 构建期由
# rootfs-skel 写进 tarball 和固件两处（同字节），并纳入 crowdsec-guard 保护。
# 不再读 /etc/config/custom_container_ip.txt / custom_bridge_ip.txt：那是 action
# 输入写出来的文件，输入已取消；继续读它等于保留了一份可能过期、且没人再更新的真相。
_net_conf="$ROOTFS/etc/crowdsec-net.conf"
if [ -z "${CONTAINER_IP:-}" ] && [ -f "$_net_conf" ]; then
    CONTAINER_IP="$(sed -n 's/^ADDRESS=\([0-9][0-9.]*\)\/[0-9][0-9]*$/\1/p' "$_net_conf" 2>/dev/null | head -n1)"
fi
CONTAINER_IP="${CONTAINER_IP:-10.1.0.10}"
if [ -z "${BRIDGE_IP:-}" ] && [ -f "$_net_conf" ]; then
    BRIDGE_IP="$(sed -n 's/^GATEWAY=//p' "$_net_conf" 2>/dev/null | head -n1)"
fi
BRIDGE_IP="${BRIDGE_IP:-10.1.0.1}"

log() { echo "[$(date '+%F %T')] $*"; }

# ---- 日志封顶（v.108.59）----
# 三处日志里只有这一个没有上限：rc.local 与探针都用 >> 追加同一份文件，
# 而 /root 在 overlay 上层，写进去都是 flash。阈值取 1MB（约十几轮完整引导），
# 超限保留最后 2000 行 —— 一次完整引导约 600~900 行，留够「上一轮 + 这一轮」
# 好对照，常态占用回落到几十 KB。
# 只在真引导开始时截一次：截得太勤会把「上一轮怎么失败的」抹掉，那正是最该看的。
BOOT_LOG="${CS_BOOTSTRAP_LOG:-/root/crowdsec-lxc-bootstrap.log}"
BOOT_LOG_MAX="${CS_BOOTSTRAP_LOG_MAX:-1048576}"
BOOT_LOG_KEEP="${CS_BOOTSTRAP_LOG_KEEP:-2000}"
_boot_log_trim() {
    [ -f "$BOOT_LOG" ] || return 0
    _bl_sz=$(wc -c <"$BOOT_LOG" 2>/dev/null) || return 0
    [ -n "$_bl_sz" ] || return 0
    [ "$_bl_sz" -gt "$BOOT_LOG_MAX" ] 2>/dev/null || return 0
    tail -n "$BOOT_LOG_KEEP" "$BOOT_LOG" >"$BOOT_LOG.tmp" 2>/dev/null || {
        rm -f "$BOOT_LOG.tmp" 2>/dev/null
        return 0
    }
    mv -f "$BOOT_LOG.tmp" "$BOOT_LOG" 2>/dev/null || return 0
    log "【日志】$BOOT_LOG 超过 ${BOOT_LOG_MAX} 字节，已截断为最后 ${BOOT_LOG_KEEP} 行"
    return 0
}

case "$0" in
    /*) _SELF="$0" ;;
    */*) _SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")" ;;
    *) _SELF="$(command -v "$0" 2>/dev/null)" ;;
esac
[ -n "$_SELF" ] && chmod +x "$_SELF" 2>/dev/null
chmod +x /etc/rc.local 2>/dev/null

# 【v.108.66】外层 attach 超时：平时 10s，容器刚起来那一段单独一个上限。
# 【v.108.70】启动窗口那档 60s→30s、窗口 120s→60s。原来的 60s 是 v.108.52 在
# 「怕首次 attach 等 PID1 就绪被截断」时取的保守值，不是量出来的。现在有实测：
# 本机 attach + cscli 0.07~0.38s，纯 shell 更低；容器刚启动时最慢的是 PID1 就绪和
# cgroup 视图，也在个位数秒内返回。30s 已是实测值的近百倍，60s 只买来「卡住时白等
# 一分钟」，而这一分钟正好把探针 tick 一起堵住。
# 两个数各自管什么：
#   · 容器启动成功后 CT_BOOT_GRACE 秒内（默认 60）→ 用 CT_TIMEOUT_BOOT（30s），
#     覆盖 PID1 就绪、cgroup 视图、首轮网络检查这些必然要等的地方；
#   · 窗口之外（正常引导后半段、探针重跑、人工调用）→ 用 CT_TIMEOUT（10s）。
# 三个数都可用同名环境变量覆盖。真机若出现「首次 attach 被判超时」，先用
# CT_TIMEOUT_BOOT=60 CT_BOOT_GRACE=120 复现原状，再判断是值不够还是别的原因，
# 不要直接把这个数改回去掩盖问题。
# 【v.108.70】内层 cscli 收到 8s（下面各处 `timeout 8 $CSCLI`）。原来外层 10s、
# 内层也是 10s，两边同时到点，外层先杀 lxc-attach，内层的 rc=124 和它已经打出来的
# 输出就全丢了，日志只剩一句「attach 超时」—— 分不清是 cscli 卡住还是 attach 卡住。
# 内层小 2s，让它先退出并把真实原因带回来。
CT_TIMEOUT="${CT_TIMEOUT:-10}"
CT_TIMEOUT_BOOT="${CT_TIMEOUT_BOOT:-30}"
CT_BOOT_GRACE="${CT_BOOT_GRACE:-60}"
_CT_BOOT_UNTIL=0
ct() {
    _ct_to="$CT_TIMEOUT"
    if [ "${_CT_BOOT_UNTIL:-0}" -gt 0 ] && [ "$(date +%s)" -lt "$_CT_BOOT_UNTIL" ]; then
        _ct_to="$CT_TIMEOUT_BOOT"
    fi
    timeout "$_ct_to" lxc-attach -P "$LXC_PATH" -n "$LXC_NAME" -- "$@"
}

# 【v.108.66】宿主侧外部命令统一超时（A 方案：分三档，不搞一刀切）
# 为什么分档：容器内命令都能 10s，因为它们是「读一个结果」；宿主侧有三类本来就是
# 「重活」，10s 一砍就变成假失败，而假失败比不设超时更糟 ——
#   · firewall reload 会重建整张 nft 表，砍在中间留下的是半张表（转发可能直接断）；
#   · network reload 让 netifd 拆了重加 lxcbr0，砍断等于网络停在半路；
#   · tar -tzf / -xzf 是 100MB 级本地 I/O，10s 必然被砍 —— 一旦真走到解压兜底，
#     10s 就等于让这条路永远失败。
# 所以：
#   run      10s  常规外部命令（lxc-* / uci / nft list / ip / mount / umount /
#                 ping / wget / pgrep / log·logd·dropbear reload）
#   run_svc  60s  重建类与启动类（firewall / network / dnsmasq reload|restart、
#                 lxc-auto start、crowdsec-firewall-bouncer 的 init.d 启停）
#   run_tar  不限（TAR_TIMEOUT=0）tar 校验与解压
# 显式豁免：ping 自带 -W、wget 自带 --timeout 的仍套 run（外层只兜 DNS 卡死），
# 两者不冲突 —— 内层先到点，外层 10s 只是最后的网。
RUN_TIMEOUT="${RUN_TIMEOUT:-10}"
SVC_TIMEOUT="${SVC_TIMEOUT:-60}"
TAR_TIMEOUT="${TAR_TIMEOUT:-0}"
run() { timeout "$RUN_TIMEOUT" "$@"; }
run_svc() { timeout "$SVC_TIMEOUT" "$@"; }
run_tar() {
    if [ "${TAR_TIMEOUT:-0}" = "0" ]; then
        "$@"
    else
        timeout "$TAR_TIMEOUT" "$@"
    fi
}
ct_running() { run lxc-ls -P "$LXC_PATH" --running 2>/dev/null | grep -qw "$LXC_NAME"; }
ct_exists() { run lxc-info -P "$LXC_PATH" -n "$LXC_NAME" >/dev/null 2>&1; }
ct_pid() { run lxc-info -P "$LXC_PATH" -n "$LXC_NAME" 2>/dev/null | sed -n 's/^PID:[[:space:]]*//p' | head -n1; }
_pgrep_bouncer() { run pgrep -f "crowdsec-firewall-bouncer" >/dev/null 2>&1; }
_ct_env() { ct sh -c 'export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; '"$1"; }

# ---- 容器 init 类型判别（v.109-min）----
# 本仓库有两种 rootfs 产物，同一份引导脚本必须都能带：
#   · systemd 版（lxc-ubuntu.tar.gz，历史产物）：PID1=systemd，网络走 systemd-networkd，
#     自启走 multi-user.target.wants 软链，cgroup 需要宿主提供 name=systemd 层级；
#   · 极简版（lxc-crowdsec.tar.gz，C 方案）：PID1=busybox init，网络走 /etc/crowdsec-net.conf
#     + /etc/init.d/netconf，自启走 /etc/inittab + /etc/init.d/crowdsec，不需要 cgroup 层级。
# 判据取「inittab 在 + 没有 systemd 二进制」两条同时成立，而不是只看 inittab：
# 只判 inittab 会把「ubuntu rootfs 里恰好有个 inittab」误判成极简版。
# rootfs 可能在脚本启动后才解压出来，所以这里必须是函数、不能是启动期求值。
_is_minimal_init() {
    [ -f "$ROOTFS/etc/inittab" ] || return 1
    [ ! -e "$ROOTFS/lib/systemd/systemd" ] || return 1
    return 0
}

# 容器内 crowdsec 重启：两种 init 统一入口。
# systemd 版原先是 systemctl → service → init.d 三级回落；极简版没有 systemctl/service，
# 直接落到 /etc/init.d/crowdsec。抽成一个函数是为了让 4 个调用点行为一致
# （原先只有 _ensure_lapi_exposed 写了 init.d 回落，enroll 之后的重启在极简版里是空转）。
_ct_restart_crowdsec() {
    _ct_env 'systemctl restart crowdsec' >/dev/null 2>&1 \
        || _ct_env 'service crowdsec restart' >/dev/null 2>&1 \
        || _ct_env '/etc/init.d/crowdsec restart' >/dev/null 2>&1
}

cs_active_on_host() { _pgrep_bouncer; }
nft_table_ready() { run nft list table ip crowdsec >/dev/null 2>&1; }

# 宿主机 bouncer 服务控制（v.99-bp.1）
# OpenWrt/ImmortalWrt 没有 Debian/Ubuntu 的 `service` 包装器，只有 /etc/init.d/<name> <action>。
BOUNCER_INIT="${BOUNCER_INIT:-/etc/init.d/crowdsec-firewall-bouncer}"
bouncer_svc() {
    [ -x "$BOUNCER_INIT" ] || { log "[bouncer] $BOUNCER_INIT 不存在（crowdsec-firewall-bouncer 未进固件）"; return 1; }
    run_svc "$BOUNCER_INIT" "$1" || { log "[bouncer] $BOUNCER_INIT $1 返回非零"; return 1; }
    return 0
}

ct_force_stop() {
    ct_running || return 0
    _r=0
    while [ "$_r" -lt 3 ]; do
        _r=$((_r+1))
        run lxc-stop -P "$LXC_PATH" -n "$LXC_NAME" -k >/dev/null 2>&1
        _i=0
        while ct_running; do
            _i=$((_i+1))
            if [ "$_i" -ge 12 ]; then
                _pid="$(ct_pid)"
                [ -n "$_pid" ] && kill -9 "$_pid" 2>/dev/null
                sleep 1
            fi
            [ "$_i" -ge 24 ] && break
            sleep 2
        done
        ct_running || return 0
        [ "$_r" -ge 3 ] && break
        log "第 $_r 轮强制停止未成功，继续停止（最多 3 轮）"
        sleep 2
    done
    log "容器 3 轮强制停止仍未停止"
    return 1
}

_wait() {
    _wf="$1"; _wn="${2:-$MAX_WAIT}"
    _wi=0
    until "$_wf"; do
        _wi=$((_wi+1))
        [ "$_wi" -ge "$_wn" ] && return 1
        sleep $SLEEP
    done
    return 0
}
_wait_ct_running() { _wait ct_running 12; }

# ---- 原子写（v.79：防半截文件——第一次写入时断电，旧方案会留下内容不齐的正式文件，
# 而 verify 若只验文件名会误判「就绪」，带着坏文件启动必失败）----
atomic_write() {
    _aw_path="$1"; _aw_needle="$2"
    cat > "$_aw_path.tmp" 2>/dev/null || { rm -f "$_aw_path.tmp" 2>/dev/null; return 1; }
    [ -s "$_aw_path.tmp" ] || { rm -f "$_aw_path.tmp" 2>/dev/null; return 1; }
    if [ -n "$_aw_needle" ] && ! grep -q "$_aw_needle" "$_aw_path.tmp" 2>/dev/null; then
        rm -f "$_aw_path.tmp" 2>/dev/null
        return 1
    fi
    mv -f "$_aw_path.tmp" "$_aw_path" 2>/dev/null || { rm -f "$_aw_path.tmp" 2>/dev/null; return 1; }
}

_lxc_net() {
    echo "$CONTAINER_IP" | awk -F. '{print $1"."$2"."$3".0/24"}'
}

_lan_ip() {
    _si=$(run uci -q get network.lan.ipaddr 2>/dev/null)
    [ -n "$_si" ] || { [ -f /etc/config/custom_router_ip.txt ] && _si=$(head -n1 /etc/config/custom_router_ip.txt | tr -d ' \t\r\n'); }
    [ -n "$_si" ] || _si='10.0.0.201'
    echo "$_si"
}

# 读取 custom_*.txt 首行（编译期 Actions 写入 /etc/config，运行时可改文件免重编译）
_read_netconf() {
    [ -f "/etc/config/$1" ] || return 0
    head -n1 "/etc/config/$1" | tr -d ' \t\r\n'
}

# 管理地址期望值唯一推导处（自 99-custom.sh 同源搬迁，v.78-bp 起由 bootstrap 每次开机按需校准）
# 输出一行四值：IP NETMASK GATEWAY DNS；推导规则与原 99-custom.sh 完全一致：
#   默认 10.0.0.201/24 网关 DNS 10.0.0.10；自定义 IP + /24 → 网关 DNS 推导为前三段.1；
#   custom_router_gateway/dns.txt 显式传入时优先级最高
_lan_static_conf() {
    _ls_ip='10.0.0.201'
    _ls_nm="$(_read_netconf custom_router_netmask.txt)"
    [ -n "$_ls_nm" ] || _ls_nm='255.255.255.0'
    _ls_gw='10.0.0.10'
    _ls_dn='10.0.0.10'
    _ls_uip="$(_read_netconf custom_router_ip.txt)"
    if [ -n "$_ls_uip" ]; then
        _ls_ip="$_ls_uip"
        if [ "$_ls_nm" = "255.255.255.0" ]; then
            _ls_gw="$(echo "$_ls_ip" | awk -F. '{print $1"."$2"."$3".1"}')"
            _ls_dn="$_ls_gw"
        fi
    fi
    _ls_ugw="$(_read_netconf custom_router_gateway.txt)"
    if [ -n "$_ls_ugw" ]; then
        _ls_gw="$_ls_ugw"
        [ -n "$(_read_netconf custom_router_dns.txt)" ] || _ls_dn="$_ls_ugw"
    fi
    _ls_udn="$(_read_netconf custom_router_dns.txt)"
    [ -n "$_ls_udn" ] && _ls_dn="$_ls_udn"
    echo "$_ls_ip $_ls_nm $_ls_gw $_ls_dn"
}

# 四值合法性闸门（v.95）：_lan_static_conf 的产出直接喂给 uci，写错就是失联。
# 这里只做「像不像一个能用的地址」的兜底，不做业务校验：
#   · IP / 网关 / DNS 必须是点分四段、每段 0-255
#   · 掩码必须点分四段（常见的 255.255.x.0 系列，也接受非连续掩码，只查格式）
#   · IP 不能是 0.0.0.0 / 255.255.255.255 / .0 网段首地址（不含 .1 之类）
# 任一不过 → 返回 1，由 build_lan_static 判 hard，绝不把坏值写进 uci。
_is_ipv4() {
    printf '%s\n' "$1" | awk -F. '
        NF != 4 { exit 1 }
        { for (i = 1; i <= 4; i++) {
              if ($i !~ /^[0-9]+$/) exit 1
              if ($i + 0 > 255) exit 1
              if (length($i) > 1 && substr($i, 1, 1) == "0") exit 1
          } }
        { exit 0 }'
}
_lan_conf_valid() {
    _lc_ip="$1"; _lc_nm="$2"; _lc_gw="$3"; _lc_dn="$4"
    for _lc_v in "$_lc_ip" "$_lc_nm" "$_lc_gw" "$_lc_dn"; do
        _is_ipv4 "$_lc_v" || return 1
    done
    case "$_lc_ip" in
        0.*|255.255.255.255) return 1 ;;
    esac
    # IP 与网关撞了就没法路由
    [ "$_lc_ip" != "$_lc_gw" ] || return 1
    return 0
}

# 物理网口列表：排除 lo/虚拟/桥接。前缀集合 = 有线（eth*/en*/lan*）+ USB 网卡（usb*）
# + 移动模块数据口（wwan*）；wlan* 不在内——无线走 AP 模式，不是桥的物理口。
# 用于 WAN-input 放行定责：单网口才需放行，多网口必有一个在 LAN，无需放行
_phys_ports() {
    # 这里 ls 是有意的：/sys/class/net 下的名字都是内核起的（eth0/br-lan/…），
    # 不存在空格、换行这类会把 glob 撑坏的情况；换成 glob 反而要处理通配符空匹配。
    # shellcheck disable=SC2010
    ls /sys/class/net/ 2>/dev/null | grep -E '^(eth|en|lan|usb|wwan)' | grep -v -E '(lo|docker|veth|br-|tun|tap)' | sort
}

# 列表归一化：把「多行」或「空格分隔」的列表统一成「排序后的单行」（v.99-bp.1）
# 用途：uci get 一个 list 返回「单行空格分隔」（eth0 eth1），而 _phys_ports 返回「多行」，
# 两者直接比永远不等；归一化后才有可比性。
_norm_list() { ( for _w in $1; do printf '%s\n' "$_w"; done ) | sort | tr '\n' ' ' | sed 's/[[:space:]]*$//'; }

# 按职责(name)定位 firewall zone 的 section 名，不赌 @zone[N] 索引
# （索引会因其他包 insert zone / 定制改序而漂移，name 才是稳定职责标识）
_zone_sec() {
    for _z in $(run uci show firewall 2>/dev/null | grep -E '=zone$' | cut -d. -f2 | cut -d= -f1); do
        [ "$(run uci -q get firewall.$_z.name 2>/dev/null)" = "$1" ] && { echo "$_z"; return 0; }
    done
    return 1
}

# LAN zone 网络接口名唯一出处：按 name 定责取 firewall zone(lan).network 首值
_zone_lan_network() {
    _lz=$(_zone_sec lan) || return 1
    _zn=$(run uci -q get firewall.$_lz.network 2>/dev/null | head -n1)
    [ -n "$_zn" ] || return 1
    echo "$_zn"
}

verify_lxc_zone() {
    # 【v.108.24】按 name 定位段，不赌段名。
    # build_lxc_zone_fwd 用 _zone_sec lxc 找段（LuCI 删了重建会变成 @zone[3]/cfg0xxxx），
    # 而这里原来写死 firewall.lxczone —— 用户在界面上明明配好了 lxc zone，
    # verify 却说没有，于是每次开机都重建一遍。判据必须和 builder 用同一个定位方式。
    _vz=$(_zone_sec lxc) || return 1
    [ "$(run uci -q get "firewall.$_vz.network")" = "lxc" ] || return 1
    [ "$(run uci -q get "firewall.$_vz.input")" = "ACCEPT" ] || return 1
    [ "$(run uci -q get "firewall.$_vz.output")" = "ACCEPT" ] || return 1
    [ "$(run uci -q get "firewall.$_vz.forward")" = "ACCEPT" ] || return 1
}

verify_fwd_rules() {
    # 【v.108.24】不只看 src/dest：build 写的四项（段类型 rule / src / dest / target）
    # 必须全部对上。原来只比 src/dest，于是 target 被清掉、段类型被改坏时判「已就绪」，
    # 规则实际是 reject/不生效 —— 容器能起、拉不到日志，症状极难倒推。
    [ "$(run uci -q get firewall.lxc2lan)" = "rule" ] || return 1
    [ "$(run uci -q get firewall.lxc2lan.src)" = "lxc" ] || return 1
    [ "$(run uci -q get firewall.lxc2lan.dest)" = "lan" ] || return 1
    [ "$(run uci -q get firewall.lxc2lan.target)" = "ACCEPT" ] || return 1
    [ "$(run uci -q get firewall.lxc2lan.proto)" = "all" ] || return 1
    [ "$(run uci -q get firewall.lxc2docker)" = "rule" ] || return 1
    [ "$(run uci -q get firewall.lxc2docker.src)" = "lxc" ] || return 1
    [ "$(run uci -q get firewall.lxc2docker.dest)" = "docker" ] || return 1
    [ "$(run uci -q get firewall.lxc2docker.target)" = "ACCEPT" ] || return 1
    [ "$(run uci -q get firewall.lxc2docker.proto)" = "all" ] || return 1
    [ "$(run uci -q get firewall.lxc2vpn)" = "rule" ] || return 1
    [ "$(run uci -q get firewall.lxc2vpn.src)" = "lxc" ] || return 1
    [ "$(run uci -q get firewall.lxc2vpn.dest)" = "vpn" ] || return 1
    [ "$(run uci -q get firewall.lxc2vpn.target)" = "ACCEPT" ] || return 1
    [ "$(run uci -q get firewall.lxc2vpn.proto)" = "all" ] || return 1
    [ "$(run uci -q get firewall.lan2lxc)" = "rule" ] || return 1
    [ "$(run uci -q get firewall.lan2lxc.src)" = "lan" ] || return 1
    [ "$(run uci -q get firewall.lan2lxc.dest)" = "lxc" ] || return 1
    [ "$(run uci -q get firewall.lan2lxc.target)" = "ACCEPT" ] || return 1
    [ "$(run uci -q get firewall.lan2lxc.proto)" = "all" ] || return 1
}

# SNAT 段定位：按 name="lxc-snat" 找 nat 段，不赌段名。
# LuCI 删了重建会把段名变成 @nat[0] / cfg0a1b2c 之类，写死 lxcsnat 会在
# 「用户在界面上明明配了」的情况下误判缺失，然后每小时开机都报一遍待办。
_snat_sec() {
    for _s in $(run uci show firewall 2>/dev/null | grep -E '=nat$' | cut -d. -f2 | cut -d= -f1); do
        [ "$(run uci -q get "firewall.$_s.name" 2>/dev/null)" = "lxc-snat" ] \
            && { printf '%s\n' "$_s"; return 0; }
    done
    return 1
}

verify_snat_rule() {
    _sn=$(_snat_sec) || return 1
    [ "$(run uci -q get "firewall.$_sn.target" 2>/dev/null)" = "SNAT" ] || return 1
    [ "$(run uci -q get "firewall.$_sn.proto"  2>/dev/null)" = "all" ] || return 1
    [ "$(run uci -q get "firewall.$_sn.src"    2>/dev/null)" = "lan" ] || return 1
    [ "$(run uci -q get "firewall.$_sn.src_ip" 2>/dev/null)" = "$(_lxc_net)" ] || return 1
    [ "$(run uci -q get "firewall.$_sn.snat_ip" 2>/dev/null)" = "$(_lan_ip)" ] || return 1
    return 0
}

verify_ip_forward() {
    [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = "1" ] || return 1
}

# 容器 veth 掉线重接（首台真机 2026-10-22 现场新增）
#
# 现象：lxcbr0 有 IP 但 <NO-CARRIER>，容器 eth0 有 IP 且 LAPI 在 :::8080 LISTEN，
#       宿主 ping 容器 100% 丢包。两边都"正常"，中间那根线不在。
# 成因：/etc/init.d/network reload 让 netifd 按 uci 重建 lxcbr0（拆了重加），
#       而容器已经在跑 —— LXC 只在 lxc-start 时插 veth，之后没人负责接回端口。
# 判据：宿主侧 veth 的 iflink == 容器 eth0 的 ifindex（veth 对端的编号关系）。
# 兜底：找不到对端就什么都不做，绝不 ip link del 网桥（那会把容器网彻底打死）。
_reattach_ct_veth() {
    run ip link show lxcbr0 >/dev/null 2>&1 || return 1
    # 已经有端口挂着了：说明没掉，什么都不用做
    ip -d link show master lxcbr0 2>/dev/null | grep -q 'veth' && return 0
    ct_running || return 0
    _rv_idx=$(ct sh -c 'cat /sys/class/net/eth0/ifindex' 2>/dev/null | tr -dc '0-9')
    [ -n "$_rv_idx" ] || { log "[网桥] 容器 eth0 ifindex 取不到，放弃重接（veth 对端无法确认）"; return 1; }
    for _rv_v in /sys/class/net/veth*; do
        [ -e "$_rv_v" ] || continue
        [ "$(cat "$_rv_v/iflink" 2>/dev/null)" = "$_rv_idx" ] || continue
        _rv_n=$(basename "$_rv_v")
        run ip link set "$_rv_n" master lxcbr0 2>/dev/null || continue
        run ip link set "$_rv_n" up 2>/dev/null || true
        run ip link set lxcbr0 up 2>/dev/null || true
        log "[网桥] 容器 veth 掉线，已重接回 lxcbr0（宿主 $_rv_n ↔ 容器 eth0 if${_rv_idx}）"
        # 立刻用 ping 证明修好了；修不好也要说出来，不能假绿
        _rv_i=0
        while [ "$_rv_i" -lt 10 ]; do
            run ping -c 1 -W 1 "$CONTAINER_IP" >/dev/null 2>&1 && { log "[网桥] 重接后 ping $CONTAINER_IP 已通"; return 0; }
            _rv_i=$((_rv_i+1)); sleep 1
        done
        log "[网桥] 重接后仍 ping 不通 $CONTAINER_IP（可能还有防火墙/路由问题，不在此函数职责内）"
        return 1
    done
    log "[网桥] 未找到与容器 eth0 if${_rv_idx} 配对的宿主 veth（容器网络需重启容器恢复）"
    return 1
}

verify_bridge() {
    # 【v.108.24】uci 侧三项（proto/device/ipaddr）与内核侧地址一起比。
    # build 写的是 network.lxc = interface / proto=static / device=lxcbr0 /
    # ipaddr=BRIDGE_IP / netmask，原来只比 proto + 内核 IP：
    # device 被改成 eth0、ipaddr 被改成别的，只要内核地址还在就判「已就绪」，
    # 重启后 netifd 按 uci 重新拉起，lxcbr0 就没了。
    [ "$(run uci -q get network.lxc)" = "interface" ] || return 1
    [ "$(run uci -q get network.lxc.proto 2>/dev/null)" = "static" ] || return 1
    [ "$(run uci -q get network.lxc.device 2>/dev/null)" = "lxcbr0" ] || return 1
    [ "$(run uci -q get network.lxc.ipaddr 2>/dev/null)" = "$BRIDGE_IP" ] || return 1
    # 【v.108.37】netmask 也要验：build 写了它，verify 原来不看，
    # 掩码被改成 /16 之类时接口照起、地址照在，但整个 10.1.0.0/16 都会被算进直连，
    # 容器和 LAN 网段的转发判定跟着变 —— 属于「写了没验」的漏项。
    [ "$(run uci -q get network.lxc.netmask 2>/dev/null)" = "255.255.255.0" ] || return 1
    # 【v.108.34】设备必须自己声明过：没有 config device 时 netifd 把 lxcbr0 当外部设备，
    # 「有就拿来用、没有也不建」。于是重启后网桥不存在，全靠脚本开机时 ip link add 兜着；
    # 脚本在 bridge 之前任何一步失败，网桥就没了 —— 这正是「ip link show 里没有 lxcbr0」。
    [ "$(run uci -q get network.lxcbr0)" = "device" ] || return 1
    [ "$(run uci -q get network.lxcbr0.type 2>/dev/null)" = "bridge" ] || return 1
    [ "$(run uci -q get network.lxcbr0.name 2>/dev/null)" = "lxcbr0" ] || return 1
    # 空网桥没有 bridge_empty='1' 时 netifd 直接不建（端口要等容器 veth 接进来）
    [ "$(run uci -q get network.lxcbr0.bridge_empty 2>/dev/null)" = "1" ] || return 1
    # 【首台真机 2026-10-22】端口在位才算就绪。
    #   netifd reload 会把 lxcbr0 拆了重建，端口跟着掉光变成 NO-CARRIER，
    #   而上面这些判据（device/proto/ipaddr/netmask/bridge_empty/地址）**全都还成立** ——
    #   这正是「两边各自都正常、中间断链」能藏住的根本原因：判据里没有一条问「桥里有谁」。
    #   容器在跑就必须有 veth 挂在桥上；容器没跑时不要求（空桥是常态，bridge_empty=1 就是为此）。
    if ct_running; then
        ip -d link show master lxcbr0 2>/dev/null | grep -q 'veth' || return 1
    fi
    run ip link show lxcbr0 >/dev/null 2>&1 || return 1
    _vb=$(ip -4 addr show lxcbr0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -n1)
    [ -n "$_vb" ] && [ "$_vb" = "$BRIDGE_IP" ]
}

# LAN zone 放行独立验证（定责 name=lan）：input/forward 必须 ACCEPT
verify_lan_input() {
    _lz=$(_zone_sec lan) || { log "[FW] 未找到 lan zone，本轮不校验 input/forward"; return 0; }
    [ "$(run uci -q get firewall.$_lz.input 2>/dev/null)" = "ACCEPT" ] || return 1
    [ "$(run uci -q get firewall.$_lz.forward 2>/dev/null)" = "ACCEPT" ] || return 1
    return 0
}

# ---- 旁路由网络基线（v.78-bp 起自 99-custom.sh 同源搬迁，每次开机按需校准）----

# 桥接口验证：br-lan bridge 设备 + ports 与 /sys 实际枚举物理口集合一致 + 无残留 cfg030f15
# 枚举为空（开机早期网口驱动未就绪）→ 跳过不误建空桥（防外网断）
verify_br_lan_ports() {
    _vp=$(_phys_ports)
    # 枚举不到物理网口 → return 1（不通过），不是 return 0。
    # 原来这里 return 0：verify 判「通过」后 ensure 根本不会去 build，于是 br-lan 桥
    # 从没被建过，却一路标记完成、组置位、--net-only 分支 exit 0 —— 网络没配好却
    # 报成功，日志干干净净。build_br_lan_ports 那边同条件是 return 1
    # （「未枚举到物理网口（驱动未就绪？），不敢建空桥」），两处必须一致：
    # 「无法确认」就是「不通过」，交给 build 响亮地失败，别在这里假装验过了。
    [ -n "$_vp" ] || return 1
    # 段类型必须是 device：`config br_lan 'br_lan'` 这种非 device 段 netifd 不认，
    # 只查 .type='bridge' 会漏过去（运行时桥还在，重启才丢）。
    [ "$(run uci -q get network.br_lan 2>/dev/null)" = "device" ] || return 1
    [ "$(run uci -q get network.br_lan.type 2>/dev/null)" = "bridge" ] || return 1
    [ "$(run uci -q get network.br_lan.name 2>/dev/null)" = "br-lan" ] || return 1
    [ "$(run uci -q get network.lan.device 2>/dev/null)" = "br-lan" ] || return 1
    for _ds in $(run uci show network 2>/dev/null | grep -E '=device$' | cut -d. -f2 | cut -d= -f1); do
        [ "$_ds" = "br_lan" ] && continue
        if [ "$(run uci -q get "network.$_ds.name" 2>/dev/null)" = "br-lan" ]; then
            return 1
        fi
    done
    # v.99-bp.1 修正：原来两侧各自 `sort` 后直接比字符串，但
    #   左边 _phys_ports 是「多行」（eth0\neth1\neth2）
    #   右边 uci get 的 list 是「单行空格分隔」（eth0 eth1 eth2）
    # 一个多行、一个单行，sort 改变不了行数，**永不相等**。真机上表现为多网口设备
    # 每次开机都判「不符」→ 重建 br-lan + commit + network reload，开机瞬间 LAN 闪断；
    # 单网口时两边恰好都是单行，所以问题被掩盖。
    # 单测里没暴露，是因为 mock 的 uci 把 list 存成多条记录、get 时按行输出（多行），
    # 与 _phys_ports 同格式 —— 与真机 uci 行为不一致。归一化后两种格式都能正确比对。
    [ "$(_norm_list "$_vp")" = "$(_norm_list "$(run uci -q get network.br_lan.ports 2>/dev/null)")" ]
}

# LAN 静态地址验证：proto/device/ipaddr/netmask/gateway/dns 与 _lan_static_conf 推导值一致
verify_lan_static() {
    # 这里就是要让它按空白拆开、按位置取 $1..$4；加引号反而会变成一个整体。
    # shellcheck disable=SC2046
    set -- $(_lan_static_conf)
    [ "$(run uci -q get network.lan.proto 2>/dev/null)" = "static" ] || return 1
    [ "$(run uci -q get network.lan.device 2>/dev/null)" = "br-lan" ] || return 1
    [ "$(run uci -q get network.lan.ipaddr 2>/dev/null)" = "$1" ] || return 1
    [ "$(run uci -q get network.lan.netmask 2>/dev/null)" = "$2" ] || return 1
    [ "$(run uci -q get network.lan.gateway 2>/dev/null)" = "$3" ] || return 1
    [ "$(run uci -q get network.lan.dns 2>/dev/null)" = "$4" ] || return 1
    return 0
}

# DHCP 让权验证：lan ignore=1（旁路由不提供 DHCP，上游光猫发）+ IPv6 RA 项清净 + 无权威 DNS
# DHCP 让权验证：只认「不对外发地址」这个实质结果。
verify_dhcp_ignore() {
    # 【v.180.94】dhcp.lan 段不存在 = LAN 上根本没有 DHCP 池，本身即「已关闭」。
    # 这里若判未就绪，build 会把段建回来（旧行为），等于替用户重开 DHCP。
    _vdi_has=0
    if run uci show dhcp 2>/dev/null | grep -q '^dhcp\.lan=dhcp$'; then
        _vdi_has=1
    fi
    [ "$_vdi_has" = "1" ] || return 0
    [ "$(run uci -q get dhcp.lan.ignore 2>/dev/null)" = "1" ] || return 1
    # 【v.108.24】删除项也要验。build 除了置 ignore=1，还删了 ra/dhcpv6/ndp/
    # ra_management 以及所有 dnsmasq 段的 authoritative。原来只验 ignore，
    # 于是「ignore 对、但 ra 又被 LuCI 打开」这种半吊子状态会被判成已就绪 ——
    # 旁路由一边说不发地址、一边还在发 RA，主机拿到 IPv6 却上不了网。
    for _k in ra dhcpv6 ndp ra_management; do
        [ -z "$(run uci -q get "dhcp.lan.$_k" 2>/dev/null)" ] || return 1
    done
    for _dm in $(run uci show dhcp 2>/dev/null | grep -E '=dnsmasq$' | cut -d. -f2 | cut -d= -f1); do
        [ -z "$(run uci -q get "dhcp.$_dm.authoritative" 2>/dev/null)" ] || return 1
    done
    return 0
}

# ---- smartdns 接管 DNS（DNS 从 dnsmasq 手里拿过来）----
# 目标：smartdns 直接监听 53 当权威解析，dnsmasq 只留 DHCP/RA，不再做 DNS。
# v.180.85 起本节点只做「已装才配置」：smartdns 不在位就直接放行，装入与补配统一交给
# 末尾的 DEPS 节点（网络没通时在这里硬装只会失败并把整轮引导带走）。
# 上游：国内 9 个 UDP（近、快；阿里/腾讯/百度/360/CNNIC），境外 4 个 DoT（带 SNI，防污染）。
# 关于 server_group：smartdns 的 server 默认「既进默认组、又进指定组」，只有显式
# 加 -exclude-default-group 才会被踢出默认组。所以这里写 Cn/Out 分组不会造成
# 「分组没人引用 → 上游全不参与解析 → 整机没 DNS」这种坑，两组都会正常出结果。
SD_DNS_IP_CN="223.5.5.5 223.6.6.6 119.29.29.29 180.76.76.76 101.226.4.6 218.30.118.6 123.125.81.6 140.207.198.6 1.2.4.8"
SD_DNS_IP_OUT="8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1"
SD_DNS_IPS="$SD_DNS_IP_CN $SD_DNS_IP_OUT"

# ---- 必备组件（v.180.85）：lxc / smartdns ----
# 演进：v.180.84 把三者（lxc/smartdns/dockerd）塞进 NETBASE 里「缺就装、装不上判 hard」。
# 真机上这是错的 —— 装机那一刻网络常常还没通（上游没起、拨号没完成），在这个位置 apk/opkg
# 必然失败，一失败就 hard 终止，后面的容器流程一步都跑不到，连「等网络好了再装」都没机会。
# 【v.180.99】脚本不再联网装包：
#   · lxc / smartdns 由固件内置（构建期 PACKAGES 装进 /rom），装包这件事整个交给构建期；
#   · pkg_base 退化为「必备组件在位验证」；
#   · NETBASE.smartdns 照旧：已装就配对配置，缺包就放行（此时 pkg_base 已拦在前）。
# docker 不再必选：路由上跑不跑 docker 是用户的选择，缺 dockerd 时 docker_fw 自己豁免。
# 【v.180.103】整条链按五阶段归位（用户口径）：
#   Ⅰ 配置网桥 / 网络接口 / 防火墙   —— NETBASE 前置 10 节点（br_lan_ports…docker_fw）
#   Ⅱ 查 lxc + smartdns，缺则从 /rom 装回 —— pkg_base（+ lxc_auto 紧随其后）
#   Ⅲ smartdns 配置                   —— NETBASE.smartdns
#   Ⅳ crowdsec 配置与安装             —— INSTALL / PREP / CAPIBLOCK / BOOT / LOGCONF / LAPI / BOUNCERVERIFY
#   Ⅴ 网络连通检测（到达 crowdsec）+ enroll —— DEPS / SMARTCHK / ENROLL
#   联网只出现在 Ⅴ：Ⅴ 之前一律离线，包只在 /rom 与运行时文件系统之间搬。
# 【v.180.102】pkg_base 的闸门从「只看 lxc」扩到「lxc 五件套 + smartdns」：
#   · 两者都是固件该内置的东西，缺了都属于装机不合规，Ⅱ 阶段一次性说清；
#   · 判据仍是「命令/文件真能用」而不是包名：lxc 看五件套，smartdns 看二进制 + init；
#   · 缺任何一个都先走 /rom 文件级自愈（lxc→_rom_restore_lxc，smartdns→_rom_restore_smartdns）；
#   · 自愈后仍缺才 hard exit 1。
_SD_MISSING=""
_PKG_MISSING=""

# ---- 只读基座（/rom）文件级自愈（v.180.101）----
# 前提：固件把 lxc / smartdns 编进 PACKAGES，于是 /rom 里有二进制，
#       还留着 /rom/usr/lib/opkg/info/*.list / *.control 这套元数据。
# 语义：opkg remove 并不会删掉 /rom 里的原件，只在 overlay 层写一个 whiteout 把上层遮住。
#       所以「恢复」= 按清单把 /rom 的原件拷回运行时路径，不联网、不装包。
# 边界：不修 opkg 数据库（opkg list-installed 依旧看不到它），也不覆盖 conffiles
#       （/etc/config/* 这类用户配置一律跳过，配置由 build_smartdns 按 uci 重写）。
ROMDIR="${ROMDIR:-/rom}"
# PKGROOT 只给夹具用：生产环境为空串，写的仍是真实路径 /usr/...
PKGROOT="${PKGROOT:-}"

# 恢复单个包：只补「运行时不存在、只读基座存在」的文件，其余一概不动
_rom_restore_pkg() {
    _rrp_base="$ROMDIR/usr/lib/opkg/info"
    [ -f "$_rrp_base/$1.list" ] || return 1
    _rrp_n=0
    while IFS= read -r _rrp_f; do
        case "$_rrp_f" in
            /etc/config/*) continue ;;
            /?*) ;;
            *) continue ;;
        esac
        # conffiles 不动：那是用户的 /etc/config，恢复出厂值等于删他的配置
        if [ -f "$_rrp_base/$1.conffiles" ] \
           && grep -qxF "$_rrp_f" "$_rrp_base/$1.conffiles" 2>/dev/null; then
            continue
        fi
        [ -e "$PKGROOT$_rrp_f" ] && continue
        [ -e "$ROMDIR$_rrp_f" ] || continue
        mkdir -p "$PKGROOT${_rrp_f%/*}" 2>/dev/null
        cp -a "$ROMDIR$_rrp_f" "$PKGROOT$_rrp_f" 2>/dev/null && _rrp_n=$((_rrp_n + 1))
    done < "$_rrp_base/$1.list"
    [ "$_rrp_n" -gt 0 ] && log "[PKG] 从只读基座恢复 $1：$_rrp_n 个文件"
    return 0
}

# 连依赖一起恢复（最多三层，防止环）。
# libc / libpthread / busybox / kernel / kmod-* 一律跳过：动它们不是「恢复」是「砸系统」。
_rom_restore_tree() {
    _rrt_d="${2:-0}"
    [ "$_rrt_d" -le 2 ] || return 0
    _rom_restore_pkg "$1"
    _rrt_ctl="$ROMDIR/usr/lib/opkg/info/$1.control"
    [ -f "$_rrt_ctl" ] || return 0
    for _rrt_x in $(sed -n 's/^Depends:[[:space:]]*//p' "$_rrt_ctl" 2>/dev/null | head -n1 | tr ',' ' '); do
        case "$_rrt_x" in
            libc|libpthread|libgcc*|librt|libm|kernel|kmod-*|busybox*) continue ;;
        esac
        [ -f "$ROMDIR/usr/lib/opkg/info/$_rrt_x.list" ] || continue
        _rom_restore_tree "$_rrt_x" $((_rrt_d + 1))
    done
    return 0
}

# lxc 全家桶：/rom 里装了哪些 lxc-* 就恢复哪些（applet 是独立包，不会互相拉）
_rom_restore_lxc() {
    _rl_any=0
    for _rl_l in "$ROMDIR"/usr/lib/opkg/info/lxc-*.list; do
        [ -f "$_rl_l" ] || continue
        _rl_p="${_rl_l##*/}"
        _rom_restore_pkg "${_rl_p%.list}"
        _rl_any=1
    done
    [ "$_rl_any" = 1 ] || return 1
    _rom_restore_tree liblxc
    return 0
}

# smartdns：单包 + 两个依赖（libpthread→libc / libopenssl3），走通用递归即可。
# 与 lxc 的区别：没有「一堆 applet 各占一个包」的问题，所以不需要按通配符扫清单；
# 反过来要显式判 .list 在不在 —— 不在说明这台机器的固件压根没编 smartdns，
# 这种情况恢复不了，直接返回 1 让 pkg_base 把话说清楚。
# /etc/config/smartdns 由 _rom_restore_pkg 统一跳过，配置交给 build_smartdns 按 uci 重写。
_rom_restore_smartdns() {
    [ -f "$ROMDIR/usr/lib/opkg/info/smartdns.list" ] || return 1
    _rom_restore_tree smartdns
    return 0
}

# smartdns 是否真在位：二进制 + init 脚本缺一不可（少了 init 就没法启停，等于没装）
# 【v.180.105】同 lxc 一样加冒烟：opkg remove libopenssl3 之后两个 -x 判断依然为真，
# 只有真跑才看得见动态库缺口。取向也一致 —— 只有明确的加载错误才判「不在位」；
# 参数不被认、输出为空等一律当作在位，绝不因为冒烟把整轮引导拖下水。
_smartdns_installed() {
    [ -x /usr/sbin/smartdns ] && [ -x /etc/init.d/smartdns ] || return 1
    case "$(/usr/sbin/smartdns -v 2>&1)" in
        *"Error loading"*|*"No such file"*|*"not found"*|*"cannot open shared object"*)
            return 1 ;;
    esac
    return 0
}

# 必备组件缺哪些（lxc 五件套）：全在返回 0；否则返回 1，缺失清单留在 _SD_MISSING。
# 只读不写 —— verify / build 两侧都用它。
# 五个命令逐一查：lxc-ls / lxc-info / lxc-attach 都是独立 applet 包（各自一个 ipk/apk），
# 没有任何反向依赖会把它们拉进来；只查 lxc-start 会得出「装好了」的假阳性 —— v.180.99 修正。
# 【v.180.100】smartdns 不在这里判：它由 _pkg_missing_all 合并，本函数只守 lxc 五件套。
# 【v.180.105】「在」≠「能用」：opkg remove liblxc 之后五个二进制全都还在，
# command -v 照过，可动态链接已经断了 —— 一直要到 ct_boot 真跑 lxc-start 才报
# 「Error loading shared library liblxc.so.1」，那时离根因已经很远。
# 所以五件套齐全后再跑一次 lxc-start --version 冒烟（一次进程，约 10ms）。
# 判据取向：只有明确看到动态库加载错误才判缺。反过来的「误判成缺」会让 pkg_base
# 硬失败、把整轮引导带走，代价远大于漏报，所以其余任何异常输出一律放过。
_sd_missing_deps() {
    _SD_MISSING=""
    for _md_c in lxc-start lxc-stop lxc-ls lxc-info lxc-attach; do
        command -v "$_md_c" >/dev/null 2>&1 || _SD_MISSING="$_SD_MISSING $_md_c"
    done
    # 文件齐了才冒烟：缺文件时上面已经判过，不必再花一次进程
    if [ -z "$_SD_MISSING" ]; then
        case "$(lxc-start --version 2>&1)" in
            *"Error loading"*|*"No such file"*|*"not found"*|*"cannot open shared object"*)
                _SD_MISSING=" lxc(动态库)" ;;
        esac
    fi
    [ -z "$_SD_MISSING" ]
}

# 必备组件总闸门（v.180.102）：lxc 五件套 + smartdns，全齐返回 0；否则返回 1，
# 合并清单留在 _PKG_MISSING（如 "lxc-ls smartdns"）。只读不写，verify / build 共用。
# 为什么合成一个函数而不是在两个地方各判一次：
#   pkg_base 是 Ⅱ 阶段的唯一判据，它要回答的是「这台机器的固件到底合不合规」——
#   只答一半会让「lxc 齐了但 smartdns 没了」的机器一路跑到 smartdns 节点才炸，
#   那一节点已经是 Ⅲ（配置），届时缺的是二进制而不是配置，报错会指向错误的方向。
_pkg_missing_all() {
    _PKG_MISSING=""
    _sd_missing_deps || _PKG_MISSING="$_SD_MISSING"
    # 判据复用 _smartdns_installed（二进制 + init 两个都要可执行），不另立一套口径
    if ! _smartdns_installed; then
        _PKG_MISSING="${_PKG_MISSING:+$_PKG_MISSING }smartdns"
    fi
    [ -z "$_PKG_MISSING" ]
}

# smartdns 主配置段（config smartdns）的段名；没有则回空
_sd_main_seg() {
    run uci -q show smartdns 2>/dev/null \
        | sed -n 's/^smartdns\.\([^.=]*\)=smartdns$/\1/p' | head -n1
}

# 让 dnsmasq 只做 DHCP、不做 DNS：所有 dnsmasq 段写 port=0（OpenWrt 官方「禁用 DNS」写法）。
# 幂等：已经是 0 也照写一遍，uci 不产生实际改动，可反复调用。
# 两个调用点：① DHCP 让权节点（smartdns 已就绪时顺手让位）② smartdns 配好之后（装完即配）。
# 段名不写死：@dnsmasq[0] 的内部名（cfg01411c 之类）重建配置就会变，一律遍历。
_dnsmasq_release_53() {
    _dr5_n=0
    for _dr5_dm in $(run uci show dhcp 2>/dev/null | grep -E '=dnsmasq$' | cut -d. -f2 | cut -d= -f1); do
        run uci -q set "dhcp.$_dr5_dm.port=0" || return 1
        _dr5_n=$((_dr5_n+1))
    done
    [ "$_dr5_n" -gt 0 ] || log "[DNS] 没有 dnsmasq 段，53 无需让出"
    return 0
}

# smartdns 校验入口：主段（verify_smartdns_main）+ 上游表（verify_smartdns_upstream）+ dnsmasq 已让出 53
# smartdns 校验拆成两件事：① 「服务本身」（主段 + dnsmasq 让出 53）② 「上游服务器表」。
# 为什么要拆（v.180.92）：混在一个函数里时上游只比了 ip 和条数，type / server_group /
# host_name 被改坏也不会重建 —— DoT 掉成明文、Cn/Out 分组失效、SNI 丢失，全是「照样能解析」
# 的静默退化，日志里看不出来。
verify_smartdns_main() {
    _vsm_seg=$(_sd_main_seg)
    [ -n "$_vsm_seg" ] || return 1
    [ "$(run uci -q get "smartdns.$_vsm_seg.enabled" 2>/dev/null)" = "1" ] || return 1
    [ "$(run uci -q get "smartdns.$_vsm_seg.port" 2>/dev/null)" = "53" ] || return 1
    [ "$(run uci -q get "smartdns.$_vsm_seg.cache_size" 2>/dev/null)" = "32768" ] || return 1
    # serve_expired / prefetch_domain：过期照回 + 后台预取，build 里写死为 1，这里必须校验，
    # 否则设备上若是 0，verify 直接判就绪、不进 build，开关永远纠正不过来。
    [ "$(run uci -q get "smartdns.$_vsm_seg.serve_expired" 2>/dev/null)" = "1" ] || return 1
    [ "$(run uci -q get "smartdns.$_vsm_seg.prefetch_domain" 2>/dev/null)" = "1" ] || return 1
    # bind_device 只认「空」或「0」：空 = init 的默认 0，等价全接口；写成 1 时 init 会生成
    # `bind [::]:53@br-lan` + `@lo`（SO_BINDTODEVICE 只收这两张网卡），容器拿 lxcbr0 的地址
    # 来查就被丢掉 —— 端口看着是 53，实际一半来源不可达。
    _vsm_bd=$(run uci -q get "smartdns.$_vsm_seg.bind_device" 2>/dev/null)
    case "$_vsm_bd" in
        ""|0) ;;
        *) log "[SMARTDNS] bind_device=$_vsm_bd：监听被绑到具体网卡，容器/其他网段收不到"
           return 1 ;;
    esac
    return 0
}

# 上游表核对：这 13 条必须**都在，且逐项吻合**（ip / type / server_group / host_name / enabled）。
# 只判「缺」和「错」，不判「多」—— 自己额外加的上游允许留着，不会被当成异常。
# 缺一条或任一项不符 → 判「未就绪」→ build_smartdns_upstream 按表补齐/纠正（不动你加的那些）。
verify_smartdns_upstream() {
    _vsu_cnt=0
    _vsu_dump="|"
    # 先把现场所有 server 段打折成 "ip;type;组;host_name;enabled|" 串，后面纯字符串比对，
    # 不再逐条 fork uci（13 段 × 5 字段只取一轮）。
    for _vsu_s in $(run uci -q show smartdns 2>/dev/null | grep -E '=server$' | cut -d. -f2 | cut -d= -f1); do
        _vsu_cnt=$((_vsu_cnt+1))
        _vsu_dump="$_vsu_dump$(run uci -q get "smartdns.$_vsu_s.ip" 2>/dev/null);$(run uci -q get "smartdns.$_vsu_s.type" 2>/dev/null);$(run uci -q get "smartdns.$_vsu_s.server_group" 2>/dev/null);$(run uci -q get "smartdns.$_vsu_s.host_name" 2>/dev/null);$(run uci -q get "smartdns.$_vsu_s.enabled" 2>/dev/null)|"
    done
    [ "$_vsu_cnt" -ge 13 ] || return 1
    while read -r _vsu_name _vsu_ip _vsu_tp _vsu_grp _vsu_host; do
        [ -n "$_vsu_ip" ] || continue
        # 表里 "-" 表示该上游不需要 SNI，对应 uci 里就不该有 host_name（get 为空串）
        _vsu_sni=""
        [ "$_vsu_tp" = "tls" ] && [ "$_vsu_host" != "-" ] && _vsu_sni="$_vsu_host"
        case "$_vsu_dump" in
            *"|$_vsu_ip;$_vsu_tp;$_vsu_grp;$_vsu_sni;1|"*) ;;
            *) log "[SMARTDNS] 上游与表不符：$_vsu_name $_vsu_ip（期望 $_vsu_tp/$_vsu_grp/${_vsu_sni:-无SNI}，enabled=1）"
               return 1 ;;
        esac
    done <<'SD_UPSTREAM_EOF'
alidns 223.5.5.5 udp Cn -
alidns 223.6.6.6 udp Cn -
dnspod 119.29.29.29 udp Cn -
baidu 180.76.76.76 udp Cn -
360dns 101.226.4.6 udp Cn -
360dns 218.30.118.6 udp Cn -
360dns 123.125.81.6 udp Cn -
360dns 140.207.198.6 udp Cn -
cnnic 1.2.4.8 udp Cn -
google 8.8.8.8 tls Out dns.google
google 8.8.4.4 tls Out dns.google
cloudflare 1.1.1.1 tls Out cloudflare-dns.com
cloudflare 1.0.0.1 tls Out cloudflare-dns.com
SD_UPSTREAM_EOF
    return 0
}

verify_smartdns() {
    # ① 固件自带 smartdns（构建期 PACKAGES 内置），本节点只负责「把配置写对」。
    # 【v.180.100】不再「未装就放行」：缺二进制说明固件不合规，直接判未就绪，
    # 让 build_smartdns 打出明确日志后硬失败，问题当场暴露，不拖到末尾 sd_serve。
    _smartdns_installed || return 1
    verify_smartdns_main || return 1
    verify_smartdns_upstream || return 1
    # dnsmasq 必须已经让出 53：port=0 是 OpenWrt 官方的「禁用 DNS」写法
    for _vsd_dm in $(run uci show dhcp 2>/dev/null | grep -E '=dnsmasq$' | cut -d. -f2 | cut -d= -f1); do
        [ "$(run uci -q get "dhcp.$_vsd_dm.port" 2>/dev/null)" = "0" ] || return 1
    done
    # 运行态复核：uci 说 port=53 不等于真在 53 上听。init 把 uci 翻译成
    #   /var/etc/smartdns/smartdns.conf，bind 行才是最终监听参数：
    #       全接口 → bind [::]:53 / bind-tcp [::]:53
    #       绑网卡 → bind [::]:53@br-lan / @lo
    # 所以这里直接看生成物。conf 还没生成（从没启动过）时放行，交给 build 走一轮。
    _vsd_conf=/var/etc/smartdns/smartdns.conf
    if [ -f "$_vsd_conf" ]; then
        run grep -qE '^bind(-tcp|-tls|-https)? ' "$_vsd_conf" 2>/dev/null || {
            log "[SMARTDNS] 生成的 conf 里没有任何 bind 行"
            return 1
        }
        if run grep -E '^bind(-tcp|-tls|-https)? ' "$_vsd_conf" 2>/dev/null | grep -q '@'; then
            log "[SMARTDNS] conf 里 bind 带 @device（只绑具体网卡），容器/其他网段收不到"
            return 1
        fi
    fi
    return 0
}

# 探测 network.wan / network.wan6 段是否仍存在，存在则回显段名。
# 用 uci show 而不是 uci get network.wan：后者依赖"段存在但无 option 时的返回"，
# 在精简 uci（busybox 版、测试 mock）里两段式路径一律 exit 1，会把"存在"误判成"不存在"。
_wan_sections() {
    for _ws in wan wan6; do
        if run uci -q show "network.$_ws" 2>/dev/null | grep -q "^network\.$_ws="; then
            printf '%s\n' "$_ws"
        fi
    done
}

# 内核里有没有名为 wan / wan6 的接口（v.108.32）。x86 的网口是 eth*，这一项恒为空；
# 一旦出现，说明 uci 之外还有东西在造 WAN 面（DSA 板子的 wan netdev、手工 ip link、
# 别的脚本插一脚）。段删干净了但接口还在，就是「配置看着是旁路由、实际还在当网关」。
_wan_ifaces() {
    for _wi in wan wan6; do
        [ -e "/sys/class/net/$_wi" ] && printf '%s\n' "$_wi"
    done
    return 0
}

# firewall 里引用了 wan / wan6 的段，输出「段:接口」，空格分隔（无尾空格）。
# 抽成一处，是因为 purge 与 audit 必须共用同一份解析：各写一份的后果是
# 「purge 认得出、audit 认不出」——清理完了体检还在报，或者反过来报绿。
# uci 的 list 在 `uci show` 里是一行带多个值：
#   firewall.@zone[1].network='wan' 'wan6'
# 所以后面按值逐个 del_list，不能整条覆盖 —— 一覆盖就把别的接口引用也抹了。
_wan_refs() {
    _wr_all=""
    for _wr_net in wan wan6; do
        for _wr_sec in $(run uci show firewall 2>/dev/null \
            | sed -n "s/^firewall\.\([^.]*\)\.network=.*'$_wr_net'.*/\1/p" | sort -u); do
            if [ -n "$_wr_all" ]; then
                _wr_all="$_wr_all $_wr_sec:$_wr_net"
            else
                _wr_all="$_wr_sec:$_wr_net"
            fi
        done
    done
    [ -n "$_wr_all" ] && printf '%s\n' "$_wr_all"
    return 0
}

# 旁路由锁死（v.108.27）：wan / wan6 段一律删除，不作为 DAG 节点、不参与任何判定。
# 为什么从节点降级成无条件动作：目标就是旁路由，WAN 口永远不该存在 ——
# 「检测有没有 wan 段」对这台机器恒等于「还没有，那就删」，多一个节点只是多一行日志。
# 为什么必须整段 delete 而不是 disabled=1：新 nft 后台不认 disabled 标志，段还在，
# fw4 生成规则时照样按 proto/device 起接口、挂 WAN zone，等于旁路由还在当路由器用。
# 为什么删完要 reload：commit 只落到 /etc/config/network，运行中的接口还在内核里；
# 不 reload 的话这一轮看起来删干净了，实际 WAN 面还通着。
purge_wan_sections() {
    # network 配置本身写坏时 uci show 会失败、输出为空 —— 那不是「没有 wan 段」，
    # 是「读不出来」。不区分的话，一台配置文件损坏的机器会被判成「WAN 已清空」。
    if ! run uci show network >/dev/null 2>&1; then
        log "[WAN] 无法解析 /etc/config/network，不能判断 wan 段状态"
        return 1
    fi
    _pw_left=$(_wan_sections)
    if [ -z "$_pw_left" ]; then
        # 【v.108.32】段删过不等于引用清过。上一版把清理写在下面「真删了段」的分支里，
        # 热更新的机器（不刷机、直接换脚本）段早就没了，永远走不到清理那一步 ——
        # firewall 里对 wan 的引用一直留着，fw4 每轮 reload 都对不存在的接口告警。
        # 清理本身幂等（没有引用就 return 0），挪到这里没有代价。
        log "[WAN] 旁路由锁定：wan/wan6 段已不存在，无需删段"
        if ! purge_wan_refs; then
            log "[WAN] firewall 引用清理失败"
            return 1
        fi
        return 0
    fi
    log "[WAN] 旁路由锁定：发现 $_pw_left，整段删除"
    for _pw_n in $_pw_left; do
        run uci -q delete "network.$_pw_n" 2>/dev/null
    done
    if ! run uci -q commit network 2>/dev/null; then
        log "[WAN] 删除后提交失败（改动只在内存里，重启即丢）"
        return 1
    fi
    _pw_after=$(_wan_sections)
    if [ -n "$_pw_after" ]; then
        log "[WAN] 删除后复核仍有残留：$_pw_after"
        return 1
    fi
    _net_reload
    # 【v.108.30】firewall 里可能还挂着 `list network 'wan' 'wan6'`。段没了之后
    # fw4 会一直对不存在的接口告警，这条引用本身也在描述一个不存在的世界。
    # 只删「引用」，不删 zone：zone 上还可能绑着 rules/forwardings，整段删会把
    # 别的东西一起带走；fw4 对没有 network 的 zone 是忽略的。
    if ! purge_wan_refs; then
        log "[WAN] firewall 引用清理失败"
        return 1
    fi
    # 【v.108.32】段删了、引用清了，最后一关是内核：netifd 没拆掉的接口会继续存在，
    # 这时「uci 里没有 wan」是真的，但网卡还挂着。reload 是异步的，这里只报不判死，
    # 判定交给开机后的 audit_wan_purged（那时该消失的早消失了）。
    _pw_if=$(_wan_ifaces)
    [ -n "$_pw_if" ] && log "[WAN] 段已删，但内核里仍有接口：$_pw_if（等 reload 收敛，体检会复核）"
    log "[WAN] 已删除 network.wan / network.wan6 并 reload，WAN 面彻底关闭"
    return 0
}

# 清掉 firewall 里对 wan/wan6 的引用（这两个接口段已不存在）。
# 解析在 _wan_refs，这里只负责按值逐个 del_list 并提交。
purge_wan_refs() {
    _pr_hit=$(_wan_refs)
    [ -n "$_pr_hit" ] || return 0
    for _pr_one in $_pr_hit; do
        _pr_sec=${_pr_one%%:*}
        _pr_net=${_pr_one##*:}
        if ! run uci -q del_list "firewall.$_pr_sec.network=$_pr_net" 2>/dev/null; then
            log "[WAN] firewall.$_pr_sec 解除 $_pr_net 引用失败"
            return 1
        fi
        log "[WAN] firewall.$_pr_sec 不再引用 $_pr_net（该接口段已删除）"
    done
    if ! run uci -q commit firewall 2>/dev/null; then
        log "[WAN] firewall 引用改动提交失败（改动只在内存里）"
        return 1
    fi
    run_svc /etc/init.d/firewall reload >/dev/null 2>&1
    return 0
}

# reload 单独抽一层：直接写绝对路径的话，「删完到底有没有让内核重建接口」
# 就只剩一句注释可以相信了 —— 抽出来测试才能真的数到这次调用。
_net_reload() { run_svc /etc/init.d/network reload >/dev/null 2>&1; }

# 管理服务监听面验证（v.77 同源）：dropbear(SSH) 绑 LAN zone 对应接口
# ——取代原 99-custom 的「Interface 清空=无差别监听所有口」：那种写法会把 SSH 暴露到 WAN
# 无 name=lan 的 zone → 不涉及，跳过
# 【v.108.40】ttyd 不再参与：本机用不到网页终端，那两条判据（interface=all +
# netstat 查端口监听）连同 build 侧的 ttyd 写入一起删掉。原判据里 `netstat -lnt`
# 在 ImmortalWrt 默认固件里通常没有这个 applet，命令不存在 → 管道空 → grep 必失败，
# 于是配置写得完全正确也被判成「写了没生效」，收口复核直接 exit 1（见 v.108.40 说明）。
verify_svc_bind() {
    _wn=$(_zone_lan_network) || { log "[服务] 无 name=lan 的 zone，本轮不校验管理服务绑定"; return 0; }
    [ "$(run uci -q get dropbear.@dropbear[0].Interface 2>/dev/null)" = "$_wn" ] || return 1
    return 0
}

# docker 防火墙验证：zone（ACCEPT + 172.16.0.0/12）+ docker↔lan 双向 forwarding
# 【v.180.81】wan zone 已从固件 /etc/config/firewall 整段删除，docker2wan 随之移除：
#   规则 dest 指向不存在的 zone 会让 fw4 整表加载失败（firewall/network reload 卡死）
# 无 dockerd → 不涉及，跳过
verify_docker_fw() {
    command -v dockerd >/dev/null 2>&1 || { log "[docker] 未安装 dockerd，本轮不校验 docker 防火墙"; return 0; }
    # 【v.108.37】段类型也要验：build 里 `uci set firewall.docker=zone`，
    # verify 原来只查 name/input/output/forward/subnet。段类型被写坏（例如变成 rule 段）
    # 时这些 option 一样在，fw4 却根本不把它当 zone —— docker 网段的转发策略全失效。
    [ "$(run uci -q get firewall.docker 2>/dev/null)" = "zone" ] || return 1
    [ "$(run uci -q get firewall.docker.name 2>/dev/null)" = "docker" ] || return 1
    [ "$(run uci -q get firewall.docker.input 2>/dev/null)" = "ACCEPT" ] || return 1
    [ "$(run uci -q get firewall.docker.output 2>/dev/null)" = "ACCEPT" ] || return 1
    [ "$(run uci -q get firewall.docker.forward 2>/dev/null)" = "ACCEPT" ] || return 1
    run uci -q get firewall.docker.subnet 2>/dev/null | grep -qx '172.16.0.0/12' || return 1
    [ "$(run uci -q get firewall.docker2lan.src 2>/dev/null)" = "docker" ] || return 1
    [ "$(run uci -q get firewall.docker2lan.dest 2>/dev/null)" = "lan" ] || return 1
    [ "$(run uci -q get firewall.docker2lan.target 2>/dev/null)" = "ACCEPT" ] || return 1
    [ "$(run uci -q get firewall.docker2lan.proto 2>/dev/null)" = "all" ] || return 1
    [ "$(run uci -q get firewall.lan2docker.src 2>/dev/null)" = "lan" ] || return 1
    [ "$(run uci -q get firewall.lan2docker.dest 2>/dev/null)" = "docker" ] || return 1
    # 【v.108.48】target / proto 原来没验：build 会写 ACCEPT，但被改成 REJECT
    # 或者丢掉 proto 时 verify 仍判就绪，规则实际是坏的却不重建。
    [ "$(run uci -q get firewall.lan2docker.target 2>/dev/null)" = "ACCEPT" ] || return 1
    [ "$(run uci -q get firewall.lan2docker.proto 2>/dev/null)" = "all" ] || return 1
    return 0
}

# 管理服务绑定 builder（v.95）：把 dropbear 的监听面钉到 LAN 网络，
# 避免 SSH 无差别监听所有口（尤其不能暴露到 WAN）。无 lan zone 则无从推导，跳过。
# 【v.108.40】ttyd 不再处理（本机不用网页终端）。
build_svc_bind() {
    _wn=$(_zone_lan_network) || { log "[服务] 无 name=lan 的 zone，跳过管理服务绑定"; return 0; }
    run uci -q set dropbear.@dropbear[0].Interface="$_wn"
    run uci -q commit dropbear 2>/dev/null
    run /etc/init.d/dropbear reload >/dev/null 2>&1 || true
    log "[服务] dropbear 绑定 $_wn"
    return 0
}

# docker 防火墙 builder（v.95）：没装 dockerd 就什么都不做；
# 装了则补 docker zone（ACCEPT + 172.16.0.0/12）与两条 forwarding（wan zone 已删）。
build_docker_fw() {
    command -v dockerd >/dev/null 2>&1 || { log "[docker] 未安装 dockerd，跳过"; return 0; }
    if ! run uci -q get firewall.docker >/dev/null 2>&1; then
        run uci -q set firewall.docker=zone >/dev/null 2>&1
    fi
    run uci -q set firewall.docker.name=docker
    run uci -q set firewall.docker.input=ACCEPT
    run uci -q set firewall.docker.output=ACCEPT
    run uci -q set firewall.docker.forward=ACCEPT
    run uci -q delete firewall.docker.subnet 2>/dev/null
    run uci -q add_list firewall.docker.subnet=172.16.0.0/12
    _fw_rule_d() {
        _frd="$1"; _frs="$2"; _frdst="$3"
        run uci -q get "firewall.$_frd" >/dev/null 2>&1 || uci -q set "firewall.$_frd=rule"
        run uci -q set "firewall.$_frd.src=$_frs"
        run uci -q set "firewall.$_frd.dest=$_frdst"
        run uci -q set "firewall.$_frd.target=ACCEPT"
        # 【v.108.48】同 _fw_rule：不写 proto 就被 fw4 默认成 tcpudp，ICMP 漏掉。
        run uci -q set "firewall.$_frd.proto=all"
    }
    _fw_rule_d docker2lan docker lan
    _fw_rule_d lan2docker lan    docker
    # 【v.180.81】wan zone 已整段删除，docker2wan 不能再写：dest 指向不存在的 zone
    # 会让 fw4 整表加载失败（firewall/network reload 卡住）。残留的一并清掉。
    run uci -q delete firewall.docker2wan 2>/dev/null
    log "[docker] 已写入 docker zone 与 2 条 forwarding（docker2wan 已清除）"
    return 0
}

# ============================================================================
# v.95：PREP 网络/防火墙节点由「只验不写」改为「验证 + 修改」
#   改完 → uci commit → 按组 reload 才真正生效（commit 只落盘，reload 才生效）
#   分组 reload：network → /etc/init.d/network reload
#               dhcp    → /etc/init.d/dnsmasq restart
#               firewall→ /etc/init.d/firewall reload（fw4 重建 nft 表）
#   不设回滚：改完 verify 仍不过 → ensure 判 hard，引导终止（按既定策略）
#   但加一道「不自杀」保护：改 br-lan / lan 之前先确认改完自己还能连上，
#   确认不了就不改、直接 hard —— 旁路由上把网桥改错等于失联。
# ============================================================================

# 改前「不自杀」预检：本次要动的字段若涉及管理面（br-lan / lan 地址），
# 必须能证明改完仍可达。证明不了就放弃写入，交给 hard 终止而非断网。
_net_write_guard() {
    _nwg_what="$1"
    _nwg_remote="${SSH_CONNECTION%% *}"
    if [ -n "$_nwg_remote" ]; then
        _nwg_ip="$(_lan_ip)"
        case "$_nwg_remote" in
            "$(echo "$_nwg_ip" | awk -F. '{print $1"."$2"."$3}')."*)
                log "[保护] 检测到 SSH 来自 LAN 网段（$_nwg_remote），改写 $_nwg_what 后本会话可能失联"
                ;;
            *)
                log "[保护] SSH 来自非 LAN 网段（$_nwg_remote），改写 $_nwg_what 影响不到本会话"
                ;;
        esac
    fi
    return 0
}

# ---- 旁路由网络基线 builder（v.78-bp 同源；v.95 起真实写入）----

# 桥接口 builder：br-lan 桥设备 + lan 指向它 + ports = 当前枚举物理口；清掉残留 cfg030f15
build_br_lan_ports() {
    _vp=$(_phys_ports)
    [ -n "$_vp" ] || { log "[BR_LAN] 未枚举到物理网口（驱动未就绪？），不敢建空桥，放弃写入"; return 1; }
    _net_write_guard "br-lan 桥与端口"

    # 段类型必须先声明成 device。只写 .type/.name 而不声明段类型时，uci 会把一个
    # 不存在的段建成 `config br_lan 'br_lan'`；netifd 只认 config device / interface，
    # 遇到别的类型直接忽略该段。表现：运行中的桥还在（内核里没拆），一重启 br-lan
    # 就没了。network.lxc 那边写了 =interface，这里此前漏了这一行。
    run uci -q set network.br_lan='device'

    # 清掉除 br_lan 之外、name 也是 br-lan 的 device 段（默认 network 的匿名段、
    # LuCI 重建留下的 cfg0xxxxx），它们会和 br_lan 抢同一批物理口。
    # 按 name 找，不赌具体段名。
    for _ds in $(run uci show network 2>/dev/null | grep -E '=device$' | cut -d. -f2 | cut -d= -f1); do
        [ "$_ds" = "br_lan" ] && continue
        [ "$(run uci -q get "network.$_ds.name" 2>/dev/null)" = "br-lan" ] || continue
        run uci -q delete "network.$_ds" 2>/dev/null
        log "[BR_LAN] 已清除重复的 br-lan device 段：$_ds"
    done

    run uci -q set network.br_lan.type='bridge'
    run uci -q set network.br_lan.name='br-lan'
    run uci -q delete network.br_lan.ports 2>/dev/null
    for _p in $_vp; do
        run uci -q add_list network.br_lan.ports="$_p"
    done
    run uci -q set network.lan.device='br-lan'
    log "[BR_LAN] 已写入 br-lan 桥，ports=$_vp"
    return 0
}

# LAN 静态地址 builder：按 _lan_static_conf 推导值写 proto/device/ipaddr/netmask/gateway/dns
build_lan_static() {
    # 同上：拆成位置参数再用，这个 shell 里没有别的取法。
    # shellcheck disable=SC2046
    set -- $(_lan_static_conf)
    # 先验再写：这四个值不是用户当场敲的，是编译期文件里读出来的。
    # 文件被写坏（空行、多空格、粘了 Windows 换行、手抖写成 10.0.0.1000）
    if ! _lan_conf_valid "$1" "$2" "$3" "$4"; then
        log "[LAN] 期望值不合法：IP=[$1] 掩码=[$2] 网关=[$3] DNS=[$4]"
        log "[LAN] 请检查 /etc/config/custom_router_{ip,netmask,gateway,dns}.txt 首行"
        log "[LAN] 为避免把 LAN 写成非法地址导致失联，放弃写入，hard 终止"
        return 1
    fi
    _net_write_guard "lan 静态地址"
    run uci -q set network.lan.proto='static'
    run uci -q set network.lan.device='br-lan'
    run uci -q set network.lan.ipaddr="$1"
    run uci -q set network.lan.netmask="$2"
    run uci -q set network.lan.gateway="$3"
    run uci -q delete network.lan.dns 2>/dev/null
    run uci -q add_list network.lan.dns="$4"
    log "[LAN] 已写入静态地址 $1/$2 网关 $3 DNS $4"
    return 0
}

# DHCP 让权 builder：dhcp.lan.ignore=1；清 IPv6 RA 相关项；所有 dnsmasq 段删 authoritative
build_dhcp_ignore() {
    # 【v.180.94】缺 dhcp.lan 段时**不建**：旁路由的 LAN 本来就不跑 DHCP，
    # 缺段是「已关闭」，不是「待配置」。旧行为是 add 一个段再 rename 成 lan 并置
    # ignore=1 —— 段被搬回来了，虽然不发地址，但等于替用户重开了一个 DHCP 池。
    # 这里改用 uci show 判段是否存在（uci get 两段式路径在精简 uci 上会误判）。
    _bdi_has=0
    if run uci show dhcp 2>/dev/null | grep -q '^dhcp\.lan=dhcp$'; then
        _bdi_has=1
    fi
    if [ "$_bdi_has" != "1" ]; then
        log "[DHCP] 无 dhcp.lan 段（LAN 不提供 DHCP），跳过让权"
        return 0
    fi
    run uci -q set dhcp.lan.ignore='1'
    run uci -q delete dhcp.lan.ra 2>/dev/null
    run uci -q delete dhcp.lan.dhcpv6 2>/dev/null
    run uci -q delete dhcp.lan.ndp 2>/dev/null
    run uci -q delete dhcp.lan.ra_management 2>/dev/null
    # 所有 dnsmasq 段删掉 authoritative：旁路由不是权威 DHCP，避免抢答
    for _dm in $(run uci show dhcp 2>/dev/null | grep -E '=dnsmasq$' | cut -d. -f2 | cut -d= -f1); do
        run uci -q delete "dhcp.$_dm.authoritative" 2>/dev/null
    done
    # 【v.180.97】53 不在这里让。曾经并到这一步试过，但 dhcp_ignore 排在 DEPS 之前：
    # 那一刻 smartdns 可能还没装，让出 53 等于本机立刻没有 DNS，_net_ready 第三层
    # 的 nslookup 必然失败，DEPS 就永远装不上 smartdns —— 首轮直接死锁。
    # 所以让位只跟着 smartdns 的配置走（build_smartdns → _dnsmasq_release_53）：
    # 能接管了才放手，接管不了就继续让 dnsmasq 顶着。
    log "[DHCP] 已让权：lan.ignore=1，并清除 RA/authoritative"
    return 0
}

# smartdns 配置入口：主段（build_smartdns_main）+ 上游表（build_smartdns_upstream）+ dnsmasq 让位
# 只写 uci 内存态，重启动作全部交给 flush_uci（commit 后重启 dnsmasq / smartdns）。
# smartdns 配置拆成两件事：① 「服务本身」（主段）② 「上游服务器表」，dnsmasq 让位留在外层。
# 只写 uci 内存态，重启动作全部交给 flush_uci（commit 后重启 dnsmasq / smartdns）。
build_smartdns_main() {
    _bsm_seg=$(_sd_main_seg)
    if [ -z "$_bsm_seg" ]; then
        run uci -q add smartdns >/dev/null 2>&1
        _bsm_seg=$(_sd_main_seg)
        [ -n "$_bsm_seg" ] || { log "[SMARTDNS] 无法创建主配置段"; return 1; }
    fi
    run uci -q set "smartdns.$_bsm_seg.enabled=1"
    run uci -q set "smartdns.$_bsm_seg.port=53"
    # bind 不是 UCI 选项：init 脚本只读 port / bind_device，历史残留的 bind 不生效，
    # 只会让人误以为在控制监听地址，顺手清掉。
    run uci -q delete "smartdns.$_bsm_seg.bind" 2>/dev/null
    # 监听全部接口：init 只在 bind_device=1 时才把 bind_device_name（默认 br-lan）拼进
    # bind 行，还额外追加 lo。设 0 后 devices 为空 → 只生成 `bind [::]:53` /
    # `bind-tcp [::]:53`，br-lan / lxcbr0 / docker0 一律可达。
    run uci -q set "smartdns.$_bsm_seg.bind_device=0"
    run uci -q set "smartdns.$_bsm_seg.cache_size=32768"
    run uci -q set "smartdns.$_bsm_seg.serve_expired=1"
    run uci -q set "smartdns.$_bsm_seg.prefetch_domain=1"
    return 0
}

# 上游按表补齐/纠正，不清空：逐条按 ip 定位段 —— 有就修正字段，没有就新建；
# 同一 ip 若存在多个重复段，只保留第一个、其余删掉。你额外加的上游（ip 不在表里）原样保留。
# 表与 verify_smartdns_upstream 里那份必须逐行一致（静态检查 S40 卡这条）。
build_smartdns_upstream() {
    # 先建「ip=段名」索引，避免每条都重新扫一遍 uci show（13 条 × 13 段 = 169 次 fork）
    _bsu_map=" "
    for _bsu_s in $(run uci -q show smartdns 2>/dev/null | grep -E '=server$' | cut -d. -f2 | cut -d= -f1); do
        _bsu_map="$_bsu_map$(run uci -q get "smartdns.$_bsu_s.ip" 2>/dev/null)=$_bsu_s "
    done
    _bsu_n=0
    while read -r _bsu_name _bsu_ip _bsu_tp _bsu_grp _bsu_host; do
        [ -n "$_bsu_ip" ] || continue
        _bsu_hit=""
        _bsu_dup=""
        for _bsu_p in $_bsu_map; do
            [ "${_bsu_p%%=*}" = "$_bsu_ip" ] || continue
            if [ -z "$_bsu_hit" ]; then
                _bsu_hit=${_bsu_p#*=}
            else
                _bsu_dup="$_bsu_dup ${_bsu_p#*=}"
            fi
        done
        for _bsu_d in $_bsu_dup; do
            run uci -q delete "smartdns.$_bsu_d" 2>/dev/null
        done
        if [ -z "$_bsu_hit" ]; then
            run uci -q add smartdns server >/dev/null 2>&1
            _bsu_hit="@server[-1]"
        fi
        run uci -q set "smartdns.$_bsu_hit.enabled=1"
        run uci -q set "smartdns.$_bsu_hit.name=$_bsu_name"
        run uci -q set "smartdns.$_bsu_hit.ip=$_bsu_ip"
        run uci -q set "smartdns.$_bsu_hit.type=$_bsu_tp"
        run uci -q set "smartdns.$_bsu_hit.server_group=$_bsu_grp"
        # DoT 必须带 SNI，否则证书主机名校验必然失败（8.8.8.8 的证书是 dns.google）
        if [ "$_bsu_tp" = "tls" ] && [ "$_bsu_host" != "-" ]; then
            run uci -q set "smartdns.$_bsu_hit.host_name=$_bsu_host"
        else
            # UDP 段不该带 SNI：历史残留的 host_name 清掉，否则 verify 会一直判不符
            run uci -q delete "smartdns.$_bsu_hit.host_name" 2>/dev/null
        fi
        _bsu_n=$((_bsu_n+1))
    done <<'SD_UPSTREAM_EOF'
alidns 223.5.5.5 udp Cn -
alidns 223.6.6.6 udp Cn -
dnspod 119.29.29.29 udp Cn -
baidu 180.76.76.76 udp Cn -
360dns 101.226.4.6 udp Cn -
360dns 218.30.118.6 udp Cn -
360dns 123.125.81.6 udp Cn -
360dns 140.207.198.6 udp Cn -
cnnic 1.2.4.8 udp Cn -
google 8.8.8.8 tls Out dns.google
google 8.8.4.4 tls Out dns.google
cloudflare 1.1.1.1 tls Out cloudflare-dns.com
cloudflare 1.0.0.1 tls Out cloudflare-dns.com
SD_UPSTREAM_EOF
    [ "$_bsu_n" -eq 13 ] || { log "[SMARTDNS] 上游按表处理条数异常（$_bsu_n ≠ 13），不接管 DNS"; return 1; }
    return 0
}

build_smartdns() {
    # ① 配置之前先确保二进制在位：固件自带；万一被 opkg remove 遮掉了，
    #    从只读基座拷回来（不联网、不装包、不碰 opkg 数据库），然后照常写配置。
    # 【v.180.102】pkg_base 已把 smartdns 纳入第 1 步闸门，正常路径到这里必然在位；
    # 这段是二次兜底（中途被手工摘掉、或本节点被单独调用时），统一走 _rom_restore_smartdns。
    if ! _smartdns_installed; then
        log "[SMARTDNS] smartdns 不在位，先试只读基座 $ROMDIR"
        _rom_restore_smartdns
        hash -r 2>/dev/null || true
        if ! _smartdns_installed; then
            log "[SMARTDNS] 只读基座也没有 smartdns：固件未内置该包（custom-packages.sh 第 79 行）"
            return 1
        fi
        log "[SMARTDNS] 已从只读基座恢复，继续写配置"
    fi
    build_smartdns_main || return 1
    # 上游没铺满就不接管 DNS：此时 dnsmasq 仍留着 53，不会出现「53 让出去了却没人应答」
    build_smartdns_upstream || return 1
    # dnsmasq 让出 53：只关 DNS 端口，DHCP/RA 一概不碰。
    # 与 DHCP 让权节点共用 _dnsmasq_release_53（v.180.95），这里保留调用是因为
    # 「刚装完 smartdns」这一刻 DHCP 节点早已跑过，只能由本函数当场让位。
    _dnsmasq_release_53 || return 1
    log "[SMARTDNS] 已写入 13 个上游（国内 9 UDP / 境外 4 DoT），dnsmasq 退为纯 DHCP"
    return 0
}

# ---- 必备组件收尾节点（v.180.85）：缺了就等网络好了再装，装完立刻配 ----
# 为什么要单独一个节点、还放在最末：装机那一刻网络常常还没通，在 NETBASE 里硬装必然失败。
# 语义是「软到达」——网络通就装并配好，不通就只记日志，下次引导自动重来。
# 与 enroll / bouncer_verify 同一档柔性（SOFT_NODES），绝不中止引导。
#
# 三层探测，任一不通就算「现在不能装」：
#   ① 网关    —— 本地链路是否通（lan 静态网关，取不到就退回默认路由的 next-hop）
#   ② 公网 IP —— 出口/NAT 是否通（223.5.5.5 阿里 DNS 的 IP，先不依赖 DNS）
#   ③ 域名    —— DNS 是否可用（www.baidu.com 能解析才算真通）
# 只看退出码不看输出：busybox ping / nslookup 的文案各版本差异太大。
_net_ready() {
    _nr_gw=$(run uci -q get network.lan.gateway 2>/dev/null)
    [ -n "$_nr_gw" ] || _nr_gw=$(run ip route 2>/dev/null | sed -n 's/^default via \([0-9.]*\) .*/\1/p' | head -n1)
    if [ -n "$_nr_gw" ]; then
        run ping -c 2 -W 2 "$_nr_gw" >/dev/null 2>&1 || return 1
    fi
    run ping -c 2 -W 2 223.5.5.5 >/dev/null 2>&1 || return 1
    run nslookup www.baidu.com >/dev/null 2>&1 || return 1
    return 0
}

# 就绪判据：lxc 与 smartdns 都在位。缺任何一个 → 未就绪，交给 build_deps 去装。
# 【v.180.98】DEPS 退化为「纯验证」：不装包、不写配置、不做任何落地改动。
# 位置也从「网络基线之后」挪到「容器流程与 bouncer 校验之后、enroll 之前」——
# 它是本轮的总闸门：网络通不通、lxc 与 smartdns 到底在不在，最后一次性交代清楚，
# 然后才允许编 enroll。装包不再由脚本负责：固件自带，pkg_base（Ⅱ 阶段）只做在位验证。
# 【v.180.103】本节点属 Ⅴ 阶段：它判的是「现在能不能真的够到 crowdsec」，所以网络三层是主体，
# lxc 那 5 次 command -v 只是 enroll 前的断言式兜底（见下方日志括号里的说明）。
verify_deps() {
    if ! _net_ready; then
        log "[DEPS] 网络不通（网关 / 公网 IP / DNS 至少一层没过）"
        return 1
    fi
    if ! _sd_missing_deps; then
        log "[DEPS] lxc 命令不在位：$_SD_MISSING（pkg_base 已在 Ⅱ 阶段拦过，这里出现说明中途被摘）"
        return 1
    fi
    verify_smartdns_main || { log "[DEPS] smartdns 主段配置不符"; return 1; }
    verify_smartdns_upstream || { log "[DEPS] smartdns 上游表不符"; return 1; }
    log "[DEPS] 网络可用、lxc 与 smartdns 均已就位、smartdns 配置吻合"
    return 0
}

# 只验证不安装：修不了就记账（deps 在 SOFT_NODES，不中止引导），
# enroll 因 GROUP_DEP_ENROLL=SMARTCHK 整组跳过，下次开机重来。
build_deps() {
    log "[DEPS] 本节点只做验证，不落地任何改动（装包 / 改配置都不在这里）"
    log "[DEPS] 本轮 enroll 跳过，缺的项由下一次开机重试"
    return 1
}

# ---- pkg_base：必备组件在位验证 = Ⅱ 阶段（v.180.103 起排在网络基线之后）----
# 位置口径（用户定的五阶段）：Ⅰ 配网桥/接口/防火墙 → Ⅱ 查 lxc+smartdns（缺则从 /rom 恢复）
#   → Ⅲ smartdns 配置 → Ⅳ crowdsec 构建 → Ⅴ 网络连通检测 + enroll。
# 所以本节点必须在 lxc_zone / fwd_rules / snat 等网络节点之后、lxc_auto 与 smartdns 之前：
#   · 前面：网络配置一步都不需要 lxc，把它排在链首会让「先配网」这条前提不成立；
#   · 后面：lxc_auto 要 lxc-auto 的服务脚本，smartdns 要二进制，都得等本节点恢复完。
# 包的来源只有一处：固件内置（构建期 PACKAGES 装进 /rom）。脚本不联网装包。
# 判据是「命令/文件真能用」而不是「包名在列表里」：liblxc 在、lxc 壳在、applet 缺一个，
# 一样跑不起来 —— 见 _sd_missing_deps 的五件套。
# 【v.180.102】闸门扩到 smartdns：判据 _pkg_missing_all（lxc 五件套 + smartdns 二进制/init），
# 两项都要，缺哪项就在日志里点名哪项。
# 只读不写：本节点不装包、不写 uci、不碰容器。
verify_pkg_base() {
    _pkg_missing_all
}

# 缺件才动，缺什么补什么：lxc 走全家桶通配，smartdns 走单包递归，互不连坐。
# 全程只从 /rom 拷文件：不联网、不 opkg/apk、不碰 opkg 数据库、不覆盖 /etc/config。
build_pkg_base() {
    if _pkg_missing_all; then
        log "[PKG] 必备组件齐备：lxc 五件套（start/stop/ls/info/attach）+ smartdns（固件自带）"
        return 0
    fi
    log "[PKG] 必备组件缺失：$_PKG_MISSING —— 先试只读基座 $ROMDIR"
    # ① lxc：applet 是各自独立的包，必须扫 lxc-*.list 全量恢复，再补 liblxc 依赖树
    if ! _sd_missing_deps; then
        _rom_restore_lxc \
            || log "[PKG] 只读基座里没有 lxc 的安装清单（$ROMDIR/usr/lib/opkg/info/lxc-*.list）"
    fi
    # ② smartdns：二进制 + init + 依赖（libopenssl3 等）；.list 不在就没救
    if ! _smartdns_installed; then
        _rom_restore_smartdns \
            || log "[PKG] 只读基座里没有 smartdns 的安装清单（$ROMDIR/usr/lib/opkg/info/smartdns.list）"
    fi
    hash -r 2>/dev/null || true
    if _pkg_missing_all; then
        log "[PKG] 已从只读基座恢复，必备组件齐全"
        return 0
    fi
    log "[PKG] 恢复后仍缺：$_PKG_MISSING"
    log "[PKG] 固件未内置：检查 shell/custom-packages.sh 第 41 行(lxc) / 第 79 行(smartdns)"
    return 1
}

# ---- sd_serve：smartdns 运行态验证（SMARTCHK 组，v.180.98 新增）----
# 单独一组、排在 BOOT 与 BOUNCERVERIFY 之后：容器没起来之前谈「DNS 是否真的在服务」
# 没有意义，口径就是「先跑完 lxc，再验证 smart」。只读不写；不通过时 build 只做
# 「按已写好的 uci 重启一次」，绝不重装、不改配置。
verify_sd_serve() {
    # 【v.180.106】判据用 pidof，不用 pgrep -x：busybox 的 pgrep -x 拿 argv[0]
    # 整串比对，进程实际是 "/usr/sbin/smartdns -f -c ..."，与 "smartdns" 不相等。
    # 真机实测 pgrep -x 恒空、pidof 直接给 PID —— 原判据让本节点每轮必失败，
    # SMARTCHK 永不置位，enroll 整组被跳过，crowdsec 也就是永远注册不上。
    run pidof smartdns >/dev/null 2>&1 || {
        log "[SMARTCHK] smartdns 进程不在"
        return 1
    }
    run netstat -lnu 2>/dev/null | grep -qE ':53[[:space:]]' || {
        log "[SMARTCHK] 53 没有在监听（UDP）"
        return 1
    }
    verify_smartdns_upstream || return 1
    if ct_running; then
        run lxc-attach -n "$LXC_NAME" -- nslookup www.baidu.com >/dev/null 2>&1 || {
            log "[SMARTCHK] 容器内解析失败（容器 DNS 指不到 smartdns）"
            return 1
        }
        log "[SMARTCHK] 53 在服务，容器内解析正常"
    else
        log "[SMARTCHK] 53 在服务（容器未运行，跳过容器内解析）"
    fi
    return 0
}

build_sd_serve() {
    log "[SMARTCHK] 按已写好的 uci 重启 smartdns（不重装、不改配置）"
    run /etc/init.d/smartdns enable >/dev/null 2>&1
    run /etc/init.d/smartdns restart >/dev/null 2>&1 || return 1
    sleep "${SD_SETTLE:-2}"
    return 0
}

# lxc zone + 四条转发规则（lxc2lan / lxc2docker / lxc2vpn / lan2lxc）
build_lxc_zone_fwd() {
    if [ -z "$(_zone_sec lxc)" ]; then
        run uci -q add firewall zone >/dev/null 2>&1
        _lzs=$(run uci show firewall 2>/dev/null | grep -E '=zone$' | cut -d. -f2 | cut -d= -f1 | tail -n1)
        [ -n "$_lzs" ] || { log "[FW] 无法新建 lxc zone"; return 1; }
        run uci -q rename "firewall.$_lzs"='lxczone' >/dev/null 2>&1 || _lzs='lxczone'
    else
        _lzs=$(_zone_sec lxc)
    fi
    run uci -q set "firewall.$_lzs.name=lxc"
    run uci -q set "firewall.$_lzs.network=lxc"
    run uci -q set "firewall.$_lzs.input=ACCEPT"
    run uci -q set "firewall.$_lzs.output=ACCEPT"
    run uci -q set "firewall.$_lzs.forward=ACCEPT"

    _fw_rule() {
        _fr_sec="$1"; _fr_src="$2"; _fr_dst="$3"
        if ! run uci -q get "firewall.$_fr_sec" >/dev/null 2>&1; then
            run uci -q set "firewall.$_fr_sec=rule"
        fi
        run uci -q set "firewall.$_fr_sec.src=$_fr_src"
        run uci -q set "firewall.$_fr_sec.dest=$_fr_dst"
        run uci -q set "firewall.$_fr_sec.target=ACCEPT"
        # 【v.108.48】必须显式写 proto=all，否则 ICMP 被漏掉。
        # fw4 对 config rule 不写 proto 时默认按 tcpudp 处理，编译出来是：
        #     meta l4proto tcp ... jump accept_to_lan "!fw4: lxc2lan"
        #     meta l4proto udp ... jump accept_to_lan "!fw4: lxc2lan"
        # 于是 ping（ICMP）、ESP、GRE 全落在规则之外 —— 真机现象是「规则明明在、
        # uci show 一条不少、fw4 也 reload 了，但容器就是出不去」，
        # forward_lxc 链里那两条规则的 counter 恒为 0，极易被误判成「没写入」。
        # 对比：config forwarding 段没有 proto 概念，天然放行所有协议 ——
        # 这就是为什么用户在 LuCI 里手加两条 forwarding 之后网络立刻通了。
        run uci -q set "firewall.$_fr_sec.proto=all"
    }
    _fw_rule lxc2lan    lxc lan
    _fw_rule lxc2docker lxc docker
    _fw_rule lxc2vpn    lxc vpn
    _fw_rule lan2lxc    lan lxc
    log "[FW] 已写入 lxc zone 与 4 条转发规则"
    return 0
}

# 两个节点共用上面的实现：verify 是分开的（分区域判、分规则判），
# 但构建是同一个动作，拆开写会重复一大段 uci。任一处不符都整体写一遍，幂等。
build_lxc_zone() { build_lxc_zone_fwd; }
build_fwd_rules() { build_lxc_zone_fwd; }

# SNAT builder：从容器网段到 LAN 地址的源地址改写（容器出网生命线）
build_snat() {
    _sn=$(_snat_sec)
    if [ -z "$_sn" ]; then
        run uci -q add firewall nat >/dev/null 2>&1 || { log "[SNAT] 无法新建 nat 段"; return 1; }
        _sn=$(run uci show firewall 2>/dev/null | grep -E '=nat$' | cut -d. -f2 | cut -d= -f1 | tail -n1)
        [ -n "$_sn" ] || return 1
        run uci -q rename "firewall.$_sn"='lxcsnat' >/dev/null 2>&1 || _sn='lxcsnat'
    fi
    run uci -q set "firewall.$_sn.name=lxc-snat"
    run uci -q set "firewall.$_sn.target=SNAT"
    run uci -q set "firewall.$_sn.proto=all"
    run uci -q set "firewall.$_sn.src=lan"
    run uci -q set "firewall.$_sn.src_ip=$(_lxc_net)"
    run uci -q set "firewall.$_sn.snat_ip=$(_lan_ip)"
    log "[SNAT] 已写入 $(_lxc_net) → $(_lan_ip) 源地址改写"
    return 0
}

# LAN zone 放行：input/forward 锁定 ACCEPT
build_lan_input() {
    _lz=$(_zone_sec lan) || { log "[FW] 无 lan zone，跳过"; return 0; }
    run uci -q set "firewall.$_lz.input=ACCEPT"
    run uci -q set "firewall.$_lz.forward=ACCEPT"
    log "[FW] lan zone input/forward 已置 ACCEPT"
    return 0
}
# 旁路由网络基线入口（v.78-bp）：五对象独立预检，哪项不符只重建哪项
# 必须在 setup_bridge/setup_lxc_firewall 之前跑：SNAT 的 snat_ip 取 _lan_ip()，
# 需先确保 network.lan.ipaddr 已校准就位（否则首启会读到固件默认地址）


# docker 防火墙入口（无条件，与模式无关）：装了 dockerd 就要保证容器网络与防火墙互通


# 防火墙修复入口：六分项独立预检，哪项不符只重建哪项
# 全对 -> 不 commit 不 reload 直接跳过；只有 ip_forward 被关 -> 只 echo 1；

# 【v.108.49】末尾的 enroll 是本次补上的：ENROLL 组一直在 GROUP_SEQ 里，但
# DAG_NODES 里从来没有 enroll 这个节点（NODE_GROUP_enroll 也不存在）。而
# ensure_group / rg_restart_verify 都是「遍历 _order，按 NODE_GROUP_<节点> 筛组内节点」，
# 于是这一组永远是 0 个小步骤 —— 日志里就是这三行连着出现：
#     [DAG] 组 ENROLL 就序（0 个小步骤）
#     ---- 组 ENROLL（Console Enroll）：0 个小步骤 ----
#     [ENROLL] Console Enroll 完成（0/0）
# re_enroll / console_enroll_ok / 注册码保管（v.108.52 起为 _park_enroll_key）一次都没被调用过（死代码）。
# 真机证据（24.10，2026-10-22）：/etc/config/crowdsec_enroll_key.txt 26 字节一直在，
# 全量日志 grep 不到「已删除注册码文件」，而 cscli console status 是 not registered。
# [v.180.91] NETBASE 组内顺序：网桥/lxc 链（bridge → lxc_zone → fwd_rules → lan_input →
#   snat → ip_forward → lxc_auto）排在 smartdns 之前——先把容器网络铺起来，再配 DNS。
#   dag_order 的组内次序就是取本行里同组节点的相对出现顺序。
DAG_NODES="img_migrate rootfs ct_config br_lan_ports lan_static dhcp_ignore bridge ct_net lxc_zone fwd_rules lan_input snat ip_forward cgroup_mount ct_bootlink svc_bind docker_fw pkg_base lxc_auto smartdns ct_resolv capi_block ct_boot logconf lapi_fetch bouncer_fill bouncer_verify capi_release enroll deps sd_serve"

# ---- 网络基线模式（--net-only）----
# 适用场景：镜像没进固件（v.107.7 起不再有 Include Crowdsec 开关，容器恒内置，
# 所以「没有镜像」一律是异常：生成失败 / 被删 / 刷的是老固件）。但 Router IP /
# 掩码 / 网关 / DNS 仍然写进了 /etc/config/custom_router_*.txt，其唯一消费者是
# PREP 里的 br_lan_ports / lan_static —— 与容器无关，没理由连网络一起放弃。
# 网络是生命线：镜像没了还能进后台查，网络没了只能扛机器去接显示器。
#
# 该模式只跑 PREP，并摘掉下面这些节点：它们全都与容器强相关，本机没容器时跑了
# 只会失败或被 firewall 拒绝（引用不存在的接口）：
#   bridge       建 lxcbr0
#   ct_net       写容器内 10-eth0.network
#   ct_bootlink  写容器内自启软链
#   ct_resolv    写容器内 resolv.conf
#   lxc_zone     firewall 里声明 lxcbr0 所在 zone
#   fwd_rules    lxcbr0 的 forward 规则
#   snat         10.1.0.0/24 → LAN IP 的源地址改写（只服务容器出网）
#
# cgroup_mount 不在此列：它挂的是 /sys/fs/cgroup/systemd（容器内 systemd 的硬前置），
# 不碰 rootfs，且 verify_cgroup_mount 在 cgroup2 统一层级下第二判据直接通过、
# 实际很少动手；万一真去挂，build_cgroup_mount 也恒 return 0，不会 hard 终止。
# 留在链上一分钱不花，还省得「镜像补上之后头一次起容器先去补挂」这一跳。
NET_ONLY=0
NET_ONLY_SKIP="bridge ct_net ct_bootlink lxc_auto ct_resolv lxc_zone fwd_rules snat"

# 小步骤依赖（DAG 边）：只声明真实的强先后关系，不做无意义的线性串联。
# 注意：PREP 组内的"防火墙小步骤依赖网络小步骤"，是因为防火墙规则要引用接口名；
# 不构成组间死锁（同组内排序由 dag_order 的段内拓扑排序解决）。
DEP_img_migrate=""
DEP_ct_config="img_migrate"
DEP_rootfs="img_migrate"
# ---- PREP：容器启动前的静态准备 ----
DEP_br_lan_ports=""
DEP_lan_static="br_lan_ports"
DEP_dhcp_ignore=""
# smartdns 与 dhcp_ignore 都碰 /etc/config/dhcp，但字段不重叠（ignore/ra vs port）：
# 谁先谁后都不冲突，故不声明相互依赖。它也不依赖 LAN 地址（监听 0.0.0.0:53）。
DEP_smartdns=""
DEP_bridge="lan_static"
# ct_net / ct_bootlink / ct_resolv 写的是容器 rootfs 里的文件（10-eth0.network、
# 自启软链、resolv.conf），显式依赖 rootfs。rootfs 属 INSTALL 组，而 INSTALL 排在
# GROUP_SEQ 第一位，跨组依赖天然满足。v.107.4 之前 INSTALL 排在 PREP 之后，
# 而 PREP 里这三个就要写 rootfs → 必失败 → hard 终止 → rootfs 永不解压。
DEP_ct_net="bridge rootfs"
DEP_cgroup_mount=""
DEP_ct_bootlink="cgroup_mount rootfs"
# lxc_auto 只碰路由器侧的 uci 配置与 rc 软链，跟 rootfs / 容器状态都无关：
# 正因为它不依赖任何东西，才能在「容器跑着、配置却空了」时被验出来并补回去。
DEP_lxc_auto=""
DEP_ct_resolv="ct_net rootfs"
DEP_svc_bind=""
# ---- 路由侧防火墙：每类接口一个独立小步骤 ----
DEP_lxc_zone="bridge"
DEP_fwd_rules="lxc_zone"
# v.108.27：wan / wan6 段在 main 一开始就被无条件删除（purge_wan_sections），
# 不再是 DAG 节点，也没有 wan zone input 这一步 —— 旁路由没有 WAN 面需要收紧。
# snat 只读 lan 地址与容器网段（由 BRIDGE_IP /
# CONTAINER_IP 推导，不依赖 ct_net 节点的执行结果）。两者都不写容器 rootfs，
# 不加 ct_net 依赖，避免与 PREP 内其他节点形成无谓的串行。
DEP_lan_input="br_lan_ports"
DEP_snat="lan_static"
DEP_ip_forward=""
DEP_docker_fw=""
# ---- 容器内静态配置：启动前一次写完，启动后不再碰文件 ----
DEP_capi_block="rootfs ct_bootlink"
# ---- 启动：启动前必须全部备妥 ----
DEP_ct_boot="ct_config rootfs lxc_zone snat cgroup_mount ct_bootlink ct_resolv capi_block"
# ---- 启动后的运行态 ----
# 【v.108.22】LOGCONF 由两个节点（acquis + log_forward）合成一个节点 logconf。
# 它们本来就是同一件事的两半：宿主把 syslog 推给容器、容器用 acquisitions 收并解析。
# 拆成两个节点只会让日志里多两行「构建执行」，出问题时还得自己拼回去看。
# 【v.108.23】listen_uri（容器内 LAPI 对外监听地址）也并进来：它和 acquis 一样，
# 都是「容器内 crowdsec 起来之前必须就位的静态配置」。放在三处之外单干的结果是
# 容易漏 —— 漏了的表现是 bouncer 永远拉不到，而日志里看不出少做了什么。
# 现在 logconf 一个节点承诺三件事，缺一不可：
#   ① 宿主把 syslog 推给容器（log_forward）
#   ② 容器用 acquisitions 收并解析（acquis）
#   ③ 容器内 LAPI 监听 0.0.0.0:PORT，路由器上的 bouncer 才连得上（listen_uri）
DEP_logconf="ct_boot ct_net"
DEP_lapi_fetch="ct_boot"
DEP_bouncer_fill="lapi_fetch logconf"
DEP_bouncer_verify="bouncer_fill"
DEP_capi_release="bouncer_verify"
# ---- ENROLL：console 注册（v.108.49 补的节点，之前这一组是空壳）----
# 依赖 capi_release：capi_block 在容器启动前把 online_client 注释掉，bouncer 验证通过
# 后由 capi_release 放回来；注册要连中央 API，必须等它放出来之后再做。
# 【v.180.86】再加 deps 依赖：注册要连中央 API，网络必须真的通、必备组件必须齐。
# 流程图里 enroll 就排在「检查网络」之后 —— 网络异常时 DEPS 组不置位，enroll 自动跳过。
DEP_enroll="capi_release deps"
# ---- DEPS：网络检查 + 必备组件补齐（v.180.85，v.180.86 提到 ENROLL 之前）----
# 故意不依赖任何组：前置组失败了它也要跑 —— 「网络好了就把 lxc/smartdns 装上」这件事
# 与容器流程成功与否无关。
# 位置按流程图定：容器流程之后、enroll 之前。enroll 要靠它联网注册，所以它是 enroll 的前置；
# 网络异常时本组不置位 → enroll 整组跳过 → 本轮就此结束（不判失败）。
DEP_deps=""

# INSTALL 排第一：rootfs 解压是 ct_net / ct_bootlink / ct_resolv（写容器内文件）
# 以及 capi_block / ct_boot 的硬前置。放在 PREP 之后时，PREP 里那些节点拿不到
# rootfs → 失败 → hard 终止 → INSTALL 永不执行 → rootfs 永不解压（自锁）。
GROUP_SEQ="NETBASE INSTALL PREP CAPIBLOCK BOOT LOGCONF LAPI BOUNCERVERIFY DEPS SMARTCHK ENROLL"
GROUP_TITLE_NETBASE="网络基线（br-lan / lxcbr0 双网桥 + 防火墙 zone 与转发规则 + smartdns 接管 53），最优先执行，不依赖 rootfs"
GROUP_TITLE_INSTALL="安装容器（迁移校验镜像 / 解压 rootfs / 写 config）"
GROUP_TITLE_PREP="容器启动前的全部静态准备（路由器网桥 / 容器网络 / cgroup）"
GROUP_TITLE_CAPIBLOCK="屏蔽 CAPI（容器内 online_client 停用）"
GROUP_TITLE_BOOT="启动容器（唯一一次开机）"
GROUP_TITLE_LOGCONF="日志链路与对外监听（宿主推送 + 容器采集 + LAPI 监听地址）"
GROUP_TITLE_LAPI="获取 LAPI 并填入路由器 bouncer"
GROUP_TITLE_BOUNCERVERIFY="验证 bouncer 列表生效并解开 CAPI"
GROUP_TITLE_ENROLL="Console Enroll"
GROUP_TITLE_DEPS="只验证不安装（网络是否通 / lxc 与 smartdns 是否就位）——排在容器流程与 bouncer 校验之后、enroll 之前；未就绪则 enroll 跳过"
GROUP_TITLE_SMARTCHK="smartdns 运行态验证（容器跑起来之后再看 53 是否真在服务、容器内能否解析）"
# 组间强依赖只有一条主线：容器启动前必须先备好网桥/容器网络/cgroup，
# 启动后才有运行态可言。其余组按功能细分，依赖如实声明（不强加线性）。
GROUP_DEP_INSTALL=""
GROUP_DEP_NETBASE=""
GROUP_DEP_PREP="NETBASE INSTALL"
GROUP_DEP_CAPIBLOCK="INSTALL PREP"
GROUP_DEP_BOOT="NETBASE PREP INSTALL CAPIBLOCK"
GROUP_DEP_LOGCONF="BOOT"
GROUP_DEP_LAPI="BOOT"
GROUP_DEP_BOUNCERVERIFY="LOGCONF LAPI"
GROUP_DEP_ENROLL="SMARTCHK"
GROUP_DEP_DEPS="BOUNCERVERIFY"
GROUP_DEP_SMARTCHK="DEPS"
NODE_GROUP_img_migrate=INSTALL
NODE_GROUP_rootfs=INSTALL
NODE_GROUP_ct_config=INSTALL
NODE_GROUP_br_lan_ports=NETBASE
NODE_GROUP_lan_static=NETBASE
NODE_GROUP_dhcp_ignore=NETBASE
NODE_GROUP_smartdns=NETBASE
NODE_GROUP_bridge=NETBASE
NODE_GROUP_ct_net=PREP
NODE_GROUP_cgroup_mount=PREP
NODE_GROUP_ct_bootlink=PREP
NODE_GROUP_lxc_auto=NETBASE
NODE_GROUP_ct_resolv=PREP
NODE_GROUP_lxc_zone=NETBASE
NODE_GROUP_fwd_rules=NETBASE
NODE_GROUP_lan_input=NETBASE
NODE_GROUP_snat=NETBASE
NODE_GROUP_ip_forward=NETBASE
NODE_GROUP_svc_bind=NETBASE
NODE_GROUP_docker_fw=NETBASE
NODE_GROUP_capi_block=CAPIBLOCK
NODE_GROUP_ct_boot=BOOT
NODE_GROUP_logconf=LOGCONF
NODE_GROUP_lapi_fetch=LAPI
NODE_GROUP_bouncer_fill=LAPI
NODE_GROUP_bouncer_verify=BOUNCERVERIFY
NODE_GROUP_capi_release=BOUNCERVERIFY
NODE_GROUP_enroll=ENROLL
NODE_GROUP_deps=DEPS
NODE_GROUP_pkg_base=NETBASE
NODE_GROUP_sd_serve=SMARTCHK

# 层级拓扑排序（v.79）：先校验「每个小步骤都对应到某个组、组间依赖不倒置」，
# 再按 GROUP_SEQ 分段，段内 Kahn 变体迭代排序（无递归，天然检测环/缺失/跨组依赖倒置）
dag_order() {
    _order=""
    # 校验 1：每个小步骤都必须声明归属（NODE_GROUP_<node>），且归属的组在序列中
    for _n in $DAG_NODES; do
        _ng=$(eval "echo \$NODE_GROUP_$_n")
        if [ -z "$_ng" ]; then
            log "[DAG] 小步骤 $_n 未声明归属组（NODE_GROUP_$_n 缺失），终止"
            exit 1
        fi
        case " $GROUP_SEQ " in
            *" $_ng "*) ;;
            *) log "[DAG] 小步骤 $_n 归属的组 $_ng 不在 GROUP_SEQ 中，终止"; exit 1 ;;
        esac
    done
    # 校验 2：组间依赖不得倒置——GROUP_DEP 里的组必须排在本组之前（否则环/死等）
    _gseen=""
    for _g in $GROUP_SEQ; do
        for _gd in $(eval "echo \$GROUP_DEP_$_g"); do
            case " $_gseen " in
                *" $_gd "*) ;;
                *) log "[DAG] 组 $_g 绑定 $_gd，但 $_gd 未排在其之前（组依赖环/倒置），终止"; exit 1 ;;
            esac
        done
        _gseen="$_gseen $_g"
    done
    # 按组分段，段内拓扑排序；前置组的节点已在 _order 中，跨组依赖天然满足
    _gprev=""
    for _g in $GROUP_SEQ; do
        _gnodes=""
        for _n in $DAG_NODES; do
            [ "$(eval "echo \$NODE_GROUP_$_n")" = "$_g" ] && _gnodes="$_gnodes $_n"
        done
        _remaining="$_gnodes"
        while [ -n "$_remaining" ]; do
            _progress=0
            _next=""
            for _n in $_remaining; do
                _ready=1
                for _d in $(eval "echo \$DEP_$_n"); do
                    _dg=$(eval "echo \$NODE_GROUP_$_d")
                    if [ "$_dg" != "$_g" ]; then
                        case " $_gprev " in
                            *" $_dg "*) continue ;;
                            *) _ready=0; break ;;
                        esac
                    fi
                    case " $_order " in *" $_d "*) ;; *) _ready=0; break ;; esac
                done
                if [ "$_ready" = 1 ]; then
                    _order="$_order $_n"
                    _progress=1
                else
                    _next="$_next $_n"
                fi
            done
            _remaining="$_next"
            if [ "$_progress" = 0 ]; then
                log "[DAG] 组 $_g 内依赖环或跨组依赖未就绪（剩余：$_remaining），终止"
                exit 1
            fi
        done
        log "[DAG] 组 $_g 就序（$(echo $_gnodes | wc -w | tr -d ' ') 个小步骤）"
        _gprev="$_gprev $_g"
    done
    log "[DAG] 层级拓扑序已生成（$(echo $GROUP_SEQ | wc -w | tr -d ' ') 个组 / $(echo $_order | wc -w | tr -d ' ') 个小步骤）"
}

# 调度器（v.79 统一 ensure + hard，迭代式无递归）：
#   依赖未就绪 → 跳过本级并沿链传播（跳过即未完成，下游连带跳过）
#   verify 就绪 → 跳过；否则 build + 复核，至多两次
#   两次均未通过（build 失败或复核仍不符）→ hard 失败，立即终止引导
#   （半就绪状态继续引导比开机失败更危险：SNAT/防火墙缺项的容器会裸奔）
# 只验不写清单（v.95 起已清空）：
#   历史原因——网络/防火墙节点曾一律只验证、不修改，因为它们由 LuCI 生成，
#   改完不 reload 不生效，反而会把用户配好的东西覆盖成「看似正确却不工作」。
#   现改为「验证 + 修改 + commit + 分组 reload」，真正生效，因此不再需要这份清单。
#   保留变量与分支结构是为了：① 万一将来某项要退回只读，加回名字即可；
#   ② ensure() 的 else 分支仍可被测试覆盖。空清单 = 所有节点都会尝试修复。
RO_ONLY_NODES=""

# =====================================================================
# 置位的值带「分类 + 时间」（v.99）
# =====================================================================
# 【为什么不再只写 1】置位原来一律是 `=1`，于是三个问题：
#   ① 看日志只知「置过了」，不知「什么时候、因为什么置的」；
#   ② 退出恢复时打印 done=29 dirty=12，全是数字，看不出是哪几个、分别什么时候置的；
#   ③ 光有 1 分不清「verify 本来就过」和「build 改回来的」——排障时这两者含义差很远。
# 现在置位的值是一个带分类前缀的时间戳：
#   V:<ts>  verified  进场 verify 直接通过，没有任何写入
#   B:<ts>  built     build 真的改了一处（时间戳 = 改动时刻）
#   R:<ts>  ro        RO_ONLY_NODES 里、脚本不代改，只登记待办
# 用法上等价于布尔：非空即真，空串（归零）即假。
# 时间戳与 stamp 文件同格式 `%F %T`，正则同构，grep 一遍就能按天/按时段筛日志。
# 取本地时区（不是 UTC）：这玩意儿是给人看日志用的，「几点置的」当然是按墙上时钟。
# 【必须用双引号】单引号同样被吞：本脚本前面已有函数定义，dash 会把
# `X='%F %T'` 解析成「赋值 X=空 + 命令 '%F %T'」，实跑报 `%T: not found`，
# 变量最终是空串——一个不会报错、只会让时间戳变成空白的隐蔽 bug。
# 不加引号也一样错，所以这里用双引号（无变量展开，等价于字面量）。
_FLAG_TS_FMT="%F %T"
_BS_FLAG_NOW() { date "+$_FLAG_TS_FMT"; }
_bs_flag_set() {   # _bs_flag_set <变量名> <分类:V|B|R>
    eval "_bs_ts=\$(date \"+\$_FLAG_TS_FMT\")"
    eval "$1='$2:'\"\$_bs_ts\""
}
_bs_flag_clear() { eval "$1=''"; }   # 空串 = 未置位（≡ 原来的 0）
# 是否已置位。用 printf | grep 而不是 case 模式：
# 时间戳里带冒号空格，case 要额外转义，容易写错；这里只判「非空」。
_bs_flag_on() {
    printf '%s' "$(eval "printf '%s' \"\${$1:-}\"")" | grep -q . 2>/dev/null
}
# 取分类字符：V / B / R，未置位时输出空
_bs_flag_tag() {
    _bt_v=$(eval "printf '%s' \"\${$1:-}\"")
    printf '%s' "$_bt_v" | cut -c1
}
# 按分类计数：_bs_flag_count <D|B|R> <变量名...>
#   D = 已置位（不分类别），B = built，R = ro
_bs_flag_count() {
    _bc_want=$1; shift
    _bc_n=0
    for _bc_v in "$@"; do
        _bs_flag_on "$_bc_v" || continue
        case "$_bc_want" in
            D) _bc_n=$((_bc_n+1)) ;;
            *) [ "$(_bs_flag_tag "$_bc_v")" = "$_bc_want" ] && _bc_n=$((_bc_n+1)) ;;
        esac
    done
    printf '%s' "$_bc_n"
}
# 列出已置位的名字与时间（带分类），供退出日志一行打全
_bs_flag_dump() {
    _bd_out=""
    for _bd_v in "$@"; do
        _bs_flag_on "$_bd_v" || continue
        _bd_out="$_bd_out ${_bd_v}=$(eval "printf '%s' \"\${$_bd_v}\"")"
    done
    printf '%s' "$_bd_out"
}

# 首次装机判定（v.108.33）：没有 installed 标记 = 这台机器还没完整跑通过一轮。
# 只读，不写文件、不动任何标记，也不改流程 —— 只回答一个窄问题：
# 「现在能不能等一个还不存在的东西」。重装（标记被清）也算首次装机，因为它确实要从头等。
_first_install() { ! _stamp_present; }

# 构建后复核的豁免名单（v.108.33，v.108.34 增补 capi_block）。默认全都复核：
# build 返回 0 只代表命令没报错。
#
# ① bouncer_verify：只在首次装机时豁免 —— 它等的是 bouncer 的首次心跳，
#    装机那一刻心跳必然还没有，这正是 v.108.21 把它列进 SOFT_NODES 的原因。
#    重启态不给豁免：那时 bouncer 早该在拉了，验不过就是真有问题。
#
# ② capi_block：**永远豁免**，因为它和 capi_release 是同一处配置的两个互斥状态：
#      capi_block   → 容器启动前把 config.yaml 的 online_client 注释掉（要求 off）
#      capi_release → bouncer 验证通过后把它放回来（要求 on）
#    收尾复核发生在 DAG 全部跑完之后，那一刻按设计就是「已放出」，拿 off 去判
#    必然不符。首台真机实测（v.108.34）：capi_block 是唯一不符节点 → exit 1 →
#    置位全部归零 → installed 不写 → 探针【补印】分支每 5 分钟重跑一次全量引导
#    → 每轮重建一次 lxcbr0 → veth 被反复甩掉。这就是「重跑副作用」的真身。
#    capi_block 的时序义务由 DEP_ct_boot 的硬前置保证（不 off 就不许启容器），
#    「真的没写成」由 build_capi_block 内部的立即复核当场抓，收尾不必再判一次。
_post_verify_skip() {
    case " $1 " in
        *" bouncer_verify "*)
            _first_install && return 0
            ;;
        *" capi_block "*)
            return 0
            ;;
    esac
    return 1
}

# 复核不是「验一次就判死」：uci 改完到生效有延迟（dropbear reload、网桥地址），
# 验一次不中不代表没写成。3 次、每次间隔 1 秒，仍不中才算没写成。
_post_verify_confirm() {
    _pv_n=0
    while [ "$_pv_n" -lt 3 ]; do
        "verify_$1" 2>/dev/null && return 0
        _pv_n=$((_pv_n + 1))
        [ "$_pv_n" -ge 3 ] && return 1
        sleep 1
    done
    return 1
}

# 收尾复核（v.108.33）：本轮 build 过的节点，在 flush 之后必须真的生效。
# 为什么放在收尾而不是 build 旁边：build 只写 uci 内存，commit/reload 在 flush_uci，
# 落地之前的 verify 结论不可信（查内核地址、端口监听的必然不符）。
# 为什么还要再 flush 一次：阶段 3（LOG_CONF/LAPI/ENROLL）的改动不一定走过 flush，
# 首轮不符可能只是没落地。先落地再验，仍不符才算「写了没生效」。
_post_verify_after_boot() {
    _pva_bad=""
    for _pva_n in $_built_nodes; do
        if _post_verify_skip "$_pva_n"; then
            # v.108.41：两种情况豁免理由不同，日志不能共用一句话（原来 capi_block
            # 会打成「等首次心跳」，看日志的人会去查一个根本不存在的 bouncer 心跳）。
            case " $_pva_n " in
                *" capi_block "*)
                    log "[复核][$_pva_n] 与 capi_release 互斥，收尾不再判（终态由 capi_release 决定）"
                    ;;
                *)
                    log "[复核][$_pva_n] 首次装机：跳过（等首次心跳的柔性节点）"
                    ;;
            esac
            continue
        fi
        _post_verify_confirm "$_pva_n" || _pva_bad="$_pva_bad $_pva_n"
    done
    if [ -z "$_pva_bad" ]; then
        log "[复核] 本轮构建的节点全部生效（$(_count_words "$_built_nodes") 个）"
        return 0
    fi
    log "[复核] 首轮不符：$_pva_bad，落地后再验一次"
    flush_uci >/dev/null 2>&1 || log "[复核] 复验前的 flush 有失败项，见上方 [flush] 行"
    _pva_bad2=""
    for _pva_n in $_pva_bad; do
        if _post_verify_confirm "$_pva_n"; then
            log "[复核][$_pva_n] 落地后生效"
        else
            _pva_bad2="$_pva_bad2 $_pva_n"
        fi
    done
    if [ -z "$_pva_bad2" ]; then
        log "[复核] 复验后全部生效"
        return 0
    fi
    for _pva_n in $_pva_bad2; do
        case " $SOFT_NODES " in
        *" $_pva_n "*)
            log "[复核][$_pva_n] 属柔性节点，记账后继续；长期监视交给探针"
            _failed="$_failed $_pva_n"
            continue
            ;;
        esac
        log "[复核][$_pva_n] 构建后始终不符（写了没生效）"
        _failed="$_failed $_pva_n"
        return 1
    done
    return 0
}

# 数词（只用来打日志）
_count_words() {
    set -- $1
    echo $#
}

ensure() {
    _o=$1
    _O=$(echo "$_o" | tr 'A-Z' 'a-z')
    # 【v.108.24】不再用 _done_ 短路。
    # 原来第一行是 `_bs_flag_on "_done_$_o" && return 0`：只要上一轮（或本轮早些时候）
    # 留下过完成标记，就直接认定没问题，连现场都不看。于是「上次跑过、这次配置被改回去了」
    # 这类情况永远发现不了 —— 标记说做了，现场说没做。
    # 现在不论第几次跑，一律先 verify 现场：达标就过（并补记 _done_），不达标就 build。
    # _done_ 退化为「本轮已就绪」的记账，只供退出汇总和组置位使用，不再决定是否验证。
    # 每条语句都必须是「配置一致性」判断，不能退化成「接口/文件在不在」：
    # 网桥要比 ports 集合、lan 要比 ipaddr/netmask/gateway/dns、删掉的项要确认真的没了。
    for _d in $(eval "echo \$DEP_$_o"); do
        case " $_failed " in
            *" $_d "*)
                log "[$_O] 依赖 $_d 未就绪，跳过本级"
                _failed="$_failed $_o"
                return 1
                ;;
        esac
    done
    if "verify_$_o" 2>/dev/null; then
        log "[$_O] 验证通过，跳过"
        _bs_flag_set "_done_$_o" V
        return 0
    fi
    case " $RO_ONLY_NODES " in
        *" $_o "*)
            log "[$_O] 验证未通过（该节点被列入 RO_ONLY_NODES，脚本不做写入）"
            log "[待办] $_o 需在 LuCI 侧补正，脚本不做任何写入"
            case " $_ro_missing " in *" $_o "*) : ;; *) _ro_missing="${_ro_missing:-} $_o" ;; esac
            _bs_flag_set "_done_$_o" R
            return 0
            ;;
    esac
    _build_ok=1
    if ! "build_$_o" 2>/dev/null; then
        log "[$_O] 构建执行失败"
        _build_ok=0
    fi
    # 【v.108.33】这里**不做**复核，是有原因的：build_* 大多只写 uci 内存态，
    # commit/reload 统一在 flush_uci 里。此刻就去 verify 内核地址、端口监听的节点，
    # 必然全部不符 —— 那会把正常机器判死。复核点放在 flush 之后（_post_verify_after_boot）。
    if [ "$_build_ok" = "0" ]; then
        # 【v.108.21】柔性节点：不中止引导。判据是「前置环节已硬性把关，这里只差时机」，
        # 不是「修不好也没关系」。bouncer_verify 就是这类：8080 已由 LAPI 组验证，
        # 它只等 bouncer 首次心跳；等不到不该让整轮引导死掉、连 installed 都不写。
        case " $SOFT_NODES " in
        *" $_o "*)
            log "[$_O] 属柔性节点（SOFT_NODES=$SOFT_NODES）：不中止引导，记账后继续；长期监视交给探针"
            _failed="$_failed $_o"
            return 1
            ;;
        esac
        # 【v.108.17 口径：不看日志，直接重置】
        # build 修不好时先分辨两种性质，别一律 hard：
        #   · 资产残缺（rootfs 缺 /etc、缺 crowdsec.service、无 init、容器目录不可写）
        #     —— 重装有意义，交给 full_reinstall。它自己还有四道门：installed 标记、
        #     连续失败计数（REINSTALL_MAX=2）、防递归、镜像 gzip 完好。
        #   · 脚本能力对不上现场（配置写不进去、判据不成立）—— 维持 hard：同一套脚本
        #     重跑只会把同样的失败再走一遍，还要先抹掉现场证据。
        # 这条判断只读不写（除了 _structurally_broken 里那次 mkdir -p，本来就幂等）。
        if _stamp_present && _structurally_broken; then
            log "[$_O] 属结构性损坏（资产残缺），转入彻底重装"
            full_reinstall || log "[$_O] 重装未接管（条件不满足，原因见上方 [重装] 行），维持 hard 终止"
        fi
        log "[$_O] 构建执行失败，hard 失败，引导终止"
        _failed="$_failed $_o"
        exit 1
    fi
    log "[$_O] 已构建"
    _bs_flag_set "_dirty_$_o" B
    _bs_flag_set "_done_$_o" B
    return 0
}
# 强制重建某节点（enroll 段 SNAT 修复用）。
# 【v.108.24】ensure 已经不看 _done_、每次都先验现场，清标记再跑是同一件事，
# 这里直接等同 ensure —— 保留函数名只为调用点可读。
rebuild() {
    ensure "$1"
}
# 组调度（v.79 层级）：组间绑定——GROUP_DEP 绑定的前置组任一失败，
# 本组整组跳过（如 boot 绑 net：容器网络/路由器网桥没就绪就不启动容器）；
# 组内小步骤逐个 ensure，统计完成度并打组边界日志；组失败只标记+传播，是否终止由小步骤 FMODE 定
ensure_group() {
    _g=$1
    _G=$(echo "$_g" | tr 'a-z' 'A-Z')
    for _gd in $(eval "echo \$GROUP_DEP_$_g"); do
        _GD=$(echo "$_gd" | tr 'a-z' 'A-Z')
        if ! _bs_flag_on "GSET_$_gd"; then
            log "[$_G] 前置组 $_GD 未置位（GSET_$_gd 为空），本组不执行"
            _group_failed="$_group_failed $_g"
            return 1
        fi
    done
    _gt=$(eval "echo \$GROUP_TITLE_$_g")
    _gn=0
    for _n in $_order; do
        [ "$(eval "echo \$NODE_GROUP_$_n")" = "$_g" ] && _gn=$((_gn+1))
    done
    log "---- 组 $_G（$_gt）：$_gn 个小步骤 ----"
    _gok=0
    for _n in $_order; do
        [ "$(eval "echo \$NODE_GROUP_$_n")" = "$_g" ] || continue
        ensure "$_n" && _gok=$((_gok+1))
    done
    if [ "$_gok" = "$_gn" ]; then
        _bs_flag_set "GSET_$_g" V
        log "[$_G] $_gt 完成（$_gok/$_gn），置位 GSET_$_g=$(eval "printf '%s' \"\${GSET_$_g}\"")"
    else
        log "[$_G] $_gt 未完成（$_gok/$_gn），不置位，后续依赖组将跳过"
        # _ro_missing 由 ensure() 以「空格 + 节点名」拼接，全空时是空串而不是空格，
        # 所以这里 trim 后判空；原先写 "  "|" " 两个模式永远匹配不到（SC2195）。
        if [ -n "$(printf '%s' "$_ro_missing" | tr -d ' \t')" ]; then
            log "[$_G] 以下节点验证未通过且脚本不代改（请在 LuCI 核对）：$_ro_missing"
        fi
        _group_failed="$_group_failed $_g"
    fi
    return 0
}

# 编译结果自检（v.108.50）：uci 里写了 proto=all ≠ nft 里真的没有协议限制。
# 真机踩过的坑（v.108.48 之前）：config rule 不写 option proto 时 fw4 默认按 tcpudp
# 编译，一条规则被拆成 tcp + udp 两条，ICMP/ESP/GRE 全落在规则外 ——
# uci show 一条不少、日志全绿，容器却出不去。
# 这里只报告、不参与判定：刚写完还没 reload 时看到的是旧表，拿来判死会误杀。
_nft_fw_report() {
    _nft_reported=1
    command -v nft >/dev/null 2>&1 || return 0
    if ! run nft list chain inet fw4 forward_lxc >/dev/null 2>&1; then
        log "[FW] 未找到 nft 链 forward_lxc（zone 未绑 lxcbr0 或 firewall 未生成）"
        return 0
    fi
    _nr=$(run nft list chain inet fw4 forward_lxc 2>/dev/null | grep -c 'meta l4proto')
    _nr=${_nr:-0}
    if [ "$_nr" -gt 0 ]; then
        log "[FW] 警告：forward_lxc 里仍有 $_nr 条带 l4proto 的规则 → ICMP/ESP/GRE 会被漏掉，检查 proto=all 是否真的写进去"
    else
        log "[FW] forward_lxc 无协议限制（proto=all 已生效，ICMP 可通）"
    fi
    return 0
}

# 分组 flush（v.95：验证 + 修改语义）：按 DAG 收集的 _dirty_* 决定 commit / reload，
# 每组至多一次。commit 只把内存改动落到 /etc/config/*，reload 才让运行中的进程读到新值，
# 两者必须成对：
flush_uci() {
    _n=0; _d=0; _f=0; _s=0
    _fu_bad=""
    # 判「脏」即「非空」：值现在是 B:<时间戳>，不再是 1
    for _o in br_lan_ports lan_static bridge; do
        _bs_flag_on "_dirty_$_o" && _n=1
    done
    for _o in dhcp_ignore; do
        _bs_flag_on "_dirty_$_o" && _d=1
    done
    # smartdns 单独一档：它要 commit 两份配置（smartdns + dhcp），还要「先让 dnsmasq
    # 放 53、再拉 smartdns、起不来就还回去」，跟单纯的 commit+reload 不是一回事。
    for _o in smartdns; do
        _bs_flag_on "_dirty_$_o" && _s=1
    done
    for _o in lxc_zone fwd_rules lan_input snat docker_fw; do
        _bs_flag_on "_dirty_$_o" && _f=1
    done

    # ---- network：桥/地址/端口，reload 才让 netifd 重建接口 ----
    if [ "$_n" = 1 ]; then
        if run uci -q commit network; then
            log "[flush] network 已提交，执行 reload"
        else
            _fu_bad="$_fu_bad network-commit"
            log "[flush] network 提交失败：改动只在内存里，重启即丢"
        fi
        if run_svc /etc/init.d/network reload >/dev/null 2>&1; then
            log "[flush] network 已重载"
            # 【首台真机 2026-10-22 现场】netifd reload 会按 uci 重建 lxcbr0：
            # 网桥被拆了重加，而容器已经在跑 —— LXC 只在 lxc-start 时插 veth，
            # 没有任何东西会把端口接回去。结果就是现场那副样子：
            #     lxcbr0: <NO-CARRIER,UP> inet 10.1.0.1/24 state DOWN
            #     容器侧 eth0 有 IP、LAPI 在 :::8080 上 LISTEN
            #     宿主 ping 10.1.0.10 100% 丢包、curl 等 2.6 秒才 Failed to connect
            # 后面所有「LAPI 探测不通」的日志都是这一条的下游症状，别被它带偏。
            _reattach_ct_veth
        else
            _fu_bad="$_fu_bad network-reload"
            log "[flush] network 重载失败（配置已落盘，下次网络重载/重启仍生效）"
        fi
    fi

    # ---- dhcp：dnsmasq 需 restart 才读取新配置（reload 不够彻底）----
    if [ "$_d" = 1 ]; then
        if run uci -q commit dhcp; then
            log "[flush] dhcp 已提交，重启 dnsmasq"
        else
            _fu_bad="$_fu_bad dhcp-commit"
            log "[flush] dhcp 提交失败：改动只在内存里，重启即丢"
        fi
        if run_svc /etc/init.d/dnsmasq restart >/dev/null 2>&1; then
            log "[flush] dnsmasq 已重启"
        else
            _fu_bad="$_fu_bad dnsmasq-restart"
            log "[flush] dnsmasq 重启失败（配置已落盘，下次重启仍生效）"
        fi
    fi

    # ---- firewall：reload 会重建整张 nft 表，上一组改动在此刻真正生效 ----
    if [ "$_f" = 1 ]; then
        if run uci -q commit firewall; then
            log "[flush] firewall 已提交，执行 reload"
        else
            _fu_bad="$_fu_bad firewall-commit"
            log "[flush] firewall 提交失败：改动只在内存里，重启即丢"
        fi
        if run_svc /etc/init.d/firewall reload >/dev/null 2>&1; then
            log "[flush] firewall 已重载（nft 表已重建）"
            _nft_fw_report
        else
            _fu_bad="$_fu_bad firewall-reload"
            log "[flush] firewall 重载失败（配置已落盘，下次重载/重启仍生效）"
        fi
    fi

    # ---- smartdns：接管 53（先让 dnsmasq 退，再拉 smartdns）----
    # 顺序不能反：dnsmasq 还占着 53 时 smartdns 绑不上。
    # 配置全由 uci 写出（主段 port=53、13 个上游、dnsmasq port=0），不存在「起不来」
    # 的情况，所以这里不做「绑不上 53 就把端口还给 dnsmasq」的回滚 —— 那是多余分支。
    if [ "$_s" = 1 ]; then
        if run uci -q commit smartdns; then
            log "[flush] smartdns 已提交"
        else
            _fu_bad="$_fu_bad smartdns-commit"
            log "[flush] smartdns 提交失败：改动只在内存里，重启即丢"
        fi
        if run uci -q commit dhcp; then
            log "[flush] dhcp 已提交（dnsmasq 的 DNS 端口置 0）"
        else
            _fu_bad="$_fu_bad dhcp-commit"
            log "[flush] dhcp 提交失败：改动只在内存里，重启即丢"
        fi
        # ① dnsmasq 先松手（给它 1 秒真正放开 53，别让 smartdns 撞端口）
        run_svc /etc/init.d/dnsmasq restart >/dev/null 2>&1 \
            || log "[flush] dnsmasq 重启失败"
        sleep "${SD_RELEASE:-1}"
        # ② 拉 smartdns，并确保开机自启（否则重启后 53 空着，整机没 DNS）
        run /etc/init.d/smartdns enable >/dev/null 2>&1
        run_svc /etc/init.d/smartdns restart >/dev/null 2>&1 \
            || log "[flush] smartdns 重启失败"
        # ③ 等服务真正把 53 接下来。删掉的是「绑不上就回滚」那段，不是这里的等待 ——
        #    紧接着的收尾复核（_post_verify）会重放 verify_smartdns，太早读只能读到
        #    「进程刚 fork、还没 listen」。默认 2 秒，可用 SD_SETTLE 覆盖。
        sleep "${SD_SETTLE:-2}"
        log "[flush] smartdns 已接管 53（dnsmasq 只剩 DHCP/RA）"
    fi

    # 清脏标记：把 DAG 里所有网络/服务侧节点全扫一遍，比手写清单更抗漏。
    # （原先手写清单漏过 bridge / svc_bind，残留脏标记会让下一轮多 reload 一次。）
    for _o in $DAG_NODES; do
        # 【v.108.33】清之前先记一笔：这一轮到底 build 过谁。收尾复核按这份名单走，
        # 不能按 _done_ 走（_done_ 里还有本轮本来就没问题的节点，复核它们纯属浪费）。
        if _bs_flag_on "_dirty_$_o"; then
            # 【v.108.52】去重：flush_uci 一轮里会被调用不止一次（收尾复核前还要再 flush），
            # 真机日志出现过 `[复核] 首轮不符： ct_net ct_net`，重复项让「不符 N 个」虚高，
            # 也让同一个节点被复验两次、白等一轮。
            case " $_built_nodes " in
                *" $_o "*) ;;
                *) _built_nodes="$_built_nodes $_o" ;;
            esac
        fi
        _bs_flag_clear "_dirty_$_o"   # v.99：置位值是 B:<ts>，归零 = 清空（写 0 会被判成脏）
    done
    [ "$_n$_d$_f$_s" = "0000" ] && log "[flush] 无配置改动，零 commit、零 reload"
    # 提交/重载失败必须能被上层看见：--net-only 据此 exit 1，不再「日志写了失败、
    # 退出码却是 0」。commit 失败尤其严重——改动只在内存里，重启就没了。
    if [ -n "$_fu_bad" ]; then
        log "[flush] 以下动作失败：$_fu_bad"
        return 1
    fi
    return 0
}

# ---- install 类节点 verify/build ----
# 镜像完整性（v.79：不只验文件名——半截 tarball 会漏判为「已就绪」，解压才炸）
verify_img_migrate() {
    # 【v.108.56】overlay 模式：容器来自 /rom 只读基底，不存在「要迁移镜像包」这回事。
    # 少了这一条，img_migrate 节点每轮都因「无 tarball」判失败，而它不在 SOFT_NODES，
    # 一轮就 hard exit —— 表现为「固件正常、容器永不启动」，且日志只说无镜像可迁移。
    [ -d "$ROM_BASE" ] && return 0
    [ -f "$TARBALL" ] || return 1
    # gzip -t 做全量 CRC 校验：包被截断或写坏这里直接不过，比只数目录名可靠
    gzip -t "$TARBALL" >/dev/null 2>&1 || return 1
    # 再确认这确实是 rootfs 包：前 200 条里出现任一顶层目录即可。
    # 原来要求 etc/ 与 usr/ 同时出现——tar 是深度优先打包（-C "$R" .），./usr 排在
    # ./etc 的上万条文件之后，前 200 条里永远看不到它，于是完好的包被判成半截，
    # verify 每轮都不过、build 又认定包完整直接 return 0，容器于是永远建不起来。
    run_tar tar -tzf "$TARBALL" 2>/dev/null | head -n 200 | grep -qE '^(\./)?(etc|usr|bin|lib)/'
}
build_img_migrate() {
    if [ -f "$TARBALL" ]; then
        gzip -t "$TARBALL" >/dev/null 2>&1 && return 0
        log "镜像文件损坏（gzip 完整性校验失败），删除后重新迁移"
        rm -f "$TARBALL"
    fi
    # 运行副本缺失/损坏：先从只读基准 /rom 恢复。squashfs 挂的是 ro，原件改不掉也
    # 删不掉，比任何放在可写层的备份都硬；副本被 rm 时 upper 只有 whiteout，cp 回去
    # 会直接把 whiteout 顶掉。非 squashfs 平台没有该路径，这段自动跳过。
    if [ -f "/rom$TARBALL" ]; then
        mkdir -p "$CS_HOME" 2>/dev/null
        cp -f "/rom$TARBALL" "$TARBALL" 2>/dev/null \
            && gzip -t "$TARBALL" >/dev/null 2>&1 \
            && { log "镜像已从 /rom 恢复：$TARBALL"; return 0; }
        rm -f "$TARBALL"
        log "从 /rom 恢复失败（写不进 overlay 或包本身有问题）"
    fi
    [ -f "$LEGACY_TARBALL" ] || { log "无镜像可迁移"; return 1; }
    mkdir -p "$CS_HOME" 2>/dev/null && mv -f "$LEGACY_TARBALL" "$TARBALL" 2>/dev/null \
        && log "镜像已从 $LEGACY_TARBALL 迁移到 $TARBALL"
}
# 容器 config 内容完整性（v.79：半截 config 会让启动链判据误判「在位」→ 开机即失败）
# v.108：不再硬查 lxc.utsname。apply_cfg 的裁剪循环会按 `lxc-info` 报错里
# `at line "..."` 的内容把该行整行 grep -v 掉（LXC 6.x 已改用 lxc.uts.name，
# 旧键会被判无效），而这里若同时硬要求 lxc.utsname 存在，就形成
# 「build 删键 → verify 不过 → 再 build 再删」的死循环，BOOT 组每轮 hard 失败、
# 容器永远起不来。判据改为「两份键在 + lxc 自己能把这份 config 解析出来」。
verify_ct_config() {
    [ -s "$CFG" ] || return 1
    grep -q "lxc.rootfs.path" "$CFG" 2>/dev/null || return 1
    grep -q "lxc.net.0.type" "$CFG" 2>/dev/null || return 1
    if command -v lxc-info >/dev/null 2>&1; then
        _vcc=$(run lxc-info -P "$LXC_PATH" -n "$LXC_NAME" 2>&1)
        printf '%s\n' "$_vcc" | grep -q 'at line "' && return 1
    fi
    return 0
}
build_ct_config() {
    rm -f "$CFG"                       # 删旧建新：内容不一致时不用半截旧文件垫底
    write_cfg || { log "容器 config 写入失败"; return 1; }
    log "已写入容器 config"
    apply_cfg || { log "config 无法解析"; return 1; }
}
# rootfs 完整性（v.79：CROWDSEC_CFG 需含 crowdsec config 必备段，半截文件判不符）
verify_rootfs() {
    # overlay 模式：挂着 + stamp 对得上就算就绪。内容由只读 lower 保证，
    # 不必再逐文件验 —— os-release 恒在，拿它当判据在这里已经失去意义。
    if _overlay_mounted; then
        _upper_stamp_ok && return 0
    fi
    [ -d "$ROOTFS/etc" ] || return 1
    [ -d "$ROOTFS/usr" ] || return 1
    [ -s "$ROOTFS/etc/os-release" ] || return 1
    grep -q '^ID=' "$ROOTFS/etc/os-release" 2>/dev/null || return 1
    [ -s "$CROWDSEC_CFG" ] || return 1
    grep -q "api:" "$CROWDSEC_CFG" 2>/dev/null || return 1
    grep -q "common:" "$CROWDSEC_CFG" 2>/dev/null || return 1
}
build_rootfs() {
    log "rootfs 未就绪，开始重建"
    # 首选：/rom 只读基底 + overlay 可写层（零解压、固定文件不可改）
    if build_overlay_root; then
        _cred_restore || log "[凭据] 恢复未成功，enroll 步将走重注册"
        _recovering=true
        return 0
    fi
    # 回退：从 tarball 解压（老固件 / 内核不支持 overlay / /overlay 不可写）
    log "[overlay] 不可用，回退到镜像解压"
    rebuild_from_image || { log "镜像解压失败"; return 1; }
    _cred_restore || log "[凭据] 恢复未成功，enroll 步将走重注册"
    _recovering=true
}
# 容器内构建子步骤判定（v.93 起由 ct_net/ct_bootlink/ct_resolv/acquis 等节点各自闭环）：
# 每一步独立 verify 就绪探测，供 ensure_sub 循环与整体快照判定共用，判定标准不变
verify_sub_ct_net() {
    _vs_dns="$(_container_dns)"
    if _is_minimal_init; then
        # 极简版：静态网络写在一份 shell 变量文件里，由 /etc/init.d/netconf 在 rcS 里套用。
        # 判据同 systemd 版一样是「三问齐全」，只是取值方式不同：
        #   systemd → Address=/Gateway=/DNS= ；极简版 → ADDRESS=/GATEWAY=/DNS=
        _vs_net="$ROOTFS/etc/crowdsec-net.conf"
        [ -f "$_vs_net" ] || return 1
        grep -qx "ADDRESS=${CONTAINER_IP}/24" "$_vs_net" 2>/dev/null || return 1
        grep -qx "GATEWAY=${BRIDGE_IP}" "$_vs_net" 2>/dev/null || return 1
        grep -qx "DNS=${_vs_dns}" "$_vs_net" 2>/dev/null || return 1
        return 0
    fi
    [ -f "$ROOTFS/etc/systemd/network/10-eth0.network" ] || return 1
    grep -q "Address=${CONTAINER_IP}/24" "$ROOTFS/etc/systemd/network/10-eth0.network" 2>/dev/null || return 1
    grep -q "Gateway=${BRIDGE_IP}" "$ROOTFS/etc/systemd/network/10-eth0.network" 2>/dev/null || return 1
    grep -q "DNS=${_vs_dns}" "$ROOTFS/etc/systemd/network/10-eth0.network" 2>/dev/null || return 1
}
verify_sub_ct_bootlink() {
    if _is_minimal_init; then
        # 极简版没有 systemd，自启语义换成 inittab + init.d：
        #   · /etc/inittab 在 —— 有 init 的启动表，PID1 起来才走得下去；
        #   · /etc/init.d/crowdsec 非空 —— 容器的全部意义，缺了必须当场判不符（同 systemd 版口径）；
        #   · /etc/init.d/rcS 可执行 —— sysinit 入口，缺了网络/syslog 都不起。
        [ -s "$ROOTFS/etc/inittab" ] || return 1
        [ -s "$ROOTFS/etc/init.d/crowdsec" ] || return 1
        [ -x "$ROOTFS/etc/init.d/rcS" ] || return 1
        [ "$(cat "$ROOTFS/etc/hostname" 2>/dev/null)" = "crowdsec" ] || return 1
        _vb_mid=$(tr -d ' \t\r\n' < "$ROOTFS/etc/machine-id" 2>/dev/null)
        printf '%s' "$_vb_mid" | grep -qE '^[0-9a-f]{32}$' || return 1
        return 0
    fi
    _wants="$ROOTFS/etc/systemd/system/multi-user.target.wants"
    for _svc in systemd-networkd crowdsec; do
        if [ ! -f "$ROOTFS/lib/systemd/system/$_svc.service" ]; then
            # 原来这里无条件 continue：服务文件不在就跳过整套检查，函数照样返回 0。
            # 后果是「容器里没有 crowdsec」被判成「自启已就绪」—— 容器起来了、
            # verify 说没问题，直到阶段 3 的 LAPI 探测才炸，中间几十分钟全是假绿。
            # crowdsec 是这台容器的全部意义，缺了必须当场判不符；
            # systemd-networkd 可以被别的网络管理器替代，缺了不拦（配置由 ct_net 管）。
            if [ "$_svc" = "crowdsec" ]; then
                log "[自启] 容器内缺 crowdsec.service，判定不符"
                return 1
            fi
            continue
        fi
        [ -L "$_wants/$_svc.service" ] || return 1
    done
    [ "$(cat "$ROOTFS/etc/hostname" 2>/dev/null)" = "crowdsec" ] || return 1
    _vb_mid=$(tr -d ' \t\r\n' < "$ROOTFS/etc/machine-id" 2>/dev/null)
    printf '%s' "$_vb_mid" | grep -qE '^[0-9a-f]{32}$' || return 1
}
verify_sub_ct_resolv() {
    _vs_dns="$(_container_dns)"
    [ "$(cat "$ROOTFS/etc/resolv.conf" 2>/dev/null)" = "nameserver ${_vs_dns}" ]
}
verify_sub_cs_acquis() {
    _a="$ROOTFS/etc/crowdsec/acquis.d/router.yaml"
    [ -s "$_a" ] || return 1
    # 一条命令整体校验：5 个顶层键齐全即内容完整（无需逐 needle 对）
    [ "$(grep -cE '^(source|listen_addr|listen_port|protocol|labels):' "$_a" 2>/dev/null)" = 5 ] || return 1
    _d="$ROOTFS/etc/crowdsec/parsers/s01-parse/openwrt-dropbear.yaml"
    [ -s "$_d" ] || return 1
    grep -q "openwrt/dropbear-logs" "$_d" 2>/dev/null || return 1
    # v.84：一条命令整体校验规则条数（对齐手动配置期 grep -c 'value: ssh_failed-auth' == 3）
    [ "$(grep -c 'value: ssh_failed-auth' "$_d" 2>/dev/null)" = 3 ] || return 1
    [ "$(grep -c 'value: ssh_auth_success' "$_d" 2>/dev/null)" = 2 ] || return 1
    _w="$ROOTFS/etc/crowdsec/parsers/s02-enrich/openwrt-whitelist.yaml"
    [ -s "$_w" ] || return 1
    # 一条命令整体校验：3 个顶层键齐全即内容完整
    [ "$(grep -cE '^(name|description|whitelist):' "$_w" 2>/dev/null)" = 3 ] || return 1
    # 【v.108.25】最后过一遍 sha：上面全是「结构对不对」，这一条是「内容还是不是
    # 我上次写的那份」。解析器少一个字节（注释被删、缩进被编辑器改）结构判据照样过，
    # 但规则可能已经不生效了 —— 那种失效不会报错，只会让日志解析悄悄变空。
    verify_cfg_sha || { log "[日志] 解析器/配置 sha 与基线不符（内容被改动）"; return 1; }
}
verify_sub_cs_listen() {
    [ -f "$CROWDSEC_CFG" ] || return 1
    grep -qE "^[[:space:]]*listen_uri:[[:space:]]*['\"]?0\\.0\\.0\\.0:${LAPI_PORT}" "$CROWDSEC_CFG" 2>/dev/null
}
verify_sub_cs_trusted() {
    [ -n "$BRIDGE_IP" ] || return 1
    printf '%s' "$BRIDGE_IP" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || return 1
    [ "${BRIDGE_IP%.*}" = "${CONTAINER_IP%.*}" ] || return 1
    [ -f "$CROWDSEC_CFG" ] || return 1
    grep -qE "^[[:space:]]*-[[:space:]]*${BRIDGE_IP}([[:space:]]|$)" "$CROWDSEC_CFG" 2>/dev/null || return 1
    grep -qE "^[[:space:]]*listen_uri:[[:space:]]*['\"]?0\.0\.0\.0:${LAPI_PORT}" "$CROWDSEC_CFG" 2>/dev/null
}
verify_sub_ct_cfg() {
    verify_ct_config                  # 与 install 类同基准：内容完整而非仅文件名
}

# ============================================================================
# v.93-bp：8 组重组后的新节点实现
# 设计原则：静态配置全部在 ct_boot 之前写完（容器启动后改文件不重载不生效）

# ---- PREP / ct_net：容器网络静态文件（IP / 网关 / DNS）+ 双向连通性 ----
# 文件正确只是"配置对"，ping 通才是"真的通"。两个方向都要验：
# 容器内 ping 的一次尝试：写法依次降级。
# 真机现象（24.10，2026-10-22）：脚本判「容器 ping 网桥失败」，人手进容器 ping 却是通的。
# 两种原因都会造成假失败，且都不该判「不符」：
#   · 极简 rootfs 的 busybox ping 未必认 `-W`（老版本只有 `-w`），选项错 → rc≠0；
#   · veth 刚被 netifd 重建过时，第一次 ping 常因邻居表还没建立而丢包。
# 口径：先严后宽，中间隔 1 秒，任一写法通即算通。
_ct_ping_ok() {
    _cpk_h="$1"
    _ct_env "ping -c 1 -W 2 $_cpk_h" >/dev/null 2>&1 && return 0
    _ct_env "ping -c 1 -w 3 $_cpk_h" >/dev/null 2>&1 && return 0
    sleep 1
    _ct_env "ping -c 1 $_cpk_h" >/dev/null 2>&1 && return 0
    return 1
}
# 【v.108.52】ping 失败时的分层诊断：attach 本身通不通、三种写法的 rc 与输出各是什么。
# 只在失败路径调用（成功一次就 return，零额外开销），日志里带 rc，便于下次一眼定位。
_ct_ping_diag() {
    _cpd_h="$1"
    _cpd_t="$(_ct_env "true" 2>&1)"; _cpd_trc=$?
    log "[网络]   attach 探针 rc=$_cpd_trc ${_cpd_t:-（无输出）}"
    _cpd_a="$(_ct_env "ping -c 1 -W 2 $_cpd_h" 2>&1)"; _cpd_arc=$?
    log "[网络]   ping -c 1 -W 2 → rc=$_cpd_arc $(printf '%s' "$_cpd_a" | tr '\n' ' ' | cut -c1-200)"
    _cpd_b="$(_ct_env "ping -c 1 -w 3 $_cpd_h" 2>&1)"; _cpd_brc=$?
    log "[网络]   ping -c 1 -w 3 → rc=$_cpd_brc $(printf '%s' "$_cpd_b" | tr '\n' ' ' | cut -c1-200)"
    _cpd_c="$(_ct_env "ping -c 1 $_cpd_h" 2>&1)"; _cpd_crc=$?
    log "[网络]   ping -c 1     → rc=$_cpd_crc $(printf '%s' "$_cpd_c" | tr '\n' ' ' | cut -c1-200)"
    return 0
}
_host_ping_ok() {
    run ping -c 1 -W 2 "$1" >/dev/null 2>&1 && return 0
    sleep 1
    run ping -c 1 "$1" >/dev/null 2>&1
}
verify_ct_net_ping() {
    ct_running || return 0          # 未启动：不判 ping，交给后续组
    if ! _host_ping_ok "$CONTAINER_IP"; then
        log "[网络] 宿主机 ping 容器 $CONTAINER_IP 失败（仅告警，不计入不符）"
        _ct_ping_diag "$CONTAINER_IP"
        return 0
    fi
    if ! _ct_ping_ok "$BRIDGE_IP"; then
        # 【v.108.52】ping 从「硬判据」降为「告警」。
        # 真机（24.10，2026-10-22）：人手 lxc-attach 进容器 ping 网桥 1/1 通，脚本在
        # 同一时刻用同一条命令却 rc=1；而 _ct_env "echo hi"、"command -v ping" 都 rc=0，
        # ct ls 也 rc=0 —— 失败夹在「attach 成功」与「ping 返回」之间，既不是防火墙
        # （input_lxc 已是 jump accept，forward_lan 有 lan2lxc 且无 l4proto），也不是 DNS。
        # 既然文件内容核对（verify_sub_ct_net）才是硬判据，ping 就不该让整轮引导 exit 1：
        # 那会把「一次手工重跑」变成「构建后始终不符 → 引导失败」的假故障。
        # 保留完整诊断输出，下次真出问题能一眼定位是哪一层。
        log "[网络] 容器 ping 网桥 $BRIDGE_IP 失败（仅告警，不计入不符；静态内容已核对）"
        _ct_ping_diag "$BRIDGE_IP"
    fi
    return 0
}
verify_ct_net() {
    verify_sub_ct_net && verify_ct_net_ping
}
build_ct_net() {
    setup_container_network || return 1
    # 容器已在跑的情况下文件改了需要生效：尝试不重启地拉起网络
    if ct_running; then
        if _is_minimal_init; then
            # 极简版没有 networkd：netconf 用 `ip ... replace` 套用，幂等、不会断掉已有连接
            _ct_env "/etc/init.d/netconf restart" >/dev/null 2>&1 || true
        else
            _ct_env "systemctl restart systemd-networkd" >/dev/null 2>&1 || true
        fi
        # 【v.108.50】改完文件不等于通了。真机上「每轮判不符 → 每轮重建一次」的根因
        # 往往是 veth 已经从 lxcbr0 上掉了（netifd 重建过网桥），而 netconf restart
        # 只套用地址、不负责把端口接回去。这里接回去再验一次：修好了下一轮自然通过，
        # 修不好也要把话说出来，不许假绿。
        if ! verify_ct_net_ping; then
            log "[网络] 重建后仍不通，检查 veth 是否掉线并尝试重接"
            _reattach_ct_veth || true
            verify_ct_net_ping || log "[网络] veth 重接后仍不通（宿主机侧链路问题，等下次网络重载/重启）"
        fi
    fi
    return 0
}

# ---- PREP / cgroup_mount：systemd cgroup 挂载点（容器启动前必须就绪）----
# 宿主侧判据（v.108.15）：不只看「这个路径上有没有挂东西」，还要看挂的是什么。
# 只 grep 路径会误判两类：
#   · 子层级挂载 —— /sys/fs/cgroup/systemd/user.slice 含同一段路径前缀
#   · 别的东西被挂到同一路径（tmpfs 等）—— 路径在、类型不对，容器内照样用不了
# 所以按 /proc/mounts 的列逐项比：$2 挂载点、$3 fstype、$4 挂载选项里的 name=systemd。
_cg_host_ok() {
    awk '$2=="/sys/fs/cgroup/systemd" && $3=="cgroup" && $4 ~ /(^|,)name=systemd(,|$)/ {f=1} END{exit !f}' \
        /proc/mounts 2>/dev/null
}

# LXC 以 systemd 方式引导，缺 /sys/fs/cgroup/systemd 容器起不来或起一半就死。
verify_cgroup_mount() {
    # 极简版容器里没有 systemd，也就没有「systemd 自己去 mount cgroup」这一步，
    # 这个宿主侧挂载点对它毫无意义 —— 直接判就绪，避免为了不存在的消费者去动宿主。
    _is_minimal_init && return 0
    # ① 唯一可靠判据：/proc/mounts 里真有这个挂载点，且是 cgroup/name=systemd
    _cg_host_ok && return 0
    # ② 只有「纯 cgroup v2 unified」才允许跳过：内核里压根没有 v1 命名层级时，
    #    容器内 systemd 的 cgroup 视图由 LXC 的 lxc.mount.auto 提供。
    #    v.108.3 之前这里只判 `cgroup2 存在` 就 return 0 —— hybrid 宿主（同时挂了
    #    cgroup v1 和 v2）会因此永远跳过挂载，容器内 systemd 起不来，
    #    而宿主这边判「已就绪」。这就是那条 Failed to mount API filesystems 的来源之一。
    #
    #    【v.108.43】原写法是：
    #        ! grep -qE 'type cgroup[[:space:]]' /proc/mounts
    #    这个条件**恒为真** —— /proc/mounts 的列是
    #        <设备> <挂载点> <fstype> <挂载选项> <dump> <pass>
    #    里面压根没有 "type " 这个字面量（那是 mount(8) 的显示格式，不是 /proc/mounts）。
    #    于是判据退化成「只要 /proc/mounts 里有 cgroup2 就跳过」，
    #    v.108.3 想修的 hybrid 误判其实一直没修上。
    #    首台真机实测正是 hybrid：
    #        cgroup2 /sys/fs/cgroup         cgroup2 ...
    #        cgroup  /sys/fs/cgroup/systemd cgroup  ... name=systemd
    #    而 verify 照样报「就绪」—— 只因为 ① 恰好也命中（name=systemd 真的挂着），
    #    两个判断互相抵消，问题被藏住了。若哪天 name=systemd 没挂，这里就会假绿：
    #    宿主说就绪、build_cgroup_mount 不执行、容器内 systemd 起不来。
    #    改按 fstype 列判：v2 在 且 v1 不在，才算纯 v2。
    if awk 'BEGIN{v1=0;v2=0} $3=="cgroup"{v1=1} $3=="cgroup2"{v2=1} END{exit !(v2 && !v1)}' \
            /proc/mounts 2>/dev/null; then
        return 0
    fi
    # ③ 其余情况（v1 可用但没挂 / hybrid）→ 确实缺，交给 _mount_systemd_cgroup
    return 1
}
build_cgroup_mount() {
    # 极简版不需要这个层级（容器里没有 systemd 去 mount cgroup）：
    # 宿主 CGROUP_DEVICE / CGROUP_FREEZER 都没开，这里少一次 mount 就少一个失败点。
    _is_minimal_init && return 0
    # 不吞返回值：这里挂不上，容器内 systemd 必然报
    # Failed to mount API filesystems 然后 Exiting PID 1，容器永远起不来。
    # 原先无条件 return 0，等于「日志说挂了、退出码说成功」。
    _mount_systemd_cgroup
    return $?
}

# 容器内 cgroup 视图是否真能用（v.108.15）
# 宿主挂对了不等于容器里能用：中间还隔着 LXC 的 mount 准备、容器内 systemd 的引导。
# 这条补的就是中间那段 —— 它只能在容器起来之后跑，所以挂在 ct_boot 尾部。
verify_ct_cgroup() {
    ct_running || return 1
    # 极简版：系统里没有任何 cgroup 消费者，PID1 是 busybox init。
    # 这一节改成「PID1 是活的 init」，而不是「能读 cgroup.procs」——后者在
    # 没有 cgroup v1 层级的宿主上本来就不成立（CGROUP_DEVICE 未开）。
    if _is_minimal_init; then
        _ct_init=$(_ct_env 'cat /proc/1/comm 2>/dev/null' 2>/dev/null | tr -d '\r' | head -n1)
        case "$_ct_init" in
            init|busybox|sh) return 0 ;;
        esac
        log "[init] 容器内 PID 1 不是 busybox init（实际「${_ct_init:-空}」）"
        return 1
    fi
    # ① 容器内能读到 cgroup 的组织文件：能读 = 这层确实挂进容器且是活的
    if ! _ct_env 'test -r /sys/fs/cgroup/systemd/cgroup.procs || test -r /sys/fs/cgroup/cgroup.procs' \
            >/dev/null 2>&1; then
        log "[cgroup] 容器内读不到 cgroup.procs（cgroup 视图没进容器）"
        return 1
    fi
    # ② PID 1 必须是 systemd：挂载形态不对时 systemd 会在挂载阶段报
    #    Failed to mount API filesystems 然后 Exiting PID 1，容器随即退出。
    #    容器还在跑但 PID 1 不是 systemd，说明根本没按 lxc.init.cmd 引导。
    _ct_init=$(_ct_env 'cat /proc/1/comm 2>/dev/null' 2>/dev/null | tr -d '\r' | head -n1)
    if [ "$_ct_init" != "systemd" ]; then
        log "[cgroup] 容器内 PID 1 不是 systemd（实际「${_ct_init:-空}」）"
        return 1
    fi
    return 0
}

# ---- PREP / ct_bootlink：容器内自启软链 + 机器身份 ----
verify_ct_bootlink() {
    verify_sub_ct_bootlink
}
build_ct_bootlink() {
    setup_container_boot
}

# ---- PREP / ct_resolv：容器内 resolv.conf ----
verify_ct_resolv() {
    verify_sub_ct_resolv
}
build_ct_resolv() {
    setup_resolv
}

# ---- CAPIBLOCK / capi_block：容器启动前注释掉 online_client ----
# 关键：这一步必须在 ct_boot 之前。config.yaml 是 crowdsec 启动时读取的，
# 启动后再改等于没改（服务不重载），新装阶段会因拿不到中央 API 凭证而反复重启。
#
# 【v.108.50】「本轮到底需不需要屏蔽」抽成单独判据，修的是每轮开机的自相矛盾：
#   capi_block 要求 off，capi_release 要求 on —— 同一台机器上这两条不可能同时成立。
#   以前 verify_capi_block 无条件要求 off，于是只要容器已经跑过一轮「放出」，
#   下一轮（探针重跑、阶段 3 的逐节点复验）必然判不符 → 注释 → 紧接着
#   capi_release 又判不符 → 放回 + 重启 crowdsec + 等 8080 回来（真机 29s）。
#   一来一回，日志里就是 _done_capi_block=B 与 _done_capi_release=B 同时出现。
#
#   两种情况下「启动前屏蔽」这个义务本身就不存在：
#   ① 容器已经在跑：启动窗口已经过去，此时注释只在下次重启才生效，
#      而 capi_release 的目标恰恰是 on —— 改了纯属自相矛盾；
#   ② 已装机（有 installed 标记）且 CAPI 凭据文件非空：新装期那个
#      「拿不到凭证 → 引擎反复重启」的前提不成立（空文件才是硬错误），
#      直接带着 on 启动即可，连那一次「放开后重启」都省了。
_capi_block_needed() {
    ct_running && return 1
    if _stamp_present && [ -s "$ROOTFS/etc/crowdsec/online_api_credentials.yaml" ]; then
        return 1
    fi
    return 0
}
verify_capi_block() {
    _capi_block_needed || return 0
    verify_online_client_off
}
build_capi_block() {
    if ! _capi_block_needed; then
        log "[CAPI] 本轮无需启动前屏蔽（容器已在跑，或已装机且 CAPI 凭据非空），跳过注释"
        return 0
    fi
    # v.108.34：build 返回 0 只代表 sed 没报错，不代表文件真的变成了 off。
    # 因为 capi_block 已从收尾复核里豁免（见 _post_verify_skip 的理由），
    # 「真的没写成」必须在当场抓住 —— 否则它会被 capi_release 悄悄盖过去。
    ensure_online_client_off || return 1
    verify_online_client_off || {
        log "[CAPI] online_client 注释后立即校验仍不符（$CROWDSEC_CFG）"
        return 1
    }
    return 0
}

# ---- LOGCONF / acquis：容器内日志采集配置（acquis + 解析器 + 白名单）----
verify_acquis() {
    verify_sub_cs_acquis
}
build_acquis() {
    setup_acquis
}

# ---- LOGCONF / logconf（v.108.22 合成；v.108.23 并入 listen_uri）----
# 一个节点承诺三件事，缺一不可：
#   ① 宿主把 syslog 推给容器（log_forward）
#   ② 容器用 acquisitions 收并解析（acquis）
#   ③ 容器内 LAPI 监听 0.0.0.0:PORT（listen_uri）—— 少了这条，前两条做得再好，
#      路由器上的 bouncer 也永远拉不到，而日志里完全看不出少了什么。
# 只判文件层、不判进程：此刻容器里 crowdsec 可能还端着旧配置，
# 「进程认没认」是 LAPI 组 _ensure_lapi_exposed（探活 + 必要时重启）的活。
verify_logconf() {
    verify_log_forward || { log "[日志] 宿主机推送配置不符"; return 1; }
    verify_acquis || { log "[日志] 容器内采集配置不符"; return 1; }
    verify_lapi_listen || { log "[日志] 容器内 LAPI 未监听 0.0.0.0:${LAPI_PORT}"; return 1; }
    return 0
}
build_logconf() {
    # 修完立刻复核：build 返回 0 不等于修好了，只有 verify 说了算。
    if ! verify_log_forward; then
        build_log_forward
        verify_log_forward || { log "[日志] 宿主机推送配置写入后仍不符"; return 1; }
    fi
    if ! verify_acquis; then
        build_acquis
        verify_acquis || { log "[日志] 容器内采集配置写入后仍不符"; return 1; }
    fi
    if ! verify_lapi_listen; then
        ensure_listen_uri
        verify_lapi_listen || { log "[LAPI] listen_uri 写入后仍不是 0.0.0.0:${LAPI_PORT}"; return 1; }
    fi
    return 0
}

# ---- LOGCONF / log_forward：宿主机把 syslog 推给容器，并做标记日志入库验证 ----
# 两层验证：
LOG_MARK_PREFIX="csprobe"
verify_log_forward() {
    [ -n "$CONTAINER_IP" ] || return 1
    _sys=$(_system_section) || return 1
    [ -n "$_sys" ] || return 1
    [ "$(run uci -q get "$_sys.log_ip" 2>/dev/null)" = "$CONTAINER_IP" ] || return 1
    [ "$(run uci -q get "$_sys.log_port" 2>/dev/null)" = "514" ] || return 1
    [ "$(run uci -q get "$_sys.log_proto" 2>/dev/null)" = "udp" ] || return 1
    [ "$(run uci -q get "$_sys.log_remote" 2>/dev/null)" = "1" ] || return 1
    return 0
}

# 取 /etc/config/system 中第一个 system 段的段名（v.93：verify 与 build 共用同一套
# 段定位逻辑，避免两处各写一遍 uci show 解析而出现「一个判就绪、一个又去写」的抖动）
_system_section() {
    run uci show system 2>/dev/null | grep -q '=system$' || return 1
    run uci show system 2>/dev/null | grep '=system$' | head -n1 | cut -d= -f1
}

# 标记日志入库验证：成功 0，失败 1。容器没跑 / cscli 不可用则返回 1（不可判）。
verify_log_pipeline() {
    ct_running || return 1
    _mark="${LOG_MARK_PREFIX}$(date +%s)_$$"
    # ① 往容器 syslog 打标记（走容器内 logger，确保进的是 acquisitions 监听的那个文件/套接字）
    _ct_env "logger -t ${LOG_MARK_PREFIX} '${_mark}'" >/dev/null 2>&1 || return 1
    # ② 给 rsyslog 与解析链路一点时间（最多 8 秒，200ms 一探）
    _i=0
    while [ "$_i" -lt 40 ]; do
        _out="$(_ct_env "$CSCLI alerts list -o raw" 2>/dev/null)"
        case "$_out" in
            *"$_mark"*) return 0 ;;
        esac
        # 没有命中规则时 alerts 里不会有；退一步查 decisions 与 metrics 源行数增长
        _out2="$(_ct_env "$CSCLI metrics show" 2>/dev/null)"
        case "$_out2" in
            *"$_mark"*) return 0 ;;
        esac
        _i=$((_i + 1))
        sleep 0.2 2>/dev/null || sleep 1
    done
    # ③ 兜底：直接看容器 syslog 是否收到了这条（验证到「收」这一层）
    _ct_env "grep -q '${_mark}' /var/log/syslog /var/log/messages 2>/dev/null" >/dev/null 2>&1
}

build_log_forward() {
    setup_log_forward || return 1
    # 配置补齐后立刻跑一次链路验证（首次构建值得花这个时间）
    if verify_log_pipeline; then
        log "[日志] 标记日志已成功入库（推送→接收→解析→入库 全链通）"
        return 0
    fi
    log "[日志] 标记日志未在窗口内入库；配置已写，解析链路留待容器下一轮拉取后再验"
    # 不 hard：容器刚起时 acquis 可能还没热，配置层已保证正确即可继续
    return 0
}

# ---- LAPI / lapi_fetch：从容器 cscli 取 LAPI 地址与密钥 ----
# 语义：容器内 LAPI 就绪 + 能拿到 local API 凭证（供路由器 bouncer 用）。
LAPI_CRED_CACHE="$STATE_DIR/lapi.env"
verify_lapi_fetch() {
    ct_running || return 1
    verify_lapi_ready || return 1
    # 【v.108.21】容器内自测通过还不够：bouncer 从路由器连，8080 必须对外开放。
    # 少了这一条，LAPI 只监听 127.0.0.1 时全程「验证通过」，bouncer 却一次都拉不到。
    verify_lapi_reachable || return 1
    # 能从容器里读出 local_api_credentials.yaml 的两个关键字段才算拿到
    _ct_env "grep -qE '^[[:space:]]*url:' /etc/crowdsec/local_api_credentials.yaml" >/dev/null 2>&1 || return 1
    _ct_env "grep -qE '^[[:space:]]*login:' /etc/crowdsec/local_api_credentials.yaml" >/dev/null 2>&1 || return 1
    return 0
}
build_lapi_fetch() {
    # 【v.108.21】先把 8080 真正打开（含老容器「文件改了但进程没重读」的兜底重启）
    # 打不开就进丢层流程：第 0 档已经在 _ensure_lapi_exposed 里试过
    # （校正 listen_uri + 重启进程 + 等待），仍不通说明不是「文件对不对」的问题，
    # 而是进程/资源/库层面的问题。丢层回基底，见 _lapi_ladder。
    if ! _ensure_lapi_exposed; then
        log "[LAPI] 8080 无法对路由器开放，LAPI 环节失败；进入丢层自愈（v.108.63）"
        if _lapi_ladder; then
            log "[LAPI] 自愈已使 8080 可达，继续读取凭证"
        else
            return 1
        fi
    fi
    # 等 LAPI 起（最多 MAX_WAIT 秒，SLEEP 步长），拿到 cscli 回显即认为就绪
    _w=0
    while [ "$_w" -lt "$MAX_WAIT" ]; do
        if verify_lapi_ready; then break; fi
        sleep "$SLEEP" 2>/dev/null || sleep 1
        _w=$((_w + SLEEP))
    done
    verify_lapi_ready || { log "[LAPI] 容器内 LAPI 未就绪（等待 ${MAX_WAIT}s）"; return 1; }

    # 缓存凭证到 STATE_DIR：既是「已获取」的证据，也供 bouncer_fill 使用
    mkdir -p "$STATE_DIR" 2>/dev/null
    _url="$(_ct_env "sed -n 's/^[[:space:]]*url:[[:space:]]*//p' /etc/crowdsec/local_api_credentials.yaml" 2>/dev/null | head -n1)"
    _key="$(_ct_env "sed -n 's/^[[:space:]]*login:[[:space:]]*//p' /etc/crowdsec/local_api_credentials.yaml" 2>/dev/null | head -n1)"
    [ -n "$_url" ] && [ -n "$_key" ] || { log "[LAPI] 读取容器内凭证失败"; return 1; }
    {
        printf 'LAPI_URL=%s\n' "$_url"
        printf 'LAPI_KEY=%s\n' "$_key"
        printf 'ts=%s\n' "$(date '+%F %T')"
    } > "$LAPI_CRED_CACHE" 2>/dev/null
    chmod 600 "$LAPI_CRED_CACHE" 2>/dev/null
    log "[LAPI] 已从容器取到 LAPI 地址与密钥（$_url）"
    return 0
}

# ---- LAPI / bouncer_fill：把 LAPI 与密钥填进路由器 bouncer ----
verify_bouncer_fill() {
    _sec=$(run uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
    [ -n "$_sec" ] || return 1
    [ "$(run uci -q get "$_sec.api_url" 2>/dev/null)" = "http://${CONTAINER_IP}:${LAPI_PORT}/" ] || return 1
    [ "$(run uci -q get "$_sec.enabled" 2>/dev/null)" = "1" ] || return 1
    [ -n "$(run uci -q get "$_sec.api_key" 2>/dev/null)" ] || return 1
    return 0
}
build_bouncer_fill() {
    verify_lapi_fetch || { log "[bouncer] LAPI 未就绪，无法填充"; return 1; }
    _bouncer_uci_apply || return 1
    # 注册到容器 LAPI 并取回 key
    _key="$(_ct_env "$CSCLI bouncers add ${BOUNCER_NAME} -o raw" 2>/dev/null | tr -d ' \t\r\n')"
    if [ -z "$_key" ]; then
        # 已存在同名 bouncer：删除旧的重建（否则拿不到新 key）
        _ct_env "$CSCLI bouncers delete ${BOUNCER_NAME}" >/dev/null 2>&1
        _key="$(_ct_env "$CSCLI bouncers add ${BOUNCER_NAME} -o raw" 2>/dev/null | tr -d ' \t\r\n')"
    fi
    [ -n "$_key" ] || { log "[bouncer] 向 LAPI 注册 bouncer 失败"; return 1; }
    _sec=$(run uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
    run uci set "$_sec.api_key=$_key"
    run uci commit crowdsec
    log "[bouncer] 已注册并写入 api_key（${BOUNCER_NAME}）"
    # 宿主机 bouncer 进程仍持着旧 key（或根本还没起来）：uci 写完必须重启一次才读到新值。
    # 不重启的话，紧接着的 BOUNCERVERIFY 会白等 60 秒再判 hard。
    _bouncer_service_restart
    # 首启补拉（首台真机 2026-10-22 现场确认的真 bug）：
    #   全新固件第一轮里 bouncer 服务还没被 enable（enable 写在阶段 3 的 fix_B 里），
    #   _bouncer_service_restart 见进程没跑就直接放行 → 紧接着的 BOUNCERVERIFY 必然
    #   60 秒后软失败 → 不置位 → ENROLL 跳过 → 无 installed 标记 → 阶段 3 重跑整条 DAG，
    #   现场表现就是引导日志里「LOGCONF → LAPI → BOUNCERVERIFY → 阶段 3」转圈。
    #   这里在写完 key 的当下就把服务拉起来（幂等：已在跑且 nft 表就绪则立即返回），
    #   让 BOUNCERVERIFY 第一次就有东西可验。不改 DAG 结构，只改动作。
    if ! cs_active_on_host; then
        log "[bouncer] 服务未运行（首启常态），就地 enable+restart"
        _ensure_bouncer_service
        if cs_active_on_host; then
            log "[bouncer] 首启拉起成功"
        else
            log "[bouncer] 首启拉起失败（仍交给 BOUNCERVERIFY 判定 + 探针兜底）"
        fi
    fi
    return 0
}

# ---- BOUNCERVERIFY / bouncer_verify：验证 bouncer 列表里确实有这个 bouncer 且在拉取 ----
verify_bouncer_verify() {
    ct_running || return 1
    bouncer_exists || return 1
    bouncer_pulling || return 1
}
build_bouncer_verify() {
    # 拉取有周期：最多等 60 秒看 last_pull 是否刷新（12 轮 × SLEEP=5）。
    # 这个 60s 与 _BP_DEFAULT_MAX_AGE 同量级是刻意的：窗口内要能真正观察到
    # 「阈值过期」，否则 verify 永远在新鲜区间里打转，等于没判定。
    _w=0
    while [ "$_w" -lt 60 ]; do
        if verify_bouncer_verify; then return 0; fi
        sleep "$SLEEP" 2>/dev/null || sleep 1
        _w=$((_w + SLEEP))
    done
    # 【v.108.58】等不到 ≠「还没到时候」。判据里 bouncer_pulling 依赖 last_pull 推进，
    # 而 last_pull 不推进的一个常见根因是本地 api_key 与 LAPI 的记录已经对不上
    # （见 _force_resign_bouncer 的注释）。这一档原来没有任何修复动作 —— 只是干等
    # 60 秒然后软失败，于是整台机器可以带着「封禁不下发」跑很久，日志里只有一句
    # 「bouncer 验证失败」，看不出根因。
    # 处置顺序：先确保服务在跑（进程没起来时重签毫无意义），再重签，再给同样的 60s。
    log "[bouncer] last_pull 60s 未刷新：先确保宿主机 bouncer 在跑，再按「key 可能已失配」重签后复验"
    _ensure_bouncer_service
    if _force_resign_bouncer; then
        _w=0
        while [ "$_w" -lt 60 ]; do
            if verify_bouncer_verify; then
                log "[bouncer] 重签 api_key 后 last_pull 已刷新（根因是 key 失配）"
                return 0
            fi
            sleep "$SLEEP" 2>/dev/null || sleep 1
            _w=$((_w + SLEEP))
        done
        log "[bouncer] 重签后 60s 内 last_pull 仍未刷新 —— 不是 key 失配（查 bouncer 进程 / 8080 连通 / 容器内 crowdsec）"
    fi
    return 1
}

# ---- BOUNCERVERIFY / capi_release：解开 CAPI（取消注释 online_client）----
# 前置：bouncer 已生效。此时才让 LAPI 去连中央 API，避免新装期连不上导致反复重启。
verify_capi_release() {
    verify_online_client_on
}
build_capi_release() {
    ensure_online_client_on || return 1
    # 运行中容器需要重载才生效：重启容器内 crowdsec 服务
    if ct_running; then
        _ct_restart_crowdsec || true
        log "[CAPI] online_client 已放出，容器内 crowdsec 已重载"
        # 【v.108.41】重启会把 8080 摘掉约 10 秒，而收尾复核紧接着就要探它
        # （verify_lapi_fetch → verify_lapi_reachable，重试窗口只有 3×1s）。
        # 首台真机实测（06:54 那一轮）：
        #   06:54:42 [LAPI] 重启后 8080 已对路由器开放      ← 上一步刚把它弄通
        #   06:54:45 这里重启 crowdsec                      ← 又摘掉
        #   06:54:47 [复核] 首轮不符： lapi_fetch
        #   06:54:50 [复核][lapi_fetch] 构建后始终不符      ← 3 秒窗口覆盖不住
        #   → 整轮 exit 1 → 探针补印又跑一轮。lapi_fetch 本身没问题，
        #     是这一步的重启把它的现场弄脏了。等 8080 回来再返回，
        #     收尾复核看到的就是稳定现场。
        _cw=0
        while [ "$_cw" -lt "$MAX_WAIT" ]; do
            verify_lapi_reachable && break
            sleep 1
            _cw=$((_cw + 1))
        done
        if verify_lapi_reachable; then
            log "[CAPI] 重启后 8080 已恢复（等待 ${_cw}s）"
        else
            log "[CAPI] 重启后 ${MAX_WAIT}s 内 8080 未恢复（收尾复核可能因此误判）"
        fi
    fi
    return 0
}

# 构建子步骤 ensure + hard（v.79，与 ensure() 同构但不写 _done/_dirty/_failed：
# 外层节点（rootfs / ct_config / acquis / ct_bootlink / ct_resolv …）自身还有两次机会，内层状态不得跨轮残留）——
ensure_sub() {
    _s_name="$1"; _s_verify="$2"; _s_build="$3"
    log "[构建] $_s_name：效验"
    if "$_s_verify" 2>/dev/null; then
        log "[构建] $_s_name 就绪，跳过"
        return 0
    fi
    if ! "$_s_build" 2>/dev/null; then
        log "[构建] $_s_name 构建执行失败，hard 失败，引导终止"
        exit 1
    fi
    log "[构建] $_s_name 已构建"
    return 0
}
# 构建 crowdsec 全链：七步各自 ensure + hard（被各节点按需调用）：
# 网络文件 → 自启软链/机器身份 → resolv.conf → 日志源/解析器 → listen_uri
# → trusted_ips → 容器 config；enroll 不在此链。

# 容器是否在跑 —— BOOT 节点的唯一判据。
# 注意：这一行曾被误并进上面的注释里，导致 verify_ct_boot 在运行期根本不存在，
# ensure 调它必然失败，BOOT 组每轮都会去 build（重复开机）。已拆出来成真函数。
verify_ct_boot() { ct_running; }

# 容器启动构造步（安装态与重启态共用）：v.81 起并入原 _fix_container_boot 的
# 「验启动链在位才开机」内容级检查——启动链缺失（config 不在/不完整、rootfs 不在）
# 校验 lxc-auto 服务侧配置：容器名必须在 /etc/config/lxc-auto 里、服务必须 enabled。
#
# ★ 必须能"写"，不能只校验（v.108.8）：lxc-auto 包自带的 /etc/config/lxc-auto
#   整份都是注释（#config container / #option name container1 / ...），uci 读出来
#   一行有效配置都没有 → config_foreach 遍历不到 container 段 →
#   /etc/init.d/lxc-auto start() 直接 return 0，一声不响什么都不做，容器开机不常驻。
#   v.108.7 曾假定"名字由镜像固定、运行期与 /rom 一致"，这个前提不成立：
#   workflow 把 custom/ 以 bind mount 挂到 files/etc/config 上（-v custom:...），
#   Docker 的整体遮蔽让仓库里那份 files/etc/config/lxc-auto 根本进不了镜像。
#   现已改由 /etc/uci-defaults/98-lxc-auto.sh 首启写入，这里再兜一层 ——
#   overlay 被清、config 被删、名字被改，都能自愈。
#
# ★ 该文件**不进 GUARD_FILES**：它是运行期 uci 配置。guard 的基准是 /rom，
#   而 /rom 里是包的注释模板，纳进去只会把写好的配置每轮打回注释态。
_ensure_lxc_auto() {
    _ea_init="$LXC_AUTO_INIT"
    if [ ! -x "$_ea_init" ]; then
        log "[lxc-auto] 服务脚本缺失（固件未带 files/etc/init.d/lxc-auto），改走直接 lxc-start"
        return 1
    fi
    _ea_dirty=0
    # ① 容器名：服务按 /etc/config/lxc-auto 里的 name 启动，没有段/名字不符都拉不起来
    _ea_name=$(run uci -q get lxc-auto.@container[0].name 2>/dev/null)
    if [ "$_ea_name" != "$LXC_NAME" ]; then
        if run uci -q get lxc-auto.@container[0] >/dev/null 2>&1; then
            run uci -q set "lxc-auto.@container[0].name=$LXC_NAME"
        else
            run uci -q add lxc-auto container
            run uci -q set "lxc-auto.@container[-1].name=$LXC_NAME"
        fi
        _ea_dirty=1
        log "[lxc-auto] /etc/config/lxc-auto 已补写容器 $LXC_NAME（原为「${_ea_name:-空}」）"
    fi
    # ② timeout：镜像固化的就是 300，被改过即异常（影响 lxc-stop 的等待时长，
    #    写太短会在容器还没退干净时就当它停了）。名字对了也要查这一项。
    _ea_to=$(uci -q get lxc-auto.@container[0].timeout 2>/dev/null)
    if [ "$_ea_to" != "300" ]; then
        run uci -q set "lxc-auto.@container[0].timeout=300"
        _ea_dirty=1
        log "[lxc-auto] timeout 已校正为 300（原为「${_ea_to:-空}」）"
    fi
    # ③ 执行面（v.108.12）：files/etc/init.d/lxc-auto 的 start_container() 里有
    #    `config_list_foreach "$cfg" command run_command` —— 段里只要出现
    #    `list command '...'`，开机就会以 root 执行它。镜像固化的容器段没有这一项，
    #    出现即为被注入（别的脚本写坏 / 从别处拷来的配置），必须清掉。
    #    只清 @container[0]：镜像只认这一个段，用户自己加的段不归本脚本管。
    if run uci -q get lxc-auto.@container[0].command >/dev/null 2>&1; then
        run uci -q delete lxc-auto.@container[0].command
        _ea_dirty=1
        log "[lxc-auto] 已删除 @container[0].command：lxc-auto 会把它当命令以 root 执行，而镜像配置里没有这一项"
    fi
    # ④ 多余段：只告警、不删。删掉别人加的容器段属于破坏性操作，
    #    和「只维护第一段」的边界冲突，交给人判断。
    if run uci -q get lxc-auto.@container[1] >/dev/null 2>&1; then
        log "[lxc-auto] 注意：/etc/config/lxc-auto 里还有第 2 个 container 段，本脚本只维护第一段，不当处置"
    fi
    if [ "$_ea_dirty" = 1 ]; then
        run uci -q commit lxc-auto \
            || { log "[lxc-auto] 写 /etc/config/lxc-auto 失败"; return 1; }
    fi
    # ② 服务必须 enabled：disabled 时 S99 不拉起，重启后容器就不在了
    if ! "$_ea_init" enabled 2>/dev/null; then
        "$_ea_init" enable >/dev/null 2>&1 \
            || { log "[lxc-auto] enable 失败"; return 1; }
        log "[lxc-auto] 服务已 enable（开机 S99 自动拉起容器）"
    fi
    return 0
}

# ---- PREP / lxc_auto：/etc/config/lxc-auto 真的写着容器段（v.108.28）----
#
# 为什么需要这个节点：`_ensure_lxc_auto` 原来只被 `build_ct_boot` 调到，而
# build_ct_boot 能不能跑到，取决于 `verify_ct_boot`（= 容器在不在跑）。
# 于是有一种现场完全静默：**容器好好跑着，而 /etc/config/lxc-auto 是空的
# （或被 overlay 清掉、被还原成 lxc-auto 包自带的注释模板）** ——
# verify_ct_boot 说「容器在跑，达标」，build_ct_boot 根本不执行，没人写配置。
# 这个口子一直藏到下次重启才炸：S99 lxc-auto 遍历不到 container 段，
# `start()` 一声不响 return 0，容器不起来，人才发现配置早没了。
# 所以把「配置在不在」从「容器在不在」里剥出来单独判，运行期也验、也补。
#
# 该文件仍**不进 GUARD_FILES**（v.108.8 的决定不变）：guard 的基准是 /rom，
# 而 /rom 里是 lxc-auto 包的注释模板，纳进去等于每轮把写好的配置打回注释态。
# 它归 bootstrap 管，不归 guard 管 —— 这个节点就是那句话的落地。
#
# ★ 但**服务脚本本身**（/etc/init.d/lxc-auto）是另一回事：它在 GUARD_FILES 里，
#   受只读基准 /rom 保护，被改/被删都会被 guard 拷回来（连 overlay 的 whiteout 都处理了）。
#   所以「服务脚本不存在」不是「固件没带」，而是「被删了、guard 还没跑到」——
#   必须判不符，并且自己从 /rom 恢复一次（不把「guard 与本脚本谁先跑」当运气）。
#   guard 恢复的是**文件**，恢复不了 **enable 状态**（/etc/rc.d/S99lxc-auto 不在清单里），
#   所以下面那条 `enabled` 判据是必需的、不是多余的。
verify_lxc_auto() {
    # 受 /rom 保护：缺失就是异常，不是「不适用」
    [ -x "$LXC_AUTO_INIT" ] || return 1
    [ -f "$LXC_AUTO_CFG" ] || return 1
    [ "$(run uci -q get lxc-auto.@container[0].name 2>/dev/null)" = "$LXC_NAME" ] || return 1
    [ "$(uci -q get lxc-auto.@container[0].timeout 2>/dev/null)" = "300" ] || return 1
    # 段里出现 command = 开机以 root 执行它（镜像固化的段没有这一项），出现即判不符
    run uci -q get lxc-auto.@container[0].command >/dev/null 2>&1 && return 1
    "$LXC_AUTO_INIT" enabled >/dev/null 2>&1 || return 1
    return 0
}
build_lxc_auto() {
    # ① 服务脚本被删了？先从只读基准恢复。guard 也会做这件事，但它有周期，
    #    本脚本可能先跑完一轮 —— 不依赖别人的执行顺序。
    if [ ! -x "$LXC_AUTO_INIT" ]; then
        _la_src="$LXC_AUTO_ROM$LXC_AUTO_INIT"
        if [ -f "$_la_src" ]; then
            rm -f "$LXC_AUTO_INIT" 2>/dev/null
            if cp -f "$_la_src" "$LXC_AUTO_INIT" 2>/dev/null && chmod 755 "$LXC_AUTO_INIT" 2>/dev/null; then
                log "[lxc-auto] 服务脚本曾被删除，已从只读基准恢复（$LXC_AUTO_INIT）"
            else
                log "[lxc-auto] 从只读基准恢复服务脚本失败（overlay 不可写？）"
                return 1
            fi
        else
            log "[lxc-auto] 只读基准里也没有 $LXC_AUTO_INIT —— 这台固件不带 lxc-auto 服务"
            return 1
        fi
    fi
    # ② 文件整个不在了也要能从零建：uci 对不存在的 config 只会在内存里造段，
    #    commit 没有落点就会失败。先放一个空文件当落点，再交给 _ensure_lxc_auto。
    #    【v.108.31】这一步以前不检查返回值：/etc/config 被删、只读、或被换成目录时，
    #    `: >` 悄悄失败，后面的报错只会说「写 lxc-auto 失败」，看不出根因在这里。
    if [ ! -f "$LXC_AUTO_CFG" ]; then
        _la_dir=$(dirname "$LXC_AUTO_CFG")
        if ! mkdir -p "$_la_dir" 2>/dev/null; then
            log "[lxc-auto] 落点目录不可用：$_la_dir（不存在且建不出来）"
            return 1
        fi
        # 重定向失败在 ash 里是**致命**的：` : > 坏路径` 会直接把整个 bootstrap 杀掉，
        # 日志里只留一行 "can't create ..." —— 既不是 return 1，也没有上下文。
        # 拿子 shell 把它关起来：死了只死子 shell，父进程拿得到非 0。
        if ! ( : > "$LXC_AUTO_CFG" ) 2>/dev/null; then
            log "[lxc-auto] 无法创建 $LXC_AUTO_CFG（overlay 只读，或该路径被目录/符号链接占着）"
            return 1
        fi
        log "[lxc-auto] $LXC_AUTO_CFG 不存在（或被删），已建空落点，按镜像应有的样子重建"
    fi
    _ensure_lxc_auto || return 1
    # ③ ensure() 在 build 成功后不复核（v.108.15 的教训），这里自己收口
    verify_lxc_auto
}

# 清掉历史遗留的 lxcboot 兜底（v.108.14）
#
# 背景：v107-bp 那版固件的启动链是断的（/etc/config/lxc-auto 整份注释 + 服务 disabled），
# 现场只能手工建 /etc/init.d/lxcboot + /etc/rc.d/S99lxcboot 兜底。这份兜底不在
# GUARD_FILES 里，也没有任何步骤会回收它。于是「保留配置」刷到 v.108 固件后，
# S99lxc-auto 与 S99lxcboot 会同时去启同一个容器：
#   · 后跑的那次 lxc-start 必然 already running 失败（这个本身无害）
#   · 但 lxcboot 里若还带手工 `mount -t cgroup -o none,name=systemd`，会再叠一份
#     挂载 → /sys/fs/cgroup/systemd 重复挂载，cgroup 视图错乱（现场确实叠过两条）
#   · 两个启动器谁先谁后取决于 rc.d 字典序之外的实现细节，出问题极难归因
#
# ★ 只在 lxc-auto 链路**确实就位**之后才清（调用点就在 _ensure_lxc_auto 成功分支内），
#   否则删掉兜底等于把唯一能起容器的路也砍了。
# ★ 备份后删，且**任何一步失败都只告警、不返回 1**：删不掉不该阻断开机，
#   那比留着旧兜底更糟。这里故意不给 ensure() 用的失败语义。
_purge_legacy_lxcboot() {
    _lb_init=/etc/init.d/lxcboot
    _lb_bak=/root/lxcboot.bak
    _lb_hit=0
    if [ -e "$_lb_init" ]; then
        # 先 disable：正常 init 脚本会自己摘掉 rc.d 链接；不标准的那种摘不掉，下面兜
        "$_lb_init" disable >/dev/null 2>&1 || true
        if cp -f "$_lb_init" "$_lb_bak" 2>/dev/null; then
            :
        else
            log "[遗留] 备份 $_lb_init 失败（原文件仍会被删，如需回滚只能从 /rom 或固件包取）"
        fi
        rm -f "$_lb_init" 2>/dev/null
        _lb_hit=1
    fi
    # rc.d 里的残留链接单独扫一遍：lxcboot 不是标准 uci init，disable 未必摘得干净
    for _lb_l in /etc/rc.d/*lxcboot*; do
        [ -e "$_lb_l" ] || continue
        rm -f "$_lb_l" 2>/dev/null
        _lb_hit=1
    done
    # 删完回读：真删掉了才说成功，别报假绿
    if [ -e "$_lb_init" ]; then
        log "[遗留] 删除 $_lb_init 失败，旧兜底仍在；lxc-auto 已就位，两者会抢同一个容器"
        return 0
    fi
    if [ "$_lb_hit" = 1 ]; then
        log "[遗留] 已清掉 lxcboot 兜底（备份 $_lb_bak）：lxc-auto 链路已就位，双启动器会互相踩"
    fi
    return 0
}

build_ct_boot() {
    # ★ 勿删、勿"优化"：两个 lxc-auto 不是一回事，别再判成"装了又关的自相矛盾"。
    #   · 仓库自带的 files/etc/init.d/lxc-auto：读 /etc/config/lxc-auto 的
    #     `config container` + `option name`，直接 `lxc-start -n <name> -d`，
    #     **不读容器 config 的 lxc.start.auto**；boot() 里还顺带挂 systemd cgroup。
    #     容器常驻走的就是这条 → 必须 enable 并由本脚本拉起它（v.108 回退 v.56 起的禁用）。
    #   · `lxc.start.auto=1`：让容器自己随 lxc-autostart 起，已弃用，与上面那个服务无关。
    # 曾经的做法是「disable lxc-auto + 脚本自己 lxc-start」，副作用是把带 cgroup 挂载的
    # 那个 boot() 一起废掉，且开机自启只剩 rc.local 一条路，失败就再没有别的手接管。
    if ! verify_ct_config; then
        log "[开机] 启动链缺失（容器 config 不在或不完整），不开机"
        return 1
    fi
    if ! verify_rootfs; then
        log "[开机] 启动链缺失（rootfs 不在或不完整），不开机"
        return 1
    fi
    # 【v.108.22】listen_uri 不在这里改。
    # 开机只需要网桥 + systemd cgroup 两个条件（这是容器能不能起来的物理前提）；
    # listen_uri 是 LAPI 对外可达性的事，放进来就把「bouncer 连不上」变成了
    # 「容器不开机」——故障范围被放大，而且用户看到的是一台直接不起机的路由器。
    # 改由 LAPI 组的 _ensure_lapi_exposed 负责（改文件 → 探活 → 不通就重启容器内
    # crowdsec 再探），改坏了最多是 LAPI 这一组失败。
    _mount_systemd_cgroup
    if _ensure_lxc_auto; then
        _purge_legacy_lxcboot
        log "启动容器 $LXC_NAME（经 lxc-auto 服务）"
        run_svc /etc/init.d/lxc-auto start >/dev/null 2>&1 || log "[lxc-auto] start 返回非 0，继续兜底"
    fi
    # 兜底：服务缺失 / 被 disable / start 异常时直接起，不让开机链断在这一步
    ct_running || run lxc-start -P "$LXC_PATH" -n "$LXC_NAME" -d >/dev/null 2>&1 || true
    if ! _wait_ct_running; then
        log "首启未拉起，重试 lxc-start -d"
        run lxc-start -P "$LXC_PATH" -n "$LXC_NAME" -d >/dev/null 2>&1 || true
        if ! _wait_ct_running; then
            _ct_revive || { log "容器启动修复链无效，引导失败"; return 1; }
        fi
    fi
    # 容器 RUNNING 不等于 cgroup 视图可用：补挂宿主层级 + 重启容器一次，仍不可用就 hard。
    # 放在 ct_boot 而不是 PREP 组，因为容器没起来时容器内无从查起。
    if ! verify_ct_cgroup; then
        log "[cgroup] 容器内 cgroup 视图不可用，补挂宿主层级并重启容器一次"
        _mount_systemd_cgroup || true
        ct_force_stop || true
        run lxc-start -P "$LXC_PATH" -n "$LXC_NAME" -d >/dev/null 2>&1 || true
        if ! _wait_ct_running || ! verify_ct_cgroup; then
            log "[cgroup] 容器内 cgroup 视图仍不可用，引导失败"
            return 1
        fi
        log "[cgroup] 补挂并重启后，容器内 cgroup 视图已可用"
    fi
    # 【v.108.66】从这一刻起 CT_BOOT_GRACE 秒内，容器内命令用 60s 超时：
    # PID1 刚就绪，首次 attach（cgroup 视图、网络检查）都可能要等它。
    # 窗口过后自动收紧到 10s —— 探针重跑时容器早已运行，走的就是 10s。
    _CT_BOOT_UNTIL=$(( $(date +%s) + CT_BOOT_GRACE ))
    log "容器已启动"
}

# lxcbr0 网桥 builder（自 setup_bridge 拆出：commit/reload 交由 flush_uci 分组处理）
# 【v.97 修正】这里原本是「只验不写」——只在内核里补一个裸 bridge，不设地址、不写 uci。
# 而 verify_bridge 要求「lxcbr0 存在 + network.lxc.proto=static + 桥上 IP == BRIDGE_IP」三件齐。
# 也就是说首次启动时 build 跑完 verify 依然不过，只是 ensure 不做事后复核所以没报错；
# 后果是容器网络整条链（ct_net / ping 双向）静默失败。v.95 已经把网络侧全部改成
# 「验证 + 修改」，唯独漏了这一个，现在补齐：
#   · uci 侧：network.lxc 段（proto/ipaddr/netmask/device），交给 flush_uci 的 network reload
#   · 内核侧：设备不存在就建，存在则校正地址（先删旧地址再按 uci 加，幂等）
build_bridge() {
    _nb_ip="$BRIDGE_IP"
    _nb_mask="$(run uci -q get network.lxc.netmask 2>/dev/null)"
    [ -n "$_nb_mask" ] || _nb_mask="255.255.255.0"

    _net_write_guard "lxcbr0 网桥与地址"

    # 【v.108.35】顺序是「先 device，再 interface」：
    #   interface 里的 device 只是一个「名字引用」，被引用的设备必须先存在。
    # 原来的顺序是先写 interface、再 ip link add，于是 netifd 读到的 interface
    # 指向一个还没声明的名字 → 按外部设备处理 → 有就用、没有不建 → 重启后网桥凭空消失。

    # ① uci：device 段。必须让 netifd 知道「lxcbr0 是我要的网桥」，
    #    它才会在 network reload 时把这个 bridge 建出来，重启后也自动存在。
    #    bridge_empty='1' 是必须的：netifd 对「一个端口都没有的 bridge」默认
    #    不认为它是 present（device_set_present false），于是根本不创建。
    #    lxcbr0 恰恰是空网桥 —— 端口要等容器启动时 veth 才接进来。
    if [ "$(run uci -q get network.lxcbr0 2>/dev/null)" != "device" ] \
       || [ "$(run uci -q get network.lxcbr0.type 2>/dev/null)" != "bridge" ] \
       || [ "$(run uci -q get network.lxcbr0.name 2>/dev/null)" != "lxcbr0" ] \
       || [ "$(run uci -q get network.lxcbr0.bridge_empty 2>/dev/null)" != "1" ]; then
        run uci -q set network.lxcbr0='device'
        run uci -q set network.lxcbr0.name='lxcbr0'
        run uci -q set network.lxcbr0.type='bridge'
        run uci -q set network.lxcbr0.bridge_empty='1'
        log "[网桥] 已声明 network.lxcbr0（device / type=bridge / bridge_empty=1），netifd 自己建，重启不再靠脚本"
    fi

    # ② 内核：设备不存在则补建（reload 之前就要能用，所以不干等 netifd）。
    #    补建失败必须说出来 —— 以前 `ip link add ... 2>/dev/null` 不看返回值，
    #    建不出来也记「已补建」，下一轮 verify 才发现，中间容器起不来。
    if ! run ip link show lxcbr0 >/dev/null 2>&1; then
        if run ip link add lxcbr0 type bridge 2>/dev/null; then
            log "[网桥] 内核中无 lxcbr0，已补建"
        elif run ip link show lxcbr0 >/dev/null 2>&1; then
            log "[网桥] lxcbr0 已由 netifd 建出（与本次补建并发，忽略）"
        else
            log "[网桥] 无法创建 lxcbr0（ip link add 失败），网桥不存在，容器网络无从谈起"
            return 1
        fi
    fi
    run ip link set lxcbr0 up 2>/dev/null || log "[网桥] lxcbr0 up 失败（设备在但没起来）"

    # ③ uci：interface 段。设备已经在，这里只负责引用 + 地址
    #    （该段缺失时 ping 判据也过不去）。
    if [ "$(run uci -q get network.lxc.proto 2>/dev/null)" != "static" ] \
       || [ "$(run uci -q get network.lxc.device 2>/dev/null)" != "lxcbr0" ] \
       || [ "$(run uci -q get network.lxc.ipaddr 2>/dev/null)" != "$_nb_ip" ]; then
        run uci -q set network.lxc='interface'
        run uci -q set network.lxc.proto='static'
        run uci -q set network.lxc.device='lxcbr0'
        run uci -q set network.lxc.ipaddr="$_nb_ip"
        run uci -q set network.lxc.netmask="$_nb_mask"
        log "[网桥] 已写入 network.lxc（$_nb_ip/$_nb_mask 设备 lxcbr0）"
    fi

    # ④ 内核：地址校正（已正确就不动，避免每轮重启都抖一下）
    #    注意 ip addr 要的是前缀长度，不是点分掩码，所以这里把 255.x.x.x 折成位数。
    _nb_pfx=$(printf '%s\n' "$_nb_mask" | awk -F. '{n=0; for(i=1;i<=4;i++){v=$i+0; while(v>0){n+=v%2; v=int(v/2)}}; print n}')
    [ -n "$_nb_pfx" ] || _nb_pfx=24
    _nb_cur=$(ip -4 addr show lxcbr0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -n1)
    if [ "$_nb_cur" != "$_nb_ip" ]; then
        [ -n "$_nb_cur" ] && run ip addr del "$_nb_cur/$_nb_pfx" dev lxcbr0 2>/dev/null
        if ! run ip addr add "$_nb_ip/$_nb_pfx" dev lxcbr0 2>/dev/null; then
            # add 失败可能是「地址其实已经在」（并发/重复执行），复核一次再定论
            _nb_chk=$(ip -4 addr show lxcbr0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -n1)
            if [ "$_nb_chk" != "$_nb_ip" ]; then
                log "[网桥] lxcbr0 地址写入失败（当前 ${_nb_chk:-无地址}，期望 $_nb_ip）"
                return 1
            fi
        fi
        log "[网桥] lxcbr0 地址已校正为 $_nb_ip/$_nb_pfx"
    fi

    # ⑥ 端口在位（首台真机 2026-10-22）：网桥一旦被重建，端口全掉、容器与宿主断链，
    #    而 uci 与地址全都"看着正常"。这里补一次重接，与 verify_bridge 的端口判据对称：
    #    verify 判不就绪 → ensure 调本函数 → 本函数把线接回去 → 下一轮 verify 通过。
    _reattach_ct_veth || true

    # ⑤ 脏标记由 ensure() 统一定位（_bs_flag_set "_dirty_$o" B），builder 里不必重复写。
    return 0
}


# ip_forward 节点 build（原 setup_lxc_firewall 尾部行为）
# 【v.97 修正】原来写完就无条件 log「已置 1」——/proc 只读、容器化宿主、权限不足
# 时写入静默失败，日志却报成功，ensure 以为修好了，实际 SNAT/转发全废。
# 现在写完必须回读确认，读不回来就判失败（让 ensure 走 hard 终止，别假装成功）。
build_ip_forward() {
    echo 1 >/proc/sys/net/ipv4/ip_forward 2>/dev/null
    if [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = "1" ]; then
        _ipfwd_touched=1     # 记下"本轮是本脚本改的"，退出时据此决定要不要还原
        _ipfwd_mark          # 落哨兵：让下次进程能认出"这个 1 是脚本置的"
        log "[防火墙] ip_forward 已置 1"
        return 0
    fi
    log "[防火墙] ip_forward 写入失败（/proc 只读或无权限），容器出网与内网互访会失效"
    return 1
}

# SNAT rule 节点 verify（v.79 纯判定）：只验 rule 本身，不夹带修复动作——
# rule 缺失/不符由 ensure 走 build_snat 重建（_dirty_snat 进 firewall 组，flush 各至多一次）；
verify_snat() {
    if verify_snat_rule; then
        log "[SNAT] 就位（src=$(_lxc_net) → $(_lan_ip)）"
        return 0
    fi
    log "[SNAT] rule 缺失/不符，待重建"
    return 1
}

setup_log_forward() {
    [ -n "$CONTAINER_IP" ] || { log "[日志] 无容器 IP，跳过转发配置"; return 1; }

    _sys=$(_system_section) || _sys=""
    if [ -z "$_sys" ]; then
        run uci add system system >/dev/null 2>&1
        _sys=$(_system_section) || _sys=""
    fi
    [ -n "$_sys" ] || { log "[日志] 无 system 段，无法配置远程日志"; return 1; }

    _want_ip="$CONTAINER_IP"
    _cur_ip=$(run uci -q get "$_sys.log_ip" 2>/dev/null)
    _cur_port=$(run uci -q get "$_sys.log_port" 2>/dev/null)
    _cur_proto=$(run uci -q get "$_sys.log_proto" 2>/dev/null)
    _cur_remote=$(run uci -q get "$_sys.log_remote" 2>/dev/null)

    if [ "$_cur_ip" = "$_want_ip" ] && [ "$_cur_port" = "514" ] \
       && [ "$_cur_proto" = "udp" ] && [ "$_cur_remote" = "1" ]; then
        log "[日志] 远程日志已指向容器 ${_want_ip}:514/udp，跳过"
        return 0
    fi

    run uci -q set "$_sys.log_ip=$_want_ip"
    run uci -q set "$_sys.log_port=514"
    run uci -q set "$_sys.log_proto=udp"
    run uci -q set "$_sys.log_remote=1"
    run uci commit system

    run /etc/init.d/log reload >/dev/null 2>&1 || run /etc/init.d/logd reload >/dev/null 2>&1 || true
    log "[日志] 宿主机系统日志已转发到容器 ${_want_ip}:514/udp"
    return 0
}


write_cfg() {
    _dst="${1:-$CFG}"
    # 容器名键按 LXC 版本选：4.0 起是 lxc.uts.name，之前是 lxc.utsname。
    # 写旧键时 LXC 6.x 会判无效，apply_cfg 的裁剪循环把整行 grep -v 掉 ——
    # 表面「自愈成功」，实际让 config 永远少这一行（现场 cat 出来确实没有
    # lxc.utsname），随后 verify_ct_config 判「不完整」、BOOT 组 hard 失败。
    # 版本取不到就按新键写（4.0 以下早已没人用；真写错也只是名字退回目录名）。
    _wm_key="lxc.uts.name"
    _wm_ver=$(run lxc-info --version 2>/dev/null | sed -n 's/^\([0-9][0-9]*\)\..*/\1/p')
    if [ -n "$_wm_ver" ] && [ "$_wm_ver" -lt 4 ] 2>/dev/null; then
        _wm_key="lxc.utsname"
    fi
    atomic_write "$_dst" "lxc.rootfs.path" <<EOF || return 1
lxc.arch = amd64
${_wm_key} = $LXC_NAME
lxc.include = /usr/share/lxc/config/common.conf
lxc.rootfs.path = dir:$ROOTFS
lxc.init.cmd = /sbin/init
lxc.autodev = 1
lxc.net.0.type = veth
lxc.net.0.link = lxcbr0
lxc.net.0.flags = up
lxc.net.0.hwaddr = 10:66:6A:7C:05:9A
lxc.tty.max = 4
lxc.pty.max = 1024
EOF
}

apply_cfg() {
    write_cfg "$CFG.tmp0" || return 1
    [ -s "$CFG.tmp0" ] || { rm -f "$CFG.tmp0"; return 1; }   # tmp 半截不落盘
    if [ -f "$CFG" ] && [ ! -f /usr/share/lxc/config/common.conf ]; then
        grep -v '^[[:space:]]*lxc.include' "$CFG.tmp0" > "$CFG" 2>/dev/null \
            && rm -f "$CFG.tmp0" || { rm -f "$CFG.tmp0"; return 1; }
    else
        mv -f "$CFG.tmp0" "$CFG" 2>/dev/null || return 1
    fi
    _trim=0
    while [ "$_trim" -lt 20 ]; do
        _err=$(run lxc-info -P "$LXC_PATH" -n "$LXC_NAME" 2>&1) && return 0
        _bad=$(printf '%s\n' "$_err" | sed -n 's/.*at line "\([^"]*\)".*/\1/p' | head -n1)
        [ -n "$_bad" ] || break
        grep -v -F "$_bad" "$CFG" > "$CFG.tmp1" 2>/dev/null && mv -f "$CFG.tmp1" "$CFG" || break
        _trim=$((_trim+1))
    done
    ct_exists
}

# 【v.108.55】容器包直接从 /rom 只读原件解压 —— 不拷贝、不比对。
# 为什么：/rom 是 squashfs，编译期写入、运行期不可写，它自己就是可信来源。
# 在可信来源外面再套一层「拷贝到 /etc 再 cmp」，只换来两个新的失败方式
# （overlay 写满、拷贝被截断），以及把 107 MB 复制进 overlay 白吃可写空间；
# 而 cmp 只能证明「刚拷的这份等于原件」，证明不了任何它本来就没法证明的事。
# 只有老固件里 /rom 压根没有这份包（当年只有 lxc-ubuntu.tar.gz）时，
# 才退回 /etc 的工作副本，并对它做 gzip 结构自检 —— 且日志如实写明来源不可证。
ROM_TARBALL="${CS_ROM_TARBALL:-/rom$CS_HOME/lxc-crowdsec.tar.gz}"
SRC_TARBALL=""

_tarball_usable() {
    [ -f "$1" ] || return 1
    [ -s "$1" ] || return 1
    run_tar tar -tzf "$1" >/dev/null 2>&1 || return 1
    return 0
}

_pick_tarball() {
    # 首选固件里的只读原件：可信、零拷贝、不占 overlay。
    if [ -f "$ROM_TARBALL" ] && [ -s "$ROM_TARBALL" ]; then
        SRC_TARBALL="$ROM_TARBALL"
        return 0
    fi
    # 老固件的退路：/etc 那份可能被人换过，只能证明「是个能解的 gzip」，证明不了来源。
    if _tarball_usable "$TARBALL"; then
        SRC_TARBALL="$TARBALL"
        log "[包] 固件里没有 /rom 副本，改用工作副本 $TARBALL（仅 gzip 结构自检，来源无法证明）"
        return 0
    fi
    log "[包] 无可用容器包：$ROM_TARBALL 与 $TARBALL 都不可用"
    return 1
}

# 【v.108.56】overlay 根：lower = /rom 只读基底，upper/work = /overlay（f2fs）
# 真正的收益不是「省一次解压」，而是「固定文件在物理上改不了」：
# /etc/init.d/rcS、/etc/inittab、crowdsec-supervise 这些留在 lower 里，
# 容器内想改也改不动，guard 从「每 60 秒盖回去」退化成冗余保险。
# 三个前提，缺一不可（2026-10-22 真机验过）：
#   ① 内核支持 overlay：/proc/filesystems 含 "nodev overlay"
#   ② upperdir 所在 fs 支持 xattr：/overlay 是 f2fs（user_xattr,inline_xattr）
#   ③ upperdir 不能是 overlayfs 本身：/srv 在 rootfs overlay 上，直接用它 rc=32
_overlay_mounted() {
    [ -d "$ROOTFS" ] || return 1
    run mount 2>/dev/null | grep -qF " on $ROOTFS type overlay"
}

_base_fingerprint() {
    [ -s "$ROM_BASE.fingerprint" ] || return 1
    head -n1 "$ROM_BASE.fingerprint" 2>/dev/null | tr -d ' \t\r\n'
}

# upper 里记着「我这层是照着哪版基底建的」。换固件后基底变了、upper 还是旧的，
# 旧副本会永久遮住新基底的同名文件 —— 看着升级了，其实没升。所以指纹不符就整层丢弃。
_upper_stamp_ok() {
    _usf="$(_base_fingerprint)" || return 0
    [ -f "$OVL_UPPER/.base-fingerprint" ] || return 1
    [ "$(head -n1 "$OVL_UPPER/.base-fingerprint" 2>/dev/null | tr -d ' \t\r\n')" = "$_usf" ]
}

_overlay_umount() {
    _overlay_mounted || return 0
    run umount "$ROOTFS" 2>/dev/null && return 0
    run umount -l "$ROOTFS" 2>/dev/null && return 0
    return 1
}

build_overlay_root() {
    [ -d "$ROM_BASE" ] || {
        log "[overlay] 固件里没有只读基底（$ROM_BASE），改用镜像解压"
        return 1
    }
    mkdir -p "$OVL_UPPER" "$OVL_WORK" "$ROOTFS" 2>/dev/null || {
        log "[overlay] 建目录失败（$OVL_UPPER / $OVL_WORK / $ROOTFS）"
        return 1
    }
    if _overlay_mounted; then
        log "[overlay] 已挂载：$ROOTFS"
        return 0
    fi
    if ! _upper_stamp_ok; then
        log "[overlay] upper 与基底指纹不符（换过固件或首次），丢弃可写层重建"
        rm -rf "$OVL_UPPER" "$OVL_WORK" 2>/dev/null
        mkdir -p "$OVL_UPPER" "$OVL_WORK" 2>/dev/null || return 1
    fi
    if ! run mount -t overlay overlay \
            -o "lowerdir=$ROM_BASE,upperdir=$OVL_UPPER,workdir=$OVL_WORK" "$ROOTFS"; then
        log "[overlay] 挂载失败：lower=$ROM_BASE upper=$OVL_UPPER work=$OVL_WORK"
        return 1
    fi
    _base_fingerprint > "$OVL_UPPER/.base-fingerprint" 2>/dev/null
    log "[overlay] 只读基底已挂载：lower=$ROM_BASE upper=$OVL_UPPER"
    return 0
}

rebuild_from_image() {
    log "尝试从镜像解压 rootfs：$TARBALL"
    # 【v.108.55】选源失败就不再往下走：rm -rf "$ROOTFS" 是不可逆的。
    _pick_tarball || return 1
    log "[包] 解压源：$SRC_TARBALL"
    ct_force_stop || return 1
    # overlay 挂着时 rm -rf 会 busy 且删不干净：先卸载再抹
    _overlay_umount || { log "[overlay] $ROOTFS 卸载失败，放弃解压"; return 1; }
    rm -rf "$ROOTFS" 2>/dev/null
    mkdir -p "$ROOTFS" || return 1
    if ( set -C; : > "$ROOTFS/.extracting" ) 2>/dev/null; then
        if run_tar tar -xzf "$SRC_TARBALL" -C "$ROOTFS"; then
            rm -f "$ROOTFS/.extracting"
            log "解压完成（$(du -sh "$ROOTFS" 2>/dev/null | cut -f1)）"
            return 0
        fi
        rm -f "$ROOTFS/.extracting"
        log "解压失败"
        return 1
    fi
    log "另一实例正在解压，等待完成"
    _i=0
    while [ -f "$ROOTFS/.extracting" ]; do
        _i=$((_i+1)); [ "$_i" -ge $MAX_WAIT ] && break; sleep $SLEEP
    done
    [ -f "$CROWDSEC_CFG" ]
}

ensure_trusted_ip() {
    [ -f "$CROWDSEC_CFG" ] || return 1
    [ -n "$BRIDGE_IP" ] || return 1
    grep -qE "^[[:space:]]*-[[:space:]]*${BRIDGE_IP}([[:space:]]|$)" "$CROWDSEC_CFG" 2>/dev/null \
        && { log "[配置] trusted_ips 已含 $BRIDGE_IP"; return 0; }
    awk -v tip="$BRIDGE_IP" '
        BEGIN { in_ti=0; indent="      " }
        /^[[:space:]]*trusted_ips:/ { in_ti=1; print; next }
        in_ti && /^[[:space:]]*-[[:space:]]/ { print; next }
        in_ti && /^[[:space:]]*#/ { print indent "- " tip; in_ti=0; print; next }
        in_ti && /^[[:space:]]*$/ { print; next }
        in_ti { print indent "- " tip; in_ti=0; print; next }
        { print }
        END { if (in_ti) print indent "- " tip }
    ' "$CROWDSEC_CFG" > "$CROWDSEC_CFG.tmp" 2>/dev/null \
        && mv -f "$CROWDSEC_CFG.tmp" "$CROWDSEC_CFG" 2>/dev/null \
        && { log "[配置] trusted_ips 已补上 $BRIDGE_IP"; return 0; }
    rm -f "$CROWDSEC_CFG.tmp" 2>/dev/null
    log "[配置] 补 trusted_ips 失败"
    return 1
}

_container_dns() {
    _dns=""
    if [ -f /etc/config/custom_router_dns.txt ]; then
        _dns=$(tr -d '\r' < /etc/config/custom_router_dns.txt | tr '\n' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    fi
    [ -n "$_dns" ] || _dns="$BRIDGE_IP"
    [ -n "$_dns" ] || _dns='10.1.0.1'
    printf '%s' "$_dns"
}

setup_container_network() {
    [ -d "$ROOTFS" ] || { log "[网络] rootfs 未就绪"; return 1; }
    if _is_minimal_init; then
        # 【v.108.46】极简版的 net.conf 是**静态文件**：构建期由 rootfs-skel 装进 tarball
        # 和固件两处（同字节），由 crowdsec-guard 逐字节保护。
        # 这里不再重写 —— 写了就是 bootstrap 和 guard 抢同一个文件（写 v1、盖回 v2），
        # 每 60 秒一次，正是 v.108.44 那个 flash 磨损事故的形态，只是换了个理由。
        # 只确认它还在：缺了交给 guard 复原，guard 也补不上就交给 _structurally_broken。
        _netfile="$ROOTFS/etc/crowdsec-net.conf"
        if [ -s "$_netfile" ]; then
            log "[网络] 容器静态 IP ${CONTAINER_IP}/24 网关 ${BRIDGE_IP}（静态文件，guard 保护）"
            return 0
        fi
        log "[网络] 缺 /etc/crowdsec-net.conf（静态文件被删？），等 guard 从 /rom 复原"
        return 1
    fi
    _dns="$(_container_dns)"
    _netfile="$ROOTFS/etc/systemd/network/10-eth0.network"
    mkdir -p "$(dirname "$_netfile")" 2>/dev/null
    atomic_write "$_netfile" "Address=${CONTAINER_IP}/24" <<EOF || { log "[网络] 容器网络文件写入不完整"; return 1; }
[Match]
Name=eth0

[Network]
Address=${CONTAINER_IP}/24
Gateway=${BRIDGE_IP}
DNS=${_dns}
EOF
    log "[网络] 容器静态 IP ${CONTAINER_IP}/24 网关 ${BRIDGE_IP} DNS ${_dns}"
    return 0
}

setup_container_boot() {
    [ -d "$ROOTFS" ] || { log "[自启] rootfs 未就绪"; return 1; }
    if _is_minimal_init; then
        # 极简版：自启写在 inittab 里（::sysinit 跑 rcS，::respawn 看住 crowdsec），
        # 没有软链可建。缺 inittab / init.d/crowdsec 说明 rootfs 残缺，必须判失败——
        # 口径与 systemd 版「缺 crowdsec.service 就 return 1」一致。
        [ -s "$ROOTFS/etc/inittab" ] \
            || { log "[自启] 容器内缺 /etc/inittab（rootfs 残缺），无法引导"; return 1; }
        [ -s "$ROOTFS/etc/init.d/crowdsec" ] \
            || { log "[自启] 容器内缺 /etc/init.d/crowdsec（rootfs 残缺）"; return 1; }
        chmod +x "$ROOTFS/etc/init.d/rcS" "$ROOTFS/etc/init.d/crowdsec" \
                 "$ROOTFS/etc/init.d/netconf" "$ROOTFS/etc/init.d/syslogd" \
                 "$ROOTFS/usr/sbin/crowdsec-supervise" 2>/dev/null
        echo "crowdsec" | atomic_write "$ROOTFS/etc/hostname" "crowdsec" || return 1
        _mid=$(cat "$ROOTFS/etc/machine-id" 2>/dev/null | tr -d ' \t\r\n')
        printf '%s' "$_mid" | grep -qE '^[0-9a-f]{32}$' || {
            _mid=$( (tr -d ' \t\r\n' < /etc/machine-id 2>/dev/null | grep -oE '^[0-9a-f]{32}$') )
            [ -n "$_mid" ] || _mid=$(sha256sum /proc/sys/kernel/random/uuid 2>/dev/null | cut -c1-32)
            [ -n "$_mid" ] || _mid=$(date +%s%N 2>/dev/null | sha256sum | cut -c1-32)
            printf '%s\n' "$_mid" | atomic_write "$ROOTFS/etc/machine-id" "" || return 1
        }
        log "[自启] 极简 init：inittab + rcS + init.d/crowdsec 已就绪，hostname/machine-id 已初始化"
        return 0
    fi
    _wants="$ROOTFS/etc/systemd/system/multi-user.target.wants"
    mkdir -p "$_wants" 2>/dev/null
    [ -f "$ROOTFS/lib/systemd/system/systemd-networkd.service" ] \
        && ln -sf /lib/systemd/system/systemd-networkd.service "$_wants/systemd-networkd.service" 2>/dev/null
    # ★ 必须判到底（v.108.15）：ensure() 在 build 成功之后**不复核** verify，
    #   只把节点标成完成。原来这里写 `[ -f ... ] && ln -sf`，crowdsec.service 不在时
    #   短路跳过、函数照样 return 0 —— verify 说「不符」、build 说「修好了」，
    #   两边都没错但结论相反，最终的假绿一路带到阶段 3 才炸。
    [ -f "$ROOTFS/lib/systemd/system/crowdsec.service" ] \
        || { log "[自启] 容器内缺 crowdsec.service（rootfs 残缺），无法建自启软链"; return 1; }
    ln -sf /lib/systemd/system/crowdsec.service "$_wants/crowdsec.service" 2>/dev/null \
        || { log "[自启] 建 crowdsec 自启软链失败（$_wants 不可写？）"; return 1; }
    echo "crowdsec" | atomic_write "$ROOTFS/etc/hostname" "crowdsec" || return 1
    # machine-id 必须是 32 位 hex（systemd 要求）；空文件会让判定永不符 → 每次启动重复构建
    _mid=$(cat "$ROOTFS/etc/machine-id" 2>/dev/null | tr -d ' \t\r\n')
    printf '%s' "$_mid" | grep -qE '^[0-9a-f]{32}$' || {
        _mid=$( (tr -d ' \t\r\n' < /etc/machine-id 2>/dev/null | grep -oE '^[0-9a-f]{32}$') )
        [ -n "$_mid" ] || _mid=$(sha256sum /proc/sys/kernel/random/uuid 2>/dev/null | cut -c1-32)
        [ -n "$_mid" ] || _mid=$(date +%s%N 2>/dev/null | sha256sum | cut -c1-32)
        printf '%s\n' "$_mid" | atomic_write "$ROOTFS/etc/machine-id" "" || return 1
    }
    log "[自启] networkd + crowdsec 软链已建，hostname/machine-id 已初始化"
    return 0
}

setup_resolv() {
    [ -d "$ROOTFS" ] || { log "[DNS] rootfs 未就绪"; return 1; }
    _resolv="$ROOTFS/etc/resolv.conf"
    if _is_minimal_init; then
        # 【v.108.46】同上：resolv.conf 也是静态文件（nameserver 固定为网桥 IP）。
        if [ -s "$_resolv" ]; then
            log "[DNS] 容器 resolv.conf 为静态文件（guard 保护）"
            return 0
        fi
        log "[DNS] 缺 /etc/resolv.conf（静态文件被删？），等 guard 从 /rom 复原"
        return 1
    fi
    _dns="$(_container_dns)"
    echo "nameserver ${_dns}" | atomic_write "$_resolv" "nameserver" \
        || { log "[DNS] resolv.conf 写入不完整"; return 1; }
    chmod 644 "$_resolv" 2>/dev/null
    log "[DNS] 容器 resolv.conf → ${_dns}"
    return 0
}

setup_acquis() {
    [ -d "$ROOTFS/etc/crowdsec" ] || { log "[配置] rootfs 内无 crowdsec"; return 1; }
    if _is_minimal_init; then
        # 【v.108.46】采集源 / 解析器 / 白名单全部静态化：内容在构建期就确定，
        # 由 rootfs-skel 进 tarball 与固件，guard 逐字节保护。
        # 以前这三个文件由本函数每轮重写，所以不能进 guard（写了就被盖回去）。
        for _sf in etc/crowdsec/acquis.d/router.yaml \
                   etc/crowdsec/parsers/s01-parse/openwrt-dropbear.yaml \
                   etc/crowdsec/parsers/s02-enrich/openwrt-whitelist.yaml; do
            [ -s "$ROOTFS/$_sf" ] \
                || { log "[配置] 缺 /$_sf（静态文件被删？），等 guard 从 /rom 复原"; return 1; }
        done
        log "[配置] 解析器 + 日志源 + 白名单为静态文件（guard 保护）"
        return 0
    fi
    mkdir -p "$ROOTFS/etc/crowdsec/acquis.d" \
             "$ROOTFS/etc/crowdsec/parsers/s01-parse" \
             "$ROOTFS/etc/crowdsec/parsers/s02-enrich" 2>/dev/null

    _acq="$ROOTFS/etc/crowdsec/acquis.d/router.yaml"
    atomic_write "$_acq" "source: syslog" <<'EOF' || return 1
source: syslog
listen_addr: 0.0.0.0
listen_port: 514
protocol: udp
labels:
  type: syslog
EOF

    _par="$ROOTFS/etc/crowdsec/parsers/s01-parse/openwrt-dropbear.yaml"
    atomic_write "$_par" "openwrt/dropbear-logs" <<'EOF' || return 1
name: openwrt/dropbear-logs
description: Parse OpenWrt non-PAM dropbear logs
filter: evt.Parsed.program == 'dropbear'
onsuccess: next_stage
nodes:
  - grok:
      pattern: "Bad password attempt for '?%{DATA:username}'? from %{IP:source_ip}:%{INT:source_port}"
      apply_on: message
    statics:
      - meta: log_type
        value: ssh_failed-auth
  - grok:
      pattern: "Login attempt for nonexistent user %{GREEDYDATA:username} from %{IP:source_ip}:%{INT:source_port}"
      apply_on: message
    statics:
      - meta: log_type
        value: ssh_failed-auth
  - grok:
      pattern: "Exit before auth from <%{IP:source_ip}:%{INT:source_port}>"
      apply_on: message
    statics:
      - meta: log_type
        value: ssh_failed-auth
  - grok:
      pattern: "Password auth succeeded for '?%{DATA:username}'? from %{IP:source_ip}:%{INT:source_port}"
      apply_on: message
    statics:
      - meta: log_type
        value: ssh_auth_success
  - grok:
      pattern: "Pubkey auth succeeded for '?%{DATA:username}'? with key %{DATA:key_type} from %{IP:source_ip}:%{INT:source_port}"
      apply_on: message
    statics:
      - meta: log_type
        value: ssh_auth_success
statics:
  - meta: service
    value: ssh
  - meta: source_ip
    expression: evt.Parsed.source_ip
  - meta: username
    expression: evt.Parsed.username
EOF

    _wl="$ROOTFS/etc/crowdsec/parsers/s02-enrich/openwrt-whitelist.yaml"
    atomic_write "$_wl" "whitelist:" <<'EOF' || return 1
name: openwrt/my-whitelist
description: 'No whitelist configured - placeholder only'
whitelist:
  reason: placeholder, nothing is whitelisted
  ip:
    - 127.0.0.1
  cidr:
    - 240.0.0.0/4
EOF
    log "[配置] 解析器 + 日志源 + 白名单已写入"
    return 0
}

# 【v.108.23】文件层判据：只问「配置写对了没」，不问「进程认了没」。
# LOGCONF 组跑的时候容器里 crowdsec 还端着旧配置，这时候做进程探测必然假红。
# 「进程认了没」交给 LAPI 组的 _ensure_lapi_exposed（探活 + 必要时重启容器内 crowdsec）。
verify_lapi_listen() {
    [ -n "$LAPI_PORT" ] || return 1
    [ -f "$CROWDSEC_CFG" ] || { log "[LAPI] config.yaml 缺失"; return 1; }
    grep -qE "^[[:space:]]*listen_uri:[[:space:]]*['\"]?0\.0\.0\.0:${LAPI_PORT}" "$CROWDSEC_CFG" 2>/dev/null
}

ensure_listen_uri() {
    [ -f "$CROWDSEC_CFG" ] || { log "[配置] config.yaml 缺失"; return 1; }
    grep -qE "^[[:space:]]*listen_uri:[[:space:]]*['\"]?0\.0\.0\.0:${LAPI_PORT}" "$CROWDSEC_CFG" 2>/dev/null \
        && { log "[配置] listen_uri 已就绪 0.0.0.0:${LAPI_PORT}"; return 0; }
    sed -i -E "s|^([[:space:]]*listen_uri:)[[:space:]]*.*|\\1 0.0.0.0:${LAPI_PORT}|" "$CROWDSEC_CFG" 2>/dev/null
    grep -qE "^[[:space:]]*listen_uri:[[:space:]]*['\"]?0\.0\.0\.0:${LAPI_PORT}" "$CROWDSEC_CFG" 2>/dev/null \
        && { log "[配置] listen_uri 已改为 0.0.0.0:${LAPI_PORT}"; return 0; }
    log "[配置] listen_uri 覆盖失败"
    return 1
}

# 【v.108.21】宿主（路由器）侧探测 LAPI。
# 为什么必须从宿主探测：bouncer 跑在路由器上，它连的是 10.1.0.10:8080。
# 容器内 `cscli` / `curl 127.0.0.1` 永远是通的 —— 即使 LAPI 只监听回环。
# 只用容器内判据，就会出现「全部验证通过、bouncer 一次都拉不到」的假绿。
verify_lapi_reachable() {
    run wget -qO- --timeout=3 "http://${CONTAINER_IP}:${LAPI_PORT}/health" 2>/dev/null \
        | grep -q '"status"'
}

# 让 8080 真正对路由器开放：探测 → 不通就重启容器内 crowdsec 再探测。
# 「改文件」和「进程认这份文件」是两件事：容器一直在跑时，只有重启才重新读 listen_uri。
# 【v.108.23】文件本身已由 LOGCONF 组的 logconf 节点写入并复核过；这里开头的
# ensure_listen_uri 是幂等兜底（运行期重跑、文件被人动过时还有一次自愈机会）。
_ensure_lapi_exposed() {
    ensure_listen_uri || return 1
    if verify_lapi_reachable; then
        log "[LAPI] 8080 已对路由器开放（${CONTAINER_IP}:${LAPI_PORT}）"
        return 0
    fi
    log "[LAPI] 路由器侧探测不通（容器内 LAPI 可能仍只监听 127.0.0.1），重启容器内 crowdsec"
    _ct_restart_crowdsec \
        || log "[LAPI] 容器内 crowdsec 重启命令均失败"
    _lw=0
    while [ "$_lw" -lt "$MAX_WAIT" ]; do
        if verify_lapi_reachable; then
            log "[LAPI] 重启后 8080 已对路由器开放"
            return 0
        fi
        sleep "$SLEEP" 2>/dev/null || sleep 1
        _lw=$((_lw + SLEEP))
    done
    log "[LAPI] 重启后 ${MAX_WAIT}s 内 8080 仍不可达（查容器内 firewall 与 crowdsec 监听地址）"
    return 1
}

ensure_online_client_off() {
    [ -f "$CROWDSEC_CFG" ] || { log "[配置] config.yaml 缺失"; return 1; }

    sed -i -E \
        -e "s|^([[:space:]]*)online_client:.*|\\1# online_client: # Central API credentials disabled by bootstrap|" \
        -e "s|^([[:space:]]*)credentials_path:.*online_api_credentials.yaml.*|\\1# credentials_path: /etc/crowdsec/online_api_credentials.yaml|" \
        "$CROWDSEC_CFG" 2>/dev/null

    sed -i -E \
        -e "/^[[:space:]]*client:/,/^[[:space:]]*server:/ s|^([[:space:]]*)#[[:space:]]*credentials_path:.*|\1credentials_path: /etc/crowdsec/local_api_credentials.yaml|" \
        "$CROWDSEC_CFG" 2>/dev/null

    if grep -qE "^[[:space:]]*# online_client:" "$CROWDSEC_CFG" 2>/dev/null; then
        log "[配置] online_client 已注释，LAPI 不再强依赖中央 API 认证"
        return 0
    fi
    log "[配置] online_client 注释失败"
    return 1
}

ensure_online_client_on() {
    [ -f "$CROWDSEC_CFG" ] || { log "[配置] config.yaml 缺失"; return 1; }

    sed -i -E \
        -e "s|^([[:space:]]*)# online_client:.*|\1online_client:|" \
        -e "s|^([[:space:]]*)# credentials_path: /etc/crowdsec/online_api_credentials.yaml.*|\1credentials_path: /etc/crowdsec/online_api_credentials.yaml|" \
        "$CROWDSEC_CFG" 2>/dev/null

    if grep -qE "^[[:space:]]*online_client:" "$CROWDSEC_CFG" 2>/dev/null; then
        log "[配置] online_client 已放出（取消注释），CAPI 可经 LAPI 后启用"
        return 0
    fi
    log "[配置] online_client 放出失败"
    return 1
}

_bouncer_uci_apply() {
    _sec=$(run uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
    if [ -z "$_sec" ]; then
        run uci add crowdsec bouncer >/dev/null 2>&1
        _sec=$(run uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
    fi
    [ -n "$_sec" ] || { log "/etc/config/crowdsec 无 bouncer 段，bouncer 包未装进固件"; return 1; }
    run uci -q set "$_sec.api_url=http://${CONTAINER_IP}:${LAPI_PORT}/"
    run uci -q set "$_sec.enabled=1"
    run uci -q set "$_sec.ipv4=1"
    run uci -q set "$_sec.ipv6=0"
    run uci -q set "$_sec.deny_action=drop"
    run uci -q set "$_sec.filter_input=1"
    run uci -q set "$_sec.filter_forward=1"
    run uci -q del "$_sec.interface"
    run uci add_list "$_sec.interface=br-lan"
    run uci commit crowdsec
    return 0
}

_wait_lapi_ready() {
    _lw_max="${1:-90}"
    _lw_i=0
    while [ "$_lw_i" -lt "$_lw_max" ]; do
        _lw_i=$((_lw_i+1))
        ct_running || { log "容器已停止，LAPI 等待中止"; return 1; }
        _ct_env "$CSCLI bouncers list -o json" >/dev/null 2>&1 && return 0
        [ $((_lw_i % 15)) -eq 0 ] && log "等待容器内 crowdsec LAPI 就绪（已等 ${_lw_i}s）"
        sleep 1
    done
    return 1
}

_bouncer_register_once() {
    _ct_env "$CSCLI bouncers delete $BOUNCER_NAME" >/dev/null 2>&1 || true
    _junk="$(_ct_env "$CSCLI bouncers list -o json" 2>/dev/null \
             | grep -oE '"name":[[:space:]]*"[^"]*"' \
             | sed -E 's/.*"name":[[:space:]]*"([^"]*)"/\1/' \
             | grep -vx "$BOUNCER_NAME")"
    for _jn in $_junk; do
        _ct_env "$CSCLI bouncers delete \"$_jn\"" >/dev/null 2>&1 || true
        log "[bouncer] 已清理残留坏记录 name=$_jn"
    done

    _raw=$(_ct_env "$CSCLI bouncers add $BOUNCER_NAME -o raw" 2>&1)
    _key=$(printf '%s\n' "$_raw" | sed -e 's/\r$//' \
           | grep -Eo '^[A-Za-z0-9+/=_-]{16,}$' | tail -n1)
    [ -n "$_key" ] || return 1
    _sec=$(run uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
    [ -n "$_sec" ] || return 1
    run uci set "$_sec.api_key=$_key"
    run uci commit crowdsec
    return 0
}

_ensure_bouncer_service() {
    if cs_active_on_host && nft_table_ready; then
        return 0
    fi
    bouncer_svc enable || true
    bouncer_svc restart || true
    sleep 3
    if cs_active_on_host && nft_table_ready; then
        log "[bouncer] 已生效"
    else
        log "[bouncer] 重启后仍未就绪"
    fi
    return 0
}

# 宿主机 bouncer 服务重启（v.94）：填完 api_key 后必须让进程重新读 uci。
# 与 _ensure_bouncer_service 的分工：
_bouncer_service_restart() {
    if ! cs_active_on_host; then
        # 还没起来：交给 _ensure_bouncer_service 的 enable+restart，这里不抢跑
        log "[bouncer] 宿主机 bouncer 未运行，交由服务拉起流程处理"
        return 0
    fi
    bouncer_svc restart \
        || { log "[bouncer] 重启宿主机 bouncer 服务失败（新 api_key 可能未生效）"; return 1; }
    # 给进程重新读 key + 建 nft 表留时间，最多 10 秒
    _br_i=0
    while [ "$_br_i" -lt 10 ]; do
        cs_active_on_host && nft_table_ready && {
            log "[bouncer] 宿主机 bouncer 已重载（新 api_key 生效）"
            return 0
        }
        _br_i=$((_br_i+1))
        sleep 1 2>/dev/null || sleep 1
    done
    log "[bouncer] 宿主机 bouncer 重载后 10 秒内 nft 表仍未就位（不阻断，交由 BOUNCERVERIFY 判定）"
    return 0
}

# 【v.108.58】强制重签 api_key。
# 为什么需要它：verify_bouncer_fill 只看本地 uci 三项（api_url / enabled / api_key 非空），
# 它回答的是「本地配置齐不齐」，不是「这个 key 还被 LAPI 认不认」。于是最典型的一种失效
# 它永远看不见 —— 换固件时 upper 与基底指纹不符、整层丢弃，LAPI 里的 bouncer 记录随之
# 清零，而 /etc/config/crowdsec（含 api_key）在 sysupgrade 保留清单里活了下来。
# 表现就是：每轮引导在 BOUNCERVERIFY 干等 60 秒 → 软失败（SOFT_NODES 不中止）→
# 下一轮重来，日志里没有一处说「key 已经不认了」。
# 复用 _bouncer_register_once：它本身就是「先删同名 → 清理残留坏记录 → add」，
# 等于把旧 key 作废重发，不需要新写一套注册逻辑。
_force_resign_bouncer() {
    # LAPI 必须真的可用，否则「注册失败」会被误读成「key 修不好」。
    _wait_lapi_ready 60 || { log "[bouncer] 重签失败：容器内 LAPI 60s 内未就绪"; return 1; }
    _bouncer_register_once || { log "[bouncer] 重签失败：向 LAPI 注册 bouncer 失败（拿不到 key）"; return 1; }
    log "[bouncer] 已重签 api_key（${BOUNCER_NAME}），重启宿主机 bouncer 让进程读到新值"
    if cs_active_on_host; then
        _bouncer_service_restart
    else
        _ensure_bouncer_service
    fi
    return 0
}

_TS_RE='[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]'

# ---- last_pull 新鲜度阈值的唯一来源（v.108）----
# 为什么收成常量：原来「600」在 bouncer_pulling 里出现三次（默认值 / 日志文本 /
#   非数字回落值），改一处漏两处就会出现「日志说 600、实际按 180 判」——正是本脚本
#   一直在防的那类「不报错、只给错误答案」。现在三个位置都引用同一个常量，语法层面
#   无法再不一致。
# 为什么是 6 个周期而不是 60 个：bouncer 的心跳是 10s 一次（crowdsec-firewall-bouncer
#   默认 update_frequency），连续丢 6 个周期（60s）已经是强信号。还要注意这 60s 只是
#   「第一轮判失效」的门槛，防抖由探针的 CS_PROBE_STALL_ROUNDS（连续 3 轮才动手）
#   负责，两者叠加后真实的误报容忍约 3 分钟，一次网络抖动不会触发修复。
# 改这里之前先看 build_bouncer_verify 的等待窗口：那边固定 60s（12 轮 × SLEEP=5），
#   与这里的默认值同量级。若把本值调到远小于 60s，安装期会在窗口内频繁判失效；
#   若调到远大于 60s，窗口内根本观察不到「过期」，安装期判定就形同虚设。两个数要同进退。
_BP_PULL_INTERVAL=10
_BP_PULL_MISS=6
_BP_DEFAULT_MAX_AGE=$((_BP_PULL_INTERVAL * _BP_PULL_MISS))

# 同一句日志不重复刷屏：_sc_wait_pull 每 5 秒调一次 bouncer_pulling，
# 原实现会让「last_pull 停滞」在 60 秒窗口里原样打 12 遍，把真正有用的信息埋掉。
_bp_say() {
    [ "$1" = "${_bp_last_msg:-}" ] && return 0
    _bp_last_msg="$1"
    log "$1"
}

# last_pull 新鲜度判定。返回 0 = 在拉，1 = 失效。
bouncer_pulling() {
    _lp="$(_ct_env "$CSCLI bouncers list" 2>/dev/null \
        | grep -E "^[[:space:]]*${BOUNCER_NAME}[[:space:]]" \
        | grep -oE "${_TS_RE}Z?" | head -n 1)"
    [ -n "$_lp" ] || return 1

    # 阈值：非数字 → 是配置笔误，警告后回落默认（不能静默关闭检查）；
    # 0 → 主动关闭，此时返回 0 是「不查」，日志必须写明，不能跟「查过了，新鲜」混同。
    # （空串在这里到不了：上一行的 ${VAR:-$_BP_DEFAULT_MAX_AGE} 已经把它换成常量值了。）
    _max_age="${BOUNCER_PULL_MAX_AGE:-$_BP_DEFAULT_MAX_AGE}"
    case "$_max_age" in
        *[!0-9]*)
            _bp_say "[bouncer] BOUNCER_PULL_MAX_AGE='$_max_age' 不是数字，回落默认 ${_BP_DEFAULT_MAX_AGE}s"
            _max_age=$_BP_DEFAULT_MAX_AGE
            ;;
    esac
    if [ "$_max_age" -le 0 ]; then
        _bp_say "[bouncer] BOUNCER_PULL_MAX_AGE=$_max_age：last_pull 新鲜度检查已按配置关闭（这是放行，不是判定为新鲜）"
        return 0
    fi

    _now="$(_ct_env "date +%s" 2>/dev/null)"
    # 【v.108.44】_lp 是 crowdsec 打的 ISO8601（形如 2026-10-21T23:59:53Z），
    # 原写法直接 `date -d "$_lp"` —— busybox 的 -d 只吃 `YYYY-MM-DD hh:mm:ss` 这类，
    # 带 T 和 Z 就解析失败，_at 恒为空，于是**每一次**都走下面那条「判不了 → 放行」。
    # 也就是说 last_pull 新鲜度检查从上线起就没真正执行过：日志写「判不了」，
    # 看着像容器里 date 坏了，实际是格式没规整。这种「检查静默失效」比判错更危险 ——
    # bouncer 真停拉了，这里照样说「放行」。
    # 现在把 T 换成空格、去掉尾部 Z；容器无 tzdata、本地即 UTC，epoch 与 date +%s
    # 同一基准，所以两种写法结果等同（-u 不被支持时退回无 -u 仍成立）。
    _lp_norm=$(printf '%s' "$_lp" | sed -e 's/T/ /' -e 's/Z$//')
    _at="$(_ct_env "date -u -d '$_lp_norm' +%s" 2>/dev/null)"
    [ -n "$_at" ] || _at="$(_ct_env "date -d '$_lp_norm' +%s" 2>/dev/null)"
    # 两种失败要分开报：「回显为空」和「格式不认」是两件事，混在一句话里
    # 会把排查方向带偏（真机日志就是这么误导的：now=[…] at=[] 被写成「date 不可用」）。
    if [ -z "$_now" ]; then
        _bp_say "[bouncer] last_pull 判不了（容器内 date +%s 回显为空），本次放行 —— 这不是「新鲜」"
        return 0
    fi
    if [ -z "$_at" ]; then
        _bp_say "[bouncer] last_pull 判不了（容器内 date 解析不了这个时间串：lp=[$_lp] 规整后=[$_lp_norm]），本次放行 —— 这不是「新鲜」"
        return 0
    fi
    if [ $(( _now - _at )) -gt "$_max_age" ]; then
        _bp_say "[bouncer] last_pull 停滞（$_lp，超过 ${_max_age}s），判定失效"
        return 1
    fi
    return 0
}

bouncer_exists() {
    _ct_env "$CSCLI bouncers list" 2>/dev/null | grep -qE "^[[:space:]]*${BOUNCER_NAME}[[:space:]]"
}


# 一组路径的「内容指纹」：文件清单 + 每个文件的 sha1 再取一次摘要。
# 用什么不用时间：时间只说明「什么时候动过」，说明不了「是不是同一个东西」——
# 时间戳变了内容没变（touch/重解压同版本）会被误判成变更；内容变了而时间戳
# 恰好相同（同一秒内两次写、cp -p 保留时间）会被漏判。判「一不一样」只能比内容。
# 细节全是从测试里踩出来的，每一处都对应一条实测：
#   ① 必须先 cd 进去再 find，只传相对清单：否则传绝对路径和传相对路径算出来的
#      指纹不同，同一个树在两种调用方式下会「看起来变了」。
#   ② 路径名会参与摘要：sha1sum 的输出里带文件名，`find c` 打印的是 `c/x.yaml`，
#      `find .` 打印的是 `./x.yaml`，同一个目录换个写法就是两个指纹。所以这里不接
#      多个路径参数，而是「第一个参数当根 cd 进去、只算这一个目录」，再统一削掉
#      `./` 前缀——同一个树怎么调都只有一个值。
#   ③ xargs 一个文件都不给时会自己去读 stdin，把外层管道吃掉 —— 加 -r 兜住，
#      并把 stdin 明确接到 /dev/null。
#   ④ 【最坑的一条】把 `</dev/null` 直接挂在整条管道末尾（`... | sha1sum </dev/null`）
#      是错的：管道里每个元素都会拿到这个重定向，上游 `find` 的 stdout 因此被接到
#      /dev/null，一个路径都流不出来，函数对任何目录都稳定返回「空集」的摘要
#      da39a3ee5e6b4b0d —— 不报错、不报警，永远说「没变」。重定向只能落在子 shell 上。
#   ⑤ 【v.104】不能用 xargs 喂文件名：它按空白拆词，名字带空格的文件会被拆成两个
#      不存在的路径，错误又被 2>/dev/null 吞掉，结果是「新增了一个文件，指纹却没变」。
#      实测：目录里加 `a b.yaml` 前后指纹完全相同（都是 9ac6a0d0acfed167）。
#      改成 while read 逐行读、一个路径一次 sha1sum，空格只是文件名的一部分。
# 空集摘要不是「没错」而是「看不出对错」，所以这里额外要求：路径给了但一个文件都没
# 找到时，返回空串而不是那个固定值——调用方据此知道「这次没法比」，而不是「一样」。
_bs_content_fp() {
    _cf_dir="${1:-.}"
    _cf_out=$(
        cd "$_cf_dir" 2>/dev/null || exit 3
        _cf_list=$(find . -type f 2>/dev/null | sort | sed 's|^\./||')
        [ -n "$_cf_list" ] || exit 4
        printf '%s\n' "$_cf_list" | while IFS= read -r _cf_f; do sha1sum "$_cf_f" 2>/dev/null; done | sha1sum 2>/dev/null | cut -c1-16
    ) || return 1
    [ -n "$_cf_out" ] || return 1
    printf '%s' "$_cf_out"
}

# ---- 静态配置 sha 基线（v.108.25）----
# 「文件在」「结构对」都只是形式；内容和上次写的那份是不是同一份，只有 sha 说得清。
# 覆盖范围刻意收窄到脚本自己写的那四份文件，不多算一个字节：
#   主配置 config.yaml / 采集源 acquis.d/router.yaml / 两个解析器
# 不比整目录指纹 —— 用户自己在 parsers/ 下加解析器是合理需求，不该判成不符。
CFG_SHA_LIST="etc/crowdsec/config.yaml
etc/crowdsec/acquis.d/router.yaml
etc/crowdsec/parsers/s01-parse/openwrt-dropbear.yaml
etc/crowdsec/parsers/s02-enrich/openwrt-whitelist.yaml"

# 四个文件逐个算 sha256，输出「sha 相对路径」行；缺任何一个都算算不出来
#
# 【v.108.42】config.yaml 不能整文件算进基线。它里面有几行是「设计上每轮必变」的：
#   capi_block    启动前把 online_client 注释掉
#   capi_release  bouncer 验证后把它放回来
# 基线是在 _stamp_write 那一刻写的（那时按设计是「放开态」），而重启态的开机引导
# 一上来就先跑 capi_block 注释 → 文件变了 → LOGCONF 的 verify_acquis 立刻报
# 「解析器/配置 sha 与基线不符」→ build_acquis 怎么写都写不回去（它压根不管
# online_client 那两行）→ hard 退出。
# 首台真机实测（07:15 那一轮，重启后第一次引导）：
#   [日志] 解析器/配置 sha 与基线不符（内容被改动）
#   [日志] 容器内采集配置不符
#   [配置] 解析器 + 日志源 + 白名单已写入
#   [日志] 容器内采集配置写入后仍不符
#   [logconf] 构建执行失败，hard 失败，引导终止（退出码 1）
# 这不是配置被改坏，是判据把「设计内的状态切换」当成了漂移。
# 处理：把这四行剔掉再算 sha —— online_client 与它的 online_api credentials_path。
# （client 段的 local_api credentials_path 不受影响，正则限定了 online_api_credentials.yaml）
_cfg_sha_now() {
    for _r in $CFG_SHA_LIST; do
        [ -f "$ROOTFS/$_r" ] || return 1
        case "$_r" in
            etc/crowdsec/config.yaml)
                _h=$(sed -E \
                        -e '/^[[:space:]]*#?[[:space:]]*online_client:/d' \
                        -e '/credentials_path:[[:space:]]*\/etc\/crowdsec\/online_api_credentials\.yaml/d' \
                        "$ROOTFS/$_r" 2>/dev/null | sha256sum | awk '{print $1}')
                ;;
            *)
                _h=$(sha256sum "$ROOTFS/$_r" 2>/dev/null | awk '{print $1}')
                ;;
        esac
        [ -n "$_h" ] || return 1
        printf '%s  %s\n' "$_h" "$_r"
    done
}

# 一轮跑完（stamp 落盘那一刻）把当时的 sha 记成基线，首行钉住版本号：
# 换了脚本版本就说明产出可能变，旧基线不该拿来判新脚本。
_cfg_sha_write() {
    mkdir -p "$STATE_DIR" 2>/dev/null || return 1
    _cs_new=$(_cfg_sha_now) || return 1
    { printf 'ver=%s\n' "$SCRIPT_VER"; printf '%s\n' "$_cs_new"; } >"$CFG_SHA_FILE.tmp" 2>/dev/null || return 1
    [ -s "$CFG_SHA_FILE.tmp" ] || { rm -f "$CFG_SHA_FILE.tmp" 2>/dev/null; return 1; }
    mv -f "$CFG_SHA_FILE.tmp" "$CFG_SHA_FILE" 2>/dev/null
}

# 判据：当前 sha 与基线逐字节一致。
# 无基线（首次安装还没跑完）或版本已变（基线过期）→ 不拿它下结论，交给结构判据。
verify_cfg_sha() {
    [ -s "$CFG_SHA_FILE" ] || return 0
    [ "$(sed -n '1s/^ver=//p' "$CFG_SHA_FILE" 2>/dev/null)" = "$SCRIPT_VER" ] || return 0
    _cs_now=$(_cfg_sha_now) || return 1
    [ "$_cs_now" = "$(sed -n '2,$p' "$CFG_SHA_FILE" 2>/dev/null)" ]
}

_stamp_present() {
    [ -s "$STAMP_FILE" ]
}

# 从 stamp 里取一个 `k=v` 字段。取不到就给空串（调用方要能区分「没这个字段」）。
_stamp_field() {
    [ -s "$STAMP_FILE" ] || return 0
    sed -n "s/^$1=//p" "$STAMP_FILE" 2>/dev/null | head -n 1
}

# 「容器配置还是不是我上次认下来的那一套」——比内容，不比时间。
_stamp_cfg_changed() {
    _sc_reason=""
    _sc_old_cfg=$(_stamp_field cfg_fp)
    _sc_old_parsers=$(_stamp_field parsers_fp)
    # 老 stamp 没有这两个字段：不是「变了」，是「当初没记」。不能据此判变更 ——
    # 否则所有从旧版本升级上来的机器，第一次开机都要白跑一轮全量复核。
    if [ -z "$_sc_old_cfg" ] && [ -z "$_sc_old_parsers" ]; then
        return 0
    fi
    _sc_new_cfg=$(_bs_content_fp "$ROOTFS/etc/crowdsec") || _sc_new_cfg=""
    _sc_new_parsers=$(_bs_content_fp "$ROOTFS/etc/crowdsec/parsers") || _sc_new_parsers=""
    # 算不出新指纹（目录被删/权限不对）属于「这次没法比」，不在这里下结论，
    # 交给 verify_rootfs 那一层去判「缺东西」。
    [ -n "$_sc_new_cfg" ] || return 0
    if [ "$_sc_old_cfg" != "-" ] && [ "$_sc_old_cfg" != "$_sc_new_cfg" ]; then
        _sc_reason="$_sc_reason cfg($_sc_old_cfg→$_sc_new_cfg)"
    fi
    if [ -n "$_sc_new_parsers" ] && [ "$_sc_old_parsers" != "-" ] \
       && [ "$_sc_old_parsers" != "$_sc_new_parsers" ]; then
        _sc_reason="$_sc_reason parsers($_sc_old_parsers→$_sc_new_parsers)"
    fi
    [ -z "$_sc_reason" ] && return 0
    log "[变更] 容器 crowdsec 配置与上次跑通时的指纹不一致：$_sc_reason"
    return 1
}

# 完整跑通的置位：同时清失败计数与未完成标记（任何一次健康开机都让计数自愈）
_stamp_write() {
    mkdir -p "$STATE_DIR" 2>/dev/null || { log "[stamp] STATE_DIR 不可写（$STATE_DIR），跳过置位"; return 1; }
    # 除了版本与时间，还记下「当时容器配置的指纹」：下次开机比对指纹就知道
    # 「容器里那套东西还是不是我上次认下来的那一套」，比时间可靠。
    _bs_fp_cfg=$(_bs_content_fp "$ROOTFS/etc/crowdsec") || _bs_fp_cfg="-"
    _bs_fp_parsers=$(_bs_content_fp "$ROOTFS/etc/crowdsec/parsers") || _bs_fp_parsers="-"
    atomic_write "$STAMP_FILE" "installed" <<EOF || { log "[stamp] 写入失败"; return 1; }
installed
ver=$SCRIPT_VER
ts=$(date '+%F %T')
cfg_fp=$_bs_fp_cfg
parsers_fp=$_bs_fp_parsers
EOF
    _bs_stamped=1
    # 【v.108.25】顺手把静态配置的 sha 记成基线：这一轮是验证通过的，
    # 它们现在长什么样，就是下一次 verify 要比对的样子。
    _cfg_sha_write || log "[stamp] 配置 sha 基线写入失败（不影响本轮，下次比对会跳过）"
    # 跑通即清账：失败计数、未完成标记、以及「抹盘后未收尾」的连续次数
    rm -f "$REINSTALL_FAIL_FILE" "$REINSTALL_PENDING_FILE" "$INTR_FILE" 2>/dev/null
    log "[stamp] installed 已置位（$STAMP_FILE）：本流程完整跑通过，重装自愈已启用"
    return 0
}

# ---- 重置额度（v.108.19）：每次开机一次 ----
# 语义：重启 = 人主动干预一次，换一次「可以抹盘重建」的权利。
# 同一次开机内无论跑几遍 bootstrap（探针触发、手动重跑），额度都只有一份。
_cur_boot_id() {
    cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d ' \t\r\n'
}

# 本次开机还有额度？（读不到 boot_id 一律当「没有」：宁可少重置，也不在无据可依时抹盘）
_reset_quota_ok() {
    _rq_bi=$(_cur_boot_id)
    [ -n "$_rq_bi" ] || return 1
    [ "$(cat "$RESET_BOOT_FILE" 2>/dev/null | tr -d ' \t\r\n')" != "$_rq_bi" ]
}

# 真正动手抹盘时调用，把额度记到本次开机名下（此后本次开机不再给第二次）
_reset_consume() {
    _rc_bi=$(_cur_boot_id)
    [ -n "$_rc_bi" ] || { log "[重装] 读不到 boot_id，额度无法记账（本次仍只做这一遍）"; return 0; }
    printf '%s\n' "$_rc_bi" | atomic_write "$RESET_BOOT_FILE" "" 2>/dev/null \
        || log "[重装] 额度记账写入失败（$RESET_BOOT_FILE）"
    log "[重装] 本次开机（$_rc_bi）的重置额度已用：${1:-无说明}"
    return 0
}

# ---- rootfs 残留校验（v.108.20）----
# 「已抹盘但没收尾」（断电/崩溃）之后，rootfs 可能是三种样子：
#   ① 根本不存在          → 必须重建，拒绝重置就等于永远不开机
#   ② 存在但是空壳/残缺    → 同上，重建
#   ③ 已解压且可用        → 上次重装其实干完了，只是收尾没跑，按普通失败处理
_rootfs_usable() {
    [ -d "$ROOTFS" ] || return 1
    [ -f "$ROOTFS/etc/os-release" ] || [ -x "$ROOTFS/sbin/init" ]
}

_intr_count() {
    _ic=""
    [ -f "$INTR_FILE" ] && _ic="$(cat "$INTR_FILE" 2>/dev/null)"
    case "$_ic" in ''|*[!0-9]*) _ic=0 ;; esac
    echo "$_ic"
}

_intr_inc() {
    _n=$(( $(_intr_count) + 1 ))
    printf '%s\n' "$_n" | atomic_write "$INTR_FILE" "" 2>/dev/null || true
}

# 半截写/非数字容错当 0（与 bouncer_pulling 的同款防御）
_reinstall_fail_count() {
    _c=""
    [ -f "$REINSTALL_FAIL_FILE" ] && _c="$(cat "$REINSTALL_FAIL_FILE" 2>/dev/null)"
    case "$_c" in ''|*[!0-9]*) _c=0 ;; esac
    echo "$_c"
}

_fail_count_inc() {
    mkdir -p "$STATE_DIR" 2>/dev/null || return 1
    _n=$(( $(_reinstall_fail_count) + 1 ))
    atomic_write "$REINSTALL_FAIL_FILE" "" <<EOF || return 1
$_n
EOF
    log "[重装] 失败计数 → $_n（阈值 $REINSTALL_MAX，达到即停机转人工）"
    return 0
}

# 上次重装没跑完（exec 前后崩溃/断电，EXIT trap 没机会跑）——开机先记账，
# 与 trap 计数两路互斥不重复：没有这路，「每天抹一次」在断电场景会漏计
_pending_recover() {
    [ -f "$REINSTALL_PENDING_FILE" ] || return 0
    log "[重装] 检出未完成的重装标记（上次抹除 rootfs 后进程未正常收尾）"
    # 【v.108.20】抹盘后断电，rootfs 已经是空的——这时拒绝重置不是「防死循环」，
    # 是「让机器永远不开机」。先看残留：该续做的续做，该算失败的算失败。
    if _rootfs_usable; then
        log "[重装] rootfs 残留校验：可用（/etc/os-release 或 /sbin/init 在）→ 上次重装已解压完成，仅补记一次失败"
        _reset_consume "上次抹盘后进程未收尾，但 rootfs 已重建"
        _fail_count_inc
    else
        _ic=$(( $(_intr_count) + 1 ))
        if [ "$_ic" -gt "$INTR_MAX" ]; then
            log "[重装] rootfs 残留校验：连续 $_ic 次「抹盘后仍未收尾」超过上限 $INTR_MAX，停止自动重建，转人工"
            _reset_consume "连续 $_ic 次抹盘后未收尾，超限"
            _fail_count_inc
        else
            _intr_inc
            log "[重装] rootfs 残留校验：不存在/残缺（第 $_ic/$INTR_MAX 次）→ 重建是唯一恢复途径，保留本次重置额度继续做"
        fi
    fi
    rm -f "$REINSTALL_PENDING_FILE" 2>/dev/null
    return 0
}

# exec 接缝：dash 禁 exec 同名函数（实测 Bad function name），测试打桩本函数验证「带标记重跑」
_bs_reexec() {
    _self="$0"
    { [ -n "$_self" ] && [ -f "$_self" ]; } || _self=/usr/sbin/crowdsec-lxc-bootstrap.sh
    log "[重装] 以重装模式重跑全流程：/bin/sh $_self"
    exec /bin/sh "$_self"
}

# 抹前备份 console 凭证：注册码虽可重用不消耗，保留凭证可免网站端多一条机器记录、免一次 Accept
_cred_backup() {
    [ -s "$ROOTFS/$_CRED_REL" ] || { log "[重装] 无 online_api_credentials.yaml，无凭证可备份"; return 0; }
    mkdir -p "$CRED_BACKUP_DIR" 2>/dev/null || { log "[重装] 备份目录不可建（$CRED_BACKUP_DIR）"; return 1; }
    cp -a "$ROOTFS/$_CRED_REL" "$CRED_BACKUP_DIR/" 2>/dev/null || { log "[重装] 凭证备份失败"; return 1; }
    log "[重装] 凭证已备份到 $CRED_BACKUP_DIR"
    return 0
}

# 二遍 rootfs 解压完成后调用：凭证落回新 rootfs + best-effort 重启容器内 crowdsec
_cred_restore() {
    [ -d "$ROOTFS/etc/crowdsec" ] || return 0
    # 【v.108.51】现场已有凭据就不覆盖：开机复核时这份可能比备份更新
    # （本轮刚 register 过），用旧副本盖回去等于把刚注册的身份作废。
    if [ -s "$ROOTFS/$_CRED_REL" ]; then
        log "[凭据] 现场已有 CAPI 凭据，保持不动"
        return 0
    fi
    _cr_src=""
    if [ -s "$CRED_KEEP_FILE" ]; then
        _cr_src="$CRED_KEEP_FILE"
    elif [ -s "$CRED_BACKUP_DIR/online_api_credentials.yaml" ]; then
        _cr_src="$CRED_BACKUP_DIR/online_api_credentials.yaml"
        log "[凭据] 无持久副本，改用重装前备份"
    fi
    if [ -z "$_cr_src" ]; then
        log "[凭据] 无可用备份，enroll 步将用注册码重注册（仅需网站端 Accept）"
        return 0
    fi
    cp -f "$_cr_src" "$ROOTFS/$_CRED_REL" 2>/dev/null \
        || { log "[凭据] 恢复失败（来源 $_cr_src）"; return 1; }
    chmod 600 "$ROOTFS/$_CRED_REL" 2>/dev/null
    log "[凭据] 已恢复 CAPI 凭据（来源 $_cr_src），无需重新 register/enroll"
    ct_running && _ct_restart_crowdsec || true
    return 0
}

# 【v.108.51】把现场凭据存成持久副本（/etc/config 下，靠 base-files-essential 活过刷机）。
# 幂等：内容没变也照抄一遍（162 字节，代价可忽略），但只在首次建文件时打日志。
# --verify-only（探针体检）承诺「一个字节都不写」，那条路径必须跳过。
_cred_keep_save() {
    [ "${_VERIFY_ONLY:-0}" = "1" ] && return 0
    [ -s "$ROOTFS/$_CRED_REL" ] || return 0
    _cks_new=0
    [ -s "$CRED_KEEP_FILE" ] || _cks_new=1
    mkdir -p "$(dirname "$CRED_KEEP_FILE")" 2>/dev/null
    cp -f "$ROOTFS/$_CRED_REL" "$CRED_KEEP_FILE" 2>/dev/null \
        || { log "[凭据] 持久副本写入失败（$CRED_KEEP_FILE），刷机后需重新注册"; return 1; }
    chmod 600 "$CRED_KEEP_FILE" 2>/dev/null
    [ "$_cks_new" = "1" ] && log "[凭据] 已建立持久副本（$CRED_KEEP_FILE），刷机后免重注册"
    return 0
}

# 【v.108.51】判「CAPI 明确拒绝现有凭据」：token 被吊销 / 实例被删 / 403。
# 只认这几句明确报错，不用 console status 的 not registered —— 刚 register、还没
# enroll 时它同样是 not registered，拿它判死会把好凭据删掉，反而退化成重注册。
_capi_cred_rejected() {
    # 【v.108.65】加 timeout 10：这条要问一次中央 API，网络坏但没断时 cscli 会一直等
    # TCP 超时（分钟级），而调用它的 re_enroll 全程持着引导锁 —— 探针的 tick 会被
    # lock-busy 挡到 PROBE_LOCK_STALE（1800s）才回收，等于保护链路停摆半小时。
    # 超时返回 124、输出为空 → 下面的 grep 不匹配 → return 1（不删凭据），方向是安全的。
    _ccr_out="$(_ct_env "timeout 8 $CSCLI capi status" 2>&1)" || true
    printf '%s' "$_ccr_out" \
        | grep -qiE 'invalid credential|unable to authenticate|unauthori[sz]ed|forbidden|wrong credential|(^|[^0-9])40[13]([^0-9]|$)' \
        && return 0
    return 1
}

# 抹前内容级复核（对应用户需求「查看每个组是否置位1」）：只读、只记日志
_reinstall_diag() {
    log "[重装] 抹除前内容级复核（每个组是否就位）"
    verify_img_migrate       >/dev/null 2>&1 && log "[重装]   img_migrate 就绪"       || log "[重装]   img_migrate 未就绪"
    verify_ct_config         >/dev/null 2>&1 && log "[重装]   ct_config 就绪"         || log "[重装]   ct_config 未就绪"
    verify_rootfs            >/dev/null 2>&1 && log "[重装]   rootfs 就绪"            || log "[重装]   rootfs 未就绪（内容级不符即视为损坏）"
    verify_ct_net      >/dev/null 2>&1 && log "[重装]   ct_net 就绪"      || log "[重装]   ct_net 未就绪"
    verify_acquis      >/dev/null 2>&1 && log "[重装]   acquis 就绪"      || log "[重装]   acquis 未就绪"
    verify_ct_resolv   >/dev/null 2>&1 && log "[重装]   ct_resolv 就绪"   || log "[重装]   ct_resolv 未就绪"
    bouncer_pulling   && log "[重装]   bouncer last_pull 判定为在拉" || log "[重装]   bouncer last_pull 失效"
    cs_active_on_host && log "[重装]   bouncer 服务活"         || log "[重装]   bouncer 服务未活"
    nft_table_ready   && log "[重装]   nft 表就绪"             || log "[重装]   nft 表缺失"
    return 0
}

# =====================================================================
# LAPI 起不来时怎么办（v.108.63：砍到一步）
#
# 触发位置：build_lapi_fetch 开头。第 0 档（校正 listen_uri + 重启容器内 crowdsec）
# 建在 _ensure_lapi_exposed 里，已经试过仍不通才进到这里。
#
# 为什么不再分档：原来「LAPI 起不来但文件和配置都正常」是死路 —— 各 verify 都通过
# （它们验的是「文件内容对不对」），build 也改不动什么，于是 hard 退出、探针 5 次后
# 停手，机器一直坏到有人重启。重启一次之所以有用，是因为给了「丢可写层」的机会。
# 这里做的事就是：把「重启才有的那次机会」提前到运行期，但必须带额度。
#
# 只留两步：
#   ① 再探一次（第 0 档刚重启过进程，可能刚好生效）—— 不破坏，零成本；
#   ② 丢可写层 → 回到只读基底。
# 「先诊断再决定」这条路走不通：诊断输出的可信度不足以支撑「不许丢层」这个结论，
# 判错一次就是「明明能修却放过」，而且判据本身要跟着 crowdsec 版本改。详见下面
# 「分档诊断已删除」那段。
#
# 一条贯穿的原则：enroll 完全不参与。它要联网、要人在网页点 Accept，不确定性太大；
# 它掉线不影响 LAPI 链路，也不该让自愈逻辑做任何破坏性动作。

# ---- 分档诊断已删除（v.108.63） ----
# v.108.61~62 在这里放过两档只读诊断：`crowdsec -t` 校验 + 按签名对症处置
# （离线时 hub update 无效、移 decisions.db），再加一道「坏的是谁的文件」的第四道门，
# 用来判断这次该不该丢层。整套东西的前提是「丢层代价高，所以先试着不丢」。
# 真机数据把这个前提推翻了（2026-10-22 实测只读基底）：
#   · hub 五个目录（collections/contexts/parsers/postoverflows/scenarios）齐全；
#   · var/lib/crowdsec/data/crowdsec.db 180224 B 在，凭据 yaml 158 B 在，
#     且与 rootfs 那份 md5 完全相同 → 丢层连机器身份都不改，也不会在 console 多记录；
#   · GeoLite2 两个 mmdb、detect.yaml 都在 → 情报库同样干净回退。
# 也就是说：丢层 = 回到构建时验证过的完整状态，不需要联网、不需要 hub update。
# 那诊断就只剩下坏处 —— 判错了会「明明丢层能修却放过」，而判据本身要维护两版代码。
# 现在配置与规则由 guard 逐字节守着（坏了 60 秒内复原）；守不住的（库、hub 更新、
# 进程状态、缓存）直接丢层回基底。一步到位，不用第二套判据。
# 唯一保留的「先试一次不破坏的」是调用方已经做过的：重启容器内 crowdsec。

# ---- 丢层的资源门 ----
# 磁盘满 / inode 耗尽时丢可写层不只无解，还更糟：重建要写更多数据。
# 读不到容量不拦（无据可依时不该替人做否定判断），但必须记一句。
_l3_res_gate() {
    _lr_avail="$(df -k "$OVL_UPPER" 2>/dev/null | awk 'NR==2{print $4}')"
    case "$_lr_avail" in
    ''|*[!0-9]*)
        log "[自愈] 丢层：读不到可写层可用空间，不拦（但这意味着无法排除磁盘满）"
        ;;
    *)
        if [ "$_lr_avail" -lt 32768 ]; then
            log "[自愈] 丢层被拒：可写层所在分区仅剩 ${_lr_avail}KB（<32MB），重建无从谈起"
            return 1
        fi
        ;;
    esac
    return 0
}

# ---- 丢层的两道门（v.108.63：从四道砍到两道） ----
# 签名门删了：没有 `crowdsec -t` 就没有可靠的「同一个根因」判据，
# 靠现象签名只会恒等（进到这里就一定是 LAPI 不通）—— 那等于把额度永久锁死，
# 比误丢一次更糟。留下的两道回答同一个问题：「凭什么现在可以再抹一次现场」。
#   ① 开机门：同一次开机只给一次。探针每 60 秒会重启 bootstrap，
#      没有这道门就是每 60 秒抹一次（CS_BOOTSTRAP_REINSTALL 只挡同一条进程链）。
#   ② 时间门：距上次不足 6 小时就拒 —— 防反复重启设备、每次白得一次额度。
# 恢复正常**不会**刷新额度：额度只跟开机和时钟走，不看 LAPI 通没通。
_l3_load() {
    L3_BI=""; L3_N=0; L3_TS=0
    [ -s "$L3_STATE" ] || return 0
    # 末位留给旧版本的四字段（曾带签名），读进来丢掉即可
    read -r L3_BI L3_N L3_TS _l3_old_sig <"$L3_STATE" 2>/dev/null || true
    case "$L3_N" in ''|*[!0-9]*) L3_N=0 ;; esac
    case "$L3_TS" in ''|*[!0-9]*) L3_TS=0 ;; esac
    return 0
}

_l3_gate() {
    _l3_load
    _lg_bi="$(_cur_boot_id)"
    if [ -z "$_lg_bi" ]; then
        log "[自愈] 丢层被拒：读不到 boot_id，无据可依时不做破坏性动作"
        return 1
    fi
    if [ "$L3_BI" != "$_lg_bi" ]; then
        [ -n "$L3_BI" ] && log "[自愈] 新的一次开机（boot_id 变了），丢层次数归零"
        L3_N=0
    fi
    if [ "$L3_N" -ge "$L3_MAX" ]; then
        log "[自愈] 丢层被拒：本次开机已用（$L3_N/$L3_MAX 次）。恢复不会刷新额度，只有重启设备才会"
        return 1
    fi
    _lg_now="$(date +%s 2>/dev/null)"
    case "$_lg_now" in ''|*[!0-9]*) _lg_now=0 ;; esac
    if [ "$L3_TS" -gt 0 ] && [ "$_lg_now" -gt 0 ]; then
        _lg_gap=$((_lg_now - L3_TS))
        if [ "$_lg_gap" -lt "$L3_GAP" ]; then
            log "[自愈] 丢层被拒：距上次丢可写层 ${_lg_gap}s，未满 ${L3_GAP}s（防重启循环反复抹盘）"
            return 1
        fi
    fi
    printf '%s %s %s\n' "$_lg_bi" "$((L3_N + 1))" "$_lg_now" \
        | atomic_write "$L3_STATE" "" 2>/dev/null \
        || log "[自愈] 丢层记账写入失败（$L3_STATE），本次仍只做这一遍"
    log "[自愈] 丢层放行：本次开机第 $((L3_N + 1))/$L3_MAX 次"
    return 0
}

# ---- 丢层前把「机器身份会不会变」说清楚 ----
# 2026-10-22 真机核对：基底里 local_api_credentials.yaml（158 B）与 crowdsec.db
# （180224 B）成对存在，而现场那份凭据与基底 md5 完全相同 → 这台机器从未重新注册，
# 丢层不改身份。但这是「现在如此」，不是一个可以写死的假设：哪天换过 key、重新
# register 过，丢层就会把凭据回退成基底那份，console 里多一条 offline 记录。
# 所以要现算现说，而不是在文档里断言「丢层无代价」。
_l3_cred_delta() {
    _cd_a="$ROOTFS/etc/crowdsec/local_api_credentials.yaml"
    _cd_b="$ROM_BASE/etc/crowdsec/local_api_credentials.yaml"
    if [ ! -s "$_cd_a" ]; then
        log "[自愈] 机器身份：现场无凭据文件，丢层后由基底带回一份"
        return 0
    fi
    if [ ! -s "$_cd_b" ]; then
        log "[自愈] 机器身份：基底无凭据，丢层后凭据为空，需 bouncer_fill 重新注册（要重新 Accept）"
        return 0
    fi
    _cd_ha="$(md5sum "$_cd_a" 2>/dev/null | cut -d' ' -f1)"
    _cd_hb="$(md5sum "$_cd_b" 2>/dev/null | cut -d' ' -f1)"
    if [ -n "$_cd_ha" ] && [ "$_cd_ha" = "$_cd_hb" ]; then
        log "[自愈] 机器身份：现场凭据与基底一致（运行期未重新注册），丢层不改变机器身份"
    else
        log "[自愈] 机器身份：现场凭据与基底不同（运行期重新注册过），丢层会回退成基底那份，console 里可能多一条 offline 记录"
    fi
    return 0
}

# ---- 丢层执行 ----
# 与 full_reinstall 的区别只在「谁有资格调它」：那条走结构性损坏 + 开机首跑，
# 这条走 LAPI 不通。破坏动作本身完全一致 —— 基底只读不动，
# 丢 upper/work 即回到构建时验证过的状态。
_l3_reset_overlay() {
    log "[自愈] 丢可写层，回到只读基底（回不来的东西：hub 更新、决策库历史、日志、machines 记录）"
    _l3_cred_delta
    _cred_backup || log "[自愈] 凭证备份失败，继续 —— bouncer_fill 会重新注册"
    ct_force_stop || { log "[自愈] 容器强停失败，放弃丢层（现场一个字节没动）"; return 1; }
    _overlay_umount || log "[自愈] overlay 卸载未成功，继续尝试抹除"
    rm -rf "$OVL_UPPER" "$OVL_WORK" 2>/dev/null \
        || { log "[自愈] 可写层抹除失败，放弃"; return 1; }
    : > "$REINSTALL_PENDING_FILE" 2>/dev/null || log "[自愈] 未完成标记写入失败（断电将漏计一次）"
    export CS_BOOTSTRAP_REINSTALL=1
    _bs_reexec
    return 1
}

# ---- 主入口 ----
# 返回 0 = 已修好（调用方继续走正常流程）；1 = 没修好（调用方按原逻辑记失败）
_lapi_ladder() {
    # 丢层后重跑时不再进：否则「丢层 → 重跑 → 又丢层」就是递归
    if [ "${CS_BOOTSTRAP_REINSTALL:-0}" = "1" ]; then
        log "[自愈] 本次已是丢层后流程，不再介入"
        return 1
    fi
    # 再探一次：调用方刚重启过容器内 crowdsec，可能刚好生效
    if verify_lapi_reachable; then
        log "[自愈] 重启进程后 8080 已通，不丢层"
        return 0
    fi
    if [ ! -d "$ROM_BASE" ]; then
        log "[自愈] 无只读基底（$ROM_BASE），丢层不可用（老固件只能走镜像解压）"
        return 1
    fi
    _l3_res_gate || return 1
    if ! _l3_gate; then
        log "[自愈] 丢层被拒 → 剩下的可能：基底本身有问题、宿主侧（overlay/磁盘/端口占用）。这三类抹现场都无效，转人工"
        return 1
    fi
    _l3_reset_overlay
    return 1
}

# 结构性损坏判定（v.106 起：自动重装的唯一理由）
# 为什么要有这个函数：修复动作就是脚本的全部能力。「脚本修了还是不行」只说明
# 修复能力对自己负责的那些配置项失效了，不说明容器需要重建 —— 重装跑的是同一套
# 脚本、同一份镜像，只会把同样的失败再走一遍，还要先 rm -rf 掉现场证据。
# 真正值得重建的只有一种情况：脚本再怎么修也够不着的东西被外部破坏了：
#   · rootfs 目录残缺（连 /etc 都没有）——磁盘满、半截解压、被误删
#   · rootfs 没有 init/systemd  ——任何 build_* 都只管配置，不补二进制
#   · 容器目录不可写            ——路径权限/磁盘只读，重装也是同一个地方
# 注意：只看「够不着」的东西。配置不符、last_pull 停滞、组未置位都不在此列，
# 那些都属于「脚本能修」，修不好就走 hard + 探针重试，绝不抹盘。
_structurally_broken() {
    if [ ! -d "$ROOTFS/etc" ]; then
        log "[结构] rootfs 缺 /etc（目录残缺），判定结构性损坏"
        return 0
    fi
    # 【v.108.17】容器必备资产缺失也算结构性损坏，统一由 ensure 转 full_reinstall。
    # 判据是「资产还在不在」（-s 比 -f 严一档：空文件等于没装），不是「内容对不对」——
    # 内容对不对由各自的 verify_* 判，这里只回答「重解压镜像能不能救」。
    # 覆盖的是一整类：容器里该有的文件被删/被清空/根本没解压出来。
    # v.109-min：init 类型决定「哪些文件算必备」——systemd 版看 crowdsec.service，
    # 极简版看 inittab + init.d/crowdsec。两套都要求 usr/bin/crowdsec 与 os-release。
    if _is_minimal_init; then
        # 【v.108.45】不再列 etc/inittab 与 etc/init.d/crowdsec。
        # 原因：从这一版起，固件里也有这 6 个容器脚本的副本（供 crowdsec-guard 拿
        # /rom squashfs 当只读基准），于是 `-s $ROOTFS/etc/inittab` 在 rootfs
        # 根本没解压时**同样成立**（读的是 squashfs 下层）—— 判据恒真，等于没判。
        # 它们的「存在 + 内容」交给 guard：guard 每轮 cmp，改坏/删掉 60 秒内补回，
        # 代价几十 KB，比整盘重解压 288MB 合理得多。
        # 这里只留**固件里没有**的文件：没有 → 只可能来自 tarball 解压 → 缺了就是真缺。
        _sb_list="$ROOTFS/etc/os-release $ROOTFS/bin/busybox
                  $ROOTFS/usr/bin/crowdsec $ROOTFS/etc/crowdsec/acquis.yaml"
        # os-release 还有第二重身份：它是 verify_rootfs 的「rootfs 已解压」标志。
        # 缺它时其余判据都可能因固件副本而恒真，所以这里单独先判、直接定性。
        if [ ! -s "$ROOTFS/etc/os-release" ]; then
            log "[结构] rootfs 缺 /etc/os-release（未解压或已损坏），判定结构性损坏"
            return 0
        fi
    else
        _sb_list="$ROOTFS/lib/systemd/system/crowdsec.service"
    fi
    for _sb_f in \
        $_sb_list \
        "$ROOTFS/usr/bin/crowdsec" \
        "$ROOTFS/etc/os-release"; do
        if [ ! -s "$_sb_f" ]; then
            log "[结构] rootfs 缺 ${_sb_f#$ROOTFS}（容器资产残缺），判定结构性损坏"
            return 0
        fi
    done
    if [ ! -e "$ROOTFS/sbin/init" ] && [ ! -e "$ROOTFS/lib/systemd/systemd" ]; then
        log "[结构] rootfs 既无 /sbin/init 也无 systemd，判定结构性损坏"
        return 0
    fi
    if ! mkdir -p "$LXC_PATH/$LXC_NAME" 2>/dev/null; then
        log "[结构] 容器目录不可写（$LXC_PATH/$LXC_NAME），判定结构性损坏"
        return 0
    fi
    return 1
}

# 五道门：全过返 0（调用方执行重装）；任一不过返 1（维持 hard 终止）
_escalate_reinstall() {
    # ①【v.106】唯一的重装理由：结构性损坏。
    #   原来这里是「last_pull 判定为在拉 → 不升级」，等价于把 last_pull 失效当成
    #   重装前提；现在 last_pull 的持续监视已整体移交运行期探针，修不好只报人工介入，
    #   所以这一门换成结构判定，语义反转过来：不是 last_pull 说了算，是资产完好度说了算。
    _structurally_broken || {
        log "[重装] 非结构性损坏（rootfs / init / 容器目录均完好），不重装"
        return 1
    }
    _stamp_present || {
        log "[重装] 无 installed 标记（本流程未曾完整跑通/初次安装），不自动重装，防开机反复重置"
        return 1
    }
    # ②【v.108.18】重启之后才重置：只有「本次开机首跑」允许重置。
    #   运行期重跑（探针 60s 轮询触发、手动重跑）时 boot_id 没变 → 不是首跑 → 拒绝重置。
    #   运行期多半是容器被停掉/网络抖动这类可修问题，修一下就好；抹 rootfs 既中断现场又没必要。
    if [ "${_BS_FIRST_RUN:-0}" != 1 ]; then
        log "[重装] 本次开机已跑过引导（非重启后首跑），不重置；先走原地修复"
        return 1
    fi
    # ③【v.108.19】额度门：本次开机只能重置一次。
    #   ②说的是「这次跑得早不早」，③说的是「这次开机还欠不欠你一次」。两者都要：
    #   ②挡探针在运行期重跑，③挡同一次开机里「首跑失败 → 再重启脚本再抹一遍」。
    if ! _reset_quota_ok; then
        log "[重装] 本次开机（$(_cur_boot_id)）的重置额度已用完，不再重置；转人工介入"
        return 1
    fi
    # ④ 本次开机的失败次数。reinstall_fail 在每个新开机的首跑处清零（见 main），
    #   所以它数的是「这次开机重置过几次、成没成」，不再是终身累计。
    _c=$(_reinstall_fail_count)
    if [ "$_c" -ge "$REINSTALL_MAX" ]; then
        log "[重装] 本次开机已重置失败 $_c 次（阈值 $REINSTALL_MAX），停止自动重装，转人工介入"
        return 1
    fi
    if [ "${CS_BOOTSTRAP_REINSTALL:-0}" = 1 ]; then
        log "[重装] 本次已是重装后流程，禁止递归重装"
        return 1
    fi
    # overlay 模式下基底在 squashfs 里只读，不存在「镜像被打断」这回事
    [ -d "$ROM_BASE" ] || verify_img_migrate || {
        log "[重装] 镜像不可用（$TARBALL gzip -t 不过），没有好镜像宁可失败也不抹 rootfs"
        return 1
    }
    return 0
}

full_reinstall() {
    log "[重装] 结构性损坏，进入彻底重装流程（v.106 起这是自动重装的唯一入口）"
    _escalate_reinstall || { log "[重装] 不满足重装条件，维持 hard 终止"; return 1; }
    _reinstall_diag
    _cred_backup || true
    ct_force_stop || { log "[重装] 容器 3 轮强停仍未停，放弃重装"; return 1; }
    # 【v.108.19】到这一步才开始破坏性动作，此时才把额度记掉。
    # 放在强停之后是有意的：强停失败时 rootfs 一个字节都没动，不该白丢一次机会。
    _reset_consume "结构性损坏，已强停容器并即将抹除 rootfs"
    _overlay_umount || log "[重装] overlay 卸载未成功，继续尝试抹除"
    if [ -d "$ROM_BASE" ]; then
        # 基底只读不动，丢可写层即可；ROOTFS 是挂载点，清它没有意义
        rm -rf "$OVL_UPPER" "$OVL_WORK" 2>/dev/null \
            || { log "[重装] 可写层抹除失败，放弃重装"; return 1; }
    else
        rm -rf "$ROOTFS" 2>/dev/null || { log "[重装] rootfs 抹除失败，放弃重装"; return 1; }
    fi
    : > "$REINSTALL_PENDING_FILE" 2>/dev/null || log "[重装] 未完成标记写入失败（断电将漏计一次）"
    export CS_BOOTSTRAP_REINSTALL=1
    _bs_reexec
    # exec 成功则不返回；exec 失败（理论上不发生）则由 EXIT trap 兜底计数
    return 1
}

# =====================================================================
# 置位恢复（三类，见各函数注释）

# ① 进程内变量归零。_bs_clear_flags 幂等：重复调用无副作用。
# v.99 起置位的值是 V:<ts>/B:<ts>/R:<ts>，所以「归零」= 清成空串（不是写成 0）。
_bs_clear_flags() {
    for _cf_n in $DAG_NODES; do
        _bs_flag_clear "_done_$_cf_n"
        _bs_flag_clear "_dirty_$_cf_n"
    done
    for _cf_g in $GROUP_SEQ; do
        _bs_flag_clear "GSET_$_cf_g"
    done
    _failed=""; _group_failed=""; _ro_missing=""
    return 0
}

# 【v.108.44】收尾清账：清掉「本来就不归 uci flush 管」的脏标记。
# 为什么会有残留：_dirty_<节点> 由 ensure() 统一置位（语义是「这个节点动过东西」，
#   不等于「这个节点动过 uci」）；而 flush_uci 每次把 DAG 里**所有** dirty 清空，
#   所以只要某节点是在最后一次 flush 之后才置位的，它就会一直留到进程退出。
#   首台真机实测 #37：done=26 dirty=1 gset=8 built=13，逐项是 _dirty_capi_release=B。
#   capi_release 改的是容器内 online_api_credentials.yaml / config.yaml（非 uci），
#   永远不会被 flush_uci 的 commit/reload 认领，于是那条标记永远清不掉。
# 为什么必须清：留着它只有一个后果 —— 每次退出都打一行 dirty=1。而这个数字的用途
#   正是「有没有改动没落盘」。常年是 1，真出现落盘失败时也没人会注意到那个 1。
#   也就是说这条残留不是「多打一行日志」，是让一个安全信号失效。
# 只清、不提交：该提交的在 flush_uci 里早提交过了，这里清的是「本来就不归它管」的那几笔。
_settle_dirty() {
    _sd_list=""
    for _sd_n in $DAG_NODES; do
        _bs_flag_on "_dirty_$_sd_n" && _sd_list="$_sd_list $_sd_n"
    done
    for _sd_n in $DAG_NODES; do _bs_flag_clear "_dirty_$_sd_n"; done
    [ -n "$_sd_list" ] && log "[收尾] 脏标记清账：$_sd_list（非 uci 改动，不归 flush 管，清掉以免 dirty 计数失真）"
    return 0
}

# 统计当前还残留多少置位（用于退出日志：正常应为 0）
# 除了总数，还给出「多少是 build 改的、多少是 verify 本来就过的」——
_bs_flag_stats() {
    # 名字列表先用变量攒好再展开：$(for ...) 直接写在调用处，加引号会变成单个参数，
    # 不加引号 shellcheck 报 SC2046（虽然这里正是想要分词）。
    # 拆成「先赋值、再不加引号展开」两头都干净，也不用灌 disable 指令。
    _fs_dl=""; _fs_bl=""; _fs_gl=""
    for _x in $DAG_NODES; do _fs_dl="$_fs_dl _done_$_x"; _fs_bl="$_fs_bl _dirty_$_x"; done
    for _x in $GROUP_SEQ; do _fs_gl="$_fs_gl GSET_$_x"; done
    _fs_done=$( _bs_flag_count D $_fs_dl )
    _fs_dirty=$( _bs_flag_count D $_fs_bl )
    _fs_gset=$( _bs_flag_count D $_fs_gl )
    _fs_built=$( _bs_flag_count B $_fs_dl )
    printf 'done=%s dirty=%s gset=%s built=%s\n' "$_fs_done" "$_fs_dirty" "$_fs_gset" "$_fs_built"
}

# ② ip_forward 恢复。启动时快照原值，退出时按「是否成功引导」决定要不要写回。
IPFWD_SENTINEL="$STATE_DIR/ip_forward.by-bootstrap"

_ipfwd_snapshot() {
    _cur=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)
    [ -n "$_cur" ] || _cur=""
    _ipfwd_touched=0
    case "$_cur" in
        1)
            if [ -f "$IPFWD_SENTINEL" ]; then
                # 上次是脚本置的，且还没还原（上次异常退出）。真原值按 0 算。
                _ipfwd_orig=0
                log "[恢复] 检出上次遗留的 ip_forward 哨兵：当前 1 是本脚本置的，按原值 0 处理"
            else
                _ipfwd_orig=1     # 别人设的，不动
            fi
            ;;
        0|"")
            _ipfwd_orig=0
            # 系统已自己回 0（重启过了）：顺手把残留哨兵清掉，免得下次误判
            [ -f "$IPFWD_SENTINEL" ] && rm -f "$IPFWD_SENTINEL" 2>/dev/null
            ;;
        *)
            _ipfwd_orig="$_cur"
            ;;
    esac
    return 0
}
# 记号：置了 1，就落下哨兵（供下次进程判断"这个 1 是我置的"）
_ipfwd_mark() {
    mkdir -p "$STATE_DIR" 2>/dev/null
    : > "$IPFWD_SENTINEL" 2>/dev/null || return 0
    return 0
}
_ipfwd_restore() {
    # 本轮没动过它，或没拿到原值：无需恢复
    [ "${_ipfwd_touched:-0}" = 1 ] || return 0
    [ -n "${_ipfwd_orig:-}" ] || return 0
    # 引导成功（写了 installed）→ 保留 1，这是期望稳态，写回 0 反而把容器网搞断。
    # 此时哨兵留着，表示"这个 1 是脚本的"，下次重跑能正确判定原值。
    [ "${_bs_stamped:-0}" = 1 ] && return 0
    # --net-only 跑通同理：没有容器，但路由器自身的转发必须保持 1。
    # 这条路径永远写不到 installed 标记，不能靠 _bs_stamped 兜住。
    [ "${_NET_ONLY_OK:-0}" = 1 ] && return 0
    _ir_cur=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)
    if [ "$_ir_cur" = "$_ipfwd_orig" ]; then
        rm -f "$IPFWD_SENTINEL" 2>/dev/null
        return 0
    fi
    if echo "$_ipfwd_orig" >/proc/sys/net/ipv4/ip_forward 2>/dev/null; then
        rm -f "$IPFWD_SENTINEL" 2>/dev/null   # 还原成功，哨兵使命结束
        log "[恢复] 引导未成功，ip_forward 已还原为 $_ipfwd_orig（原值）"
    else
        log "[恢复] 引导未成功，但 ip_forward 还原失败（/proc 只读），当前值 $_ir_cur"
        log "[恢复] 哨兵保留：下次重跑时仍能认出这个 1 是脚本置的"
    fi
    return 0
}

# ③ reinstall_pending 状态说明（只报告，不动文件）
_pending_report() {
    [ -f "${REINSTALL_PENDING_FILE:-}" ] || return 0
    log "[恢复] 重装未完成标记仍在（$REINSTALL_PENDING_FILE）：本次退出被判定为中途失败，下次开机将计一次失败。这是设计行为，不是漏清理"
    return 0
}

# EXIT trap 回调。做两件事，顺序要紧：
#   先做「重装失败计数」（要用到当前的 stamp/pending 状态），
#   再做「置位恢复」（把进程内变量归零、按需还原内核态）。
_bs_on_exit() {
    # ---- 第一部分：重装失败计数 ----
    if [ "${CS_BOOTSTRAP_REINSTALL:-0}" = 1 ] \
       && [ "${_bs_st:-0}" -ne 0 ] \
       && [ "${_bs_stamped:-0}" != 1 ]; then
        log "[重装] 重装后流程以退出码 $_bs_st 收场，计一次失败"
        _fail_count_inc
        rm -f "$REINSTALL_PENDING_FILE" 2>/dev/null
    fi

    # ---- 第二部分：置位恢复 ----
    # 只在「真有东西要恢复」时才打日志——正常跑完的路径上置位本来就该归零，
    # 每次都打两条「快照/已归零」只会把日志淹掉（跳过 DAG 的极简路径尤其明显）。
    if command -v _bs_flag_stats >/dev/null 2>&1; then
        _bx_snap=$(_bs_flag_stats)
        if [ "$_bx_snap" != "done=0 dirty=0 gset=0 built=0" ] \
           || [ "${_ipfwd_touched:-0}" = 1 ] \
           || [ -f "${REINSTALL_PENDING_FILE:-}" ]; then
            log "[恢复] 退出时置位快照：$_bx_snap（退出码 ${_bs_st:-?}）"
            # v.99：光有计数看不出「哪几个、什么时候置的」，真出问题时要翻半天。
            # 这里把每个已置位的名字连同 V/B/R 与时间戳打一行，日志本身就是现场。
            _bx_list=""
            for _bx_n in $DAG_NODES; do _bx_list="$_bx_list _done_$_bx_n _dirty_$_bx_n"; done
            for _bx_g in $GROUP_SEQ; do _bx_list="$_bx_list GSET_$_bx_g"; done
            _bx_dump=$(_bs_flag_dump $_bx_list)
            [ -n "$_bx_dump" ] && log "[恢复] 逐项：$_bx_dump"
            _ipfwd_restore
            _pending_report
            _bs_clear_flags
            log "[恢复] 置位已全部归零：$(_bs_flag_stats)"
        else
            # 干净退出：静默归零，不留噪音
            _ipfwd_restore
            _bs_clear_flags
        fi
    fi
    return 0
}

# 信号处理：INT/TERM/HUP 与 EXIT 走同一条恢复路径。
# 不装这几个的话，被 kill / SSH 断线时 EXIT trap 未必触发（dash 下 SIGTERM 默认
# 直接终止进程、不走 EXIT），置位与内核态就留在半截状态里。
_bs_on_signal() {
    _bs_sig="$1"
    # 三个信号 trap 全部摘掉：防止处理过程中再来一个信号把恢复逻辑打断、跑两遍。
    trap - INT TERM HUP
    log "[恢复] 收到信号 SIG$_bs_sig，按异常退出处理"
    _bs_st=143
    _bs_on_exit
    # 【必须连 EXIT trap 一起摘掉】否则下面的 exit 会再触发一次 EXIT trap，
    # 恢复逻辑跑第二遍：日志里会出现两条「置位快照/已归零」，
    # ip_forward 也可能被记成"还原过两次"。这个坑第一次就踩到了。
    trap - EXIT
    exit 143
}

console_enroll_ok() {
    # ① 首选 cscli console status：它直接回答「这台机器有没有绑到 console」。
    #    ⚠️【v.108.52 根因修正】真机输出（24.10，网页端关闭实例后，2026-10-22）：
    #      | Central API (CAPI) | ✅ authenticated |
    #      | Enrolled           | ❌ not enrolled  |
    #    CAPI 的 authenticated 与 console 的 Enrolled 是**两件事**：网页上把实例
    #    「关闭/删除」后，CAPI 凭据照样被接受（authenticated），只有 Enrolled 变成
    #    not enrolled。v.108.51 及之前只 grep 字符串 'not registered'，于是把
    #    「未注册」误判成「已注册」→ verify_enroll 直接 return 0 → 设备永远发现不了
    #    自己被摘掉，也就永不重注册。这就是「网页端不小心关闭后路由器不回来」的根因
    #    （比「注册成功即删 key」更前置：判据先瞎了，key 根本轮不到被用）。
    #    两个词都要认：老版 cscli 用 not registered，新版用 not enrolled。
    #    加 timeout 是因为这条会顺带问一次中央 API，网络不好时可能挂住。
    _out="$(_ct_env "timeout 8 $CSCLI console status" 2>&1)"
    if printf '%s' "$_out" | grep -qiE 'enrolled|central api'; then
        printf '%s' "$_out" | grep -qiE 'not[[:space:]]*-?[[:space:]]*(enrolled|registered)' && return 1
        return 0
    fi
    # ② 退回 capi status 的 enrolled 判据（console status 不可用时的兜底）
    _out="$(_ct_env "timeout 8 $CSCLI capi status" 2>&1)"
    [ -n "$_out" ] || return 1
    _line="$(printf '%s\n' "$_out" | grep -i 'enrolled' | head -n1)"
    [ -n "$_line" ] || return 1
    printf '%s\n' "$_line" | grep -qiE 'not enrolled|(^|[^[:alnum:]_])false' && return 1
    return 0
}

_wait_capi_net() {
    _wn_max="${1:-30}"
    _wn_dl=$(( $(date +%s) + _wn_max ))
    while [ "$(date +%s)" -lt "$_wn_dl" ]; do
        ct_running || { log "[enroll] 容器已停止，放弃等待 DNS 就绪"; return 1; }
        # getent 在极简版里没有（busybox 1.35 静态版不带该 applet），nslookup 一定有 ——
        # 只写 getent 会让 enroll 永远卡在「30 秒内解析不到」，而容器 DNS 其实是好的。
        _ct_env "timeout 2 getent hosts api.crowdsec.net" >/dev/null 2>&1 && return 0
        _ct_env "timeout 2 nslookup api.crowdsec.net" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

# ---- 注册码保管（v.108.52：由「注册成功即删」改为「移入保险柜」）----
# 历史包袱：v.99-bp.1 起注册成功就 rm 掉 key，理由是固件公开下载、明文不该留在设备上。
# 但 key 同时也是设备唯一的自愈凭据 —— 删掉之后网页端一旦把实例关掉/删掉，
# re_enroll 读不到 key 只能放弃，用户只能重刷固件或手动 enroll。
# 现在改为两处存放：
#   主文件 $ENROLL_KEY_FILE       固件里带的（一次性的，注册成功后不再需要）
#   保险柜 $ENROLL_KEY_KEEP(.keep) 600，注册成功后搬到这里，sysupgrade 默认保留
# 读取顺序：主文件 → 保险柜。
_park_enroll_key() {
    [ -f "$ENROLL_KEY_FILE" ] || return 0
    _pek_new="$(head -n1 "$ENROLL_KEY_FILE" 2>/dev/null | tr -d ' \t\r\n')"
    [ -n "$_pek_new" ] || { rm -f "$ENROLL_KEY_FILE" 2>/dev/null; return 0; }
    _pek_old=""
    [ -s "$ENROLL_KEY_KEEP" ] && _pek_old="$(head -n1 "$ENROLL_KEY_KEEP" 2>/dev/null | tr -d ' \t\r\n')"
    if [ -f "$ENROLL_KEY_KEEP" ] && [ "$_pek_old" = "$_pek_new" ]; then
        # 保险柜里已经是同一把码，主文件多余
        rm -f "$ENROLL_KEY_FILE" 2>/dev/null
        log "[enroll] 注册码已在保险柜（$ENROLL_KEY_KEEP），清掉主文件"
        return 0
    fi
    if mv -f "$ENROLL_KEY_FILE" "$ENROLL_KEY_KEEP" 2>/dev/null; then
        chmod 600 "$ENROLL_KEY_KEEP" 2>/dev/null
        log "[enroll] 注册码已移入保险柜（$ENROLL_KEY_KEEP，600）：网页端被摘后可自动重注册"
    else
        rm -f "$ENROLL_KEY_FILE" 2>/dev/null
        log "[enroll] 注册码移入保险柜失败，已删除主文件（下次被摘需手动 enroll）"
    fi
    return 0
}

# 读注册码：主文件 → 保险柜 两级回落。
# 结果放全局 $_ENROLL_KEY_V，不写 stdout —— log() 走 stdout，用 $(...) 取值会被日志污染。
_enroll_key_load() {
    _ENROLL_KEY_V=""
    if [ -s "$ENROLL_KEY_FILE" ]; then
        _ENROLL_KEY_V="$(head -n1 "$ENROLL_KEY_FILE" 2>/dev/null | tr -d ' \t\r\n')"
        [ -n "$_ENROLL_KEY_V" ] && return 0
    fi
    if [ -s "$ENROLL_KEY_KEEP" ]; then
        _ENROLL_KEY_V="$(head -n1 "$ENROLL_KEY_KEEP" 2>/dev/null | tr -d ' \t\r\n')"
        [ -n "$_ENROLL_KEY_V" ] \
            && log "[enroll] 主注册码缺失，改用保险柜里的注册码（$ENROLL_KEY_KEEP）"
    fi
    return 0
}

# ---- 提交记录（v.108.54：只记录，不再当闸门）----
# console enroll 成功 ≠ 本地已注册：必须有人去 app.crowdsec.net 点 Accept。
# 这段间隔里 console status 必然是 not enrolled，不能拿它判失败。
# 判定改由「本次开机是否已提交过」（进程变量 _ENROLL_TRIED）承担，这里只留个时间戳备查。
_enroll_submit_mark() {
    [ "${_VERIFY_ONLY:-0}" = "1" ] && return 0     # 体检承诺「一个字节都不写」
    printf '%s\n' "$(date +%s)" > "$ENROLL_SUBMIT_FILE" 2>/dev/null \
        && chmod 600 "$ENROLL_SUBMIT_FILE" 2>/dev/null
    return 0
}
_enroll_submit_clear() {
    [ "${_VERIFY_ONLY:-0}" = "1" ] && return 0
    [ -f "$ENROLL_SUBMIT_FILE" ] && rm -f "$ENROLL_SUBMIT_FILE" 2>/dev/null
    return 0
}

re_enroll() {
    log "[enroll] console 未注册，用注册码 enroll（注册码固定有效，可反复使用，不消耗）"

    # v.108.52：主文件缺失时回落到保险柜 —— 网页端把实例关掉后，靠这里自愈。
    _enroll_key_load
    _enroll_key="$_ENROLL_KEY_V"
    if [ -z "$_enroll_key" ]; then
        log "[enroll] 无注册码（$ENROLL_KEY_FILE / $ENROLL_KEY_KEEP 都缺失或为空），放弃 enroll"
        log "[enroll] 补救：网页端 app.crowdsec.net 取注册码后执行 cscli console enroll <key>"
        return 1
    fi

    verify_snat || { log "[enroll] SNAT 缺失/不符，重建"; rebuild snat; }

    if ! _wait_capi_net 30; then
        log "[enroll] 30 秒内仍无法解析 api.crowdsec.net（容器 DNS 未就绪），放弃本次 enroll"
        return 1
    fi

    _cred_file="$ROOTFS/etc/crowdsec/online_api_credentials.yaml"

    # 【v.108.51】凭据还在但 CAPI 明确不认（token 被吊销、实例在 console 里被删）：
    # 不重建就永远 enroll 不了 —— 老逻辑只看「文件非空」，会把坏凭据当好凭据一路用下去。
    if [ -s "$_cred_file" ] && _capi_cred_rejected; then
        log "[enroll] CAPI 拒绝现有凭据（失效/被吊销），删除后重建"
        rm -f "$_cred_file" 2>/dev/null
    fi

    if [ ! -s "$_cred_file" ]; then
        log "[enroll] online_api_credentials.yaml 缺失，先 cscli capi register 注册 CAPI 凭据"
        if ! _capi_reg_out="$(_ct_env "timeout 8 $CSCLI capi register" 2>&1)"; then
            log "[enroll] capi register 失败：$(printf '%s' "$_capi_reg_out" | tr '\n' ' ' | cut -c1-300)"
            return 1
        fi
        log "[enroll] capi register 成功，凭据已写入 online_api_credentials.yaml"
    fi

    # 【v.108.65】这是整个引导里唯一用 5s 的地方，也是唯一「等下去没有意义」的地方：
    # 提交后要等云端应答，而网页端不点 Accept 就会一直停在注册状态（现场遇到过）。
    # 挂住的代价是引导锁不放 + 探针 tick 全被挡。
    # 5s 的依据：① 走到这里说明 _wait_capi_net 已确认 api.crowdsec.net 可解析；
    # ② 注册是 POST，云端 5s 不答再等也不会有结果，只会继续占着锁。
    # 其余几条（console status / capi status / capi register）保持 10s：
    # 它们要的是应答内容，多等几秒才有结果，卡住也不等于「网页没点」。
    # 超时（rc=124）走下面的失败分支：记「注册码未消耗，下次开机重试」，不会重复提交。
    if ! _enroll_out="$(_ct_env "timeout 5 /usr/bin/cscli console enroll \"$_enroll_key\"" 2>&1)"; then
        log "[enroll] enroll 执行失败：$(printf '%s' "$_enroll_out" | tr '\n' ' ' | cut -c1-300)"
        log "[enroll] 注册码未消耗，下次开机重试"
        return 1
    fi
    log "[enroll] enroll 命令返回成功：$(printf '%s' "$_enroll_out" | tr '\n' ' ' | cut -c1-200)"

    # 【v.108.53】提交成功立刻落盘时间戳（备查用；判定靠 _ENROLL_TRIED）。
    _enroll_submit_mark
    log "[enroll] 已记录提交时间（$ENROLL_SUBMIT_FILE）；本次开机不再重复提交（重启可再试一次）"

    # 【v.108.69】原来这里还有一条 `cscli console enable --all`，已删除 —— 不是
    # 「没用」，是反向作用：它把 /etc/crowdsec/console.yaml 的四个共享开关全翻成
    # true（含 share_manual_decisions，即把本机手动封的 IP 上报 CrowdSec 云端），
    # 而 console.yaml 不在 guard 白名单里，60 秒内就被 /rom 只读基底盖回 false。
    # 真机日志（2026-10-24 06:52:18）抓到过这次复原，差异正是
    #   share_manual_decisions: false→true、share_context: false→true。
    # 它从 v.108.49 起一次都没生效过，只多一次写盘 + 一次复原 + 一行日志。
    # 删掉比给它开白名单更对：白名单等于把「手动封禁上报」永久化。
    # 代价：console 网页的「共享统计」保持出厂默认（关）。要开就手动 cscli，
    # 并同时把 console.yaml 加进 guard 白名单，否则 60 秒后仍会被盖回。
    # 【v.108.64】capi status 仍要超时：它问云端，而此刻仍持着引导锁；
    # 失败无害（空就跳过打印），但「挂住」有害（引导锁不放 + 探针 tick 全被挡）。
    _ct_restart_crowdsec || true

    _capi_out="$(_ct_env "timeout 8 $CSCLI capi status" 2>&1)"
    [ -n "$_capi_out" ] && log "[enroll] capi status：$(printf '%s' "$_capi_out" | tr '\n' ' ' | cut -c1-200)"

    _i=0
    while [ "$_i" -lt 2 ]; do
        _i=$((_i+1))
        if console_enroll_ok; then
            log "[enroll] 已注册（Enrolled）；网页端 Accept 后 CAPI 才 authenticated，无需脚本干预"
            _enroll_submit_clear
            _park_enroll_key
            return 0
        fi
        sleep 5
    done

    log "[enroll] enroll 已成功，两轮探测（间隔 5s）后本地仍未显示 Enrolled"
    log "[enroll] 需要前往网站确认接受：请访问 https://app.crowdsec.net 接受该实例（Accept）"
    log "[enroll] 未及时 Accept 前 CAPI 侧可能有报错，属正常过程；Accept 后自动恢复"
    _park_enroll_key
    return 0
}

_mount_systemd_cgroup() {
    _cg=/sys/fs/cgroup/systemd
    # 极简版容器里没有 systemd 会去 mount cgroup，这一层对它不构成前提：
    # 直接在函数入口拦住，所有调用点（开机链、补挂、重装）一次性都覆盖到。
    _is_minimal_init && { log "[cgroup] 极简 init 容器：无需 systemd 命名层级，跳过"; return 0; }
    # 判据必须是「/proc/mounts 里真有这个挂载点」，不能是「目录可写」。
    # /sys/fs/cgroup 本身是 tmpfs，`mkdir -p /sys/fs/cgroup/systemd` 出来的空目录
    # 天然可写，旧写法据此直接 return 0 —— 容器内 systemd 随后自己去 mount 就撞：
    #   Failed to mount cgroup at /sys/fs/cgroup/systemd: Operation not permitted
    #   [!!!!!!] Failed to mount API filesystems.
    # 表现就是容器怎么都起不来，而宿主日志里一片「cgroup 可写，无需挂载」。
    if _cg_host_ok; then
        log "[cgroup] systemd 命名层级已挂载，无需处理"
        return 0
    fi
    # 挂载点被占着但形态不对（别的东西挂上去了 / 挂成了 tmpfs）：
    # 直接 mount 会 EBUSY，必须先卸。卸不掉就如实判失败，别硬报成功。
    if grep -qE "[[:space:]]${_cg}[[:space:]]" /proc/mounts 2>/dev/null; then
        log "[cgroup] ${_cg} 上有挂载但不是 cgroup/name=systemd 层级，先卸载再重挂"
        if ! run umount "$_cg" 2>/dev/null; then
            log "[cgroup] 卸载失败（多半被运行中的容器引用），无法纠正挂载形态"
            return 1
        fi
    fi
    mkdir -p "$_cg" 2>/dev/null
    if run mount -t cgroup -o rw,nosuid,nodev,noexec,relatime,none,name=systemd cgroup "$_cg" 2>/dev/null; then
        # mount 返回 0 不代表挂对了，回读确认形态（不只是「路径存在」）
        if _cg_host_ok; then
            log "[cgroup] 已挂载 systemd 命名层级（容器内 systemd 需要）"
            return 0
        fi
        log "[cgroup] mount 返回 0 但形态不符（不是 cgroup/name=systemd），按失败处理"
        return 1
    fi
    if grep -qE "cgroup2[[:space:]]" /proc/mounts 2>/dev/null; then
        # unified 宿主上 v1 命名层级本就不该存在，挂不上不是「我们没修好」，
        # 容器内 systemd 由 LXC 的 lxc.mount.auto 提供 cgroup 视图。
        # 这种情况不能返回 1 —— 否则 build 失败会按 ensure 的语义直接 hard 终止，
        # 整个 PREP 组后面的节点一个都跑不到。
        log "[cgroup] 宿主是 cgroup v2 unified，跳过 v1 systemd 层级（容器侧由 lxc.mount.auto 负责）"
        return 0
    fi
    log "[cgroup] systemd 命名层级挂载失败（内核缺 CONFIG_CGROUP_* 或该层级已被其它控制器占用）"
    return 1
}

_ct_revive() {
    log "[施救] 容器启动修复链（补挂 cgroup → 重写 config 重启 → 验活；不重建）"

    _mount_systemd_cgroup

    log "[施救] 强停残留 → 重写容器 config → 重启"
    ct_force_stop || true
    write_cfg || true
    run lxc-start -P "$LXC_PATH" -n "$LXC_NAME" -d >/dev/null 2>&1 || true
    if _wait_ct_running; then
        log "[施救] 重写 config 后容器已拉起"
        return 0
    fi
    log "[施救] 重写 config 仍无效（不再重建重装，交由上层 hard 终止）"
    return 1
}

# ---- 阶段 3 服务链（v.81 A/B/C 步骤化：A 容器内配置 → B crowdsec 配置+bouncer 链路 → C last_pull）----
# 与 DAG ensure 同构但只修一次（v.81）：安装顺序保证前置已就绪，修一次不过即 hard——
phase3_step() {
    _p3_title="$1"
    _p3_verify="$2"
    _p3_fix="$3"
    log "[服务链] $_p3_title：查验"
    if "$_p3_verify" 2>/dev/null; then
        log "[服务链] $_p3_title 就绪，跳过"
        return 0
    fi
    # 一次修复（v.81）：不符 → 修复一次 → 复核，不过即 hard，不等第二次
    log "[服务链] $_p3_title 未就绪，执行修复（一次）"
    if ! "$_p3_fix" 2>/dev/null; then
        log "[服务链] $_p3_title 修复执行失败，hard 失败，引导终止"
        exit 1
    fi
    if "$_p3_verify" 2>/dev/null; then
        log "[服务链] $_p3_title 修复后复核通过"
        return 0
    fi
    log "[服务链] $_p3_title 一次修复未通过复核，hard 失败，引导终止"
    exit 1
}

# enroll 专用效验步（保留之前做法，不纳入修复循环）：fix（re_enroll）内部已自带终态判定——
# 「enroll 命令成功但 10 秒内未显示 Enrolled（等网站人工 Accept）」是合法中间态，
# 不能靠事后复核判失败；fix 返 0 即过、返 1 即 hard
phase3_step_enroll() {
    _p3_title="$1"
    _p3_verify="$2"
    _p3_fix="$3"
    log "[服务链] $_p3_title：查验"
    if "$_p3_verify" 2>/dev/null; then
        log "[阶段3] $_p3_title 就绪，跳过"
        return 0
    fi
    log "[阶段3] $_p3_title 未就绪，执行修复"
    if "$_p3_fix" 2>/dev/null; then
        log "[阶段3] $_p3_title 修复完成（fix 自带终态判定，未终止等待亦算过）"
        return 0
    fi
    log "[阶段3] $_p3_title 修复失败，引导终止（重跑亦同，需人工介入）"
    exit 1
}

verify_online_client_off() {
    [ -f "$CROWDSEC_CFG" ] || return 1
    ! grep -qE "^[[:space:]]*online_client:" "$CROWDSEC_CFG" 2>/dev/null
}

verify_online_client_on() {
    [ -f "$CROWDSEC_CFG" ] || return 1
    grep -qE "^[[:space:]]*online_client:" "$CROWDSEC_CFG" 2>/dev/null
}

# LAPI 可达性判定（容器在运行 + cscli bouncers list 有回显）：
# verify_B 的注册态分支与「等 LAPI 就绪」的判据共用——注意它只判「LAPI 活着」，
# 不判 last_pull（那是 bouncer_verify 与探针的职责），也不夹带任何修复动作
verify_lapi_ready() {
    ct_running || return 1
    _ct_env "$CSCLI bouncers list -o json" >/dev/null 2>&1
}

# ---- 步骤 A：宿主机→容器日志转发链路（v.83 起收窄）----
# 文件级容器配置（网络文件/自启软链/resolv/acquis/listen/trusted/ct_config）
verify_A() {
    verify_log_forward
}

fix_A() {
    if verify_log_forward; then
        log "[步骤A] 宿主机日志转发已就绪，跳过"
        return 0
    fi
    log "[步骤A] 宿主机日志转发缺项，补写"
    setup_log_forward || return 1
    return 0
}

# ---- 步骤 B：crowdsec bouncer 服务链路（v.83 起收窄）----
# 文件级配置（listen_uri/trusted_ips/ct_config）已由阶段 1+2 保证，此处不再复核；
verify_B() {
    cs_active_on_host && nft_table_ready || return 1
    if verify_lapi_ready; then
        bouncer_exists || return 1
    else
        log "[步骤B] LAPI 不可达，注册态无法查验（return 0，交由步骤 C 判定）"
    fi
    return 0
}

fix_B() {
    if verify_B; then
        log "[步骤B] 服务链路已就绪，跳过链路修复"
        return 0
    fi
    # 文件级判据（listen/trusted/ct_config）已由 PREP/INSTALL 组各节点保证，
    # 此处只修复阶段 3 独有的服务链路：屏蔽 CAPI → 应用 bouncer UCI → 等 LAPI →
    # 注册 → 起宿主机服务 → 等 nft 表就位
    log "[步骤B] 屏蔽 online_client 并修复 bouncer 服务链路"
    ensure_online_client_off || true
    _bouncer_uci_apply || return 1
    _wait_lapi_ready 90 || log "[步骤B] LAPI 90 秒未就绪，仍尝试注册"
    _bouncer_register_once || { log "[步骤B] bouncer 注册失败（拿不到 key）"; return 1; }
    _ensure_bouncer_service
    _fb_i=0
    while [ "$_fb_i" -lt 12 ]; do
        _fb_i=$((_fb_i+1))
        nft_table_ready && break
        sleep 1
    done
    return 0
}

# ---- 步骤 C：LAPI 可达 + last_pull（v.106 职责切分后，只验不重装）----
# 【v.106 改动缘由】用户现场口径：
#   「如果错误了还是按照脚本的方式去修；如果脚本修复不了这个错误，就说明脚本
#     已经损坏了，就没必要去重装了。」「探针只探 last_pull 的状态，其他不探。」
# 即修复动作就是脚本的全部能力，所以「修不好」等于「修复能力/资产失效」——此时
# 重装用同一套脚本、同一份镜像只会把同样的失败再走一遍，还会先抹掉现场证据；
# 叠加探针周期性地触发修复，就退化成「每小时抹一次盘」，正是 v.103 之前的老毛病。
# 因此 v.106 起 last_pull 的持续监视整体移交运行期探针（crowdsec-lxc-probe.sh）：
#   探针 60s 一轮判 last_pull → 连续 3 轮停滞 → 重跑本脚本（幂等修复）→ 修不好
#   就报「脚本修复能力失效，需人工介入」，仍然不重装。
# 本函数只回答一个问题：「装完/修完这一次，链路通不通」，不通就 hard 退出。
#   ① LAPI 可达（bouncer 绑定后的必备探测，保留）：容器在跑 + cscli 有回显
#   ② last_pull 在等待窗口内刷新（只观察，不作为重装依据）
#   ③ 拉不到时复验 A/B 要素并修一次，修完再等一个窗口
# 自动重装的唯一入口不在这里，见 _structurally_broken()（只认结构性损坏）。

# last_pull 纯等待窗口（默认 12×5s=60s）：只观察不改状态
# 两个调用点都不传参，走默认 60s；形参留着的意义是测试能把它调成 1 轮跑快些。
_sc_wait_pull() {
    _sw_max="${1:-12}"
    _sw_i=0
    log "[步骤C] 进入 last_pull 拉取窗口（最多 ${_sw_max}×5s，只观察不修复）"
    while [ "$_sw_i" -lt "$_sw_max" ]; do
        _sw_i=$((_sw_i+1))
        sleep 5
        if bouncer_pulling; then
            log "[步骤C] last_pull 已刷新（等待 ${_sw_i}×5s）"
            return 0
        fi
        [ $(( _sw_i % 4 )) -eq 0 ] && log "[步骤C] last_pull 仍未刷新，继续等待（${_sw_i}/${_sw_max}）"
    done
    return 1
}



# 各组节点清单（由 NODE_GROUP_* 派生，供组级 verify/build 遍历；顺序即组内声明序）
NETBASE_NODES="br_lan_ports lan_static dhcp_ignore bridge lxc_zone fwd_rules lan_input snat ip_forward svc_bind docker_fw pkg_base lxc_auto smartdns"
PREP_NODES="ct_net cgroup_mount ct_bootlink ct_resolv"
INSTALL_NODES="img_migrate rootfs ct_config"
CAPIBLOCK_NODES="capi_block"
BOOT_NODES="ct_boot"
LOGCONF_NODES="logconf"
LAPI_NODES="lapi_fetch bouncer_fill"
BOUNCERVERIFY_NODES="bouncer_verify capi_release"
ENROLL_NODES="enroll"
DEPS_NODES="deps"
SMARTCHK_NODES="sd_serve"
# ---- 8 组组级 verify/build（v.93 按功能切分，组内小步骤各自 ensure）----
# 组级 verify = 组内节点全部内容一致；组级 build = 组内节点逐个 ensure（各自两次闭环）。
# 组与组之间只保留一条真实存在的硬顺序：静态准备/安装/屏蔽 CAPI → 启动容器 → 其余。

# NETBASE：路由器侧网络基线 —— 两块网桥（br-lan / lxcbr0）与防火墙 zone、转发规则。
# 全部只碰 uci 与内核网络栈，不读不写容器 rootfs，因此可以排在 INSTALL 解压之前，
# 保证「rootfs 还在解压时，LAN 已经能进 LuCI」。
verify_NETBASE() {
    for _n in $NETBASE_NODES; do
        "verify_$_n" 2>/dev/null || return 1
    done
    return 0
}
build_NETBASE() {
    for _n in $NETBASE_NODES; do
        ensure "$_n" || return 1
    done
    flush_uci
    return 0
}

# PREP：容器启动前必须在位的静态准备（容器网络 / cgroup），依赖 NETBASE 与 INSTALL
verify_PREP() {
    for _n in $PREP_NODES; do
        "verify_$_n" 2>/dev/null || return 1
    done
    return 0
}
build_PREP() {
    # 网络侧 11 项全部「验证 + 修改」（v.95/v.97 起，含 bridge；v.108.40 去掉 dns_domain）：
    # br_lan_ports / lan_static / dhcp_ignore / bridge / …
    for _n in $PREP_NODES; do
        ensure "$_n" || return 1
    done
    flush_uci
    return 0
}

# INSTALL：解压 rootfs / 迁移镜像 / 校验容器 config（全部磁盘态，可先于启动完成）
verify_INSTALL() {
    for _n in $INSTALL_NODES; do
        "verify_$_n" 2>/dev/null || return 1
    done
    return 0
}
build_INSTALL() {
    for _n in $INSTALL_NODES; do
        ensure "$_n" || return 1
    done
    return 0
}

# CAPIBLOCK：容器启动前把 online_client 停用（config.yaml 只在 crowdsec 启动时读一次，
# 启动后再改等于没改——所以必须先屏蔽、后开机）
verify_CAPIBLOCK() {
    for _n in $CAPIBLOCK_NODES; do
        "verify_$_n" 2>/dev/null || return 1
    done
    return 0
}
build_CAPIBLOCK() {
    for _n in $CAPIBLOCK_NODES; do
        ensure "$_n" || return 1
    done
    return 0
}

# BOOT：唯一一次开机
verify_BOOT() {
    for _n in $BOOT_NODES; do
        "verify_$_n" 2>/dev/null || return 1
    done
    return 0
}
build_BOOT() {
    for _n in $BOOT_NODES; do
        ensure "$_n" || return 1
    done
    return 0
}

# LOGCONF：宿主机推送 + 容器内采集解析（开机后才有容器可写入，故在 BOOT 之后）
verify_LOGCONF() {
    for _n in $LOGCONF_NODES; do
        "verify_$_n" 2>/dev/null || return 1
    done
    return 0
}
build_LOGCONF() {
    for _n in $LOGCONF_NODES; do
        ensure "$_n" || return 1
    done
    return 0
}

# LAPI：容器内 cscli 取 LAPI 地址/凭据 → 写入路由器 bouncer
verify_LAPI() {
    for _n in $LAPI_NODES; do
        "verify_$_n" 2>/dev/null || return 1
    done
    return 0
}
build_LAPI() {
    for _n in $LAPI_NODES; do
        ensure "$_n" || return 1
    done
    return 0
}

# BOUNCERVERIFY：bouncer 列表真生效 → 才放开 CAPI
verify_BOUNCERVERIFY() {
    for _n in $BOUNCERVERIFY_NODES; do
        "verify_$_n" 2>/dev/null || return 1
    done
    return 0
}
build_BOUNCERVERIFY() {
    for _n in $BOUNCERVERIFY_NODES; do
        ensure "$_n" || return 1
    done
    return 0
}

# ENROLL 节点（v.108.49）：console 注册。无注册码视为就绪，不阻断引导。
# 【为什么改写成节点级函数】v.79 把调度器换成「组 → 遍历 _order 按 NODE_GROUP_ 筛节点」
# 之后，组级函数（verify_PREP / verify_ENROLL 这一套）就再没被任何路径调用过；
# 而 enroll 又恰好没进 DAG_NODES，于是这一组连节点都没有，两条死路叠在一起：
# 「组在、组日志照打、注册码永不消费」。现在 enroll 是真节点，走 ensure() 的
# verify → build 两段，组级函数保留为薄封装（万一别处还有引用，不至于调空）。
# 幂等性：验的是「注册码还在、console 还没 Enrolled」这一对条件，成功一次即删码，
# 下一轮 verify 直接过，不会反复注册。
verify_enroll() {
    _enroll_key_load
    # ① 已注册：清「等 Accept」标记，把主注册码搬进保险柜（不再删除）。
    #    --verify-only（探针体检）承诺「一个字节都不写」，那条路径只报不动。
    if console_enroll_ok; then
        if [ "${_VERIFY_ONLY:-0}" = "1" ]; then
            [ -f "$ENROLL_KEY_FILE" ] && log "[ENROLL] 已注册但主注册码仍在（体检模式：只报，不移动）"
        else
            _enroll_submit_clear
            _park_enroll_key
        fi
        return 0
    fi
    # ② 未注册且无码：无法自愈，把「已掉线」明明白白打出来，但不让开机失败。
    #    （旧写法 `[ -s key ] || return 0` 在这里静默通过，日志看着正常、设备其实早掉线。）
    if [ -z "$_ENROLL_KEY_V" ]; then
        log "[ENROLL] ** 未注册且无可用注册码（$ENROLL_KEY_FILE / $ENROLL_KEY_KEEP 都不在），无法自动重注册"
        log "[ENROLL] ** 补救：app.crowdsec.net 取注册码后执行 cscli console enroll <key>"
        return 0
    fi
    # ③ 本次开机已提交、等网页 Accept：这段间隔本地必然是 not enrolled，不能当失败。
    #    （v.108.52 就是把它当失败，每个复验轮次都重新提交一次，网页堆出一串 pending。）
    if [ "$_ENROLL_TRIED" = "1" ]; then
        if [ "$_ENROLL_WAIT_LOGGED" = "0" ]; then
            log "[ENROLL] 本次开机已提交注册，等待网页端 Accept（重启设备可再尝试一次）"
            log "[ENROLL]   → app.crowdsec.net → Instances 点 Accept enroll，之后本地自动变 enrolled"
            _ENROLL_WAIT_LOGGED=1
        fi
        return 0
    fi
    # ④ 本次开机还没试过：交给 build 提交一次
    log "[ENROLL] 检测到未注册（网页端可能被关闭/删除），发现可用注册码，交给 build 重注册"
    return 1
}
build_enroll() {
    _enroll_key_load
    if [ -z "$_ENROLL_KEY_V" ]; then
        log "[ENROLL] 未配置注册码（$ENROLL_KEY_FILE / $ENROLL_KEY_KEEP 都没有），跳过 console enroll"
        return 0
    fi
    # 本次开机只提交一次：阶段 1 / 阶段 3 / 重启态复验都走这个函数，共用同一个进程变量。
    # 想再试一次就重启设备（v.108.54：这是唯一的重置方式，不需要删文件）。
    if [ "$_ENROLL_TRIED" = "1" ]; then
        log "[ENROLL] 本次开机已提交过注册，跳过重复提交（想再试一次请重启设备）"
        return 0
    fi
    _ENROLL_TRIED=1
    re_enroll
}
verify_ENROLL() { verify_enroll; }
build_ENROLL() { build_enroll; }
# DEPS：末尾的必备组件补齐（v.180.85）。与其它组不同，这里的 build 本身是柔性的
# （网络不通/装不上都只记日志返回 0），绝不能让「组件没装上」变成整轮引导的失败。
verify_DEPS() { verify_deps; }
build_DEPS() { build_deps; }

# 单步：verify 内容一致 → 置位跳过；否则 build 一次（不再复核）
rg_step() {
    _rs_title="$1"; _rs_verify="$2"; _rs_build="$3"
    if "$_rs_verify" 2>/dev/null; then
        log "[$_rs_title] 内容一致，跳过"
        return 0
    fi
    log "[$_rs_title] 内容不符，执行构建一次"
    if ! "$_rs_build" 2>/dev/null; then
        log "[$_rs_title] 构建执行失败，hard 失败，引导终止"
        return 1
    fi
    log "[$_rs_title] 已构建"
    return 0
}

# 重启态：按 GROUP_SEQ 逐组验证；某组里有个节点修不好 → hard 退出（v.106 起不重装）
# 【2026-10-20 修掉的三个致命缺陷，每一个都能让这台机器每小时被抹一次盘】
#   ① 变量名大小写（v.104 更正 v.103 的错误修法）：GROUP_SEQ 里是全大写
#      （PREP INSTALL ...），置位走 ensure_group 的 _bs_flag_set "GSET_$_g"，
#      $_g 来自 GROUP_SEQ，所以写进 shell 的变量名就是 GSET_PREP。
#      v.103 为了「统一口径」把读取端 tr 成小写去读 GSET_prep —— 而 shell 变量名
#      大小写敏感，于是八个组一个都读不到，每次开机第 1 组就判「未置位」→
#      full_reinstall：复核链整体失效，last_pull 一旦失效就直接 rm -rf rootfs。
#      口径钉死：组键一律（大写）用 GROUP_SEQ 原值，置位与读取两侧都不做大小写转换。
#   ② 组级函数根本不存在：这里原本调 verify_$_g / build_$_g，也就是
#      verify_PREP / build_PREP …… 全脚本一个都没有（只有 verify_br_lan_ports
#      这类节点级函数）。`"verify_PREP" 2>/dev/null` 在 dash 下报
#      "not found" 并被 2>/dev/null 吞掉，返回非 0 ⇒ 每次都判「内容不符」⇒
#      调 build_PREP 同样不存在 ⇒ 「构建失败且无法修复」⇒ full_reinstall ⇒ 抹盘。
#      **每次开机都抹一次容器**，还完全静默。现在改成遍历该组内的节点，
#      调真正的 verify_<节点> / build_<节点>。
#   ③ 一个节点修不好就整机重装太重：节点级 verify 不过是很常见的事（比如某个
#      uci 值被人在 LuCI 里改了），build 一次基本都能修回来。v.106 起更进一步：
#      build 也失败时不再升级到重装，而是打一份只读诊断后 hard 退出 —— 修不好等于
#      脚本的修复能力对不上现场，重装是同一套脚本、同一份镜像再跑一遍，只会重蹈
#      覆辙并先把证据抹掉。自动重装的唯一入口收在 _structurally_broken() 里，
#      只认结构性损坏（rootfs 残缺 / 无 init / 容器目录不可写）。
#   ④ 【v.105，与①并列的第二个 v.103 遗留】重建后不落盘：build_* 只写 uci 内存态，
#      commit/reload 统一归 flush_uci；而 _dirty_ 脏标记只有 ensure() 会置。
#      本函数直接调 build_、组末又没 flush_uci ⇒ 「修好了」只活在内存里：
#      /etc/config 没动、fw4 的 nft 表没重建，uci delta 在 /tmp 下，重启即清空，
#      下次开机 verify 又不过、又修一遍，永远修不进去。现在：build 成功即补
#      _dirty_，并在每组末尾 flush_uci（放在 bad 判断之前，已修好的也要落盘）。
rg_restart_verify() {
    for _rg_g in $GROUP_SEQ; do
        _rgG=$(echo "$_rg_g" | tr 'a-z' 'A-Z')
        # 读 _rgG（大写）：置位点是 ensure_group 的 _bs_flag_set "GSET_$_g"，
        # $_g 来自 GROUP_SEQ（全大写），变量名就是 GSET_PREP。
        # v.103 这里 tr 成小写去读 GSET_prep —— shell 变量名大小写敏感，永远读不到。
        if ! _bs_flag_on "GSET_$_rgG"; then
            # 【v.106】组置位只表示「本进程的 ensure_group 跑成功过」，不是配置真相。
            # 重启态下这里为真，通常意味着阶段 1+2 该组中途失败（或上次是旧版本 /
            log "[重启态] 组 $_rgG 本轮未置位（阶段 1+2 未完成该组），改为逐节点复验判定"
        fi
        # 组内逐节点复验：通过就跳过，不过就修一次。
        # 节点清单从全局拓扑序 _order 里按 NODE_GROUP_<节点> 筛出来 ——
        # 与 ensure_group 同一个口径，不另建一份平行的组→节点表（那种并行表迟早会歪）。
        _rg_bad=""
        for _rg_n in $_order; do
            [ "$(eval "echo \$NODE_GROUP_$_rg_n")" = "$_rgG" ] || continue
            "verify_$_rg_n" 2>/dev/null && continue
            log "[重启态][$_rgG] $_rg_n 内容不符，执行构建一次"
            if "build_$_rg_n" 2>/dev/null; then
                # build_* 只写 uci 内存态（commit/reload 统一归 flush_uci 处理），
                # 脏标记也只在 ensure() 里置 —— 本函数直接调 build_ 绕过了 ensure，
                # 所以必须自己补 _dirty_，否则下面的 flush_uci 会判「无改动」跳过提交。
                _bs_flag_set "_dirty_$_rg_n" B
                log "[重启态][$_rgG] $_rg_n 已构建"
                continue
            fi
            log "[重启态][$_rgG] $_rg_n 构建也失败（不是配置错，是环境坏了）"
            case " $SOFT_NODES " in
            *" $_rg_n "*)
                log "[重启态][$_rgG] $_rg_n 属柔性节点（SOFT_NODES），只告警不中止；长期监视交给探针"
                continue
                ;;
            esac
            _rg_bad="$_rg_bad $_rg_n"
        done
        # 【v.105】组末落盘。build_* 只写 uci 内存态：不 flush 就等于「只在内存里修好了」
        # ——/etc/config 没动、fw4 的 nft 表没重建，而 uci 的 delta 在 /tmp 下，重启即清空，
        # 下次开机 verify 又不过、又 build 一遍，永远修不进去。日志却全程报「已构建」。
        flush_uci
        if [ -n "$_rg_bad" ]; then
            # 【v.106 用户口径】修不好＝脚本修复能力/资产失效，重装没有意义：同一套脚本、
            # 同一份镜像只会把同样的失败再走一遍，还要先把现场证据抹掉。唯一例外是
            # 结构性损坏（rootfs/init/容器定义被外部破坏），那由 _structurally_broken()
            # 判定，不在这里。这里先打一份只读诊断，再 hard 退出。
            log "[重启态][$_rgG] 这些节点修不好：$_rg_bad → 修复能力失效，hard 退出（不重装）"
            _reinstall_diag
            exit 1
        fi
        log "[重启态][$_rgG] 组内节点全部就绪"
    done
    log "[重启态] 全部 $(echo $GROUP_SEQ | wc -w | tr -d ' ') 个组验证通过"
}

main() {
    log "===== crowdsec-lxc-bootstrap v$SCRIPT_VER 开始（容器 $LXC_NAME）====="

    # 【--net-only】只校准路由器网络基线，不碰镜像 / rootfs / 容器。
    # 组链缩成 PREP 一组：INSTALL / CAPIBLOCK / BOOT 及之后的四组全部不参与，
    # 因为它们的每一步都要求容器 rootfs 存在。
    #
    # 注意不能只改 GROUP_SEQ：dag_order 会遍历整个 DAG_NODES，发现某个小步骤归属的
    # 组不在 GROUP_SEQ 里就直接终止（「归属的组 INSTALL 不在 GROUP_SEQ 中」）。
    # 所以必须同时把 DAG_NODES 裁成「PREP 组里与容器无关的节点」。
    if [ "$NET_ONLY" = "1" ]; then
        GROUP_SEQ="NETBASE"
        _no_dag=""
        for _no_n in $DAG_NODES; do
            [ "$(eval "echo \$NODE_GROUP_$_no_n")" = "NETBASE" ] || continue
            case " $NET_ONLY_SKIP " in
                *" $_no_n "*) continue ;;
            esac
            _no_dag="$_no_dag $_no_n"
        done
        DAG_NODES="$_no_dag"
        # 【v.108.29】组内真正执行的是 PREP_NODES，不是 DAG_NODES：
        # build_PREP / verify_PREP 都是 `for _n in $PREP_NODES`。只裁 DAG 的话，
        # PREP 组照样把 bridge / ct_net / ct_bootlink / ct_resolv / lxc_zone /
        # fwd_rules / snat 全跑一遍 ——「--net-only 不碰容器」就成了一句空话，
        # 没有 rootfs 时还会在 ct_net 上失败、把整个网络基线搭进去。
        _no_base=""
        for _no_n in $NETBASE_NODES; do
            case " $NET_ONLY_SKIP " in
                *" $_no_n "*) continue ;;
            esac
            _no_base="$_no_base $_no_n"
        done
        NETBASE_NODES="$_no_base"
        log "===== 网络基线模式（--net-only）：只校准路由器网络，不碰容器 ====="
        log "[网络基线] 跳过容器相关节点：$NET_ONLY_SKIP"
    fi

    # 【v.180.85】lxc 缺失不做硬失败：容器相关的每个节点都要 lxc-* 命令，硬跑只会
    # 第一个节点就 exit 1，把整轮引导带走。
    # 【v.180.104】缺 lxc 时这一轮跑「Ⅰ 网络 11 节点 + Ⅱ pkg_base」，两条出路：
    #   · pkg_base 从 /rom 补齐 → 末段看到 lxc-start 在，恢复完整组链接着跑；
    #   · /rom 里也没有   → 只留网络基线落盘，本轮到此刻收工，下次开机再试。
    # 判据仍是 verify-first：pkg_base 先 _pkg_missing_all，缺了才逐个文件拷，
    # 已就位时零写入、零扫描。
    # 裁剪方式与 --net-only 同源：只改 GROUP_SEQ 不够，dag_order 会遍历整个 DAG_NODES
    # 并校验归属组是否在 GROUP_SEQ 里，所以 DAG_NODES 必须同步收窄。
    _LXC_READY=1
    _FULL_DAG=""
    _FULL_SEQ=""
    _FULL_NETBASE=""
    if [ "$NET_ONLY" != "1" ] && ! command -v lxc-start >/dev/null 2>&1; then
        _LXC_READY=0
        # pkg_base 在本轮降为柔性：它只负责「尽力从 /rom 装回」，
        # 装不回来属于固件不合规，但网络基线已经配好，不该把整轮带走。
        SOFT_NODES="$SOFT_NODES pkg_base"
        # 完整组链留底：恢复成功后末段用它把容器流程接着跑完。
        _FULL_DAG="$DAG_NODES"
        _FULL_SEQ="$GROUP_SEQ"
        _FULL_NETBASE="$NETBASE_NODES"
        _lx_dag=""
        for _lx_n in $DAG_NODES; do
            case "$(eval "echo \$NODE_GROUP_$_lx_n")" in
                NETBASE)
                    # lxc_auto / smartdns 必须摘掉：它们要 lxc-auto 的服务脚本和
                    # smartdns 二进制，Ⅱ 恢复成功之前跑必然失败（成功后由末段重跑完整链补上）。
                    # pkg_base 必须保留 —— 它正是 Ⅱ「从 /rom 装回」的执行者，剔掉它 Ⅱ 永远没机会跑。
                    case "$_lx_n" in
                        lxc_auto|smartdns) continue ;;
                    esac
                    _lx_dag="$_lx_dag $_lx_n"
                    ;;
            esac
        done
        # 组级 verify_NETBASE / build_NETBASE 遍历的是 NETBASE_NODES，不只是 DAG_NODES，
        # 这里同步收窄，避免两处口径不一致（--net-only 也踩过同一个坑）。
        _lx_base=""
        for _lx_n in $NETBASE_NODES; do
            case "$_lx_n" in
                lxc_auto|smartdns) continue ;;
            esac
            _lx_base="$_lx_base $_lx_n"
        done
        NETBASE_NODES="$_lx_base"
        GROUP_SEQ="NETBASE"
        DAG_NODES="$_lx_dag"
        log "[PKG] 未检测到 lxc（缺 lxc-start）：本轮只跑网络基线，容器步骤整体跳过"
        log "[PKG] 固件应内置 lxc：请检查 custom-packages.sh / apk-custom-packages.sh 的 lxc 清单后重编"
    fi

    # 重装自愈持久状态：目录就位 + 退出记账 + 上次未完成重装先计数
    mkdir -p "$STATE_DIR" 2>/dev/null
    # 【v.108.18】判定「本次开机首跑」。boot_id 每次开机都变，所以拿它当开机身份：
    #   标记里的 id ≠ 当前 id  → 是新的一次开机，且是这次开机第一次跑 bootstrap → 首跑
    #   标记里的 id = 当前 id  → 本次开机已经跑过了（探针重跑 / 手动重跑）→ 非首跑
    # 拿不到 boot_id（极老内核）时按非首跑处理：宁可少重置，也不在运行期抹现场。
    _bi_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d ' \t\r\n')
    if [ -n "$_bi_boot" ] && [ "$(cat "$BOOT_ID_FILE" 2>/dev/null | tr -d ' \t\r\n')" != "$_bi_boot" ]; then
        _BS_FIRST_RUN=1
        printf '%s\n' "$_bi_boot" | atomic_write "$BOOT_ID_FILE" "" 2>/dev/null \
            || log "[重装] 开机身份标记写入失败（$BOOT_ID_FILE），本次仍按首跑处理"
        # 【v.108.19】新的一次开机 → 失败计数归零，它从此只数「本次开机重置的结果」，
        # 不再是终身累计（否则一次偶发失败会把自愈能力永久关死）。
        # 必须赶在 _pending_recover 之前清：pending 补记的那一次要留在本次开机账上。
        if [ -f "$REINSTALL_FAIL_FILE" ]; then
            log "[重装] 新的一次开机：上次失败计数 $(_reinstall_fail_count) 归零，本次重新计"
            rm -f "$REINSTALL_FAIL_FILE" 2>/dev/null
        fi
    fi
    if [ "$_BS_FIRST_RUN" = 1 ]; then
        log "[重装] 本次开机的首跑：资产残缺且额度未用时可重置一次"
    else
        log "[重装] 本次开机已跑过引导（运行期重跑）：不重置，只走修复"
    fi
    # 三条退出路径统一走同一套恢复逻辑：
    #   EXIT  —— 正常返回 / exit N
    trap '_bs_st=$?; _bs_on_exit' EXIT
    trap '_bs_on_signal INT'  INT
    trap '_bs_on_signal TERM' TERM
    trap '_bs_on_signal HUP'  HUP
    _ipfwd_snapshot        # 记下 ip_forward 原值，退出时按需还原
    _bs_clear_flags        # 进场先归零，确保不会读到上一次（exec 前）的残留
    _pending_recover

    dag_order

    # 本机判定：无镜像且无 rootfs → 跳过（不进 DAG）。
    # net-only 不受此限：它的全部目的就是「没有镜像也把网络配了」。
if [ "$NET_ONLY" != "1" ] && [ ! -f "$TARBALL" ] && [ ! -f "$LEGACY_TARBALL" ] \
   && [ ! -d "$ROM_BASE" ] && [ ! -f "$CROWDSEC_CFG" ]; then
        log "无镜像且无 rootfs，本机不带 CrowdSec，跳过"
        exit 0
    fi

    _recovering=false
    mkdir -p "$LXC_PATH/$LXC_NAME" 2>/dev/null

    # 【v.108.27】旁路由锁死：wan / wan6 段在这里无条件删除，不属于任何组、不参与判定。
    # 放在组循环之前：网络组的每一项（网桥 / lan 地址 / 防火墙）都建立在「这台机器
    # 只当旁路由」这个前提上，WAN 段还留着的话前提就是假的。
    # 删不掉就终止 —— WAN 面开着却继续往下配，等于配了一台会自己拨号的路由器。
    if ! purge_wan_sections; then
        log "[WAN] 无法删除 wan/wan6 段，引导终止（WAN 面必须关闭）"
        exit 1
    fi

    # ---- 阶段 1+2：组链式调度（每组置位 GSET_<组>，后组执行前校验前置全部置位）----
    # 抽成函数是因为 v.180.89 起这条链可能跑两遍：lxc 原先缺失时，DEPS 现场补装成功后
    # 立刻回头把容器流程（含 enroll / last pull）走完，而不是留到下次开机。
    _run_chain() {
        _group_failed=""
        # 清零要走 _bs_flag_clear：v.99 起置位值是 V:<ts>，写 0 是非空值、会被判成"已置位"
        for _g in $GROUP_SEQ; do _bs_flag_clear "GSET_$_g"; done
        for _g in $GROUP_SEQ; do
            ensure_group "$_g"
        done
        flush_uci || _flush_rc=1
    }
    _flush_rc=0
    _run_chain

    # ---- net-only 到此收工：PREP 跑完网络基线就结束，不进容器服务链 ----
    # 这一步必须放在 flush_uci 之后：commit / reload 在 flush_uci 里做，提前退出
    # 会让改好的 network 停在内存里、重启即丢。
    # _NET_ONLY_OK 是给退出钩子看的：网络基线跑通了，说明 ip_forward=1 是期望稳态，
    # 不许在 _ipfwd_restore 里被还原成 0（那会把路由器的转发关掉，整机不能上网）。
    if [ "$NET_ONLY" = "1" ]; then
        if [ "$_flush_rc" != "0" ]; then
            log "网络基线未完成（--net-only）：配置提交/重载失败，详见上方 [flush] 行"
            exit 1
        fi
        if _bs_flag_on "GSET_PREP"; then
            _NET_ONLY_OK=1
            log "网络基线完成（--net-only）：路由器网络已按 /etc/config/custom_router_*.txt 校准"
            exit 0
        fi
        log "网络基线未完成（--net-only）：详见上方各节点日志，未做任何容器操作"
        exit 1
    fi

    # 【v.180.85】lxc 原先缺失的这一轮到此收工：容器流程整体没跑，不能拿「前置组未置位」
    # 去判失败（那会把「组件已补装成功」的机器记成失败，探针还会反复重跑）。
    # 网络基线与组件安装都已落盘（上面 flush 过），下次引导从 INSTALL 组正常接管。
    if [ "$_LXC_READY" = 0 ]; then
        if command -v lxc-start >/dev/null 2>&1; then
            # 流程图 Ⅲ①：网络正常 → 不存在 lxc → 安装 lxc → 进行配置（含 enroll）→ last pull。
            # 这里恢复完整组链当场再跑一遍：NETBASE 各节点 verify 直接通过（无写入），
            # 真正干活的是 INSTALL → PREP → CAPIBLOCK → BOOT → … → ENROLL。
            GROUP_SEQ="$_FULL_SEQ"
            DAG_NODES="$_FULL_DAG"
            NETBASE_NODES="$_FULL_NETBASE"
            # deps 上一轮记的失败要抹掉，否则 enroll 会被「依赖 deps 失败」拦住；
            # 它自己的置位也要清，重跑时重新判定。
            _failed=""
            _bs_flag_clear "_done_deps"
            _bs_flag_clear "_dirty_deps"
            _LXC_READY=1
            dag_order
            log "[PKG] lxc 已就位：恢复完整组链，继续容器安装配置与 enroll"
            _run_chain
        else
            # 网络异常/装不上：按流程图「跳过结束」。网络基线跑通了，ip_forward=1 是
            # 期望稳态，不能因为「这轮没装完容器」被退出钩子还原成 0。
            _bs_flag_on "GSET_NETBASE" && _NET_ONLY_OK=1
            log "[PKG] 本轮容器流程已跳过（lxc 仍不在位）：网络基线与本地装包已完成，下次引导继续"
            exit 0
        fi
    fi

    # 【v.180.98】DEPS 只管验证，且已挪到容器流程与 bouncer 校验之后、enroll 之前：
    # 未置位 = 网络 / lxc / smartdns 至少一项没到位。容器该建的已经建完，
    # 不拿它去判整轮失败（那会把「组件缺一点」记成安装失败、探针反复重跑），
    # 只交代清楚「enroll 会被跳过」；installed 是否写由后面的 flush 与落地复核决定。
    if ! _bs_flag_on "GSET_DEPS"; then
        log "[DEPS] 未就绪（网络 / lxc / smartdns 至少一项不符）：本轮 enroll 跳过，下次开机重试"
    fi

    # 前置组（INSTALL / PREP / CAPIBLOCK / BOOT）任一未置位 → 容器内服务链无从谈起
    for _g in INSTALL PREP CAPIBLOCK BOOT; do
        _bs_flag_on "GSET_$_g" && continue
        # 【v.106】自动重装的唯一判定点就在这里。
        # 前置组做不下去时先问一句：是资产被外部破坏（rootfs 残缺 / 没有 init /
        # 容器目录不可写），还是脚本自己修不动？前者重建有意义，后者重建只是把
        # 同一套脚本再跑一遍、顺带抹掉现场 —— 所以只有前者才允许 full_reinstall。
        # 【v.106.1】首次安装做不下去 ≠ 资产被破坏。
        # 没有 installed 标记 = 这台机器从没装成过，rootfs 本来就不存在，
        # _structurally_broken 的「缺 /etc」判据会恒真 —— 若不加这一道，
        # 首次失败会被读成「结构性损坏」→ 白跑一次全量重装，日志还会把现场带偏。
        if ! _stamp_present; then
            log "[$_g] 未置位：首次安装未完成（无 installed 标记），引导终止（不重装）"
            exit 1
        fi
        if _structurally_broken; then
            log "[$_g] 未置位且存在结构性损坏，转入彻底重装"
            full_reinstall || { log "[$_g] 重装条件不满足（原因见上方 [重装] 行），异常退出"; exit 1; }
            log "[$_g] 重装流程未接管（exec 失败），异常退出"
            exit 1
        fi
        log "[$_g] 未置位：前置组未完成，且无结构性损坏，引导终止（不重装）"
        exit 1
    done

    # ---- 阶段 3：LOGCONF / LAPI / BOUNCERVERIFY / ENROLL 四组（后四组）----
    log "===== 阶段 3：服务链开始 ====="

    if [ "${CS_BOOTSTRAP_REINSTALL:-0}" = 1 ]; then
        _cred_restore || log "[重装] 凭证恢复未成功，enroll 步将走重注册"
    fi

    if [ "$_recovering" = true ]; then
        rg_step "CAPI 屏蔽（新装恢复中先断中央 API）" verify_online_client_off ensure_online_client_off
    fi

    if _stamp_present; then
        log "[重启态] 检出 installed 标记：按组逐步验证，失败修复一次，仍失败即 hard 退出（不重装）"
        # 指纹只用来「说清楚现场」，不用来改变流程走向：重启态本来就是逐组复核，
        # 配置被改过与没被改过，要做的事完全一样（复核 → 不对就修一次 → 还不对重装）。
        _stamp_cfg_changed || log "[变更] 上面这处差异说明容器配置被人/别的脚本改过；本次仍按组复核一遍"
        rg_restart_verify
    else
        log "[安装态] 无 installed 标记：完整执行 LOGCONF → LAPI → BOUNCERVERIFY → ENROLL"
        ensure_group LOGCONF
        ensure_group LAPI
        ensure_group BOUNCERVERIFY
        ensure_group ENROLL
    fi

    # 【v.108.11】总 flush 的失败以前只记录不处置：_flush_rc 算完就丢，
    # 下面照样 _stamp_write + exit 0。后果是 commit/reload 失败（网络、防火墙没落盘）
    # 也被当成「引导成功」，rc.local 拿到 0，下次开机重来一遍还是同样的失败。
    # 用户口径：失败必须返回 1，不许假成功。
    if [ "$_flush_rc" != "0" ]; then
        log "配置提交/重载失败（详见上方 [flush] 行），引导按失败退出"
        exit 1
    fi

    # 【v.108.32】WAN 面收口：开头删过，不代表结尾还是删着的。
    # 中间任何一步都可能把它造回来 —— 手工 uci、后装的包自己生成 wan 段、
    # 网络组重建 interface。这里是本轮最后一道：不符合就地再清一次，清完还不符合
    # 就按失败退出。绝不允许「8 组全过、WAN 面却开着」的引导返回 0。
    # 判据分两级：段与 firewall 引用是硬的（uci 说没了就是没了，做不到就是没做到）；
    # 内核接口是软的 —— reload 异步，刚删完的接口可能还挂着，这里只报不判死，
    # 交给开机后的 --verify-only（那时早该收敛，不收敛就是真问题）。
    _wan_hard_ok=true
    [ -z "$(_wan_sections)" ] || _wan_hard_ok=false
    [ -z "$(_wan_refs)" ] || _wan_hard_ok=false
    if [ "$_wan_hard_ok" = false ]; then
        log "[WAN] 收口复核不符（段或 firewall 引用），自动再清一次"
        if ! purge_wan_sections; then
            log "[WAN] 收口清理失败，引导按失败退出（WAN 面必须是关的）"
            exit 1
        fi
        if [ -n "$(_wan_sections)" ] || [ -n "$(_wan_refs)" ]; then
            log "[WAN] 清理后仍不符，引导按失败退出（WAN 面必须是关的）"
            exit 1
        fi
        log "[WAN] 收口复核已恢复"
    fi

    # 【v.108.50】防火墙「编译结果」报告：本轮没有 reload 过防火墙时也要看一眼。
    # flush 路径里已经报过就不重复（_nft_reported=1）。这一行的意义是把
    # 「uci 写了 proto=all」和「nft 里真的没有 l4proto 限制」分开说清楚 ——
    # 出问题时不至于再靠人去猜是没写还是没生效。只报告，不参与判定。
    [ "${_nft_reported:-0}" = 1 ] || _nft_fw_report

    # 【v.108.33】落地复核：本轮 build 过的节点必须在 flush 之后真的生效。
    # 这一关专门抓「build 返回 0、配置却没写成」——以前只有 30 轮后的体检能发现。
    if ! _post_verify_after_boot; then
        log "[复核] 有节点构建后始终不生效，引导按失败退出"
        exit 1
    fi

    # 【v.108.51】凭据持久副本：放在 _stamp_write 之前。刷机后 /srv 全丢，
    # 只有 /etc/config 能活下来；这一步把「本轮已验证可用」的 CAPI 凭据存到那里，
    # 下一次刷机的 build_rootfs → _cred_restore 才有的可恢复。
    # 排在 stamp 之前是因为：stamp 写入失败会 exit 1，那时凭据仍应被保住。
    _cred_keep_save || log "[凭据] 持久副本未建立，刷机后需重新 register/enroll"

    # 链路全通：置位 installed（enroll 是网站人工面，不计入安装成功判据）
    # 【v.108.30】installed 是探针与「重装自愈」的共同前提：写不进去，探针会一直等
    # （v.108.30 起改成补印重跑，但那是兜底），下次开机又会当没装过整趟重来。
    # 以前这里 `|| true` 把它咽了，退出码 0 报成功 —— 失败必须返回 1。
    # 【v.108.32】顺序上排在 WAN 收口之后：收口不通过说明这轮没达到「旁路由」这个前提，
    # 先写 installed 等于给一台还没锁住 WAN 的机器盖章。
    if ! _stamp_write; then
        log "[stamp] installed 落位失败（$STAMP_FILE），引导按失败退出"
        exit 1
    fi

    # 【v.108.44】成功路径才清账：失败退出时残留的 dirty 是现场证据，不能抹。
    # 清掉的是「最后一次 flush 之后才置位、且不归 uci 管」的那些（实测是 capi_release）。
    _settle_dirty

    if [ -x /etc/init.d/crowdsec-lxc-probe ]; then
        run /etc/init.d/crowdsec-lxc-probe enable >/dev/null 2>&1 || true
        run /etc/init.d/crowdsec-lxc-probe start  >/dev/null 2>&1 || true
        log "[探针] 运行期 last_pull 探针已启用（crowdsec-lxc-probe）"
    fi

    log "引导结束"
    exit 0
}

# ---- 网络基线模式（v.107.6）：只校准路由器网络，不碰容器 ----
# rc.local 在「无镜像且无 rootfs」时改走这里（见 rc.local 的 BOOT_MODE）。
# v.107.7 起容器恒内置、没有开关，所以走到这条分支 = 镜像没进固件（异常）。
# 即便如此也先把网络配好：网络是唯一的远程入口，丢了就只剩接显示器。
if [ "${1:-}" = "--net-only" ]; then
    NET_ONLY=1
    shift
fi

# ---- 运行期探针入口（v.82）：供 crowdsec-lxc-probe.sh 复用 last_pull 判定逻辑 ----
# 单一事实源：探针只验证 last_pull，判定标准（bouncer_pulling 的新鲜度阈值，
# 默认 60s = 6 个 10s 心跳周期，见 _BP_DEFAULT_MAX_AGE）与引导
if [ "${1:-}" = "--probe-check" ]; then
    bouncer_pulling
    exit $?
fi

# ---- 全量验证模式（v.108.25）----
# 既然每个节点都已经是「先验现场、有就过」，那整个脚本其实随时可以退化成一次体检：
# 从 img_migrate 到 capi_release 全跑一遍 verify_*，不写任何一个字节。
# 用途：探针定期跑一次就知道「这台机器有没有漂移」；人也随时能问同样的问题。
# 有项不符时返回 1，修复仍然交给正常引导（它自己会按需补那几项）。
# 【v.108.29】WAN 段已经不在 DAG 里了（主流程无条件删），但「它确实清空了」这件事
# 仍然必须能被体检发现。否则 --verify-only 会在 WAN 面开着的时候报告「全达标」——
# 又一处假绿，而且是最不该有的那种：这台机器会不会自己拨号，体检说了算。
# 只读：不删不写，跟其他 audit 项一个口径。
# 【v.108.32】原来只验网络段。段删干净、firewall 里还挂着 `list network 'wan' 'wan6'`，
# 体检照样报绿 —— 而那条引用正是「这台机器还在按有 WAN 的世界生成规则」的证据。
# 现在三项一起验：段、引用、内核接口。
audit_wan_purged() {
    run uci show network >/dev/null 2>&1 || return 1
    # ① network 里不许有 wan / wan6 段（v.108.27 定死了整段不存在，不是 disabled）
    [ -z "$(_wan_sections)" ] || return 1
    # ② firewall 里不许再有指向这两个接口的 list network 引用（v.108.32）
    [ -z "$(_wan_refs)" ] || return 1
    # ③ 内核里不许冒出 wan / wan6 接口（v.108.32）
    [ -z "$(_wan_ifaces)" ] || return 1
    return 0
}

_audit_all() {
    _ab=0
    _an=0
    _askip=0
    for _n in $DAG_NODES; do
        # 【v.108.61】enroll 不纳入体检：它要联网、要人在 app.crowdsec.net 点 Accept，
        # 不确定性太大。而且 --verify-only 是独立进程，_ENROLL_TRIED 恒为 0 →
        # 只要「有注册码且尚未注册」就恒返回 1，体检于是**永远**报不符，
        # 探针每 30 轮（≈30 分钟）白跑一次完整引导，日志里还看不出原因。
        # 必须打「跳过」而不是「OK」：把没验的报成达标，就是「不报错、只给错误答案」。
        case "$_n" in
        enroll)
            printf '[审计] %-16s 跳过（需联网，不入体检；注册状态见引导日志）\n' "$_n"
            _askip=$((_askip + 1))
            continue
            ;;
        esac
        _an=$((_an + 1))
        if "verify_$_n" >/dev/null 2>&1; then
            printf '[审计] %-16s OK\n' "$_n"
        else
            printf '[审计] %-16s 不符\n' "$_n"
            _ab=$((_ab + 1))
        fi
    done
    _an=$((_an + 1))
    if audit_wan_purged; then
        printf '[审计] %-16s OK\n' "wan_purged"
    else
        printf '[审计] %-16s 不符\n' "wan_purged"
        _ab=$((_ab + 1))
    fi
    printf '[审计] 共 %s 项，不符 %s 项' "$_an" "$_ab"
    [ "$_askip" -gt 0 ] && printf '（另有 %s 项跳过：enroll 需联网）' "$_askip"
    printf '\n'
    [ "$_ab" -eq 0 ]
}

if [ "${1:-}" = "--verify-only" ]; then
    # 体检模式：调用方（探针 / 人）信的是「一个字节都不写」，verify_enroll 里
    # 「已注册就清明文注册码」这一步必须在这里关掉。
    _VERIFY_ONLY=1
    _audit_all
    exit $?
fi

# ---- 测试钩子：只要函数定义，不执行 main ----
# v.98 起 tests/ 里有几套用例要「跑生产函数的真实逻辑，但不碰真系统」。
if [ "${1:-}" = "--only-funcs" ]; then
    sed -n '1,/^main "\$@"$/p' "$0" | sed '$d'
    exit 0
fi

# ---- 日志封顶：真引导才截，--verify-only / --probe-check 早就 exit 了 ----
_boot_log_trim

main "$@"
