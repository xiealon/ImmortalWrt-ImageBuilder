#!/bin/sh
# 【v.180.78】固件版本标记 —— 与 crowdsec-lxc-bootstrap.sh 的 SCRIPT_VER 同步，每次改脚本一起改
# crowdsec-lxc-probe：运行期 last_pull 监视探针（v.106）
# 职责边界（刻意收窄成一条）：
#   只验证 last_pull。判停滞 → 告警 + 持引导锁重跑 crowdsec-lxc-bootstrap.sh。
#   本脚本不做任何修复动作 —— 修复逻辑全部复用 bootstrap，与开机引导共用一把锁，
#   永远只有一个 bootstrap 在跑。
# 【v.106 职责切分】last_pull 的持续监视从 bootstrap 的 step_C 整体搬到本脚本：
#   · bootstrap 只回答「装完/修完这一次，链路通不通」，不通就 hard 退出；
#   · 本脚本负责「一直盯着」，停滞就重跑 bootstrap 做幂等修复；
#   · 重跑仍修不好 = 脚本对不上现场 → 记账并升级「需人工介入」，仍然不重装。
#     理由：重装跑的是同一套脚本、同一份镜像，只会重蹈覆辙，还要先抹掉现场。
#   自动重装的唯一入口收在 bootstrap 的 _structurally_broken()，只认结构性损坏。
# 判定标准单一事实源：`$BOOT --probe-check`（bootstrap 入口，复用 bouncer_pulling
#   60s 新鲜度 = 6 个 10s 心跳周期），探针不自己解析 last_pull，两边标准永不打架。
# 参数（环境变量覆盖，与 bootstrap 的 CS_BOOTSTRAP_* 同风格）：
#   CS_PROBE_INTERVAL     一轮间隔秒（默认 60）
#   CS_PROBE_STALL_ROUNDS 连续停滞几轮才动作（默认 3，防容器刚起的拉取周期误报）
#   CS_PROBE_COOLDOWN     触发后冷却秒（默认 600，防爆冲）
#   CS_PROBE_LOCK_STALE   锁最长存活秒（默认 1800），超过视为陈旧锁回收
#   CS_PROBE_FAIL_ALERT   连续修复失败几次后报「需人工介入」（默认 5）
# 启动时机：init.d START=99 开机拉起。首启时安装可能尚未完成——无 installed
#   标记则静默等待（每分钟一次文件存在检查，零成本），不误判停滞。
# 【v.106 修掉的静默失效】原来锁只是一个 mkdir 出来的空目录：bootstrap 被
#   kill -9 或断电后锁永久残留 → 探针此后永远走 lock-busy，每分钟打一条
#   「引导进行中」就算完事，看日志一切正常，实际再也不会修复任何东西。
#   现在锁里落 pid + ts，遇锁先判陈旧（进程已死 / 超时 / 旧格式且无进程）再回收。

# 【v.180.118】两个路径都可被环境覆盖：生产环境走默认值（判真实 /rom 与 /usr/sbin），
# 只有 tests/probe_boot_heal.sh 会替换成临时目录 —— 否则「脚本被删」这种情形
# 没法在不动真机的前提下复现。
BOOT="${CS_PROBE_BOOT:-/usr/sbin/crowdsec-lxc-bootstrap.sh}"
ROMDIR="${CS_PROBE_ROM:-/rom}"
GUARD=/usr/sbin/crowdsec-guard.sh
LOCK=/tmp/.crowdsec-lxc-bootstrap.lock
# 【v.108.70】与 bootstrap 同源。bootstrap 自己认 CS_BOOTSTRAP_LOG（第 171 行），
# 但 probe 这边原来是硬编码：改了 bootstrap 的日志路径，probe 还在往老文件追加输出、
# 也在老文件里找「补印」痕迹，两边对不上却没有任何报错 —— 这类「不报错但给错答案」
# 比直接报错难查得多。现在两边都从同一个变量取默认值。
BOOT_LOG="${CS_BOOTSTRAP_LOG:-/root/crowdsec-lxc-bootstrap.log}"
LXC_NAME="${LXC_NAME:-ubuntu}"
LXC_PATH="${LXC_PATH:-/srv/lxc}"
# 与 bootstrap 的 STATE_DIR 推导保持一致（CS_BOOTSTRAP_STATE 可整体改根）
STAMP_FILE="${CS_BOOTSTRAP_STATE:-$LXC_PATH/$LXC_NAME/.bootstrap}/installed"
# 【v.108.30】补印判据用：installed 缺失时，靠「容器文件系统在不在」区分
# 「真的还没装」和「装过了但印丢了」。CS_ROOTFS 只为测试能指到临时目录。
ROOTFS="${CS_ROOTFS:-$LXC_PATH/$LXC_NAME/rootfs}"
# 探针自己的运行状态（跨轮/跨重启持久：停滞轮数、上次触发、连续失败次数）
STATE_FILE="${CS_PROBE_STATE:-/tmp/crowdsec-probe.state}"

PROBE_INTERVAL="${CS_PROBE_INTERVAL:-60}"
PROBE_STALL_ROUNDS="${CS_PROBE_STALL_ROUNDS:-3}"
PROBE_COOLDOWN="${CS_PROBE_COOLDOWN:-600}"
PROBE_LOCK_STALE="${CS_PROBE_LOCK_STALE:-1800}"
PROBE_FAIL_ALERT="${CS_PROBE_FAIL_ALERT:-5}"
# 【v.108.25】全量体检间隔（按轮数）。bootstrap 的 --verify-only 会把 28 个节点
# 从 img_migrate 到 capi_release 全验一遍、一个字节都不写。last_pull 只反映
# 「bouncer 拉得到吗」，配置被改坏但还能拉的时候它照样是绿的 —— 所以每隔
# AUDIT_EVERY 轮做一次从头到脚的体检。0 = 关闭。
PROBE_AUDIT_EVERY="${CS_PROBE_AUDIT_EVERY:-30}"
# 【v.108.67 设上限 / v.108.68 分档】bootstrap 内部每条宿主命令都有上限（v.108.66），
# 但「节点数 × 10s」没有上界；probe 是常驻进程，卡在 wait 上不退 = procd 不 respawn
# = 监视链路静默停摆（本文件里最像「看起来在跑、其实什么都没做」的一处）。
#
# 一个 1800s 的大锅不行：它比最坏路径还长一倍，等于「真卡住」也要等半小时才有人知道。
# 按调用类型分三档，每档都按**代码里数得出来的最坏路径**取 1.5 倍：
#   --probe-check  只判 last_pull（bouncer_pulling：2 次 attach + 时间比较），
#                  正常 3~5s                                        → 60s（十倍余量）
#   --verify-only  28 个节点全验、一个字节都不写，正常 20~40s          → 300s
#   无参数（完整）  ct_force_stop 最多 3×48s≈150s + _wait_lapi_ready 60s
#                  + _wait_capi_net 30s + 网桥重接 10×1s + DNS 30s
#                  + enroll 两轮 15s ≈ 5~6 分钟                     → 900s
# 取最坏路径的倍数而不是正常耗时：上限越短越容易误杀，而误杀要白等一轮冷却，
# 连续 5 次才锁存 need-human —— 宁可在真卡住时多等几分钟，也不制造假失败。
PROBE_CHECK_MAX="${CS_PROBE_CHECK_MAX:-60}"
PROBE_VERIFY_MAX="${CS_PROBE_VERIFY_MAX:-300}"
PROBE_FIX_MAX="${CS_PROBE_FIX_MAX:-900}"
# guard 自身有 3 次 attach × 10s，正常几百 ms；60s 是硬顶，不是预期耗时。
PROBE_GUARD_MAX="${CS_PROBE_GUARD_MAX:-60}"
# 【v.180.78】固件版本号。五个脚本统一用 SCRIPT_VER 一个名字，
# 一条命令就能全查出来：
#   grep -H -m1 '^SCRIPT_VER=' /usr/sbin/crowdsec-*.sh /etc/rc.local \
#        /etc/init.d/crowdsec-lxc-probe
# 只有 crowdsec-lxc-bootstrap.sh 的那一份参与 CFG_SHA_FILE 指纹判定；
# 这里这份纯标记，改它不会触发任何重写。
SCRIPT_VER="2026-10-28.180.130"

plog() { logger -t crowdsec-probe "$*"; }

# 所有 bootstrap 调用都从这里走：一处定义、多处引用，避免漏掉某一处。
# 按参数选档：--probe-check / --verify-only / 其余（完整引导）。
# _BOOT_MAX 留给 124 那句日志复用 —— 日志里写的必须是**这一档实际用的**上限，
# 写成常量名会让人以为所有调用都是同一个数。
# timeout 只终止 bootstrap 本身，容器（lxc-start -d 拉起的）不受影响。
_boot() {
    case "${1:-}" in
    --probe-check) _BOOT_MAX="$PROBE_CHECK_MAX" ;;
    --verify-only) _BOOT_MAX="$PROBE_VERIFY_MAX" ;;
    *) _BOOT_MAX="$PROBE_FIX_MAX" ;;
    esac
    timeout "$_BOOT_MAX" "$BOOT" "$@"
}

# ---- 核心脚本完整性：每轮先复原被改动的脚本，再判定 last_pull ----
# 必须排在 probe_tick 之前：bootstrap 持锁时 tick 会走 lock-busy 提前返回，
# 完整性检查不能跟着停摆 —— 那正好是"脚本正在被用"的时候。
# guard 不负责它自己（被改成 exit 0 就什么都不会复原），所以调用前先自举。
_guard_run() {
    if [ -f "/rom$GUARD" ] && ! cmp -s "/rom$GUARD" "$GUARD" 2>/dev/null; then
        rm -f "$GUARD"
        cp -f "/rom$GUARD" "$GUARD" 2>/dev/null
        chmod 755 "$GUARD" 2>/dev/null
    fi
    # 【v.180.119】bootstrap 同口径复原：每轮查，与本函数的 guard 同一时机 ——
    # tick 遇到 lock-busy 会提前返回，完整性检查不能跟着停摆。
    _ensure_boot || :
    [ -x "$GUARD" ] && timeout "$PROBE_GUARD_MAX" "$GUARD" quiet
    return 0
}

# ---- 锁陈旧判定：返 0 = 陈旧（可回收），返 1 = 真的有人持有 ----
# LOCK_WHY 说明原因，只用于日志（测试可断言）
_lock_stale() {
    LOCK_WHY=""
    _ls_pid=$(cat "$LOCK/pid" 2>/dev/null)
    _ls_ts=$(cat "$LOCK/ts"  2>/dev/null)
    # ① 锁里有 pid 且该进程已不存在 → 持有者被 kill -9 或异常退出
    if [ -n "$_ls_pid" ] && ! kill -0 "$_ls_pid" 2>/dev/null; then
        LOCK_WHY="持有者 pid $_ls_pid 已不存在"
        return 0
    fi
    # ② 锁里有落盘时间且已超时 → 持有者卡死（pid 被复用也拦得住）
    if [ -n "$_ls_ts" ]; then
        _ls_now=$(date +%s)
        if [ $((_ls_now - _ls_ts)) -gt "$PROBE_LOCK_STALE" ]; then
            LOCK_WHY="持锁 $((_ls_now - _ls_ts))s，超过 ${PROBE_LOCK_STALE}s"
            return 0
        fi
        return 1
    fi
    # ③ 旧格式锁（v.106 之前留下的空目录，无 pid/ts）：无法自证，用一个保守依据
    #    —— 真有 bootstrap 进程在跑就不动它，否则回收。
    if pgrep -f "crowdsec-lxc-bootstrap" >/dev/null 2>&1; then
        LOCK_WHY=""
        return 1
    fi
    LOCK_WHY="旧格式锁且无 bootstrap 进程"
    return 0
}

# ---- bootstrap 本体在位性（v.180.118）----
# 探针能跑到这里，说明它自己还在；但 bootstrap 可能已经不在了 ——
# 它不属于任何 opkg/apk 包（是 files/ 直接铺进固件的），所以 opkg remove 碰不到它，
# 只有手动 rm、或某个写错的脚本把它删了才会消失。
# 一旦它没了，三条修复通道（补印 / 停滞 / DNS）全部以 127 空转，
# 日志只会一路「bootstrap 退出 127」，最后停在「需人工介入」—— 而 /rom 里其实有一份。
#
# 口径：与 _guard_run 一致 —— 与只读基座不一致就覆盖（v.180.119 起）。
# 这个口径的安全前提是「更新只通过刷机完成」：刷机后 /rom 即当前版，
# 两边内容相同 → 每轮零动作；只有运行副本被删或被改，才从 /rom 复原。
#
# ⚠ 部署顺序：**先刷机、后让新探针生效**。
# 如果拿新探针跑在旧固件上（/rom 还是 2026-04-22 那版 286834 B），
# 每轮都会把运行副本的 bootstrap 盖回旧版 —— 那时日志会连刷
# 「与只读基座不一致，已按固件版复原」，看到这句就该刷机了。
_ensure_boot() {
    # 【v.180.119】口径与上一段 _guard_run 完全一致：**与只读基座不一致就覆盖**。
    # 这个口径成立的前提只有一个 —— 更新只通过刷机完成：
    # 刷机后 /rom 里就是当前版，两边 cmp 相同，本函数每轮都零动作。
    # 代价（已知并接受）：不刷机、却在路由器上手动换掉运行副本的话，
    # 下一轮就会被 /rom 那份盖回去。
    _eb_src="${BOOT_SRC:-$ROMDIR$BOOT}"
    # 只读基座里没有可用版本 → 补不了，交给调用方记 78
    [ -x "$_eb_src" ] || {
        [ -x "$BOOT" ] && return 0
        plog "【脚本】$BOOT 不可用，且只读基座里也没有（$_eb_src）：自动修复通道已失效，请重刷固件"
        return 1
    }
    # 在位且与只读基座一致 → 零动作（这是刷机后的常态）
    [ -x "$BOOT" ] && cmp -s "$_eb_src" "$BOOT" 2>/dev/null && return 0
    cp -f "$_eb_src" "$BOOT" 2>/dev/null
    chmod 755 "$BOOT" 2>/dev/null
    [ -x "$BOOT" ] || {
        plog "【脚本】$BOOT 无法复原（拷贝或改权限失败，源 $_eb_src）"
        return 1
    }
    plog "【脚本】$BOOT 与只读基座不一致，已按固件版复原（$_eb_src）"
    return 0
}

# ---- smartdns 53 体检（v.180.117）----
# 补的是一整类白屏：DNS 挂了但 last_pull 照样新鲜，于是 stalled 判定永远不触发。
# last_pull 走的是 IP 直连 LAPI（http://10.1.0.10:8080/），不查 DNS ——
# 所以「53 没人应答」这件事，原来的探针完全看不见，一直要到人去翻 /etc/resolv.conf 才发现。
# 典型成因：在 LuCI 里改 smartdns 配置写坏了 → restart 失败 → 53 无应答 → 全家断网，
# 而探针日志一路「ok」，重启路由器才恢复。
#
# 判据取向（只认本地故障，这一点决定了它不会误刷）：
#   · 进程不在        → 本机问题，重跑引导有意义
#   · 53 没在监听     → 本机问题（起不来 / bind 绑到具体网卡）
#   · 进程在、53 在听 → 一律算好。上游全挂、外网不通也一样「算好」——
#     那是网络问题，重跑引导修不好，每轮触发只会刷日志、白撞冷却。
_dns_ok() {
    if ! pidof smartdns >/dev/null 2>&1; then
        DNS_WHY="进程不在"
        return 1
    fi
    if ! netstat -lnu 2>/dev/null | grep -qE ':53[[:space:]]'; then
        DNS_WHY="53 未监听（UDP）"
        return 1
    fi
    DNS_WHY=""
    return 0
}

# ---- smartdns 规则文件自愈（v.180.124）----
# 2026-10-28 真机事故：/rom/etc/smartdns/ 里 address.conf(824B)、blacklist-ip.conf(231B)、
# custom.conf(97B)、domain-block.list(96B)、domain-forwarding.list(106B) 全在，
# /etc/smartdns/ 里一个都没有。smartdns 解析 /var/etc/smartdns/smartdns.conf 第 32 行
# 的 conf-file 时直接失败退出 → procd 判 crash loop → 53 端口全空 → probe 判
# 「进程不在」→ 重跑整条 bootstrap → 重启 smartdns → 再挂，死循环。
# 为什么 bootstrap 救不回来：_rom_restore_pkg 对 conffiles 一律 continue，而
# smartdns.conffiles 正好就是 /etc/config/smartdns + 这 5 个文件。文件不存在时，
# 那条「不覆盖用户配置」的保护就变成了「永远不修」。
# bootstrap 侧的 _rom_restore_smartdns_conf 只在新固件里生效；这里再兜一层，
# 让旧固件也能自愈。取向与 bootstrap 完全一致：
#   · 只处理 /etc/smartdns/ 这 5 个文件，绝不碰 /etc/config/smartdns；
#   · 只补「不存在」的，存在就一个字节不动（用户清成 0 字节也尊重）；
#   · 文件齐了立即返回，不重启、不写日志 —— 所以每分钟调一次也是零动作。
_DNS_CONF_FILES="address.conf blacklist-ip.conf custom.conf domain-block.list domain-forwarding.list"
# 两个路径可被环境覆盖：生产环境走默认（真实 /etc/smartdns 与 /etc/init.d/smartdns），
# 只在单元测试里替换成临时目录 —— 否则「文件缺失」这种情形没法在不动真机的前提下复现。
_DNS_CONF_DIR="${CS_PROBE_SD_CONF:-/etc/smartdns}"
_DNS_INIT="${CS_PROBE_SD_INIT:-/etc/init.d/smartdns}"
# 只给测试用：换成 busybox 的 true / false 来模拟「重启后进程在 / 不在」。
_DNS_PIDOF="${CS_PROBE_SD_PIDOF:-pidof}"

_dns_conf_missing() {
    for _dcm_f in $_DNS_CONF_FILES; do
        [ -e "$_DNS_CONF_DIR/$_dcm_f" ] || return 0
    done
    return 1
}

# 返回 0 = 补了文件且重启后进程确实在；返回 1 = 没补（文件齐/源也没有）或补了没救回来。
_dns_selfheal() {
    _dns_conf_missing || return 1
    _dsh_n=0
    for _dsh_f in $_DNS_CONF_FILES; do
        [ -e "$_DNS_CONF_DIR/$_dsh_f" ] && continue
        [ -e "$ROMDIR/etc/smartdns/$_dsh_f" ] || continue
        mkdir -p "$_DNS_CONF_DIR" 2>/dev/null
        cp -a "$ROMDIR/etc/smartdns/$_dsh_f" "$_DNS_CONF_DIR/$_dsh_f" 2>/dev/null \
            && _dsh_n=$((_dsh_n + 1))
    done
    [ "$_dsh_n" -gt 0 ] || return 1
    plog "【DNS】【自愈】/etc/smartdns 缺 $_dsh_n 个规则文件，已从 $ROMDIR 补回，重启 smartdns"
    "$_DNS_INIT" restart >/dev/null 2>&1
    sleep "${CS_PROBE_SD_WAIT:-2}"
    "$_DNS_PIDOF" smartdns >/dev/null 2>&1 && return 0
    return 1
}

# 持锁跑一轮 bootstrap，等它结束，回收锁。返回它的退出码；77 = 抢锁失败。
# 抽出来是因为现在有两条通道要跑同一件事（last_pull 停滞 / DNS 不可用），
# 各写一遍的话，「pid 写进锁」这类容易写错的细节迟早会分叉 ——
# 陈旧锁判定依据的是持有者 pid，不是探针自己，写错了会让锁被误判成陈旧。
_run_fix() {
    # 先保证要跑的东西在：不在就什么都别谈。返回 78 与抢锁失败的 77 区分开 ——
    # 两者的日志和处置完全不同（一个是「等下一轮」，一个是「要重刷固件」）。
    _ensure_boot || return 78
    if ! mkdir "$LOCK" 2>/dev/null; then
        plog "【持锁失败】并发占用，本轮放弃"
        return 77
    fi
    # 后台起 bootstrap 并立刻把「它的」pid 写进锁：陈旧判定的依据必须是持有者，
    # 不是探针自己 —— 否则探针被重启时会把一个仍在跑着的 bootstrap 判成陈旧。
    _boot >>"$BOOT_LOG" 2>&1 &
    _rf_pid=$!
    echo "$_rf_pid" > "$LOCK/pid" 2>/dev/null
    date +%s > "$LOCK/ts" 2>/dev/null
    wait "$_rf_pid"
    _rf_rc=$?
    rm -rf "$LOCK" 2>/dev/null
    return "$_rf_rc"
}

# DNS 通道：连续 PROBE_STALL_ROUNDS 轮不可用 → 冷却检查 → 跑一轮引导 → 看现场复验。
# 计数与锁存都是独立的（P_DNS_*）：与 last_pull 那条链路根因完全不同，
# 共用一个计数器的话，修 DNS 会把「容器拉不动」的累计清零，反过来也一样 ——
# 这正是 v.108.58 在两个锁存上踩过的坑（P_HUMAN 归补印、P_HUMAN_PULL 归停滞）。
# 复验不看退出码看现场：引导可能 exit 0（sd_serve 失败只是 hard 终止在最后一步），
# 也可能 exit 1 而 DNS 其实已恢复，唯一可信的判据是再问一次 _dns_ok。
_dns_watch() {
    if _dns_ok; then
        if [ "${P_DNS_BAD:-0}" -gt 0 ]; then
            plog "【DNS】smartdns 已恢复（此前不可用 $P_DNS_BAD 轮）"
        fi
        P_DNS_BAD=0
        P_DNS_FIX=0
        return 0
    fi
    # 【v.180.124】进程不在时先分诊：是不是规则文件被遮掉了？
    # 是 → 补文件 + 重启 smartdns，当场复验；救回来就别去跑整条 bootstrap。
    # 否 → 一个字都不动，继续走原来的「计数 → 冷却 → 重跑引导」。
    if [ "$DNS_WHY" = "进程不在" ] && _dns_selfheal; then
        if _dns_ok; then
            plog "【DNS】自愈成功：补回规则文件并重启 smartdns 后已恢复（此前不可用 ${P_DNS_BAD:-0} 轮）"
            P_DNS_BAD=0
            P_DNS_FIX=0
            return 0
        fi
    fi
    P_DNS_BAD=$((${P_DNS_BAD:-0} + 1))
    if [ "${P_HUMAN_DNS:-0}" = "1" ]; then
        P_ACTION="dns-need-human-hold"
        plog "【DNS】【需人工介入】已停止重跑（smartdns 仍不可用：$DNS_WHY，累计第 ${P_DNS_BAD} 轮）。修好后重启探针或删除 $STATE_FILE 解除"
        return 0
    fi
    if [ "$P_DNS_BAD" -lt "$PROBE_STALL_ROUNDS" ]; then
        P_ACTION="dns-warn"
        plog "【DNS】smartdns 不可用：$DNS_WHY（第 $P_DNS_BAD/$PROBE_STALL_ROUNDS 轮）"
        return 0
    fi
    _dw_now="$(date +%s)"
    if [ $((_dw_now - ${P_DNS_TRIG:-0})) -lt "$PROBE_COOLDOWN" ]; then
        P_ACTION="dns-cooldown"
        plog "【DNS】smartdns 持续不可用（$DNS_WHY），冷却中（剩余 $((PROBE_COOLDOWN - (_dw_now - P_DNS_TRIG)))s），暂不触发"
        return 0
    fi
    P_DNS_TRIG="$_dw_now"
    P_DNS_BAD=0
    P_ACTION="dns-trigger"
    plog "【DNS】smartdns 连续 ${PROBE_STALL_ROUNDS} 轮不可用（$DNS_WHY），持锁重跑 $BOOT 复验/修复"
    _run_fix
    _dw_rc=$?
    if [ "$_dw_rc" = 78 ]; then
        P_ACTION="dns-boot-missing"
        return 0
    fi
    if [ "$_dw_rc" = 77 ]; then
        P_ACTION="dns-lock-fail"
        return 0
    fi
    if [ "$_dw_rc" = 124 ]; then
        plog "【DNS】【超时】bootstrap 超过 ${_BOOT_MAX:-$PROBE_FIX_MAX}s 未返回，已终止（锁已回收）"
    fi
    if _dns_ok; then
        P_DNS_FIX=0
        plog "【DNS】已恢复（bootstrap 退出 $_dw_rc）"
        return 0
    fi
    P_DNS_FIX=$((${P_DNS_FIX:-0} + 1))
    if [ "$P_DNS_FIX" -ge "$PROBE_FAIL_ALERT" ]; then
        P_ACTION="dns-need-human"
        P_HUMAN_DNS=1
        plog "【DNS】【需人工介入】bootstrap 连续 $P_DNS_FIX 次未能让 smartdns 恢复（本次 $_dw_rc，仍 $DNS_WHY）。先查 $BOOT_LOG，再看 /etc/config/smartdns 是否被手工改坏"
    else
        P_ACTION="dns-fix-fail"
        plog "【DNS】bootstrap 退出 $_dw_rc，smartdns 仍不可用（连续第 $P_DNS_FIX/${PROBE_FAIL_ALERT} 次，日志见 $BOOT_LOG）"
    fi
    return 0
}

# ---- 可测化的一轮处理：判定 + 动作 ----
# 全局状态（测试可直接预设/断言）：
#   P_STALL 连续停滞轮数 / P_LAST_TRIG 上次触发时刻 / P_FAIL 连续修复失败次数
#   P_DNS_BAD 连续 DNS 不可用轮数 / P_DNS_TRIG 上次 DNS 触发时刻 / P_DNS_FIX 连续 DNS 修复失败次数
#   P_LOCK_RECLAIMED 本轮是否回收过陈旧锁 / P_ACTION 本轮动作标签
probe_tick() {
    P_ACTION=""
    # 【v.108.30】「没有 installed」有两种，处置完全不同：
    #   · 镜像没进固件 / 首启引导还没跑到 → 真的没装，等，不判停滞（原逻辑）
    #   · rootfs 已经在、印却不在 → 引导跑过（或跑崩在半路）。这种以前也一律 wait-install，
    #     等于探针在等一个永远不会自己发生的事：能把印写回去的只有引导脚本，
    #     而引导只在开机和探针拉起时才跑。机器就这么静默地永远「未安装」下去。
    if [ ! -s "$STAMP_FILE" ]; then
        [ -d "$ROOTFS/etc" ] || { P_ACTION="wait-install"; return 0; }
    fi
    # 开机引导或上次触发正在跑（持锁中）：本轮不判不动作——只留一个 bootstrap
    if [ -d "$LOCK" ]; then
        if _lock_stale; then
            # 陈旧锁必须回收，否则下面的「持锁失败」会让探针永远不再修复
            plog "【陈旧锁】$LOCK_WHY，回收后本轮继续判定"
            rm -rf "$LOCK" 2>/dev/null
            P_LOCK_RECLAIMED=1
        else
            P_ACTION="lock-busy"
            plog "【引导锁】引导进行中（持锁），本轮跳过判定"
            return 0
        fi
    fi
    # 【v.108.30】补印：rootfs 在、installed 不在，持锁重跑一次引导让它自己写回去。
    # 冷却与失败计数都沿用 last_pull 停滞那一套：不缺耐心，也不刷 flash——
    # 60s 一轮的探针若无冷却，一台配置写不进去的机器会每分钟重跑一次完整引导。
    if [ ! -s "$STAMP_FILE" ]; then
        # 【v.108.34】达到失败阈值后彻底停手。原来达到阈值只打一条「需人工介入」，
        # 下一轮冷却一过照样重跑 —— 于是变成「每 5 分钟重建一次网桥 + 重启一次容器」
        # 的永久循环（首台真机实测：capi_block 误判 → exit 1 → 5 分钟一轮不停）。
        # 重跑同一套脚本换不来新结果，代价却是真实的：每轮 PREP 都会重建 lxcbr0，
        # veth 就有一次被甩掉的机会。停手比乱修安全。
        # 解除方式三种：引导修好后自己写回 installed、重启探针、删 $STATE_FILE。
        if [ "${P_HUMAN:-0}" = "1" ]; then
            P_ACTION="need-human-hold"
            plog "【需人工介入】已停止重跑（installed 仍缺：$STAMP_FILE）。修好后重启探针或删除 $STATE_FILE 解除"
            return 0
        fi
        _rs_now="$(date +%s)"
        if [ $((_rs_now - ${P_LAST_TRIG:-0})) -lt "$PROBE_COOLDOWN" ]; then
            P_ACTION="restamp-cooldown"
            plog "【补印】installed 缺失，冷却中（剩余 $((PROBE_COOLDOWN - (_rs_now - ${P_LAST_TRIG:-0})))s）"
            return 0
        fi
        P_LAST_TRIG="$_rs_now"
        P_ACTION="restamp"
        plog "【补印】installed 缺失但容器 rootfs 已就绪（$ROOTFS），持锁重跑引导补印"
                _run_fix
        _rs_rc=$?
        if [ "$_rs_rc" = 78 ]; then
            P_ACTION="boot-missing"
            return 0
        fi
        if [ "$_rs_rc" = 77 ]; then
            P_ACTION="lock-fail"
            return 0
        fi
        if [ "$_rs_rc" = 0 ] && [ -s "$STAMP_FILE" ]; then
            P_ACTION="restamp-ok"
            P_FAIL=0
            P_HUMAN=0
            plog "【补印】引导退出 0，installed 已落位（$STAMP_FILE）"
        else
            P_FAIL=$((${P_FAIL:-0} + 1))
            if [ "$P_FAIL" -ge "$PROBE_FAIL_ALERT" ]; then
                P_ACTION="need-human"
                P_HUMAN=1
                plog "【需人工介入】补印连续 $P_FAIL 次仍失败（本次退出 $_rs_rc），installed 依然缺失：$STAMP_FILE。已停止自动重跑"
            else
                P_ACTION="restamp-fail"
                plog "【补印】引导退出 $_rs_rc，installed 仍缺失（连续第 $P_FAIL/${PROBE_FAIL_ALERT} 次，日志见 $BOOT_LOG）"
            fi
        fi
        return 0
    fi
    # 【v.108.25】每 PROBE_AUDIT_EVERY 轮做一次全量体检。
    # 顺序是「体检 → 问 ② last_pull 有效吗 → 有效再复检一次 → 仍异常才重跑 ①」：
    #   · 体检说不符，可能只是容器刚重启、文件正被写、配置还没被进程认下 —— 一次不算数；
    #   · 先问 ② 是拿「链路此刻通不通」当旁证：链路都不通时，修配置没有意义，
    #     那种情况交给 ② 自己的停滞判定（3 轮 + 冷却后它自己会拉 ①），这里不动手；
    #   · 链路有效才复检，两次都不符才认定是真漂移 → 重跑 ①（它会自己先验后补）。
    # 这样 ③ 永远不会在「bouncer 拉不动」时抢跑，避免和 ② 各拉一次 ①。
    P_ROUND=$((${P_ROUND:-0} + 1))
    if [ "${PROBE_AUDIT_EVERY:-0}" -gt 0 ] 2>/dev/null \
       && [ $((P_ROUND % PROBE_AUDIT_EVERY)) -eq 0 ]; then
        if _boot --verify-only >>"$BOOT_LOG" 2>&1; then
            plog "【体检】第 ${P_ROUND} 轮：全量验证全部达标"
            P_AUDIT_BAD=0
        elif ! _boot --probe-check >/dev/null 2>&1; then
            P_ACTION="audit-wait-bouncer"
            plog "【体检】第 ${P_ROUND} 轮：有项不符，但 last_pull 此刻无效 —— 不抢跑，交给停滞判定处置"
        elif _boot --verify-only >>"$BOOT_LOG" 2>&1; then
            plog "【体检】第 ${P_ROUND} 轮：首检不符、复检通过（偶发），不动现场"
            P_AUDIT_BAD=0
        else
            P_AUDIT_BAD=$((${P_AUDIT_BAD:-0} + 1))
            plog "【体检】第 ${P_ROUND} 轮：首检与复检都不符（连续 ${P_AUDIT_BAD} 次），重跑引导按需补齐"
            _run_fix
        fi
    fi
    # 【v.180.117】DNS 体检必须排在 last_pull 判定之前：后者在「链路正常」时直接
    # return 0，放在它后面等于永远不执行 —— 而 DNS 挂掉恰恰是「链路照样正常」的情形。
    _dns_watch
    if _boot --probe-check >/dev/null 2>&1; then
        if [ "${P_STALL:-0}" -gt 0 ]; then
            plog "【恢复】last_pull 已恢复（停滞 $P_STALL 轮后）"
        fi
        if [ "${P_FAIL:-0}" -gt 0 ]; then
            plog "【恢复】修复已生效，连续失败计数 ${P_FAIL} 清零"
        fi
        P_STALL=0
        P_FAIL=0
        # 【v.108.58】last_pull 自己恢复了 = 根因已消失，停手锁存必须一起解除。
        # 原来只清 P_STALL/P_FAIL，P_HUMAN 留着 → 下次真停滞时直接「停手」，
        # 等于自动修复被永久关掉，而日志里只写「需人工介入」不写「因为你上次没修好」。
        P_HUMAN_PULL=0
        P_ACTION="ok"
        return 0
    fi
    P_STALL=$((${P_STALL:-0} + 1))
    # 【v.108.58】need-human 之后必须停手。这条检查原来只在补印分支（installed 缺失）
    # 有 —— v.108.34 修过「达到失败阈值后冷却一过照样重跑」，但只修了那一条路；
    # 停滞这条路照样每 10 分钟重建一次 lxcbr0、重启一次容器内 crowdsec。
    # 重跑同一套脚本换不来新结果，代价却是真实的（真机 veth 被甩掉过一次）。
    # 解除方式与补印分支一致：修好后重启探针、或删掉 $STATE_FILE。
    if [ "${P_HUMAN_PULL:-0}" = "1" ]; then
        P_ACTION="need-human-hold"
        plog "【需人工介入】已停止重跑（last_pull 仍停滞，累计第 ${P_STALL} 轮）。修好后重启探针或删除 $STATE_FILE 解除"
        return 0
    fi
    if [ "$P_STALL" -lt "$PROBE_STALL_ROUNDS" ]; then
        P_ACTION="stall-warn"
        plog "【停滞】last_pull 停滞（第 $P_STALL/$PROBE_STALL_ROUNDS 轮）"
        return 0
    fi
    # 连续停滞达阈值 → 冷却检查 → 告警 + 拉起 bootstrap
    _now="$(date +%s)"
    if [ $((_now - ${P_LAST_TRIG:-0})) -lt "$PROBE_COOLDOWN" ]; then
        P_ACTION="cooldown"
        plog "【冷却】last_pull 持续停滞，冷却中（剩余 $((PROBE_COOLDOWN - (_now - P_LAST_TRIG)))s），暂不触发"
        return 0
    fi
    P_LAST_TRIG="$_now"
    P_STALL=0
    P_ACTION="trigger"
    plog "【触发】last_pull 连续停滞 $PROBE_STALL_ROUNDS 轮，持锁重跑 $BOOT 复验/修复"
    _run_fix
    _rc=$?
    if [ "$_rc" = 78 ]; then
        P_ACTION="boot-missing"
        return 0
    fi
    if [ "$_rc" = 77 ]; then
        P_ACTION="lock-fail"
        return 0
    fi
    # 【v.108.67】124 撞的是 _boot 的总上限，语义是「卡住了」，不是「修不好」。
    # 不单独说一句的话，日志只剩「bootstrap 退出 124」，看的人会当成脚本自己的退出码。
    if [ "$_rc" = 124 ]; then
        plog "【超时】bootstrap 超过 ${_BOOT_MAX:-$PROBE_FIX_MAX}s 未返回，已终止（容器或网络卡住；锁已回收）"
    fi
    # 【v.108.58】bootstrap 退出 0 不等于 last_pull 修好了：bouncer_verify 在
    # SOFT_NODES 里（首启心跳有 10s 延迟，不该把整轮引导判死），它失败时引导照样
    # exit 0。原来这里直接 P_FAIL=0 并打「复验完成」，于是 PROBE_FAIL_ALERT 那条
    # 「需人工介入」对 last_pull 停滞永远不可达 —— 每 10 分钟重跑一轮、日志一路报喜，
    # 机器卡在坏状态。这是「不报错、只给错误答案」的典型形态。
    # 退出 0 时再自问一次：仍停滞 = 这轮没修好，按失败计（97 只是给日志一个可辨识的值）。
    if [ "$_rc" = 0 ] && ! _boot --probe-check >/dev/null 2>&1; then
        _rc=97
        plog "【复验未生效】bootstrap 退出 0，但 last_pull 仍停滞（bouncer_verify 是 SOFT 节点，不参与退出码）—— 按失败计"
    fi
    if [ "$_rc" = 0 ]; then
        P_FAIL=0
        plog "【复验完成】bootstrap 退出 0（链路就绪或已修复）"
        return 0
    fi
    P_FAIL=$((${P_FAIL:-0} + 1))
    if [ "$P_FAIL" -ge "$PROBE_FAIL_ALERT" ]; then
        P_ACTION="need-human"
        # 锁存写 P_HUMAN_PULL，不写 P_HUMAN：P_HUMAN 归补印链路。
        # 共用的话，两条链路会互相把对方的自动修复关掉，而根因完全不同。
        P_HUMAN_PULL=1
        plog "【需人工介入】bootstrap 连续 $P_FAIL 次未能让 last_pull 恢复（本次 $_rc）：判定修复能力对不上现场。按设计此时不重装——重装跑同一套脚本只会重蹈覆辙。请人工检查 $BOOT_LOG"
    else
        P_ACTION="fix-fail"
        plog "【复验失败】bootstrap 退出 $_rc（连续第 $P_FAIL/${PROBE_FAIL_ALERT} 次，日志见 $BOOT_LOG）"
    fi
    return 0
}

# ---- 【v.180.128】本地包源自检 ----
# pkg-cache 是固件自带的离线包库，被 opkg 卸掉的包靠它装回来。
# 它坏掉不影响路由转发，所以不能像 last_pull 那样触发修复；但也不能一声不吭 ——
# 等到真要用（ssrp/clashoo 被卸）才发现装不回来，那时人已经在救火了。
# 这里只做「看一眼、异常才说话」：状态变化时才写日志，防止每分钟刷一条。
# 【v.180.130】按包管理器选路径：25.12 是 apk（.apk / packages.adb / /etc/apk/repositories），
# 24.10 及以前是 opkg（.ipk / Packages / /etc/opkg/customfeeds.conf）。
if command -v apk >/dev/null 2>&1; then
    PKG_CACHE_RO_P="${PKG_CACHE_RO:-$ROMDIR/root/apk-cache}"
    PKG_CACHE_P="${PKG_CACHE:-/root/apk-cache}"
    PKG_IDX="packages.adb"
    PKG_EXT="apk"
    # CS_PROBE_PKG_CONF 只给夹具用：生产环境为空，读的仍是 /etc/apk/repositories
    PKG_CF="${CS_PROBE_PKG_CONF:-/etc/apk/repositories}"
else
    PKG_CACHE_RO_P="${PKG_CACHE_RO:-$ROMDIR/root/pkg-cache}"
    PKG_CACHE_P="${PKG_CACHE:-/root/pkg-cache}"
    PKG_IDX="Packages"
    PKG_EXT="ipk"
    # CS_PROBE_PKG_CONF 只给夹具用：生产环境为空，读的仍是 /etc/opkg/customfeeds.conf
    PKG_CF="${CS_PROBE_PKG_CONF:-/etc/opkg/customfeeds.conf}"
fi
PKG_STATE="${CS_PROBE_PKG_STATE:-/tmp/crowdsec-probe.pkgcache}"

_pkgcache_probe() {
    _pk_msg=""
    _pk_dir=""
    for _pk_d in "$PKG_CACHE_RO_P" "$PKG_CACHE_P"; do
        [ -n "$_pk_d" ] || continue
        [ -f "$_pk_d/$PKG_IDX" ] || continue
        _pk_dir="$_pk_d"
        break
    done
    if [ -z "$_pk_dir" ]; then
        _pk_msg="本地包源不可用：$PKG_CACHE_RO_P 与 $PKG_CACHE_P 都没有 $PKG_IDX 索引，被卸的包只能拷文件兜底（包管理器记账不会恢复）"
    else
        _pk_n=$(ls "$_pk_dir"/*."$PKG_EXT" 2>/dev/null | wc -l)
        [ "$_pk_n" -gt 0 ] 2>/dev/null || _pk_msg="本地包源 $_pk_dir 有索引但 0 个 $PKG_EXT，装不上任何包"
        if [ -z "$_pk_msg" ] && [ -f "$PKG_CF" ]; then
            while IFS= read -r _pk_l; do
                case "$_pk_l" in
                # 两种写法都要认：
                #   opkg: src/gz pkgcache  file:///rom/root/pkg-cache
                #   apk : file:///rom/root/apk-cache
                # 只要是 file:// 源就校验目录在不在 —— 死掉的 file:// 源会让
                # opkg/apk 取索引时整体报错，不分是哪个包管理器加进来的。
                *file://*)
                    _pk_t=${_pk_l##*file://}
                    _pk_t=${_pk_t%%[!0-9A-Za-z/._:-]*}
                    if [ -n "$_pk_t" ] && [ ! -d "$_pk_t" ]; then
                        _pk_msg="$(basename "$PKG_CF") 存在死源 file://$_pk_t（目录不存在），包管理器取索引会报错"
                        break
                    fi
                    ;;
                esac
            done < "$PKG_CF"
        fi
    fi
    _pk_prev=""
    [ -s "$PKG_STATE" ] && _pk_prev=$(cat "$PKG_STATE" 2>/dev/null)
    [ "$_pk_msg" = "$_pk_prev" ] && return 0
    printf '%s\n' "$_pk_msg" > "$PKG_STATE" 2>/dev/null
    if [ -n "$_pk_msg" ]; then
        plog "【包源】$_pk_msg"
    elif [ -n "$_pk_prev" ]; then
        plog "【包源】已恢复正常（$_pk_dir，$(ls "$_pk_dir"/*."$PKG_EXT" 2>/dev/null | wc -l) 个 $PKG_EXT）"
    fi
    return 0
}

# ---- 状态落盘 / 恢复：让停滞轮数、冷却、失败计数跨重启仍然准确 ----
_probe_save() {
    # 【v.180.117】四个 dns* 键的命名是被 sed 逼出来的：_probe_load 用
    # `s/.*fail=\([0-9]*\).*/` 这类贪婪匹配取值，新键只要含有旧键的字面量
    # （比如 dns_fail 含 fail=、dns_human 含 human=）就会被当成旧键取走，
    # 于是「DNS 修复失败 2 次」会把 last_pull 的失败计数改成 2。
    # 所以叫 dnsfix / dnshold，不叫 dns_fail / dns_human。
    printf 'stall=%s last_trig=%s fail=%s action=%s ts=%s round=%s audit_bad=%s human=%s human_pull=%s dnsbad=%s dnsfix=%s dnstrig=%s dnshold=%s\n' \
        "${P_STALL:-0}" "${P_LAST_TRIG:-0}" "${P_FAIL:-0}" "${P_ACTION:-none}" "$(date +%s)" \
        "${P_ROUND:-0}" "${P_AUDIT_BAD:-0}" "${P_HUMAN:-0}" "${P_HUMAN_PULL:-0}" \
        "${P_DNS_BAD:-0}" "${P_DNS_FIX:-0}" "${P_DNS_TRIG:-0}" "${P_HUMAN_DNS:-0}" \
        > "$STATE_FILE" 2>/dev/null
}
_probe_load() {
    [ -s "$STATE_FILE" ] || return 0
    _pl=$(cat "$STATE_FILE" 2>/dev/null)
    _v=$(printf '%s\n' "$_pl" | sed -n 's/.*stall=\([0-9][0-9]*\).*/\1/p')
    [ -n "$_v" ] && P_STALL="$_v"
    _v=$(printf '%s\n' "$_pl" | sed -n 's/.*last_trig=\([0-9][0-9]*\).*/\1/p')
    [ -n "$_v" ] && P_LAST_TRIG="$_v"
    _v=$(printf '%s\n' "$_pl" | sed -n 's/.*fail=\([0-9][0-9]*\).*/\1/p')
    [ -n "$_v" ] && P_FAIL="$_v"
    # 【v.108.58】停滞链路的独立锁存。旧状态文件没有这个键 → 保持 0（向后兼容）。
    _v=$(printf '%s\n' "$_pl" | sed -n 's/.*human_pull=\([0-9][0-9]*\).*/\1/p')
    [ -n "$_v" ] && P_HUMAN_PULL="$_v"
    _v=$(printf '%s\n' "$_pl" | sed -n 's/.*round=\([0-9][0-9]*\).*/\1/p')
    [ -n "$_v" ] && P_ROUND="$_v"
    _v=$(printf '%s\n' "$_pl" | sed -n 's/.*audit_bad=\([0-9][0-9]*\).*/\1/p')
    [ -n "$_v" ] && P_AUDIT_BAD="$_v"
    _v=$(printf '%s\n' "$_pl" | sed -n 's/.*human=\([0-9][0-9]*\).*/\1/p')
    [ -n "$_v" ] && P_HUMAN="$_v"
    # 【v.180.117】DNS 通道的独立计数与锁存。旧状态文件没这几个键 → 保持 0（向后兼容）。
    _v=$(printf '%s\n' "$_pl" | sed -n 's/.*dnsbad=\([0-9][0-9]*\).*/\1/p')
    [ -n "$_v" ] && P_DNS_BAD="$_v"
    _v=$(printf '%s\n' "$_pl" | sed -n 's/.*dnsfix=\([0-9][0-9]*\).*/\1/p')
    [ -n "$_v" ] && P_DNS_FIX="$_v"
    _v=$(printf '%s\n' "$_pl" | sed -n 's/.*dnstrig=\([0-9][0-9]*\).*/\1/p')
    [ -n "$_v" ] && P_DNS_TRIG="$_v"
    _v=$(printf '%s\n' "$_pl" | sed -n 's/.*dnshold=\([0-9][0-9]*\).*/\1/p')
    [ -n "$_v" ] && P_HUMAN_DNS="$_v"
    return 0
}

# ---- 主循环：等安装 → 每 PROBE_INTERVAL 一轮 ----
P_STALL=0
P_LAST_TRIG=0
P_FAIL=0
P_LOCK_RECLAIMED=0
P_ROUND=0
P_AUDIT_BAD=0
P_HUMAN=0
P_HUMAN_PULL=0
P_DNS_BAD=0
P_DNS_FIX=0
P_DNS_TRIG=0
P_HUMAN_DNS=0
DNS_WHY=""
_probe_load
while true; do
    P_LOCK_RECLAIMED=0
    _guard_run
    probe_tick
    _probe_save
    _pkgcache_probe
    sleep "$PROBE_INTERVAL"
done
