#!/bin/sh
# R35【v.180.118】：bootstrap 本体被删时自动从 /rom 补回
#
# bootstrap 不属于任何 opkg/apk 包（它是 files/ 直接铺进固件的），
# 所以 opkg remove 碰不到它 —— 只有手动 rm 或写错的脚本才让它消失。
# 它一旦没了，补印 / 停滞 / DNS 三条通道全部以 127 空转，
# 一路记「bootstrap 退出 127」到「需人工介入」，而 /rom 里其实有一份。
#
# 本测试盯两件事：
#   1. 缺失时能补回（含可执行位）。
#   2. 存在时**一个字都不改** —— 这是与 _guard_run（与 /rom 不一致就复原）的
#      关键差别。/rom 里是构建固件那一刻的版本，运行副本是迭代过的；
#      照抄 guard 的写法会每轮把新版静默打回旧版。
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
PR="$REPO/files/usr/sbin/crowdsec-lxc-probe.sh"

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

echo "== 35.1 静态 =="
ck "R35.1a 有 _ensure_boot" "$(grep -c '^_ensure_boot()' "$PR")" "1"
ck "R35.1b _run_fix 开头先调 _ensure_boot" \
   "$(body _run_fix "$PR" | grep -c '_ensure_boot || return 78')" "1"
# 判据是「在不在」，不是「与 /rom 像不像」：绝不能出现 cmp
ck "R35.1c _ensure_boot 里没有 cmp（不比对内容）" \
   "$(body _ensure_boot "$PR" | grep -c 'cmp')" "0"
ck "R35.1d 也不做 rm -f（不覆盖已有文件）" \
   "$(body _ensure_boot "$PR" | grep -c 'rm -f')" "0"
ck "R35.1e 判据用 -x 且第一行就提前返回（在位零写入）" \
   "$(body _ensure_boot "$PR" | grep -c '\[ -x "\$BOOT" \] && return 0')" "1"
ck "R35.1f 三条通道都认 78" \
   "$(grep -c '= 78 \]' "$PR")" "3"
ck "R35.1g BOOT 路径可被环境覆盖（夹具用）" \
   "$(grep -c 'BOOT="\${CS_PROBE_BOOT:-/usr/sbin/crowdsec-lxc-bootstrap.sh}"' "$PR")" "1"
ck "R35.1h ROMDIR 可被环境覆盖" \
   "$(grep -c 'ROMDIR="\${CS_PROBE_ROM:-/rom}"' "$PR")" "1"

echo
echo "== 35.2 动态 =="
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/bh.XXXXXX") || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMPD"' EXIT

LIB="$TMPD/fns.sh"
: > "$LIB"
body _ensure_boot "$PR" >> "$LIB"
[ -s "$LIB" ] || { echo "FAIL: 抽不到函数"; exit 1; }

ROM="$TMPD/rom"
mkdir -p "$ROM/usr/sbin"
BOOT="$TMPD/run/bootstrap.sh"
ROMDIR="$ROM"
BOOT_SRC="$ROM/usr/sbin/bootstrap.sh"
mkdir -p "$TMPD/run"

log_out="$TMPD/out.log"
: > "$log_out"
plog() { printf '%s\n' "$*" >> "$log_out"; }
. "$LIB"

# A 缺失 + /rom 有 -> 补回
printf '#!/bin/sh\necho rom-version\n' > "$ROM/usr/sbin/bootstrap.sh"
chmod 644 "$ROM/usr/sbin/bootstrap.sh"
rm -f "$BOOT"
_ensure_boot
ck "R35.2a 缺失时返回 0" "$?" "0"
ck "R35.2b 文件已补回" "$([ -f "$BOOT" ] && echo yes || echo no)" "yes"
ck "R35.2c 可执行位已补上" "$([ -x "$BOOT" ] && echo yes || echo no)" "yes"
ck "R35.2d 日志说明是固件内置版本" \
   "$(grep -c '固件内置版本' "$log_out")" "1"

# B 已在位 -> 一个字都不改（哪怕与 /rom 内容不同）
printf '#!/bin/sh\necho newer-version\n' > "$BOOT"
chmod 755 "$BOOT"
_sum_before=$(cksum "$BOOT")
: > "$log_out"
_ensure_boot
ck "R35.2e 已在位返回 0" "$?" "0"
ck "R35.2f 内容未被覆盖成 /rom 那份" "$(cksum "$BOOT")" "$_sum_before"
ck "R35.2g 执行起来还是新版" "$("$BOOT")" "newer-version"
ck "R35.2h 在位时不写日志（不刷屏）" "$(wc -l < "$log_out")" "0"

# C 缺失 + /rom 也没有 -> 明说要重刷
rm -f "$BOOT" "$ROM/usr/sbin/bootstrap.sh"
: > "$log_out"
_ensure_boot
ck "R35.2i 都没了返回 1" "$?" "1"
ck "R35.2j 文件仍不存在" "$([ -e "$BOOT" ] && echo yes || echo no)" "no"
ck "R35.2k 日志点明请重刷固件" \
   "$(grep -c '请人工重刷固件或从仓库取回' "$log_out")" "1"

# D /rom 有但运行副本没执行位 -> 视为缺失，补一次
printf '#!/bin/sh\necho rom-version\n' > "$ROM/usr/sbin/bootstrap.sh"
printf 'not-exec\n' > "$BOOT"
chmod 644 "$BOOT"
: > "$log_out"
_ensure_boot
ck "R35.2l 无执行位视同缺失 -> 返回 0（补过）" "$?" "0"
ck "R35.2m 补成可执行" "$([ -x "$BOOT" ] && echo yes || echo no)" "yes"

echo
if [ "$R" -eq 0 ]; then
    echo "全部通过"
else
    echo "失败 $R 项"
fi
exit $((R > 0))
