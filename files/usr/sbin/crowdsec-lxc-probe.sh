#!/bin/sh
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

BOOT=/usr/sbin/crowdsec-lxc-bootstrap.sh
GUARD=/usr/sbin/crowdsec-guard.sh
LOCK=/tmp/.crowdsec-lxc-bootstrap.lock
BOOT_LOG=/root/crowdsec-lxc-bootstrap.log
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

plog() { logger -t crowdsec-probe "$*"; }

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
    [ -x "$GUARD" ] && "$GUARD" quiet
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

# ---- 可测化的一轮处理：判定 + 动作 ----
# 全局状态（测试可直接预设/断言）：
#   P_STALL 连续停滞轮数 / P_LAST_TRIG 上次触发时刻 / P_FAIL 连续修复失败次数
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
        _rs_now="$(date +%s)"
        if [ $((_rs_now - ${P_LAST_TRIG:-0})) -lt "$PROBE_COOLDOWN" ]; then
            P_ACTION="restamp-cooldown"
            plog "【补印】installed 缺失，冷却中（剩余 $((PROBE_COOLDOWN - (_rs_now - ${P_LAST_TRIG:-0})))s）"
            return 0
        fi
        P_LAST_TRIG="$_rs_now"
        P_ACTION="restamp"
        plog "【补印】installed 缺失但容器 rootfs 已就绪（$ROOTFS），持锁重跑引导补印"
        if ! mkdir "$LOCK" 2>/dev/null; then
            P_ACTION="lock-fail"
            plog "【持锁失败】并发占用，本轮放弃"
            return 0
        fi
        "$BOOT" >>"$BOOT_LOG" 2>&1 &
        _rs_pid=$!
        echo "$_rs_pid" > "$LOCK/pid" 2>/dev/null
        date +%s > "$LOCK/ts" 2>/dev/null
        wait "$_rs_pid"
        _rs_rc=$?
        rm -rf "$LOCK" 2>/dev/null
        if [ "$_rs_rc" = 0 ] && [ -s "$STAMP_FILE" ]; then
            P_ACTION="restamp-ok"
            P_FAIL=0
            plog "【补印】引导退出 0，installed 已落位（$STAMP_FILE）"
        else
            P_FAIL=$((${P_FAIL:-0} + 1))
            if [ "$P_FAIL" -ge "$PROBE_FAIL_ALERT" ]; then
                P_ACTION="need-human"
                plog "【需人工介入】补印连续 $P_FAIL 次仍失败（本次退出 $_rs_rc），installed 依然缺失：$STAMP_FILE"
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
        if "$BOOT" --verify-only >>"$BOOT_LOG" 2>&1; then
            plog "【体检】第 ${P_ROUND} 轮：全量验证全部达标"
            P_AUDIT_BAD=0
        elif ! "$BOOT" --probe-check >/dev/null 2>&1; then
            P_ACTION="audit-wait-bouncer"
            plog "【体检】第 ${P_ROUND} 轮：有项不符，但 last_pull 此刻无效 —— 不抢跑，交给停滞判定处置"
        elif "$BOOT" --verify-only >>"$BOOT_LOG" 2>&1; then
            plog "【体检】第 ${P_ROUND} 轮：首检不符、复检通过（偶发），不动现场"
            P_AUDIT_BAD=0
        else
            P_AUDIT_BAD=$((${P_AUDIT_BAD:-0} + 1))
            plog "【体检】第 ${P_ROUND} 轮：首检与复检都不符（连续 ${P_AUDIT_BAD} 次），重跑引导按需补齐"
            if mkdir "$LOCK" 2>/dev/null; then
                "$BOOT" >>"$BOOT_LOG" 2>&1 &
                _ap=$!
                echo "$_ap" > "$LOCK/pid" 2>/dev/null
                date +%s > "$LOCK/ts" 2>/dev/null
                wait "$_ap"
                rm -rf "$LOCK" 2>/dev/null
            fi
        fi
    fi
    if "$BOOT" --probe-check >/dev/null 2>&1; then
        if [ "${P_STALL:-0}" -gt 0 ]; then
            plog "【恢复】last_pull 已恢复（停滞 $P_STALL 轮后）"
        fi
        if [ "${P_FAIL:-0}" -gt 0 ]; then
            plog "【恢复】修复已生效，连续失败计数 ${P_FAIL} 清零"
        fi
        P_STALL=0
        P_FAIL=0
        P_ACTION="ok"
        return 0
    fi
    P_STALL=$((${P_STALL:-0} + 1))
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
    if ! mkdir "$LOCK" 2>/dev/null; then
        P_ACTION="lock-fail"
        plog "【持锁失败】并发占用，本轮放弃"
        return 0
    fi
    # 后台起 bootstrap 并立刻把「它的」pid 写进锁：陈旧判定的依据必须是持有者，
    # 不是探针自己 —— 否则探针被重启时会把一个仍在跑着的 bootstrap 判成陈旧。
    "$BOOT" >>"$BOOT_LOG" 2>&1 &
    _bp=$!
    echo "$_bp" > "$LOCK/pid" 2>/dev/null
    date +%s > "$LOCK/ts"  2>/dev/null
    wait "$_bp"
    _rc=$?
    rm -rf "$LOCK" 2>/dev/null
    if [ "$_rc" = 0 ]; then
        P_FAIL=0
        plog "【复验完成】bootstrap 退出 0（链路就绪或已修复）"
        return 0
    fi
    P_FAIL=$((${P_FAIL:-0} + 1))
    if [ "$P_FAIL" -ge "$PROBE_FAIL_ALERT" ]; then
        P_ACTION="need-human"
        plog "【需人工介入】bootstrap 连续 $P_FAIL 次退出非 0（本次 $_rc）：判定修复能力对不上现场。按设计此时不重装——重装跑同一套脚本只会重蹈覆辙。请人工检查 $BOOT_LOG"
    else
        P_ACTION="fix-fail"
        plog "【复验失败】bootstrap 退出 $_rc（连续第 $P_FAIL/${PROBE_FAIL_ALERT} 次，日志见 $BOOT_LOG）"
    fi
    return 0
}

# ---- 状态落盘 / 恢复：让停滞轮数、冷却、失败计数跨重启仍然准确 ----
_probe_save() {
    printf 'stall=%s last_trig=%s fail=%s action=%s ts=%s round=%s audit_bad=%s\n' \
        "${P_STALL:-0}" "${P_LAST_TRIG:-0}" "${P_FAIL:-0}" "${P_ACTION:-none}" "$(date +%s)" \
        "${P_ROUND:-0}" "${P_AUDIT_BAD:-0}" \
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
    _v=$(printf '%s\n' "$_pl" | sed -n 's/.*round=\([0-9][0-9]*\).*/\1/p')
    [ -n "$_v" ] && P_ROUND="$_v"
    _v=$(printf '%s\n' "$_pl" | sed -n 's/.*audit_bad=\([0-9][0-9]*\).*/\1/p')
    [ -n "$_v" ] && P_AUDIT_BAD="$_v"
    return 0
}

# ---- 主循环：等安装 → 每 PROBE_INTERVAL 一轮 ----
P_STALL=0
P_LAST_TRIG=0
P_FAIL=0
P_LOCK_RECLAIMED=0
P_ROUND=0
P_AUDIT_BAD=0
_probe_load
while true; do
    P_LOCK_RECLAIMED=0
    _guard_run
    probe_tick
    _probe_save
    sleep "$PROBE_INTERVAL"
done
