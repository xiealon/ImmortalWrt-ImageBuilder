#!/bin/bash
# 【v.108.72】固件版本标记 —— 与 crowdsec-lxc-bootstrap.sh 的 SCRIPT_VER 同步，每次改脚本一起改
source shell/custom-packages.sh
source shell/switch_repository.sh
echo "第三方软件包: $CUSTOM_PACKAGES"
LOGFILE="/tmp/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >> $LOGFILE
echo "编译固件大小为: $PROFILE MB"

mkdir -p /home/build/immortalwrt/files/etc/config

# custom/ 由 workflow 挂到 /home/build/immortalwrt/custom（v.108.9）。
# 旧写法直接把 custom 挂到 files/etc/config 上，Docker 的 bind mount 会整体遮蔽
# 该目录 —— 仓库里固化在 files/etc/config 下的文件（lxc-auto）永远进不了镜像，
# 镜像落回软件包自带的默认模板。改成挂到独立目录、由这里拷进来：注入的
# /etc/config/*.txt 照样进镜像，固化的文件也不再被吃掉。
for _cf in /home/build/immortalwrt/custom/*; do
    [ -f "$_cf" ] || continue
    # 固化配置优先：action 注入不该有本事把 lxc-auto 覆盖成别的容器名，
    # 那会让 lxc-auto 服务拉错容器（或一个都不拉），且现场毫无报错。
    case "$(basename "$_cf")" in
        lxc-auto)
            echo "::warning::custom/ 里出现了 lxc-auto，已忽略（容器配置由 files/etc/config 固化）"
            continue ;;
    esac
    cp -f "$_cf" /home/build/immortalwrt/files/etc/config/ \
        || { echo "::error::拷贝 $_cf 到 files/etc/config 失败"; exit 1; }
done

if [ -z "$CUSTOM_PACKAGES" ]; then
  echo "⚪️ 未选择 任何第三方软件包"
else
  echo "🔄 正在同步第三方软件仓库 Cloning run file repo..."
  git clone --depth=1 https://github.com/wukongdaily/store.git /tmp/store-run-repo

  mkdir -p /home/build/immortalwrt/extra-packages
  cp -r /tmp/store-run-repo/run/x86/* /home/build/immortalwrt/extra-packages/

  echo "✅ Run files copied to extra-packages:"
  ls -lh /home/build/immortalwrt/extra-packages/*.run
  sh shell/prepare-packages.sh
  ls -lah /home/build/immortalwrt/packages/
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建固件..."

PACKAGES=""
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES -dnsmasq dnsmasq-full"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"

PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES base-files coreutils-nohup"

PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

# Docker 包已固定写在 shell/custom-packages.sh 里（v.99-bp.2：纯 X86，不再由开关控制）

if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 已选择 luci-app-openclash，添加 openclash core"
    mkdir -p files/etc/openclash/core
    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-v1.tar.gz"
    wget -qO- $META_URL | tar xOvz > files/etc/openclash/core/clash_meta
    chmod +x files/etc/openclash/core/clash_meta
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O files/etc/openclash/GeoIP.dat
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O files/etc/openclash/GeoSite.dat
    URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases/latest \
      | grep "browser_download_url.*ipk" \
      | head -n1 \
      | cut -d '"' -f 4)
    echo "OpenClash latest ipk: $URL"
    wget "$URL" -P /home/build/immortalwrt/packages/
else
    echo "⚪️ 未选择 luci-app-openclash"
fi

# 【v.108.71】SSR Plus → Clashoo。
# 原来这段在 PACKAGES 里出现 luci-app-ssr-plus 时，把 mihomo 内核单独下到 files/usr/bin/mihomo。
# clashoo 不需要这一步：它的主包已经把 mihomo 打进去了
# （control: Provides: mihomo, clash-meta；Installed-Size 46,499,840 B）。
# 再下一份就是同一台机器上两套内核、两条版本线，谁生效取决于 PATH 和谁先起 —— 删掉。
# 换成一个现场断言：store 的 run 包必须真的解出了 clashoo 的 ipk。
# 不这么做的话，失败会以 `make image` 的 Unknown package 'clashoo' 收场，
# 看不出是「store 没给这个包」还是「包名写错了」。
if echo "$PACKAGES" | grep -q "clashoo"; then
    _cl_ipk=$(ls packages/clashoo_*.ipk 2>/dev/null | head -n1)
    _cl_luci=$(ls packages/luci-app-clashoo_*.ipk 2>/dev/null | head -n1)
    if [ -z "$_cl_ipk" ] || [ -z "$_cl_luci" ]; then
        echo "::error::PACKAGES 里选了 clashoo，但 packages/ 下缺包（clashoo=$_cl_ipk luci=$_cl_luci）——store 的 run 没解出 ipk"
        ls -la packages/ 2>/dev/null || true
        echo "::error::预期来自 wukongdaily/store 的 run/x86/clashoo_2026.05.15_x86_64.run"
        exit 1
    fi
    echo "✅ clashoo 就位: $_cl_ipk + $_cl_luci（自带 mihomo 内核，不再单独下载）"
else
    echo "⚪️ 未选择 clashoo"
fi

case " $PACKAGES " in
    *" luci-i18n-aria2"*)
        mkdir -p files/aria2
        chown 6800:6800 files/aria2
        chmod 775 files/aria2
        echo "✅ aria2 下载目录 /aria2 已建（编译期）"
        ;;
    *)
        echo "⚪️ 未选择 aria2，跳过 /aria2 目录创建"
        ;;
esac

# 【v.108.45 → v.108.56】guard 的静态基准。
# 现在基底已整份在 squashfs（$BASE_DIR），这 16 个文件本来就在里面，再拷一遍是为了
# 「与 rootfs-skel 单一来源对齐」——prebuilt 包若比仓库旧，以仓库版本为准。
# 仍然不放进来的：config.yaml / crowdsec-net.conf / resolv.conf。
# 它们由 bootstrap 的 capi / ct_net / ct_resolv 每轮重写，
# 固化进只读层就是「bootstrap 写 → guard 改回去」的死循环。
# 【v.108.60】acquis.yaml 反过来从「不进来」变成「必须进来」：它是日志入口，
# config.yaml 的 acquisition_path 指着它，而 v.108.46 之后 bootstrap 不再重写它
# （setup_acquis 只校验 router.yaml 那三份）。以前它被删只能靠 _structurally_broken
# 判整盘损坏 → 重装 288MB，现在由 guard 一次原子 cp 复原。
# 【v.108.56】容器固定文件进 squashfs：把 prebuilt 包展开成只读基底。
# 为什么不再「tarball 原样进固件、首启解压」：
#   ① tarball 是个压缩包，guard 没法用 cmp 比它；展开进 squashfs 后才有同路径散文件；
#   ② 首启省掉 288MB 解压（真机实测这是开机最重的一段）；
#   ③ 固定文件落在 lower，容器内改不动 —— 保护从「每 60 秒盖回去」变成「物理不可写」。
# 体积账：tarball 107MB 换成 squashfs 里的 base，压缩后大致相当，固件几乎不变大；
# 所以包解压完就删，不让同一份内容在固件里存两次。
BASE_DIR="files/srv/lxc/ubuntu/base"
TARBALL_IN="files/etc/crowdsec/lxc-crowdsec.tar.gz"
if [ -f "$TARBALL_IN" ]; then
    echo "==> 展开容器只读基底 → $BASE_DIR"
    rm -rf "$BASE_DIR"
    mkdir -p "$BASE_DIR"
    tar -xzpf "$TARBALL_IN" -C "$BASE_DIR" \
        || { echo "::error::展开容器基底失败（$TARBALL_IN）"; exit 1; }
    for _need in etc/os-release etc/inittab usr/bin/crowdsec etc/crowdsec/acquis.yaml; do
        [ -e "$BASE_DIR/$_need" ] \
            || { echo "::error::基底缺 $_need —— 包结构不对，不能进固件"; exit 1; }
    done
    # 指纹给运行期用：upper 记着自己照着哪版基底建的，不符就整层丢弃，
    # 否则换固件后旧 upper 会永久遮住新基底的同名文件 —— 看着升级了，其实没升。
    sha256sum "$TARBALL_IN" | awk '{print $1}' > "$BASE_DIR.fingerprint"
    echo "==> 基底就绪：$(du -sh "$BASE_DIR" | cut -f1)，指纹 $(cat "$BASE_DIR.fingerprint")"
    rm -f "$TARBALL_IN"
    echo "==> 已从固件移除 prebuilt 包（内容已在 $BASE_DIR）"
else
    # 【v.108.59】workflow 只剩 prebuilt 一条路：本地 Prepare 回退已删，Download 步骤
    # 取不到包就在自己那一步 ::error:: + exit 1。这里是最后一道兜底 —— 万一哪天有人
    # 把那句 exit 去掉，也不能让空基底混进固件。
    # 继续构建只会得到「网络正常、容器永不启动」的固件 —— 现场表现是 rc.local 静默走
    # --net-only，路由器好好的，容器永远不来，属于最难查的一类。宁可让构建失败。
    echo "::error::没有容器基底：files/etc/crowdsec/lxc-crowdsec.tar.gz 不存在，prebuilt 未产出，拒绝构建无容器的固件"
    exit 1
fi

[ -d rootfs-skel ] || {
    echo "::error::找不到 rootfs-skel/（当前目录 $(pwd)）—— workflow 的 docker run 必须把仓库根下的 rootfs-skel 挂进来：-v \"\$GITHUB_WORKSPACE/rootfs-skel:/home/build/immortalwrt/rootfs-skel\"。没有它，容器内那批受保护文件既进不了 tarball 也进不了固件。"
    exit 1
}
ROOTFS_GUARD_DIR="$BASE_DIR"
# 【v.108.56】目标从 rootfs/ 改为 base/：guard 运行期读的是挂载点合并视图，
# 但静态基准必须和基底在同一处，否则 squashfs 里会多一份 288MB 之外的副本。
if [ -d "$BASE_DIR" ]; then
for _rel in \
    etc/passwd \
    etc/group \
    etc/nsswitch.conf \
    etc/hosts \
    etc/resolv.conf \
    etc/crowdsec-net.conf \
    etc/crowdsec/acquis.yaml \
    etc/crowdsec/acquis.d/router.yaml \
    etc/crowdsec/parsers/s01-parse/openwrt-dropbear.yaml \
    etc/crowdsec/parsers/s02-enrich/openwrt-whitelist.yaml \
    etc/inittab \
    etc/init.d/rcS \
    etc/init.d/crowdsec \
    etc/init.d/netconf \
    etc/init.d/syslogd \
    usr/sbin/crowdsec-supervise; do
    mkdir -p "$ROOTFS_GUARD_DIR/$(dirname "$_rel")"
    cp -f "rootfs-skel/$_rel" "$ROOTFS_GUARD_DIR/$_rel" \
        || { echo "::error::缺 rootfs-skel/$_rel（容器脚本单一来源，prepare 与 guard 都靠它）"; exit 1; }
done
chmod 0755 "$ROOTFS_GUARD_DIR"/etc/init.d/rcS "$ROOTFS_GUARD_DIR"/etc/init.d/crowdsec \
           "$ROOTFS_GUARD_DIR"/etc/init.d/netconf "$ROOTFS_GUARD_DIR"/etc/init.d/syslogd \
           "$ROOTFS_GUARD_DIR"/usr/sbin/crowdsec-supervise
chmod 0644 "$ROOTFS_GUARD_DIR/etc/passwd" "$ROOTFS_GUARD_DIR/etc/group" \
           "$ROOTFS_GUARD_DIR/etc/nsswitch.conf" "$ROOTFS_GUARD_DIR/etc/hosts" \
           "$ROOTFS_GUARD_DIR/etc/resolv.conf" "$ROOTFS_GUARD_DIR/etc/crowdsec-net.conf" \
           "$ROOTFS_GUARD_DIR/etc/inittab"
chmod 0644 "$ROOTFS_GUARD_DIR/etc/crowdsec/acquis.yaml" \
           "$ROOTFS_GUARD_DIR/etc/crowdsec/acquis.d/router.yaml" \
           "$ROOTFS_GUARD_DIR/etc/crowdsec/parsers/s01-parse/openwrt-dropbear.yaml" \
           "$ROOTFS_GUARD_DIR/etc/crowdsec/parsers/s02-enrich/openwrt-whitelist.yaml"
fi
echo "==> 容器内受保护文件已进固件（16 个，/rom 只读基准）"

# 出镜像前补齐执行位并逐项断言：路径改名或文件漏拷时让构建直接失败。
# 不再用 2>/dev/null 把 chmod 的错误吞掉——那样后面那句"已确保可执行"就是在撒谎。
# 99-custom.sh / 98-lxc-auto.sh 走 uci-defaults 的 `.` 载入，不依赖执行位，所以只在 chmod 里，不进断言表。
chmod +x files/etc/rc.local \
         files/etc/uci-defaults/99-custom.sh \
         files/etc/uci-defaults/98-lxc-auto.sh \
         files/usr/sbin/crowdsec-lxc-bootstrap.sh \
         files/usr/sbin/crowdsec-lxc-probe.sh \
         files/usr/sbin/crowdsec-guard.sh \
         files/etc/init.d/crowdsec-lxc-probe 2>/dev/null
for _f in files/etc/rc.local \
          files/usr/sbin/crowdsec-lxc-bootstrap.sh \
          files/usr/sbin/crowdsec-lxc-probe.sh \
          files/usr/sbin/crowdsec-guard.sh \
          files/etc/init.d/crowdsec-lxc-probe; do
    [ -x "$_f" ] || { echo "::error::缺少执行位: $_f"; exit 1; }
done
echo "==> 已确保 CrowdSec 引导脚本可执行"

echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"

make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files" ROOTFS_PARTSIZE=$PROFILE

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
