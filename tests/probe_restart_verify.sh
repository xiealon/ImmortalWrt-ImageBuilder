#!/bin/sh
# R11：重启态逐组复验 —— 「哪个坏了修哪个」。修不好 → hard 退出 + 只读诊断，
# v.106 起不再重装（重装跑同一套脚本、同一份镜像，只会重蹈覆辙并抹掉现场证据）。
#
# 这一层挡的是三个曾经真实存在、且全都静默的缺陷：
#   ① 组级 verify/build 函数压根不存在（verify_PREP / build_PREP ...），
#      `"verify_PREP" 2>/dev/null` 报 not found 被吞掉 → 返回非 0 →
#      判「内容不符」→ 调不存在的 build_PREP → 判「修不好」→ full_reinstall。
#      结果是每次开机都抹一次容器，日志上却一切正常。
#   ② 组键大小写：置位变量叫 GSET_PREP（GROUP_SEQ 原值，全大写），读取必须同名。
#      v.103 曾把读取端 tr 成小写去读 GSET_prep，而夹具也跟着写小写 —— 夹具自己
#      伪造了现场，于是测试全绿、生产全错。v.104 起夹具一律按 ensure_group 的写法
#      造状态（大写），并加静态断言禁止读取端再做大小写转换。
#   ③ main 里残留 eval "GSET_$_g=0"：v.99 值是 V:<ts>，0 是非空值会被判成已置位。
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
BS="$REPO/files/usr/sbin/crowdsec-lxc-bootstrap.sh"
# 只含活代码的副本：整行注释（行首可有空白 + #）不算命中。
# 注释里提到某关键字（例如记录「曾经 disable lxc-auto」）不该被断言当成
# 「代码里在做这件事」，否则断言会假红或假绿。断言一律 grep 这份副本。
BS_C="$(mktemp)"
grep -v '^[[:space:]]*#' "$BS" > "$BS_C"
trap 'rm -f "$BS_C"' EXIT INT TERM
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/r11.XXXXXX")
R=0
ck() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 got=[$2] want=[$3]"; R=$((R+1)); fi; }

sh "$BS_C" --only-funcs > "$TMPD/f.sh" 2>/dev/null

echo "===== R11a. 静态：不许再调不存在的组级函数 ====="
ck "R11.1 rg_restart_verify 不再调 verify_\$组名 / build_\$组名" \
   "$(awk '/^rg_restart_verify\(\)/,/^}/' "$BS_C" | grep -cE '"(verify|build)_\$_rg?_?[gG]"')" "0"
ck "R11.2 rg_restart_verify 改成遍历节点（verify_\$_rg_n）" \
   "$(awk '/^rg_restart_verify\(\)/,/^}/' "$BS_C" | grep -c '"verify_\$_rg_n"')" "1"
ck "R11.3 节点清单取自全局 _order（与 ensure_group 同口径）" \
   "$(awk '/^rg_restart_verify\(\)/,/^}/' "$BS_C" | grep -c 'for _rg_n in \$_order')" "1"
ck "R11.4 组内按 NODE_GROUP_ 筛，不另建平行的组→节点表" \
   "$(awk '/^rg_restart_verify\(\)/,/^}/' "$BS_C" | grep -c 'NODE_GROUP_\$_rg_n')" "1"
ck "R11.5 main 里没有 eval \"GSET_...=0\" 旧写法" \
   "$(grep -cE 'eval "GSET_[^"]*=0"' "$BS_C")" "0"
ck "R11.5b rg_restart_verify 读组键时不做大小写转换（防 v.103 的错修法复发）" \
   "$(awk '/^rg_restart_verify\(\)/,/^}/' "$BS_C" | grep -cE "tr 'A-Z' 'a-z'|GSET_\\\$_rg_key")" "0"
ck "R11.5c 读的是大写 _rgG，与 ensure_group 置位同名" \
   "$(awk '/^rg_restart_verify\(\)/,/^}/' "$BS_C" | grep -c '_bs_flag_on "GSET_\$_rgG"')" "1"
ck "R11.5d 组末必须 flush_uci（否则修好的配置只活在内存里）" \
   "$(awk '/^rg_restart_verify\(\)/,/^}/' "$BS_C" | grep -c '^[[:space:]]*flush_uci')" "1"
ck "R11.5e build 成功后补 _dirty_（否则 flush_uci 判「无改动」跳过提交）" \
   "$(awk '/^rg_restart_verify\(\)/,/^}/' "$BS_C" | grep -c '_bs_flag_set "_dirty_\$_rg_n"')" "1"
ck "R11.5f 【v.106】step_C 不再调用 full_reinstall（last_pull 交给探针，修不好不重装）" \
   "$(awk '/^step_C\(\)/,/^}/' "$BS_C" | grep -c 'full_reinstall')" "0"
ck "R11.5g 【v.106】rg_restart_verify 不再调用 full_reinstall" \
   "$(awk '/^rg_restart_verify\(\)/,/^}/' "$BS_C" | grep -c 'full_reinstall')" "0"
ck "R11.5h 【v.108.17】full_reinstall 两个入口：main 的组未置位分支 + ensure 的 build 失败分支" \
   "$(grep -cE '^[[:space:]]*full_reinstall \|\|' "$BS_C")" "2"
ck "R11.5i 【v.106】main 的调用点必须紧跟在 _structurally_broken 判定之后" \
   "$(awk '/^main\(\)/,0' "$BS_C" | grep -c 'if _structurally_broken; then')" "1"
ck "R11.5j 【v.106】_structurally_broken 不看 last_pull（它不是重装理由）" \
   "$(awk '/^_structurally_broken\(\)/,/^}/' "$BS_C" | grep -c 'bouncer_pulling')" "0"
ck "R11.5k 【v.106.1】首次安装未完成不走重装（无 installed 标记提前退出）" \
   "$(awk '/^main\(\)/,0' "$BS_C" | grep -c 'if ! _stamp_present; then')" "1"
ck "R11.5l 【v.106.1】该提前退出必须排在结构性损坏判定之前（顺序不能反）" \
   "$(awk '/^main\(\)/,0' "$BS_C" | awk '/if ! _stamp_present; then/{a=NR} /if _structurally_broken; then/{b=NR} END{ if(a>0 && b>0 && a<b) print "ok"; else print "bad" }')" "ok"
# 【v.108.18】「重启之后才重置一次，首次开机不重置」拆成两道门：
#   installed 标记（_stamp_present）挡首次安装——它没写就说明流程从没跑通过，重置无从谈起；
#   boot_id 抢跑判定（_BS_FIRST_RUN）挡运行期重跑——探针 60s 触发时不是重启，只修不重置。
ck "R11.5m 【v.108.18】重置要求本次开机首跑（非首跑直接拒绝）" \
   "$(awk '/^_escalate_reinstall\(\)/,/^}/' "$BS_C" | grep -c '${_BS_FIRST_RUN:-0}')" "1"
ck "R11.5n 【v.108.19】boot_id 只有两处读取（_cur_boot_id 与 main），不散落" \
   "$(grep -c 'random/boot_id' "$BS_C")" "2"
ck "R11.5o 【v.108.18】installed 标记那道门仍在、且排在首跑门之前" \
   "$(awk '/^_escalate_reinstall\(\)/,/^}/' "$BS_C" | awk '/_stamp_present \|\|/{a=NR} /_BS_FIRST_RUN:-0/{b=NR} END{ if(a>0 && b>0 && a<b) print "ok"; else print "bad" }')" "ok"
ck "R11.5p 【v.108.18】首跑判定在每个进程里重新算（不靠环境变量跨进程传递）" \
   "$(awk '/^main\(\)/,0' "$BS_C" | grep -c '_BS_FIRST_RUN=1')" "1"
# 【v.108.19】额度门：每次开机一次。光有「首跑」不够——同一次开机里首跑失败后
# 再被拉起（探针/手动）同样要拦住，那要靠额度记账，不是靠 boot_id 比较。
ck "R11.5q 【v.108.19】重置前必须过额度门 _reset_quota_ok" \
   "$(awk '/^_escalate_reinstall\(\)/,/^}/' "$BS_C" | grep -c '_reset_quota_ok')" "1"
ck "R11.5r 【v.108.19】额度只在真正抹盘前消耗（强停之后、rm -rf 之前）" \
   "$(awk '/^full_reinstall\(\)/,/^}/' "$BS_C" | awk '/ct_force_stop \|\|/{a=NR} /_reset_consume/{b=NR} /rm -rf "\$ROOTFS"/{c=NR} END{ if(a>0 && b>a && c>b) print "ok"; else print "bad" }')" "ok"
ck "R11.5s 【v.108.19】新的一次开机把失败计数归零（不再是终身累计）" \
   "$(awk '/^main\(\)/,0' "$BS_C" | grep -c 'rm -f "\$REINSTALL_FAIL_FILE"')" "1"
ck "R11.5t 【v.108.20】未收尾的重装先看 rootfs 残留，两种情况各有处置" \
   "$(awk '/^_pending_recover\(\)/,/^}/' "$BS_C" | grep -c '_reset_consume')" "2"
ck "R11.5u 【v.108.19】额度记账用 boot_id 当键，不靠时间/次数" \
   "$(awk '/^_reset_consume\(\)/,/^}/' "$BS_C" | grep -c '\$_rc_bi')" "3"
# 【v.108.20】抹盘后断电 = rootfs 没了，重建是唯一恢复途径。把它当「又一次失败」
# 拒掉，结果就是机器永远不开机。必须先校验残留再决定。
ck "R11.5v 【v.108.20】未收尾时先校验 rootfs 残留" \
   "$(awk '/^_pending_recover\(\)/,/^}/' "$BS_C" | grep -c '_rootfs_usable')" "1"
ck "R11.5w 【v.108.20】rootfs 缺失分支不得消耗额度（保留给重建）" \
   "$(awk '/^_pending_recover\(\)/,/^}/' "$BS_C" | awk '/if _rootfs_usable; then/{if(!a)a=NR} /_reset_consume/{if(!b)b=NR} /^[[:space:]]*else$/{if(!c)c=NR} END{ if(a>0 && b>a && c>b) print "ok"; else print "bad" }')" "ok"
ck "R11.5x 【v.108.20】连续「抹盘后未收尾」有上限，超限收口" \
   "$(grep -c 'INTR_MAX' "$BS_C")" "4"
# 【v.108.21】ensure_listen_uri 曾经只有定义、零调用 —— 容器内 LAPI 只听 127.0.0.1，
# 路由器上的 bouncer 一次都拉不到，而所有容器内判据全是绿的。这类死代码必须有断言钉住。
ck "R11.5y 【v.108.21】ensure_listen_uri 必须有调用点（不许再成死代码）" \
   "$(grep -c 'ensure_listen_uri' "$BS_C" | awk '{print ($1>=2)?"ok":"bad"}')" "ok"
ck "R11.5z 【v.108.21】LAPI 就绪判据包含宿主侧探测（bouncer 的视角）" \
   "$(awk '/^verify_lapi_fetch\(\)/,/^}/' "$BS_C" | grep -c 'verify_lapi_reachable')" "1"
ck "R11.5aa 【v.108.21】build_lapi_fetch 先确保 8080 对外开放再等就绪" \
   "$(awk '/^build_lapi_fetch\(\)/,/^}/' "$BS_C" | awk '/_ensure_lapi_exposed/{a=NR} /verify_lapi_ready; then break/{b=NR} END{ if(a>0 && b>a) print "ok"; else print "bad" }')" "ok"
ck "R11.5ab 【v.108.23】listen_uri 写入归 LOGCONF，LAPI 侧留兜底，开机侧必须为 0" \
   "$(awk '/^build_logconf\(\)/,/^}/' "$BS_C" | grep -c 'ensure_listen_uri')$(awk '/^_ensure_lapi_exposed\(\)/,/^}/' "$BS_C" | grep -c 'ensure_listen_uri')$(awk '/^build_ct_boot\(\)/,/^}/' "$BS_C" | grep -c 'ensure_listen_uri')" "110"
ck "R11.5ac 【v.108.21】SCRIPT_VER 跟上版本（版本号是核对固件的唯一依据）" \
   "$(grep -c 'SCRIPT_VER="2026-10-21' "$BS_C")" "1"
# 【v.108.21】bouncer_verify 只差「首次心跳还没到」，用它把整轮引导判死会导致
# installed 永不写入 → 探针永远 wait-install。柔性节点机制必须两处都生效。
ck "R11.5ad 【v.108.21】SOFT_NODES 默认含 bouncer_verify" \
   "$(grep -c 'SOFT_NODES=.*bouncer_verify' "$BS_C")" "1"
ck "R11.5ae 【v.108.21】ensure 的 build 失败分支识别柔性节点（不 exit）" \
   "$(awk '/^ensure\(\) \{/,/^}/' "$BS_C" | grep -c '\$SOFT_NODES')" "2"
ck "R11.5af 【v.108.21】rg_restart_verify 也识别柔性节点（重启态同样不 hard）" \
   "$(awk '/^rg_restart_verify\(\)/,/^}/' "$BS_C" | grep -c '\$SOFT_NODES')" "1"
# 【v.108.22】LOGCONF 由两个节点合成一个：宿主推 + 容器采本来就是一件事的两半，
# 拆开只会让出问题时的日志变成两行互不相干的「构建执行」，看不出是哪半断的。
ck "R11.5ag 【v.108.22】LOGCONF 只剩一个节点 logconf" \
   "$(grep -c '^LOGCONF_NODES="logconf"$' "$BS_C")" "1"
ck "R11.5ah 【v.108.22】acquis / log_forward 不再是独立 DAG 节点" \
   "$(sed -n '/^DAG_NODES=/p' "$BS_C" | grep -c ' acquis \| log_forward ')" "0"
ck "R11.5ai 【v.108.22】logconf 一个节点覆盖两半（采配置 + 推配置）" \
   "$(awk '/^build_logconf\(\)/,/^}/' "$BS_C" | grep -c 'build_acquis\|build_log_forward')" "2"
# 【v.108.23】listen_uri 并进 logconf：三件事一个节点承诺，缺一不可。
ck "R11.5aj 【v.108.23】verify_logconf 逐条判三半（推/采/监听地址）" \
   "$(awk '/^verify_logconf\(\)/,/^}/' "$BS_C" | grep -c 'verify_log_forward\|verify_acquis\|verify_lapi_listen')" "3"
ck "R11.5ak 【v.108.23】listen_uri 有文件层判据（不拿进程探测当组内判据）" \
   "$(grep -c '^verify_lapi_listen() {' "$BS_C")" "1"

echo "===== R11b. 行为：哪个坏了修哪个 ====="
cat > "$TMPD/a.sh" <<'EOS'
. "$F"
log() { printf 'LOG %s\n' "$*"; }
GROUP_SEQ="PREP"
_order="br_lan_ports lan_static"
NODE_GROUP_br_lan_ports=PREP
NODE_GROUP_lan_static=PREP
GSET_PREP="V:2026-10-20 12:00:00"
verify_br_lan_ports() { return 0; }
build_br_lan_ports()  { echo "BUILD_CALLED br_lan_ports"; return 0; }
verify_lan_static()   { [ -f "$T/fixed" ]; }
build_lan_static()    { echo "BUILD_CALLED lan_static"; : > "$T/fixed"; return 0; }
flush_uci() { echo "FLUSH_CALLED"; }
full_reinstall() { echo "FULL_REINSTALL"; exit 9; }
rg_restart_verify
echo "REACHED_END"
EOS
F="$TMPD/f.sh" T="$TMPD" sh "$TMPD/a.sh" > "$TMPD/out" 2>&1
ck "R11.6 已经对的节点不去动它（build 未被调用）" \
   "$(grep -c 'BUILD_CALLED br_lan_ports' "$TMPD/out")" "0"
ck "R11.7 坏掉的节点调了一次 build 修回来" \
   "$(grep -c 'BUILD_CALLED lan_static' "$TMPD/out")" "1"
ck "R11.8 能修好就不重装" "$(grep -c 'FULL_REINSTALL' "$TMPD/out")" "0"
ck "R11.9 一路走到底（没有中途 exit）" "$(grep -c '^REACHED_END' "$TMPD/out")" "1"
ck "R11.9b 【v.105】本组修复后必须落盘（flush_uci 被调用一次）" \
   "$(grep -c 'FLUSH_CALLED' "$TMPD/out")" "1"

echo "===== R11c. 行为：修不好 → hard 退出，不重装（v.106） ====="
cat > "$TMPD/b.sh" <<'EOS'
. "$F"
log() { printf 'LOG %s\n' "$*"; }
GROUP_SEQ="PREP"
_order="br_lan_ports lan_static"
NODE_GROUP_br_lan_ports=PREP
NODE_GROUP_lan_static=PREP
GSET_PREP="V:2026-10-20 12:00:00"
verify_br_lan_ports() { return 0; }
verify_lan_static()   { return 1; }
build_lan_static()    { return 1; }
full_reinstall() { echo "FULL_REINSTALL"; exit 9; }
rg_restart_verify
echo "REACHED_END"
EOS
F="$TMPD/f.sh" sh "$TMPD/b.sh" > "$TMPD/out2" 2>&1
ck "R11.10 build 也失败 → 不重装（重装跑同一套脚本只会重蹈覆辙）" \
   "$(grep -c 'FULL_REINSTALL' "$TMPD/out2")" "0"
ck "R11.11 修不好后不再往下走" "$(grep -c '^REACHED_END' "$TMPD/out2")" "0"
ck "R11.12 日志点明是哪个节点修不好" \
   "$(grep -c '修不好：.*lan_static' "$TMPD/out2")" "1"
ck "R11.12b 修不好时先打只读诊断（现场不被抹掉）" \
   "$(grep -c '抹除前内容级复核' "$TMPD/out2")" "1"

echo "===== R11d. 行为：组未置位 / 组键大小写 ====="
cat > "$TMPD/c.sh" <<'EOS'
. "$F"
log() { printf 'LOG %s\n' "$*"; }
GROUP_SEQ="PREP"
_order="br_lan_ports"
NODE_GROUP_br_lan_ports=PREP
GSET_PREP=""                      # 组未置位
verify_br_lan_ports() { return 0; }
full_reinstall() { echo "FULL_REINSTALL"; exit 9; }
rg_restart_verify
echo "REACHED_END"
EOS
F="$TMPD/f.sh" sh "$TMPD/c.sh" > "$TMPD/out3" 2>&1
ck "R11.13 【v.106】组未置位不再重装（置位只是流程记录，不是配置真相）" \
   "$(grep -c 'FULL_REINSTALL' "$TMPD/out3")" "0"
ck "R11.13b 组未置位但节点验得过 → 一路走到底" \
   "$(grep -c '^REACHED_END' "$TMPD/out3")" "1"
# 组键大小写：GROUP_SEQ 给大写，置位变量也就必须是 GSET_PREP（同一个名字）。
# 这里给的正是「组已置位」的现场，所以不该重装。
cat > "$TMPD/d.sh" <<'EOS'
. "$F"
log() { printf 'LOG %s\n' "$*"; }
GROUP_SEQ="PREP"
_order="br_lan_ports"
NODE_GROUP_br_lan_ports=PREP
GSET_PREP="V:2026-10-20 12:00:00"
verify_br_lan_ports() { return 0; }
full_reinstall() { echo "FULL_REINSTALL"; exit 9; }
rg_restart_verify
echo "REACHED_END"
EOS
F="$TMPD/f.sh" sh "$TMPD/d.sh" > "$TMPD/out4" 2>&1
ck "R11.14 置位为 GSET_PREP 时读得到（不误判未置位）" \
   "$(grep -c 'FULL_REINSTALL' "$TMPD/out4")" "0"
ck "R11.15 组键读对后一路走到底" "$(grep -c '^REACHED_END' "$TMPD/out4")" "1"

rm -rf "$TMPD"
echo "R11 FAIL=$R"
[ "$R" = 0 ]
