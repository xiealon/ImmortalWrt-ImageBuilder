#!/bin/sh
# R34【v.108.63】：LAPI 起不来 → 再探一次 → 丢可写层；体检不验 enroll
#
# 两个缺口的现场表现：
#   A. enroll 恒被判不符 —— --verify-only 是独立进程，_ENROLL_TRIED 恒为 0，
#      于是「有注册码但还没在网页点 Accept」的机器每次体检都报不符，
#      探针每 30 轮（≈30 分钟）白跑一次完整引导，日志里看不出原因。
#   B. LAPI 起不来但文件和配置都正常 —— 各 verify 都通过、build 改不动什么，
#      hard 退出 → 探针 5 次后停手 → 机器一直坏到有人重启。
#
# v.108.63 起 B 只走一步：丢可写层回只读基底。原先的三档诊断
# （crowdsec -t / 按签名对症 / 第四道门）整段删除，所以这里也钉住「它不再回来」——
# 那套判据要跟着 crowdsec 版本改，而判错的代价是「明明能修却放过」。
#
# 本文件同时钉住「额度不会被恢复刷新」：若拿「恢复正常」当重置条件，
# 就会变成「坏→丢层→好→再坏→再丢」的周期性抹盘。
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

echo "===== R34b. 接在正确位置 ====="
ck "R34.5 _lapi_ladder 存在" \
   "$(grep -c '^_lapi_ladder()' "$BS_C")" "1"
ck "R34.6 build_lapi_fetch 调用它" \
   "$(body build_lapi_fetch "$BS_C" | grep -c '_lapi_ladder')" "1"
ck "R34.7 调用在 _ensure_lapi_exposed 之后（重启进程先试过）" \
   "$(body build_lapi_fetch "$BS_C" | awk '/_ensure_lapi_exposed/ {a=NR} /_lapi_ladder/ {b=NR} END {print (a && b && a < b) ? "yes" : "no"}')" "yes"
ck "R34.8 修好则继续读凭证，不是直接 return 0" \
   "$(body build_lapi_fetch "$BS_C" | grep -c '继续读取凭证')" "1"
ck "R34.9 自愈不依赖 enroll（出现即为越界）" \
   "$(body _lapi_ladder "$BS_C" | grep -c 'enroll')" "0"

echo "===== R34c. 三档诊断确实删干净了（不许回来） ====="
ck "R34.10 没有 crowdsec -t 诊断" \
   "$(grep -c '^_lapi_cfg_test()' "$BS_C")" "0"
ck "R34.11 没有按签名对症处置" \
   "$(grep -c '^_lapi_fix_by_sig()' "$BS_C")" "0"
ck "R34.12 没有第四道门" \
   "$(grep -c '^_l3_blame_gate()' "$BS_C")" "0"
ck "R34.13 没有出错文件提取 / 摘要 / 签名" \
   "$(grep -c '^_l3_path_of()\|^_l3_sig_of()\|^_l3_short()' "$BS_C")" "0"
ck "R34.14 不再调 cscli hub update（离线无效，丢层不需要它）" \
   "$(grep -c 'cscli hub update' "$BS_C")" "0"
ck "R34.15 主流程里没有 -t 退出码分支" \
   "$(body _lapi_ladder "$BS_C" | grep -c '_LCT_')" "0"

echo "===== R34d. 丢层执行（真跑） ====="
sh "$BS_C" --only-funcs > "$TMPD/f.sh" 2>/dev/null
[ -s "$TMPD/f.sh" ] || { echo "FATAL: --only-funcs 导出失败"; exit 2; }

# 桩脚本统一约定：可变参数走 T_ 前缀的环境变量。
# 为什么不能反过来（先设变量再 source）：--only-funcs 导出的是整个脚本前部，
# 里面那些顶层赋值（STATE_DIR / OVL_UPPER / L3_STATE / L3_MAX / L3_GAP）会把外部值全部覆盖，
# 必须 source 之后再重设一遍。
cat > "$TMPD/gate.sh" <<'EOS'
. "$F"
TMPD="$T_TMPD"; STATE_DIR="$TMPD"; L3_STATE="$TMPD/st"
OVL_UPPER="$TMPD/up"; OVL_WORK="$TMPD/wk"; REINSTALL_PENDING_FILE="$TMPD/pend"
BOOT="$T_BOOT"; DF_AVAIL="$T_DF"; NOW="$T_NOW"
L3_MAX="${T_L3MAX:-1}"; L3_GAP="${T_L3GAP:-21600}"
log() { printf '%s\n' "$*" >> "$TMPD/log"; }
date() { printf '%s\n' "$NOW"; }
_cur_boot_id() { printf '%s\n' "$BOOT"; }
df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/x 1000 100 %s 50%% %s\n' "$DF_AVAIL" "$OVL_UPPER"; }
_l3_gate
echo "RC=$?"
EOS

cat > "$TMPD/lad.sh" <<'EOS'
. "$F"
TMPD="$T_TMPD"; STATE_DIR="$TMPD"; L3_STATE="$TMPD/st"
OVL_UPPER="$TMPD/up"; OVL_WORK="$TMPD/wk"; REINSTALL_PENDING_FILE="$TMPD/pend"
ROM_BASE="$T_ROM"; BOOT="$T_BOOT"; CS_BOOTSTRAP_REINSTALL="$T_REINSTALL"
L3_MAX="${T_L3MAX:-1}"; L3_GAP="${T_L3GAP:-21600}"
log() { printf '%s\n' "$*" >> "$TMPD/log"; }
date() { printf '1700000000\n'; }
ct_running() { return 0; }
_cur_boot_id() { printf '%s\n' "$BOOT"; }
_bs_reexec() { printf 'REEXEC\n' >> "$TMPD/actions"; return 0; }
_cred_backup() { return 0; }
ct_force_stop() { printf 'STOP\n' >> "$TMPD/actions"; return 0; }
_overlay_umount() { printf 'UMOUNT\n' >> "$TMPD/actions"; return 0; }
rm() { printf 'RMOVL %s\n' "$*" >> "$TMPD/actions"; return 0; }
df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/x 1000 100 %s 50%% x\n' "$T_DF"; }
verify_lapi_reachable() { [ "$T_LAPI_UP" = 1 ]; }
_lapi_ladder
echo "RC=$?"
EOS

run_gate() {   # $1=BOOT $2=已有状态 $3=DF可用KB $4=当前时刻 ${5}=L3_MAX ${6}=L3_GAP
    rm -f "$TMPD/st" "$TMPD/log"
    [ -n "$2" ] && printf '%s\n' "$2" > "$TMPD/st"
    F="$TMPD/f.sh" T_TMPD="$TMPD" T_BOOT="$1" T_DF="$3" T_NOW="$4" \
        T_L3MAX="${5:-}" T_L3GAP="${6:-}" \
        sh "$TMPD/gate.sh" 2>/dev/null | sed -n 's/^RC=//p'
}

run_ladder() {   # $1=REINSTALL $2=LAPI_UP $3=ROM_OK ${4}=DF
    rm -rf "$TMPD/st" "$TMPD/log" "$TMPD/actions" "$TMPD/rom"
    _rom=""
    if [ "$3" = 1 ]; then
        mkdir -p "$TMPD/rom/etc/crowdsec"
        _rom="$TMPD/rom"
    fi
    F="$TMPD/f.sh" T_TMPD="$TMPD" T_REINSTALL="$1" T_LAPI_UP="$2" T_ROM="$_rom" \
        T_DF="${4-102400}" T_BOOT=bootL \
        sh "$TMPD/lad.sh" 2>/dev/null | sed -n 's/^RC=//p'
    # 「什么都没做」的用例不会生成 actions；补一个空文件，免得 grep 报错被当成「没匹配」
    [ -f "$TMPD/actions" ] || : > "$TMPD/actions"
}

ck "R34.16 再探成功 → 不丢层" \
   "$(run_ladder 0 1 1 >/dev/null; grep -c 'RMOVL' "$TMPD/actions")" "0"
ck "R34.17 再探成功 → 返回 0（继续读凭证）" \
   "$(run_ladder 0 1 1)" "0"
ck "R34.18 起不来 + 有基底 + 门过 → 丢层" \
   "$(run_ladder 0 0 1 >/dev/null; grep -c 'RMOVL' "$TMPD/actions")" "1"
ck "R34.19 丢的是 upper + work" \
   "$(body _l3_reset_overlay "$BS_C" | grep -c 'rm -rf "\$OVL_UPPER" "\$OVL_WORK"')" "1"
ck "R34.20 先强停容器再抹层（不对着活容器动手）" \
   "$(run_ladder 0 0 1 >/dev/null; awk '/STOP/{s=NR} /RMOVL/{r=NR} END{print (s&&r&&s<r)?"yes":"no"}' "$TMPD/actions")" "yes"
ck "R34.21 丢层后走 re-exec（不是原地继续）" \
   "$(run_ladder 0 0 1 >/dev/null; grep -c 'REEXEC' "$TMPD/actions")" "1"
ck "R34.22 无只读基底 → 不丢层" \
   "$(run_ladder 0 0 0 >/dev/null; grep -c 'RMOVL' "$TMPD/actions")" "0"
ck "R34.23 递归保护：丢层后重跑不再介入" \
   "$(run_ladder 1 0 1)" "1"
ck "R34.24 递归保护时不碰现场" \
   "$(run_ladder 1 0 1 >/dev/null; grep -c 'RMOVL\|STOP' "$TMPD/actions")" "0"

echo "===== R34e. 资源门 ====="
ck "R34.25 只剩 8MB → 拒" \
   "$(run_ladder 0 0 1 8192 >/dev/null; grep -c 'RMOVL' "$TMPD/actions")" "0"
ck "R34.26 只剩 100MB → 放行" \
   "$(run_ladder 0 0 1 102400 >/dev/null; grep -c 'RMOVL' "$TMPD/actions")" "1"
ck "R34.27 读不到容量 → 不拦，但记一句" \
   "$(run_ladder 0 0 1 '' >/dev/null; grep -c '无法排除磁盘满' "$TMPD/log")" "1"

echo "===== R34f. 两道门（真跑 _l3_gate） ====="
ck "R34.28 本次开机已用 1/1 → 拒" \
   "$(run_gate bootA 'bootA 1 1700000000' 999999 1700000000)" "1"
ck "R34.29 换成新 boot_id → 次数归零、放行" \
   "$(run_gate bootB 'bootA 1 1690000000' 999999 1700000000)" "0"
ck "R34.30 距上次 100 秒 → 拒（防重启循环反复抹盘）" \
   "$(run_gate bootB 'bootB 0 1699999900' 999999 1700000000)" "1"
ck "R34.31 距上次 30000 秒 → 放行" \
   "$(run_gate bootB 'bootB 0 1699970000' 999999 1700000000)" "0"
ck "R34.32 读不到 boot_id → 拒（无据不破坏）" \
   "$(run_gate '' '' 999999 1700000000)" "1"
ck "R34.33 放行后把次数与时刻写回（三字段）" \
   "$(run_gate bootB 'bootB 0 1699970000' 999999 1700000000 >/dev/null; awk '{print $1, $2, ($3>0)?"ts":"nots", NF}' "$TMPD/st")" "bootB 1 ts 3"
ck "R34.34 旧的四字段状态（带签名）仍能读，不算坏" \
   "$(run_gate bootA 'bootA 1 1700000000 deadbeef' 999999 1700000000)" "1"

echo "===== R34g. 签名门已删（它会把额度永久锁死） ====="
ck "R34.35 主流程不再传签名" \
   "$(body _lapi_ladder "$BS_C" | grep -c '_l3_gate \"')" "0"
ck "R34.36 _l3_gate 不再读签名" \
   "$(body _l3_gate "$BS_C" | grep -c 'L3_SIG')" "0"
ck "R34.37 状态文件只写三字段" \
   "$(body _l3_gate "$BS_C" | grep -c '%s %s %s')" "1"

echo "===== R34h. 丢层前把机器身份说清楚 ====="
cat > "$TMPD/cred.sh" <<'EOS'
. "$F"
ROOTFS="$T_ROOTFS"; ROM_BASE="$T_ROMBASE"
log() { printf '%s\n' "$*" >> "$T_LOG"; }
_l3_cred_delta
EOS

run_cred() {   # $1=same|diff|noa|nob → 输出对应那行日志的条数
    _d="$TMPD/cr.$1"
    rm -rf "$_d"
    mkdir -p "$_d/root/etc/crowdsec" "$_d/rom/etc/crowdsec"
    printf 'url: http://127.0.0.1:8080\nlogin: admin\n' > "$_d/root/etc/crowdsec/local_api_credentials.yaml"
    case "$1" in
    same) cp -f "$_d/root/etc/crowdsec/local_api_credentials.yaml" "$_d/rom/etc/crowdsec/local_api_credentials.yaml" ;;
    diff) printf 'url: http://127.0.0.1:8080\nlogin: other\n' > "$_d/rom/etc/crowdsec/local_api_credentials.yaml" ;;
    noa)  rm -f "$_d/root/etc/crowdsec/local_api_credentials.yaml" ;;
    nob)  : > "$_d/rom/etc/crowdsec/local_api_credentials.yaml" ;;
    esac
    : > "$_d/log"
    F="$TMPD/f.sh" T_ROOTFS="$_d/root" T_ROMBASE="$_d/rom" T_LOG="$_d/log" \
        sh "$TMPD/cred.sh" >/dev/null 2>&1
    case "$1" in
    same) grep -c '不改变机器身份' "$_d/log" ;;
    diff) grep -c 'offline 记录' "$_d/log" ;;
    noa)  grep -c '现场无凭据' "$_d/log" ;;
    nob)  grep -c '基底无凭据' "$_d/log" ;;
    esac
}

ck "R34.38 凭据与基底一致 → 明说「不改变机器身份」" "$(run_cred same)" "1"
ck "R34.39 凭据与基底不同 → 明说「可能多一条 offline 记录」" "$(run_cred diff)" "1"
ck "R34.40 现场无凭据 → 说明由基底带回" "$(run_cred noa)" "1"
ck "R34.41 基底无凭据 → 说明要重新注册" "$(run_cred nob)" "1"
ck "R34.42 丢层前先算这笔账（不是事后才知道）" \
   "$(body _l3_reset_overlay "$BS_C" | grep -c '_l3_cred_delta')" "1"

echo "===== R34i. 被拒时要说清「为什么轮不到自动修」 ====="
ck "R34.43 被拒 → 点明基底 / 宿主侧两类，转人工" \
   "$(body _lapi_ladder "$BS_C" | grep -c '基底本身有问题、宿主侧')" "1"

echo "===== R34j. 联网 cscli 超时：只有 enroll 收 5s，其余 10s（v.108.65） ====="
# 目的：这几条都要问云端，任一条无超时挂住 = 引导锁不放 + 探针 tick 全被挡。
# 唯一收到 5s 的是 console enroll：网页端不点 Accept 时它会一直等，等下去没有意义。
# 其余 5 条（console status / capi status ×3 / capi register）要的是应答内容，
# 多等几秒才有结果，卡住也不等于「网页没点」→ 维持 10s。
# 【v.108.69】原第 7 条 console enable --all 删除（它写 console.yaml，guard 60s 内
# 盖回，是互斗的死代码），R34.48 由「有 timeout 10」改为「不存在调用」的反向断言。
ck "R34.44 console enroll 带 timeout 5（唯一的 5s）" \
   "$(grep -c 'timeout 5 /usr/bin/cscli console enroll' "$BS")" "1"
# 【v.108.70】内层从 10s 收到 8s：外层 attach 也是 10s，两边同时到点会先杀
# lxc-attach，内层的 rc=124 和已经打出来的输出就全丢了。内层小 2s 先退，才带得回原因。
ck "R34.45 console status 内层 timeout 8（外层 10 留 2s 收尾）" \
   "$(grep -c 'timeout 8 \$CSCLI console status' "$BS")" "1"
ck "R34.46 capi status 三处都是 timeout 8（凭据复核 / 兜底判据 / enroll 后打印）" \
   "$(grep -c 'timeout 8 \$CSCLI capi status' "$BS")" "3"
ck "R34.47 capi register 内层 timeout 8" \
   "$(grep -c 'timeout 8 \$CSCLI capi register' "$BS")" "1"
ck "R34.47b 内层不再有 timeout 10 的 cscli（防止漏改一处）" \
   "$(grep -c 'timeout 10 \$CSCLI' "$BS")" "0"
ck "R34.48 bootstrap 已不再调用 console enable --all（v.108.69 删：写 console.yaml 与 guard 互斗）" \
   "$(grep -c "_ct_env 'timeout 10 /usr/bin/cscli console enable --all'" "$BS")" "0"
ck "R34.49 timeout 5 全文只有 1 处（不许扩散到别的命令）" \
   "$(grep -c 'timeout 5 ' "$BS")" "1"
ck "R34.50 enroll 前先等 DNS 就绪（5s 够用的前提，不能被删）" \
   "$(grep -c '_wait_capi_net 30' "$BS")" "1"

echo "===== R34k. 版本号 ====="
ck "R34.51 版本推进到 108.70" \
   "$(grep -c 'SCRIPT_VER="2026-10-24.108.70-bp"' "$BS")" "1"

echo "------------------------------------------------------------------"
echo "R34 RESULT: $R 项失败"
exit $R
