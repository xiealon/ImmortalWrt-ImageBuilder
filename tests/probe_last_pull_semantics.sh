#!/bin/sh
# R12：last_pull 判定的诚实性 —— 「判不了」不许假装「没问题」。
#
# bouncer_pulling 返回 0 有两种来路：明确新鲜，和判不了。原先判不了的三条路径
# （容器内 date 不可用 / 阈值非数字 / 阈值=0）全是裸 return 0、一个字不打。
# 而历史上 _escalate_reinstall 第一句就是 if bouncer_pulling → 「不升级」：
# 判不了被读成「已恢复」，打出「last_pull 已恢复，重装无益」——
# 机器卡在坏状态，日志一路报喜。这是"不报错、只给错误答案"那一类。
# 【v.106】那个门已经废掉了：last_pull 不再决定要不要重装（持续监视移交运行期
# 探针），_escalate_reinstall 的第一门改成 _structurally_broken。但 bouncer_pulling
# 自身的诚实性仍然必须是这套测试的目标——它现在供探针 --probe-check 使用。
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
BS="$REPO/files/usr/sbin/crowdsec-lxc-bootstrap.sh"
# 只含活代码的副本：整行注释（行首可有空白 + #）不算命中。
# 注释里提到某关键字（例如记录「曾经 disable lxc-auto」）不该被断言当成
# 「代码里在做这件事」，否则断言会假红或假绿。断言一律 grep 这份副本。
BS_C="$(mktemp)"
grep -v '^[[:space:]]*#' "$BS" > "$BS_C"
trap 'rm -f "$BS_C"' EXIT INT TERM
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/r12.XXXXXX")
R=0
ck() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 got=[$2] want=[$3]"; R=$((R+1)); fi; }

sh "$BS_C" --only-funcs > "$TMPD/f.sh" 2>/dev/null

cat > "$TMPD/t.sh" <<'EOS'
. "$F"
log() { printf 'LOG %s\n' "$*"; }
BOUNCER_NAME=crowdsec-firewall-bouncer
NOW=$(date +%s)
STALE=$(date -u -d "@$((NOW-7200))" '+%Y-%m-%dT%H:%M:%S')
FRESH=$(date -u -d "@$((NOW-60))"  '+%Y-%m-%dT%H:%M:%S')
# v.108 边界用例：默认阈值 60s（6 个 10s 心跳周期），所以两侧各取一个贴近的值。
# NEAR_OK 差值 50s  → 未达阈值，应判新鲜
# NEAR_BAD 差值 90s → 刚过阈值，应判失效
# FRESH 差值恰好 60s → 判定用 -gt，等号不成立，仍算新鲜（这条由 R12.1 顺带钉住）
NEAR_OK=$(date  -u -d "@$((NOW-50))" '+%Y-%m-%dT%H:%M:%S')
NEAR_BAD=$(date -u -d "@$((NOW-90))" '+%Y-%m-%dT%H:%M:%S')
L_NEAR_OK="  crowdsec-firewall-bouncer  10.0.0.201 ${NEAR_OK}Z ok"
L_NEAR_BAD="  crowdsec-firewall-bouncer  10.0.0.201 ${NEAR_BAD}Z ok"
L_STALE="  crowdsec-firewall-bouncer  10.0.0.201 ${STALE}Z ok"
L_FRESH="  crowdsec-firewall-bouncer  10.0.0.201 ${FRESH}Z ok"
# 桩必须匹配完整命令串（含尾部 +%s），否则 _at 取空、整条判定全走到"判不了"
_ct_env() {
    case "$1" in
        "date +%s") echo "$NOW" ;;
        "date -d '"*"' +%s")
            [ "$DATE_D_RC" = 1 ] && return 1
            case "$1" in
                *"${FRESH}Z"*)    echo $((NOW-60))  ;;
                *"${NEAR_OK}Z"*)  echo $((NOW-50))  ;;
                *"${NEAR_BAD}Z"*) echo $((NOW-90))  ;;
                *)                echo $((NOW-7200)) ;;
            esac ;;
        *bouncers*) printf '%s\n' "$LIST" ;;
        *) return 1 ;;
    esac
}
echo "== 1 真新鲜 =="
LIST="$L_FRESH"; DATE_D_RC=0; bouncer_pulling; echo "rc=$?"
echo "== 2 真停滞 =="
LIST="$L_STALE"; DATE_D_RC=0; bouncer_pulling; echo "rc=$?"
echo "== 3 列表里没有这个 bouncer =="
LIST="  other-bouncer  10.0.0.201 ${FRESH}Z ok"; DATE_D_RC=0; bouncer_pulling; echo "rc=$?"
echo "== 4 容器内 date -d 不可用 =="
LIST="$L_STALE"; DATE_D_RC=1; bouncer_pulling; echo "rc=$?"
echo "== 5 阈值=0 主动关闭 =="
LIST="$L_STALE"; DATE_D_RC=0; BOUNCER_PULL_MAX_AGE=0 bouncer_pulling; echo "rc=$?"
echo "== 6 阈值非数字（笔误） =="
LIST="$L_STALE"; DATE_D_RC=0; BOUNCER_PULL_MAX_AGE=abc bouncer_pulling; echo "rc=$?"
echo "== 7 阈值空串（:- 已换成默认阈值） =="
LIST="$L_STALE"; DATE_D_RC=0; BOUNCER_PULL_MAX_AGE= bouncer_pulling; echo "rc=$?"
echo "== 8 去重：连调 3 次停滞 =="
LIST="$L_STALE"; DATE_D_RC=0; _bp_last_msg=""
bouncer_pulling; bouncer_pulling; bouncer_pulling; echo "rc=$?"
echo "== 9 边界：差值 50s，未达 60s 阈值 =="
LIST="$L_NEAR_OK"; DATE_D_RC=0; _bp_last_msg=""; bouncer_pulling; echo "rc=$?"
echo "== 10 边界：差值 90s，刚过 60s 阈值 =="
LIST="$L_NEAR_BAD"; DATE_D_RC=0; _bp_last_msg=""; bouncer_pulling; echo "rc=$?"
EOS
F="$TMPD/f.sh" sh "$TMPD/t.sh" > "$TMPD/out" 2>&1
seg() { awk "/^== $1 /{p=1;next} p&&/^== /{exit} p" "$TMPD/out"; }
rc()  { seg "$1" | sed -n 's/^rc=//p'; }
lg()  { seg "$1" | grep -c "^LOG "; }

echo "===== R12a. 明确判定的两种，行为不能变 ====="
ck "R12.1 真新鲜 → rc 0" "$(rc 1)" "0"
ck "R12.2 真新鲜 → 完全静默（不刷屏）" "$(lg 1)" "0"
ck "R12.3 真停滞 → rc 1" "$(rc 2)" "1"
ck "R12.4 真停滞 → 有停滞日志" "$(lg 2)" "1"
ck "R12.5 列表里没有这个 bouncer → rc 1" "$(rc 3)" "1"

echo "===== R12b. 判不了的三条路径：放过，但必须说出来 ====="
# 这是本次修复的核心：返回码保持 0（放过方向），但日志必须出现
ck "R12.6 date 不可用 → 仍放过（rc 0，不冤枉好机器）" "$(rc 4)" "0"
ck "R12.7 date 不可用 → 必须打「判不了」（不许静默）" \
   "$(seg 4 | grep -c '判不了')" "1"
ck "R12.8 「判不了」日志里点明这不是「新鲜」" \
   "$(seg 4 | grep -c '这不是「新鲜」')" "1"
ck "R12.9 阈值=0 → 放过但说明是「按配置关闭」" \
   "$(seg 5 | grep -c '已按配置关闭')" "1"
ck "R12.10 阈值=0 → 也点明不是判定为新鲜" \
   "$(seg 5 | grep -c '不是判定为新鲜')" "1"
ck "R12.11 阈值非数字 → 警告一句" \
   "$(seg 6 | grep -c '不是数字，回落默认 60s')" "1"
ck "R12.12 阈值非数字 → 不再静默放行，判失效" "$(rc 6)" "1"
ck "R12.13 阈值空串 → 按默认阈值判失效" "$(rc 7)" "1"

# 【v.108】默认阈值 600 → 60（6 个 10s 心跳周期）。上面 R12.1~R12.13 都用
# 「滞后 7200s」构造停滞，改 60 之后照样全绿 —— 也就是说它们根本测不到阈值位置。
# 这几条专门钉边界：要么拒收错误的默认值，要么这套测试就是摆设。
ck "R12.13a 差值 50s（未达 60s 阈值）→ 判新鲜" "$(rc 9)" "0"
ck "R12.13b 差值 90s（刚过 60s 阈值）→ 判失效" "$(rc 10)" "1"
ck "R12.13c 默认值走常量，不是裸数字" \
   "$(grep -cF 'BOUNCER_PULL_MAX_AGE:-$_BP_DEFAULT_MAX_AGE' "$BS_C")" "1"
ck "R12.13d bouncer_pulling 函数体内不再出现裸 600（防「日志说 A、实际判 B」）" \
   "$(awk '/^bouncer_pulling\(\)/,/^}/' "$BS_C" | grep -c '600')" "0"
ck "R12.13e 周期定义 = 10s × 6" \
   "$(grep -cE '^_BP_PULL_(INTERVAL=10|MISS=6)$' "$BS_C")" "2"

echo "===== R12c. 日志不许刷屏 ====="
# _sc_wait_pull 每 5 秒调一次；原实现会在 60s 窗口里把「停滞」打 12 遍
ck "R12.14 连调 3 次停滞只出 1 行日志" "$(lg 8)" "1"

echo "===== R12d. 上游措辞：不许把「判不了」说成「已恢复」 ====="
# 排除注释：讲清这个 bug 的注释里当然要引用那句原来的错话
ck "R12.15 可执行代码里不再写「last_pull 已恢复」" \
   "$(grep -vE '^[[:space:]]*#' "$BS_C" | grep -c 'last_pull 已恢复')" "0"
ck "R12.16 【v.106】_escalate_reinstall 第一门改为结构性损坏判定" \
   "$(awk '/^_escalate_reinstall\(\)/,/^}/' "$BS_C" | grep -c '_structurally_broken ||')" "1"
ck "R12.16b 【v.106】重装不再由 last_pull 决定（该函数里没有 bouncer_pulling）" \
   "$(awk '/^_escalate_reinstall\(\)/,/^}/' "$BS_C" | grep -c 'bouncer_pulling')" "0"
ck "R12.17 _reinstall_diag 写「判定为在拉」而非「有效」" \
   "$(grep -c 'bouncer last_pull 判定为在拉' "$BS_C")" "1"
ck "R12.18 _sc_wait_pull 有进度日志（不再干等）" \
   "$(awk '/^_sc_wait_pull\(\)/,/^}/' "$BS_C" | grep -c '仍未刷新，继续等待')" "1"
ck "R12.19 _sc_wait_pull 进窗口时先报一句" \
   "$(awk '/^_sc_wait_pull\(\)/,/^}/' "$BS_C" | grep -c '只观察不修复')" "1"

rm -rf "$TMPD"
echo "R12 FAIL=$R"
[ "$R" = 0 ]
