#!/bin/sh
# v.108.37 回归：把「写了没验」的漏项补上，并把覆盖率本身做成断言
#   ① verify_bridge 补 netmask（build 写了，verify 原来不看）
#   ② verify_docker_fw 补段类型 zone（段类型坏了 fw4 根本不认这个 zone）
#   ③ 机制化：build_ 里每个固定 uci key，verify_ 必须读过 —— 以后加字段漏验，这里直接红
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
FILES_DIR="${CS_FILES_DIR:-files}"
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

echo "== ① 逐个补上的漏项 =="
ck "R28.1 verify_bridge 验 netmask" \
   "$(body verify_bridge | grep -c 'network.lxc.netmask 2>/dev/null)" = "255.255.255.0"')" "1"
ck "R28.2 verify_docker_fw 验段类型=zone" \
   "$(body verify_docker_fw | grep -c '\[ "\$(run uci -q get firewall.docker 2>/dev/null)" = "zone" \]')" "1"

echo "== ② 覆盖率：build 写的固定 key 必须被 verify 读到 =="
T=$(mktemp -d)
cov_node() {
    _n=$1
    body "build_$_n" > "$T/b.txt"
    body "verify_$_n" > "$T/v.txt"
    sed -n 's/.*uci -q set \(["]*[A-Za-z0-9_.@\[\]-]*\)["]*=.*/\1/p' "$T/b.txt" | sort -u > "$T/k.txt"
    _miss=""
    while read -r k; do
        [ -z "$k" ] && continue
        grep -qF "uci -q get $k" "$T/v.txt" || _miss="$_miss $k"
    done < "$T/k.txt"
    printf '%s' "${_miss:-OK}"
}
i=0
for n in bridge docker_fw lan_static dhcp_ignore fwd_rules lxc_auto br_lan_ports; do
    i=$((i + 1))
    ck "R28.3.$i $n 的 key 全覆盖" "$(cov_node "$n")" "OK"
done

echo "== ③ 版本 =="
ck "R28.4 版本号已推进（形如 2026-10-29.180.191）" \
   "$(grep -cE '^SCRIPT_VER="[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\.[0-9]+\.[0-9]+"$' "$BS")" "1"

rm -rf "$T"
echo "----"
if [ "$R" -eq 0 ]; then echo "ALL PASS"; else echo "FAILED: $R"; fi
exit "$R"
