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
# 【v.180.143】改成扫目录，不再逐个枚举。
# 起因：v.180.133 新增的 pkg-cache-check/fix/restore/lib.sh 忘了加进原来的枚举列表，
# 四个脚本以 644 进固件，真机 /usr/sbin/pkg-cache-check.sh 直接
#   -ash: /usr/sbin/pkg-cache-check.sh: Permission denied   (rc=126)
# 而 bootstrap 里调 /usr/sbin/pkg-cache-restore.sh 的地方同样失效 —— 包级自愈一直是废的，
# 只是没在真机上跑过所以没暴露。枚举法必然还会漏，改成扫 files/usr/sbin/*.sh。
chmod +x files/etc/rc.local \
         files/etc/uci-defaults/99-custom.sh \
         files/etc/uci-defaults/98-lxc-auto.sh \
         files/usr/sbin/*.sh \
         files/etc/init.d/crowdsec-lxc-probe 2>/dev/null
for _f in files/etc/rc.local \
          files/usr/sbin/*.sh \
          files/etc/init.d/crowdsec-lxc-probe; do
    [ -x "$_f" ] || { echo "::error::缺少执行位: $_f"; exit 1; }
done
echo "==> 已确保引导/自愈脚本可执行（files/usr/sbin 下 $(ls files/usr/sbin/*.sh 2>/dev/null | wc -l | tr -d ' ') 个）"

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

# ---- 第 0.5 遍（条件）：只在拿不到 apk 二进制时才补编 ----
# 【v.180.136】原来这里无条件编一整遍，唯一的目的是拿到
# staging_dir/host/bin/apk 去给包库建索引。但那个 apk 是 ImageBuilder
# 压缩包自带的预编译工具，解压后就在 —— 于是这一整遍（实测 5-10 分钟）
# 多数时候纯属白跑。现在先探测：有就跳过，最后只编一次。
#
# 不能干脆删掉：万一某个 ImageBuilder 版本确实不带 apk，索引就建不出来，
# 包库退化成「只能按绝对路径装」。所以保留这个兜底分支，代价只是一次 test -x。
# 【v.180.138】判据从「文件存在」收紧成「版本是 apk-tools 3」。
# 上一轮就是只看 -x：文件在、可执行，但它是 2.x —— 只认 tar.gz 的老格式，
# 而 25.12 的包全是 ADB 二进制，于是 no index 一败到底（详见包库段）。
_AK_PRE=""
for _c in "$(pwd)/staging_dir/host/bin/apk" "$(pwd)/staging_dir/host/bin/apk.static"; do
    [ -x "$_c" ] || continue
    _ak_v=$("$_c" --version 2>&1 | head -n1)
    echo "==> [预构建] 探测到 $_c：${_ak_v:-（--version 无输出）}"
    case "$_ak_v" in
    *"apk-tools 3"*) _AK_PRE="$_c" ;;
    *) echo "==> [预构建] 版本不是 apk-tools 3.x，用它建索引会把 25.12 的包全部判成坏包" ;;
    esac
    break
done
if [ -n "$_AK_PRE" ]; then
    echo "==> [预构建] apk 二进制可用：$_AK_PRE"
    echo "==> [预构建] 跳过第一遍 make image，最后只编一次"
else
    echo "==> [预构建] 没有可用的 apk 二进制，先编一遍把它生成出来（这一步省不掉）"
    make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files" ROOTFS_PARTSIZE=$PROFILE
    if [ $? -ne 0 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed (pre-pass)!"
        exit 1
    fi
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
# 【v.180.134】合法 apk 的判定：只有两种文件头
#   1f 8b        gzip       -> apk v2（tar.gz 结构）
#   41 44 42 64  "ADBd"     -> apk v3（ADB 容器）
# 其它一律不是包。真机日志里 apk index 报 "file format not supported" 的
# 那 6 个（xray-core/xray-plugin/v2ray-geoip/v2ray-geosite），就是 run 包里
# 带的坏文件；而「按文件名判断已存在」让它们挡住了官方源的好版本，
# 于是一个坏包废掉整份索引。
_ak_is_apk() {
    _ai_h=$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')
    case "$_ai_h" in
    1f8b* | 41444264*) return 0 ;;
    esac
    return 1
}

_ak_a=0
_ak_skip_btf=""
_ak_skip_geo=""
_ak_bad_a=""
for _f in packages/*.apk; do
    [ -f "$_f" ] || continue
    case "${_f##*/}" in
    vmlinux-btf-*)
        _ak_skip_btf="${_f##*/}"
        continue
        ;;
    # 【v.180.136】geo 数据统一走官方源，run 包带来的两份不要。
    # 原因：同名包在库里会凑出 3 个版本 —— PassWall 的 202606182327.1 /
    # 2026.06.06-r1、daed 的 20260529193437-r1。apk 装依赖时只挑版本号最大的，
    # 而 14 位数字段 20260529193437 必然赢，于是真正装进固件的是 daed 那份；
    # geoip.dat 的格式与 xray-core 版本耦合，选错不报错、只静默分流错误。
    # 官方 25.12.2 有这两个包（geoip 202605120112-r1 / geosite 20260518025449-r1），
    # 格式合法、版本统一、与官方 core 同批构建，比各带一份可靠。
    v2ray-geoip-* | v2ray-geosite-*)
        _ak_skip_geo="$_ak_skip_geo ${_f##*/}"
        continue
        ;;
    esac
    # 拷之前先验文件头：坏文件不进库，否则它会以「已存在」挡住官方源的好版本
    if ! _ak_is_apk "$_f"; then
        _ak_bad_a="$_ak_bad_a ${_f##*/}"
        continue
    fi
    cp -f "$_f" "$_AK_DIR"/ && _ak_a=$((_ak_a + 1))
done
echo "==> [apk-cache] 来源 A（run 包）：$_ak_a 个 apk"
if [ -n "$_ak_bad_a" ]; then
    echo "::warning::run 包里有不是合法 apk 的文件（已丢弃，改由官方源补）：$_ak_bad_a"
fi
if [ -n "$_ak_skip_btf" ]; then
    echo "::warning::已排除 $_ak_skip_btf（内核 BTF 与目标内核版本不一致；25.12 内核自带 BTF，无需此包）"
fi
if [ -n "$_ak_skip_geo" ]; then
    echo "==> [apk-cache] 已排除 run 包里的 geo 数据（统一走官方源，避免多版本被 apk 挑错）：$_ak_skip_geo"
fi

# apk 二进制定位：只给最后「生成 packages.adb 索引」用，来源 B 已不依赖 apk。
# 【v.180.131】apk 不一定在 PATH 里：ImageBuilder 容器是 Ubuntu 底子，
# 给 rootfs 装包用的是它自带那份（staging_dir/host/bin/apk，与 grub-bios-setup 同目录）。
# 上一轮日志已证实探测命中该路径，所以按「自带优先、PATH 兜底」探一遍固定到 _AK_BIN。
# 【v.180.138】这里原来只判断 -x。文件在、能执行，但版本不对时 apk 会对
# 25.12 的每一个包都报 file format not supported —— 上一轮 114 个包就是这样
# 被判成「坏包」全删的。所以从这一处开始就必须按版本挑工具。
_AK_BIN=""
for _c in "$(pwd)/staging_dir/host/bin/apk" "$(pwd)/staging_dir/host/bin/apk.static"; do
    [ -x "$_c" ] || continue
    case "$("$_c" --version 2>&1 | head -n1)" in
    *"apk-tools 3"*) _AK_BIN="$_c"; break ;;
    esac
    echo "==> [apk-cache] 跳过 $_c：$("$_c" --version 2>&1 | head -n1)（不是 apk-tools 3）"
done
if [ -z "$_AK_BIN" ]; then
    _c=$(command -v apk 2>/dev/null)
    if [ -n "$_c" ]; then
        case "$("$_c" --version 2>&1 | head -n1)" in
        *"apk-tools 3"*) _AK_BIN="$_c" ;;
        *) echo "==> [apk-cache] PATH 里的 apk 也不是 3.x：$("$_c" --version 2>&1 | head -n1)" ;;
        esac
    fi
fi
_AK_IDX=""
if [ -n "$_AK_BIN" ]; then
    echo "==> [apk-cache] apk 用：$_AK_BIN（$("$_AK_BIN" --version 2>&1 | head -n1)）"
    # 【v.180.139】根因终于定位：apk 有两个建索引的 applet，作用完全不同 ——
    #   apk index  -> 生成 v2 的 APKINDEX.tar.gz，只吃 tar.gz 包
    #   apk mkndx  -> 生成 apkv3 的 packages.adb，这才是 25.12 要的东西
    # 之前一直用 index 去读 ADB 包，于是每个包都报
    #   "xxx.apk: file format not supported (in this applet)"
    # 那句 (in this applet) 的意思正是「当前 applet 不支持这种文件格式」。
    # v.180.134 把这句当成「包是坏的」，是整条误删链的起点。
    #
    # 早探针顺便就把 applet 定下来：拿 extra-packages 里现成的一个包逐个试，
    # 谁能建出非空索引就用谁。失败只报错不阻断 —— 阻断会卡死整条构建线，
    # 而「有包无索引」的镜像至少还能按绝对路径装。
    _ak_ep=$(find extra-packages -name '*.apk' 2>/dev/null | head -n1)
    if [ -n "$_ak_ep" ]; then
        for _ap in mkndx index; do
            if "$_AK_BIN" --allow-untrusted "$_ap" -o /tmp/ak-probe.adb "$_ak_ep" \
                    >/tmp/ak-probe.log 2>&1 && [ -s /tmp/ak-probe.adb ]; then
                _AK_IDX="$_ap"
                echo "==> [apk-cache] 索引命令确定为 apk $_ap（试索引 $(basename "$_ak_ep") 通过）"
                break
            fi
        done
        if [ -z "$_AK_IDX" ]; then
            echo "::error::apk mkndx 与 index 都建不出索引：$_AK_BIN 读不了 $(basename "$_ak_ep")"
            head -n 5 /tmp/ak-probe.log 2>/dev/null
        fi
        rm -f /tmp/ak-probe.adb
    else
        # 没有现成的包可试：押 mkndx（25.12 唯一的正解），失败再回退
        _AK_IDX="mkndx"
    fi
else
    echo "::error::没有可用的 apk-tools 3.x，本次建不出 packages.adb（包仍会收进镜像，真机可按绝对路径装）"
fi

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
            # run 包优先：packages/ 里已有【且合法】的同名包就不再下官方版。
            # 【v.180.134】原来只看文件名在不在，坏文件会一直挡住官方版；
            # 现在顺手把同名的坏文件删掉，让官方版能补进来。
            _ak_keep=0
            for _ak_e in "$_AK_DIR/$_ak_nm"-*.apk; do
                [ -f "$_ak_e" ] || continue
                if _ak_is_apk "$_ak_e"; then
                    _ak_keep=1
                else
                    rm -f "$_ak_e"
                    echo "::warning::丢弃非法 apk（交回官方源）：${_ak_e##*/}"
                fi
            done
            [ "$_ak_keep" = "1" ] && continue
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
if [ -n "$_AK_BIN" ] && [ -n "$_AK_IDX" ]; then
    # 先把工具本身是什么打出来。v.180.136 的日志里缺的就是这一行，才把
    # 「工具不认所有包」误判成「包全是坏的」，一路把 114 个包连同官方源下载的
    # 一起删光，最后产出空包库 + 0 条 manifest。
    echo "==> [apk-cache] apk 版本：$("$_AK_BIN" --version 2>&1 | head -n1)，索引命令：$_AK_IDX"

    _ak_rc2=0
    ( cd "$_AK_DIR" && "$_AK_BIN" --allow-untrusted "$_AK_IDX" -o packages.adb ./*.apk ) \
        >/tmp/apk-index.log 2>&1 || _ak_rc2=1
    if [ "$_ak_rc2" != "0" ]; then
        ( cd "$_AK_DIR" && "$_AK_BIN" --allow-untrusted "$_AK_IDX" -o packages.adb --no-warnings ./*.apk ) >>/tmp/apk-index.log 2>&1 || _ak_rc2=2
    fi

    _ak_total=$(ls "$_AK_DIR"/*.apk 2>/dev/null | wc -l)
    # 一次最多剔 5%（下限 3）：能剔掉的就该是「个别畸形文件」。
    # 需要剔一大片的时候，坏的不是包，是工具 —— 这时候一个都不能删。
    _ak_cap=$((_ak_total / 20))
    [ "$_ak_cap" -lt 3 ] && _ak_cap=3
    [ "$_ak_cap" -gt "$_ak_total" ] && _ak_cap=$_ak_total

    # 单包独立验证：只有「单独建索引也失败」的包才算坏。
    # 批量日志里那句 file format not supported 分不清「这个包坏」和「工具不认所有包」——
    # 工具读不了格式时，会对每一个文件报同一句话。
    _ak_one_ok() {
        _o=$(mktemp 2>/dev/null) || _o="/tmp/ak-one.$$"
        _r=1
        if ( cd "$_AK_DIR" && "$_AK_BIN" --allow-untrusted "$_AK_IDX" -o "$_o" "./$1" ) >/dev/null 2>&1; then
            [ -s "$_o" ] && _r=0
        fi
        rm -f "$_o"
        return $_r
    }

    # 工具可用性探针：随便挑前 3 个包单独建索引，全失败就说明是工具的问题。
    _ak_probe=0
    for _ak_p in $(ls "$_AK_DIR"/*.apk 2>/dev/null | head -n3); do
        if _ak_one_ok "$(basename "$_ak_p")"; then
            _ak_probe=1
            break
        fi
    done
    if [ "$_ak_probe" = "0" ] && [ "$_ak_total" -gt 0 ]; then
        echo "::error::apk 工具连单个包都建不出索引 —— 这是工具/版本问题，不是包的问题，本次一个文件都不剔除"
        tail -3 /tmp/apk-index.log 2>/dev/null
    fi

    # 隔离目录放 /tmp，绝不能放 files/ 下 —— 那是要整体打进固件的。
    _AK_QUAR="${AK_QUAR_OVERRIDE:-/tmp/apk-quarantine}"
    _ak_quar_n=0
    _ak_round=0
    while :; do
        [ "$_ak_rc2" = "0" ] && [ -s "$_AK_DIR/packages.adb" ] && break
        [ "$_ak_round" -ge 5 ] && break
        [ "$_ak_probe" = "1" ] || break
        _ak_badlist=$(grep -oE '\./[^:]+: file format not supported' /tmp/apk-index.log \
            2>/dev/null | sed 's#^\./##; s/: file format not supported$//' | sort -u)
        [ -n "$_ak_badlist" ] || break
        _ak_cand=$(printf '%s\n' "$_ak_badlist" | grep -c .)
        if [ "$_ak_cand" -gt "$_ak_cap" ]; then
            echo "::error::一轮要剔 $_ak_cand 个，超过上限 $_ak_cap（总 $_ak_total）——判定为工具不认这批包，一个都不删"
            break
        fi
        _ak_round=$((_ak_round + 1))
        mkdir -p "$_AK_QUAR" 2>/dev/null
        for _ak_b in $_ak_badlist; do
            [ -f "$_AK_DIR/$_ak_b" ] || continue
            if _ak_one_ok "$_ak_b"; then
                echo "==> [apk-cache] 保留 $_ak_b：批量报错，但单包能建索引（工具问题，不是包坏）"
                continue
            fi
            _ak_h=$(od -An -tx1 -N4 "$_AK_DIR/$_ak_b" 2>/dev/null | tr -d ' \n')
            echo "::error::隔离 $_ak_b：头部=$_ak_h 大小=$(wc -c < "$_AK_DIR/$_ak_b") 字节（单包也建不出索引）"
            # 用 mv 不用 rm：判断可能错，判断错了还得能从隔离区捡回来
            mv -f "$_AK_DIR/$_ak_b" "$_AK_QUAR/$_ak_b" 2>/dev/null && _ak_quar_n=$((_ak_quar_n + 1))
        done
        echo "==> [apk-cache] 隔离 $_ak_quar_n 个后重建索引（第 $_ak_round 轮）"
        _ak_rc2=0
        ( cd "$_AK_DIR" && "$_AK_BIN" --allow-untrusted "$_AK_IDX" -o packages.adb ./*.apk ) \
            >/tmp/apk-index.log 2>&1 || _ak_rc2=1
    done
    # 【v.180.137】索引（packages.adb）就是这个包库的依赖查询表：
    # 没有它，apk 不知道谁依赖谁，`apk add xxx` 只能退化成「按绝对路径单文件装」，
    # LuCI 的软件包页也会显示空白。所以生成出来必须再验一遍，不能只看退出码。
    _ak_idx_ok=0
    if [ "$_ak_rc2" = "0" ] && [ -s "$_AK_DIR/packages.adb" ]; then
        _ak_sz=$(wc -c < "$_AK_DIR/packages.adb")
        _ak_magic=$(od -An -tx1 -N3 "$_AK_DIR/packages.adb" | tr -d ' \n')
        case "$_ak_magic" in
        414442 | 1f8b*) _ak_idx_ok=1 ;;
        *) echo "::error::packages.adb 头部异常（$_ak_magic），这份索引 apk 读不了" ;;
        esac
        # 【v.180.138】上一轮的空库索引是 88 字节的 gzip，头部 1f8b08 —— 魔数检查
        # 放它过去了，日志还打「索引已生成」，等于把空库包装成成功。
        # 包数上百的索引不可能低于 1KB，低于这个数就是空索引。
        if [ "$_ak_idx_ok" = "1" ] && [ "$_ak_sz" -lt 1024 ]; then
            echo "::error::packages.adb 只有 $_ak_sz 字节，是空索引（$(ls "$_AK_DIR"/*.apk 2>/dev/null | wc -l) 个包一个都没进去）"
            _ak_idx_ok=0
        fi
        if [ "$_ak_idx_ok" = "1" ]; then
            echo "==> [apk-cache] 索引已生成：$_ak_sz 字节，头部=$_ak_magic"
            if [ "$_ak_round" -gt 0 ]; then
                echo "==> [apk-cache] 重建 $_ak_round 轮后成功（被剔除的不是合法 apk，真机也装不上）"
            fi
        fi
    fi
    if [ "$_ak_idx_ok" != "1" ]; then
        # 用 error 而不是 warning：这份镜像刷上去以后，包库是「有包、查不了依赖」的
        # 半残状态，用户装 ssr-plus/daed 这类带一串依赖的包会直接失败。
        # 仍然不中断构建 —— 一次 40 分钟的构建不该因为几个 run 包里的畸形文件全废，
        # 但必须让日志红到没人能忽略。
        echo "::error::apk index 失败：本镜像没有可用的依赖查询表（packages.adb），包库只能按绝对路径单文件装"
        echo "==> [apk-cache] 诊断：$(ls "$_AK_DIR"/*.apk 2>/dev/null | wc -l) 个 apk 未被索引"
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

# ---- 唯一一遍：此时 files/ 里的包库已完整，一次合进 rootfs ----
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
