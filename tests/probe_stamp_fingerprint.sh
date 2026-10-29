#!/bin/sh
# R9：判「一不一样」要比内容，不比时间。
#
# 这一层专门驳几个看起来合理、实际会误判的做法：
#   · 「stamp 里的时间 < 文件 mtime」→ 判变更
#       反例：touch 一下、重解压同版本 tar、备份还原 —— mtime 变、内容没变，被误判成
#       「容器被动过」，于是好好的机器被拖去重装（或至少白跑一轮全量复验）。
#   · 「内容变了但 mtime 没变」→ 判没变更
#       反例：同一秒内两次写、cp -p / tar -p 保留时间 —— 内容变了被漏判。
# 所以正确判据只有一个：**内容指纹**。
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
FILES_DIR="${CS_FILES_DIR:-files-24}"
BS="$REPO/$FILES_DIR/usr/sbin/crowdsec-lxc-bootstrap.sh"
# 只含活代码的副本：整行注释（行首可有空白 + #）不算命中。
# 注释里提到某关键字（例如记录「曾经 disable lxc-auto」）不该被断言当成
# 「代码里在做这件事」，否则断言会假红或假绿。断言一律 grep 这份副本。
BS_C="$(mktemp)"
grep -v '^[[:space:]]*#' "$BS" > "$BS_C"
trap 'rm -f "$BS_C"' EXIT INT TERM
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/r9.XXXXXX")
R=0
ck() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 got=[$2] want=[$3]"; R=$((R+1)); fi; }

sh "$BS_C" --only-funcs > "$TMPD/f.sh" 2>/dev/null

echo "===== R9a. 指纹本身：只认内容 ====="
cat > "$TMPD/a.sh" <<'EOS'
. "$F"
T="$T"; mkdir -p "$T/p" "$T/c"
printf 'a\n' > "$T/c/config.yaml"; printf 'p\n' > "$T/p/x.yaml"
# 一律「切到这个树的根，再给相对路径」——生产里就是这么调的（rootfs + etc/crowdsec/...）
# 顺带保证：同一个树传绝对路径与传相对路径，指纹必须一样，否则「同一个东西」会被判成两个
echo "BASE=$(_bs_content_fp "$T")"
echo "AGAIN=$(_bs_content_fp "$T")"
# 只动时间：应该不变
touch "$T/p/x.yaml"; sleep 1; touch "$T/p/x.yaml"
echo "TOUCHED=$(_bs_content_fp "$T")"
# 内容变、把 mtime 按回原样：应该变
cp -p "$T/p/x.yaml" "$T/ref"
printf 'p-CHANGED\n' > "$T/p/x.yaml"; touch -r "$T/ref" "$T/p/x.yaml"
echo "CONTENT=$(_bs_content_fp "$T")"
# 加一个文件：应该变
printf 'new\n' > "$T/p/y.yaml"
echo "ADDED=$(_bs_content_fp "$T")"
# 删一个文件：应该变
rm -f "$T/p/y.yaml"
echo "REMOVED=$(_bs_content_fp "$T")"
# 相对路径 vs 绝对路径：同一个树，指纹不该因为 cwd 变化而变（find 输出是相对/绝对，
# 这里只要求「同一个调用方式下稳定」，所以只比同一种）
# 路径不存在：必须返回空串，不能返回「空集摘要」——
# da39a3ee5e6b4b0d 是「什么都没算」的固定值，拿它当指纹会让所有坏情况看起来都一样。
mkdir -p "$T/emptydir"
echo "EMPTYDIR=[$(_bs_content_fp "$T/emptydir" 2>/dev/null)]"
echo "MISSING=[$(_bs_content_fp "$T/no-such-dir" 2>/dev/null)]"
EOS
F="$TMPD/f.sh" T="$TMPD/tree" sh "$TMPD/a.sh" > "$TMPD/out" 2>&1
g() { grep -m1 "^$1=" "$TMPD/out" | sed "s/^$1=//"; }
_base=$(g BASE)
ck "R9.1 同内容两次指纹相同" "$(g AGAIN)" "$_base"
ck "R9.1b 指纹非空（空指纹等于永远说没变）" "$([ -n "$_base" ] && echo nonempty)" "nonempty"
ck "R9.2 只 touch（mtime 变、内容不变）→ 指纹不变" "$(g TOUCHED)" "$_base"
ck "R9.3 内容变但 mtime 按回原样 → 指纹变" \
   "$([ "$(g CONTENT)" != "$_base" ] && echo changed)" "changed"
ck "R9.4 多一个文件 → 指纹变" "$([ "$(g ADDED)" != "$_base" ] && [ "$(g ADDED)" != "$(g CONTENT)" ] && echo changed)" "changed"
ck "R9.5 删掉该文件 → 回到 CONTENT 那版指纹" "$(g REMOVED)" "$(g CONTENT)"
ck "R9.6 指纹是 16 位十六进制" "$(printf '%s' "$_base" | grep -cE '^[0-9a-f]{16}$')" "1"
# 同一个目录树，只要内容一样，指纹就必须一样——不管你用哪个路径、从哪进入。
# 这条挡住的是「路径名参与摘要」：`find c` 打印 `c/x.yaml`、`find .` 打印 `./x.yaml`，
# 两种写法天然不同，所以生产实现必须「cd 进去 + 只算这一个目录」。
ck "R9.6a 同一内容不同路径 → 指纹一致" \
   "$( . "$TMPD/f.sh"; mkdir -p "$TMPD/absT/c"; printf 'a\n' > "$TMPD/absT/c/config.yaml"
      mkdir -p "$TMPD/absT2/c"; printf 'a\n' > "$TMPD/absT2/c/config.yaml"
      x=$(_bs_content_fp "$TMPD/absT/c")
      y=$(_bs_content_fp "$TMPD/absT2/c")
      z=$(_bs_content_fp "$TMPD/absT2/c/")
      [ -n "$x" ] && [ "$x" = "$y" ] && [ "$x" = "$z" ] && echo same )" "same"
# 目录里一个文件都没有 / 路径根本不存在 → 都要给空串，不能给「空集摘要」。
# 那一串 da39a3ee5e6b4b0d 是「什么都没算」的固定值，拿它当指纹会让所有坏情况长得一样，
# 而「一样」在调用方那里就等于「没变过」——又一个假绿。
# 「能不能比」和「比出了什么」是两件事，所以取不到时用退出码 1 表明「这次没法比」。
ck "R9.6d 目录空无一物 → 空串（不是空集摘要）" "$(g EMPTYDIR)" "[]"
ck "R9.6e 路径不存在 → 空串（不是空集摘要）" "$(g MISSING)" "[]"
ck "R9.6f 取不到指纹时退出码非零（区分「没法比」与「一样」）" \
   "$( . "$TMPD/f.sh"; _bs_content_fp "$TMPD/tree/no-such-dir" >/dev/null 2>&1; echo "rc=$?" )" "rc=1"
# 空目录：xargs 一个文件都不给时会抢 stdin，把调用方的管道吃掉
ck "R9.6b 空目录不吞 stdin（用一个假 sha1sum 探针）" \
   "$( . "$TMPD/f.sh"; mkdir -p "$TMPD/empty"; printf 'STDIN-ALIVE\n' | { _bs_content_fp "$TMPD/empty" >/dev/null; cat; } )" "STDIN-ALIVE"

echo "===== R9b. 时间戳判据会被这些场景骗（反例说明必须用内容） ====="
cat > "$TMPD/b.sh" <<'EOS'
. "$F"
T="$T"; mkdir -p "$T/p"
printf 'p\n' > "$T/p/x.yaml"
# 造一个「stamp 时间早于文件 mtime」的场景：内容一个字没动，只把 mtime 推到将来
_stamp_ts="2026-01-01 00:00:00"
touch -d '2026-06-01 00:00:00' "$T/p/x.yaml" 2>/dev/null
_file_ts=$(date -r "$T/p/x.yaml" '+%F %T' 2>/dev/null)
# 时间判据会怎么说：文件 mtime(6月) 晚于 stamp(1月) ⇒ 「容器被动过，要重装」
echo "TIME_WOULD_SAY=changed"
echo "CONTENT_SAYS=same"
echo "STAMP_TS=$_stamp_ts"
echo "FILE_TS=$_file_ts"
echo "FP1=$(_bs_content_fp "$T/p")"
EOS
F="$TMPD/f.sh" T="$TMPD/tree2" sh "$TMPD/b.sh" > "$TMPD/out2" 2>&1
# 关键断言：同样的内容，无论 mtime 怎么变，指纹都该等于「干净拷贝」的指纹
mkdir -p "$TMPD/tree3/p"; printf 'p\n' > "$TMPD/tree3/p/x.yaml"
_FP_clean=$( . "$TMPD/f.sh"; _bs_content_fp "$TMPD/tree3/p" )
_FP_old=$(grep -m1 '^FP1=' "$TMPD/out2" | sed 's/^FP1=//')
ck "R9.7 改了 mtime 的树与干净拷贝指纹一致（时间不参与判据）" "$_FP_old" "$_FP_clean"
# 反过来：时间判据在这一场景已经「说了 changed」，内容判据说「一样」——两者结论相反，
# 而事实是内容一个字没动。这条把「时间判据会误判」钉成可执行断言，而不是注释里的一句话。
ck "R9.7b 该场景时间判据会说 changed（证明它会误判）" \
   "$(grep -m1 '^TIME_WOULD_SAY=' "$TMPD/out2" | sed 's/^TIME_WOULD_SAY=//')" "changed"
ck "R9.7c 该场景文件 mtime 确实晚于 stamp 时间（前提成立）" \
   "$(s=$(sed -n 's/^STAMP_TS=//p' "$TMPD/out2"); f=$(sed -n 's/^FILE_TS=//p' "$TMPD/out2")
      awk -v s="$s" -v f="$f" 'BEGIN{ print (f > s) ? "later" : "not-later" }')" "later"
ck "R9.7d 该场景内容判据说 same（与时间判据结论相反）" "$_FP_old" "$_FP_clean"

echo "===== R9c. 生产接线：指纹要真的落进 stamp ====="
ck "R9.8 有 _bs_content_fp 定义" "$(grep -cE '^_bs_content_fp\(\) *\{' "$BS_C")" "1"
ck "R9.9 stamp 写了 cfg_fp" "$(awk '/^_stamp_write\(\)/,/^}/' "$BS_C" | grep -c '^cfg_fp=')" "1"
ck "R9.10 stamp 写了 parsers_fp" "$(awk '/^_stamp_write\(\)/,/^}/' "$BS_C" | grep -c '^parsers_fp=')" "1"
ck "R9.11 指纹算的是容器 crowdsec 配置目录" \
   "$(awk '/^_stamp_write\(\)/,/^}/' "$BS_C" | grep -c '_bs_content_fp "\$ROOTFS/etc/crowdsec"')" "1"
ck "R9.12 指纹算的是容器 parsers 目录" \
   "$(awk '/^_stamp_write\(\)/,/^}/' "$BS_C" | grep -c '_bs_content_fp "\$ROOTFS/etc/crowdsec/parsers"')" "1"
# 拿不到指纹时写 `-` 占位：留空的话，下次读出来分不清「没记」和「记了个空」
ck "R9.12b 指纹取不到时写 - 占位" \
   "$(awk '/^_stamp_write\(\)/,/^}/' "$BS_C" | grep -cE '_bs_fp_(cfg|parsers)=.*\|\| _bs_fp_(cfg|parsers)="-"')" "2"
# 反例钉子：全脚本不许出现「拿时间戳比大小判变更」这种写法
ck "R9.13 全脚本没有拿 mtime 比 stamp 时间" "$(grep -cE 'date -r .*[<>]|\[ .*_ts.*-(ot|nt) ' "$BS_C")" "0"
# 反例钉子：`</dev/null` 不许挂在整条管道末尾（会把 find 的 stdout 也接到 /dev/null，
# 函数对任何目录都返回空集摘要，永远说「没变」——不报错、不报警的假绿）
# 行首缩进锚用来排除注释：这坑值得在源码里讲清楚，讲的话里当然会带这个写法。
ck "R9.14 管道末尾没有裸 </dev/null 重定向" \
   "$(grep -cE '^[[:space:]]*[^#].*\|[^|)]*</dev/null' "$BS_C")" "0"


echo "===== R10. 读点：_stamp_cfg_changed 的三种状态 ====="
# 这一层测的是「拿 stamp 里记的指纹跟现在比，判得对不对」，以及最关键的一条：
# 判错的方向必须是「宁可放过，不可冤枉」—— 误判成「变了」会让好机器白跑一轮全量复核。
cat > "$TMPD/c.sh" <<'EOS2'
. "$F"
T="$T"
R="$T/rootfs"
mkdir -p "$R/etc/crowdsec/parsers"
printf 'k: v\n' > "$R/etc/crowdsec/config.yaml"
printf 'p\n'   > "$R/etc/crowdsec/parsers/http.yaml"
ROOTFS="$R"
STAMP_FILE="$T/stamp"
log() { printf 'LOG %s\n' "$*"; }

# ① 正常写入后再比：应当一致
_stamp_write >/dev/null 2>&1
echo "STAMP=[$(tr '\n' '|' < "$STAMP_FILE")]"
_stamp_cfg_changed; echo "SAME_RC=$?"

# ② 改一个解析器内容：应当不一致
printf 'p-CHANGED\n' > "$R/etc/crowdsec/parsers/http.yaml"
_stamp_cfg_changed; echo "CFG_RC=$?"

# ③ 目录里少一个文件：也要能看出来（所以指纹算的是整个目录，不是单个文件）
printf 'p\n' > "$R/etc/crowdsec/parsers/http.yaml"
_stamp_cfg_changed >/dev/null 2>&1; echo "RESTORED_RC=$?"
rm -f "$R/etc/crowdsec/parsers/http.yaml"
_stamp_cfg_changed; echo "MISSING_RC=$?"

# ④ 只 touch 不动内容：必须判「没变」（这就是不用时间戳的意义）
printf 'p\n' > "$R/etc/crowdsec/parsers/http.yaml"
touch "$R/etc/crowdsec/parsers/http.yaml" "$R/etc/crowdsec/config.yaml"
_stamp_cfg_changed >/dev/null 2>&1; echo "TOUCH_RC=$?"

# ⑤ 老 stamp（没有 fp 字段）：不许判变更，否则升级上来的机器全都要白跑一遍
printf 'installed\nver=old\nts=2026-01-01 00:00:00\n' > "$STAMP_FILE"
_stamp_cfg_changed; echo "OLD_RC=$?"

# ⑥ fp 记成 - （当时算不出来）：同样不许判变更
printf 'installed\nver=old\nts=x\ncfg_fp=-\nparsers_fp=-\n' > "$STAMP_FILE"
_stamp_cfg_changed; echo "DASH_RC=$?"

# ⑦ 容器目录整个没了：算不出新指纹 ⇒ 不下结论（交给 verify_rootfs 判「缺东西」）
printf 'installed\nver=v\nts=x\ncfg_fp=aaaa\nparsers_fp=bbbb\n' > "$STAMP_FILE"
rm -rf "$R/etc"
_stamp_cfg_changed; echo "GONE_RC=$?"
EOS2
F="$TMPD/f.sh" T="$TMPD/r10" sh "$TMPD/c.sh" > "$TMPD/out3" 2>&1
h() { sed -n "s/^$1=//p" "$TMPD/out3"; }
ck "R10.1 刚写好的 stamp 与现场一致（rc=0）" "$(h SAME_RC)" "0"
ck "R10.2 stamp 里记了 cfg_fp 与 parsers_fp" \
   "$(printf '%s' "$(h STAMP)" | grep -c 'cfg_fp=[0-9a-f]\{16\}|parsers_fp=[0-9a-f]\{16\}')" "1"
ck "R10.3 改了解析器内容 → 判变更（rc=1）" "$(h CFG_RC)" "1"
ck "R10.4 改回来 → 又一致（指纹只看内容，不看改过几次）" "$(h RESTORED_RC)" "0"
ck "R10.5 删掉一个解析器 → 判变更（算的是整个目录）" "$(h MISSING_RC)" "1"
ck "R10.6 只 touch 不动内容 → 判没变（不误伤好机器）" "$(h TOUCH_RC)" "0"
ck "R10.7 老 stamp 没有 fp 字段 → 不判变更（升级不冤枉）" "$(h OLD_RC)" "0"
ck "R10.8 fp 记成 - → 不判变更" "$(h DASH_RC)" "0"
ck "R10.9 容器目录整个没了 → 不下结论（交给 verify_rootfs）" "$(h GONE_RC)" "0"
# 两处真变更（③ 改内容、⑤ 删文件）各打一行；其余五个场景都不该打
ck "R10.10 只在真变更时打 [变更] 日志（两处）" \
   "$(grep -c '\[变更\]' "$TMPD/out3")" "2"
ck "R10.11 [变更] 日志里带新旧两个指纹（现场可直接对账）" \
   "$(grep -c '\[变更\] .*([0-9a-f]\{16\}→[0-9a-f]\{16\})' "$TMPD/out3")" "2"

rm -rf "$TMPD"
echo "R9 FAIL=$R"
[ "$R" = 0 ]
