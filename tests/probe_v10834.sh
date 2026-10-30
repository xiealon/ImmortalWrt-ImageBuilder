#!/bin/sh
# v.108.35 回归：lxcbr0 必须先作为 device 存在，再被 lxc 接口引用
#   ① uci 里必须有 config device（name=lxcbr0 / type=bridge）
#   ② 顺序必须是 device → 内核建 → interface 引用，不能反过来
#   ③ lxc 接口的 option device 必须指向 lxcbr0
#   ④ ip link add 失败时不许写 interface（写个指向不存在设备的接口更糟）
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

echo "== ① 静态：device 段 =="
ck "R27.1 build 声明 network.lxcbr0=device" \
   "$(body build_bridge | grep -c "uci -q set network.lxcbr0='device'")" "1"
ck "R27.2 device 名字是 lxcbr0" \
   "$(body build_bridge | grep -c "uci -q set network.lxcbr0.name='lxcbr0'")" "1"
ck "R27.3 device 类型是 bridge" \
   "$(body build_bridge | grep -c "uci -q set network.lxcbr0.type='bridge'")" "1"
ck "R27.4 verify 验段类型是 device" \
   "$(body verify_bridge | grep -c '\[ "\$(run uci -q get network.lxcbr0)" = "device" \]')" "1"
ck "R27.5 verify 验 name=lxcbr0" \
   "$(body verify_bridge | grep -c 'run uci -q get network.lxcbr0.name 2>/dev/null)" = "lxcbr0"')" "1"
ck "R27.6 verify 验 type=bridge" \
   "$(body verify_bridge | grep -c 'run uci -q get network.lxcbr0.type 2>/dev/null)" = "bridge"')" "1"
ck "R27.6a build 写 bridge_empty=1（空网桥不设就不会被创建）" \
   "$(body build_bridge | grep -c "uci -q set network.lxcbr0.bridge_empty='1'")" "1"
ck "R27.6b build 判据含 bridge_empty" \
   "$(body build_bridge | grep -c 'network.lxcbr0.bridge_empty 2>/dev/null)" != "1"')" "1"
ck "R27.6c verify 验 bridge_empty=1" \
   "$(body verify_bridge | grep -c 'run uci -q get network.lxcbr0.bridge_empty 2>/dev/null)" = "1"')" "1"

echo "== ② 静态：lxc 接口必须引用这个 device =="
ck "R27.7 build 写 network.lxc.device=lxcbr0" \
   "$(body build_bridge | grep -c "uci -q set network.lxc.device='lxcbr0'")" "1"
ck "R27.8 build 判据里含 device 校验（被改回别处会重写）" \
   "$(body build_bridge | grep -c 'network.lxc.device 2>/dev/null)" != "lxcbr0"')" "1"
ck "R27.9 verify 验 interface.device=lxcbr0" \
   "$(body verify_bridge | grep -c 'run uci -q get network.lxc.device 2>/dev/null)" = "lxcbr0"')" "1"

echo "== ③ 静态：顺序 device → 建 → interface =="
_dn=$(body build_bridge | grep -n 'uci -q set network.lxcbr0=' | head -1 | cut -d: -f1)
_in=$(body build_bridge | grep -n 'uci -q set network.lxc=' | head -1 | cut -d: -f1)
_ln=$(body build_bridge | grep -n 'ip link add lxcbr0' | head -1 | cut -d: -f1)
ck "R27.10 device 段写在 interface 段之前" "$([ "$_dn" -lt "$_in" ] && echo yes || echo no)" "yes"
ck "R27.11 内核建网桥在 interface 段之前" "$([ "$_ln" -lt "$_in" ] && echo yes || echo no)" "yes"

echo "== ④ 静态：失败必须说出来 =="ck "R27.12 建不出来返回 1" \
   "$(body build_bridge | grep -c '无法创建 lxcbr0')" "1"
ck "R27.13 up 失败有日志" \
   "$(body build_bridge | grep -c 'lxcbr0 up 失败')" "1"
ck "R27.14 地址写入失败会复核再判" \
   "$(body build_bridge | grep -c 'lxcbr0 地址写入失败')" "1"

echo "== ④b 开机口径：首次与重启都「先验证、缺则补」 =="
ck "R27.14a 首次装机豁免不覆盖 bridge（只认 bouncer_verify）" \
   "$(body _post_verify_skip | grep -c 'bouncer_verify')" "1"
ck "R27.14b 首次装机豁免的判定值不出现 bridge" \
   "$(body _post_verify_skip | grep -c 'bridge')" "0"
ck "R27.14c 收口复核按 verify_ 前缀逐节点（bridge 在其中）" \
   "$(body _post_verify_confirm | grep -c '^        "verify_\$1" 2>/dev/null && return 0$')" "1"
ck "R27.14d 重启态同样走 verify→build，无白名单" \
   "$(body rg_restart_verify | grep -c 'verify_')" "1"
ck "R27.14e bridge 在 DAG 节点表里（重启与体检都会走到它）" \
   "$(grep -c '^DAG_NODES=.*bridge' "$BS")" "1"

echo "== ⑤ 行为：缺配置时写入，齐全时不动 =="
T=$(mktemp -d)
OPS="$T/ops"; LOG="$T/log"; KV="$T/kv"
: > "$OPS"; : > "$LOG"; : > "$KV"

log() { echo "$*" >> "$LOG"; }
_net_write_guard() { :; }
# 代码里的 uci / ip 调用全都包在 run 里（带 timeout）。不 mock 这一层，
# run 会去找进程而看不到上面的 shell 函数，build_bridge 会一路失败。
run() { "$@"; }
run_svc() { "$@"; }
RUN_TIMEOUT=60
SVC_TIMEOUT=60
BRIDGE_IP="10.1.0.1"

uci() {
    case "$*" in
        "-q get network.lxc.proto") sed -n "s/^network\.lxc\.proto=//p" "$KV" ;;
        "-q get network.lxc.ipaddr") sed -n "s/^network\.lxc\.ipaddr=//p" "$KV" ;;
        "-q get network.lxc.netmask") sed -n "s/^network\.lxc\.netmask=//p" "$KV" ;;
        "-q get network.lxc.device") sed -n "s/^network\.lxc\.device=//p" "$KV" ;;
        "-q get network.lxcbr0") grep -q '^network\.lxcbr0=device$' "$KV" && echo device ;;
        "-q get network.lxcbr0.type") sed -n "s/^network\.lxcbr0\.type=//p" "$KV" ;;
        "-q get network.lxcbr0.name") sed -n "s/^network\.lxcbr0\.name=//p" "$KV" ;;
        "-q get network.lxcbr0.bridge_empty") sed -n "s/^network\.lxcbr0\.bridge_empty=//p" "$KV" ;;
        "-q set "*)
            _kv=${*#-q set }
            _kv=$(printf '%s' "$_kv" | tr -d "'")
            echo "$_kv" >> "$OPS"
            echo "$_kv" >> "$KV"
            ;;
    esac
    return 0
}
ip() {
    case "$*" in
        "link show lxcbr0") return 0 ;;
        "link set lxcbr0 up") return 0 ;;
        "-4 addr show lxcbr0") echo "    inet $BRIDGE_IP/24 brd 10.1.0.255 scope global lxcbr0" ;;
    esac
    return 0
}
eval "$(body build_bridge)"

build_bridge
ck "R27.15 首次执行返回 0" "$?" "0"
ck "R27.16 写了 device 段" "$(grep -c '^network.lxcbr0=device$' "$OPS")" "1"
ck "R27.17 写了 type=bridge" "$(grep -c '^network.lxcbr0.type=bridge$' "$OPS")" "1"
ck "R27.18 写了 name=lxcbr0" "$(grep -c '^network.lxcbr0.name=lxcbr0$' "$OPS")" "1"
ck "R27.18a 写了 bridge_empty=1" "$(grep -c '^network.lxcbr0.bridge_empty=1$' "$OPS")" "1"
ck "R27.19 lxc 接口引用了 lxcbr0" "$(grep -c '^network.lxc.device=lxcbr0$' "$OPS")" "1"
_wd=$(grep -n '^network.lxcbr0=' "$OPS" | head -1 | cut -d: -f1)
_wi=$(grep -n '^network.lxc=' "$OPS" | head -1 | cut -d: -f1)
ck "R27.20 写入顺序：device 段在 interface 之前" "$([ "$_wd" -lt "$_wi" ] && echo yes || echo no)" "yes"

: > "$OPS"
build_bridge
ck "R27.21 配置已齐全时零写入" "$(wc -l < "$OPS" | tr -d ' ')" "0"

echo "== ⑥ 行为：建不出网桥时不写 interface =="
: > "$OPS"; : > "$KV"
ip() {
    case "$*" in
        "link show lxcbr0") return 1 ;;
        "link add lxcbr0 type bridge") return 1 ;;
    esac
    return 0
}
build_bridge
ck "R27.22 建不出网桥返回 1" "$?" "1"
ck "R27.23 没有写 interface 段（不引用不存在的设备）" "$(grep -c '^network.lxc=' "$OPS")" "0"
ck "R27.24 拒绝理由写进日志" "$(grep -c '无法创建 lxcbr0' "$LOG")" "1"

rm -rf "$T"
echo "----"
if [ "$R" -eq 0 ]; then echo "ALL PASS"; else echo "FAILED: $R"; fi
exit "$R"
