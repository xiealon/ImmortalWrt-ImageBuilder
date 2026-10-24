#!/bin/sh

BASE_DIR="extra-packages"
TEMP_DIR="$BASE_DIR/temp-unpack"
TARGET_DIR="packages"

# 【v.180.79】run 包换成自己仓库 CloudRunFilesBuilder 的版本。
# 它由 Actions 每天构建（clashoo 取 kenzok8/openwrt-clashoo、mosdns 取 sbwml/luci-app-mosdns
# 的最新正式版），而 build24.sh 拷过来的 wukongdaily/store 靠人工同步，
# clashoo 一直停在 2026.05.15、mosdns 停在 5.3.4-r1。
# 必须先删旧 run：下面会把 $BASE_DIR/*.run 全解一遍，两份并存就是两个版本的 ipk
# 同时进 packages/，最后装哪个取决于文件名排序 —— 看着更新了、其实没更新。
for _pkg in clashoo mosdns; do
    _url=$(curl -sL https://api.github.com/repos/xiealon/CloudRunFilesBuilder/releases/latest \
        | grep -o '"browser_download_url": *"[^"]*"' | cut -d'"' -f4 \
        | grep -E "/${_pkg}[_-]v?[0-9]" | grep -E '_x86_64\.run$' | head -n1)
    if [ -z "$_url" ]; then
        echo "::warning::取不到 ${_pkg} 的最新 run，沿用 $BASE_DIR 里的旧包"
        continue
    fi
    rm -f "$BASE_DIR"/${_pkg}_*.run
    wget -q "$_url" -P "$BASE_DIR"/ \
        || { echo "::error::下载 ${_pkg} 失败: $_url"; exit 1; }
    echo "✅ ${_pkg} 已换新: $(basename "$_url")"
done

rm -rf "$TEMP_DIR" "$TARGET_DIR"
mkdir -p "$TEMP_DIR" "$TARGET_DIR"

for run_file in "$BASE_DIR"/*.run; do
    [ -e "$run_file" ] || continue
    echo "🧩 解压 $run_file -> $TEMP_DIR"
    sh "$run_file" --target "$TEMP_DIR" --noexec
done

find "$TEMP_DIR" -type f -name "*.ipk" -exec cp -v {} "$TARGET_DIR"/ \;


find "$BASE_DIR" -mindepth 2 -maxdepth 2 -type f -name "*.ipk" ! -path "$TEMP_DIR/*" \
  -exec echo "👉 Found:" {} \; \
  -exec cp -v {} "$TARGET_DIR"/ \;

echo "✅ 所有 .ipk 文件已整理至 $TARGET_DIR/"
