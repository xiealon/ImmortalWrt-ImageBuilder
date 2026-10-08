#!/bin/bash
# Log file for debugging
source shell/custom-packages.sh
source shell/switch_repository.sh
echo "第三方软件包: $CUSTOM_PACKAGES"
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
  # 同步第三方软件仓库run/ipk
  echo "🔄 正在同步第三方软件仓库 Cloning run file repo..."
  git clone --depth=1 https://github.com/wukongdaily/store.git /tmp/store-run-repo

  # 拷贝 run/x86 下所有 run 文件和ipk文件 到 extra-packages 目录
  mkdir -p /home/build/immortalwrt/extra-packages
  cp -r /tmp/store-run-repo/run/x86/* /home/build/immortalwrt/extra-packages/

  echo "✅ Run files copied to extra-packages:"
  ls -lh /home/build/immortalwrt/extra-packages/*.run
  # 解压并拷贝ipk到packages目录
  sh shell/prepare-packages.sh
  ls -lah /home/build/immortalwrt/packages/
fi

# 输出调试信息
echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建固件..."

# ============= imm仓库内的插件==============
# 定义所需安装的包列表 下列插件你都可以自行删减
PACKAGES=""
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES -dnsmasq dnsmasq-full"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"

# 24.10
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES base-files coreutils-nohup"

# 文件管理器
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"
# ======== shell/custom-packages.sh =======
# 合并imm仓库以外的第三方插件
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
      | grep "browser_download_url.*ipk" \
      | head -n1 \
      | cut -d '"' -f 4)
    echo "OpenClash latest ipk: $URL"
    wget "$URL" -P /home/build/immortalwrt/packages/
else
    echo "⚪️ 未选择 luci-app-openclash"
fi

# ============ aria2 下载目录：编译期就固化进镜像 ============
# 目标：刷完机 /aria2 直接存在、属主正确、服务已启用，不依赖首次开机脚本成功执行。
#
# 机制（都核对过上游源码）：
#   ImageBuilder 用 `cp -fpR files/. <rootfs>/` 把 FILES 拷进镜像（rules.mk: CP:=cp -fpR）
#     - 空目录会一起拷进去 → 所以 /aria2 会存在
#     - -p 会保留权限和属主 → 所以这里 chown 的 6800:6800 能被带进镜像
#     - git 不追踪空目录 → 不能只靠仓库里放一个 files/aria2，必须在编译期现建
#   6800 = aria2 包的 USERID（net/aria2/Makefile: USERID:=aria2=6800:aria2=6800）。
#   99-custom.sh 里还留了一次兜底 chown，万一上游改 uid 也不会翻车。
mkdir -p files/aria2/.aria2
chown 6800:6800 files/aria2 files/aria2/.aria2
chmod 775 files/aria2
chmod 700 files/aria2/.aria2

# 顺带把 aria2 的 uci 配置也固化下来（enabled 默认是 0，想要开机就跑就得写 1）。
# ⚠️ 必须写 files/etc/config/，不要在仓库里提交 files/etc/config/aria2：
#    workflow 把宿主机的 custom/ 挂到了 files/etc/config/，仓库里那个目录
#    在容器内是被盖住看不见的（后挂的子路径覆盖先挂的父路径）。
#    反过来，容器内往 files/etc/config/ 写文件 = 写进宿主机 custom/，
#    最终就会成为固件里的 /etc/config/。
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

# 构建镜像
echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"

make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files" ROOTFS_PARTSIZE=$PROFILE

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
