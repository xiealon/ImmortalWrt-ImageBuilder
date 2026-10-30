#!/bin/sh
# R7：ip_forward 哨兵机制，跑**生产脚本本体**，不抄逻辑。
#
# 怎么做到"跑本体又不动真 /proc"：
#   把整个脚本复制一份，只把字面量 /proc/sys/net/ipv4/ip_forward 换成临时文件路径，
#   再用 `sh 副本 --only-funcs` 只取定义（脚本底部那个测试钩子）。
#   于是下面调用的 _ipfwd_snapshot / _ipfwd_mark / _ipfwd_restore 全是生产版本，
#   一行逻辑都没抄——生产代码改坏了，这里立刻红。
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
FILES_DIR="${CS_FILES_DIR:-files}"
BS="$REPO/$FILES_DIR/usr/sbin/crowdsec-lxc-bootstrap.sh"
# 只含活代码的副本：整行注释（行首可有空白 + #）不算命中。
# 注释里提到某关键字（例如记录「曾经 disable lxc-auto」）不该被断言当成
# 「代码里在做这件事」，否则断言会假红或假绿。断言一律 grep 这份副本。
BS_C="$(mktemp)"
grep -v '^[[:space:]]*#' "$BS" > "$BS_C"
trap 'rm -f "$BS_C"' EXIT INT TERM
TMPD=${TMPD_R7:-$(mktemp -d "${TMPDIR:-/tmp}/r7.XXXXXX")}
PFWD="$TMPD/proc"
mkdir -p "$PFWD"
export REAL="$PFWD/ip_forward"
SANDBOX="$TMPD/sandbox.sh"

sed "s|/proc/sys/net/ipv4/ip_forward|$REAL|g" "$BS_C" > "$SANDBOX"
grep -q "$REAL" "$SANDBOX" || { echo "FATAL: 字面量替换失败"; exit 1; }

export LOG="$TMPD/log"
export IMPL="$TMPD/impl.sh"
sh "$SANDBOX" --only-funcs > "$IMPL" 2>"$TMPD/err" || { echo "FATAL: --only-funcs 失败"; cat "$TMPD/err"; exit 1; }
grep -q '^_ipfwd_snapshot()' "$IMPL" || { echo "FATAL: 生产函数未导出"; exit 1; }

# 驱动脚本：source 生产定义 → 用 _step 摆出"进场状态"→ 看快照/还原的真实结果
cat > "$TMPD/t8.sh" <<'EOS'
. "$IMPL"
# log 必须在 source 之后覆盖（生产 log 会把 date 前缀一起写进去）
log() { echo "$*" >> "$LOG"; }
IPFWD_SENTINEL="$REAL.by-bootstrap"     # 沙箱内把哨兵也摆到临时目录
_ird() { cat "$REAL" 2>/dev/null; }
_irw() { echo "$1" > "$REAL"; }

# step <标签> <进场时机器值> <进场时哨兵是否存在 0/1> <退出时是否已成功引导 0/1>
_step() {
    echo "--- $1" >> "$LOG"
    _irw "$2"
    rm -f "$IPFWD_SENTINEL"; [ "$3" = 1 ] && : > "$IPFWD_SENTINEL"
    _bs_stamped=$4
    _ipfwd_snapshot                       # ← 生产版本
    echo "ORIG=$_ipfwd_orig HAS_SENTINEL=$([ -f "$IPFWD_SENTINEL" ] && echo 1 || echo 0)" >> "$LOG"
    # 模拟 build_ip_forward 真的把 1 置上（含哨兵），再走退出还原
    _irw 1; _ipfwd_touched=1; _ipfwd_mark   # ← 生产版本
    echo "MARKED_SENTINEL=$([ -f "$IPFWD_SENTINEL" ] && echo 1 || echo 0)" >> "$LOG"
    _ipfwd_restore                        # ← 生产版本
    echo "VAL=$(_ird) SENTINEL_AFTER=$([ -f "$IPFWD_SENTINEL" ] && echo 1 || echo 0)" >> "$LOG"
}

# 顺序要紧：每步结束都留下"机器值 1 + 哨兵在"。若 A 还在前面，D 的收尾会把
# 全局态留在 1+哨兵，再跑一次 A 就不是"上次留下的"了——所以四个 case 各自独立、
# 且最后一个动作必须是"验收态"，不能有下一步去污染它。这里用显式重置把耦合掐断。
# (i) 上次是脚本置的 1，异常退出没还原 → 哨兵在 → 原值按 0 → 这次失败退出必须写回 0
_step A 1 1 0
# (ii) 别人设的 1（手工开的转发）→ 无哨兵 → 原值就是 1 → 失败退出也不许动
_step B 1 0 0
# (iii) 机器已自己回 0（重启过）+ 残留哨兵 → 原值 0，且哨兵在快照阶段就该清掉
_step C 0 1 0
# (iv) 引导成功 → 保留 1，哨兵留着备下次判断
_step D 1 1 1
EOS

: > "$LOG"
# 设备上只有 /bin/sh（ash），没有独立 dash
sh "$TMPD/t8.sh" >"$TMPD/out" 2>"$TMPD/t8.err" || true
[ -s "$TMPD/t8.err" ] && { echo "--- stderr:"; cat "$TMPD/t8.err"; }

seg() { awk -v n="$1" '$0=="--- "n {f=1; next} /^--- /{f=0} f' "$LOG"; }

# 取 "K=值" 里 K 的值。注意两点，都是踩过的：
#   · 同一行挤了多个 K=V，得先 `tr ' ' '\n'` 拆开再找；
#   · 不能用 `grep "^K="` —— 拆开后的第二段前面还有个换行，^ 锚点匹配不上
#     （grep 是按行匹配，但这里是同一个流里逐行，锚点本身没问题；真正的坑是
#     `grep -m1`/`head -1` 组合在某些实现上会提前退出，所以统一改成不带 -m 的写法）。
get() {
    _gv=$(seg "$1" | tr ' ' '\n' | grep "^$2=" | head -1)
    printf '%s' "${_gv#"$2="}"
}

R=0
ck() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 got=[$2] want=[$3]"; R=$((R+1)); fi; }

ck "R7.1 (i) 哨兵在+当前1 → 原值按 0"   "$(get A ORIG)" "0"
ck "R7.2 (i) 置位时确实落了哨兵"         "$(get A MARKED_SENTINEL)" "1"
ck "R7.3 (i) 失败退出 → 写回 0"          "$(get A VAL)" "0"
ck "R7.4 (i) 还原后哨兵删除"             "$(get A SENTINEL_AFTER)" "0"
ck "R7.5 (ii) 无哨兵+当前1 → 原值 1"     "$(get B ORIG)" "1"
ck "R7.6 (ii) 别人置的 1 不许动"          "$(get B VAL)" "1"
ck "R7.7 (iii) 当前0+残留哨兵 → 原值 0"  "$(get C ORIG)" "0"
ck "R7.8 (iii) 快照阶段即清掉残留哨兵"    "$(get C HAS_SENTINEL)" "0"
ck "R7.9 (iii) 退出后仍为 0"             "$(get C VAL)" "0"
ck "R7.10 (iv) 成功引导 → 保留 1"        "$(get D VAL)" "1"
ck "R7.11 (iv) 成功引导 → 哨兵保留"      "$(get D SENTINEL_AFTER)" "1"
# A 和 D 两次进场都命中哨兵，所以这里期望 2（不是 1——写测试时先写成 1，被探针抓住了）
ck "R7.12 每命中一次哨兵就留一行说明" "$(grep -c '检出上次遗留的 ip_forward 哨兵' "$LOG")" "2"

# ---- 静态：哨兵确实挂在生产路径上 ----
ck "R7.13 build_ip_forward 置 1 后落哨兵" \
   "$(awk '/^build_ip_forward\(\)/,/^}/' "$BS_C" | grep -c '^ *_ipfwd_mark')" "1"
ck "R7.14 哨兵落在 STATE_DIR 下" \
   "$(grep -c '^IPFWD_SENTINEL="\$STATE_DIR/' "$BS_C")" "1"
ck "R7.15 成功引导分支在写回之前 return" \
   "$(awk '/^_ipfwd_restore\(\)/,/^}/' "$BS_C" | grep -c '_bs_stamped:-0.*= 1 ] && return 0')" "1"

[ -n "${TMPD_R7:-}" ] || rm -rf "$TMPD"
echo "R7 FAIL=$R"
[ "$R" = 0 ]
