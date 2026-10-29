#!/bin/sh
# v.108.40 回归：删掉两个「用不到」的东西 —— ttyd 网页终端 + 安卓 NTP 的 dhcp domain
#
# ① dns_domain 整节点移除（26 个 DAG 节点 / 16 个 PREP 节点），三个函数一并删干净
# ② svc_bind 只剩 dropbear，ttyd 的 verify/build 全删，且不再依赖 netstat
# ③ 删了节点之后「每个节点都有 verify_/build_」「分组与 DAG 一一对应」两条不变量仍成立
#
# 为什么删 ttyd 判据：`verify_svc_bind` 原来第 ⑤ 条是
#   netstat -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]7681$"
# ImmortalWrt 默认固件通常不带 netstat 这个 applet，命令不存在 → 管道为空 → grep
# 必失败。配置写得完全正确也被判成「写了没生效」→ 收口复核 exit 1 → _stamp_write
# 不执行 → installed 永远写不下 → 每次开机全量重跑并重赌 bouncer_verify 的 60 秒窗口。
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
BS="$REPO/files/usr/sbin/crowdsec-lxc-bootstrap.sh"
BS_C="$(mktemp)"
grep -v '^[[:space:]]*#' "$BS" > "$BS_C"
trap 'rm -f "$BS_C"' EXIT INT TERM

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

DAGN=$(sed -n 's/^DAG_NODES="\(.*\)"$/\1/p' "$BS")
PREPN=$(sed -n 's/^PREP_NODES="\(.*\)"$/\1/p' "$BS")

echo "== ① dns_domain 节点已整段移除 =="
ck "R29.1 DAG_NODES 不含 dns_domain" \
   "$(echo " $DAGN " | grep -c ' dns_domain ')" "0"
ck "R29.2 PREP_NODES 不含 dns_domain" \
   "$(echo " $PREPN " | grep -c ' dns_domain ')" "0"
ck "R29.3 无 NODE_GROUP_dns_domain" \
   "$(grep -c '^NODE_GROUP_dns_domain=' "$BS")" "0"
ck "R29.4 无 DEP_dns_domain" \
   "$(grep -c '^DEP_dns_domain=' "$BS")" "0"
ck "R29.5 verify_/build_/_dns_domain_sec 三个函数都不存在" \
   "$(grep -cE '^(_dns_domain_sec|verify_dns_domain|build_dns_domain)\(\)' "$BS")" "0"
ck "R29.6 全脚本（含注释）不再提 time.android.com" \
   "$(grep -c 'time\.android' "$BS")" "0"
ck "R29.7 全脚本（含注释）不再提 203.107.6.88" \
   "$(grep -c '203\.107\.6\.88' "$BS")" "0"

echo "== ② svc_bind 只剩 dropbear，不再依赖 netstat =="
ck "R29.8 verify_svc_bind 不引用 ttyd" \
   "$(body verify_svc_bind | grep -c 'ttyd')" "0"
ck "R29.9 verify_svc_bind 不引用 netstat" \
   "$(body verify_svc_bind | grep -c 'netstat')" "0"
ck "R29.10 build_svc_bind 不引用 ttyd" \
   "$(body build_svc_bind | grep -c 'ttyd')" "0"
ck "R29.11 verify_svc_bind 仍要求 dropbear 绑 LAN 网络" \
   "$(body verify_svc_bind | grep -c 'dropbear.@dropbear\[0\].Interface')" "1"
ck "R29.12 build_svc_bind 仍写 dropbear 绑定并 commit+reload" \
   "$(body build_svc_bind | grep -c -e 'uci -q set dropbear.@dropbear\[0\].Interface' -e 'uci -q commit dropbear' -e 'init.d/dropbear reload')" "3"
ck "R29.13 verify_svc_bind 保留「无 lan zone 就放行」的豁免" \
   "$(body verify_svc_bind | grep -c '_zone_lan_network) ||')" "1"

echo "== ③ 删节点后不变量仍成立 =="
# 节点数会随版本增删，写死具体数字只会让这份测试每次改 DAG 就红一次；
# 真正该守的是「分组与 DAG 一一对应」（下面 R29.16~R29.19 那几条）。
ck "R29.14 DAG_NODES 非空且与分组行数一致" \
   "$([ "$(echo $DAGN | wc -w | tr -d ' ')" = "$(grep -cE '^NODE_GROUP_[A-Za-z0-9_]+=' "$BS")" ] && echo ok)" "ok"
ck "R29.15 PREP 的每个节点都登记为 PREP 分组" \
   "$(for _n in $PREPN; do grep -q "^NODE_GROUP_$_n=PREP$" "$BS" || echo "$_n"; done | wc -l | tr -d ' ')" "0"
ck "R29.16 NODE_GROUP 行数 = DAG 节点数" \
   "$(grep -cE '^NODE_GROUP_[A-Za-z0-9_]+=' "$BS")" "$(echo $DAGN | wc -w | tr -d ' ')"
ck "R29.17 NODE_GROUP 无重复行" \
   "$(grep -oE '^NODE_GROUP_[A-Za-z0-9_]+' "$BS" | sort | uniq -d | wc -l | tr -d ' ')" "0"
_orph=""
for _n in $DAGN; do
    grep -qE "^verify_${_n}\(\)[[:space:]]*\{" "$BS" || _orph="$_orph verify_$_n"
    grep -qE "^build_${_n}\(\)[[:space:]]*\{" "$BS" || _orph="$_orph build_$_n"
    grep -qE "^NODE_GROUP_${_n}=" "$BS" || _orph="$_orph group_$_n"
done
ck "R29.18 每个 DAG 节点都有 verify_/build_/分组（缺项列在此）" "$_orph" ""
ck "R29.19 PREP_NODES 全部在 DAG 内" \
   "$(for _n in $PREPN; do case " $DAGN " in *" $_n "*) ;; *) echo "$_n" ;; esac; done | wc -l | tr -d ' ')" "0"

echo "== ④ 脏标记清零清单跟着收窄 =="
ck "R29.20 flush_uci 的 dhcp 组脏检查只剩 dhcp_ignore" \
   "$(sed -n '/^flush_uci() {/,/^}/p' "$BS" | grep -c 'for _o in dhcp_ignore; do')" "1"
ck "R29.21 flush_uci 的 dhcp 组不再点名 dns_domain" \
   "$(sed -n '/^flush_uci() {/,/^}/p' "$BS" | grep -c 'dns_domain')" "0"
ck "R29.22 版本号已推进（形如 2026-10-29.180.191）" \
   "$(grep -cE '^SCRIPT_VER="[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\.[0-9]+\.[0-9]+"$' "$BS")" "1"

echo "-----"
if [ "$R" -eq 0 ]; then
    echo "全部通过"
else
    echo "失败 $R 条"
fi
exit "$R"
