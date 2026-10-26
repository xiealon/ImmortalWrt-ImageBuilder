#!/bin/sh

BASE_DIR="extra-packages"
TEMP_DIR="$BASE_DIR/temp-unpack"
TARGET_DIR="packages"

# 包来源：extra-packages/ 由 x86-64/build24.sh 从 xiealon/store 的 run/x86 全量同步

rm -rf "$TEMP_DIR" "$TARGET_DIR"
mkdir -p "$TEMP_DIR" "$TARGET_DIR"

for run_file in "$BASE_DIR"/*.run; do
    [ -e "$run_file" ] || continue
    echo "🧁 解压 $run_file -> $TEMP_DIR"
    sh "$run_file" --target "$TEMP_DIR" --noexec
done

find "$TEMP_DIR" -type f -name "*.ipk" -exec cp -v {} "$TARGET_DIR"/ \;

echo "✅ 所有 .ipk 文件已整理至 $TARGET_DIR/"
