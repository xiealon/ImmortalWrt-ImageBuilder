#!/bin/sh
# R35【v.108.67】：常驻进程里不许有「没有上限的等待」
#
# 这一类坏法与本轮 guard 那两处裸 lxc-attach 同源，但更隐蔽：
#   进程没有崩，只是卡在等；procd 看到 pid 还在 → 不 respawn →
#   服务表里 state=running，日志里一个字都没有，功能已经全停了。
#
# 四处落点（都在 procd 管的常驻/开机路径上）：
#   ① probe 的 8 处 bootstrap 调用 —— 内部每条宿主命令 10s，条数没有上界
#   ② probe 调 guard —— 3 次 attach × 10s 之上再给硬顶
#   ③ rc.local 同步跑 bootstrap —— 卡住会把 rcS 收尾一起拖住
#   ④ init.d 服务壳 start_service 里同步跑 guard —— 卡住连探针都起不来
# guard 自己的两处 attach（v.108.66）与 /health 的 wget（v.108.67）在 R13 里钉。
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
PR="$REPO/files/usr/sbin/crowdsec-lxc-probe.sh"
RC="$REPO/files/etc/rc.local"
IN="$REPO/files/etc/init.d/crowdsec-lxc-probe"
TMPD="$REPO/tests/.r35.$$"
rm -rf "$TMPD"; mkdir -p "$TMPD" || { echo "FATAL: 无法创建 $TMPD"; exit 2; }
trap 'rm -rf "$TMPD"' EXIT INT TERM
R=0
ck() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 got=[$2] want=[$3]"; R=$((R+1)); fi; }
# 只统计活代码：整行注释不算命中（注释里提到某关键字不等于代码在做）
cg() { grep -v '^[[:space:]]*#' "$1" | grep -c -- "$2"; }
# 取某个函数的函数体（到第一个行首 } 为止），断言「这个函数里没有裸调用」时用它，
# 免得把 _boot 定义体里的 "$BOOT" 也算进来。
body() { awk -v fn="$1" '$0 ~ "^"fn"\\(\\)[[:space:]]*\\{" { inside = 1 } inside { print } inside && /^}/ { exit }' "$2"; }

echo "===== R35a. 常量与入口 ====="
ck "R35.1 三档默认 60 / 300 / 900（按调用类型，不给一个 1800 大锅）" \
   "$(cg "$PR" '^PROBE_CHECK_MAX="\${CS_PROBE_CHECK_MAX:-60}"$')$(cg "$PR" '^PROBE_VERIFY_MAX="\${CS_PROBE_VERIFY_MAX:-300}"$')$(cg "$PR" '^PROBE_FIX_MAX="\${CS_PROBE_FIX_MAX:-900}"$')" "111"
ck "R35.2 PROBE_GUARD_MAX 默认 60" \
   "$(cg "$PR" '^PROBE_GUARD_MAX="\${CS_PROBE_GUARD_MAX:-60}"$')" "1"
ck "R35.3 _boot 有 case 三档" \
   "$(cg "$PR" '--probe-check) _BOOT_MAX="\$PROBE_CHECK_MAX"')$(cg "$PR" '--verify-only) _BOOT_MAX="\$PROBE_VERIFY_MAX"')$(cg "$PR" '\*) _BOOT_MAX="\$PROBE_FIX_MAX"')" "111"
ck "R35.3b _boot 用 _BOOT_MAX 传给 timeout，参数原样透传" \
   "$(cg "$PR" '^    timeout "\$_BOOT_MAX" "\$BOOT" "\$@"$')" "1"

echo "===== R35b. probe：所有 bootstrap 调用都走 _boot ====="
ck "R35.4 _boot 调用 8 处（补印1 + 体检4 + 主判定1 + 触发1 + 复检1）" \
   "$(cg "$PR" '_boot ')" "8"
ck "R35.5 probe_tick 里没有裸 \"\$BOOT\" 调用（全部走 _boot）" \
   "$(body probe_tick "$PR" | grep -c '"$BOOT" ')" "0"
ck "R35.6 124 撞上限时单独记账，且用的是本档实际上限" \
   "$(cg "$PR" '【超时】bootstrap 超过 \${_BOOT_MAX:-\$PROBE_FIX_MAX}s 未返回')" "1"
ck "R35.7 124 的判定在失败计数之前（不改变原有计数语义）" \
   "$(awk '/\[ "\$_rc" = 124 \]/{a=NR} a && !b && /P_FAIL=\$\(\(/ {b=NR} END{print (a && b && a<b) ? "yes" : "no"}' "$PR")" "yes"
ck "R35.8 probe 调 guard 带 timeout" \
   "$(cg "$PR" 'timeout "\$PROBE_GUARD_MAX" "\$GUARD" quiet')" "1"

echo "===== R35c. 开机入口与服务壳 ====="
ck "R35.9 rc.local 的 bootstrap 调用带硬顶" \
   "$(cg "$RC" 'timeout "\${CS_RC_BOOT_MAX:-1800}" /bin/sh "\$BOOT"')" "1"
ck "R35.10 rc.local 撞上限时写日志（否则只看到「引导没跑完」）" \
   "$(cg "$RC" '\[ "\$_rc" = 124 \]')" "1"
ck "R35.11 init.d start_service 的 guard 调用带硬顶" \
   "$(cg "$IN" 'timeout 60 "\$_g" quiet')" "1"

echo "===== R35d. 行为：_boot 真的把上限传给了 timeout ====="
awk '/^_boot\(\)/ { inside = 1 } inside { print } inside && /^}/ { exit }' "$PR" > "$TMPD/boot.sh"
ck "R35.12 能抽出 _boot 定义" "$([ -s "$TMPD/boot.sh" ] && echo yes || echo no)" "yes"
cat > "$TMPD/run.sh" <<'EOS'
BOOT=/usr/sbin/crowdsec-lxc-bootstrap.sh
# 默认值来自实现，这里只验证「按参数选了哪一档、传进 timeout 的是不是那个数」
PROBE_CHECK_MAX=60
PROBE_VERIFY_MAX=300
PROBE_FIX_MAX=900
timeout() { printf 'TO=%s CMD=%s NARGS=%s\n' "$1" "$2" "$(($# - 2))"; }
. "$TMPD/boot.sh"
_boot --probe-check
_boot --verify-only x
_boot
PROBE_CHECK_MAX=7
_boot --probe-check
_boot --unknown-arg
EOS
TMPD="$TMPD" sh "$TMPD/run.sh" > "$TMPD/out" 2>&1
ck "R35.13 _boot 透传：按档选上限 / 命令 / 参数个数（未知参数落完整档）" \
   "$(tr '\n' '|' < "$TMPD/out")" \
   "TO=60 CMD=/usr/sbin/crowdsec-lxc-bootstrap.sh NARGS=1|TO=300 CMD=/usr/sbin/crowdsec-lxc-bootstrap.sh NARGS=2|TO=900 CMD=/usr/sbin/crowdsec-lxc-bootstrap.sh NARGS=0|TO=7 CMD=/usr/sbin/crowdsec-lxc-bootstrap.sh NARGS=1|TO=900 CMD=/usr/sbin/crowdsec-lxc-bootstrap.sh NARGS=1|"

echo "------------------------------------------------------------------"
echo "R35 RESULT: $R 项失败"
exit $R
