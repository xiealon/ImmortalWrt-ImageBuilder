#!/bin/sh
# R34【v.108.61】：LAPI 起不来时的自愈阶梯 + 体检不验 enroll
#
# 两个缺口的现场表现：
#   A. enroll 恒被判不符 —— --verify-only 是独立进程，_ENROLL_TRIED 恒为 0，
#      于是「有注册码但还没在网页点 Accept」的机器每次体检都报不符，
#      探针每 30 轮（≈30 分钟）白跑一次完整引导，日志里看不出原因。
#   B. LAPI 起不来但文件和配置都正常 —— 各 verify 都通过、build 改不动什么，
#      hard 退出 → 探针 5 次后停手 → 机器一直坏到有人重启。
#      现在补一条阶梯：诊断 → 对症 → 丢可写层（带三道门）。
#
# 本文件同时钉住「第三档的额度不会被恢复刷新」这个最危险的设计：
# 若拿「恢复正常」当重置条件，就会变成「坏→丢层→好→再坏→再丢」的周期性抹盘。
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
BS="$REPO/files/usr/sbin/crowdsec-lxc-bootstrap.sh"
# 只含活代码的副本：整行注释不算命中（同 probe_last_pull_semantics 的 cg 口径）
BS_C="$REPO/tests/.r34.body.$$"
grep -v '^[[:space:]]*#' "$BS" > "$BS_C"
# 不用 mktemp：本机 busybox-w32 下 $TMPDIR 为空时模板解析成空串，路径会退化到 C 盘根。
TMPD="$REPO/tests/.r34.$$"
rm -rf "$TMPD"; mkdir -p "$TMPD" || { echo "无法创建临时目录 $TMPD"; exit 2; }
trap 'rm -rf "$TMPD" "$BS_C"' EXIT INT TERM
R=0
ck() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 got=[$2] want=[$3]"; R=$((R+1)); fi; }
body() {
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\)[[:space:]]*\\{" { inside = 1 }
        inside { print }
        inside && /^}/ { exit }
    ' "$2"
}

echo "===== R34a. 体检不验 enroll ====="
ck "R34.1 _audit_all 有 enroll 跳过分支" \
   "$(body _audit_all "$BS_C" | grep -c '^        enroll)')" "1"
ck "R34.2 跳过的必须打「跳过」，不能打 OK" \
   "$(body _audit_all "$BS_C" | grep -c '跳过（需联网')" "1"
ck "R34.3 跳过的项不计入「共 N 项」" \
   "$(body _audit_all "$BS_C" | awk '/_askip=\$\(\(_askip \+ 1\)\)/ {s=NR} /_an=\$\(\(_an \+ 1\)\)/ && s {print (s < NR) ? "yes" : "no"; exit}')" "yes"
ck "R34.4 收尾行单独说明跳过数量" \
   "$(body _audit_all "$BS_C" | grep -c '另有 %s 项跳过')" "1"

echo "===== R34b. 阶梯接在正确位置 ====="
ck "R34.5 _lapi_ladder 存在" \
   "$(grep -c '^_lapi_ladder()' "$BS_C")" "1"
ck "R34.6 build_lapi_fetch 调用阶梯" \
   "$(body build_lapi_fetch "$BS_C" | grep -c '_lapi_ladder')" "1"
ck "R34.7 调用在 _ensure_lapi_exposed 之后（第 0 档先试过）" \
   "$(body build_lapi_fetch "$BS_C" | awk '/_ensure_lapi_exposed/ {a=NR} /_lapi_ladder/ {b=NR} END {print (a && b && a < b) ? "yes" : "no"}')" "yes"
ck "R34.8 修好则继续读凭证，不是直接 return 0" \
   "$(body build_lapi_fetch "$BS_C" | grep -c '继续读取凭证')" "1"
ck "R34.9 阶梯不依赖 enroll（自愈逻辑里出现 enroll 即为越界）" \
   "$(body _lapi_ladder "$BS_C" | grep -c 'enroll')" "0"

echo "===== R34c. 三档各自的证据门 ====="
ck "R34.10 第 1 档用 crowdsec -t（只校验不启动）" \
   "$(body _lapi_cfg_test "$BS_C" | grep -c 'crowdsec -t -c /etc/crowdsec/config.yaml')" "1"
ck "R34.11 -t 不通过时不进第三档（配置坏≠该丢层）" \
   "$(body _lapi_ladder "$BS_C" | grep -c '不做第三档')" "1"
ck "R34.12 bad-yaml 走 cscli hub update" \
   "$(body _lapi_fix_by_sig "$BS_C" | grep -c "cscli hub update'")" "1"
ck "R34.13 bad-db 移走 decisions.db（留 .l3bak）" \
   "$(body _lapi_fix_by_sig "$BS_C" | grep -c 'mv -f "\$f" "\$f.l3bak')" "1"
ck "R34.14 且不写 machines.db" \
   "$(body _lapi_fix_by_sig "$BS_C" | grep -c 'machines.db')" "0"
ck "R34.15 第 2 档改完必须重启进程（改文件≠进程认了）" \
   "$(body _lapi_fix_by_sig "$BS_C" | grep -c '_ct_restart_crowdsec')" "1"
ck "R34.16 第三档只在有只读基底时可用" \
   "$(body _lapi_ladder "$BS_C" | grep -c '\[ -d "\$ROM_BASE" \]')" "1"
ck "R34.17 第三档丢可写层（upper + work）" \
   "$(body _l3_reset_overlay "$BS_C" | grep -c 'rm -rf "\$OVL_UPPER" "\$OVL_WORK"')" "1"
ck "R34.18 丢层前备份凭证" \
   "$(body _l3_reset_overlay "$BS_C" | grep -c '_cred_backup')" "1"
ck "R34.19 递归保护：重装后重跑不再进阶梯" \
   "$(body _lapi_ladder "$BS_C" | grep -c 'CS_BOOTSTRAP_REINSTALL')" "1"

echo "===== R34d. 第三档三道门（真跑） ====="
sh "$BS_C" --only-funcs > "$TMPD/f.sh" 2>/dev/null
[ -s "$TMPD/f.sh" ] || { echo "FATAL: --only-funcs 导出失败"; exit 2; }

# 桩脚本统一约定：可变参数走 T_ 前缀的环境变量。
# 为什么不能反过来（先设变量再 source）：--only-funcs 导出的是整个脚本前部，
# 里面那些顶层赋值（STATE_DIR / OVL_UPPER / L3_STATE / L3_MAX）会把外部值全部覆盖，
# 必须 source 之后再重设一遍。
cat > "$TMPD/gate.sh" <<'EOS'
. "$F"
TMPD="$T_TMPD"; STATE_DIR="$TMPD"; L3_STATE="$TMPD/st"
OVL_UPPER="$TMPD/up"; OVL_WORK="$TMPD/wk"; REINSTALL_PENDING_FILE="$TMPD/pend"
BOOT="$T_BOOT"; DF_AVAIL="$T_DF"
L3_MAX="${T_L3MAX:-1}"; L3_GAP="${T_L3GAP:-21600}"
log() { :; }
_cur_boot_id() { printf '%s\n' "$BOOT"; }
df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/x 1000 100 %s 50%% %s\n' "$DF_AVAIL" "$OVL_UPPER"; }
_l3_gate "$T_SIG"
echo "RC=$?"
EOS

cat > "$TMPD/lad.sh" <<'EOS'
. "$F"
TMPD="$T_TMPD"; STATE_DIR="$TMPD"; L3_STATE="$TMPD/st"
OVL_UPPER="$TMPD/up"; OVL_WORK="$TMPD/wk"; REINSTALL_PENDING_FILE="$TMPD/pend"
ROM_BASE="$T_ROM"; BOOT="$T_BOOT"; CS_BOOTSTRAP_REINSTALL="$T_REINSTALL"
L3_MAX="${T_L3MAX:-1}"; L3_GAP="${T_L3GAP:-21600}"
log() { printf '%s\n' "$*" >> "$TMPD/log"; }
ct_running() { return 0; }
_cur_boot_id() { printf '%s\n' "$BOOT"; }
_bs_reexec() { printf 'REEXEC\n' >> "$TMPD/actions"; return 0; }
_cred_backup() { return 0; }
ct_force_stop() { return 0; }
_overlay_umount() { return 0; }
rm() { printf 'RMOVL %s\n' "$*" >> "$TMPD/actions"; return 0; }
df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/x 1000 100 100000 50%% x\n'; }
verify_lapi_reachable() {
    # 第 1 次问（阶梯开头）由 T_LAPI_UP 控制；之后由 T_FIX_UP 控制（模拟第 2 档生效）
    _n=$(cat "$TMPD/rc_ask" 2>/dev/null || echo 0)
    _n=$((_n + 1)); echo "$_n" > "$TMPD/rc_ask"
    if [ "$_n" -le 1 ]; then [ "$T_LAPI_UP" = 1 ]; return $?; fi
    [ "$T_FIX_UP" = 1 ]
}
_wait_lapi_ready() { return 0; }
_lapi_cfg_test() { _LCT_RC="$T_LCT_RC"; _LCT_SIG="$T_SIG"; return 0; }
_ct_env() { printf 'CTENV %s\n' "$1" >> "$TMPD/actions"; return 0; }
_ct_restart_crowdsec() { printf 'RESTART\n' >> "$TMPD/actions"; return 0; }
_lapi_ladder
echo "RC=$?"
EOS

run_gate() {   # $1=sig $2=BOOT $3=已有状态 $4=DF可用KB
    rm -f "$TMPD/st" "$TMPD/log" "$TMPD/actions"
    [ -n "$3" ] && printf '%s\n' "$3" > "$TMPD/st"
    F="$TMPD/f.sh" T_TMPD="$TMPD" T_BOOT="$2" T_DF="$4" T_SIG="$1" \
        sh "$TMPD/gate.sh" 2>/dev/null | sed -n 's/^RC=//p'
}

run_ladder() {   # $1=REINSTALL $2=LAPI_UP $3=LCT_RC $4=sig $5=FIX_UP $6=ROM_OK
    rm -rf "$TMPD/st" "$TMPD/log" "$TMPD/actions" "$TMPD/rc_ask" "$TMPD/rom"
    _rom=""
    if [ "$6" = 1 ]; then mkdir -p "$TMPD/rom"; _rom="$TMPD/rom"; fi
    F="$TMPD/f.sh" T_TMPD="$TMPD" T_REINSTALL="$1" T_LAPI_UP="$2" T_LCT_RC="$3" \
        T_SIG="$4" T_FIX_UP="$5" T_ROM="$_rom" T_BOOT=bootL \
        sh "$TMPD/lad.sh" 2>/dev/null | sed -n 's/^RC=//p'
    # 「什么都没做」的用例不会生成 actions；补一个空文件，免得 grep 报错被当成「没匹配」
    [ -f "$TMPD/actions" ] || : > "$TMPD/actions"
}

# 资源门单独测：它只在 _lapi_ladder 里调用，不在 _l3_gate 里（两者职责分开）
cat > "$TMPD/res.sh" <<'EOS'
. "$F"
TMPD="$T_TMPD"; STATE_DIR="$TMPD"; OVL_UPPER="$TMPD/up"
T_DF_="$T_DF"
log() { :; }
df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/x 1000 100 %s 50%% x\n' "$T_DF_"; }
_l3_res_gate
echo "RC=$?"
EOS
run_res() {   # $1=可用KB（空=读不到）
    F="$TMPD/f.sh" T_TMPD="$TMPD" T_DF="$1" sh "$TMPD/res.sh" 2>/dev/null | sed -n 's/^RC=//p'
}

NOW=$(date +%s)
OLD_TS=$((NOW - 30000))
NEW_TS=$((NOW - 60))

ck "R34.20 三闸全空 → 放行" \
   "$(run_gate 'cfg-ok' 'bootA' '' 100000)" "0"
ck "R34.21 放行后状态写成「1 次 + 本次 boot_id」" \
   "$(grep -c '^bootA 1 ' "$TMPD/st")" "1"
ck "R34.22 同一开机第二次 → 拒绝（1 次/开机）" \
   "$(run_gate 'cfg-ok' 'bootA' "bootA 1 $NOW cfg-ok" 100000)" "1"
ck "R34.23 **恢复不刷新**：状态仍是 1 次，再跑依然拒绝" \
   "$(run_gate 'cfg-other' 'bootA' "bootA 1 $OLD_TS cfg-ok" 100000)" "1"
ck "R34.24 6 小时时间门：次数为 0 但上次丢层未满 6h → 拒绝" \
   "$(run_gate 'cfg-ok' 'bootB' "bootOld 0 $NEW_TS bad-yaml" 100000)" "1"
ck "R34.25 签名门：跨开机但同一签名且上次没修好 → 拒绝" \
   "$(run_gate 'cfg-ok' 'bootB' "bootOld 0 $OLD_TS cfg-ok" 100000)" "1"
ck "R34.26 签名变了 + 时间够 → 放行（换根因该给机会）" \
   "$(run_gate 'bad-db' 'bootB' "bootOld 0 $OLD_TS cfg-ok" 100000)" "0"
ck "R34.27 磁盘不足（<32MB）→ 资源门拒绝（重建无从谈起）" \
   "$(run_res 2048)" "1"
ck "R34.28 磁盘充足 → 资源门放行" \
   "$(run_res 100000)" "0"
ck "R34.29 磁盘读不到 → 不拦（无据不否定）" \
   "$(run_res '')" "0"
ck "R34.30 读不到 boot_id → 拒绝" \
   "$(run_gate 'cfg-ok' '' '' 100000)" "1"

echo "===== R34e. 阶梯主入口的行为（真跑） ====="
ck "R34.31 一开始 8080 就通 → 返回 0" \
   "$(run_ladder 0 1 0 'cfg-ok' 0 0)" "0"
ck "R34.32 通时不调 _lapi_cfg_test（先探再诊断，省一次 attach）" \
   "$(run_ladder 0 1 0 'cfg-ok' 0 0 >/dev/null; grep -c 'CTENV' "$TMPD/actions")" "0"
ck "R34.33 重装后重跑 → 阶梯不介入" \
   "$(run_ladder 1 0 0 'cfg-ok' 0 1)" "1"
ck "R34.34 -t 不通过 → 不丢层（actions 里没有 RMOVL）" \
   "$(run_ladder 0 0 1 'bad-yaml' 0 1 >/dev/null; grep -c 'RMOVL' "$TMPD/actions")" "0"
ck "R34.35 -t 不通过且第 2 档无效 → 返回 1" \
   "$(run_ladder 0 0 1 'bad-yaml' 0 1)" "1"
ck "R34.36 bad-yaml 处置：调了 cscli hub update" \
   "$(run_ladder 0 0 1 'bad-yaml' 0 1 >/dev/null; grep -c 'hub update' "$TMPD/actions")" "1"
ck "R34.37 bad-yaml 处置后重启了容器内 crowdsec" \
   "$(run_ladder 0 0 1 'bad-yaml' 0 1 >/dev/null; grep -c '^RESTART' "$TMPD/actions")" "1"
ck "R34.38 bad-db 处置：移走 decisions.db" \
   "$(run_ladder 0 0 1 'bad-db' 0 1 >/dev/null; grep -c 'decisions.db' "$TMPD/actions")" "1"
ck "R34.39 bad-fs 不猜处置（不重启、不丢层）" \
   "$(run_ladder 0 0 1 'bad-fs' 0 1 >/dev/null; grep -c 'RESTART\|RMOVL' "$TMPD/actions")" "0"
ck "R34.40 -t 通过 + 有基底 + 三闸空 → 丢层" \
   "$(run_ladder 0 0 0 'cfg-ok' 0 1 >/dev/null; grep -c 'RMOVL' "$TMPD/actions")" "1"
ck "R34.41 丢层后走 re-exec（不是原地继续）" \
   "$(run_ladder 0 0 0 'cfg-ok' 0 1 >/dev/null; grep -c 'REEXEC' "$TMPD/actions")" "1"
ck "R34.42 没有只读基底 → 不进第三档" \
   "$(run_ladder 0 0 0 'cfg-ok' 0 0 >/dev/null; grep -c 'RMOVL' "$TMPD/actions")" "0"
ck "R34.43 第 2 档生效 → 不丢层" \
   "$(run_ladder 0 0 1 'bad-yaml' 1 1 >/dev/null; grep -c 'RMOVL' "$TMPD/actions")" "0"
ck "R34.44 第 2 档生效后返回 0" \
   "$(run_ladder 0 0 1 'bad-yaml' 1 1)" "0"

echo "===== R34f. 版本号 ====="
ck "R34.45 版本推进到 108.61" \
   "$(grep -c 'SCRIPT_VER="2026-10-22.108.61-bp"' "$BS")" "1"

echo "------------------------------------------------------------------"
echo "R34 RESULT: $R 项失败"
exit $R
