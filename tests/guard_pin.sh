#!/bin/sh
# R33：容器配置「能固定的都固定」（v.108.60）
#
# 三件事必须同时成立，缺一件这套保护就会互相打脸：
#   ① /etc/crowdsec 从整目录白名单收窄后，构建期固定的配置（profiles / simulation /
#      scenarios / notifications / acquis.d）被改了要能复原 —— 以前它们一个字节都不设防；
#   ② 运行期必然变化的四类（hub/、config.yaml 的 online_client 两行、两本凭据、*.db）
#      必须仍然放过 —— 放不过去的表现是每 60 秒盖回一次，把 cscli 的活干废；
#   ③ config.yaml 只在 daemonize / listen_uri 不满足时复原，两态（capi 注释 / 放开）
#      都要判成「正常」—— 判错就是与 bootstrap 的 capi_block/capi_release 死循环。
#
# 这个文件同时是「白名单改动是否安全」的回归：任何把 /etc/crowdsec/* 整目录放回去的
# 改动都会让 R33.10 / R33.11 / R33.15 变红。
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
G="$REPO/files/usr/sbin/crowdsec-guard.sh"
# 不用 mktemp：本机 busybox-w32 下 $TMPDIR 为空时模板会解析成空串，
# 路径退化成 /upper、/root（真机 / 本机根目录），测试会往根上写。
TMPD="$REPO/tests/.r33.$$"
rm -rf "$TMPD"
mkdir -p "$TMPD" || { echo "无法创建临时目录 $TMPD"; exit 2; }
R=0
ck() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 got=[$2] want=[$3]"; R=$((R+1)); fi; }
cg() { grep -v '^[[:space:]]*#' "$1" | grep -c -- "$2"; }

ROM="$TMPD/rom"
RT="$TMPD/root"
UP="$TMPD/upper"
LOG="$TMPD/guard.log"
BASE="$ROM/srv/lxc/ubuntu/base"
PREFIX="/srv/lxc/ubuntu/rootfs"
CT="$RT$PREFIX"

CFG_TWO="daemonize: false
listen_uri: 0.0.0.0:8080
online_client:"

mkdir -p "$BASE/etc/crowdsec/hub/parsers" \
         "$BASE/etc/crowdsec/parsers/s01-parse" \
         "$BASE/etc/crowdsec/acquis.d" \
         "$BASE/usr/lib/crowdsec" \
         "$CT/etc/crowdsec/acquis.d" "$CT/etc/crowdsec/hub/parsers" \
         "$CT/usr/lib/crowdsec" "$UP"
printf '%s\n' "$CFG_TWO" > "$BASE/etc/crowdsec/config.yaml"
printf 'ORIGINAL-ACQ\n' > "$BASE/etc/crowdsec/acquis.yaml"
printf 'ORIGINAL-PROF\n' > "$BASE/etc/crowdsec/profiles.yaml"
printf 'ORIGINAL-SIM\n' > "$BASE/etc/crowdsec/simulation.yaml"
printf 'ORIGINAL-HUB\n' > "$BASE/etc/crowdsec/hub/parsers/x.yaml"
printf 'ORIGINAL-CRED\n' > "$BASE/etc/crowdsec/online_api_credentials.yaml"
printf 'ORIGINAL-ROUTER\n' > "$BASE/etc/crowdsec/acquis.d/router.yaml"
printf 'ORIGINAL-LIB-A\n' > "$BASE/usr/lib/crowdsec/a"
printf 'ORIGINAL-LIB-B\n' > "$BASE/usr/lib/crowdsec/b"
# 过 _ct_gate：极简 init（有 os-release + inittab，无 systemd）
printf 'ID=ubuntu\n' > "$CT/etc/os-release"
printf '::sysinit:/etc/init.d/rcS\n' > "$CT/etc/inittab"

run_g() {
    CS_GUARD_ROM="$ROM" CS_GUARD_ROOT="$RT" CS_GUARD_LOG="$LOG" \
    CS_GUARD_FILES="/nonexistent/x" CS_GUARD_LAPI_AUDIT=0 \
    CS_GUARD_CT_UPPER="$UP" sh "$G" quiet
}
reset_all() {
    rm -f "$LOG"
    rm -rf "$UP"
    mkdir -p "$UP/etc/crowdsec/hub/parsers"
    rm -f "$CT"/etc/crowdsec/*.user-* "$CT"/etc/crowdsec/*.guard-tmp 2>/dev/null
    printf '%s\n' "$CFG_TWO" > "$CT/etc/crowdsec/config.yaml"
    printf 'ORIGINAL-ACQ\n' > "$CT/etc/crowdsec/acquis.yaml"
    printf 'ORIGINAL-PROF\n' > "$CT/etc/crowdsec/profiles.yaml"
    printf 'ORIGINAL-SIM\n' > "$CT/etc/crowdsec/simulation.yaml"
    printf 'ORIGINAL-ROUTER\n' > "$CT/etc/crowdsec/acquis.d/router.yaml"
    rm -f "$CT/etc/crowdsec/online_api_credentials.yaml"
}
lg() { if [ -f "$LOG" ]; then wc -l < "$LOG" | tr -d ' '; else echo 0; fi; }

echo "== 1 config.yaml：两态都判正常、坏了才修 =="
reset_all
run_g
ck "R33.1 与基底一致时不动、不写日志" "$(lg)" "0"
ck "R33.2 一致时不产生备份" "$(ls "$CT/etc/crowdsec"/config.yaml.user-* 2>/dev/null | wc -l | tr -d ' ')" "0"

# capi_block 把 online_client 注释掉 —— 与基底不同，但这是设计内状态
reset_all
printf 'daemonize: false\nlisten_uri: 0.0.0.0:8080\n# online_client: # disabled by bootstrap\n' \
    > "$CT/etc/crowdsec/config.yaml"
run_g
ck "R33.3 capi 注释态判正常（不与 bootstrap 互斗）" "$(lg)" "0"
ck "R33.4 capi 注释态内容原样保留" \
   "$(grep -c '^# online_client:' "$CT/etc/crowdsec/config.yaml")" "1"

reset_all
printf 'daemonize: true\nlisten_uri: 0.0.0.0:8080\nonline_client:\n' \
    > "$CT/etc/crowdsec/config.yaml"
run_g
ck "R33.5 daemonize 被改回 true → 从基底复原" \
   "$(grep -c '^daemonize: false' "$CT/etc/crowdsec/config.yaml")" "1"
ck "R33.6 复原动作写日志（判据不符）" \
   "$(grep -c 'config.yaml daemonize/listen_uri 判据不符，已从只读基底复原' "$LOG" 2>/dev/null)" "1"
ck "R33.7 复原前留了一份证据" \
   "$(grep -c '^daemonize: true' "$CT/etc/crowdsec"/config.yaml.user-* 2>/dev/null | head -n1)" "1"

reset_all
printf 'daemonize: false\nlisten_uri: 127.0.0.1:8080\nonline_client:\n' \
    > "$CT/etc/crowdsec/config.yaml"
run_g
ck "R33.8 listen_uri 改成回环 → 复原成 0.0.0.0:8080" \
   "$(grep -c 'listen_uri: 0.0.0.0:8080' "$CT/etc/crowdsec/config.yaml")" "1"

reset_all
rm -f "$CT/etc/crowdsec/config.yaml"
run_g
ck "R33.9 config.yaml 被删 → 复原" \
   "$(grep -c '^daemonize: false' "$CT/etc/crowdsec/config.yaml" 2>/dev/null)" "1"

echo "== 2 收窄白名单：构造期固定的配置要能自愈 =="
reset_all
printf 'TAMPERED\n' > "$UP/etc/crowdsec/profiles.yaml"
printf 'TAMPERED\n' > "$CT/etc/crowdsec/profiles.yaml"
run_g
ck "R33.10 profiles.yaml 被改 → 按基底复原" "$(cat "$CT/etc/crowdsec/profiles.yaml")" "ORIGINAL-PROF"
ck "R33.11 审计段留下日志" "$(grep -c 'profiles.yaml 与只读基底不一致，已自动复原' "$LOG" 2>/dev/null)" "1"

echo "== 3 运行期会变的那几类必须仍然放过 =="
reset_all
printf 'TAMPERED-HUB\n' > "$UP/etc/crowdsec/hub/parsers/x.yaml"
printf 'TAMPERED-HUB\n' > "$CT/etc/crowdsec/hub/parsers/x.yaml"
run_g
ck "R33.12 hub 被 cscli 重写后不动" "$(cat "$CT/etc/crowdsec/hub/parsers/x.yaml")" "TAMPERED-HUB"
ck "R33.13 hub 不进日志" "$(cat "$LOG" 2>/dev/null | grep -c 'hub/parsers/x.yaml')" "0"

reset_all
printf 'TAMPERED-CRED\n' > "$UP/etc/crowdsec/online_api_credentials.yaml"
printf 'TAMPERED-CRED\n' > "$CT/etc/crowdsec/online_api_credentials.yaml"
run_g
ck "R33.14 CAPI 凭据被 enroll 改写后不动" \
   "$(cat "$CT/etc/crowdsec/online_api_credentials.yaml")" "TAMPERED-CRED"

echo "== 4 日志入口 acquis.yaml 进第一层（管删除，不只管修改）=="
reset_all
rm -f "$CT/etc/crowdsec/acquis.yaml"
run_g
ck "R33.15 acquis.yaml 被删 → 复原（不再走整盘重装）" \
   "$(cat "$CT/etc/crowdsec/acquis.yaml" 2>/dev/null)" "ORIGINAL-ACQ"
ck "R33.16 日志写明是被删除后复原" \
   "$(grep -c 'acquis.yaml 被删除，已从只读基准复原（容器脚本）' "$LOG" 2>/dev/null)" "1"

echo "== 4b 动了就死的配置不吃单轮上限 =="
# profiles / simulation 被改坏 → crowdsec 启动在解析阶段失败 → LAPI 直接死。
# 这类不能因为「本轮已修满 OVL_FIX_MAX 个」就跳过，所以 /etc/crowdsec 前缀豁免配额。
# 反向同时验证：豁免只给 /etc/crowdsec，/usr/lib 下的仍受上限约束。
reset_all
mkdir -p "$UP/usr/lib/crowdsec"
printf 'BROKEN-SIM\n' > "$UP/etc/crowdsec/simulation.yaml"
printf 'BROKEN-SIM\n' > "$CT/etc/crowdsec/simulation.yaml"
printf 'BROKEN-A\n' > "$UP/usr/lib/crowdsec/a"
printf 'BROKEN-A\n' > "$CT/usr/lib/crowdsec/a"
printf 'BROKEN-B\n' > "$UP/usr/lib/crowdsec/b"
printf 'BROKEN-B\n' > "$CT/usr/lib/crowdsec/b"
CS_GUARD_OVL_FIX_MAX=1 CS_GUARD_ROM="$ROM" CS_GUARD_ROOT="$RT" CS_GUARD_LOG="$LOG" \
    CS_GUARD_FILES="/nonexistent/x" CS_GUARD_LAPI_AUDIT=0 \
    CS_GUARD_CT_UPPER="$UP" sh "$G" quiet
ck "R33.17 单轮上限已满也照样复原 simulation.yaml" \
   "$(cat "$CT/etc/crowdsec/simulation.yaml")" "ORIGINAL-SIM"
ck "R33.18 非 crowdsec 路径仍受上限约束（至少一个留在坏态）" \
   "$(cat "$CT/usr/lib/crowdsec/a" "$CT/usr/lib/crowdsec/b" 2>/dev/null | grep -c '^BROKEN-' | awk '{print ($1>=1)?"yes":"no"}')" "yes"
ck "R33.19 超出上限的那条写进了日志" \
   "$(cat "$LOG" 2>/dev/null | grep -c '超出上限')" "1"

echo "== 5 静态：清单与判据不许回退 =="
ck "R33.20 acquis.yaml 在容器清单里" "$(cg "$G" '^/etc/crowdsec/acquis.yaml$')" "1"
ck "R33.21 profiles / simulation 在容器清单里（动了就死，逐字节固定）" \
   "$(cg "$G" '^/etc/crowdsec/profiles.yaml$')$(cg "$G" '^/etc/crowdsec/simulation.yaml$')" "11"
ck "R33.22 /etc/crowdsec 前缀豁免单轮上限" "$(cg "$G" '/etc/crowdsec/\*) ;;')" "1"
ck "R33.23 白名单不再整目录放过 /etc/crowdsec" \
   "$(cg "$G" '^/etc/crowdsec/\*|')" "0"
ck "R33.24 hub 仍在白名单" "$(cg "$G" '/etc/crowdsec/hub/\*')" "1"
ck "R33.25 config.yaml 仍在白名单（由结构判据管）" \
   "$(cg "$G" '/etc/crowdsec/hub/\*|/etc/crowdsec/config.yaml) continue')" "1"
ck "R33.26 config.yaml 不在 GUARD_CT_FILES（否则与 capi 逐字节互斗）" \
   "$(grep -v '^[[:space:]]*#' "$G" | sed -n '/^GUARD_CT_FILES=/,/^}/p' | grep -c '^/etc/crowdsec/config.yaml$')" "0"
ck "R33.27 _cs_cfg_audit 有定义" "$(cg "$G" '^_cs_cfg_audit() {')" "1"
ck "R33.28 _cs_cfg_audit 被调用一次" "$(cg "$G" '&& _cs_cfg_audit')" "1"
ck "R33.29 先修主配置再做整层审计" \
   "$(awk '/&& _cs_cfg_audit/{a=NR} /&& _ovl_audit/{b=NR} END{print (a>0 && b>a)?"yes":"no"}' "$G")" "yes"
ck "R33.30 判据与构建期同源：daemonize false" "$(cg "$G" "daemonize:\[\[:space:\]\]\*false")" "1"
ck "R33.31 判据与构建期同源：listen_uri 0.0.0.0:8080" \
   "$(cg "$G" '0\\.0\\.0\\.0:')" "1"

echo "R33 RESULT: $R 项失败"
# 临时目录建在 repo/tests 下（本机 mktemp 不可靠），跑完必须清掉：
# 留下 .r33.* 会被下次 git add -A 带进仓库。
rm -rf "$TMPD"
