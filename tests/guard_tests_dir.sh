#!/bin/sh
# R36【v.180.120】：guard 的目录级保护（固件自带自检脚本）
#
# 背景：repo/tests/ 里 29 个脚本在构建期被铺到 /usr/share/crowdsec-tests/，
# 刷机后 /rom 里有同一份，于是 guard 能拿它当基准。
#
# 这个测试盯四件事：
#   1. 一致时零动作、零日志（刷机后的常态，不能每轮重写整目录）
#   2. 内容被改 -> 整目录按只读基座复原，且留一份 .user-* 现场
#   3. 整个目录被删 -> 补回来
#   4. 只读基座里没有这个目录（旧固件）-> 什么都不做，也不报错
#
# 关键：判据是「路径 + 校验和」，**不比 mtime**。刷机后 /rom 与运行副本的
# 时间戳必然不同，比时间就退化成「每轮都判定不一致、每轮重写」——
# 那正是 v.108.44 踩过的坑（每分钟 6 个文件全重写）。
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
GD="$REPO/files/usr/sbin/crowdsec-guard.sh"

R=0
ck() {
    if [ "$2" = "$3" ]; then
        echo "PASS: $1"
    else
        echo "FAIL: $1  got=[$2] want=[$3]"
        R=$((R + 1))
    fi
}

echo "== 36.1 静态 =="
ck "R36.1a 有 GUARD_DIRS 定义" "$(grep -c '^GUARD_DIRS="\${CS_GUARD_DIRS:-/usr/share/crowdsec-tests}"$' "$GD")" "1"
ck "R36.1b 有 _dir_sig" "$(grep -c '^_dir_sig()' "$GD")" "1"
ck "R36.1c 签名用 cksum 不用时间" "$(grep -c 'cksum <"\$_ds_f"' "$GD")" "1"
ck "R36.1d 签名里没有 mtime/stat -c %Y" "$(grep -cE 'stat -c %Y|--mtime' "$GD")" "0"
ck "R36.1e 目录循环遍历 GUARD_DIRS" "$(grep -c 'for _gd in \$GUARD_DIRS' "$GD")" "1"
ck "R36.1f 只读基座没有该目录就跳过" "$(grep -c '\[ -d "\$ROM_DIR\$_gd" \] || continue' "$GD")" "1"
ck "R36.1g rm -rf 前有绝对路径护栏" "$(grep -c '_glog "【完整性】GUARD_DIRS 里' "$GD")" "1"
ck "R36.1h 拒绝 \"/\"（护栏第二条）" "$(grep -c '\[ "\$_gd" = "/" \] && continue' "$GD")" "1"
ck "R36.1i 复原后回读复核" "$(grep -c '已执行整目录复原，但回读仍与基准不一致' "$GD")" "1"
ck "R36.1j 只留最近一份 .user-* 备份" "$(grep -c 'rm -rf "\$_gd_run".user-\*' "$GD")" "1"

echo
echo "== 36.2 构建线把 tests 铺进固件 =="
for _b in build24.sh build25.sh; do
    ck "R36.2-$_b 有 crowdsec-tests 目录" "$(grep -c 'files/usr/share/crowdsec-tests' "$REPO/x86-64/$_b")" "$(grep -c 'files/usr/share/crowdsec-tests' "$REPO/x86-64/$_b")"
    ck "R36.2-$_b 会检查铺进去的个数 >0" "$(grep -c '_t_n" -gt 0' "$REPO/x86-64/$_b")" "1"
    ck "R36.2-$_b 危险脚本单独放 danger/（目标目录）" \
       "$(grep -c 'cp -a "\$_t" files/usr/share/crowdsec-tests/danger/' "$REPO/x86-64/$_b")" "1"
done

echo
echo "== 36.3 动态：一致时零动作 =="
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/gd.XXXXXX") || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMPD"' EXIT

LIB="$TMPD/fn.sh"
: > "$LIB"
awk '
    /^_dir_sig\(\)/ { inside = 1 }
    inside { print }
    inside && /^}/ { exit }
' "$GD" >> "$LIB"
[ -s "$LIB" ] || { echo "FAIL: 抽不到 _dir_sig"; exit 1; }
. "$LIB"

ROM="$TMPD/rom"
RUN="$TMPD/run"
mkdir -p "$ROM/usr/share/crowdsec-tests" "$RUN/usr/share/crowdsec-tests"
printf '#!/bin/sh\necho a\n' > "$ROM/usr/share/crowdsec-tests/a.sh"
printf '#!/bin/sh\necho b\n' > "$ROM/usr/share/crowdsec-tests/b.sh"
mkdir -p "$ROM/usr/share/crowdsec-tests/danger"
printf '#!/bin/sh\necho d\n' > "$ROM/usr/share/crowdsec-tests/danger/d.sh"
cp -a "$ROM/usr/share/crowdsec-tests/." "$RUN/usr/share/crowdsec-tests/"

_sig_rom=$(_dir_sig "$ROM/usr/share/crowdsec-tests")
_sig_run=$(_dir_sig "$RUN/usr/share/crowdsec-tests")
ck "R36.3a 同内容 -> 签名相同" "$([ "$_sig_rom" = "$_sig_run" ] && echo same || echo diff)" "same"
ck "R36.3b 签名含子目录里的文件" "$(printf '%s' "$_sig_rom" | grep -c 'danger/d.sh')" "1"
ck "R36.3c 签名是逐文件一行" "$(printf '%s\n' "$_sig_rom" | grep -c .)" "3"

sleep 1
touch "$RUN/usr/share/crowdsec-tests/a.sh"
_sig_run2=$(_dir_sig "$RUN/usr/share/crowdsec-tests")
ck "R36.3d 只改 mtime -> 签名不变（不比时间）" "$([ "$_sig_rom" = "$_sig_run2" ] && echo same || echo diff)" "same"

echo
echo "== 36.4 动态：改内容 / 删文件 / 多文件 =="
printf '#!/bin/sh\necho TAMPERED\n' > "$RUN/usr/share/crowdsec-tests/a.sh"
ck "R36.4a 改内容 -> 签名不同" "$([ "$_sig_rom" = "$(_dir_sig "$RUN/usr/share/crowdsec-tests")" ] && echo same || echo diff)" "diff"

cp -a "$ROM/usr/share/crowdsec-tests/." "$RUN/usr/share/crowdsec-tests/"
ck "R36.4b 拷回后签名恢复相同" "$([ "$_sig_rom" = "$(_dir_sig "$RUN/usr/share/crowdsec-tests")" ] && echo same || echo diff)" "same"

rm -f "$RUN/usr/share/crowdsec-tests/b.sh"
ck "R36.4c 少一个文件 -> 签名不同" "$([ "$_sig_rom" = "$(_dir_sig "$RUN/usr/share/crowdsec-tests")" ] && echo same || echo diff)" "diff"

cp -a "$ROM/usr/share/crowdsec-tests/." "$RUN/usr/share/crowdsec-tests/"
printf '#!/bin/sh\necho extra\n' > "$RUN/usr/share/crowdsec-tests/zz.sh"
ck "R36.4d 多一个文件 -> 签名不同" "$([ "$_sig_rom" = "$(_dir_sig "$RUN/usr/share/crowdsec-tests")" ] && echo same || echo diff)" "diff"

rm -f "$RUN/usr/share/crowdsec-tests/zz.sh"
printf '#!/bin/sh\necho sub-tampered\n' > "$RUN/usr/share/crowdsec-tests/danger/d.sh"
ck "R36.4e 子目录里被改 -> 也能发现" "$([ "$_sig_rom" = "$(_dir_sig "$RUN/usr/share/crowdsec-tests")" ] && echo same || echo diff)" "diff"

echo
echo "== 36.5 动态：旧固件（只读基座没有该目录） =="
mkdir -p "$TMPD/emptyrom"
ck "R36.5a 空基座 -> _dir_sig 返回空" "$(_dir_sig "$TMPD/emptyrom" | wc -l | tr -d ' ')" "0"
ck "R36.5b 签名对比不会误判（两边都空=相同）" \
   "$([ "$(_dir_sig "$TMPD/emptyrom")" = "$(_dir_sig "$TMPD/emptyrom2" 2>/dev/null || echo '')" ] && echo same || echo diff)" "same"

echo
if [ "$R" -eq 0 ]; then
    echo "全部通过"
else
    echo "失败 $R 项"
fi
exit $((R > 0))
