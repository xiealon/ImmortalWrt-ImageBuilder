#!/bin/sh
# R13：核心脚本防篡改（crowdsec-guard）—— 只读基准 + 三处看门狗
#
# 为什么不是 chattr +i：/usr/sbin 下的文件在 overlayfs 合并视图里，还没 copy-up 时
# chattr 的 ioctl 打到下层 squashfs，直接 Operation not supported（实测报的就是这个）；
# 先 copy-up 再设也能成功，但 flag 只落在 upper 的 ext4 上，刷机重建 overlay 就丢，
# 而且挡不住直接删 /overlay/upper/... 把上层实体拿掉。squashfs 的 /rom 是内核级只读
# （remount rw 直接失败），原件改不掉也删不掉，拿它当基准才站得住。
# 本测试盯三件事：不一致（改过 / 删了 / 丢执行位）必须复原；基准缺失时不许臆造；
# 三个调用点的相对顺序（guard 必须排在前置检查和 probe_tick 之前）。
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
G="$REPO/files/usr/sbin/crowdsec-guard.sh"
RC="$REPO/files/etc/rc.local"
PR="$REPO/files/usr/sbin/crowdsec-lxc-probe.sh"
IN="$REPO/files/etc/init.d/crowdsec-lxc-probe"
B24="$REPO/x86-64/build24.sh"
B25="$REPO/x86-64/build25.sh"
# 本机 busybox-w32 下 $TMPDIR 为空时 mktemp 的模板会解析成空串，TMPD 变成空，
# 于是 $ROM/$RT 退化成 /rom、/root（C 盘根）。后果不只是脏：上一次跑剩下的
# /rom/srv/lxc/ubuntu/base 会让下一次的 guard 看到「容器就位」，凭空多出几条日志，
# 断言就红在一个跟代码无关的地方（真踩过：本轮 R13.3/R13.14/R13.17/R13.39/R13.41）。
TMPD="$REPO/tests/.r13.$$"
rm -rf "$TMPD"
mkdir -p "$TMPD" || { echo "无法创建临时目录 $TMPD"; exit 2; }
R=0
ck() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 got=[$2] want=[$3]"; R=$((R+1)); fi; }
# 只统计活代码的命中：整行注释（行首可有空白 + #）不算。
# 注释里提到某关键字（例如记录「曾经 disable」）不该被当成「代码在做这件事」，
# 否则断言会假红或假绿。
cg() { grep -v '^[[:space:]]*#' "$1" | grep -c -- "$2"; }

ROM="$TMPD/rom"
RT="$TMPD/root"
LOG="$TMPD/guard.log"
mkdir -p "$ROM/usr/sbin/nodir" "$RT/usr/sbin" "$RT/etc/init.d" "$ROM/etc/init.d"

# 保护表用 .sh 扩展名：本机 busybox-w32 的 [ -x ] 按扩展名判定，.local/.txt 恒为假，
# 会让"内容一致但不可执行"这一支每轮都触发，把 R13.3 的静默性搅乱。
GF="
/usr/sbin/a.sh
/etc/b.sh
"
run_g() { CS_GUARD_ROM="$ROM" CS_GUARD_ROOT="$RT" CS_GUARD_LOG="$LOG" CS_GUARD_FILES="$GF" sh "$G" "$@"; }
reset_all() {
    rm -f "$LOG"
    printf 'ORIGINAL\n' > "$ROM/usr/sbin/a.sh"
    printf 'ORIGINAL\n' > "$ROM/etc/b.sh"
    printf 'ORIGINAL\n' > "$RT/usr/sbin/a.sh"
    printf 'ORIGINAL\n' > "$RT/etc/b.sh"
}

echo "== 1 基准目录不存在：不许动任何文件 =="
reset_all
printf 'TAMPERED\n' > "$RT/usr/sbin/a.sh"
CS_GUARD_ROM="$TMPD/no-such-rom" CS_GUARD_ROOT="$RT" CS_GUARD_LOG="$LOG" CS_GUARD_FILES="$GF" sh "$G"
ck "R13.1 无基准时保持篡改状态" "$(cat "$RT/usr/sbin/a.sh")" "TAMPERED"

echo "== 2 一致：零动作、不写日志 =="
reset_all
run_g
ck "R13.2 一致时不改内容" "$(cat "$RT/usr/sbin/a.sh")" "ORIGINAL"
ck "R13.3 一致时不写日志" "$([ -s "$LOG" ] && echo has || echo empty)" "empty"

echo "== 3 内容被改：复原 + 留证据 =="
reset_all
printf 'TAMPERED\n' > "$RT/usr/sbin/a.sh"
run_g
ck "R13.4 被改后复原" "$(cat "$RT/usr/sbin/a.sh")" "ORIGINAL"
ck "R13.5 生成 .user- 备份" "$(ls "$RT/usr/sbin"/a.sh.user-* 2>/dev/null | wc -l)" "1"
ck "R13.6 备份内容是被改的那份" "$(cat "$RT/usr/sbin"/a.sh.user-* 2>/dev/null)" "TAMPERED"
ck "R13.7 日志记录不一致" "$(grep -c '与只读基准不一致' "$LOG" 2>/dev/null)" "1"

echo "== 4 文件被删：复原 =="
reset_all
rm -f "$RT/etc/b.sh"
run_g
ck "R13.8 被删后复原" "$(cat "$RT/etc/b.sh" 2>/dev/null)" "ORIGINAL"
ck "R13.9 日志记录被删除" "$(grep -c '被删除' "$LOG" 2>/dev/null)" "1"

echo "== 5 权限以基准为准（含 644 的配置文件） =="
# 原测试靠 chmod 构造「内容同但丢执行位」，但 Windows 下 busybox 的 chmod 语义
# 不可靠（同一环境下 -x 恒真），构造不出两侧权限不同的现场，改用静态断言：
# guard 必须按基准的 stat 权限比对，而不是硬判 [ -x ] —— 后者会把清单里任何
# 644 的 /etc/config/* 都当成「不一致」，每轮复原一次，反而搅成死循环。
ck "R13.10 权限按 stat 比对" "$(cg "$G" "stat -c '%a'")" "2"
ck "R13.10b 不再硬判 -x" "$(cg "$G" '&& \[ -x "\$_f" \]')" "0"

echo "== 6 连续两次篡改：备份只留最近一份 =="
reset_all
printf 'BAD1\n' > "$RT/usr/sbin/a.sh"; run_g
printf 'BAD2\n' > "$RT/usr/sbin/a.sh"; run_g
ck "R13.11 只留 1 份备份" "$(ls "$RT/usr/sbin"/a.sh.user-* 2>/dev/null | wc -l)" "1"
ck "R13.12 备份是最新那次" "$(cat "$RT/usr/sbin"/a.sh.user-* 2>/dev/null)" "BAD2"

echo "== 7 基准里没有该项：不臆造 =="
reset_all
rm -f "$RT/usr/sbin/x.bin"
CS_GUARD_ROM="$ROM" CS_GUARD_ROOT="$RT" CS_GUARD_LOG="$LOG" \
    CS_GUARD_FILES="/usr/sbin/never-existed.sh" sh "$G"
ck "R13.13 基准无此项时不创建" "$([ -f "$RT/usr/sbin/never-existed.sh" ] && echo yes || echo no)" "no"

echo "== 8 单项复原失败：记账，且不拖累其他项 =="
reset_all
printf 'ORIGINAL\n' > "$ROM/usr/sbin/nodir/b.sh"
printf 'ORIGINAL\n' > "$RT/usr/sbin/a.sh"
printf 'TAMPERED\n' > "$RT/usr/sbin/a.sh"
rm -rf "$RT/usr/sbin/nodir"
rm -f "$LOG"
CS_GUARD_ROM="$ROM" CS_GUARD_ROOT="$RT" CS_GUARD_LOG="$LOG" \
    CS_GUARD_FILES="/usr/sbin/nodir/b.sh
/usr/sbin/a.sh" sh "$G"
ck "R13.14 失败项记账" "$(grep -c '复原失败' "$LOG" 2>/dev/null)" "1"
ck "R13.15 同轮其他项仍复原" "$(cat "$RT/usr/sbin/a.sh")" "ORIGINAL"

echo "== 9 quiet 与默认输出 =="
reset_all
printf 'TAMPERED\n' > "$RT/usr/sbin/a.sh"
_q=$(run_g quiet 2>&1 >/dev/null)
ck "R13.16 quiet 不写 stderr" "[$_q]" "[]"
printf 'TAMPERED\n' > "$RT/usr/sbin/a.sh"
_q=$(run_g 2>&1 >/dev/null)
ck "R13.17 非 quiet 写 stderr" "$(printf '%s' "$_q" | grep -c 'crowdsec-guard:')" "1"

echo "== 10 生产默认：基准不存在时安静退出 =="
rm -f "$TMPD/prod.log"
CS_GUARD_LOG="$TMPD/prod.log" sh "$G" quiet
ck "R13.18 默认路径 exit 0" "$?" "0"
ck "R13.19 默认路径不写日志" "$([ -f "$TMPD/prod.log" ] && echo yes || echo no)" "no"

echo "== 11 保护表的范围 =="
ck "R13.20 含 bootstrap" "$(cg "$G" '^/usr/sbin/crowdsec-lxc-bootstrap.sh$')" "1"
ck "R13.21 含 probe" "$(cg "$G" '^/usr/sbin/crowdsec-lxc-probe.sh$')" "1"
ck "R13.22 含 guard 自身" "$(cg "$G" '^/usr/sbin/crowdsec-guard.sh$')" "1"
ck "R13.23 含 rc.local" "$(cg "$G" '^/etc/rc.local$')" "1"
ck "R13.24 含 init.d 服务壳" "$(cg "$G" '^/etc/init.d/crowdsec-lxc-probe$')" "1"
ck "R13.24b 含 lxc-auto 服务（容器常驻靠它）" "$(cg "$G" '^/etc/init.d/lxc-auto$')" "1"
# action 注入的 config 和运行期配置绝不能被"复原"，否则 _drop_enroll_key 删不掉 key
ck "R13.25 不含 action 注入的 /etc/config/*.txt" "$(cg "$G" '^/etc/config/.*\.txt$')" "0"
# /etc/config/lxc-auto 是运行期 uci 配置：/rom 里是 lxc-auto 包的注释模板，
# 纳进 guard 会把 bootstrap / uci-defaults 写好的配置每轮复原成注释态，
# 容器于是随机起不来。v.108.7 加过、v.108.8 撤回。
ck "R13.25b 不含 /etc/config/lxc-auto" "$(cg "$G" '^/etc/config/lxc-auto$')" "0"
ck "R13.26 不含容器 rootfs" "$(cg "$G" '^/srv/lxc')" "0"

echo "== 12 三个调用点的相对顺序 =="
# rc.local：bootstrap 被删时前置检查会 exit 0，guard 必须排在它前面才有机会复原
_lg=$(grep -n 'crowdsec-guard.sh' "$RC" | head -n1 | cut -d: -f1)
# 用 "||" 一起匹配，避开注释里同样出现过的这串字面
_lb=$(grep -n -F '[ -f "$BOOT" ] ||' "$RC" | head -n1 | cut -d: -f1)
ck "R13.27 rc.local 有 guard 调用" "$([ -n "$_lg" ] && echo yes || echo no)" "yes"
ck "R13.28 rc.local guard 在前置检查之前" "$([ -n "$_lg" ] && [ -n "$_lb" ] && [ "$_lg" -lt "$_lb" ] && echo yes || echo no)" "yes"
# probe：bootstrap 持锁时 tick 走 lock-busy 早退，guard 不能跟着停
_pg=$(grep -n '^    _guard_run$' "$PR" | head -n1 | cut -d: -f1)
_pt=$(grep -n '^    probe_tick$' "$PR" | head -n1 | cut -d: -f1)
ck "R13.29 probe 主循环调用 guard" "$([ -n "$_pg" ] && echo yes || echo no)" "yes"
ck "R13.30 guard 在 probe_tick 之前" "$([ -n "$_pg" ] && [ -n "$_pt" ] && [ "$_pg" -lt "$_pt" ] && echo yes || echo no)" "yes"
ck "R13.31 init.d 起服务前自举+调用" "$(cg "$IN" 'crowdsec-guard.sh')" "1"
ck "R13.32 init.d 调用带 quiet" "$(cg "$IN" '"\$_g" quiet')" "1"

echo "== 13 日志封顶（超 64KB 只留最后 200 行） =="
reset_all
printf 'short-line\n' > "$LOG"
printf 'TAMPERED\n' > "$RT/usr/sbin/a.sh"
run_g
ck "R13.38 小日志不轮转、原内容保留" "$(grep -c 'short-line' "$LOG")" "1"
ck "R13.39 小日志只追加一行" "$(wc -l < "$LOG" | tr -d ' ')" "2"

reset_all
rm -f "$LOG"
_i=0
while [ "$_i" -lt 2000 ]; do
    echo "[2026-01-01 00:00:00] padding line $_i 0123456789012345678901234567890123456789" >> "$LOG"
    _i=$((_i + 1))
done
_before=$(wc -c < "$LOG" | tr -d ' ')
printf 'TAMPERED\n' > "$RT/usr/sbin/a.sh"
run_g
ck "R13.40 轮转前确实超限" "$([ "$_before" -gt 65536 ] && echo yes || echo no)" "yes"
ck "R13.41 轮转后只留最后 200 行 + 新 1 行" "$(wc -l < "$LOG" | tr -d ' ')" "201"
ck "R13.42 轮转后体积回落到 64KB 内" "$([ "$(wc -c < "$LOG" | tr -d ' ')" -lt 65536 ] && echo yes || echo no)" "yes"
ck "R13.43 轮转保留的是尾部内容" "$(grep -c 'padding line 1999' "$LOG")" "1"
ck "R13.44 轮转没丢掉最新那条" "$(grep -c '已复原' "$LOG")" "1"

echo "== 14 出镜像时执行位有断言，不靠 2>/dev/null 掩盖 =="
for _b in "$B24" "$B25"; do
    _n=$(basename "$_b")
    ck "R13.33 $_n 断言表含 guard" "$(cg "$_b" 'files/usr/sbin/crowdsec-guard.sh')" "2"
    ck "R13.34 $_n 断言表含 probe" "$(cg "$_b" 'files/usr/sbin/crowdsec-lxc-probe.sh')" "2"
    ck "R13.35 $_n 断言表含 init.d" "$(cg "$_b" 'files/etc/init.d/crowdsec-lxc-probe')" "2"
    ck "R13.36 $_n 有 -x 断言" "$(cg "$_b" '\[ -x "\$_f" \]')" "1"
    # 三处硬失败：make image 返回非 0、执行位断言缺位、custom/* 拷进 files/etc/config 失败
    ck "R13.37 $_n 缺位即失败" "$(cg "$_b" 'exit 1')" "3"
done

echo "== 15 断言自身不许再被注释糊弄 =="
# 同 probe_netsafe R17：对脚本文件的断言一律走 cg()，整行注释不算命中
ck "R13.45 guard 断言普遍走 cg" \
   "$(grep -c 'cg "\$G"' "$0" | awk '{print ($1>=5)?"1":"0"}')" "1"
ck "R13.46 cg 已定义" \
   "$(grep -c '^cg() {' "$0")" "1"

echo "------------------------------------------------------------------"
echo "R13 RESULT: $R 项失败"
# 临时目录在 repo/tests 下，跑完必须清掉，否则会被下次 git add -A 带进仓库
rm -rf "$TMPD"
exit $R
