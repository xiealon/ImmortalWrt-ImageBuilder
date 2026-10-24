#!/bin/sh
# R31【v.108.58】：last_pull 停滞这条线，既要「修不掉时说出来」，也要「真能修掉 key 失配」
#
# 三个既有盲区，各自的现场表现：
#   A. bootstrap 退出 0 被当成「修好了」—— bouncer_verify 在 SOFT_NODES 里
#      （首启心跳有 10s 延迟，判死不合适），它失败时引导照样 exit 0。
#      于是探针 P_FAIL 永远是 0，PROBE_FAIL_ALERT 那条「需人工介入」
#      对 last_pull 停滞永远不可达：每 10 分钟重跑一轮、日志一路报喜。
#   B. 到了 need-human 也不停手 —— 这条检查原来只在补印（installed 缺失）分支有。
#   C. verify_bouncer_fill 只看本地 uci 三项（url / enabled / key 非空），
#      而「换固件丢 upper → LAPI 的 bouncer 记录清零 + /etc/config/crowdsec 被
#      sysupgrade 保留」这种最典型的失效它永远通过 → 永远不重签 → 干等 60 秒软失败。
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
BS="$REPO/files/usr/sbin/crowdsec-lxc-bootstrap.sh"
PR="$REPO/files/usr/sbin/crowdsec-lxc-probe.sh"
R=0
ck() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 got=[$2] want=[$3]"; R=$((R+1)); fi; }
body() {
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\)[[:space:]]*\\{" { inside = 1 }
        inside { print }
        inside && /^}/ { exit }
    ' "$2"
}

echo "===== R31a. 退出 0 不等于修好（A） ====="
ck "R31.1 退出 0 时再自问一次 last_pull" \
   "$(body probe_tick "$PR" | grep -c 'if \[ "\$_rc" = 0 \] && ! _boot --probe-check')" "1"
ck "R31.2 仍停滞则改写退出码，按失败计" \
   "$(body probe_tick "$PR" | grep -c '_rc=97')" "1"
ck "R31.3 日志点明根因是 SOFT 节点不参与退出码" \
   "$(body probe_tick "$PR" | grep -c 'SOFT 节点，不参与退出码')" "1"
ck "R31.4 复核必须在 P_FAIL=0 之前（顺序反了就等于没做）" \
   "$(body probe_tick "$PR" | awk '/_rc=97/ {a=NR} /P_FAIL=0/ && a && !b {b=NR} END {print (a && b && a<b) ? "yes" : "no"}')" "yes"

echo "===== R31b. 需人工介入后必须停手（B） ====="
ck "R31.5 停手分支出现在两处（补印 + 停滞）" \
   "$(body probe_tick "$PR" | grep -c 'P_ACTION="need-human-hold"')" "2"
ck "R31.6 停滞分支的停手检查在计数累加之后" \
   "$(body probe_tick "$PR" | awk '/P_STALL=\$\(\(/ {f=1} f && /P_HUMAN/ {print "yes"; exit}')" "yes"
ck "R31.7 停滞分支的停手检查在触发之前（否则仍会重跑）" \
   "$(body probe_tick "$PR" | awk '/P_HUMAN/ && !a {a=NR} /\[ "\$P_STALL" -lt "\$PROBE_STALL_ROUNDS" \]/ && a {b=NR} END {print (a && b && a<b) ? "yes" : "no"}')" "yes"

echo "===== R31c. 重签动作存在且复用既有注册逻辑（C） ====="
ck "R31.8 有 _force_resign_bouncer" \
   "$(grep -c '^_force_resign_bouncer()' "$BS")" "1"
ck "R31.9 先确认 LAPI 可用，再注册（失败别误读成 key 修不好）" \
   "$(body _force_resign_bouncer "$BS" | grep -c '_wait_lapi_ready 60')" "1"
ck "R31.10 复用 _bouncer_register_once（先删同名再 add = 作废旧 key）" \
   "$(body _force_resign_bouncer "$BS" | grep -c '_bouncer_register_once')" "1"
ck "R31.11 不自己再写一套注册逻辑（避免两处漂移）" \
   "$(body _force_resign_bouncer "$BS" | grep -c 'cscli bouncers add')" "0"
ck "R31.12 写完 key 要重启服务，进程没跑则拉起" \
   "$(body _force_resign_bouncer "$BS" | grep -c '_bouncer_service_restart')" "1"
ck "R31.13 LAPI 未就绪时如实返回失败" \
   "$(body _force_resign_bouncer "$BS" | grep -c '_wait_lapi_ready 60 || {')" "1"

echo "===== R31d. 等不到 last_pull 时才重签，且有第二窗口（C） ====="
ck "R31.14 build_bouncer_verify 会调重签（调用点唯一且在 if 里）" \
   "$(body build_bouncer_verify "$BS" | grep -c '^    if _force_resign_bouncer; then$')" "1"
ck "R31.15 重签前先确保服务在跑（进程没起来时重签无意义）" \
   "$(body build_bouncer_verify "$BS" | grep -c '^    _ensure_bouncer_service$')" "1"
ck "R31.16 重签后还给一个 60s 窗口复验（两个窗口）" \
   "$(body build_bouncer_verify "$BS" | grep -c '_w" -lt 60')" "2"
ck "R31.17 重签失败不当作通过" \
   "$(body build_bouncer_verify "$BS" | grep -c 'if _force_resign_bouncer; then')" "1"
ck "R31.18 仍不通时点明「不是 key 失配」并给出下一步" \
   "$(body build_bouncer_verify "$BS" | grep -c '不是 key 失配')" "1"
ck "R31.19 函数仍以失败收尾（不许吞掉）" \
   "$(body build_bouncer_verify "$BS" | tail -n 2 | grep -c 'return 1')" "1"

echo "===== R31e. 停手锁存必须独立且能自动解除（A 的配套） ====="
# 共用一把锁的后果：补印链路锁存后，last_pull 停滞再也不会自动修（反之亦然），
# 而两条链路的根因完全不同。而且恢复时若不清锁，自动修复等于被永久关掉。
ck "R31.20 停滞链路用自己的锁存 P_HUMAN_PULL" \
   "$(body probe_tick "$PR" | grep -c '\${P_HUMAN_PULL:-0}')" "1"
ck "R31.21 达阈值时写的是 P_HUMAN_PULL（不是共用的 P_HUMAN）" \
   "$(body probe_tick "$PR" | grep -c '^        P_HUMAN_PULL=1$')" "1"
ck "R31.22 恢复时清 P_HUMAN_PULL（锁存不许永久留着）" \
   "$(body probe_tick "$PR" | grep -c 'P_HUMAN_PULL=0')" "1"
ck "R31.23 初始化也置 0" \
   "$(grep -c '^P_HUMAN_PULL=0$' "$PR")" "1"
ck "R31.24 状态落盘与恢复都带 human_pull（跨重启仍然准确）" \
   "$(grep -c 'human_pull=' "$PR")" "2"
ck "R31.25 旧状态文件没有该键时保持 0（向后兼容，不臆造）" \
   "$(body _probe_load "$PR" | grep -c '\[ -n "\$_v" \] && P_HUMAN_PULL="\$_v"')" "1"
ck "R31.26 补印链路的 P_HUMAN 语义未被改动（仍由它自己清）" \
   "$(body probe_tick "$PR" | grep -c '^            P_HUMAN=0$')" "1"
ck "R31.27 版本号不低于 108.58（不再写死，后续 bump 不该让它红）" \
   "$(sed -n 's/^SCRIPT_VER="2026-[0-9][0-9]-[0-9][0-9]\.\([0-9][0-9]*\)\.\([0-9][0-9]*\)"$/\1 \2/p' "$BS" \
      | awk '{ if ($1 > 108 || ($1 == 108 && $2 >= 58)) print "yes"; else print "no" }')" "yes"

echo "------------------------------------------------------------------"
echo "R31 RESULT: $R 项失败"
exit $R
