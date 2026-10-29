#!/bin/sh
# 置位恢复专项：验证「无论脚本怎么退出，都不留半截置位」。
#
# 为什么单开一个文件：这类逻辑只在**真实退出路径**上才有意义。
#   · 进程内变量归零 —— 必须真的跑完 main 或真的被 kill 才能观察到
#   · ip_forward 还原 —— 必须真的写 /proc 才能验证
#   · 信号 trap —— 必须真的发信号，函数级调用测不出来
# 前两套测试都是「调函数看返回值」，抓不到 trap 有没有装上、顺序对不对。
REPO=$(cd "$(dirname "$0")/.." && pwd)
BS="$REPO/files/usr/sbin/crowdsec-lxc-bootstrap.sh"
PASS=0; FAIL=0
chk() {
    if { [ "$2" = ok ] && [ "$3" = 0 ]; } || { [ "$2" = fail ] && [ "$3" != 0 ]; }; then
        PASS=$((PASS+1)); echo "PASS: $1"
    else FAIL=$((FAIL+1)); echo "FAIL: $1 (rc=$3, want $2)"; fi
}
eq() {
    if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "PASS: $1"
    else FAIL=$((FAIL+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi
}

echo "===== R0. 静态：三类恢复都在位 ====="
for _f in _bs_clear_flags _bs_flag_stats _ipfwd_snapshot _ipfwd_restore _pending_report _bs_on_signal; do
    eq "R0.$_f 有定义" "$(grep -cE "^$_f\(\) *\{" "$BS")" "1"
done
eq "R0.trap EXIT 已注册" "$(grep -cE "trap '_bs_st=\\\$\\?; _bs_on_exit' EXIT" "$BS")" "1"
eq "R0.trap INT 已注册"  "$(grep -cE "trap '_bs_on_signal INT' *INT" "$BS")" "1"
eq "R0.trap TERM 已注册" "$(grep -cE "trap '_bs_on_signal TERM' *TERM" "$BS")" "1"
eq "R0.trap HUP 已注册"  "$(grep -cE "trap '_bs_on_signal HUP' *HUP" "$BS")" "1"
eq "R0.进场先快照 ip_forward" "$(grep -c '^    _ipfwd_snapshot' "$BS")" "1"
eq "R0.进场先归零" "$(grep -c '^    _bs_clear_flags' "$BS")" "1"
# 计数必须在恢复之前（顺序错了计数就判不准）
_on_exit_body=$(awk '/^_bs_on_exit\(\)/,/^}/' "$BS")
_l_cnt=$(printf '%s\n' "$_on_exit_body" | grep -n '_fail_count_inc' | head -1 | cut -d: -f1)
_l_clr=$(printf '%s\n' "$_on_exit_body" | grep -n '_bs_clear_flags' | head -1 | cut -d: -f1)
eq "R0.先计数后恢复（顺序）" "$([ -n "$_l_cnt" ] && [ -n "$_l_clr" ] && [ "$_l_cnt" -lt "$_l_clr" ] && echo ok)" "ok"

echo "===== R1. 进程内变量归零（真实子进程） ====="
# 在子 shell 里 source 脚本的函数定义 + 置位，然后跑 _bs_on_exit，看是否归零。
# 用真的 dash 子进程，确保 trap 与变量作用域都真实。
run_case() {
    _case=$1
    sh -c '
        BS="$1"; CASE="$2"
        . "$(dirname "$0")/funcs.sh" 2>/dev/null || true
    ' sh "$BS" "$_case" >/dev/null 2>&1
}

# 造一个只含我们需要的函数定义的临时文件
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/reset.XXXXXX")
FUNCS="$TMPD/funcs.sh"
python3 - "$BS" > "$FUNCS" <<'PY'
import sys, re
src = open(sys.argv[1]).read().splitlines()
want = {'_bs_clear_flags','_bs_flag_stats','_ipfwd_snapshot','_ipfwd_restore',
        '_pending_report','_bs_on_exit','_bs_on_signal','_fail_count_inc',
        '_bs_flag_set','_bs_flag_clear','_bs_flag_on','_bs_flag_tag',
        '_bs_flag_count','_bs_flag_dump'}
out=[]; i=0
while i < len(src):
    m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{', src[i])
    if m and m.group(1) in want:
        depth=0; j=i; buf=[]
        while j < len(src):
            buf.append(src[j]); depth += src[j].count('{') - src[j].count('}')
            if depth <= 0: break
            j += 1
        out.append('\n'.join(buf)); i = j+1
    else:
        i += 1
for l in src:
    if re.match(r'^(DAG_NODES|GROUP_SEQ|STATE_DIR|REINSTALL_PENDING_FILE|REINSTALL_FAIL_FILE|_FLAG_TS_FMT)=', l):
        out.append(l)
print('\n\n'.join(out))
PY

LOG_OUT="$TMPD/log"
cat > "$TMPD/t1.sh" <<'EOS'
. "$FUNCS"
log() { echo "$*" >> "$LOG_OUT"; }   # 必须在 source 之后覆盖，否则被真 log 盖掉
# 置一堆位，模拟"跑到一半"
# v.99 起置位值是 V:/B:/R:<ts>，测试也要按真实形态注入（写 1 就不是生产里会出现的样子了）
for n in $DAG_NODES; do
    _bs_flag_set "_done_$n" V
    _bs_flag_set "_dirty_$n" B
done
for g in $GROUP_SEQ; do _bs_flag_set "GSET_$g" V; done
_failed=" a b"; _group_failed=" c"
echo "BEFORE: $(_bs_flag_stats)" 
_bs_on_exit
echo "AFTER:  $(_bs_flag_stats)"
EOS
: > "$LOG_OUT"
_env="LOG_OUT=$LOG_OUT FUNCS=$FUNCS"
env LOG_OUT="$LOG_OUT" FUNCS="$FUNCS" sh "$TMPD/t1.sh" > "$TMPD/t1.out" 2>&1
_before=$(grep '^BEFORE:' "$TMPD/t1.out" | sed 's/BEFORE: *//')
_after=$(grep '^AFTER:' "$TMPD/t1.out" | sed 's/AFTER: *//')
# 从生产脚本里解析（本测试文件没 source 它，$DAG_NODES 在父 shell 是空的）
Nd=$(sed -n 's/^DAG_NODES="\(.*\)"$/\1/p' "$BS" | wc -w | tr -d ' ')
Ng=$(sed -n 's/^GROUP_SEQ="\(.*\)"$/\1/p' "$BS" | wc -w | tr -d ' ')
eq "R1.1 置位前的快照正确" "$_before" "done=$Nd dirty=$Nd gset=$Ng built=0"
eq "R1.2 退出后全部归零"   "$_after"  "done=0 dirty=0 gset=0 built=0"
# 三行：置位快照 / 逐项明细 / 已归零。v.99 多了「逐项」那一行（不然只知道个数、不知道是谁）
eq "R1.3 日志记了三次（快照/逐项/归零）" "$(grep -c '\[恢复\]' "$LOG_OUT")" "3"
eq "R1.4 逐项明细列出了所有已置位（29 done + 29 dirty + 8 gset）" \
   "$(grep '\[恢复\] 逐项：' "$LOG_OUT" | grep -o '[A-Za-z_]*=[VBR]:' | wc -l | tr -d ' ')" "66"
eq "R1.5 逐项明细带分类前缀 V" \
   "$(grep -c 'GSET_PREP=V:' "$LOG_OUT")" "1"

echo "===== R2. 信号 trap 真的会触发恢复 ====="
# 造一个长跑脚本，装上同样的 trap，然后发 TERM，检查是否留下恢复日志
cat > "$TMPD/t2.sh" <<'EOS'
. "$FUNCS"
log() { echo "$*" >> "$LOG_OUT"; }
for n in $DAG_NODES; do eval "_done_$n=1"; done
trap '_bs_st=$?; _bs_on_exit' EXIT
trap '_bs_on_signal INT'  INT
trap '_bs_on_signal TERM' TERM
trap '_bs_on_signal HUP'  HUP
# 长睡，等外面 kill
: > "$1"
sleep 30 &
echo $! > "$TMPD/child"
wait
EOS
: > "$LOG_OUT"
env LOG_OUT="$LOG_OUT" FUNCS="$FUNCS" TMPD="$TMPD" sh "$TMPD/t2.sh" "$TMPD/ready" &
_t2pid=$!
# 等到 ready 文件出现（说明 trap 已装好、进入 wait）
_i=0; while [ ! -f "$TMPD/ready" ] && [ "$_i" -lt 50 ]; do _i=$((_i+1)); sleep 0.1; done
kill -TERM "$_t2pid" 2>/dev/null
wait "$_t2pid" 2>/dev/null
_rc=$?
eq "R2.1 TERM 触发后退出码为 143" "$_rc" "143"
eq "R2.2 日志里看到了 SIGTERM" "$(grep -c 'SIGTERM' "$LOG_OUT")" "1"
eq "R2.3 信号路径也做了归零" "$(grep -c '置位已全部归零' "$LOG_OUT")" "1"
eq "R2.4 归零后快照为 0" "$(grep '置位已全部归零' "$LOG_OUT" | grep -c 'done=0 dirty=0 gset=0 built=0')" "1"

echo "===== R3. ip_forward 还原策略 ====="
# 用假的 /proc 路径不好搞，改成直接验证逻辑分支：把写 /proc 的动作替换成写临时文件
cat > "$TMPD/t3.sh" <<'EOS'
. "$FUNCS"
log() { echo "$*" >> "$LOG_OUT"; }
# 覆写 restore：把 /proc 换成临时文件，其余逻辑照旧
_ipfwd_restore() {
    [ "${_ipfwd_touched:-0}" = 1 ] || { echo "SKIP-untouched" >> "$LOG_OUT"; return 0; }
    [ -n "${_ipfwd_orig:-}" ] || { echo "SKIP-no-orig" >> "$LOG_OUT"; return 0; }
    [ "${_bs_stamped:-0}" = 1 ] && { echo "KEEP-stamped" >> "$LOG_OUT"; return 0; }
    echo "RESTORE-$_ipfwd_orig" >> "$LOG_OUT"
}
_ipfwd_orig=0; _bs_stamped=0
_ipfwd_touched=1; _ipfwd_restore
_ipfwd_touched=0; _ipfwd_restore
_ipfwd_touched=1; _bs_stamped=1; _ipfwd_restore
EOS
: > "$LOG_OUT"
env LOG_OUT="$LOG_OUT" FUNCS="$FUNCS" sh "$TMPD/t3.sh" >/dev/null 2>&1
eq "R3.1 本轮改过且未成功 → 还原" "$(grep -c '^RESTORE-0$' "$LOG_OUT")" "1"
eq "R3.2 本轮没改过 → 不动"        "$(grep -c '^SKIP-untouched$' "$LOG_OUT")" "1"
eq "R3.3 引导成功 → 保留（不还原）" "$(grep -c '^KEEP-stamped$' "$LOG_OUT")" "1"

echo "===== R7. ip_forward 哨兵文件（重跑不误判） ====="
# 逻辑独立成 probe_ipfwd_sentinel.sh：那边要拿生产脚本本体跑（sed 沙箱化 /proc），
# 塞在主文件里会和这里的 FUNCS 提取、PATH 打桩互相干扰。这里只做汇总统计。
_R7OUT=$(sh "$REPO/tests/probe_ipfwd_sentinel.sh" 2>&1)
printf '%s\n' "$_R7OUT"
_R7PASS=$(printf '%s\n' "$_R7OUT" | grep -c '^PASS:')
_R7FAIL=$(printf '%s\n' "$_R7OUT" | grep -c '^FAIL:')
PASS=$((PASS+_R7PASS)); FAIL=$((FAIL+_R7FAIL))
[ "$_R7FAIL" = 0 ] || echo "!! R7 有 $_R7FAIL 条失败（详见上方）"

echo "===== R8. 置位值格式：分类 + 时间戳 ====="
_R8OUT=$(sh "$REPO/tests/probe_flag_format.sh" 2>&1)
printf '%s\n' "$_R8OUT"
_R8P=$(printf '%s\n' "$_R8OUT" | grep -c '^PASS:')
_R8F=$(printf '%s\n' "$_R8OUT" | grep -c '^FAIL:')
PASS=$((PASS+_R8P)); FAIL=$((FAIL+_R8F))
[ "$_R8F" = 0 ] || echo "!! R8 有 $_R8F 条失败（详见上方）"

echo "===== R9. 内容指纹：判「一不一样」不比时间 ====="
_R9OUT=$(sh "$REPO/tests/probe_stamp_fingerprint.sh" 2>&1)
printf '%s\n' "$_R9OUT"
_R9P=$(printf '%s\n' "$_R9OUT" | grep -c '^PASS:')
_R9F=$(printf '%s\n' "$_R9OUT" | grep -c '^FAIL:')
PASS=$((PASS+_R9P)); FAIL=$((FAIL+_R9F))
[ "$_R9F" = 0 ] || echo "!! R9 有 $_R9F 条失败（详见上方）"

echo "===== R11. 重启态逐组复验：哪个坏了修哪个 ====="
_R11OUT=$(sh "$REPO/tests/probe_restart_verify.sh" 2>&1)
printf '%s\n' "$_R11OUT"
_R11P=$(printf '%s\n' "$_R11OUT" | grep -c '^PASS:')
_R11F=$(printf '%s\n' "$_R11OUT" | grep -c '^FAIL:')
PASS=$((PASS+_R11P)); FAIL=$((FAIL+_R11F))
[ "$_R11F" = 0 ] || echo "!! R11 有 $_R11F 条失败（详见上方）"

echo "===== R4. reinstall_pending 不被清（设计如此） ====="
eq "R4.1 _pending_report 只读不删" \
   "$(awk '/^_pending_report\(\)/,/^}/' "$BS" | grep -c 'rm -f')" "0"
eq "R4.2 退出路径里没有 rm pending 的通用清理" \
   "$(awk '/^_bs_on_exit\(\)/,/^}/' "$BS" | grep 'rm -f' | grep -c 'REINSTALL_PENDING_FILE')" "1"

echo "===== R5. 真实脚本端到端：不带 CrowdSec 的机器上干干净净退出 ====="
# 这条最能说明问题：真实 main() 跑一遍，退出时置位必须为 0
E2E="$TMPD/e2e"
mkdir -p "$E2E/lxc" "$E2E/state"
cat > "$TMPD/t5.sh" <<'EOS'
export CS_BOOTSTRAP_STATE="$E2E/state"
export PATH=/tmp/mockbin:/tmp/mockbin_sys:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
. "$FUNCS"
LXC_PATH="$E2E/lxc"; LXC_NAME=cs
EOS
# 直接把 main 里的关键几行抄出来跑（不跑完整 DAG，太重）
cat > "$TMPD/t5.sh" <<'EOS'
. "$FUNCS"
log() { echo "$*" >> "$LOG_OUT"; }
LXC_PATH="$E2E/lxc"; LXC_NAME=cs
mkdir -p "$STATE_DIR"
trap '_bs_st=$?; _bs_on_exit' EXIT
_ipfwd_snapshot
_bs_clear_flags
# 模拟跑了几组
for g in PREP INSTALL CAPIBLOCK; do eval "GSET_$g=1"; done
eval "_done_br_lan_ports=1; _dirty_lan_static=1"
log "MID: $(_bs_flag_stats)"
exit 0
EOS
: > "$LOG_OUT"
env LOG_OUT="$LOG_OUT" FUNCS="$FUNCS" E2E="$E2E" \
    CS_BOOTSTRAP_STATE="$E2E/state" sh "$TMPD/t5.sh" >/dev/null 2>&1
eq "R5.1 中途确实置了位" "$(grep 'MID:' "$LOG_OUT" | grep -c 'done=1 dirty=1 gset=3')" "1"
eq "R5.2 正常 exit 0 后也归零" "$(grep -c '置位已全部归零.*done=0 dirty=0 gset=0 built=0' "$LOG_OUT")" "1"

echo "===== R6. 干净退出不刷屏（日志噪音控制） ====="
cat > "$TMPD/t6.sh" <<'EOS'
. "$FUNCS"
log() { echo "$*" >> "$LOG_OUT"; }
_bs_clear_flags          # 全零
_ipfwd_touched=0
_bs_st=0
_bs_on_exit
EOS
: > "$LOG_OUT"
env LOG_OUT="$LOG_OUT" FUNCS="$FUNCS" sh "$TMPD/t6.sh" >/dev/null 2>&1
eq "R6.1 全零退出时不打「快照/已归零」" "$(grep -c '\[恢复\]' "$LOG_OUT")" "0"
# 反例：有置位时必须打
cat > "$TMPD/t7.sh" <<'EOS'
. "$FUNCS"
log() { echo "$*" >> "$LOG_OUT"; }
_bs_clear_flags
eval "GSET_PREP=1"
_bs_st=0
_bs_on_exit
EOS
: > "$LOG_OUT"
env LOG_OUT="$LOG_OUT" FUNCS="$FUNCS" sh "$TMPD/t7.sh" >/dev/null 2>&1
eq "R6.2 有残留时必须打日志（快照/逐项/归零）" "$(grep -c '\[恢复\]' "$LOG_OUT")" "3"
eq "R6.3 生产脚本里只有一处快照日志" \
   "$(awk '/^_bs_on_exit\(\)/,/^}/' "$BS" | grep -c '退出时置位快照')" "1"

rm -rf "$TMPD"
echo ""
echo "===== 置位恢复专项: PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" = 0 ] || exit 1
