#!/bin/sh
# R35【v.180.118 引入 / v.180.119 改口径】：bootstrap 本体与只读基座不一致就复原
#
# bootstrap 不属于任何 opkg/apk 包（它是 files/ 直接铺进固件的），
# 所以 opkg remove 碰不到它 —— 只有手动 rm 或写错的脚本才让它消失/被改。
# 它一旦不可用，补印 / 停滞 / DNS 三条通道全部以 127 空转，
# 一路记「bootstrap 退出 127」到「需人工介入」，而 /rom 里其实有一份。
#
# v.180.119 起口径与 _guard_run 统一：**与只读基座不一致就覆盖**。
# 这个口径成立的前提是「更新只通过刷机完成」—— 刷机后 /rom 即当前版，
# 两边内容相同 → 每轮零动作；只有被删、被改、丢了执行位才动手。
#
# 本测试盯四件事：
#   1. 缺失时能补回（含可执行位）。
#   2. 内容一致时**一个字都不改**，也不写日志（刷机后的常态，不能刷屏）。
#   3. 内容不一致（被改过）时，按只读基座覆盖回来 —— 这是 v.180.119 的改动。
#   4. 每轮都要检查，不是等触发修复才查（tick 遇 lock-busy 会提前返回）。
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
# v.180.119：判据改成「与只读基座像不像」，所以要出现 cmp
ck "R35.1c _ensure_boot 里用 cmp 比对内容" \
   "$(body _ensure_boot "$PR" | grep -c 'cmp -s')" "1"
ck "R35.1d 不做 rm -f（cp -f 覆盖即可，别把在执行的文件抹成空洞）" \
   "$(body _ensure_boot "$PR" | grep -c 'rm -f')" "0"
ck "R35.1e 一致就提前返回（在位且一致 = 零写入）" \
   "$(body _ensure_boot "$PR" | grep -c '&& cmp -s "\$_eb_src" "\$BOOT"' )" "1"
ck "R35.1f 不一致时 cp -f 覆盖并补执行位" \
   "$(body _ensure_boot "$PR" | grep -c 'cp -f "\$_eb_src" "\$BOOT"')" "1"
ck "R35.1g 三条通道都认 78" \
   "$(grep -c '= 78 \]' "$PR")" "3"
ck "R35.1h BOOT 路径可被环境覆盖（夹具用）" \
   "$(grep -c 'BOOT="\${CS_PROBE_BOOT:-/usr/sbin/crowdsec-lxc-bootstrap.sh}"' "$PR")" "1"
ck "R35.1i ROMDIR 可被环境覆盖" \
   "$(grep -c 'ROMDIR="\${CS_PROBE_ROM:-/rom}"' "$PR")" "1"
# 每轮检查：放进 _guard_run（tick 遇 lock-busy 会提前返回，完整性检查不能跟着停摆）
ck "R35.1j _guard_run 每轮都调 _ensure_boot" \
   "$(body _guard_run "$PR" | grep -c '_ensure_boot || :')" "1"
ck "R35.1k _guard_run 里先修 bootstrap 再跑 guard" \
   "$(body _guard_run "$PR" | awk '/_ensure_boot/{b=NR} /PROBE_GUARD_MAX/{g=NR} END{print (b<g && b>0 && g>0) ? "yes" : "no"}')" "yes"
ck "R35.1l 版本号已升到 180.119" \
   "$(grep -c 'SCRIPT_VER="2026-10-28.180.119"' "$PR")" "1"

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
ck "R35.2d 补回的就是只读基座那份" "$("$BOOT")" "rom-version"
ck "R35.2e 日志说明按固件版复原" \
   "$(grep -c '已按固件版复原' "$log_out")" "1"

# B 已在位且与 /rom 一致 -> 零动作、零日志（刷机后的常态）
: > "$log_out"
_sum_before=$(cksum "$BOOT")
_mtime_before=$(date -r "$BOOT" +%s 2>/dev/null || echo 0)
_ensure_boot
ck "R35.2f 一致时返回 0" "$?" "0"
ck "R35.2g 内容一个字节都没动" "$(cksum "$BOOT")" "$_sum_before"
ck "R35.2h 一致时不写日志（不刷屏）" "$(wc -l < "$log_out")" "0"

# C 在位但被改过 -> 按只读基座覆盖回来（v.180.119 的核心）
printf '#!/bin/sh\necho tampered\n' > "$BOOT"
chmod 755 "$BOOT"
ck "R35.2i 场景成立：此刻跑的是被改过的版本" "$("$BOOT")" "tampered"
: > "$log_out"
_ensure_boot
ck "R35.2j 被改过 -> 返回 0" "$?" "0"
ck "R35.2k 已按只读基座覆盖回来" "$("$BOOT")" "rom-version"
ck "R35.2l 与只读基座逐字节一致" \
   "$(cmp -s "$BOOT" "$ROM/usr/sbin/bootstrap.sh" && echo same || echo diff)" "same"
ck "R35.2m 执行位仍在" "$([ -x "$BOOT" ] && echo yes || echo no)" "yes"
ck "R35.2n 日志说明不一致并已复原" \
   "$(grep -c '与只读基座不一致，已按固件版复原' "$log_out")" "1"

# D 缺失 + /rom 也没有 -> 明说要重刷
rm -f "$BOOT" "$ROM/usr/sbin/bootstrap.sh"
: > "$log_out"
_ensure_boot
ck "R35.2o 都没了返回 1" "$?" "1"
ck "R35.2p 文件仍不存在" "$([ -e "$BOOT" ] && echo yes || echo no)" "no"
ck "R35.2q 日志点明请重刷固件" \
   "$(grep -c '自动修复通道已失效，请重刷固件' "$log_out")" "1"

# E /rom 有、运行副本没执行位 -> 视为不可用，覆盖一次
printf '#!/bin/sh\necho rom-version\n' > "$ROM/usr/sbin/bootstrap.sh"
printf 'not-exec\n' > "$BOOT"
chmod 644 "$BOOT"
: > "$log_out"
_ensure_boot
ck "R35.2r 无执行位视同不可用 -> 返回 0（补过）" "$?" "0"
ck "R35.2s 补成可执行" "$([ -x "$BOOT" ] && echo yes || echo no)" "yes"
ck "R35.2t 内容也是只读基座那份" "$("$BOOT")" "rom-version"

# F 运行副本在、/rom 没有 -> 不动它，返回 0（旧固件上也能跑）
printf '#!/bin/sh\necho standalone\n' > "$BOOT"
chmod 755 "$BOOT"
rm -f "$ROM/usr/sbin/bootstrap.sh"
: > "$log_out"
_ensure_boot
ck "R35.2u 只读基座没有但运行副本在 -> 返回 0（不动）" "$?" "0"
ck "R35.2v 内容保持不变" "$("$BOOT")" "standalone"
ck "R35.2w 这种情况不写日志" "$(wc -l < "$log_out")" "0"

echo
if [ "$R" -eq 0 ]; then
    echo "全部通过"
else
    echo "失败 $R 项"
fi
exit $((R > 0))
