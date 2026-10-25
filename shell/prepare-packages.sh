#!/bin/sh

BASE_DIR="extra-packages"
TEMP_DIR="$BASE_DIR/temp-unpack"
TARGET_DIR="packages"

# 【v.181】run 包固定取自己仓库 CloudRunFilesBuilder 的 extra 标签。
# 上游 workflow 每次构建完，会把该包以固定文件名覆盖到 extra：
#   https://github.com/xiealon/CloudRunFilesBuilder/releases/download/extra/clashoo_x86_64.run
# 不再走 releases/latest + 正则筛选：latest 会被别的 release 抢占（例如 lxc-latest），
# 且同一包存在新旧两份时 head -n1 可能拿到旧的。
# 必须先后旧 run：下面会把 $BASE_DIR/*.run 全解一遍，两份并存就是两个版本的 ipk
# 同时进 packages/，最后谁赢取决于文件名排序 —— 看着更新了、其实没更新。
RUN_BASE="https://github.com/xiealon/CloudRunFilesBuilder/releases/download/extra"
for _pkg in clashoo mosdns; do
    rm -f "$BASE_DIR"/${_pkg}_*.run
    wget -q "$RUN_BASE/${_pkg}_x86_64.run" -P "$BASE_DIR"/ \
        || { echo "::error::下载 ${_pkg} 失败: $RUN_BASE/${_pkg}_x86_64.run"; exit 1; }
    echo "✅ ${_pkg} 已取: ${_pkg}_x86_64.run ($(stat -c%s "$BASE_DIR/${_pkg}_x86_64.run") bytes)"
done

rm -rf "$TEMP_DIR" "$TARGET_DIR"
mkdir -p "$TEMP_DIR" "$TARGET_DIR"

for run_file in "$BASE_DIR"/*.run; do
    [ -e "$run_file" ] || continue
    echo "🧁 解压 $run_file -> $TEMP_DIR"
    sh "$run_file" --target "$TEMP_DIR" --noexec
done

find "$TEMP_DIR" -type f -name "*.ipk" -exec cp -v {} "$TARGET_DIR"/ \;


find "$BASE_DIR" -mindepth 2 -maxdepth 2 -type f -name "*.ipk" ! -path "$TEMP_DIR/*" \
  -exec echo "📜 Found:" {} \; \
  -exec cp -v {} "$TARGET_DIR"/ \;

echo "✅ 所有 .ipk 文件已整理至 $TARGET_DIR/"
