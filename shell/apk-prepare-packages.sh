#!/bin/sh

BASE_DIR="extra-packages"
TEMP_DIR="$BASE_DIR/temp-unpack"
TARGET_DIR="packages"

# 【v.186】25.12 的包统一从 extra25 标签取（24.10 在 extra），
# 两个标签里的文件名完全一致，不再带 25- 前缀。
RUN_BASE="https://github.com/xiealon/CloudRunFilesBuilder/releases/download/extra-apk"
for _pkg in clashoo mosdns; do
    rm -f "$BASE_DIR"/${_pkg}_*.run "$BASE_DIR"/25-${_pkg}_*.run
    rm -rf "$BASE_DIR"/${_pkg}
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

find "$TEMP_DIR" -type f -name "*.apk" -exec cp -v {} "$TARGET_DIR"/ \;

# 【v.186】apk 文件名必须严格等于 <pkgname>-<pkgver>.apk，且 pkgver 与包内
# PKGINFO 完全一致 —— apk index 就是从 PKGINFO 生成的，imagebuilder 的
# package_install 按索引拼文件名去 packages/ 找，找不到就报
#   ERROR: xxx: package mentioned in index not found
# 上游各式各样的"美化"（把 ~ 换成 .、追加 -<arch>、甚至直接把 ~ 删掉，
# 例如 sbwml 的 luci-i18n-mosdns-zh-cn-26.255.53985~73981c0.apk）都没法用
# sed 猜回来，所以这里直接读 PKGINFO 定名。已规范的幂等，不会动。
for f in "$TARGET_DIR"/*.apk; do
    [ -e "$f" ] || continue
    pn=$(tar -xzOf "$f" .PKGINFO 2>/dev/null | sed -n 's/^pkgname[[:space:]]*=[[:space:]]*//p' | head -n1)
    pv=$(tar -xzOf "$f" .PKGINFO 2>/dev/null | sed -n 's/^pkgver[[:space:]]*=[[:space:]]*//p'  | head -n1)
    if [ -z "$pn" ] || [ -z "$pv" ]; then
        echo "::warning::读不到 PKGINFO，跳过: $(basename "$f")"
        continue
    fi
    cur=$(basename "$f")
    if [ "$cur" != "$pn-$pv.apk" ]; then
        mv -f "$f" "$TARGET_DIR/$pn-$pv.apk"
        echo "🔧 apk 名以 PKGINFO 为准: $cur -> $pn-$pv.apk"
    fi
done

find "$BASE_DIR" -mindepth 2 -maxdepth 2 -type f -name "*.apk" ! -path "$TEMP_DIR/*" \
  -exec echo "📜 Found:" {} \; \
  -exec cp -v {} "$TARGET_DIR"/ \;

echo "✅ 所有 .apk 文件已整理至 $TARGET_DIR/"
