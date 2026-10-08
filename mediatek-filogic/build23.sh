#!/bin/bash
source shell/custom-packages.sh
source shell/switch_repository.sh
# 该文件实际为imagebuilder容器内的build.sh

if [ -n "$CUSTOM_PACKAGES" ]; then
  echo "✅ 你选择了第三方软件包：$CUSTOM_PACKAGES"
  if [ "$PROFILE" = "glinet_gl-mt3000" ]; then
    echo "❌ 检查到您集成了第三方软件包 由于mt3000闪存空间较小 不支持此操作"
    echo "✅ 系统将自动帮你注释掉shell/custom-packages.sh中的插件 目前支持第三方插件集成的机型是mt2500/mt6000等大闪存机型"
    CUSTOM_PACKAGES=""
  else
    # 下载 run 文件仓库
    echo "🔄 正在同步第三方软件仓库 Cloning run file repo..."
    git clone --depth=1 https://github.com/wukongdaily/store.git /tmp/store-run-repo

    # 拷贝 run/arm64 下所有 run 文件和ipk文件 到 extra-packages 目录
    mkdir -p /home/build/immortalwrt/extra-packages
    cp -r /tmp/store-run-repo/run/arm64/* /home/build/immortalwrt/extra-packages/

    echo "✅ Run files copied to extra-packages:"
    ls -lh /home/build/immortalwrt/extra-packages/*.run
    # 解压并拷贝ipk到packages目录
    sh shell/prepare-packages.sh
    ls -lah /home/build/immortalwrt/packages/
    # 添加架构优先级信息
    sed -i '1i\
    arch aarch64_generic 10\n\
    arch aarch64_cortex-a53 15' repositories.conf
  fi
else
  echo "⚪️ 未选择任何第三方软件包"
fi
# yml 传入的路由器型号 PROFILE
echo "Building for profile: $PROFILE"
echo "Include Docker: $INCLUDE_DOCKER"
mkdir -p  /home/build/immortalwrt/files/etc/config

# 输出调试信息
echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting build process..."

# 定义所需安装的包列表 下列插件你都可以自行删减
PACKAGES=""
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-i18n-filebrowser-zh-cn"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
#23.05
PACKAGES="$PACKAGES luci-i18n-opkg-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES luci-i18n-passwall-zh-cn"
PACKAGES="$PACKAGES luci-app-openclash"
PACKAGES="$PACKAGES luci-i18n-homeproxy-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"
# 增加几个必备组件 方便用户安装iStore
PACKAGES="$PACKAGES fdisk"
PACKAGES="$PACKAGES script-utils"
# 第三方软件包 合并
# ======== shell/custom-packages.sh =======
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
    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-arm64.tar.gz"
    wget -qO- $META_URL | tar xOvz > files/etc/openclash/core/clash_meta
    chmod +x files/etc/openclash/core/clash_meta
    # Download GeoIP and GeoSite
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O files/etc/openclash/GeoIP.dat
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O files/etc/openclash/GeoSite.dat
else
    echo "⚪️ 未选择 luci-app-openclash"
fi

# ============ aria2 下载目录：仅当固件包含 aria2 才固化进镜像 ============
# 判定：PACKAGES 里出现 aria2（含 luci-i18n-aria2* / luci-app-aria2 / aria2）即视为装了。
# 不满足就跳过，避免往镜像里塞一个没有对应二进制的假配置。
# 机制（核对过上游源码）：ImageBuilder 用 cp -fpR 把 files/ 拷进 rootfs，
#   -p 保留属主 → 这里 chown 的 6800:6800（aria2 包 USERID）会带进镜像。
case " $PACKAGES " in
    *" aria2 "*|*" luci-i18n-aria2"*|*" luci-app-aria2"*)
        mkdir -p files/aria2/.aria2
        chown 6800:6800 files/aria2 files/aria2/.aria2
        chmod 775 files/aria2
        chmod 700 files/aria2/.aria2
        mkdir -p files/etc/config
        cat > files/etc/config/aria2 <<'EOF'
config aria2 'main'
	option enabled '1'
	option user 'aria2'
	option dir '/aria2'
	option config_dir '/aria2/.aria2'
	option bt_enable_lpd 'true'
	option enable_dht 'true'
	option follow_torrent 'true'
	option file_allocation 'none'
	option save_session_interval '30'
	option seed_time '0'
	option max_overall_upload_limit '50k'
	option max_upload_limit '50k'
	list header ''
	list bt_tracker ''
	list extra_settings ''
EOF
        echo "✅ aria2 下载目录 + 配置已写入 files/"
        ls -ld files/aria2 files/aria2/.aria2 files/etc/config/aria2
        ;;
    *)
        echo "⚪️ 未选择 aria2，跳过下载目录固化"
        ;;
esac

# 构建镜像
echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"

make image PROFILE=$PROFILE PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files"

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
