#!/bin/bash
# 【v.180.78】固件版本标记 —— 与 crowdsec-lxc-bootstrap.sh 的 SCRIPT_VER 同步，每次改脚本一起改
source shell/apk-custom-packages.sh
echo "第三方apk软件包: $CUSTOM_PACKAGES"
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
  git clone --depth=1 https://github.com/wukongdaily/apk.git /tmp/store-apk-repo

  mkdir -p /home/build/immortalwrt/extra-packages
  cp -r /tmp/store-apk-repo/run/x86/* /home/build/immortalwrt/extra-packages/

  echo "✅ Run files copied to extra-packages:"
  sh shell/apk-prepare-packages.sh
  ls -lah /home/build/immortalwrt/packages/
fi


echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建固件..."

PACKAGES=""
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"

PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"


# Docker 包已固定写在 shell/apk-custom-packages.sh 里（v.99-bp.2：纯 X86，不再由开关控制）

if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 已选择 luci-app-openclash，添加 openclash core"
    mkdir -p files/etc/openclash/core
    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-v1.tar.gz"
    wget -qO- $META_URL | tar xOvz > files/etc/openclash/core/clash_meta
    chmod +x files/etc/openclash/core/clash_meta
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O files/etc/openclash/GeoIP.dat
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O files/etc/openclash/GeoSite.dat
    URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases/latest \
      | grep "browser_download_url.*apk" \
      | head -n1 \
      | cut -d '"' -f 4)
    echo "OpenClash latest apk: $URL"
    wget "$URL" -P /home/build/immortalwrt/packages/
else
    echo "⚪️ 未选择 luci-app-openclash"
fi

# 【v.108.71】SSR Plus → Clashoo（与 build24.sh 同一个理由）。
# clashoo 的 apk 自带 mihomo（Provides: mihomo, clash-meta），不再单独下内核；
# 改成断言 wukongdaily/apk 的 run/x86/clashoo/ 里那三个 apk 真的进了 packages/。
if echo "$PACKAGES" | grep -q "clashoo"; then
    _cl_apk=$(ls packages/clashoo-*.apk 2>/dev/null | head -n1)
    _cl_luci=$(ls packages/luci-app-clashoo-*.apk 2>/dev/null | head -n1)
    if [ -z "$_cl_apk" ] || [ -z "$_cl_luci" ]; then
        echo "::error::PACKAGES 里选了 clashoo，但 packages/ 下缺包（clashoo=$_cl_apk luci=$_cl_luci）—— apk 仓库的 run 没解出 apk"
        ls -la packages/ 2>/dev/null || true
        echo "::error::预期来自 wukongdaily/apk 的 run/x86/clashoo/"
        exit 1
    fi
    echo "✅ clashoo 就位: $_cl_apk + $_cl_luci（自带 mihomo 内核，不再单独下载）"
else
    echo "⚪️ 未选择 clashoo"
fi

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

# 【v.180.120】把仓库里的自检脚本铺进固件。
# 刷机后 /rom 里就有这批文件的只读基准，guard 的目录级保护才比得出、也才补得回。
# 放 /usr/share（只读数据位）而不是 /usr/sbin，免得和真正的可执行命令混在一起。
#
# 分两组：
#   crowdsec-tests/       只读断言类，跑起来不改现场
#   crowdsec-tests/danger 会写 uci 或注入损坏的那几个，动之前先看 README
mkdir -p files/usr/share/crowdsec-tests/danger
_t_n=0
_t_d=0
# tests/ 是仓库里的目录，靠 workflow 的 -v 挂进容器；没挂上就只是没自检脚本，
# 不影响固件功能（guard 对 /usr/share/crowdsec-tests 是「没有就跳过」），所以只警告不中断。
[ -d tests ] || echo "::warning::容器里没有 tests/ 目录，本次镜像不带自检脚本"
for _t in tests/*; do
    [ -f "$_t" ] || continue
    case "${_t##*/}" in
    probe_netsafe.sh|probe_v10832.sh|test_bp_*)
        cp -a "$_t" files/usr/share/crowdsec-tests/danger/ || exit 1
        _t_d=$((_t_d + 1))
        ;;
    *)
        cp -a "$_t" files/usr/share/crowdsec-tests/ || exit 1
        _t_n=$((_t_n + 1))
        ;;
    esac
done
chmod 755 files/usr/share/crowdsec-tests/*.sh files/usr/share/crowdsec-tests/danger/*.sh 2>/dev/null || true
chmod 644 files/usr/share/crowdsec-tests/*.py 2>/dev/null || true
# 空目录会被 make image 静默丢掉。这里只警告不 exit：自检脚本是附加能力，
# 缺了它固件照样该出，否则一次漏挂载就把整条构建线卡死。
if [ "$_t_n" -gt 0 ]; then
    echo "==> 自检脚本已铺进固件：只读 $_t_n 个，danger $_t_d 个"
else
    echo "::warning::自检脚本一个都没铺进去，本镜像不含 crowdsec-tests（不阻断出镜像）"
fi

# ---- 第一遍：先出镜像，把包取到本地 ----
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files" ROOTFS_PARTSIZE=$PROFILE

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

# ---- v.180.130：收关键包 apk 到 files/root/apk-cache/ ----
# 目的：smartdns / lxc / daed / mosdns / ssr-plus / clashoo / crowdsec-bouncer 被人
# opkg→apk 卸掉后，能用固件自带的包装回来，且记账正确（/etc/apk/world）、LuCI 可见。
#
# files/ 在下面第二遍 make image 时合进 rootfs，所以这批 apk 最终躺在 squashfs 里，
# 刷机后是只读的 /rom/root/apk-cache（不是 overlay 的 /root/apk-cache）。
# 运行期脚本按 /rom 优先解析：只读层删不掉、不占 overlay、与固件同版。
_AK_DIR="files/root/apk-cache"
rm -rf "$_AK_DIR"
mkdir -p "$_AK_DIR"

# 【v.180.132】白名单按 25.12.2（本次实建 622 个包的 Installing 清单）逐条核对修正。
# 旧版是照 24.10 抄的，有 12 个包名在 25.12 里根本不存在，白等一整轮：
#   lxc-monitord                    → 25.12 叫 lxc-monitor（无尾 d）
#   lxc-unprivileged / lxc-user-nic → 25.12 无此拆包，删
#   luci-i18n-smartdns-zh-cn        → 25.12 无此 i18n 包，删
#   dae / dae-geoip / dae-geosite / luci-app-dae / luci-i18n-dae-zh-cn
#                                   → 25.12 全套改名 daed-*（多一个 d），旧名删
#   crowdsec                        → 本体跑在 LXC 容器里（由 crowdsec-lxc tarball 提供，
#                                     宿主机不需要），宿主机只装防火墙 bouncer，所以不收主包
# 修正后 51 条，实测在 25.12.2 官方 index.json 里 51/51 全部命中；
# xray-core 走 run 包（26.6.22，比官方 26.3.27 新，按 run 包优先原则不下官方版）。
_AK_WANT="lxc lxc-attach lxc-auto lxc-autostart lxc-cgroup lxc-checkconfig lxc-common
lxc-config lxc-configs lxc-console lxc-copy lxc-create lxc-destroy lxc-device
lxc-execute lxc-freeze lxc-hooks lxc-info lxc-init lxc-ls lxc-monitor
lxc-snapshot lxc-start lxc-stop lxc-templates lxc-top lxc-unfreeze
lxc-unshare lxc-usernsexec lxc-wait liblxc rpcd-mod-lxc
luci-app-lxc luci-i18n-lxc-zh-cn
smartdns luci-app-smartdns
mosdns
daed daed-geoip daed-geosite luci-app-daed luci-i18n-daed-zh-cn
crowdsec-firewall-bouncer luci-app-crowdsec-firewall-bouncer
luci-i18n-crowdsec-firewall-bouncer-zh-cn nftables-json
v2ray-geoip v2ray-geosite xray-core xray-plugin sing-box"

# 来源 A：packages/ 里 run 包解出的 apk（第三方包，官方源没有）
#
# 【v.180.131】vmlinux-btf 单独排除，理由是与内核强绑定且实测对不上：
#   · 25.12.0 内核 6.12.87 / 25.12.1 内核 6.12.94 / 25.12.2 内核 6.12.103
#   · daed 的 run 包里带的是 vmlinux-btf-6.12.79
#   三个候选版本没有一个是 6.12.79，装上去 daed 的 eBPF 校验过不去。
#   而且 25.12 官方源里【一个 btf 包都没有】，说明内核已自带 BTF
#   （/sys/kernel/btf/vmlinux 由内核提供），本就不该再放一份。
#   若将来 run 包的 btf 版本与目标内核一致，把下面的 case 去掉即可 ——
#   这个判断不写死版本号，只按包名排除，换版本时不需要改代码。
_ak_a=0
_ak_skip_btf=""
for _f in packages/*.apk; do
    [ -f "$_f" ] || continue
    case "${_f##*/}" in
    vmlinux-btf-*)
        _ak_skip_btf="${_f##*/}"
        continue
        ;;
    esac
    cp -f "$_f" "$_AK_DIR"/ && _ak_a=$((_ak_a + 1))
done
echo "==> [apk-cache] 来源 A（run 包）：$_ak_a 个 apk"
if [ -n "$_ak_skip_btf" ]; then
    echo "::warning::已排除 $_ak_skip_btf（内核 BTF 与目标内核版本不一致；25.12 内核自带 BTF，无需此包）"
fi

# apk 二进制定位：只给最后「生成 packages.adb 索引」用，来源 B 已不依赖 apk。
# 【v.180.131】apk 不一定在 PATH 里：ImageBuilder 容器是 Ubuntu 底子，
# 给 rootfs 装包用的是它自带那份（staging_dir/host/bin/apk，与 grub-bios-setup 同目录）。
# 上一轮日志已证实探测命中该路径，所以按「自带优先、PATH 兜底」探一遍固定到 _AK_BIN。
_AK_BIN=""
for _c in "$(pwd)/staging_dir/host/bin/apk" "$(pwd)/staging_dir/host/bin/apk.static"; do
    if [ -x "$_c" ]; then
        _AK_BIN="$_c"
        break
    fi
done
if [ -z "$_AK_BIN" ]; then
    _AK_BIN=$(command -v apk 2>/dev/null)
fi
[ -n "$_AK_BIN" ] && echo "==> [apk-cache] apk 用：$_AK_BIN"

# 【v.180.132】来源 B：官方源官方包，用 index.json + HTTP 直下。
# 三条实证决定了这个写法，前两版都是错的：
#   ① 上一版想"直接读本地 packages/"——错。ImageBuilder 的 packages/ 里只有 run 包
#      （日志里来源 A 恰好 75 个 = packages/*.apk 全量，排除 btf 后），官方 547 个包
#      是它联网流式装进 rootfs 的，装完不落地，本地根本没有；
#   ② 原版用 apk fetch —— 也错。apk-tools 3.0.5 的 FETCH_OPTIONS 里没有 --output-dir
#      也没有 --recursive（只有 -o/--output、--built-after、--pkgname-spec、-s/--stdout、
#      --url、--link），所以 rc=1；而且宿主机是 Ubuntu，没有 /etc/apk/repositories，
#      apk update 必然失败，apk 也就无从知道有哪些包可下；
#   ③ 官方每个 feed 目录都有 index.json，格式是 {"packages":{"包名":"完整版本"}}，
#      文件名就是 "包名-版本.apk"。实测 lxc-6.0.5-r1 / smartdns-48.4-r1 /
#      luci-app-daed-26.236.50544~cb5d434 等 HEAD 全部 200。
# 所以直接取 index.json 拼文件名下载，不碰 apk 的索引/签名/宿主配置，确定性最高。
# 版本取的就是 25.12.2 官方源当前版本，与本次 ImageBuilder 装机来源同源同日。
_AK_BASE="${AK_BASE_OVERRIDE:-https://downloads.immortalwrt.org/releases/25.12.2}"
_AK_FEEDS="${AK_FEEDS_OVERRIDE:-packages/x86_64/base packages/x86_64/luci packages/x86_64/packages packages/x86_64/routing packages/x86_64/telephony targets/x86/64/packages}"

_AK_DL="${AK_DL_OVERRIDE:-}"
if [ -z "$_AK_DL" ]; then
    if command -v curl >/dev/null 2>&1; then
        _AK_DL=curl
    elif command -v wget >/dev/null 2>&1; then
        _AK_DL=wget
    fi
fi
echo "==> [apk-cache] 下载器：${_AK_DL:-无}；源：$_AK_BASE"

# $1=url $2=输出文件
_ak_dl() {
    case "$_AK_DL" in
    curl) curl -fsSL --connect-timeout 20 --max-time 180 -o "$2" "$1" ;;
    wget) wget -q -T 30 -O "$2" "$1" ;;
    *) return 1 ;;
    esac
}

_ak_b=0
_ak_miss=""
if [ -n "$_AK_DL" ]; then
    # 【v.180.133】_AK_WANT 是多行字符串，原来只 tr ' ' '|' 换空格，换行还在。
    # 而 pattern 外面套的是 "(...)"：换行会把整个正则拆成 12 条残缺片段 ——
    # 第一段只有左括号、最后一段只有右括号，grep 直接报 Unmatched 退出，
    # stdout 空，退出码又被 2>/dev/null 吞掉。run #77 的真机表现就是
    # 「1.4 秒、来源 B 0 个 apk、连一条 missing 都没有」。
    # 先把所有空白压成单空格，再转 |，最后校验 pattern 里不能再有空白。
    _ak_pat=$(printf '%s' "$_AK_WANT" | tr '\n' ' ' | tr -s ' ' | sed 's/^ *//; s/ *$//' | tr ' ' '|')
    case "$_ak_pat" in
    "" | *[[:space:]]*)
        echo "::error::白名单正则里还有空白（或为空），index.json 匹配必然失败"
        exit 1
        ;;
    esac
    for _ak_fd in $_AK_FEEDS; do
        _ak_u="$_AK_BASE/$_ak_fd"
        _ak_jf="/tmp/akidx.json"
        if ! _ak_dl "$_ak_u/index.json" "$_ak_jf"; then
            echo "::warning::取不到 $_ak_u/index.json，跳过这个 feed"
            continue
        fi
        # 一次 grep 抽出白名单里所有 "<名>":"<版本>"，再逐个拼文件名
        # index.json 实际是 "包名": "版本"（冒号后有空格），grep 要容忍空白，再统一去掉
        for _ak_kv in $(grep -oE "\"($_ak_pat)\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$_ak_jf" 2>/dev/null | sed 's/[[:space:]]//g'); do
            _ak_nm=$(printf '%s' "$_ak_kv" | sed 's/^"//; s/":".*$//')
            _ak_ver=$(printf '%s' "$_ak_kv" | sed 's/^.*":"//; s/"$//')
            [ -n "$_ak_nm" ] && [ -n "$_ak_ver" ] || continue
            # run 包优先：packages/ 里已有的包名（比如更新的 clashoo/daed）不再下官方版
            if ls "$_AK_DIR/$_ak_nm"-*.apk >/dev/null 2>&1; then
                continue
            fi
            _ak_fn="$_ak_nm-$_ak_ver.apk"
            if _ak_dl "$_ak_u/$_ak_fn" "$_AK_DIR/$_ak_fn"; then
                _ak_b=$((_ak_b + 1))
            else
                _ak_miss="$_ak_miss $_ak_nm"
            fi
        done
    done
else
    echo "::warning::容器里既没有 curl 也没有 wget，官方源这部分收不到"
fi
echo "==> [apk-cache] 来源 B（官方源 index.json 直下）：$_ak_b 个 apk"
if [ -n "$_ak_miss" ]; then
    echo "::warning::以下包在官方源上没下到（可能已改名或不在 25.12.2 源里）：$_ak_miss"
fi

_ak_n=$(ls "$_AK_DIR"/*.apk 2>/dev/null | wc -l)
_ak_sz=$(du -sh "$_AK_DIR" 2>/dev/null | cut -f1)
echo "==> [apk-cache] 合计 $_ak_n 个 apk，$_ak_sz，位于 /root/apk-cache/（刷机后为只读的 /rom/root/apk-cache）"

if [ "$_ak_n" -lt 100 ]; then
    echo "::error::apk-cache 只收到 $_ak_n 个包，远低于预期（run 包约 75 + 官方白名单约 49）"
    echo "::error::来源 A 看 packages/*.apk；来源 B 看上面的 missing 列表"
    exit 1
fi

# --- 生成 apk 索引 ---
# apk 的索引是 packages.adb（二进制 ADB 格式），手写不出来，必须用它自己的命令。
# opkg 那套「拼 Packages 纯文本」在这里完全不适用。
# 失败不中断构建：没有索引时仍能按绝对路径单文件装（依赖齐的常态够用）。
if [ -n "$_AK_BIN" ]; then
    _ak_rc2=0
    ( cd "$_AK_DIR" && "$_AK_BIN" --allow-untrusted index -o packages.adb ./*.apk ) \
        >/tmp/apk-index.log 2>&1 || _ak_rc2=1
    if [ "$_ak_rc2" != "0" ]; then
        ( cd "$_AK_DIR" && "$_AK_BIN" --allow-untrusted index -o packages.adb --no-warnings ./*.apk ) >>/tmp/apk-index.log 2>&1 || _ak_rc2=2
    fi
    if [ "$_ak_rc2" != "2" ] && [ -s "$_AK_DIR/packages.adb" ]; then
        echo "==> [apk-cache] 索引已生成：$(wc -c < "$_AK_DIR/packages.adb") 字节"
    else
        echo "::warning::apk index 失败，本包库只能按绝对路径单文件装（依赖齐时可用）"
        tail -6 /tmp/apk-index.log 2>/dev/null
    fi
fi

# --- manifest.txt：pkg-cache-restore.sh --all 的比对基准 ---
# apk 文件名是 <包名>-<版本>.apk，版本一定以数字开头，所以从「-数字」处截断。
# 不能按最后一段截：lxc-auto-6.0.5-r1.apk 的包名自己带连字符。
# 不含容器内组件的原因同 24 版：crowdsec 跑在 LXC 容器里，宿主机没有这个包。
_ak_man=$(ls "$_AK_DIR"/*.apk 2>/dev/null \
    | sed -E 's#.*/##; s/\.apk$//; s/-[0-9][0-9A-Za-z._-]*$//' \
    | grep -v '^$' | sort -u)
printf '%s\n' "$_ak_man" > "$_AK_DIR/manifest.txt"
_ak_mn=$(printf '%s\n' "$_ak_man" | grep -c .)
echo "==> [apk-cache] manifest.txt：$_ak_mn 个包名（供 restore --all 比对）"

ls "$_AK_DIR" | head -n 20

# ---- 第二遍：把包库打进 rootfs ----
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files" ROOTFS_PARTSIZE=$PROFILE

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed (2nd pass: apk-cache)!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."

echo "==> 离线恢复示例（固件刷好后，包被别人卸载时）："
echo "    单个包：apk add --allow-untrusted /rom/root/apk-cache/smartdns-*.apk"
echo "    走源装：apk add --allow-untrusted --no-network --repository file:///rom/root/apk-cache smartdns"
echo "    查库存：ls /rom/root/apk-cache/ | wc -l"
echo "    说明：apk 在 squashfs 只读层（/rom）里，删不掉；装完 /etc/apk/world 记账正确、LuCI 可见"
