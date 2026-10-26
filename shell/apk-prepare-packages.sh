#!/bin/sh

BASE_DIR="extra-packages"
TEMP_DIR="$BASE_DIR/temp-unpack"
TARGET_DIR="packages"

# 包来源：extra-packages/ 由 x86-64/build25.sh 从 xiealon/apk 的 run/x86 全量同步
rm -rf "$TEMP_DIR" "$TARGET_DIR"
mkdir -p "$TEMP_DIR" "$TARGET_DIR"

for run_file in "$BASE_DIR"/*.run; do
    [ -e "$run_file" ] || continue
    echo "🧁 解压 $run_file -> $TEMP_DIR"
    sh "$run_file" --target "$TEMP_DIR" --noexec
done

find "$TEMP_DIR" -type f -name "*.apk" -exec cp -v {} "$TARGET_DIR"/ \;

# 2. 收集 extra-packages/*/ 下裸放的 .apk（只查一级子目录）
find "$BASE_DIR" -mindepth 2 -maxdepth 2 -type f -name "*.apk" ! -path "$TEMP_DIR/*" \
  -exec echo "📜 Found:" {} \; \
  -exec cp -v {} "$TARGET_DIR"/ \;

apk_fixname() {
  for f in "$1"/*.apk; do
    [ -e "$f" ] || continue
    cur=$(basename "$f")
    base="${cur%.apk}"
    pn=$(tar -xzOf "$f" .PKGINFO 2>/dev/null | sed -n 's/^pkgname[[:space:]]*=[[:space:]]*//p' | head -n1)
    pv=$(tar -xzOf "$f" .PKGINFO 2>/dev/null | sed -n 's/^pkgver[[:space:]]*=[[:space:]]*//p'  | head -n1)
    if [ -n "$pn" ] && [ -n "$pv" ]; then
      want="$pn-$pv.apk"
    else
      nb=$(printf '%s' "$base" \
        | sed -E 's/-(x86_64|aarch64_[a-z0-9_]+|arm_[a-z0-9_-]+|i386_pentium4|mips[a-z0-9_]*)$//' \
        | sed -E 's/([0-9]{4}\.[0-9]{2}\.[0-9]{2})\./\1~/')
      want="$nb.apk"
    fi
    if [ "$cur" != "$want" ]; then
      mv -f "$f" "$1/$want"
      echo "🔧 apk 名修正: $cur -> $want"
    fi
  done
}

# 【v.186】apk 文件名必须严格等于 <pkgname>-<pkgver>.apk，且 pkgver 与包内
# PKGINFO 完全一致 —— apk index 就是从 PKGINFO 生成的，imagebuilder 的
# package_install 按索引拼文件名去 packages/ 找，找不到就报
#   ERROR: xxx: package mentioned in index not found
# 上游各式各样的"美化"（把 ~ 换成 .、追加 -<arch>、甚至直接把 ~ 删掉，
# 例如 sbwml 的 luci-i18n-mosdns-zh-cn-26.255.53985~73981c0.apk）都没法用
# sed 猜回来，所以这里直接读 PKGINFO 定名。已规范的幂等，不会动。
apk_fixname "$TARGET_DIR"

echo "✅ 所有 .apk 文件已整理至 $TARGET_DIR/"
