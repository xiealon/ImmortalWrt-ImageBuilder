#!/bin/bash
# Log file for debugging
# 目前支持少部分第三方软件apk 通过打开shell/apk-custom-packages.sh的注释来集成
source shell/apk-custom-packages.sh
echo "第三方apk软件包: $CUSTOM_PACKAGES"
LOGFILE="/tmp/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >> $LOGFILE
echo "编译固件大小为: $PROFILE MB"
echo "Include Docker: $INCLUDE_DOCKER"

# custom_router_ip.txt 等由 workflow 生成后，靠 docker -v 挂到这个目录下，
# 99-custom.sh 开机时会从这里读取 IP / 网关 / DNS。目录必须存在。
mkdir -p /home/build/immortalwrt/files/etc/config

if [ -z "$CUSTOM_PACKAGES" ]; then
  echo "⚪️ 未选择 任何第三方软件包"
else
  # ============= 同步第三方插件库==============
  # 同步第三方软件仓库run/apk
  echo "🔄 正在同步第三方软件仓库 Cloning run file repo..."
  git clone --depth=1 https://github.com/wukongdaily/apk.git /tmp/store-apk-repo

  # 拷贝 run/x86 下所有 run 文件和apk文件 到 extra-packages 目录
  mkdir -p /home/build/immortalwrt/extra-packages
  cp -r /tmp/store-apk-repo/run/x86/* /home/build/immortalwrt/extra-packages/

  echo "✅ Run files copied to extra-packages:"
  # 解压并拷贝apk到packages目录
  sh shell/apk-prepare-packages.sh
  ls -lah /home/build/immortalwrt/packages/
fi


# 输出调试信息
echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建固件..."

# ============= imm仓库内的插件==============
# 定义所需安装的包列表 下列插件你都可以自行删减
PACKAGES=""
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"
#25.12
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"

# 文件管理器
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"
# ======== shell/apk-custom-packages.sh =======
# 合并imm仓库以外的第三方插件 暂时注释
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"


# 判断是否需要编译 Docker 插件
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "Adding package: luci-i18n-dockerman-zh-cn"
fi

# 若构建openclash 则添加内核
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 已选择 luci-app-openclash，添加 openclash core"
    mkdir -p files/etc/openclash/core
    # Download clash_meta
    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-v1.tar.gz"
    wget -qO- $META_URL | tar xOvz > files/etc/openclash/core/clash_meta
    chmod +x files/etc/openclash/core/clash_meta
    # Download GeoIP and GeoSite
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O files/etc/openclash/GeoIP.dat
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O files/etc/openclash/GeoSite.dat
    # Download latest openclash Client
    URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases/latest \
      | grep "browser_download_url.*apk" \
      | head -n1 \
      | cut -d '"' -f 4)
    echo "OpenClash latest apk: $URL"
    wget "$URL" -P /home/build/immortalwrt/packages/
else
    echo "⚪️ 未选择 luci-app-openclash"
fi

if echo "$PACKAGES" | grep -q "luci-app-ssr-plus"; then
    echo "✅ 已选择 luci-app-ssr-plus，添加 mihomo core"
    mkdir -p files/usr/bin
    # Download mihomo
    MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/download/v1.19.24/mihomo-linux-amd64-compatible-v1.19.24.gz"
    mkdir -p files/usr/bin
    wget -qO- "$MIHOMO_URL" | gzip -dc > files/usr/bin/mihomo
    chmod +x files/usr/bin/mihomo
    echo "✅ 已下载 mihomo core"
    ls -lah files/usr/bin
else
    echo "⚪️ 未选择 luci-app-ssr-plus"
fi

# ============ 可选：加挂第三方 apk 源（25.12 起从 opkg 换成 apk，加源方式变了） ============
# opkg 时代是在 .config 里写 src/gz xxx URL；apk 时代的源清单就是 imagebuilder 根目录的
# repositories.conf，格式是「每行一个 URL」，没有 src/gz 前缀。
#
# 用法（两步，缺一不可，否则 apk 会以 UNTRUSTED signature 拒绝安装）：
#   1) 把第三方源的 URL 通过环境变量 EXTRA_APK_REPOS 传进来（多个用换行分隔）
#   2) 把该源的签名公钥 *.rsa.pub / *.pub 放进仓库的 shell/apk-keys/ 目录，
#      下面会自动拷到 imagebuilder 的 keys/ 去（没有公钥 apk 不认这个源）
REPOS_CONF="/home/build/immortalwrt/repositories.conf"
if [ -n "$EXTRA_APK_REPOS" ] && [ -f "$REPOS_CONF" ]; then
    echo "🔗 加挂第三方 apk 源:"
    echo "$EXTRA_APK_REPOS"
    printf '%s\n' "$EXTRA_APK_REPOS" >> "$REPOS_CONF"
    echo "--- 当前 repositories.conf ---"
    cat "$REPOS_CONF"
else
    echo "⚪️ 未加挂第三方 apk 源"
fi

if [ -d /home/build/immortalwrt/shell/apk-keys ]; then
    mkdir -p /home/build/immortalwrt/keys
    cp -v /home/build/immortalwrt/shell/apk-keys/*.pub /home/build/immortalwrt/keys/ 2>/dev/null
    cp -v /home/build/immortalwrt/shell/apk-keys/*.rsa.pub /home/build/immortalwrt/keys/ 2>/dev/null
fi

# 构建镜像
echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"

make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files" ROOTFS_PARTSIZE=$PROFILE

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
