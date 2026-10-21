#!/bin/sh
# v.108.33 回归：构建后复核（方案 A）+ 首次装机豁免只开给 bouncer_verify
#   ① 复核点不在 build 旁边，在 flush 之后（此刻配置才落地）
#   ② 本轮 build 过谁，按 _dirty_ 记进 _built_nodes，复核照这份名单走
#   ③ 首次装机判定只有一个调用点：_post_verify_skip 里的 bouncer_verify
#   ④ 其它节点（安装/复核/bouncer 本身的验证）一律先验证再动作，不看首次装机
set -u
REPO="C:/Users/Alon/Documents/JiuwenSwarm/2026-10-20/chat-1/work/REVIEW/verify"
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
    ' "$BS"
}

T=$(mktemp -d)
LOG="$T/log"
OPS="$T/ops"
: > "$LOG"
: > "$OPS"

log() { echo "$*" >> "$LOG"; }
sleep() { :; }
flush_uci() { echo "FLUSH" >> "$OPS"; return 0; }

eval "$(body _stamp_present)"
eval "$(body _first_install)"
eval "$(body _post_verify_skip)"
eval "$(body _post_verify_confirm)"
eval "$(body _count_words)"
eval "$(body _post_verify_after_boot)"

STAMP_FILE="$T/installed"
rm -f "$STAMP_FILE"
_failed=""
SOFT_NODES="bouncer_verify"
_built_nodes=""

echo "== ① 首次装机判定：只有一处调用，只服务 bouncer_verify =="
ck "R26.1 _first_install 定义一处" \
   "$(grep -c '^_first_install()' "$BS")" "1"
ck "R26.2 _first_install 调用一处" \
   "$(grep -c '_first_install &&' "$BS")" "1"
ck "R26.3 调用点就在 _post_verify_skip 里面" \
   "$(body _post_verify_skip | grep -c '_first_install')" "1"
ck "R26.4 _post_verify_skip 的名单里只有 bouncer_verify" \
   "$(body _post_verify_skip | grep -c 'bouncer_verify')" "1"
ck "R26.5 _post_verify_skip 名单里没有别的节点" \
   "$(body _post_verify_skip | tr ' ' '\n' | grep -cE '^(lan_static|snat|ct_boot|bridge|capiblock|enroll)$')" "0"
ck "R26.6 首次装机判定不写任何文件（只读）" \
   "$(body _first_install | grep -c 'uci \|> "\$')" "0"

echo "== ② 行为：首次装机只豁免 bouncer_verify 的复核 =="
rm -f "$STAMP_FILE"
_post_verify_skip bouncer_verify
ck "R26.7 首次装机 + bouncer_verify → 跳过复核" "$?" "0"
_post_verify_skip lan_static
ck "R26.8 首次装机 + lan_static → 照样复核" "$?" "1"
_post_verify_skip snat
ck "R26.9 首次装机 + snat → 照样复核" "$?" "1"
_post_verify_skip ct_boot
ck "R26.10 首次装机 + ct_boot → 照样复核" "$?" "1"
printf 'installed\nver=x\n' > "$STAMP_FILE"
_post_verify_skip bouncer_verify
ck "R26.11 重启态 + bouncer_verify → 不再豁免" "$?" "1"

echo "== ③ 行为：复核在 flush 之后跑，失败就判 =="
verify_ok1() { return 0; }
verify_bad1() { return 1; }
: > "$OPS"; : > "$LOG"
_built_nodes=" ok1 "
_post_verify_after_boot
ck "R26.12 全生效 → 返回 0" "$?" "0"
ck "R26.13 全生效时不做多余 flush" "$(grep -c '^FLUSH$' "$OPS")" "0"

: > "$OPS"; : > "$LOG"
_built_nodes=" bad1 "
_post_verify_after_boot
ck "R26.14 复核始终不符 → 返回 1" "$?" "1"
ck "R26.15 首轮不符会先落地再复验（flush 一次）" "$(grep -c '^FLUSH$' "$OPS")" "1"
ck "R26.16 日志说清是「写了没生效」" "$(grep -c '写了没生效' "$LOG")" "1"

: > "$OPS"; : > "$LOG"
_built_nodes=" bouncer_verify "
rm -f "$STAMP_FILE"
_post_verify_after_boot
ck "R26.17 首次装机的 bouncer_verify 复核失败 → 不判引导失败" "$?" "0"
ck "R26.18 跳过时留下日志（不静默）" "$(grep -c '首次装机：跳过' "$LOG")" "1"

echo "== ④ 结构：复核点与记账 =="
ck "R26.19 ensure 里不再有 build 后立即复核" \
   "$(body ensure | grep -c '_post_verify_confirm')" "0"
ck "R26.20 ensure 里注明了为什么不在 build 后验" \
   "$(body ensure | grep -c 'commit/reload 统一在 flush_uci')" "1"
ck "R26.21 flush_uci 清脏标记前记账" \
   "$(body flush_uci | grep -c '_bs_flag_on "_dirty_\$_o" && _built_nodes="\$_built_nodes \$_o"')" "1"
ck "R26.22 记账看 _dirty_ 不看 _done_（只数实际取值）" \
   "$(body flush_uci | grep -c '_bs_flag_on "_done_')" "0"
ck "R26.23 收尾复核在 _stamp_write 之前" \
   "$(awk '/_post_verify_after_boot; then/{a=NR} /if ! _stamp_write; then/{b=NR} END{print (a && b && a<b) ? "yes" : "no"}' "$BS")" "yes"
ck "R26.24 收尾复核在 flush_uci 之后（main 里位置）" \
   "$(awk '/^    flush_uci \|\| _flush_rc=1/{f=NR} /_post_verify_after_boot; then/{p=NR} END{print (f && p && p>f) ? "yes" : "no"}' "$BS")" "yes"
ck "R26.25 复核失败走 exit 1" \
   "$(awk '/【v.108.33】落地复核/,/_stamp_write; then/' "$BS" | grep -c 'exit 1')" "1"
ck "R26.26 二进制里有二次落地（flush + 复验）" \
   "$(body _post_verify_after_boot | grep -c 'flush_uci >/dev/null 2>&1')" "1"
ck "R26.27 柔性节点在复核阶段只记账" \
   "$(body _post_verify_after_boot | grep -c '_failed="\$_failed \$_pva_n"')" "2"

echo "== ⑤ 先验证再动作：顺序没被首次装机判断改掉 =="
ck "R26.28 ensure 仍是先 verify 再 build" \
   "$(body ensure | awk '/verify_\$_o/{v=NR} /build_\$_o/{b=NR} END{print (v && b && v<b) ? "yes" : "no"}')" "yes"
ck "R26.29 ensure 里没有任何 _first_install 判断" \
   "$(body ensure | grep -c '_first_install')" "0"
ck "R26.30 bouncer_verify 自己仍是 verify → build（ensure 统一口径）" \
   "$(grep -c '^verify_bouncer_verify()' "$BS")$(grep -c '^build_bouncer_verify()' "$BS")" "11"
ck "R26.31 安装判定（_stamp_present）没有被首次装机顶替" \
   "$(grep -c '^_stamp_present()' "$BS")" "1"

rm -rf "$T"
echo "----"
if [ "$R" -eq 0 ]; then
    echo "ALL PASS"
else
    echo "FAILED: $R"
fi
exit "$R"
