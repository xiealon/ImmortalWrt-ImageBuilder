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

# run 包里以裸 gz 形式附带的内核（ssr-plus 的 mihomo.gz）：它的 install.sh 只在直接执行 run 时
# 才解到 /usr/bin，走 ImageBuilder 时只收 ipk，这里补一步，否则装了 luci-app-ssr-plus 却没有内核
for _gz in "$TEMP_DIR"/*.gz; do
    [ -e "$_gz" ] || continue
    _n=$(basename "$_gz" .gz)
    mkdir -p files/usr/bin
    gzip -dc "$_gz" > "files/usr/bin/$_n" || { echo "::error::解压 $_gz 失败"; exit 1; }
    chmod +x "files/usr/bin/$_n"
    echo "✅ 内核已解出: files/usr/bin/$_n ($(stat -c%s "files/usr/bin/$_n") bytes)"
done


find "$BASE_DIR" -mindepth 2 -maxdepth 2 -type f -name "*.ipk" ! -path "$TEMP_DIR/*" \
  -exec echo "📜 Found:" {} \; \
  -exec cp -v {} "$TARGET_DIR"/ \;

echo "✅ 所有 .ipk 文件已整理至 $TARGET_DIR/"
