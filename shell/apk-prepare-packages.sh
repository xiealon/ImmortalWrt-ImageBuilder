#!/bin/sh

BASE_DIR="extra-packages"
TEMP_DIR="$BASE_DIR/temp-unpack"
TARGET_DIR="packages"

# 【v.181】run 包固定取自己仓库 CloudRunFilesBuilder 的 extra 标签（理由同 24.10 线的
# prepare-packages.sh）：上游 25.12 workflow 每次构建完会把 apk 包以固定文件名覆盖到 extra。
#   https://github.com/xiealon/CloudRunFilesBuilder/releases/download/extra/25-clashoo_x86_64.run
#   https://github.com/xiealon/CloudRunFilesBuilder/releases/download/extra/25-mosdns_x86_64.run
# 不再走 releases/latest + 正则筛选：latest 会被别的 release 抢占，
# 且同一包存在新旧两份时 head -n1 可能拿到旧的。
# 两个额外注意点：
#   ① 资产名带 25- 前缀，否则会取到 24.10 的 ipk 版；
#   ② apk 仓库里 clashoo 是 run/x86/clashoo/ 目录（三个 apk），不是 run 文件，
#      所以连目录一起删，否则旧 apk 会被下面的 find 收进 packages/。
RUN_BASE="https://github.com/xiealon/CloudRunFilesBuilder/releases/download/extra"
for _pkg in clashoo mosdns; do
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


find "$BASE_DIR" -mindepth 2 -maxdepth 2 -type f -name "*.apk" ! -path "$TEMP_DIR/*" \
  -exec echo "📜 Found:" {} \; \
  -exec cp -v {} "$TARGET_DIR"/ \;

echo "✅ 所有 .apk 文件已整理至 $TARGET_DIR/"
