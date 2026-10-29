#!/bin/sh
# v.108.28 断言：/etc/config/lxc-auto 有自己的节点 —— 容器跑着的时候也验、也补
# 背景：_ensure_lxc_auto 原来只在 build_ct_boot 里被调到，而 build_ct_boot 只在
#       「容器没跑」时才执行。于是「容器跑着 + 配置空了」这种现场完全静默。
REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
BS="$REPO/files/usr/sbin/crowdsec-lxc-bootstrap.sh"
G="$REPO/files/usr/sbin/crowdsec-guard.sh"
R=0
ck() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 got=[$2] want=[$3]"; R=$((R+1)); fi; }

echo "== 22 v.108.28：lxc-auto 配置独立成节点 =="
ck "R22.1 DAG 里有 lxc_auto 节点" \
   "$(sed -n '/^DAG_NODES=/p' "$BS" | grep -c ' lxc_auto ')" "1"
# 【v.108.47】起 lxc_auto 归 NETBASE（跟着 pkg_base 的 lxc 包走），不再走 PREP ——
# 它只碰路由器侧 uci 与 rc 链路，开机前单独跑没有意义。
ck "R22.2 分组登记为 NETBASE" \
   "$(grep -c '^NODE_GROUP_lxc_auto=NETBASE$' "$BS")" "1"
ck "R22.3 PREP 组不收它" \
   "$(sed -n '/^PREP_NODES=/p' "$BS" | grep -c ' lxc_auto ')" "0"
ck "R22.4 无依赖（只碰路由器侧 uci，不依赖 rootfs / 容器）" \
   "$(grep -c '^DEP_lxc_auto=\"\"$' "$BS")" "1"
ck "R22.5 不在 SOFT_NODES（配置写不进去要大声失败）" \
   "$(sed -n '/^SOFT_NODES=/p' "$BS" | grep -c 'lxc_auto')" "0"
ck "R22.6 verify_lxc_auto 存在" "$(grep -c '^verify_lxc_auto()' "$BS")" "1"
ck "R22.7 build_lxc_auto 存在" "$(grep -c '^build_lxc_auto()' "$BS")" "1"
ck "R22.8 判据含容器名" \
   "$(awk '/^verify_lxc_auto\(\)/,/^}/' "$BS" | grep -c 'lxc-auto.@container\[0\].name')" "1"
ck "R22.9 判据含 timeout=300" \
   "$(awk '/^verify_lxc_auto\(\)/,/^}/' "$BS" | grep -c 'container\[0\].timeout')" "1"
ck "R22.10 判据含 command 注入项" \
   "$(awk '/^verify_lxc_auto\(\)/,/^}/' "$BS" | grep -c 'container\[0\].command')" "1"
ck "R22.11 判据含服务 enabled" \
   "$(awk '/^verify_lxc_auto\(\)/,/^}/' "$BS" | grep -c 'LXC_AUTO_INIT" enabled')" "1"
ck "R22.12 配置文件不存在即判不符（不是静默通过）" \
   "$(awk '/^verify_lxc_auto\(\)/,/^}/' "$BS" | grep -c '\[ -f "\$LXC_AUTO_CFG" \] || return 1')" "1"
ck "R22.13 服务脚本受 /rom 保护：缺失即判不符，不判「不适用」" \
   "$(awk '/^verify_lxc_auto\(\)/,/^}/' "$BS" | grep -c '\[ -x "\$LXC_AUTO_INIT" \] || return 1')" "1"
ck "R22.14 判据里不再有「不适用」那种放行分支" \
   "$(awk '/^verify_lxc_auto\(\)/,/^}/' "$BS" | grep -c '_said_lxc_auto_na\|本节点不适用')" "0"
ck "R22.15 build 先给空文件当 commit 落点（并检查建不建得出来）" \
   "$(awk '/^build_lxc_auto\(\)/,/^}/' "$BS" | grep -c 'if ! ( : > "\$LXC_AUTO_CFG" ) 2>/dev/null; then')" "1"
ck "R22.15a 落点建不出来要判失败，不是接着往下走" \
   "$(awk '/^build_lxc_auto\(\)/,/^}/' "$BS" | grep -c '无法创建 \$LXC_AUTO_CFG')" "1"
ck "R22.15b 服务脚本被删时先从只读基准恢复" \
   "$(awk '/^build_lxc_auto\(\)/,/^}/' "$BS" | grep -c '_la_src="\$LXC_AUTO_ROM\$LXC_AUTO_INIT"')" "1"
ck "R22.15c 只读基准里也没有才判失败（说清是固件不带）" \
   "$(awk '/^build_lxc_auto\(\)/,/^}/' "$BS" | grep -c '这台固件不带 lxc-auto 服务')" "1"
ck "R22.16 build 交给 _ensure_lxc_auto 补写" \
   "$(awk '/^build_lxc_auto\(\)/,/^}/' "$BS" | grep -c '_ensure_lxc_auto || return 1')" "1"
ck "R22.17 build 写完自己复核（ensure 不复核）" \
   "$(awk '/^build_lxc_auto\(\)/,/^}/' "$BS" | grep -c '^    verify_lxc_auto$')" "1"
ck "R22.18 开机步仍兜一层（lxc_auto 节点被跳过也能开机）" \
   "$(awk '/^build_ct_boot\(\)/,/^}/' "$BS" | grep -c '_ensure_lxc_auto')" "1"
ck "R22.19 /etc/config/lxc-auto 仍不进 GUARD_FILES（/rom 是注释模板）" \
   "$(sed -n '/^GUARD_FILES=/,/^}\"/p' "$G" | grep -c '^/etc/config/lxc-auto$')" "0"
ck "R22.20 首启 uci-defaults 仍然写这一段" \
   "$(grep -c 'lxc-auto.@container\[-1\].name=$_LXC_NAME' "$REPO/files/etc/uci-defaults/98-lxc-auto.sh")" "1"
ck "R22.21 服务脚本路径默认仍是 /etc/init.d/lxc-auto" \
   "$(grep -c '^LXC_AUTO_INIT="\${CS_LXC_AUTO_INIT:-/etc/init.d/lxc-auto}"$' "$BS")" "1"
ck "R22.22 配置文件路径默认仍是 /etc/config/lxc-auto" \
   "$(grep -c '^LXC_AUTO_CFG="\${CS_LXC_AUTO_CFG:-/etc/config/lxc-auto}"$' "$BS")" "1"
ck "R22.24 只读基准默认是 /rom" \
   "$(grep -c '^LXC_AUTO_ROM="\${CS_LXC_AUTO_ROM:-/rom}"$' "$BS")" "1"
ck "R22.23 _ensure_lxc_auto 也走这两个变量（只有一个口径）" \
   "$(awk '/^_ensure_lxc_auto\(\)/,/^}/' "$BS" | grep -c '_ea_init="\$LXC_AUTO_INIT"')" "1"

echo "------------------------------------------------------------------"
echo "R22 RESULT: $R 项失败"
exit $R
