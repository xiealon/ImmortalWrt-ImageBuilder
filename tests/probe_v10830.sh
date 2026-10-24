#!/bin/sh
# v.108.30 回归：这一版修的是「遗留项」里真能修的那几处
#   ① 探针：installed 丢了不再永远 wait-install（rootfs 在就补印重跑）
#   ② bootstrap：installed 写不进去不再 `|| true` 咽掉，按失败退出
#   ③ firewall：删完 wan 段顺手解除引用（只解引用，不删 zone）
#   ④ rc.local：锁里写 pid/ts，回收与释放都用 rm -rf（有 pid/ts 后 rmdir 必失败）
#   ⑤ uci-defaults：不再把容器名写死成 ubuntu
#   ⑥ 死代码 step_C 已删
set -u
REPO="C:/Users/Alon/Documents/JiuwenSwarm/2026-10-20/chat-1/work/REVIEW/verify"
BS="$REPO/files/usr/sbin/crowdsec-lxc-bootstrap.sh"
PR="$REPO/files/usr/sbin/crowdsec-lxc-probe.sh"
RC="$REPO/files/etc/rc.local"
UD="$REPO/files/etc/uci-defaults/98-lxc-auto.sh"

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

echo "== ① 探针补印 =="
ck "R24.1 探针有 ROOTFS 变量（CS_ROOTFS 可覆盖，测试才指得动）" \
   "$(grep -c '^ROOTFS="\${CS_ROOTFS:-\$LXC_PATH/\$LXC_NAME/rootfs}"$' "$PR")" "1"
ck "R24.2 缺印时先用 rootfs 在不在分流" \
   "$(body probe_tick "$PR" | grep -c '\[ -s "\$STAMP_FILE" \]; then')" "1"
ck "R24.3 rootfs 不在才 wait-install" \
   "$(body probe_tick "$PR" | grep -c '\[ -d "\$ROOTFS/etc" \] || { P_ACTION="wait-install"; return 0; }')" "1"
ck "R24.4 有补印分支（restamp）" \
   "$(body probe_tick "$PR" | grep -c 'P_ACTION="restamp"')" "1"
ck "R24.5 补印受冷却约束（不许每 60s 重跑整趟引导）" \
   "$(body probe_tick "$PR" | grep -c 'restamp-cooldown')" "1"
ck "R24.6 补印失败计入 P_FAIL，达阈值转 need-human" \
   "$(body probe_tick "$PR" | grep -c '补印连续 \$P_FAIL 次仍失败')" "1"
ck "R24.7 补印成功要求「退出 0 且印真的在了」" \
   "$(body probe_tick "$PR" | grep -c '\[ "\$_rs_rc" = 0 \] && \[ -s "\$STAMP_FILE" \]')" "1"
ck "R24.8 补印持锁期间写 pid/ts（陈旧锁判定要靠它）" \
   "$(body probe_tick "$PR" | grep -c 'echo "\$_rs_pid" > "\$LOCK/pid"')" "1"
ck "R24.9 wait-install 仍然保留（真的没装时不该乱跑）" \
   "$(body probe_tick "$PR" | grep -c 'P_ACTION="wait-install"')" "1"

echo "== ② installed 写失败必须失败 =="
ck "R24.10 不再 \`_stamp_write || true\`" \
   "$(grep -c '_stamp_write || true' "$BS")" "0"
ck "R24.11 写失败即 exit 1" \
   "$(grep -c 'if ! _stamp_write; then' "$BS")" "1"
ck "R24.12 失败日志说清楚后果（探针会一直等）" \
   "$(grep -c 'installed 落位失败' "$BS")" "1"

echo "== ③ firewall 引用清理 =="
ck "R24.13 有 purge_wan_refs" \
   "$(grep -c '^purge_wan_refs()' "$BS")" "1"
ck "R24.14 用 del_list 逐值解除（不是整条覆盖）" \
   "$(body purge_wan_refs "$BS" | grep -c 'uci -q del_list "firewall\.\$_pr_sec\.network=\$_pr_net"')" "1"
ck "R24.15 只解引用，不删 zone" \
   "$(body purge_wan_refs "$BS" | grep -cE 'uci -q delete "firewall\.')" "0"
ck "R24.16 有引用才动，无引用直接返回（幂等）" \
   "$(body purge_wan_refs "$BS" | grep -c '\[ -n "\$_pr_hit" \] || return 0')" "1"
ck "R24.17 改完 commit 并 reload firewall" \
   "$(body purge_wan_refs "$BS" | grep -c '/etc/init.d/firewall reload')" "1"
ck "R24.18 purge_wan_sections 会调用它，失败即失败（v.108.32 起两处：删段后 + 段已不存在时）" \
   "$(body purge_wan_sections "$BS" | grep -c 'if ! purge_wan_refs; then')" "2"

echo "== ④ rc.local 的锁 =="
ck "R24.19 抢到锁后写 pid" \
   "$(grep -c 'echo "\$\$" > "\$LOCK/pid"' "$RC")" "1"
ck "R24.20 抢到锁后写 ts" \
   "$(grep -c 'date +%s > "\$LOCK/ts"' "$RC")" "1"
ck "R24.21 残留锁回收用 rm -rf（有 pid/ts 后 rmdir 必失败）" \
   "$(grep -c 'rm -rf "\$LOCK"' "$RC")" "2"
ck "R24.22 不再用 rmdir 释放锁" \
   "$(grep -cE '^[[:space:]]*rmdir "\$LOCK"' "$RC")" "0"
ck "R24.23 日志里带上持有者 pid（卡住时能查到是谁）" \
   "$(grep -c 'pid=\$(cat "\$LOCK/pid"' "$RC")" "2"

echo "== ⑤ uci-defaults 不再写死容器名 =="
ck "R24.24 没有 name=ubuntu 这种硬写" \
   "$(grep -c 'name=ubuntu' "$UD")" "0"
ck "R24.25 名字取自 LXC_NAME（默认 ubuntu）" \
   "$(grep -c '^_LXC_NAME="\${LXC_NAME:-ubuntu}"$' "$UD")" "1"
ck "R24.26 段在时只补缺字段，不改名" \
   "$(grep -c '\[ -n "\$_cur_name" \] ||' "$UD")" "1"
ck "R24.27 无字段改动就不 commit（幂等不写盘）" \
   "$(grep -c '\[ "\$_changed" = 1 \] || exit 0' "$UD")" "1"

echo "== ⑥ 死代码 =="
ck "R24.28 step_C 已删除" \
   "$(grep -c 'step_C' "$BS")" "0"

echo "------------------------------------------------------------------"
echo "R24 RESULT: $R 项失败"
exit $R
