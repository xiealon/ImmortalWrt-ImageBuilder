#!/bin/sh
# v.108.32 回归：WAN 面锁死
#   ① purge_wan_sections 幂等 —— 段早就删过的机器也要清 firewall 引用
#   ② firewall 引用解析抽成 _wan_refs，purge 与 audit 共用一份（不许各写一套）
#   ③ audit_wan_purged 从「只验网络段」扩到「段 / 引用 / 内核接口」三条
#   ④ 全脚本没有创建 wan 段的路径（静态锁：谁写回来谁挂测试）
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
FILES_DIR="${CS_FILES_DIR:-files-24}"
BS="$REPO/$FILES_DIR/usr/sbin/crowdsec-lxc-bootstrap.sh"

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
    ' "$BS"
}

T=$(mktemp -d)
UCI_NET="$T/net"
UCI_FW="$T/fw"
OPS="$T/ops"
LOG="$T/log"
: > "$OPS"
: > "$LOG"

log() { echo "$*" >> "$LOG"; }
_net_reload() { echo "RELOAD network" >> "$OPS"; }
# bootstrap 里的外部调用统一包在 run / run_svc 里（带 timeout）。这两个包装函数
# 必须一起 mock：不 mock 的话 run 会去执行真实的 uci（测试里的 uci 只是 shell 函数，
# timeout 子进程看不到它）—— 轻则 RUN_TIMEOUT 为空报错、断言全红，重则真改设备配置。
run() { "$@"; }
run_svc() { "$@"; }
RUN_TIMEOUT=60
SVC_TIMEOUT=60

# ---- uci mock：读两个文件，写操作记到 $OPS，delete/del_list 真的改文件 ----
uci() {
    case "$*" in
        "-q show network."*)
            _k=${*#-q show }
            grep "^$_k=" "$UCI_NET" 2>/dev/null
            return 0 ;;
        "show network")
            cat "$UCI_NET"; return 0 ;;
        "show firewall")
            cat "$UCI_FW"; return 0 ;;
        "-q delete network."*)
            _d=${*#-q delete }
            grep -v "^$_d=" "$UCI_NET" > "$UCI_NET.n" 2>/dev/null
            mv -f "$UCI_NET.n" "$UCI_NET" 2>/dev/null
            echo "DELETE $_d" >> "$OPS"
            return 0 ;;
        "-q del_list "*)
            echo "DELLIST ${*#-q del_list }" >> "$OPS"
            return 0 ;;
        "-q commit "*)
            echo "COMMIT ${*#-q commit }" >> "$OPS"
            return 0 ;;
    esac
    return 0
}

eval "$(body _wan_sections)"
eval "$(body _wan_ifaces)"
eval "$(body _wan_refs)"
eval "$(body purge_wan_refs)"
eval "$(body purge_wan_sections)"

reset_env() {
    : > "$OPS"
    : > "$LOG"
}

echo "== ① 结构：一份解析，两处使用 =="
ck "R25.1 有 _wan_refs 公共解析" \
   "$(grep -c '^_wan_refs()' "$BS")" "1"
ck "R25.2 purge_wan_refs 改用 _wan_refs，不再自己解析" \
   "$(body purge_wan_refs | grep -c '_pr_hit=$(_wan_refs)')" "1"
ck "R25.3 purge_wan_refs 里不再残留自己的 sed 解析" \
   "$(body purge_wan_refs | grep -c 'sed -n')" "0"
ck "R25.4 有 _wan_ifaces（内核接口判据）" \
   "$(grep -c '^_wan_ifaces()' "$BS")" "1"
ck "R25.5 内核判据看 /sys/class/net，不调 ip/ifconfig" \
   "$(body _wan_ifaces | grep -c '/sys/class/net/\$_wi')$(body _wan_ifaces | grep -cE '(^|[^-])ip (link|addr)')" "10"

echo "== ② 幂等：段已删的机器也要清引用 =="
reset_env
printf "network.lan=interface\n" > "$UCI_NET"
printf "firewall.@zone[1]=zone\nfirewall.@zone[1].network='wan' 'wan6'\n" > "$UCI_FW"
purge_wan_sections
ck "R25.6 段不存在时返回 0" "$?" "0"
ck "R25.7 段不存在也会去解引用（DELLIST wan）" \
   "$(grep -c 'DELLIST firewall.@zone\[1\].network=wan$' "$OPS")" "1"
ck "R25.8 段不存在也会去解引用（DELLIST wan6）" \
   "$(grep -c 'DELLIST firewall.@zone\[1\].network=wan6' "$OPS")" "1"
ck "R25.9 解除后 commit firewall" \
   "$(grep -c '^COMMIT firewall$' "$OPS")" "1"
ck "R25.10 日志不再说「无需动作」（它确实动了）" \
   "$(grep -c '无需删段' "$LOG")" "1"

reset_env
printf "network.lan=interface\n" > "$UCI_NET"
printf "firewall.@zone[0]=zone\nfirewall.@zone[0].network='lan' 'lxc'\n" > "$UCI_FW"
purge_wan_sections
ck "R25.11 无引用时仍然返回 0（幂等，不许因为没活干就失败）" "$?" "0"
ck "R25.12 无引用时不产生任何写操作" "$(wc -l < "$OPS" | tr -d ' ')" "0"

echo "== ③ 真删段：先删后清，顺序不许反 =="
reset_env
printf "network.lan=interface\nnetwork.wan=interface\nnetwork.wan6=interface\n" > "$UCI_NET"
printf "firewall.@zone[1]=zone\nfirewall.@zone[1].network='wan' 'wan6'\n" > "$UCI_FW"
purge_wan_sections
ck "R25.13 有段时返回 0" "$?" "0"
ck "R25.14 两个段都 delete 了" \
   "$(grep -c '^DELETE network.wan$' "$OPS")$(grep -c '^DELETE network.wan6$' "$OPS")" "11"
ck "R25.15 commit network 一次" \
   "$(grep -c '^COMMIT network$' "$OPS")" "1"
ck "R25.16 删完 reload 网络" \
   "$(grep -c '^RELOAD network$' "$OPS")" "1"
ck "R25.17 引用清理排在删段之后（DELLIST 在 DELETE 之后）" \
   "$(awk '/^DELETE network.wan$/{d=NR} /^DELLIST /{if(!x)x=NR} END{print (d && x && x>d) ? "yes" : "no"}' "$OPS")" "yes"

reset_env
printf "network.lan=interface\nnetwork.wan=interface\n" > "$UCI_NET"
printf "firewall.@zone[1]=zone\n" > "$UCI_FW"
purge_wan_sections
ck "R25.18 第二遍跑（段已没了）不重复 commit network" \
   "$(grep -c '^COMMIT network$' "$OPS")" "1"

echo "== ④ audit 三项一起验 =="
ck "R25.19 audit 验网络段" \
   "$(awk '/^audit_wan_purged\(\)/,/^}/' "$BS" | grep -c '\[ -z "\$(_wan_sections)" \] || return 1')" "1"
ck "R25.20 audit 验 firewall 引用" \
   "$(awk '/^audit_wan_purged\(\)/,/^}/' "$BS" | grep -c '\[ -z "\$(_wan_refs)" \] || return 1')" "1"
ck "R25.21 audit 验内核接口" \
   "$(awk '/^audit_wan_purged\(\)/,/^}/' "$BS" | grep -c '\[ -z "\$(_wan_ifaces)" \] || return 1')" "1"
ck "R25.22 audit 仍然先判 network 可解析" \
   "$(awk '/^audit_wan_purged\(\)/,/^}/' "$BS" | grep -c 'uci show network >/dev/null 2>&1 || return 1')" "1"

eval "$(awk '/^audit_wan_purged\(\)/,/^}/' "$BS")"
reset_env
printf "network.lan=interface\n" > "$UCI_NET"
printf "firewall.@zone[0].network='lan'\n" > "$UCI_FW"
audit_wan_purged
ck "R25.23 干净机器判 OK" "$?" "0"
printf "firewall.@zone[1].network='wan' 'wan6'\n" > "$UCI_FW"
audit_wan_purged
ck "R25.24 只剩 firewall 引用也判不符（旧版会报绿）" "$?" "1"

echo "== ⑤ 静态锁：全脚本没有创建 wan 的路径 =="
ck "R25.25 没有 uci set network.wan" \
   "$(grep -c 'uci [^|]*set[[:space:]]*"\?network\.wan' "$BS")" "0"
ck "R25.26 没有 uci add network wan" \
   "$(grep -c 'add[[:space:]]*"\?network"\?[[:space:]]*"\?wan' "$BS")" "0"
ck "R25.27 没有 network.wan=interface 这种造段写法" \
   "$(grep -c 'network\.wan=interface' "$BS")" "0"
ck "R25.28 DAG 里没有 wan 节点" \
   "$(grep -c '^DAG_NODES=".*wan' "$BS")" "0"
ck "R25.29 PREP 里没有 wan 节点" \
   "$(grep -c '^PREP_NODES=".*wan' "$BS")" "0"
ck "R25.30 版本号已推进（形如 2026-10-29.180.191）" \
   "$(grep -cE '^SCRIPT_VER="[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\.[0-9]+\.[0-9]+"$' "$BS")" "1"

echo "== ⑥ 收口：一轮跑完再验一次，不合规就自己清 =="
ck "R25.31 有收口复核（_wan_hard_ok）" \
   "$(grep -c '^    _wan_hard_ok=true$' "$BS")" "1"
ck "R25.32 收口判据含段与引用两项" \
   "$(grep -c '^    \[ -z "\$(_wan_sections)" \] || _wan_hard_ok=false$' "$BS")$(grep -c '^    \[ -z "\$(_wan_refs)" \] || _wan_hard_ok=false$' "$BS")" "11"
ck "R25.33 收口不符就再 purge 一次" \
   "$(awk '/^    # 【v.108.32】WAN 面收口/,/收口复核已恢复/' "$BS" | grep -c 'purge_wan_sections')" "1"
ck "R25.34 清理后仍不符按失败退出" \
   "$(awk '/^    # 【v.108.32】WAN 面收口/,/收口复核已恢复/' "$BS" | grep -c 'exit 1')" "2"
ck "R25.35 收口排在 _stamp_write 之前（没锁住就不许盖章）" \
   "$(awk '/WAN 面收口/{a=NR} /if ! _stamp_write; then/{b=NR} END{print (a && b && a<b) ? "yes" : "no"}' "$BS")" "yes"
ck "R25.36 内核接口只报不判死（reload 异步，不能卡在这）" \
   "$(awk '/WAN 面收口/,/收口复核已恢复/' "$BS" | grep -c '_wan_ifaces')" "0"

rm -rf "$T"
echo "----"
if [ "$R" -eq 0 ]; then
    echo "ALL PASS"
else
    echo "FAILED: $R"
fi
exit "$R"
