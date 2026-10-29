#!/bin/sh
# R34【重写于 v.180.191】：探针的 smartdns / 53 体检
#
# 这是按当前实现重写的版本，替换掉 v.180.117 时代那一份。旧版三条断言现在都不成立：
#   1. 断言 _dns_ok 用 netstat -lnu 判 53 —— v.180.186 已改成 socket inode 反查归属；
#   2. 断言 _dns_watch 在 --repair 失败后跑 _run_fix —— v.180.191 已把这一级删掉；
#   3. mock 的是 pidof / netstat 两个桩 —— 现在的判据读 /proc，桩不到点子上。
#
# 本版盯五件事：
#   A. 判据只认本地故障，且判的是「53 到底归不归 smartdns」；
#   B. 修复只交给 pkg-restore-smartdns.sh，探针不补文件、不动 uci；
#   C. 触发链上不许出现 bootstrap（v.180.191：与它彻底分开）；
#   D. 四道闸：1-2 轮告警 → 第 3 轮动作 → 冷却 → 连续失败锁存；
#   E. 状态键不被 _probe_load 的贪婪 sed 串改。
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
FILES_DIR="${CS_FILES_DIR:-files-24}"
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
ck "R34.1a 有 _dns_ok" "$(grep -c '^_dns_ok()' "$PR")" "1"
ck "R34.1b 有 _dns_watch" "$(grep -c '^_dns_watch()' "$PR")" "1"
ck "R34.1c 有 _sd_run" "$(grep -c '^_sd_run()' "$PR")" "1"
ck "R34.1d probe_tick 里调了 _dns_watch" \
   "$(body probe_tick "$PR" | grep -c '^    _dns_watch$')" "1"
_l_dns=$(grep -n '^    _dns_watch$' "$PR" | head -1 | cut -d: -f1)
_l_pc=$(grep -n 'if _boot --probe-check >/dev/null 2>&1; then' "$PR" | head -1 | cut -d: -f1)
# last_pull 判定在「链路正常」时直接 return 0，_dns_watch 排在它后面等于永远不执行
# —— 而 DNS 挂掉恰恰是链路照样正常的情形。
ck "R34.1e _dns_watch 排在 last_pull 判定之前" \
   "$([ -n "$_l_dns" ] && [ -n "$_l_pc" ] && [ "$_l_dns" -lt "$_l_pc" ] && echo ok)" "ok"

echo
echo "== 34.2 判据：只认本地故障，且判 53 归属（v.180.186）=="
_dok=$(code _dns_ok)
ck "R34.2a 判进程（pidof smartdns）" \
   "$(printf '%s' "$_dok" | grep -c 'pidof smartdns')" "1"
ck "R34.2b 读 /proc/net/udp 判端口" \
   "$(printf '%s' "$_dok" | grep -c '/proc/net/udp')" "1"
ck "R34.2c 端口 53 写成十六进制 0035" \
   "$(printf '%s' "$_dok" | grep -c '0035')" "1"
ck "R34.2d 按 socket inode 反查 fd 归属" \
   "$(printf '%s' "$_dok" | grep -c 'socket:\[')" "1"
# netstat 的 :53 与 pidof 各说各的，两个都满足也可能不是同一个进程 —— 不能再用
ck "R34.2e 不再用 netstat 判端口" \
   "$(printf '%s' "$_dok" | grep -c 'netstat')" "0"
ck "R34.2f 不再用 pgrep -x（busybox 下 argv[0] 比对恒空）" \
   "$(printf '%s' "$_dok" | grep -c 'pgrep')" "0"
ck "R34.2g 三种原因各写一次 DNS_WHY" \
   "$(printf '%s' "$_dok" | grep -cE 'DNS_WHY="[^"]')" "3"
ck "R34.2h 原因：进程不在" \
   "$(printf '%s' "$_dok" | grep -c 'DNS_WHY="进程不在"')" "1"
ck "R34.2i 原因：53 未监听" \
   "$(printf '%s' "$_dok" | grep -c 'DNS_WHY="53 未监听（UDP）"')" "1"
ck "R34.2j 原因：53 被别人占着" \
   "$(printf '%s' "$_dok" | grep -c '53 被别的进程占着')" "1"
# 上游/外网不进判据：重跑修复脚本修不好它，只会白撞冷却
ck "R34.2k 不查上游（无 nslookup / server 比对）" \
   "$(printf '%s' "$_dok" | grep -cE 'nslookup|server_group')" "0"

echo
echo "== 34.3 修复只交脚本；链上不许有 bootstrap（v.180.191）=="
ck "R34.3a _sd_run 最后一步是现场复验 _dns_ok" \
   "$(code _sd_run | grep -c '_dns_ok')" "1"
ck "R34.3b 复验前先等一会（等服务真起来）" \
   "$(code _sd_run | grep -c 'sleep')" "1"
ck "R34.3c 脚本不在位就不动（可执行检查）" \
   "$(code _sd_run | grep -c '\-x ')" "1"
ck "R34.3d _dns_watch 交 --repair" \
   "$(code _dns_watch | grep -c '_sd_run --repair')" "1"
ck "R34.3e _dns_watch 不调 _run_fix" \
   "$(code _dns_watch | grep -c '_run_fix')" "0"
ck "R34.3f _dns_watch 不直接跑 bootstrap" \
   "$(code _dns_watch | grep -c '_boot')" "0"
ck "R34.3g 探针不自己补规则文件（无 cp/mv/mkdir/touch 动作）" \
   "$(code _dns_watch | grep -cE '^[[:space:]]*(cp|mv|mkdir|install|touch) ')" "0"
ck "R34.3h 探针不自己动 uci" \
   "$(code _dns_watch | grep -c 'uci ')" "0"
ck "R34.3i 失败计数用 PROBE_FAIL_ALERT" \
   "$(code _dns_watch | grep -c 'PROBE_FAIL_ALERT')" "2"

echo
echo "== 34.4 动态：四道闸 =="
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/dns.XXXXXX") || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMPD"' EXIT

LIB="$TMPD/fns.sh"
: > "$LIB"
body _dns_watch "$PR" >> "$LIB"
body _probe_load "$PR" >> "$LIB"
[ -s "$LIB" ] || { echo "FAIL: 抽不到函数"; exit 1; }

STATE_FILE="$TMPD/state"
PROBE_STALL_ROUNDS=3
PROBE_COOLDOWN=600
PROBE_FAIL_ALERT=3
log_out="$TMPD/out.log"
: > "$log_out"
: > "$TMPD/boot_calls"

# 现场由 DNSTATE 控制；--repair 成败由 REPAIR_RC 控制；bootstrap 只打点
plog() { printf '%s\n' "$*" >> "$log_out"; }
_dns_ok() {
    [ "${DNSTATE:-bad}" = "ok" ] && { DNS_WHY=""; return 0; }
    DNS_WHY="模拟：53 未监听"
    return 1
}
_sd_run() { [ "${REPAIR_RC:-1}" = "0" ] && return 0; return 1; }
_boot() { echo x >> "$TMPD/boot_calls"; return 0; }
. "$LIB"

P_DNS_BAD=0; P_DNS_FIX=0; P_DNS_TRIG=0; P_HUMAN_DNS=0; P_ACTION=""

DNSTATE=ok
_dns_watch
ck "R34.4a 正常时不动作" "$P_ACTION" ""
ck "R34.4b 正常时计数 0" "$P_DNS_BAD" "0"

DNSTATE=bad
_dns_watch
ck "R34.4c 第 1 轮只告警" "$P_ACTION" "dns-warn"
ck "R34.4d 第 1 轮不跑修复" "$(wc -l < "$TMPD/boot_calls")" "0"
ck "R34.4e 第 1 轮失败计数仍 0" "$P_DNS_FIX" "0"
_dns_watch
ck "R34.4f 第 2 轮仍只告警" "$P_ACTION" "dns-warn"

REPAIR_RC=1
_dns_watch
ck "R34.4g 第 3 轮触发，脚本没修好 -> 记失败" "$P_ACTION" "dns-fix-fail"
ck "R34.4h 触发后轮数清零" "$P_DNS_BAD" "0"
ck "R34.4i 失败计数 1" "$P_DNS_FIX" "1"
ck "R34.4j 全程没跑 bootstrap" "$(wc -l < "$TMPD/boot_calls")" "0"

P_DNS_TRIG=$(date +%s)
_dns_watch; _dns_watch; _dns_watch
ck "R34.4k 冷却期内不触发" "$P_ACTION" "dns-cooldown"
ck "R34.4l 冷却期内失败计数不变" "$P_DNS_FIX" "1"
ck "R34.4m 冷却期内也没跑 bootstrap" "$(wc -l < "$TMPD/boot_calls")" "0"

P_DNS_TRIG=$(( $(date +%s) - 700 ))
REPAIR_RC=0
_dns_watch
ck "R34.4n 冷却过后再触发并修好" "$P_ACTION" "dns-script-fixed"
ck "R34.4o 修好后失败计数清零" "$P_DNS_FIX" "0"

REPAIR_RC=1
P_DNS_FIX=0; P_DNS_BAD=0; P_HUMAN_DNS=0; P_DNS_TRIG=0
n=0
while [ $n -lt 12 ]; do
    P_ACTION=""
    _dns_watch
    [ "$P_HUMAN_DNS" = "1" ] && break
    P_DNS_TRIG=$((P_DNS_TRIG - 700))
    n=$((n + 1))
done
ck "R34.4p 连续 3 次失败 -> 需人工介入" "$P_ACTION" "dns-need-human"
ck "R34.4q 锁存位已置" "$P_HUMAN_DNS" "1"
ck "R34.4r 失败计数正好 3" "$P_DNS_FIX" "3"
ck "R34.4s 锁存全程没跑 bootstrap" "$(wc -l < "$TMPD/boot_calls")" "0"

P_ACTION=""
_dns_watch
ck "R34.4t 锁存后不再重跑" "$P_ACTION" "dns-need-human-hold"

# 锁存不等于永久：53 自己好了要解除
DNSTATE=ok
_dns_watch
ck "R34.4u DNS 恢复后轮数清零" "$P_DNS_BAD" "0"
ck "R34.4v DNS 恢复后失败计数清零" "$P_DNS_FIX" "0"
# 注意：当前实现恢复时不清 P_HUMAN_DNS —— 与 last_pull 那条链路不一样，
# 锁存后要人工确认。这里断言的是现状，不是理想行为。
ck "R34.4w 恢复不清锁存位（现状）" "$P_HUMAN_DNS" "1"

echo
echo "== 34.5 状态键（防贪婪 sed 串改）=="
_sv=$(grep -n "dnsbad=" "$PR" | head -1 | cut -d: -f1)
ck "R34.5a 落盘含 dnsbad/dnsfix/dnstrig/dnshold" \
   "$(sed -n "${_sv}p" "$PR" | grep -c 'dnsbad=%s dnsfix=%s dnstrig=%s dnshold=%s')" "1"
ck "R34.5b 没有 dns_fail（含 fail= 会被 .*fail= 偷走）" \
   "$(grep -c 'dns_fail=' "$PR")" "0"
ck "R34.5c 没有 dns_human（含 human= 会被 .*human= 偷走）" \
   "$(grep -c 'dns_human=' "$PR")" "0"
ck "R34.5d 恢复段四个键都有 sed" \
   "$(body _probe_load "$PR" | grep -cE "sed -n 's/\.\*dns(bad|fix|trig|hold)=")" "4"

# 真实回环：写一份完整状态行，载入后四个值各归各位，且不串到别的通道
printf 'stall=0 last_trig=0 fail=1 action=none ts=0 round=0 audit_bad=0 human=0 human_pull=0 dnsbad=7 dnsfix=9 dnstrig=1700000000 dnshold=1 appbad=0 apptrig=0 appfix=0 apphold=0 kmodbad=0 kmodtrig=0 kmodfix=0 kmodhold=0 lxcbad=0 lxctrig=0 lxcfix=0 lxchold=0\n' > "$STATE_FILE"
P_STALL=0; P_FAIL=0; P_HUMAN=0
P_DNS_BAD=0; P_DNS_FIX=0; P_DNS_TRIG=0; P_HUMAN_DNS=0
P_APP_BAD=0; P_KMOD_BAD=0; P_LXC_BAD=0
_probe_load
ck "R34.5e 载入 dnsbad" "$P_DNS_BAD" "7"
ck "R34.5f 载入 dnsfix" "$P_DNS_FIX" "9"
ck "R34.5g 载入 dnstrig" "$P_DNS_TRIG" "1700000000"
ck "R34.5h 载入 dnshold" "$P_HUMAN_DNS" "1"
ck "R34.5i .*fail= 取到 1 而不是 dnsfix 的 9" "$P_FAIL" "1"
ck "R34.5j .*human= 没被 dnshold 串改" "$P_HUMAN" "0"
ck "R34.5k appbad 没被串改" "$P_APP_BAD" "0"
ck "R34.5l lxcbad 没被串改" "$P_LXC_BAD" "0"

echo
echo "== 34.6 文案 =="
_log=$(cat "$log_out")
ck "R34.6a 有【DNS】专用标签" "$(yn "$(printf '%s' "$_log" | grep -c '【DNS】')")" "yes"
ck "R34.6b 告警带上第几轮" "$(yn "$(grep -c '第 $P_DNS_BAD/$PROBE_STALL_ROUNDS 轮' "$PR")")" "yes"
ck "R34.6c 需人工介入点了排查方向" \
   "$(yn "$(grep -c '/etc/config/smartdns' "$PR")")" "yes"
ck "R34.6d 修好时留了一条" "$(yn "$(printf '%s' "$_log" | grep -c '脚本修复成功')")" "yes"

echo
if [ "$R" -eq 0 ]; then
    echo "全部通过"
else
    echo "失败 $R 项"
fi
exit $((R > 0))
