#!/bin/sh

BASE_DIR="extra-packages"
TEMP_DIR="$BASE_DIR/temp-unpack"
TARGET_DIR="packages"

# 包来源：extra-packages/ 由 x86-64/build24.sh 从 xiealon/store 的 run/x86 全量同步
# 注意：同步用的是 cp -r，run/x86 下的子目录（luci-app-lucky/ luci-app-easytier/
# luci-app-partexp/ luci-app-taskplan/ tailscale-community/ 等）会整个落到
# extra-packages/<子目录>/，里面的散装 ipk 必须单独收一遍；只收 run 解压产物会漏掉，
# 表现就是 opkg 报 Unknown package 'luci-app-lucky' 之类然后 image 构建失败。

rm -rf "$TEMP_DIR" "$TARGET_DIR"
mkdir -p "$TEMP_DIR" "$TARGET_DIR"

for run_file in "$BASE_DIR"/*.run; do
    [ -e "$run_file" ] || continue
    echo "🧁 解压 $run_file -> $TEMP_DIR"
    sh "$run_file" --target "$TEMP_DIR" --noexec
done

# 1. 收集 .run 解压出来的 .ipk
find "$TEMP_DIR" -type f -name "*.ipk" -exec cp -v {} "$TARGET_DIR"/ \;

# 2. 收集 extra-packages/*/ 下的 .ipk（只查一级子目录，排除 temp-unpack）
find "$BASE_DIR" -mindepth 2 -maxdepth 2 -type f -name "*.ipk" ! -path "$TEMP_DIR/*" \
  -exec echo "📦 Found:" {} \; \
  -exec cp -v {} "$TARGET_DIR"/ \;

echo "✅ 所有 .ipk 文件已整理至 $TARGET_DIR/"
