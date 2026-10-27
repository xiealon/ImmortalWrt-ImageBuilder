#!/bin/sh
# R34【v.180.117】：探针的 smartdns / 53 体检
#
# 补的是「DNS 挂了但探针一无所知」这一类：last_pull 走 IP 直连 LAPI，不查 DNS，
# 所以 53 无应答时停滞判定永远不触发，日志一路 ok。成因大多是有人在 LuCI 里
# 把 smartdns 配置改坏 → restart 失败 → 全家断网 → 只能重启路由器。
#
# 本测试盯三件事：
#   1. 判据只认本地故障（进程 / 53 监听）。上游全挂、外网不通必须算「好」，
#      否则每轮都触发、白撞冷却 —— 重跑引导修不好上游。
#   2. 触发走 _run_fix（与 last_pull 停滞同一套持锁逻辑），计数与锁存独立。
#   3. 状态键命名不能被 _probe_load 的贪婪 sed 串改：dns_fail 含 fail=、
#      dns_human 含 human=，都会把另一条链路的计数顶掉。
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
PR="$REPO/files/usr/sbin/crowdsec-lxc-probe.sh"

R=0
ck() {
    if [ "$2" = "$3" ]; then
        echo "PASS: $1"
    else
        echo "FAIL: $1  got=[$2] want=[$3]"
        R=$((R + 1))
    fi
}
body() {
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\)[[:space:]]*\\{" { inside = 1 }
        inside { print }
        inside && /^}/ { exit }
    ' "$2"
}

echo "== 34.1 函数与调用位置 =="
ck "R34.1a 有 _dns_ok" "$(grep -c '^_dns_ok()' "$PR")" "1"
ck "R34.1b 有 _run_fix" "$(grep -c '^_run_fix()' "$PR")" "1"
ck "R34.1c 有 _dns_watch" "$(grep -c '^_dns_watch()' "$PR")" "1"
ck "R34.1d probe_tick 里调了 _dns_watch" \
   "$(body probe_tick "$PR" | grep -c '^    _dns_watch$')" "1"
# 顺序是这段的关键：last_pull 判定的「链路正常」分支会直接 return 0，
# _dns_watch 若排在它后面就永远不执行 —— 而 DNS 挂掉恰恰是链路照样正常的情形。
_l_dns=$(grep -n '^    _dns_watch$' "$PR" | head -1 | cut -d: -f1)
_l_pc=$(grep -n 'if _boot --probe-check >/dev/null 2>&1; then' "$PR" | head -1 | cut -d: -f1)
ck "R34.1e _dns_watch 排在 last_pull 判定之前" \
   "$([ -n "$_l_dns" ] && [ -n "$_l_pc" ] && [ "$_l_dns" -lt "$_l_pc" ] && echo ok)" "ok"
ck "R34.1f 停滞通道改用 _run_fix（不再各写一份持锁）" \
   "$(body probe_tick "$PR" | grep -c '^    _run_fix$')" "1"
ck "R34.1g probe_tick 里不再有自己的 mkdir LOCK" \
   "$(body probe_tick "$PR" | grep -c 'mkdir "\$LOCK"')" "0"

echo
echo "== 34.2 判据范围：只认本地故障 =="
_dok=$(body _dns_ok "$PR")
ck "R34.2a 判进程（pidof smartdns）" \
   "$(printf '%s' "$_dok" | grep -c 'pidof smartdns')" "1"
ck "R34.2b 判 53 监听（netstat -lnu）" \
   "$(printf '%s' "$_dok" | grep -c 'netstat -lnu')" "1"
# 上游/外网不应该进判据：重跑引导修不好它
ck "R34.2c 不查上游（无 nslookup / server 比对）" \
   "$(printf '%s' "$_dok" | grep -cE 'nslookup|smartdns\.\$|server_group')" "0"
ck "R34.2d 不用 pgrep -x（busybox 下 argv[0] 比对恒空）" \
   "$(printf '%s' "$_dok" | grep -c 'pgrep')" "0"

echo
echo "== 34.3 状态键命名（防贪婪 sed 串改）=="
_sv=$(grep -n 'dnsbad=' "$PR" | head -1 | cut -d: -f1)
ck "R34.3a 落盘含 dnsbad/dnsfix/dnstrig/dnshold" \
   "$(printf '%s' "$(sed -n "${_sv}p" "$PR")" | grep -c 'dnsbad=%s dnsfix=%s dnstrig=%s dnshold=%s')" "1"
ck "R34.3b 落盘没有 dns_fail（含 fail= 会被 .*fail= 偷走）" \
   "$(grep -c 'dns_fail=' "$PR")" "0"
ck "R34.3c 落盘没有 dns_human（含 human= 会被 .*human= 偷走）" \
   "$(grep -c 'dns_human=' "$PR")" "0"
ck "R34.3d 恢复段四个键都有 sed" \
   "$(body _probe_load "$PR" | grep -cE "sed -n 's/\.\*dns(bad|fix|trig|hold)=")" "4"
# 动态复核：真实的行 + 真实的表达式，确认各取各的
_line='stall=0 last_trig=0 fail=1 action=none ts=0 round=0 audit_bad=0 human=0 human_pull=0 dnsbad=0 dnsfix=9 dnstrig=0 dnshold=0'
ck "R34.3e .*fail= 取到 1 而不是 dnsfix 的 9" \
   "$(printf '%s\n' "$_line" | sed -n 's/.*fail=\([0-9][0-9]*\).*/\1/p')" "1"
ck "R34.3f .*human= 取到 0 而不是别的" \
   "$(printf '%s\n' "$_line" | sed -n 's/.*human=\([0-9][0-9]*\).*/\1/p')" "0"
ck "R34.3g .*dnsfix= 取到 9" \
   "$(printf '%s\n' "$_line" | sed -n 's/.*dnsfix=\([0-9][0-9]*\).*/\1/p')" "9"

echo
echo "== 34.4 动态：_dns_ok 判据 =="
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/dns.XXXXXX") || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMPD"' EXIT

LIB="$TMPD/fns.sh"
: > "$LIB"
for _f in _ensure_boot _dns_ok _run_fix _dns_watch; do
    body "$_f" "$PR" >> "$LIB"
done
[ -s "$LIB" ] || { echo "FAIL: 抽不到函数"; exit 1; }

# 桩：进程与 53 各有独立标记文件；_boot 记录调用并把「修复」写进标记
pidof() { [ -f "$TMPD/pid" ] || return 1; echo 1234; }
netstat() {
    [ -f "$TMPD/listen" ] && printf 'udp        0      0 0.0.0.0:53              0.0.0.0:*\n'
    return 0
}
date() { echo "${FAKE_NOW:-1700000000}"; return 0; }

# _run_fix 现在开头会调 _ensure_boot，这里给一个真实可执行的假 bootstrap，
# 否则每条通道都会以 78（boot-missing）提前返回，测不到后面的逻辑。
BOOT="$TMPD/boot.sh"
printf '#!/bin/sh\nexit 0\n' > "$BOOT"
chmod 755 "$BOOT"
ROMDIR="$TMPD/rom"
mkdir -p "$ROMDIR"
BOOT_SRC=""
BOOT_LOG="$TMPD/boot.log"
LOCK="$TMPD/lock"
STATE_FILE="$TMPD/state"
PROBE_STALL_ROUNDS=3
PROBE_COOLDOWN=600
PROBE_FAIL_ALERT=5
PROBE_FIX_MAX=900
BOOT_FIXES=0
export BOOT_FIXES
log_out="$TMPD/out.log"
: > "$log_out"

plog() { printf '%s\n' "$*" >> "$log_out"; }
_boot() {
    echo x >> "$TMPD/boot_calls"
    [ "${BOOT_FIXES:-0}" = "1" ] && : > "$TMPD/pid" && : > "$TMPD/listen"
    return 0
}
. "$LIB"

P_DNS_BAD=0; P_DNS_FIX=0; P_DNS_TRIG=0; P_HUMAN_DNS=0; P_ACTION=""

# 进程在 + 53 在听 = 好（哪怕上游全挂，这也不该触发）
: > "$TMPD/pid"; : > "$TMPD/listen"
_dns_ok; ck "R34.4a 进程+53 都在 -> 判好(0)" "$?" "0"
rm -f "$TMPD/pid"
_dns_ok; ck "R34.4b 进程不在 -> 判坏(1)" "$?" "1"
ck "R34.4c 原因点明是进程" "$DNS_WHY" "进程不在"
: > "$TMPD/pid"; rm -f "$TMPD/listen"
_dns_ok; ck "R34.4d 进程在但 53 没听 -> 判坏(1)" "$?" "1"
ck "R34.4e 原因点明是 53" "$DNS_WHY" "53 未监听（UDP）"

echo
echo "== 34.5 动态：计数 / 触发 / 冷却 / 锁存 =="
rm -f "$TMPD/boot_calls"
: > "$TMPD/pid"; : > "$TMPD/listen"      # 先正常
_dns_watch
ck "R34.5a 正常时不动作" "$P_ACTION" ""
ck "R34.5b 正常时计数为 0" "$P_DNS_BAD" "0"
ck "R34.5c 正常时不跑引导" "$([ -f "$TMPD/boot_calls" ] && wc -l < "$TMPD/boot_calls" || echo 0)" "0"

rm -f "$TMPD/pid"                         # 坏掉
_dns_watch
ck "R34.5d 第 1 轮只告警" "$P_ACTION" "dns-warn"
ck "R34.5e 第 1 轮不跑引导" "$([ -f "$TMPD/boot_calls" ] && wc -l < "$TMPD/boot_calls" || echo 0)" "0"
_dns_watch
ck "R34.5f 第 2 轮仍只告警" "$P_ACTION" "dns-warn"
_dns_watch
# 触发与复验在同一次调用里跑完（_dns_watch 同步等 bootstrap 结束），
# 所以外面能看到的最终标签是「修复失败」；中间态 dns-trigger 抓不到。
ck "R34.5g 第 3 轮触发（同步复验，最终态为修复失败）" "$P_ACTION" "dns-fix-fail"
ck "R34.5h 触发后计数清零" "$P_DNS_BAD" "0"
ck "R34.5i 引导真跑了一次" "$(wc -l < "$TMPD/boot_calls")" "1"
ck "R34.5j 没修好 -> 记失败 1 次" "$P_DNS_FIX" "1"
ck "R34.5k 失败日志写明第几次/阈值" \
   "$(grep -c '连续第 1/5 次' "$log_out")" "1"

# 冷却：再攒 3 轮也不该再跑引导
FAKE_NOW=1700000100
_dns_watch; _dns_watch; _dns_watch
ck "R34.5l 冷却期内不触发" "$P_ACTION" "dns-cooldown"
ck "R34.5m 冷却期内引导没再跑" "$(wc -l < "$TMPD/boot_calls")" "1"

# 冷却过后 + 引导能修好
rm -f "$TMPD/boot_calls"
FAKE_NOW=1700001000
BOOT_FIXES=1
_dns_watch; _dns_watch; _dns_watch
ck "R34.5n 冷却过后再次触发" "$P_ACTION" "dns-trigger"
ck "R34.5o 引导又跑了一次" "$(wc -l < "$TMPD/boot_calls")" "1"
ck "R34.5p 现场已恢复 -> 失败计数清零" "$P_DNS_FIX" "0"

# 连续失败达阈值 -> 锁存停手
BOOT_FIXES=0
rm -f "$TMPD/pid"
P_DNS_FIX=4
FAKE_NOW=1700002000
_dns_watch; _dns_watch; _dns_watch
ck "R34.5q 连续第 5 次失败 -> 需人工介入" "$P_ACTION" "dns-need-human"
ck "R34.5r 锁存位已置" "$P_HUMAN_DNS" "1"
FAKE_NOW=1700009000
_dns_watch
ck "R34.5s 锁存后不再重跑（即使冷却已过）" "$P_ACTION" "dns-need-human-hold"

# 锁存不等于永久：DNS 自己好了要解除
: > "$TMPD/pid"; : > "$TMPD/listen"
_dns_watch
ck "R34.5t DNS 恢复后计数清零" "$P_DNS_BAD" "0"

echo
echo "== 34.6 日志可读性 =="
ck "R34.6a 有【DNS】专用标签" \
   "$(grep -c 'plog "【DNS】' "$PR")" "9"
ck "R34.6b 告警带上第几轮" \
   "$(grep -c '第 \$P_DNS_BAD/\$PROBE_STALL_ROUNDS 轮' "$PR")" "1"
ck "R34.6c 需人工介入那句点了排查方向" \
   "$(grep -c '再看 /etc/config/smartdns 是否被手工改坏' "$PR")" "1"

echo
if [ "$R" -eq 0 ]; then
    echo "全部通过"
else
    echo "失败 $R 项"
fi
exit $((R > 0))
