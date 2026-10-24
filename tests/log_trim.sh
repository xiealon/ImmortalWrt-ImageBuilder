#!/bin/sh
# R32【v.108.59】：引导日志封顶
#
# 三处日志里只有 /root/crowdsec-lxc-bootstrap.log 没有上限：rc.local 和探针都用
# >> 追加同一个文件，而 /root 在 overlay 上层，写进去都是 flash。
# 这里验两件事：静态（阈值/路径/调用点只有真引导一处）+ 动态（真截一次、真不截一次）。
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
BS="$REPO/files/usr/sbin/crowdsec-lxc-bootstrap.sh"
# v.108.70：probe 的 BOOT_LOG 也要与上面同源，R32.1e 用它
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

echo "== 32.1 函数与默认值 =="
ck "R32.1a 有 _boot_log_trim 定义" \
   "$(grep -c '^_boot_log_trim()' "$BS")" "1"
ck "R32.1b 默认阈值 1MB" \
   "$(grep -c '^BOOT_LOG_MAX="\${CS_BOOTSTRAP_LOG_MAX:-1048576}"$' "$BS")" "1"
ck "R32.1c 默认保留最后 2000 行" \
   "$(grep -c '^BOOT_LOG_KEEP="\${CS_BOOTSTRAP_LOG_KEEP:-2000}"$' "$BS")" "1"
ck "R32.1d 默认路径就是 rc.local / 探针共用的那个，且可被环境覆盖" \
   "$(grep -c '^BOOT_LOG="\${CS_BOOTSTRAP_LOG:-/root/crowdsec-lxc-bootstrap.log}"$' "$BS")" "1"
# 【v.108.70】probe 原来把 BOOT_LOG 写死成 /root/crowdsec-lxc-bootstrap.log。
# bootstrap 自己认 CS_BOOTSTRAP_LOG，于是「改了日志路径」之后：probe 还在往老文件
# 追加输出、也在老文件里找「补印」痕迹，两边对不上却没有任何报错 —— 这类
# 「不报错但给错答案」比直接报错难查得多。现在两边同源。
ck "R32.1e probe 的 BOOT_LOG 也认 CS_BOOTSTRAP_LOG（与 bootstrap 同源）" \
   "$(grep -c '^BOOT_LOG="\${CS_BOOTSTRAP_LOG:-/root/crowdsec-lxc-bootstrap.log}"$' "$PR")" "1"

echo "== 32.2 截断逻辑 =="
ck "R32.2a 未超限直接返回（-gt 判断，取等不截）" \
   "$(body _boot_log_trim "$BS" | grep -c '\[ "\$_bl_sz" -gt "\$BOOT_LOG_MAX" \]')" "1"
ck "R32.2b 用 tail 保留尾部（不是清空）" \
   "$(body _boot_log_trim "$BS" | grep -c 'tail -n "\$BOOT_LOG_KEEP"')" "1"
ck "R32.2c 先写 .tmp 再 mv（半截文件不会顶替日志）" \
   "$(body _boot_log_trim "$BS" | grep -c 'mv -f "\$BOOT_LOG.tmp" "\$BOOT_LOG"')" "1"
ck "R32.2d tail 失败时清掉 .tmp（不留垃圾文件）" \
   "$(body _boot_log_trim "$BS" | grep -c 'rm -f "\$BOOT_LOG.tmp"')" "1"
ck "R32.2e 截断要在日志里留一句（否则人以为日志丢了）" \
   "$(body _boot_log_trim "$BS" | grep -c '已截断为最后')" "1"

echo "== 32.3 调用点只有真引导这一处 =="
ck "R32.3a 顶格调用恰好 1 次" \
   "$(grep -c '^_boot_log_trim$' "$BS")" "1"
ck "R32.3b 调用在 main 之前" \
   "$(awk '/^_boot_log_trim$/{t=NR} /^main "\$@"$/{m=NR} END{print (t && m && t < m) ? "yes" : "no"}' "$BS")" "yes"
ck "R32.3c --only-funcs 测试钩子仍在调用点之前（导函数时不该截真日志）" \
   "$(awk '/= "--only-funcs"/{o=NR} /^_boot_log_trim$/{t=NR} END{print (o && t && o < t) ? "yes" : "no"}' "$BS")" "yes"
ck "R32.3d 版本号推进到 180.75" \
   "$(grep -c 'SCRIPT_VER="2026-10-24.180.75"' "$BS")" "1"

echo "== 32.4 真跑：超限要截 =="
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT INT TERM
body _boot_log_trim "$BS" > "$TMPD/fn.sh"
# 20000 行 × 约 60 字节 ≈ 1.2MB，超过 1MB 阈值
awk 'BEGIN{for(i=1;i<=20000;i++) printf "[2026-10-22 12:00:00] line %05d ============================================\n", i}' > "$TMPD/log"
_s0=$(wc -c <"$TMPD/log" | tr -d ' ')
_last0=$(tail -n 1 "$TMPD/log")
(
    BOOT_LOG="$TMPD/log"; BOOT_LOG_MAX=1048576; BOOT_LOG_KEEP=2000
    log() { printf '%s\n' "$*" >>"$TMPD/log.note"; }
    . "$TMPD/fn.sh"
    _boot_log_trim
)
_s1=$(wc -c <"$TMPD/log" | tr -d ' ')
_lines1=$(wc -l <"$TMPD/log" | tr -d ' ')
_last1=$(tail -n 1 "$TMPD/log")

ck "R32.4a 截前确实超阈值（造数据有效）" \
   "$([ "$_s0" -gt 1048576 ] && echo yes || echo no)" "yes"
ck "R32.4b 截后小于阈值" \
   "$([ "$_s1" -lt 1048576 ] && echo yes || echo no)" "yes"
ck "R32.4c 保留的正是最后 2000 行" "$_lines1" "2000"
ck "R32.4d 末行是原来那一行（截的是头不是尾）" "$_last1" "$_last0"
ck "R32.4e 留下了截断提示" \
   "$(grep -c '已截断为最后' "$TMPD/log.note" 2>/dev/null || echo 0)" "1"
ck "R32.4f 没有 .tmp 残留" \
   "$(ls "$TMPD" 2>/dev/null | grep -c 'log\.tmp')" "0"

echo "== 32.5 真跑：没超限一个字节都不动 =="
awk 'BEGIN{for(i=1;i<=100;i++) printf "[2026-10-22 12:00:00] line %03d\n", i}' > "$TMPD/small"
cp "$TMPD/small" "$TMPD/small.ref"
(
    BOOT_LOG="$TMPD/small"; BOOT_LOG_MAX=1048576; BOOT_LOG_KEEP=2000
    log() { printf '%s\n' "$*" >>"$TMPD/small.note"; }
    . "$TMPD/fn.sh"
    _boot_log_trim
)
ck "R32.5a 小文件逐字节未变" \
   "$(cmp -s "$TMPD/small" "$TMPD/small.ref" && echo same || echo diff)" "same"
ck "R32.5b 小文件不写截断提示" \
   "$([ -f "$TMPD/small.note" ] && echo wrote || echo none)" "none"

echo "== 32.6 真跑：日志不存在不报错 =="
(
    BOOT_LOG="$TMPD/nope.log"; BOOT_LOG_MAX=1048576; BOOT_LOG_KEEP=2000
    log() { :; }
    . "$TMPD/fn.sh"
    _boot_log_trim
    echo "rc=$?"
) > "$TMPD/rc.txt" 2>&1
ck "R32.6a 文件不存在时静默返回 0" \
   "$(grep -c '^rc=0$' "$TMPD/rc.txt")" "1"
ck "R32.6b 文件不存在时不创建它" \
   "$([ -f "$TMPD/nope.log" ] && echo created || echo none)" "none"

echo "------------------------------------------------------------------"
echo "R32 RESULT: $R 项失败"
exit $R
