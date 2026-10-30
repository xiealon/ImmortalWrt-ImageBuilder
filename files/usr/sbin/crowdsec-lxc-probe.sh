#!/bin/sh
# 【v.180.198】固件版本标记 —— 与 crowdsec-lxc-bootstrap.sh 的 SCRIPT_VER 同步，每次改脚本一起改
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
#   CS_PROBE_FAIL_ALERT   连续修复失败几次后报「需人工介入」（默认 3）
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
# 【2026-10-29 用户定】连续修复失败 3 次就锁存 need-human，原来是 5。
# 每次重试之间隔着 PROBE_COOLDOWN（600s）：3 次≈20 分钟喊人，5 次≈40 分钟。
# 而重试跑的是同一套动作（同一份包库、同一个 apk fix），第 4、5 次换不来新结果，
# 只是再写两遍 flash。修不好的三种原因 —— 包里没有、基底坏了、运行侧写不进 ——
# 一个都不会因为多试两次而改变。
PROBE_FAIL_ALERT="${CS_PROBE_FAIL_ALERT:-3}"
# 【v.108.25】全量体检间隔（按轮数）。bootstrap 的 --verify-only 会把 28 个节点
# 从 img_migrate 到 capi_release 全验一遍、一个字节都不写。last_pull 只反映
# 「bouncer 拉得到吗」，配置被改坏但还能拉的时候它照样是绿的 —— 所以每隔
# AUDIT_EVERY 轮做一次从头到脚的体检。0 = 关闭。
PROBE_AUDIT_EVERY="${CS_PROBE_AUDIT_EVERY:-30}"
# 【v.180.198】bouncer 下发面健康检查间隔（按轮数，默认 10 轮 = 10 分钟）。
# 与体检同频但独立开关：体检只读（--verify-only 承诺不写），这里要重启服务。
PROBE_HEAL_EVERY="${CS_PROBE_HEAL_EVERY:-10}"
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
# 连续 3 次才锁存 need-human（见 PROBE_FAIL_ALERT）—— 宁可多等几分钟，也不制造假失败。
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
SCRIPT_VER="2026-10-30.180.198"

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

# ---- smartdns 两条判据：服务生效（--check）+ 上游条数（v.180.198）----
# 这条通道改过三次口径，留个索引，免得下次读代码时以为漏了一半：
#   v.180.117  只判 53（pidof + netstat），连续 N 轮不通过调 --repair；
#   v.180.186  把「53 在听」改成按 socket inode 反查归属 —— dnsmasq 占着 53 时
#              旧判据照样通过，那才是真的没接管；
#   v.180.198  先删 53、只留上游条数（53 起不来该是人看得见的硬故障，脚本别偷偷换人），
#              同日又按要求把 53 判回来 —— 但改用脚本自己的 --check，且失败不再回滚。
# 现状：① 服务没生效、② 上游 0 条，任一成立就动作；修法仍然只有一处 --config。
# 数 uci 里的上游段数。返回纯数字（0 = 没配任何上游）。
# 为什么用 uci 而不是查 smartdns 的实际生效配置：uci 是唯一事实来源，
# smartdns 的 init 每次 start 都从它生成 conf；数段只做一次 uci show + grep，
# 约 10ms，每 60 秒一轮可忽略。
_up_n() {
    uci -q show smartdns 2>/dev/null | grep -c '=server$'
}

# ---- 修复一律交脚本（v.180.158）----
# 探针只做两件事：探测 + 拉脚本。自己不动手补文件、不拼 uci ——
# 修法只留一处（pkg-restore-smartdns.sh），避免探针和脚本两套实现慢慢漂移。
# 这条规则对所有被观测的应用都一样：daed / ssrp / mosdns / clashoo 由
# pkg-restore-apps.sh 统一承担（v.180.162 落地），探针只探测 + 调它，
# 不内联各自的修复动作。
# 不按应用各建一支 pkg-restore-<app>.sh：smartdns 需要专用脚本是因为它还要
# 重写主段与上游、commit、重启并等 53 口；这四个只做「装包」一件事，
# 动作完全同构，四支脚本只会变成四份要同步维护的同一段代码。
#
# 探测项与覆盖关系（用户 2026-10-29 定）：
#   · last_pull 一项覆盖三个项目：lxc 运行时、crowdsec-firewall-bouncer、
#     容器里的 crowdsec。三者必须都正常且配置正确才会产生 LAPI 连接、
#     刷新 last_pull —— 缺任何一个，这项立刻失效。
#     所以它是三项的联合健康信号，不必再分别探三者的进程 / 端口；
#     失效时直接拉 bootstrap，由它去验、去恢复这三项
#     （lxc、bouncer、容器 正好是 bootstrap 六件事里的三件）。
#   · smartdns 两条一起判（v.180.198）：
#     ① 服务生效 —— pkg-restore-smartdns.sh --check（pidof + 53 归属反查）；
#     ② 上游条数 —— uci show smartdns | grep -c '=server$'，0 条才算失效。
#     任一不满足就调 pkg-restore-smartdns.sh --config 重写主段与 13 条上游。
#     判据只留在脚本与这块注释各一处，探针不重复实现（见上方「两条判据」那段）。
#   · 其余应用（daed / ssrp / mosdns / clashoo）只判包在不在册，
#     不搞进程/端口 —— 它们不像 smartdns 那样接管 53，端口多维度没有意义。
#     判的是「主程序 + 依赖内核 + LuCI 界面」整组（v.180.164 扩范围），
#     具体清单与「该不该有」的门槛都在 pkg-restore-apps.sh 里，探针不重复一份。
#     缺了走 _apps_watch → pkg-restore-apps.sh 装回。
#   · lxc 的二进制（v.180.189）判文件不判包：34 个包里 23 条关键路径逐条 [-e]。
#     为什么不能只判包：删掉 /usr/bin/lxc-snapshot 时包还在册，--lxc-missing 输出空、
#     静默放过 —— 而 bootstrap 的 _lxc_missing_deps 只钉死五个核心 applet。
#     为什么不能只判进程：lxc 是工具集不是常驻服务，没有进程可判。
#     恢复交 pkg-restore.sh --lxc（包级，走 apk fix，不做文件级覆盖）。
#
# 为什么不保留「补规则文件 + 重启」的快速通道：
# 2026-10-28 那次事故的根因是 /etc/smartdns 下 5 个规则文件被遮掉，当时探针自己补文件、
# 自己重启，救回来了。但那套逻辑与脚本的 _sd_conf 是同一份清单、两处实现（清单在两边
# 各硬写一遍），将来加文件漏一处就会出现「探针认为齐了、脚本认为缺着」。
# 现在统一走 --repair：它内部第一步就是 _sd_conf 补文件，再重写主段与 13 条上游、
# commit 并重启。代价从「补文件后约 2 秒」变成「完整流程约 15 秒」，但只在
# 连续 N 轮不可用且冷却闸门通过之后触发，不会每分钟来一次。
_SD_RESTORE="${CS_PROBE_SD_RESTORE:-/usr/sbin/pkg-restore-smartdns.sh}"

# 跑脚本的一个子命令。输出转 syslog（标签与探针分开，排障时能分清谁说的）。
# 【v.180.198】不再做「53 现场复验」：复验函数随 53 体检一起删除。
# 上游是否写回由下一轮的 _up_n 再数一次 —— 判据看下一轮的事实，不信退出码。
_up_run() {
    [ -x "$_SD_RESTORE" ] || return 1
    _ur_out="$("$_SD_RESTORE" "$1" 2>&1)"
    _ur_rc=$?
    [ -n "$_ur_out" ] && printf '%s\n' "$_ur_out" | logger -t crowdsec-probe-sd 2>/dev/null
    [ "$_ur_rc" = "0" ] || return 1
    return 0
}

# 【v.180.198】服务是否真的在生效：pidof smartdns + 53 端口归属反查。
# 判据不在这里写第二遍 —— 交 pkg-restore-smartdns.sh --check（内部的 _sd_serve），
# 与 --config 用的是同一份「53 该归谁」的定义。修法留一处，判据也留一处。
# 脚本本身不在位时返回 0（放行）：那是 pkg-restore 的事，不该让 DNS 通道误报。
_up_svc() {
    [ -x "$_SD_RESTORE" ] || return 0
    "$_SD_RESTORE" --check >/dev/null 2>&1
}

# 持锁跑一轮 bootstrap，等它结束，回收锁。返回它的退出码；77 = 抢锁失败。
# 抽出来是因为有两条通道要跑同一件事（last_pull 停滞 / 补印复验），
# 各写一遍的话，「pid 写进锁」这类容易写错的细节迟早会分叉 ——
# 陈旧锁判定依据的是持有者 pid，不是探针自己，写错了会让锁被误判成陈旧。
# 【v.180.191】DNS 通道已退出本函数（见 _up_watch），现在是这两条在用。
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

# DNS 通道：两条判据任一不满足就动作，连续 PROBE_STALL_ROUNDS 轮 → 冷却 → 交 --config。
# 【v.180.198】由原「53 通道」与「上游条数通道」合流（用户 2026-10-31 定）：
#   ① 服务没生效 —— pidof 无进程，或 53 不归 smartdns（被 dnsmasq / 别的进程抢了）；
#   ② 上游被删光 —— 53 照样在听、照样回 SERVFAIL，这才是更隐蔽的那种坏法。
# 两条都过才判好，否则走同一套计数 / 冷却 / 锁存，写回交 pkg-restore-smartdns.sh --config。
# 判据不重复实现：① 用脚本的 --check（_up_svc），② 用 _up_n 数 uci 里的 server 段。
# 与旧「53 通道」的关键区别：写回失败不再把 53 还给 dnsmasq（53 只归 smartdns），
# 脚本只 log + return 1，由本通道的失败计数顶上并最终喊人。
# 计数与锁存独立（P_UP_*），不与 last_pull 链路共用 —— 共用一个计数器的话，
# 修 DNS 会把「容器拉不动」的累计清零，反过来也一样（v.108.58 踩过）。
# 不判「上游少了几条」：用户可能自己删过某几条，那是配置自由；0 条才算失效。
_up_watch() {
    # 没装 smartdns 不是这条通道的事（包由 pkg-restore.sh 管），直接放行
    if [ ! -x /usr/sbin/smartdns ]; then
        P_UP_BAD=0
        P_UP_FIX=0
        return 0
    fi
    _uw_why=""
    _up_svc || _uw_why="53 未由 smartdns 接管"
    _uw_n=$(_up_n)
    case "$_uw_n" in ''|*[!0-9]*) _uw_n=0 ;; esac
    if [ "$_uw_n" -le 0 ]; then
        if [ -n "$_uw_why" ]; then
            _uw_why="$_uw_why + 上游 0 条"
        else
            _uw_why="上游 0 条"
        fi
    fi
    if [ -z "$_uw_why" ]; then
        if [ "${P_UP_BAD:-0}" -gt 0 ]; then
            plog "【DNS】已恢复（$_uw_n 条上游，53 由 smartdns 接管）"
        fi
        P_UP_BAD=0
        P_UP_FIX=0
        return 0
    fi
    P_UP_BAD=$((${P_UP_BAD:-0} + 1))
    if [ "${P_HUMAN_UP:-0}" = "1" ]; then
        P_ACTION="up-need-human-hold"
        plog "【DNS】【需人工介入】已停止重跑（$_uw_why，累计第 ${P_UP_BAD} 轮）。修好后重启探针或删除 $STATE_FILE 解除"
        return 0
    fi
    if [ "$P_UP_BAD" -lt "$PROBE_STALL_ROUNDS" ]; then
        P_ACTION="up-warn"
        plog "【DNS】$_uw_why（第 $P_UP_BAD/$PROBE_STALL_ROUNDS 轮）"
        return 0
    fi
    _uw_now="$(date +%s)"
    if [ $((_uw_now - ${P_UP_TRIG:-0})) -lt "$PROBE_COOLDOWN" ]; then
        P_ACTION="up-cooldown"
        plog "【DNS】$_uw_why，冷却中（剩余 $((PROBE_COOLDOWN - (_uw_now - P_UP_TRIG)))s），暂不触发"
        return 0
    fi
    P_UP_TRIG="$_uw_now"
    P_UP_BAD=0
    # --config 会重写主段、13 条上游、commit 并重启 smartdns（约 15 秒），
    # 所以必须放在冷却闸门之后，不能每轮都来一次。
    P_ACTION="up-repair"
    plog "【DNS】$_uw_why 连续 ${PROBE_STALL_ROUNDS} 轮，交 pkg-restore-smartdns.sh --config 重写配置与 13 条上游"
    if _up_run --config; then
        P_UP_FIX=0
        P_ACTION="up-fixed"
        plog "【DNS】已写回：下一轮复核 53 与上游条数"
        return 0
    fi
    P_UP_FIX=$((${P_UP_FIX:-0} + 1))
    if [ "$P_UP_FIX" -ge "$PROBE_FAIL_ALERT" ]; then
        P_ACTION="up-need-human"
        P_HUMAN_UP=1
        plog "【DNS】【需人工介入】--config 连续 $P_UP_FIX 次未能写回。依次查：53 是否被别的进程占着（netstat -lnup | grep :53）、/etc/config/smartdns 是否可写、uci 是否被锁、/etc/smartdns 下规则文件是否被遮"
    else
        P_ACTION="up-fix-fail"
        plog "【DNS】--config 未能写回（连续第 $P_UP_FIX/${PROBE_FAIL_ALERT} 次）"
    fi
    return 0
}

# ---- 应用主程序通道（v.180.162，v.180.164 扩到依赖与界面）----
# 用户 2026-10-29 定：daed / ssrp / mosdns / clashoo 不像 smartdns 那样接管 53，
# 不搞进程/端口那一套，只判包在不在册；缺了交 pkg-restore-apps.sh 装回。
# v.180.164 起「包」不再等于主程序一个：内核依赖（xray-core / sing-box /
# vmlinux-btf / geo 数据）和 LuCI 壳一并纳入 —— 实测 force-depends 删 clashoo
# 会一次带走 44MB 内核而壳与 i18n 不动，只看主程序名覆盖不到这种半损坏态。
# 判据与「该不该有」的门槛全在脚本里（只恢复固件本来就带的那些包），
# 探针这边只做三件事：拉脚本问一次 → 连续 N 轮缺才动作 → 装完再问一次。
# 修法只留一处，与 smartdns 那条通道同一个取向（v.180.158）。
_APPS_RESTORE="${CS_PROBE_APPS_RESTORE:-/usr/sbin/pkg-restore-apps.sh}"

_apps_watch() {
    [ -x "$_APPS_RESTORE" ] || return 0
    _aw_out="$("$_APPS_RESTORE" --check 2>&1)"
    _aw_rc=$?
    if [ "$_aw_rc" = "0" ]; then
        if [ "${P_APP_BAD:-0}" -gt 0 ]; then
            plog "【应用】主程序已全部在位（此前缺 $P_APP_BAD 轮）"
        fi
        P_APP_BAD=0
        P_APP_FIX=0
        P_HUMAN_APP=0
        return 0
    fi
    # 2 = 判断不了（opkg/apk 都不在，或脚本自己跑不起来）。不计数、不动作 ——
    # 跟「缺了」是两件事，混在一起会在老固件上刷满假告警。
    [ "$_aw_rc" = "1" ] || return 0
    P_APP_BAD=$((${P_APP_BAD:-0} + 1))
    # 达到失败阈值后停手。理由同补印链路：重跑同一套装包换不来新结果，
    # 而每轮都跑一次 opkg --force-reinstall 是实打实刷 flash。
    if [ "${P_HUMAN_APP:-0}" = "1" ]; then
        P_ACTION="app-need-human-hold"
        return 0
    fi
    if [ "$P_APP_BAD" -lt "$PROBE_STALL_ROUNDS" ]; then
        P_ACTION="app-warn"
        plog "【应用】主程序缺失：$_aw_out（第 $P_APP_BAD/$PROBE_STALL_ROUNDS 轮）"
        return 0
    fi
    _aw_now="$(date +%s)"
    if [ $((_aw_now - ${P_APP_TRIG:-0})) -lt "$PROBE_COOLDOWN" ]; then
        P_ACTION="app-cooldown"
        plog "【应用】主程序持续缺失：$_aw_out，冷却中（剩余 $((PROBE_COOLDOWN - (_aw_now - P_APP_TRIG)))s），暂不装回"
        return 0
    fi
    P_APP_TRIG="$_aw_now"
    P_APP_BAD=0
    P_ACTION="app-repair"
    plog "【应用】连续 ${PROBE_STALL_ROUNDS} 轮缺失（$_aw_out），交 pkg-restore-apps.sh 装回"
    "$_APPS_RESTORE" --repair >>"$BOOT_LOG" 2>&1
    # 复判不看脚本退出码：装包可能 exit 0 而包其实没进记账（本地库缺该包时
    # pkg-restore.sh 会逐包 log 失败但整体仍返回非 0；反过来也有 exit 1 而
    # 主要应用都装回来的情况）。唯一可信的判据是再问一次 --check。
    if _aw_out2="$("$_APPS_RESTORE" --check 2>&1)"; then
        P_APP_BAD=0
        P_APP_FIX=0
        P_ACTION="app-fixed"
        plog "【应用】装回成功，主程序已全部在位"
        return 0
    fi
    P_APP_FIX=$((${P_APP_FIX:-0} + 1))
    if [ "$P_APP_FIX" -ge "$PROBE_FAIL_ALERT" ]; then
        P_ACTION="app-need-human"
        P_HUMAN_APP=1
        plog "【应用】【需人工介入】连续 $P_APP_FIX 次装不回（仍缺：$_aw_out2）。多为只读基底包库里没有该包，或包管理器记账写不进去。已停止自动重装"
    else
        P_ACTION="app-fix-fail"
        plog "【应用】装回失败（仍缺：$_aw_out2，连续第 $P_APP_FIX/${PROBE_FAIL_ALERT} 次，日志见 $BOOT_LOG）"
    fi
    return 0
}

# ---- 应用依赖的文件级通道（v.180.181）----
# 盯 18 个包、72 个文件：9 个 kmod 的 26 个 .ko 与 9 个 modules.d 配置，
# 加 ca-bundle / libcap / yq / ip-full / firewall4 / coreutils-nohup / libopenssl3，
# 以及 v2ray-geoip / v2ray-geosite 的两个 .dat（v.180.182 补入，daed 的规则来源）。
# **不含内核本体**（/boot/vmlinuz 与其余模块都不管，内核坏了重刷固件）。
# **不含 /etc/config/**（UCI 配置归 bootstrap 管，恢复出厂基底反而会拆掉 lxc zone）。
# 为什么必须走文件级：kmod-* 在固件出厂库里有、包库里没有 apk，apk add 无处可装；
# 而「包在册、文件被 whiteout」这种形态 apk info -e 完全看不见。
# 详见 pkg-restore.sh 里 --deps 那段的说明。
_KMODS_RESTORE="${CS_PROBE_KMODS_RESTORE:-/usr/sbin/pkg-restore.sh}"

_kmods_watch() {
    [ -f "$_KMODS_RESTORE" ] || return 0
    _kd_out="$(sh "$_KMODS_RESTORE" --deps --check 2>&1)"
    _kd_rc=$?
    if [ "$_kd_rc" = 0 ]; then
        if [ "${P_KMOD_BAD:-0}" -gt 0 ]; then
            plog "【依赖文件】已齐全（此前缺 $P_KMOD_BAD 轮）"
        fi
        P_KMOD_BAD=0
        P_KMOD_FIX=0
        P_HUMAN_KMOD=0
        return 0
    fi
    if [ "$_kd_rc" = 2 ]; then
        if [ "${P_KMOD_NOSRC:-0}" != "1" ]; then
            P_KMOD_NOSRC=1
            P_ACTION="kmods-nosrc"
            plog "【依赖文件】只读基底里没有包文件清单（/rom/lib/apk/packages、/rom/usr/lib/opkg/info 都没有），判不了（$_kd_out）"
        fi
        return 0
    fi
    P_KMOD_BAD=$((${P_KMOD_BAD:-0} + 1))
    if [ "${P_HUMAN_KMOD:-0}" = "1" ]; then
        P_ACTION="kmods-need-human-hold"
        return 0
    fi
    if [ "$P_KMOD_BAD" -lt "$PROBE_STALL_ROUNDS" ]; then
        P_ACTION="kmods-warn"
        plog "【依赖文件】缺失：$_kd_out（第 $P_KMOD_BAD/$PROBE_STALL_ROUNDS 轮）"
        return 0
    fi
    _kd_now=$(date +%s)
    if [ $((_kd_now - ${P_KMOD_TRIG:-0})) -lt "$PROBE_COOLDOWN" ]; then
        P_ACTION="kmods-cooldown"
        plog "【依赖文件】持续缺失，冷却中（剩余 $((PROBE_COOLDOWN - (_kd_now - ${P_KMOD_TRIG:-0})))s），暂不补回"
        return 0
    fi
    P_KMOD_TRIG="$_kd_now"
    P_KMOD_BAD=0
    P_ACTION="kmods-repair"
    plog "【依赖文件】连续 $PROBE_STALL_ROUNDS 轮缺失，开始补回：$_kd_out"
    sh "$_KMODS_RESTORE" --deps --repair >>"$BOOT_LOG" 2>&1
    # 修完必须再问一次 --check，不能凭 --repair 的返回值下结论。
    if _kd_out2="$(sh "$_KMODS_RESTORE" --deps --check 2>&1)"; then
        P_KMOD_BAD=0
        P_KMOD_FIX=0
        P_ACTION="kmods-fixed"
        plog "【依赖文件】已从只读基底补回（/etc/config 不在保护范围，用户配置未动）"
        return 0
    fi
    P_KMOD_FIX=$((${P_KMOD_FIX:-0} + 1))
    if [ "$P_KMOD_FIX" -ge "$PROBE_FAIL_ALERT" ]; then
        P_ACTION="kmods-need-human"
        P_HUMAN_KMOD=1
        plog "【依赖文件】【需人工介入】连续 $P_KMOD_FIX 次补不回（仍缺：$_kd_out2）。多为只读基底不可读或运行侧不可写 —— 只能重刷固件。已停止自动补回"
    else
        P_ACTION="kmods-fix-fail"
        plog "【依赖文件】补回失败（仍缺：$_kd_out2，连续第 $P_KMOD_FIX/${PROBE_FAIL_ALERT} 次，日志见 $BOOT_LOG）"
    fi
    return 0
}

# ---- lxc 二进制的文件级通道（v.180.189）----
# 补的是 _lxc_missing_deps 的盲区。那一条只钉死五个核心 applet
# （lxc-start / lxc-stop / lxc-ls / lxc-info / lxc-attach），判的是「跑不跑得起来」，
# 而且挂在 bootstrap 里 —— 其余 29 个 applet（snapshot / monitor / copy / top …）
# 的二进制被删时，--lxc-missing 看不见（包还在册），也没人每分钟去看。
# 这里改判文件：读 /rom/lib/apk/packages/lxc*.list 与 liblxc.list，
# 挑 /usr/bin、/usr/sbin、/etc/init.d、*.so 逐条 [ -e ]，全程不调 apk。
# 成本实测（192.168.1.201 / 25.12）：34 个包、23 条关键路径，一轮 **6.2 ms**；
# 探针一轮原本约 107 ms，加完约 113 ms，占 60 秒周期的 0.19%。
# 恢复仍走包级 --lxc：实测一轮 3.1 秒，主要耗在 34 次 apk info -e（单次约 77 ms）——
# 所以只在连续 N 轮缺失 + 冷却闸门之后跑一次，绝不每分钟跑。
_LXC_FILES="${CS_PROBE_LXC_FILES:-/usr/sbin/pkg-restore.sh}"
_LXC_RESTORE="${CS_PROBE_LXC_RESTORE:-/usr/sbin/pkg-restore.sh}"

_lxc_watch() {
    [ -f "$_LXC_FILES" ] || return 0
    _lw_out="$(sh "$_LXC_FILES" --lxc-files 2>&1)"
    _lw_rc=$?
    if [ "$_lw_rc" = "0" ]; then
        if [ "${P_LXC_BAD:-0}" -gt 0 ]; then
            plog "【lxc 文件】已全部在位（此前缺 $P_LXC_BAD 轮）"
        fi
        P_LXC_BAD=0
        P_LXC_FIX=0
        P_HUMAN_LXC=0
        return 0
    fi
    # 2 = 只读基底里一张清单都没有，判不了（老固件 / 未刷机）。不计数、不动作。
    if [ "$_lw_rc" = "2" ]; then
        if [ "${P_LXC_NOSRC:-0}" != "1" ]; then
            P_LXC_NOSRC=1
            P_ACTION="lxc-nosrc"
            plog "【lxc 文件】只读基底里没有 lxc 包清单，判不了（$_lw_out）"
        fi
        return 0
    fi
    P_LXC_BAD=$((${P_LXC_BAD:-0} + 1))
    if [ "${P_HUMAN_LXC:-0}" = "1" ]; then
        P_ACTION="lxc-need-human-hold"
        return 0
    fi
    if [ "$P_LXC_BAD" -lt "$PROBE_STALL_ROUNDS" ]; then
        P_ACTION="lxc-warn"
        plog "【lxc 文件】二进制缺失：$_lw_out（第 $P_LXC_BAD/$PROBE_STALL_ROUNDS 轮）"
        return 0
    fi
    _lw_now=$(date +%s)
    if [ $((_lw_now - ${P_LXC_TRIG:-0})) -lt "$PROBE_COOLDOWN" ]; then
        P_ACTION="lxc-cooldown"
        plog "【lxc 文件】持续缺失：$_lw_out，冷却中（剩余 $((PROBE_COOLDOWN - (_lw_now - ${P_LXC_TRIG:-0})))s），暂不装回"
        return 0
    fi
    P_LXC_TRIG="$_lw_now"
    P_LXC_BAD=0
    P_ACTION="lxc-repair"
    plog "【lxc 文件】连续 $PROBE_STALL_ROUNDS 轮缺失（$_lw_out），交 pkg-restore.sh --lxc 包级装回"
    sh "$_LXC_RESTORE" --lxc >>"$BOOT_LOG" 2>&1
    # 复判不看 --lxc 的退出码：它逐包跑，任一包失败整体非 0，但缺的那个可能已经补回；
    # 反过来也可能整体 0 而某个包被跳过。唯一可信的是再判一次文件。
    if _lw_out2="$(sh "$_LXC_FILES" --lxc-files 2>&1)" && [ -z "$_lw_out2" ]; then
        P_LXC_BAD=0
        P_LXC_FIX=0
        P_ACTION="lxc-fixed"
        plog "【lxc 文件】已按包内清单补回（包管理器记账同步，未做文件级覆盖）"
        return 0
    fi
    P_LXC_FIX=$((${P_LXC_FIX:-0} + 1))
    if [ "$P_LXC_FIX" -ge "$PROBE_FAIL_ALERT" ]; then
        P_ACTION="lxc-need-human"
        P_HUMAN_LXC=1
        plog "【lxc 文件】【需人工介入】连续 $P_LXC_FIX 次补不回（仍缺：$_lw_out2）。多为只读基底的包库里没有该包，或 apk fix 写不进运行侧。已停止自动装回"
    else
        P_ACTION="lxc-fix-fail"
        plog "【lxc 文件】装回失败（仍缺：$_lw_out2，连续第 $P_LXC_FIX/${PROBE_FAIL_ALERT} 次，日志见 $BOOT_LOG）"
    fi
    return 0
}

# ---- 可测化的一轮处理：判定 + 动作 ----
# 全局状态（测试可直接预设/断言）：
#   P_STALL 连续停滞轮数 / P_LAST_TRIG 上次触发时刻 / P_FAIL 连续修复失败次数
#   P_UP_BAD 连续「DNS 不正常」轮数 / P_UP_TRIG 上次写回时刻 / P_UP_FIX 连续写回失败次数 / P_HUMAN_UP 停手锁存
#   P_APP_BAD 连续主程序缺失轮数 / P_APP_TRIG 上次装回时刻 / P_APP_FIX 连续装回失败次数
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
    # 【v.180.198】bouncer 下发面：与体检同频（每 PROBE_HEAL_EVERY 轮）。
    # 具体判据在 bootstrap 的 --bouncer-heal 里：数 bouncer 日志中本轮进程
    # （最后一次 Starting 之后）出现几次 netlink 错误（不限子类）—— 脱节时 last_pull
    # 照样新鲜，60 秒那套守护判定永远看不见它。动作只有一次重启，不写任何配置。
    # 是否真的动手还受 bootstrap 内的存活时间冷却约束（默认 1 小时 1 次）：
    # 刚重启过的进程即便数到错误也只记日志、不重复重启。
    if [ "${PROBE_HEAL_EVERY:-10}" -gt 0 ] 2>/dev/null \
       && [ $((P_ROUND % PROBE_HEAL_EVERY)) -eq 0 ]; then
        _bh_rc=0
        _boot --bouncer-heal >>"$BOOT_LOG" 2>&1 || _bh_rc=$?
        if [ "$_bh_rc" = "1" ]; then
            plog "【bouncer 下发】本轮进程 netlink 错误达阈值，已重启 crowdsec-firewall-bouncer（详见 $BOOT_LOG）"
        elif [ "$_bh_rc" != "0" ]; then
            plog "【bouncer 下发】检查异常退出 $_bh_rc（124=超时；详见 $BOOT_LOG）"
        fi
    fi
    # 【v.180.117】DNS 体检必须排在 last_pull 判定之前：后者在「链路正常」时直接
    # return 0，放在它后面等于永远不执行 —— 而上游被删光恰恰是「链路照样正常」的情形。
    _up_watch
    # 应用主程序通道同样必须排在 last_pull 判定之前：应用被删不影响 last_pull，
    # 放在「链路正常就 return 0」后面等于永远不执行 —— v.180.117 在 DNS 上踩过这一脚。
    _apps_watch
    # 应用依赖的内核模块同理：/lib/modules 里的 .ko 被删不影响 last_pull，
    # 排在「链路正常就 return 0」后面等于永远不执行。
    _kmods_watch
    # 【v.180.189】lxc 二进制的文件级判据，同样必须在此之前：
    # 删掉 /usr/bin/lxc-snapshot 不影响 last_pull，排在后面等于永远不执行。
    _lxc_watch
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
    PKG_CACHE_RO_P="${PKG_CACHE_RO:-$ROMDIR/root/pkg-cache}"
    PKG_CACHE_P="${PKG_CACHE:-/root/pkg-cache}"
    # opkg 的 file:// 源只认 Packages.gz：给裸 Packages 一律 update 失败
    # （copy_file: .../Packages.gz: No such file or directory）。判据必须一致，
    # 否则会把「有 Packages 但 opkg 读不了」的目录当成可用源，报「一切正常」。
    PKG_IDX="Packages.gz"
    PKG_EXT="ipk"
    # CS_PROBE_PKG_CONF 只给夹具用：生产环境为空，读的仍是 /etc/opkg/customfeeds.conf
    PKG_CF="${CS_PROBE_PKG_CONF:-/etc/opkg/customfeeds.conf}"
PKG_STATE="${CS_PROBE_PKG_STATE:-/tmp/crowdsec-probe.pkgcache}"
# 【v.180.133】包库修复拆成独立脚本：fix 按 resolve→挂源→铺索引 的顺序修，
# 探针只负责「发现坏就叫一次修」。脚本不存在时退化为旧行为（只报告不修）。
# 【v.180.165】判定不外包了：原 PKG_CHECK_BIN 指向 pkg-cache-check.sh，但探针从
# v.180.133 起就把判定写在下面的 _pkgcache_probe 里 —— 那份 check 脚本看不见
# 「死源」和「0 个包」这两种坏法，于是内联重写了一份，旧脚本没删。结果是：
# 文件从上线起没被任何代码调用过，却被 guard 逐字节保护、被构建补执行位，
# 而且它与内联版判据还不一样（各有一项对方没有的检查）。
# 已随本版删除该脚本，判定只留 _pkgcache_probe 一处，不再有两份判据各改一边。
PKG_FIX_BIN="${CS_PROBE_PKG_FIX:-/usr/sbin/pkg-cache-fix.sh}"

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
                    # 【v.180.165】apk 的 ndx 写法指向的是索引**文件**，不是目录：
                    #   ndx file:///rom/root/apk-cache/packages.adb
                    # 直接拿整段做 [ -d ] 必然失败。而 fix 那边的判据是 pcl_feed_ok
                    # （只看源行对不对），当场返回 0 —— 于是 25.12 上每秒一轮的
                    # 「存在死源 → 修复完成」成了每分钟的固定节目，纯噪音。
                    # 末段正好是索引文件名时，退到上一级目录再判。
                    case "$_pk_t" in
                    */"$PKG_IDX") _pk_t=${_pk_t%/"$PKG_IDX"} ;;
                    esac
                    if [ -n "$_pk_t" ] && [ ! -d "$_pk_t" ]; then
                        _pk_msg="$(basename "$PKG_CF") 存在死源 file://$_pk_t（目录不存在），包管理器取索引会报错"
                        break
                    fi
                    ;;
                esac
            done < "$PKG_CF"
        fi
    fi
    # 【v.180.133】异常不再只报告：叫一次 pkg-cache-fix.sh（幂等）。
    # 节流靠下面那个状态文件 —— 修不好时 _pk_msg 不变，下一轮与 _pk_prev
    # 相同会直接 return，不会每分钟重跑修复、也不会刷日志。
    if [ -n "$_pk_msg" ] && [ -x "$PKG_FIX_BIN" ]; then
        plog "【包源】$_pk_msg；尝试修复（$PKG_FIX_BIN）"
        if "$PKG_FIX_BIN" >/dev/null 2>&1; then
            _pk_msg=""
            rm -f "$PKG_STATE" 2>/dev/null
            plog "【包源】修复完成"
        else
            plog "【包源】修复失败，需人工介入（$PKG_FIX_BIN 返回非 0）"
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
    # 于是「DNS 写回失败 2 次」会把 last_pull 的失败计数改成 2。
    # 所以叫 dnsfix / dnshold，不叫 dns_fail / dns_human。
    # 【v.180.162】应用通道同理：appbad / apptrig / appfix / apphold，
    # 四个都不含旧键字面量（audit_bad= / dnstrig= / dnsfix= / dnshold=）。
    # 【v.180.181】依赖文件通道：kmodbad / kmodtrig / kmodfix / kmodhold。
    # 四组都避开了旧键字面量（human= / fail= / appbad= 等），不会互相取错。
    # 【v.180.189】lxc 文件通道：lxcbad / lxctrig / lxcfix / lxchold。
    # 同样避开 —— lxcbad 不含 "appbad="，lxctrig 不含 "dnstrig="/"kmodtrig="。
    printf 'stall=%s last_trig=%s fail=%s action=%s ts=%s round=%s audit_bad=%s human=%s human_pull=%s upbad=%s upfix=%s uptrig=%s uphold=%s appbad=%s apptrig=%s appfix=%s apphold=%s kmodbad=%s kmodtrig=%s kmodfix=%s kmodhold=%s lxcbad=%s lxctrig=%s lxcfix=%s lxchold=%s\n' \
        "${P_STALL:-0}" "${P_LAST_TRIG:-0}" "${P_FAIL:-0}" "${P_ACTION:-none}" "$(date +%s)" \
        "${P_ROUND:-0}" "${P_AUDIT_BAD:-0}" "${P_HUMAN:-0}" "${P_HUMAN_PULL:-0}" \
        "${P_UP_BAD:-0}" "${P_UP_FIX:-0}" "${P_UP_TRIG:-0}" "${P_HUMAN_UP:-0}" \
        "${P_APP_BAD:-0}" "${P_APP_TRIG:-0}" "${P_APP_FIX:-0}" "${P_HUMAN_APP:-0}" \
        "${P_KMOD_BAD:-0}" "${P_KMOD_TRIG:-0}" "${P_KMOD_FIX:-0}" "${P_HUMAN_KMOD:-0}" \
        "${P_LXC_BAD:-0}" "${P_LXC_TRIG:-0}" "${P_LXC_FIX:-0}" "${P_HUMAN_LXC:-0}" \
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
    # 【v.180.198】DNS 通道的独立计数与锁存。旧状态文件没这几个键 → 保持 0（向后兼容）。
    _v=$(printf '%s\n' "$_pl" | sed -n 's/.*upbad=\([0-9][0-9]*\).*/\1/p')
    [ -n "$_v" ] && P_UP_BAD="$_v"
    _v=$(printf '%s\n' "$_pl" | sed -n 's/.*upfix=\([0-9][0-9]*\).*/\1/p')
    [ -n "$_v" ] && P_UP_FIX="$_v"
    _v=$(printf '%s\n' "$_pl" | sed -n 's/.*uptrig=\([0-9][0-9]*\).*/\1/p')
    [ -n "$_v" ] && P_UP_TRIG="$_v"
    _v=$(printf '%s\n' "$_pl" | sed -n 's/.*uphold=\([0-9][0-9]*\).*/\1/p')
    [ -n "$_v" ] && P_HUMAN_UP="$_v"
    # 【v.180.162】应用通道的独立计数与锁存。旧状态文件没这几个键 → 保持 0（向后兼容）。
    _v=$(printf '%s\n' "$_pl" | sed -n 's/.*appbad=\([0-9][0-9]*\).*/\1/p')
    [ -n "$_v" ] && P_APP_BAD="$_v"
    _v=$(printf '%s\n' "$_pl" | sed -n 's/.*apptrig=\([0-9][0-9]*\).*/\1/p')
    [ -n "$_v" ] && P_APP_TRIG="$_v"
    _v=$(printf '%s\n' "$_pl" | sed -n 's/.*appfix=\([0-9][0-9]*\).*/\1/p')
    [ -n "$_v" ] && P_APP_FIX="$_v"
    _v=$(printf '%s\n' "$_pl" | sed -n 's/.*apphold=\([0-9][0-9]*\).*/\1/p')
    [ -n "$_v" ] && P_HUMAN_APP="$_v"
    # 【v.180.181】依赖文件通道。旧状态文件没这几个键 → 保持 0（向后兼容）。
    _v=$(printf '%s\n' "$_pl" | sed -n 's/.*kmodbad=\([0-9][0-9]*\).*/\1/p')
    [ -n "$_v" ] && P_KMOD_BAD="$_v"
    _v=$(printf '%s\n' "$_pl" | sed -n 's/.*kmodtrig=\([0-9][0-9]*\).*/\1/p')
    [ -n "$_v" ] && P_KMOD_TRIG="$_v"
    _v=$(printf '%s\n' "$_pl" | sed -n 's/.*kmodfix=\([0-9][0-9]*\).*/\1/p')
    [ -n "$_v" ] && P_KMOD_FIX="$_v"
    _v=$(printf '%s\n' "$_pl" | sed -n 's/.*kmodhold=\([0-9][0-9]*\).*/\1/p')
    [ -n "$_v" ] && P_HUMAN_KMOD="$_v"
    # 【v.180.189】lxc 文件通道。旧状态文件没这几个键 → 保持 0（向后兼容）。
    _v=$(printf '%s\n' "$_pl" | sed -n 's/.*lxcbad=\([0-9][0-9]*\).*/\1/p')
    [ -n "$_v" ] && P_LXC_BAD="$_v"
    _v=$(printf '%s\n' "$_pl" | sed -n 's/.*lxctrig=\([0-9][0-9]*\).*/\1/p')
    [ -n "$_v" ] && P_LXC_TRIG="$_v"
    _v=$(printf '%s\n' "$_pl" | sed -n 's/.*lxcfix=\([0-9][0-9]*\).*/\1/p')
    [ -n "$_v" ] && P_LXC_FIX="$_v"
    _v=$(printf '%s\n' "$_pl" | sed -n 's/.*lxchold=\([0-9][0-9]*\).*/\1/p')
    [ -n "$_v" ] && P_HUMAN_LXC="$_v"
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
P_UP_BAD=0
P_UP_FIX=0
P_UP_TRIG=0
P_HUMAN_UP=0
# 【v.180.162】应用主程序通道（daed / ssrp / mosdns / clashoo）
P_APP_BAD=0
P_APP_TRIG=0
P_APP_FIX=0
P_HUMAN_APP=0
# 【v.180.181】应用依赖的文件级通道（18 包 / 72 文件，不含 /etc/config）
P_KMOD_BAD=0
P_KMOD_TRIG=0
P_KMOD_FIX=0
P_HUMAN_KMOD=0
# 【v.180.189】lxc 二进制的文件级通道（34 包 / 23 条关键路径）
P_LXC_BAD=0
P_LXC_TRIG=0
P_LXC_FIX=0
P_HUMAN_LXC=0
_probe_load
while true; do
    P_LOCK_RECLAIMED=0
    _guard_run
    probe_tick
    _probe_save
    _pkgcache_probe
    sleep "$PROBE_INTERVAL"
done
