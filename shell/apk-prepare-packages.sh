#!/bin/sh

BASE_DIR="extra-packages"
TEMP_DIR="$BASE_DIR/temp-unpack"
TARGET_DIR="packages"

# 【v.180.79】run 包换成自己仓库 CloudRunFilesBuilder 的版本（理由同 24.10 线的
# prepare-packages.sh：wukongdaily/apk 的 run 也靠人工同步，mosdns 停在 5.3.4-r5）。
# 两个额外注意点：
#   ① 资产名带 25- 前缀，正则必须锚在斜杠后，否则会取到 24.10 的 ipk 版；
#   ② apk 仓库里 clashoo 是 run/x86/clashoo/ 目录（三个 apk），不是 run 文件，
#      所以连目录一起删，否则旧 apk 会被下面的 find 收进 packages/。
for _pkg in clashoo mosdns; do
    _url=$(curl -sL https://api.github.com/repos/xiealon/CloudRunFilesBuilder/releases/latest \
        | grep -o '"browser_download_url": *"[^"]*"' | cut -d'"' -f4 \
        | grep -E "/25-${_pkg}[_-]v?[0-9]" | grep -E '_x86_64\.run$' | head -n1)
    if [ -z "$_url" ]; then
        echo "::warning::取不到 25-${_pkg} 的最新 run，沿用 $BASE_DIR 里的旧包"
        continue
    fi
    rm -f "$BASE_DIR"/25-${_pkg}_*.run
    rm -rf "$BASE_DIR"/${_pkg}
    wget -q "$_url" -P "$BASE_DIR"/ \
        || { echo "::error::下载 25-${_pkg} 失败: $_url"; exit 1; }
    echo "✅ 25-${_pkg} 已换新: $(basename "$_url")"
done

rm -rf "$TEMP_DIR" "$TARGET_DIR"
mkdir -p "$TEMP_DIR" "$TARGET_DIR"

for run_file in "$BASE_DIR"/*.run; do
    [ -e "$run_file" ] || continue
    echo "🧩 解压 $run_file -> $TEMP_DIR"
    sh "$run_file" --target "$TEMP_DIR" --noexec
done

find "$TEMP_DIR" -type f -name "*.apk" -exec cp -v {} "$TARGET_DIR"/ \;


find "$BASE_DIR" -mindepth 2 -maxdepth 2 -type f -name "*.apk" ! -path "$TEMP_DIR/*" \
  -exec echo "👉 Found:" {} \; \
  -exec cp -v {} "$TARGET_DIR"/ \;

echo "✅ 所有 .apk 文件已整理至 $TARGET_DIR/"
