#!/bin/sh

BASE_DIR="extra-packages"
TEMP_DIR="$BASE_DIR/temp-unpack"
TARGET_DIR="packages"

# 【v.181】run 包固定取自己仓库 CloudRunFilesBuilder 的 extra 标签（理由同 24.10 线的
# prepare-packages.sh）：上游 25.12 workflow 每次构建完会把 apk 包以固定文件名覆盖到 extra。
#   https://github.com/xiealon/CloudRunFilesBuilder/releases/download/extra/25-clashoo_x86_64.run
# 不再走 releases/latest + 正则筛选：latest 会被别的 release 抢占，
# 且同一包存在新旧两份时 head -n1 可能拿到旧的。
# 两个额外注意点：
#   ① 资产名带 25- 前缀，否则会取到 24.10 的 ipk 版；
#   ② apk 仓库里 clashoo 是 run/x86/clashoo/ 目录（三个 apk），不是 run 文件，
#      所以连目录一起删，否则旧 apk 会被下面的 find 收进 packages/。
RUN_BASE="https://github.com/xiealon/CloudRunFilesBuilder/releases/download/extra"
for _pkg in clashoo; do
    rm -f "$BASE_DIR"/25-${_pkg}_*.run
    rm -rf "$BASE_DIR"/${_pkg}
    wget -q "$RUN_BASE/25-${_pkg}_x86_64.run" -P "$BASE_DIR"/ \
        || { echo "::error::下载 25-${_pkg} 失败: $RUN_BASE/25-${_pkg}_x86_64.run"; exit 1; }
    echo "✅ 25-${_pkg} 已取: 25-${_pkg}_x86_64.run ($(stat -c%s "$BASE_DIR/25-${_pkg}_x86_64.run") bytes)"
done

rm -rf "$TEMP_DIR" "$TARGET_DIR"
mkdir -p "$TEMP_DIR" "$TARGET_DIR"

for run_file in "$BASE_DIR"/*.run; do
    [ -e "$run_file" ] || continue
    echo "🧁 解压 $run_file -> $TEMP_DIR"
    sh "$run_file" --target "$TEMP_DIR" --noexec
done

find "$TEMP_DIR" -type f -name "*.apk" -exec cp -v {} "$TARGET_DIR"/ \;

# 【v.182】apk 文件名必须严格等于 <pkgname>-<pkgver>.apk。
# 上游 kenzok8/openwrt-clashoo 为区分架构，把 PKGINFO 里 pkgver 的 "~" 改写成 "."，
# 并在文件名尾部追加 -<arch>：
#   磁盘上的名字  clashoo-2026.10.24.91e85ee-r1-x86_64.apk
#   索引里的真名  clashoo-2026.10.24~91e85ee-r1   （apk index 从 PKGINFO 读）
# imagebuilder 的 package_install 阶段按索引里的 pkgname-pkgver 拼文件名去
# packages/ 找包，拼出来的东西不存在，于是报 3 条：
#   ERROR: clashoo-2026.10.24~91e85ee-r1: package mentioned in index not found
#   ERROR: luci-app-clashoo-1.31.0-r6: package mentioned in index not found
#   ERROR: luci-i18n-clashoo-zh-cn-1.31.0-r6: package mentioned in index not found
# 这里把名字还原成索引期望的形式：去掉架构后缀，再把 YYYY.MM.DD. 的最后一个点换回 "~"。
# 已经规范的名字不会被改动（幂等）。
for f in "$TARGET_DIR"/*.apk; do
    [ -e "$f" ] || continue
    b=$(basename "$f" .apk)
    nb=$(printf '%s' "$b" \
        | sed -E 's/-(x86_64|aarch64_[a-z0-9_]+|arm_[a-z0-9_-]+|i386_pentium4|mips[a-z0-9_]*)$//' \
        | sed -E 's/([0-9]{4}\.[0-9]{2}\.[0-9]{2})\./\1~/')
    if [ "$nb" != "$b" ]; then
        mv -f "$f" "$TARGET_DIR/$nb.apk"
        echo "🔧 apk 名规范化: $b.apk -> $nb.apk"
    fi
done



find "$BASE_DIR" -mindepth 2 -maxdepth 2 -type f -name "*.apk" ! -path "$TEMP_DIR/*" \
  -exec echo "📜 Found:" {} \; \
  -exec cp -v {} "$TARGET_DIR"/ \;

echo "✅ 所有 .apk 文件已整理至 $TARGET_DIR/"
