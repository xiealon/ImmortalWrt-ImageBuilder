#!/bin/sh
# R8：置位值必须是「分类 + 时间戳」，不是裸 1。
#
# 为什么要单测这一层：置位是**贯穿全脚本**的机制，ensure / ensure_group / flush_uci /
# rg_restart_verify / main 都在读它。改格式时最怕的不是某处忘了改（那会立刻红），
# 而是「读的点用 `= 1` 比较」——值变成 V:<ts> 后恒不相等，症状是某些组莫名判未置位。
# 所以这里既验写出来的格式，也验**全脚本再没有 `= 1` 式的置位比较**。
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
BS="$REPO/files/usr/sbin/crowdsec-lxc-bootstrap.sh"
# 只含活代码的副本：整行注释（行首可有空白 + #）不算命中。
# 注释里提到某关键字（例如记录「曾经 disable lxc-auto」）不该被断言当成
# 「代码里在做这件事」，否则断言会假红或假绿。断言一律 grep 这份副本。
BS_C="$(mktemp)"
grep -v '^[[:space:]]*#' "$BS" > "$BS_C"
trap 'rm -f "$BS_C"' EXIT INT TERM
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/r8.XXXXXX")
R=0
ck() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 got=[$2] want=[$3]"; R=$((R+1)); fi; }

echo "===== R8. 静态：置位的写/读/清三处都换过来了 ====="
# 写：不再出现 eval "<名>=1"
_old_write=$(grep -cE 'eval "_?(done|dirty)_\$_?[A-Za-z_]*=1"|eval "GSET_\$_?[A-Za-z_]*=1"' "$BS_C")
ck "R8.1 全脚本无 eval 写裸 1" "$_old_write" "0"
# 清：不再出现 "=0"
_old_clear=$(grep -cE 'eval "_?(done|dirty)_[^"]*=0"' "$BS_C")
ck "R8.2 全脚本无 eval 清成 0" "$_old_clear" "0"
# 读：不再出现 [ "$(...)" = 1 ] 或 != 1 形式的置位比较
_old_read=$(grep -cE '\$\(eval "echo \\\$_?(done|dirty)_[^"]*"\)" [!=]= 1' "$BS_C")
ck "R8.3 全脚本无「置位 = 1」式比较" "$_old_read" "0"
_old_read2=$(grep -cE '\$\(eval "echo \\\$GSET_[^"]*"\)" [!=]= 1' "$BS_C")
ck "R8.4 全脚本无「GSET = 1」式比较" "$_old_read2" "0"
# 三个分类前缀都真的被用过（不是只写了个 V 完事）
# 两处：ensure 里 verify 通过置 done、ensure_group 里整组完成置 GSET
ck "R8.5 V 分类有写入点（done + GSET）" "$(grep -c '_bs_flag_set "[^"]*" V' "$BS_C")" "2"
# 三处：ensure 的 dirty + done，加 v.105 起 rg_restart_verify 直接调 build_（绕过
# ensure）后自己补的 _dirty_ —— 少了它，组末 flush_uci 会判「无改动」跳过提交，
# 「已构建」就只活在内存里。注释里那次不算（所以模式带行首缩进锚点）。
ck "R8.6 B 分类有写入点（ensure 的 dirty+done、rgbuild 的 dirty）" \
   "$(grep -c '^ *_bs_flag_set "[^"]*" B' "$BS_C")" "3"
ck "R8.7 R 分类有写入点" "$(grep -c '_bs_flag_set "[^"]*" R' "$BS_C")" "1"
# 格式串必须是双引号（单引号在已有函数定义的 dash 里被吞，变量变空）
ck "R8.8 时间格式串用双引号" "$(grep -c '^_FLAG_TS_FMT="%F %T"$' "$BS_C")" "1"
# 实际 source 一遍，确认这行不会往 stderr 吐 "not found"
_src_err=$(sh "$BS_C" --only-funcs 2>&1 >/dev/null)
ck "R8.9 source 时无 stderr 报错" "$_src_err" ""

echo "===== R8b. 行为：三分类写出来的值可被正确识别 ====="
sh "$BS_C" --only-funcs > "$TMPD/f.sh" 2>/dev/null
cat > "$TMPD/t.sh" <<'EOS'
. "$F"
log() { :; }
_bs_flag_set A V; _bs_flag_set Bn B; _bs_flag_set C R; _bs_flag_clear D
echo "A=$A"; echo "B=$Bn"; echo "C=$C"; echo "D=[$D]"
echo "ON_A=$(_bs_flag_on A && echo 1 || echo 0)"
echo "ON_D=$(_bs_flag_on D && echo 1 || echo 0)"
echo "TAG_A=$(_bs_flag_tag A) TAG_B=$(_bs_flag_tag Bn) TAG_C=$(_bs_flag_tag C) TAG_D=[$(_bs_flag_tag D)]"
echo "CNT_D=$(_bs_flag_count D A Bn C D)"
echo "CNT_B=$(_bs_flag_count B A Bn C D)"
echo "EMPTY_ZERO=$(_bs_flag_on E && echo 1 || echo 0)"
EOS
# 设备上只有 /bin/sh（ash），没有独立的 dash —— 用 sh 才贴近真实运行环境。
F="$TMPD/f.sh" sh "$TMPD/t.sh" > "$TMPD/out" 2>&1
_g() { grep -m1 "^$1=" "$TMPD/out" | sed "s/^$1=//"; }
ck "R8.10 V 写出的格式" "$(printf '%s' "$(_g A)" | grep -cE '^V:[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$')" "1"
ck "R8.11 B 写出的格式" "$(printf '%s' "$(_g B)" | grep -cE '^B:[0-9]{4}')" "1"
ck "R8.12 R 写出的格式" "$(printf '%s' "$(_g C)" | grep -cE '^R:[0-9]{4}')" "1"
ck "R8.13 清空后为空串" "$(_g D)" "[]"
ck "R8.14 已置位判真" "$(_g ON_A)" "1"
ck "R8.15 已清空判假" "$(_g ON_D)" "0"
ck "R8.16 未定义变量判假（不炸）" "$(_g EMPTY_ZERO)" "0"
ck "R8.17 分类字符取对" "$(_g TAG_A)" "V TAG_B=B TAG_C=R TAG_D=[]"
ck "R8.18 D 计数 = 已置位总数 3" "$(_g CNT_D)" "3"
ck "R8.19 B 分类计数 = 1" "$(_g CNT_B)" "1"

# 反向：值写成 1（旧格式）时必须被判成「已置位但在 _bs_flag_tag 下没有分类」
# ——这条是为了防止「将来谁把某处改回 =1，测试却因为只判非空而放过」
cat > "$TMPD/t2.sh" <<'EOS'
. "$F"
log() { :; }
X=1
echo "ON=$(_bs_flag_on X && echo 1 || echo 0)"
echo "TAG=[$(_bs_flag_tag X)]"
EOS
F="$TMPD/f.sh" sh "$TMPD/t2.sh" > "$TMPD/out2" 2>&1
ck "R8.20 旧格式 1 仍判为已置位（兼容）" "$(grep -m1 '^ON=' "$TMPD/out2" | cut -d= -f2)" "1"
ck "R8.21 但取不到合法分类（能据此发现残留旧格式）" "$(grep -m1 '^TAG=' "$TMPD/out2" | sed 's/^TAG=//')" "[1]"

rm -rf "$TMPD"
echo "R8 FAIL=$R"
[ "$R" = 0 ]
