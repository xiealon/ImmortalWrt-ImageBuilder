#!/bin/sh
# R34【重写于 v.180.198】：探针的 smartdns 上游条数体检
#
# v.180.198（用户 2026-10-31 定）把 v.180.191 那版「53 体检」整段撤掉，本文件随之重写。
# 被删掉的东西：
#   1. _dns_ok —— pidof + /proc/net/udp + socket inode 反查 53 归属；
#   2. _dns_watch 的三种 DNS_WHY 原因与 dns-* 动作标签；
#   3. _sd_run 里「sleep 等它起来 + 现场复验」这两步。
# 换成的判据只有一句可读的话：uci 里还剩几条 server 段，一条都没有就写回 13 条。
#
# 本版盯六件事：
#   A. 判据只数 uci 上游段，不碰 53、不碰进程、不碰 /proc；
#   B. 修复只交给 pkg-restore-smartdns.sh --config，探针不补文件、不动 uci；
#      「服务是否生效」交脚本的 --check 判，探针不重复实现 pidof / 53 反查；
#   C. 触发链上不许出现 bootstrap（与 last_pull 那条链彻底分开）；
#   D. 四道闸：1-2 轮告警 → 第 3 轮动作 → 冷却 → 连续失败锁存；
#   E. 状态键不被 _probe_load 的贪婪 sed 串改；
#   F. 没装 smartdns 也交脚本（--config 内部会从 /rom 装回），不许探针自己放行。
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
FILES_DIR="${CS_FILES_DIR:-files}"
PR="$REPO/$FILES_DIR/usr/sbin/crowdsec-lxc-probe.sh"

R=0
ck() {
    if [ "$2" = "$3" ]; then
        echo "PASS: $1"
    else
        echo "FAIL: $1  got=[$2] want=[$3]"
        R=$((R + 1))
    fi
}
yn() { awk -v v="$1" 'BEGIN{ if (v > 0) print "yes"; else print "no" }'; }
body() {
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\)[[:space:]]*\\{" { inside = 1 }
        inside { print }
        inside && /^}/ { exit }
    ' "$2"
}
# 去掉注释行之后的函数体：注释里提到某个名字不算调用
code() { body "$1" "$PR" | grep -v '^[[:space:]]*#'; }

echo "== 34.1 函数与调用位置 =="
ck "R34.1a 有 _up_n" "$(grep -c '^_up_n()' "$PR")" "1"
ck "R34.1b 有 _up_run" "$(grep -c '^_up_run()' "$PR")" "1"
ck "R34.1c 有 _up_watch" "$(grep -c '^_up_watch()' "$PR")" "1"
ck "R34.1g 有 _up_svc" "$(grep -c '^_up_svc()' "$PR")" "1"
ck "R34.1d 旧函数已删净（_dns_ok/_dns_watch/_sd_run）" \
   "$(grep -cE '^_(dns_ok|dns_watch|sd_run)\\(\\)' "$PR")" "0"
ck "R34.1e probe_tick 里调了 _up_watch" \
   "$(body probe_tick "$PR" | grep -c '^    _up_watch$')" "1"
_l_up=$(grep -n '^    _up_watch$' "$PR" | head -1 | cut -d: -f1)
_l_pc=$(grep -n 'if _boot --probe-check >/dev/null 2>&1; then' "$PR" | head -1 | cut -d: -f1)
# last_pull 判定在「链路正常」时直接 return 0，_up_watch 排在它后面等于永远不执行
# —— 而上游被删光恰恰是链路照样正常的情形。
ck "R34.1f _up_watch 排在 last_pull 判定之前" \
   "$([ -n "$_l_up" ] && [ -n "$_l_pc" ] && [ "$_l_up" -lt "$_l_pc" ] && echo ok)" "ok"
echo
echo "== 34.2 判据：只数 uci 里的上游段 =="
_un=$(code _up_n)
ck "R34.2a 读 uci 的 smartdns 配置" \
   "$(printf '%s' "$_un" | grep -c 'uci -q show smartdns')" "1"
ck "R34.2b 数的是 server 段（带行尾锚点）" \
   "$(printf '%s' "$_un" | grep -cF "grep -c '=server\$'")" "1"
ck "R34.2c 不判进程" \
   "$(printf '%s' "$_un" | grep -c 'pidof')" "0"
ck "R34.2d 不判 53（无 netstat / /proc/net/udp / 0035）" \
   "$(printf '%s' "$_un" | grep -cE 'netstat|/proc/net/udp|0035')" "0"
ck "R34.2e 不按 socket inode 反查归属" \
   "$(printf '%s' "$_un" | grep -c 'socket:\[')" "0"
# 上游连通性从来不在判据里：脚本修不好它，只会白撞冷却
ck "R34.2f 全文件无 nslookup" \
   "$(grep -c 'nslookup' "$PR")" "0"
# 服务判据不在探针里重写一遍：转调脚本的 --check（内部 _sd_serve）
ck "R34.2g 服务判据交脚本 --check" \
   "$(code _up_svc | grep -c '\-\-check')" "1"
ck "R34.2h _up_svc 不自己 pidof / 读 /proc" \
   "$(code _up_svc | grep -cE 'pidof|/proc/')" "0"

echo
echo "== 34.3 修复只交脚本；链上不许有 bootstrap =="
_ur=$(code _up_run)
ck "R34.3a 脚本不在位就不动（-x 检查）" \
   "$(printf '%s' "$_ur" | grep -c '\[ -x ')" "1"
ck "R34.3b 脚本路径来自 _SD_RESTORE" \
   "$(printf '%s' "$_ur" | grep -c '_SD_RESTORE')" "2"
ck "R34.3c 脚本输出转 syslog 且标签与探针分开" \
   "$(printf '%s' "$_ur" | grep -c 'logger -t crowdsec-probe-sd')" "1"
ck "R34.3d 不再现场复验（函数体里没有 _up_n）" \
   "$(printf '%s' "$_ur" | grep -c '_up_n')" "0"
ck "R34.3e 不再 sleep 等服务" \
   "$(printf '%s' "$_ur" | grep -c 'sleep')" "0"
_uw=$(code _up_watch)
ck "R34.3f 交 --config" "$(printf '%s' "$_uw" | grep -c '_up_run --config')" "1"
ck "R34.3m 判据两条都在（_up_svc + _up_n）" \
   "$(printf '%s' "$_uw" | grep -c '_up_svc')|$(printf '%s' "$_uw" | grep -c '_up_n')" "1|1"
ck "R34.3g 不调 _run_fix" "$(printf '%s' "$_uw" | grep -c '_run_fix')" "0"
ck "R34.3h 不跑 bootstrap" "$(printf '%s' "$_uw" | grep -c '_boot')" "0"
ck "R34.3i 不自己补文件" \
   "$(printf '%s' "$_uw" | grep -cE '^[[:space:]]*(cp|mv|mkdir|install|touch) ')" "0"
ck "R34.3j 不自己动 uci（日志文案不算）" \
   "$(printf '%s' "$_uw" | grep -cE '^[[:space:]]*uci ')" "0"
ck "R34.3k 失败计数用 PROBE_FAIL_ALERT" \
   "$(printf '%s' "$_uw" | grep -c 'PROBE_FAIL_ALERT')" "2"
ck "R34.3l 不自己判二进制就放行（装包交脚本）" \
   "$(printf '%s' "$_uw" | grep -c '/usr/sbin/smartdns')" "0"
echo
echo "== 34.4 动态：四道闸 =="
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/up.XXXXXX") || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMPD"' EXIT

LIB="$TMPD/fns.sh"
: > "$LIB"
# _up_watch 里已经没有「二进制不在就放行」的前置分支（v.180.198 删掉了），
# 原样抽出来即可，不再需要 sed 把路径换成开关。
body _up_watch "$PR" >> "$LIB"
body _probe_load "$PR" >> "$LIB"
[ -s "$LIB" ] || { echo "FAIL: 抽不到函数"; exit 1; }

STATE_FILE="$TMPD/state"
PROBE_STALL_ROUNDS=3
PROBE_COOLDOWN=600
PROBE_FAIL_ALERT=3
log_out="$TMPD/out.log"
: > "$log_out"
: > "$TMPD/boot_calls"

# 上游条数由 UPSRV 控制；--config 成败由 REPAIR_RC 控制；bootstrap 只打点
plog() { printf '%s\n' "$*" >> "$log_out"; }
_up_n() { printf '%s\n' "${UPSRV:-0}"; }
_up_svc() { [ "${SVC_RC:-0}" = "0" ] && return 0; return 1; }
_up_run() { [ "${REPAIR_RC:-1}" = "0" ] && return 0; return 1; }
_boot() { echo x >> "$TMPD/boot_calls"; return 0; }
. "$LIB"

P_UP_BAD=0; P_UP_FIX=0; P_UP_TRIG=0; P_HUMAN_UP=0; P_ACTION=""

UPSRV=13
_up_watch
ck "R34.4a 上游在时不动作" "$P_ACTION" ""
ck "R34.4b 上游在时计数 0" "$P_UP_BAD" "0"

# 上游配着、但 53 没被 smartdns 接管 —— 服务判据要能单独抓住这种
SVC_RC=1
_up_watch
ck "R34.4b1 服务没生效也算坏" "$P_ACTION" "up-warn"
ck "R34.4b2 原因指向 53" "$(grep -c '53 未由 smartdns 接管' "$log_out")" "1"
SVC_RC=0
P_UP_BAD=0; P_UP_FIX=0; P_ACTION=""

UPSRV=0
_up_watch
ck "R34.4c 第 1 轮只告警" "$P_ACTION" "up-warn"
ck "R34.4d 第 1 轮不跑修复" "$(wc -l < "$TMPD/boot_calls")" "0"
ck "R34.4e 第 1 轮失败计数仍 0" "$P_UP_FIX" "0"
_up_watch
ck "R34.4f 第 2 轮仍只告警" "$P_ACTION" "up-warn"

REPAIR_RC=1
_up_watch
ck "R34.4g 第 3 轮触发，脚本没修好 -> 记失败" "$P_ACTION" "up-fix-fail"
ck "R34.4h 触发后轮数清零" "$P_UP_BAD" "0"
ck "R34.4i 失败计数 1" "$P_UP_FIX" "1"
ck "R34.4j 全程没跑 bootstrap" "$(wc -l < "$TMPD/boot_calls")" "0"

P_UP_TRIG=$(date +%s)
_up_watch; _up_watch; _up_watch
ck "R34.4k 冷却期内不触发" "$P_ACTION" "up-cooldown"
ck "R34.4l 冷却期内失败计数不变" "$P_UP_FIX" "1"
ck "R34.4m 冷却期内也没跑 bootstrap" "$(wc -l < "$TMPD/boot_calls")" "0"

P_UP_TRIG=$(( $(date +%s) - 700 ))
REPAIR_RC=0
_up_watch
ck "R34.4n 冷却过后再触发并写回" "$P_ACTION" "up-fixed"
ck "R34.4o 写回后失败计数清零" "$P_UP_FIX" "0"

REPAIR_RC=1
P_UP_FIX=0; P_UP_BAD=0; P_HUMAN_UP=0; P_UP_TRIG=0
n=0
while [ $n -lt 12 ]; do
    P_ACTION=""
    _up_watch
    [ "$P_HUMAN_UP" = "1" ] && break
    P_UP_TRIG=$((P_UP_TRIG - 700))
    n=$((n + 1))
done
ck "R34.4p 连续 3 次失败 -> 需人工介入" "$P_ACTION" "up-need-human"
ck "R34.4q 锁存位已置" "$P_HUMAN_UP" "1"
ck "R34.4r 失败计数正好 3" "$P_UP_FIX" "3"
ck "R34.4s 锁存全程没跑 bootstrap" "$(wc -l < "$TMPD/boot_calls")" "0"

P_ACTION=""
_up_watch
ck "R34.4t 锁存后不再重跑" "$P_ACTION" "up-need-human-hold"

# 锁存不等于永久：上游回来了要解除计数
UPSRV=13
_up_watch
ck "R34.4u 上游恢复后轮数清零" "$P_UP_BAD" "0"
ck "R34.4v 上游恢复后失败计数清零" "$P_UP_FIX" "0"
# 注意：当前实现恢复时不清 P_HUMAN_UP —— 锁存后要人工确认。
# 这里断言的是现状，不是理想行为。
ck "R34.4w 恢复不清锁存位（现状）" "$P_HUMAN_UP" "1"
echo
echo "== 34.5 状态键（防贪婪 sed 串改）=="
_sv=$(grep -n "printf 'stall=%s" "$PR" | head -1 | cut -d: -f1)
ck "R34.5a 落盘含 upbad/upfix/uptrig/uphold" \
   "$(sed -n "${_sv}p" "$PR" | grep -c 'upbad=%s upfix=%s uptrig=%s uphold=%s')" "1"
ck "R34.5b 没有 up_fail（含 fail= 会被 .*fail= 偷走）" \
   "$(grep -c 'up_fail=' "$PR")" "0"
ck "R34.5c 没有 up_human（含 human= 会被 .*human= 偷走）" \
   "$(grep -c 'up_human=' "$PR")" "0"
ck "R34.5d 恢复段四个键都有 sed" \
   "$(body _probe_load "$PR" | grep -cE "sed -n 's/\.\*up(bad|fix|trig|hold)=")" "4"

# 真实回环：写一份完整状态行，载入后四个值各归各位，且不串到别的通道
printf 'stall=0 last_trig=0 fail=1 action=none ts=0 round=0 audit_bad=0 human=0 human_pull=0 upbad=7 upfix=9 uptrig=1700000000 uphold=1 appbad=0 apptrig=0 appfix=0 apphold=0 kmodbad=0 kmodtrig=0 kmodfix=0 kmodhold=0 lxcbad=0 lxctrig=0 lxcfix=0 lxchold=0\n' > "$STATE_FILE"
P_STALL=0; P_FAIL=0; P_HUMAN=0; P_LAST_TRIG=0; P_ROUND=0; P_AUDIT_BAD=0; P_HUMAN_PULL=0
P_UP_BAD=0; P_UP_FIX=0; P_UP_TRIG=0; P_HUMAN_UP=0
P_APP_BAD=0; P_KMOD_BAD=0; P_LXC_BAD=0
_probe_load
ck "R34.5e 载入 upbad" "$P_UP_BAD" "7"
ck "R34.5f 载入 upfix" "$P_UP_FIX" "9"
ck "R34.5g 载入 uptrig" "$P_UP_TRIG" "1700000000"
ck "R34.5h 载入 uphold" "$P_HUMAN_UP" "1"
ck "R34.5i .*fail= 取到 1 而不是 upfix 的 9" "$P_FAIL" "1"
ck "R34.5j .*human= 没被 uphold 串改" "$P_HUMAN" "0"
ck "R34.5k appbad 没被串改" "$P_APP_BAD" "0"
ck "R34.5l lxcbad 没被串改" "$P_LXC_BAD" "0"

echo
echo "== 34.6 文案 =="
_log=$(cat "$log_out")
ck "R34.6a 有【DNS】专用标签" "$(yn "$(printf '%s' "$_log" | grep -c '【DNS】')")" "yes"
ck "R34.6b 不再有【上游】标签" "$(printf '%s' "$_log" | grep -c '【上游】')" "0"
ck "R34.6c 告警带上第几轮" "$(yn "$(grep -cF '第 $P_UP_BAD/$PROBE_STALL_ROUNDS 轮' "$PR")")" "yes"
ck "R34.6d 需人工介入点了排查方向" \
   "$(yn "$(grep -c '/etc/config/smartdns' "$PR")")" "yes"
ck "R34.6e 写回时留了一条" "$(yn "$(printf '%s' "$_log" | grep -c '已写回')")" "yes"

echo
if [ "$R" -eq 0 ]; then
    echo "全部通过"
else
    echo "失败 $R 项"
fi
exit $((R > 0))
