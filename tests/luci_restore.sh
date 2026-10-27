#!/bin/sh
# R33【v.180.116】：luci-app-smartdns 界面的「缺则从只读基座补回」
#
# 与 smartdns 本体（_smartdns_installed + pkg_base ①②）的区别，是这一段的全部理由：
#   本体是功能闸门 —— 缺了整轮引导就该停，所以它进 _pkg_missing_all；
#   界面不是 —— 脚本一行都不依赖它（只用 uci + /usr/sbin/smartdns + init.d），
#   所以它单独判（_luci_smartdns_ok）、单独补（_rom_restore_luci_smartdns），
#   只挂在 pkg_base 里顺路做，失败也只记一条日志，绝不判节点失败。
#
# 覆盖两个最容易写错、错了又很难看出来的点：
#   1. 固件压根没编界面时，必须静默通过 —— 老固件（/rom 里没有 luci-app-smartdns.list）
#      就是这样，若不判这一条，每轮引导都会白恢复一次、每次都在日志里留一行「缺」。
#   2. 恢复只拷 luci-app-smartdns 自己的文件，不递归它的 Depends ——
#      那里面有 luci-base，递归进去会一路碰 rpcd / ubus / ucode，那是基础系统。
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
BS="$REPO/files/usr/sbin/crowdsec-lxc-bootstrap.sh"

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

echo "== 33.1 函数与调用点 =="
ck "R33.1a 有 _luci_smartdns_ok 定义" \
   "$(grep -c '^_luci_smartdns_ok()' "$BS")" "1"
ck "R33.1b 有 _rom_restore_luci_smartdns 定义" \
   "$(grep -c '^_rom_restore_luci_smartdns()' "$BS")" "1"
ck "R33.1c verify_pkg_base 调 _luci_smartdns_ok" \
   "$(body verify_pkg_base "$BS" | grep -c '_luci_smartdns_ok')" "1"
ck "R33.1d build_pkg_base 调 _rom_restore_luci_smartdns" \
   "$(body build_pkg_base "$BS" | grep -c '_rom_restore_luci_smartdns')" "2"

echo
echo "== 33.2 界面绝不进功能闸门 =="
# 这是本段最要紧的约束：一旦 luci 混进 _pkg_missing_all，界面被卸就会把 pkg_base
# 判成硬失败，经 _structurally_broken 把整轮引导带走 —— 代价和收益完全不成比例。
ck "R33.2a _pkg_missing_all 里没有 luci" \
   "$(body _pkg_missing_all "$BS" | grep -ci 'luci')" "0"
ck "R33.2b _lxc_missing_deps 里没有 luci" \
   "$(body _lxc_missing_deps "$BS" | grep -ci 'luci')" "0"
# 恢复函数必须直连 _rom_restore_pkg，不得走 _rom_restore_tree（递归 luci-base）
ck "R33.2c 恢复不递归依赖（无 _rom_restore_tree）" \
   "$(body _rom_restore_luci_smartdns "$BS" | grep -c '_rom_restore_tree')" "0"
ck "R33.2d 恢复只拷本包（调 _rom_restore_pkg luci-app-smartdns）" \
   "$(body _rom_restore_luci_smartdns "$BS" | grep -c '_rom_restore_pkg luci-app-smartdns')" "1"

echo
echo "== 33.3 动态：判据四种情形 =="
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/luci.XXXXXX") || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMPD"' EXIT

LIB="$TMPD/fns.sh"
: > "$LIB"
for _f in _luci_smartdns_ok _rom_restore_luci_smartdns _rom_restore_pkg; do
    body "$_f" "$BS" >> "$LIB"
    if [ "$(wc -l < "$LIB")" -eq 0 ]; then
        echo "FAIL: 抽不到函数 $_f"
        exit 1
    fi
done

# 只读基座（模拟 /rom）：固件里编了界面
ROM="$TMPD/rom"
mkdir -p "$ROM/usr/lib/opkg/info" "$ROM/usr/share/luci/menu.d" "$ROM/usr/libexec"
printf '{}\n' > "$ROM/usr/share/luci/menu.d/luci-app-smartdns.json"
printf '#!/bin/sh\nexit 0\n' > "$ROM/usr/libexec/smartdns-call"
cat > "$ROM/usr/lib/opkg/info/luci-app-smartdns.list" <<'LIST'
/usr/share/luci/menu.d/luci-app-smartdns.json
/usr/libexec/smartdns-call
/etc/config/smartdns
LIST
# 当前系统根（模拟 /）
ROOT="$TMPD/root"
mkdir -p "$ROOT"

log() { printf '    [log] %s\n' "$*"; }
ROMDIR="$ROM"
PKGROOT="$ROOT"
. "$LIB"

# A 固件编了、系统里没有 -> 判缺
_luci_smartdns_ok
ck "R33.3a 固件有清单 + 系统缺 -> 判缺(1)" "$?" "1"

# B 界面在位（两个文件都在）-> 通过
mkdir -p "$ROOT/usr/share/luci/menu.d" "$ROOT/usr/libexec"
cp "$ROM/usr/share/luci/menu.d/luci-app-smartdns.json" "$ROOT/usr/share/luci/menu.d/"
cp "$ROM/usr/libexec/smartdns-call" "$ROOT/usr/libexec/"
_luci_smartdns_ok
ck "R33.3b 两个文件都在 -> 通过(0)" "$?" "0"

# C 残缺：只有 menu.d，没有 smartdns-call -> 仍判缺（能点开、点了没反应比没菜单更误导）
rm -f "$ROOT/usr/libexec/smartdns-call"
_luci_smartdns_ok
ck "R33.3c 只剩 menu.d、缺 smartdns-call -> 判缺(1)" "$?" "1"

# D 固件压根没编（/rom 无清单）-> 不归本节点管，静默通过
mv "$ROM/usr/lib/opkg/info/luci-app-smartdns.list" "$TMPD/list.bak"
rm -f "$ROOT/usr/share/luci/menu.d/luci-app-smartdns.json"
_luci_smartdns_ok
ck "R33.3d /rom 无清单 -> 不算缺(0)，不白恢复" "$?" "0"
mv "$TMPD/list.bak" "$ROM/usr/lib/opkg/info/luci-app-smartdns.list"

echo
echo "== 33.4 动态：从只读基座恢复 =="
rm -rf "$ROOT"
mkdir -p "$ROOT"
_out=$(_rom_restore_luci_smartdns)
_r=$?
ck "R33.4a 恢复成功返回 0" "$_r" "0"
ck "R33.4b menu.d 已补回" \
   "$([ -f "$ROOT/usr/share/luci/menu.d/luci-app-smartdns.json" ] && echo yes || echo no)" "yes"
ck "R33.4c smartdns-call 已补回 且可执行位跟着来" \
   "$([ -x "$ROOT/usr/libexec/smartdns-call" ] && echo yes || echo no)" "yes"
# 用户配置一律不动：/etc/config/smartdns 在清单里，但必须被跳过
ck "R33.4d /etc/config/smartdns 没被拷进来" \
   "$([ -e "$ROOT/etc/config/smartdns" ] && echo yes || echo no)" "no"
ck "R33.4e 日志点明恢复的包和文件数" \
   "$(printf '%s' "$_out" | grep -c '从只读基座恢复 luci-app-smartdns：2 个文件')" "1"

# F /rom 没有清单时不去动系统
mv "$ROM/usr/lib/opkg/info/luci-app-smartdns.list" "$TMPD/list.bak2"
rm -rf "$ROOT"
mkdir -p "$ROOT"
_rom_restore_luci_smartdns
ck "R33.4f /rom 无清单 -> 恢复失败(1)" "$?" "1"
ck "R33.4g 且一个文件都没写" "$(ls -A "$ROOT" | wc -l)" "0"
mv "$TMPD/list.bak2" "$ROM/usr/lib/opkg/info/luci-app-smartdns.list"

echo
echo "== 33.5 构建期包清单 =="
ck "R33.5a 24.10 包选项含 luci-app-smartdns" \
   "$(grep -c 'CUSTOM_PACKAGES="\$CUSTOM_PACKAGES luci-app-smartdns"' \
        "$REPO/shell/custom-packages.sh")" "1"
ck "R33.5b 25.12 包选项含 luci-app-smartdns" \
   "$(grep -c 'CUSTOM_PACKAGES="\$CUSTOM_PACKAGES luci-app-smartdns"' \
        "$REPO/shell/apk-custom-packages.sh")" "1"
ck "R33.5c 两条线都没误选 smartdns-ui（Rust 大包）" \
   "$(cat "$REPO/shell/custom-packages.sh" "$REPO/shell/apk-custom-packages.sh" \
        | grep -c 'CUSTOM_PACKAGES="\$CUSTOM_PACKAGES smartdns-ui"')" "0"

echo
if [ "$R" -eq 0 ]; then
    echo "全部通过"
else
    echo "失败 $R 项"
fi
exit $((R > 0))
