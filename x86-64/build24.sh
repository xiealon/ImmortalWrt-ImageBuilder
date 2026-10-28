#!/bin/bash
# 【v.180.78】固件版本标记 —— 与 crowdsec-lxc-bootstrap.sh 的 SCRIPT_VER 同步，每次改脚本一起改
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
# 【v.180.143】改成扫目录，不再逐个枚举。
# 起因：v.180.133 新增的 pkg-cache-check/fix/restore/lib.sh 忘了加进原来的枚举列表，
# 四个脚本以 644 进固件，真机 /usr/sbin/pkg-cache-check.sh 直接
#   -ash: /usr/sbin/pkg-cache-check.sh: Permission denied   (rc=126)
# 而 bootstrap 里调 /usr/sbin/pkg-cache-restore.sh 的地方同样失效 —— 包级自愈一直是废的，
# 只是没在真机上跑过所以没暴露。枚举法必然还会漏，改成扫 files/usr/sbin/*.sh。
# 【v.180.163】init.d 也改成扫目录：cgroup2-guard 没有 .sh 后缀，
# 「files/usr/sbin/*.sh」和「逐个点名的 init.d 两项」两条通道都漏了它 ——
# 它靠 git mode 恰好是 755 才没出事，一旦哪次提交丢了执行位，docker 会在
# 开机时静默失败（devices cgroup 没挂 → dockerd 退出 → docker0 不建）。
chmod +x files/etc/rc.local \
         files/etc/uci-defaults/*.sh \
         files/usr/sbin/*.sh \
         files/etc/init.d/* 2>/dev/null
for _f in files/etc/rc.local \
          files/usr/sbin/*.sh \
          files/etc/init.d/*; do
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

# ---- v.180.126：两遍 make image，把关键包的 ipk 收进固件 ----
# 目的：smartdns / lxc 全套 / daed / dae / mosdns / ssr-plus / clashoo /
# crowdsec-firewall-bouncer 被人 opkg 卸掉后，用固件自带的 ipk 装回来 ——
# 走 opkg 装，记账正确、conffiles 由包管理器恢复、LuCI 软件包页面也看得见，
# 不再依赖 bootstrap 里 cp -a 拷文件那套（那套不写 opkg 数据库）。
#
# 为什么必须两遍 make image：files/ 是在 rootfs 组装阶段合并的，而 ipk 要等
# 第一遍跑完才齐。分区由 $PROFILE 决定（workflow 的 Profile 下拉框传进来）。
#
# v.180.125 的错误：从 bin/packages/x86_64 收包。这个仓库用 ImageBuilder，
# 不编译包，bin/ 下只有 targets/，那个目录根本不存在 —— 收出来是空的。
# 现在改成两个真实来源：
#   A. packages/     prepare-packages.sh 解 run 得到的第三方 ipk
#                    （clashoo / luci-app-ssr-plus / luci-app-mosdns / v2ray-geo* 只在这里）
#   B. repositories.conf 的官方 feed   按白名单取 Filename 再下载
#                    （smartdns / lxc 全套 / daed / mosdns / crowdsec-bouncer）
ROOTFS_MB="${PROFILE:-2048}"
case "$ROOTFS_MB" in
    ''|*[!0-9]*)
        echo "::warning::PROFILE=$PROFILE 不是数字，分区沿用 .config 里已有的值"
        ROOTFS_MB="" ;;
esac
if [ -n "$ROOTFS_MB" ] && [ -f .config ]; then
    # .config 是单文件 bind mount，sed -i 靠 rename 会撞 "Device or resource busy"，
    # 所以先写到临时文件再原地截断写回。
    if sed "s|^CONFIG_TARGET_ROOTFS_PARTSIZE=.*|CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_MB|" .config > /tmp/imm.cfg 2>/dev/null; then
        cat /tmp/imm.cfg > .config
        echo "==> rootfs 分区按 Profile 设为 ${ROOTFS_MB}MB"
    else
        echo "::warning::改写 .config 的 ROOTFS_PARTSIZE 失败，沿用原值"
    fi
fi

make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files" ROOTFS_PARTSIZE=$ROOTFS_MB

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

# ---- 第一遍之后：收关键包 ipk 到 files/root/pkg-cache/ ----
# files/ 在下面第二遍 make image 时合进 rootfs，所以这批 ipk 最终躺在 squashfs 里，
# 刷机后是只读的 /rom/root/pkg-cache（不是 overlay 的 /root/pkg-cache）。
# 运行期脚本（bootstrap/guard/probe）因此按 /rom 优先解析包库目录：
# 只读层删不掉、不占 overlay 空间、也不会出现「overlay 里是旧固件留下的旧 ipk」。
_PC_DIR="files/root/pkg-cache"
_PC_MISS=/tmp/pkg-cache-miss.txt
rm -rf "$_PC_DIR"
mkdir -p "$_PC_DIR"
: > "$_PC_MISS"

# 白名单。官方源没有的（clashoo / luci-app-ssr-plus / luci-app-mosdns /
# v2ray-geo*）会记进 miss，由来源 A（packages/ 里的 run 包）补上。
# 白名单，按应用分组列。依据是 run 包实解内容 + 官方 feed 索引核实：
#   ssrp_x86_64.run        -> luci-app-ssr-plus / luci-i18n-ssr-plus-zh-cn（mihomo 版，不带 ssr-libev）
#   mosdns_x86_64.run      -> mosdns / luci-app-mosdns / luci-i18n-mosdns-zh-cn / v2ray-geo*
#   clashoo_x86_64.run     -> clashoo / luci-app-clashoo / luci-i18n-clashoo-zh-cn
#   luci-app-dead_x86_64.run（文件名是 dead，里面是 daed）-> daed / luci-app-daed /
#                             luci-i18n-daed-zh-cn / v2ray-geo* / vmlinux-btf
# 官方 feed 另有 smartdns / smartdns-ui / lxc 全套 / dae / crowdsec-bouncer。
#
# 刻意不收录的：
#   libopenssl3   ssrp run 里带了这个，但它是系统核心库 —— 拿它 --force-reinstall
#                 会把 opkg/wget 依赖的 openssl 换掉，风险远大于收益。真缺了应该重刷固件。
#   ssr-plus      裸名，不存在。实际包名是 luci-app-ssr-plus。
_PC_WANT="lxc lxc-attach lxc-auto lxc-autostart lxc-cgroup lxc-checkconfig lxc-common
lxc-config lxc-configs lxc-console lxc-copy lxc-create lxc-destroy lxc-device
lxc-execute lxc-freeze lxc-hooks lxc-info lxc-init lxc-ls lxc-monitor lxc-monitord
lxc-snapshot lxc-start lxc-stop lxc-templates lxc-top lxc-unfreeze lxc-unprivileged
lxc-unshare lxc-user-nic lxc-usernsexec lxc-wait liblxc rpcd-mod-lxc
luci-app-lxc luci-i18n-lxc-zh-cn
smartdns smartdns-ui luci-app-smartdns luci-i18n-smartdns-zh-cn
mosdns luci-app-mosdns luci-i18n-mosdns-zh-cn v2ray-geoip v2ray-geosite
daed daed-geoip daed-geosite luci-app-daed luci-i18n-daed-zh-cn vmlinux-btf
dae dae-geoip dae-geosite luci-app-dae luci-i18n-dae-zh-cn
crowdsec crowdsec-firewall-bouncer luci-app-crowdsec-firewall-bouncer
luci-i18n-crowdsec-firewall-bouncer-zh-cn nftables-json
luci-app-ssr-plus luci-i18n-ssr-plus-zh-cn
shadowsocksr-libev-ssr-local shadowsocksr-libev-ssr-redir shadowsocksr-libev-ssr-server
trojan-plus xray-core xray-plugin sing-box
clashoo luci-app-clashoo luci-i18n-clashoo-zh-cn"

# --- 来源 A：容器里已经存在的 ipk ---
# 构建本来就要把用到的包取到本地，能捞到就别再下载一遍（省流量也省时间）。
# 两个地方会有：packages/ 是 prepare-packages.sh 解 run 得到的第三方包，
# dl/ staging_dir/ build_dir/ 是 ImageBuilder 自己下载/解包时留下的。
# 只捞白名单里的 —— passwall / nekobox 那类几十兆的无关包不进固件。
_pc_a=0
_pc_hit() {
    for _pw in $_PC_WANT; do
        case "$1" in
            "${_pw}_"*) return 0 ;;
        esac
    done
    return 1
}
for _d in packages dl staging_dir build_dir; do
    [ -d "$_d" ] || continue
    for _f in $(find "$_d" -name '*.ipk' 2>/dev/null); do
        [ -f "$_f" ] || continue
        _bn=$(basename "$_f")
        [ -f "$_PC_DIR/$_bn" ] && continue
        _pc_hit "$_bn" || continue
        cp -f "$_f" "$_PC_DIR/$_bn" 2>/dev/null && _pc_a=$((_pc_a + 1))
    done
done
echo "==> [pkg-cache] 来源 A（容器内已有 ipk，按白名单捞）：$_pc_a 个"

# --- 来源 B：官方 feed，先按 Depends 算依赖闭包，再逐个下载 ---
# 为什么必须闭包：只收白名单那 75 个，opkg install 会因缺依赖失败；
# 而用 --force-depends 硬装会装出半残的包（文件在、跑不起来）。
# 宁可多收几十兆，也别让恢复在真机上失败。
_pc_b=0
_idx_all=/tmp/pc-index-all.txt
# 基础系统包不进闭包 —— 它们真缺了整个系统已经废了，靠 ipk 补是饮鸩止渴。
# libopenssl3 也在这里：拿它 --force-reinstall 会把 opkg/wget 依赖的 openssl 换掉。
_skip_list="libc libpthread librt libdl libm libgcc libstdcpp libopenssl3 kernel
base-files busybox opkg procd uci ubus ubox netifd libubox libubus libuci"
: > "$_idx_all"
if [ -f repositories.conf ]; then
    echo "==> [pkg-cache] repositories.conf:"
    cat repositories.conf
    _i=0
    while read -r _a _b _c _rest; do
        case "$_a" in
            src*) ;;
            *) continue ;;
        esac
        _u="$_c"
        [ -n "$_u" ] || continue
        _i=$((_i + 1))
        _gz="/tmp/pc-idx-$_i.gz"
        wget -q -O "$_gz" "$_u/Packages.gz" 2>/dev/null || { rm -f "$_gz"; continue; }
        [ -s "$_gz" ] || { rm -f "$_gz"; continue; }
        _base=$(echo "$_u" | sed 's|/[^/]*$||')
        # 索引里的 Filename 有两种写法：带 feed 目录（packages/smartdns_x.ipk）
        # 或不带（smartdns_x.ipk）。所以两个候选 URL 都存，下载时依次试。
        gzip -dc "$_gz" 2>/dev/null | awk -v b="$_base" -v u="$_u" '
            /^Package: / { print; next }
            /^Filename: / {
                s = $0
                sub(/^Filename:[ \t]*/, "", s)
                print "Filename: " b " " u " " s
                next
            }
            { print }
        ' >> "$_idx_all"
        rm -f "$_gz"
    done < repositories.conf
fi

if [ -s "$_idx_all" ]; then
    awk -v want="$_PC_WANT" -v skip="$_skip_list" '
        BEGIN {
            n = split(want, W, " ")
            for (i = 1; i <= n; i++) wanted[W[i]] = 1
            m = split(skip, S, " ")
            for (i = 1; i <= m; i++) skipped[S[i]] = 1
        }
        /^Package: / { cur = $2; next }
        /^Depends: / {
            s = $0
            sub(/^Depends:[ \t]*/, "", s)
            gsub(/\([^)]*\)/, "", s)
            gsub(/[|,]/, " ", s)
            if (cur != "") dep[cur] = dep[cur] " " s
            next
        }
        /^Filename: / {
            if (cur != "") {
                s = $0
                sub(/^Filename:[ \t]*/, "", s)
                fn[cur] = s
            }
            next
        }
        END {
            qn = 0
            for (p in wanted) q[++qn] = p
            i = 1
            while (i <= qn) {
                p = q[i]; i++
                if (p in seen) continue
                seen[p] = 1
                nd = split(dep[p], D, " ")
                for (j = 1; j <= nd; j++) {
                    d = D[j]
                    gsub(/[ \t]/, "", d)
                    if (d == "" || (d in skipped) || (d in seen)) continue
                    q[++qn] = d
                }
            }
            for (p in seen) {
                if (p in skipped) continue
                if (p in fn) print p " " fn[p]
                else print p " MISSING - -"
            }
        }
    ' "$_idx_all" > /tmp/pc-plan.txt

    _pc_plan=$(wc -l < /tmp/pc-plan.txt)
    echo "==> [pkg-cache] 依赖闭包展开：$_pc_plan 个包待收"
    while read -r _p _base _u _fn; do
        [ "$_base" = "MISSING" ] && continue
        _bn=$(basename "$_fn")
        [ -f "$_PC_DIR/$_bn" ] && continue
        if wget -q -O "$_PC_DIR/$_bn" "$_base/$_fn" 2>/dev/null && [ -s "$_PC_DIR/$_bn" ]; then
            _pc_b=$((_pc_b + 1))
        elif wget -q -O "$_PC_DIR/$_bn" "$_u/$_fn" 2>/dev/null && [ -s "$_PC_DIR/$_bn" ]; then
            _pc_b=$((_pc_b + 1))
        else
            rm -f "$_PC_DIR/$_bn"
            echo "下载失败 $_p $_fn" >> "$_PC_MISS"
        fi
    done < /tmp/pc-plan.txt
fi
echo "==> [pkg-cache] 来源 B（官方 feed + 依赖闭包）：$_pc_b 个"

# --- 校验：ipk 必须是能解开的 tar.gz ---
# 【v.180.140】对照 25 版 v.180.138 的教训：坏包不能一删了之。
# 25 版就是「工具读不懂」被当成「包坏了」，一句话删掉 114 个包（含官方源刚下载的）。
# 24 版这里原来也是 gzip -t 失败就 rm，只是恰好没踩到 —— 同一个坑，一起补上：
#   ① 先看魔数再看 gzip -t：1f8b 之外的东西（HTML 错误页、截断文件、空文件）
#      要把它到底是什么打进日志，否则下次照样只能猜；
#   ② 隔离到 /tmp，不直接删：判断可能错，错了还得能捡回来；
#   ③ 熔断：坏到 max(3, 总数 5%) 以上，就不是个别畸形文件了，一个都不动。
_pc_total=$(ls "$_PC_DIR"/*.ipk 2>/dev/null | wc -l)
_pc_cap=$((_pc_total / 20))
[ "$_pc_cap" -lt 3 ] && _pc_cap=3
[ "$_pc_cap" -gt "$_pc_total" ] && _pc_cap=$_pc_total
_pc_bad=0
_pc_badlist=""
for _f in "$_PC_DIR"/*.ipk; do
    [ -f "$_f" ] || continue
    _h=$(od -An -tx1 -N2 "$_f" 2>/dev/null | tr -d ' \n')
    if [ "$_h" = "1f8b" ] && gzip -t "$_f" 2>/dev/null; then
        continue
    fi
    _pc_bad=$((_pc_bad + 1))
    _pc_badlist="$_pc_badlist $(basename "$_f")|${_h:-unreadable}"
done
if [ "$_pc_bad" -gt 0 ]; then
    if [ "$_pc_bad" -gt "$_pc_cap" ]; then
        echo "::error::$_pc_bad 个 ipk 通不过 gzip 校验，超过上限 $_pc_cap（总 $_pc_total）——判定为系统性异常，本次一个都不剔除"
        _show=0
        for _b in $_pc_badlist; do
            _show=$((_show + 1))
            [ "$_show" -le 10 ] && echo "    未剔除：$_b"
        done
    else
        mkdir -p /tmp/ipk-quarantine 2>/dev/null
        for _b in $_pc_badlist; do
            _bn=$(printf '%s' "$_b" | sed 's/|.*//')
            _bh=$(printf '%s' "$_b" | sed 's/.*|//')
            echo "隔离损坏的包：$_bn（头部=$_bh）" >> "$_PC_MISS"
            mv -f "$_PC_DIR/$_bn" /tmp/ipk-quarantine/ 2>/dev/null
        done
        echo "::warning::隔离 $_pc_bad 个损坏/不完整的 ipk（在 /tmp/ipk-quarantine，未删除）"
    fi
fi

# --- 白名单缺口报告 ---
_pc_gap=""
for _p in $_PC_WANT; do
    if ! ls "$_PC_DIR"/${_p}_*.ipk >/dev/null 2>&1; then
        _pc_gap="$_pc_gap $_p"
    fi
done

_pc_n=$(ls "$_PC_DIR"/*.ipk 2>/dev/null | wc -l)
_pc_sz=$(du -sh "$_PC_DIR" | cut -f1)
echo "==> [pkg-cache] 合计 $_pc_n 个 ipk，$_pc_sz，位于 /root/pkg-cache/（刷机后为只读的 /rom/root/pkg-cache）"
if [ -n "$_pc_gap" ]; then
    echo "::warning::白名单里这些包没收到（如属第三方 run 包，看上面来源 A 的数量；如确实没有，固件里就没有可离线装回的 ipk）：$_pc_gap"
fi
if [ -s "$_PC_MISS" ]; then
    echo "==> [pkg-cache] 失败明细（前 20 行）："
    head -n 20 "$_PC_MISS"
fi
if [ "$_pc_n" -eq 0 ]; then
    echo "::error::pkg-cache 一个 ipk 都没收到，离线装回功能不可用"
    exit 1
fi
# --- 生成本地 opkg 索引 ---
# 没有 Packages 索引，opkg install 只认单个 ipk，一缺依赖就得联网；
# 有了索引 + customfeeds.conf 里的 file:// 源，opkg 会自己从本地源补齐依赖。
# 【v.180.133】四段式。少任何一段，真机上就有装不回来的包：
#   ① 正向：从合并后的官方索引里筛出本地有的 ipk，只把 Filename 改成本地名
#      （官方索引里的 Filename 带 feed 子目录前缀，不改 opkg 找不到文件）。
#   ② 反向补：run 包的第三方版本【根本不在官方索引里】，只做①时 164 个 ipk
#      只有 139 条索引 —— mosdns 的 r4、daed、clashoo、luci-app-ssr-plus 全没条目，
#      `opkg install mosdns` 直接 not available from any configured src，
#      只有绝对路径直装能活，LuCI 软件包页也看不到它们。
#   ③ Packages.gz：opkg 的 file:// 源【只认 .gz】，给裸 Packages 一律报
#      copy_file: ///rom/root/pkg-cache/Packages.gz: No such file or directory；
#      而 update 一失败，opkg 就不为该源建 src 记录，之后按包名装全废。
#   ④ Packages.sig：/etc/opkg.conf 默认带 option check_signature，全局验签开着
#      时本地源还要签名，否则 update 同样必挂。用户手删那行只存在 overlay，
#      重新刷机就失效 —— 所以必须让固件自带签名。
if [ -s /tmp/pc-plan.txt ] && [ -s "$_idx_all" ]; then
    _pc_have=$(ls "$_PC_DIR" 2>/dev/null | grep '\.ipk$' | tr '\n' ' ')
    awk -v have="$_pc_have" '
        BEGIN {
            RS = ""
            n = split(have, H, " ")
            for (i = 1; i <= n; i++) if (H[i] != "") ok[H[i]] = 1
        }
        {
            nf = split($0, L, "\n")
            keep = 0
            for (i = 1; i <= nf; i++) {
                if (L[i] ~ /^Filename: /) {
                    f = L[i]
                    sub(/^Filename:[ \t]*/, "", f)
                    m = split(f, P, " ")
                    fn = P[m]
                    gsub(/.*\//, "", fn)
                    if (fn in ok) { keep = 1; fname = fn }
                }
            }
            if (keep) {
                for (i = 1; i <= nf; i++) {
                    if (L[i] ~ /^Filename: /) print "Filename: " fname
                    else if (L[i] != "") print L[i]
                }
                print ""
            }
        }
    ' "$_idx_all" > "$_PC_DIR/Packages"
else
    : > "$_PC_DIR/Packages"
    echo "::warning::没有合并后的官方索引，本地 Packages 只能靠各 ipk 的 control 自解"
fi

# --- ② 反向补条目：官方索引里没有的 ipk，从 control 现生成 ---
# 判据用 Filename 而不是包名：同名多版本要共存（本地 r1 + 官方 r1 + 本地 r4），
# 按包名判会把高版本当"已收录"跳过，opkg 就永远选不到它。
_pc_add=0
for _f in "$_PC_DIR"/*.ipk; do
    [ -f "$_f" ] || continue
    _bn="${_f##*/}"
    if grep -qF "Filename: $_bn" "$_PC_DIR/Packages" 2>/dev/null; then
        continue
    fi
    # ipk = tar.gz 套 control.tar.gz；OpenWrt 打的是 ./control.tar.gz，
    # 不同 tar 实现对前导 ./ 处理不一，两种都试
    _ctl=$(tar -xzOf "$_f" ./control.tar.gz 2>/dev/null | tar -xzO ./control 2>/dev/null)
    [ -n "$_ctl" ] || _ctl=$(tar -xzOf "$_f" control.tar.gz 2>/dev/null | tar -xzO control 2>/dev/null)
    if [ -z "$_ctl" ]; then
        echo "::warning::$_bn 读不出 control，跳过索引补录（该包只能绝对路径直装）"
        continue
    fi
    {
        echo "Package: $(printf '%s\n' "$_ctl" | sed -n 's/^Package: //p' | head -1)"
        echo "Version: $(printf '%s\n' "$_ctl" | sed -n 's/^Version: //p' | head -1)"
        _pc_v=$(printf '%s\n' "$_ctl" | sed -n 's/^Depends: //p' | head -1)
        [ -n "$_pc_v" ] && echo "Depends: $_pc_v"
        _pc_v=$(printf '%s\n' "$_ctl" | sed -n 's/^Architecture: //p' | head -1)
        [ -n "$_pc_v" ] && echo "Architecture: $_pc_v"
        echo "Filename: $_bn"
        echo "Size: $(wc -c < "$_f" | tr -d ' ')"
        _pc_v=$(printf '%s\n' "$_ctl" | sed -n 's/^Description: //p' | head -1)
        [ -n "$_pc_v" ] && echo "Description: $_pc_v"
        echo ""
    } >> "$_PC_DIR/Packages"
    _pc_add=$((_pc_add + 1))
done
echo "==> [pkg-cache] 反向补条目：$_pc_add 个（run 包三方版本，官方索引里没有）"

_pc_idx=$(grep -c '^Package: ' "$_PC_DIR/Packages" 2>/dev/null)
[ -n "$_pc_idx" ] || _pc_idx=0
_pc_uniq=$(grep '^Package: ' "$_PC_DIR/Packages" 2>/dev/null | sort -u | wc -l | tr -d ' ')
[ -n "$_pc_uniq" ] || _pc_uniq=0
echo "==> [pkg-cache] 本地索引：$_pc_idx 条 / $_pc_uniq 个包名 / $_pc_n 个 ipk"
# 0 条索引等于「有包、查不了依赖」：opkg update 会为这个源建出一条空记录，
# 之后按包名装任何东西都是 not available from any configured src。
# 这不是 warning，是包库报废 —— 必须报错，别让镜像看起来是好的。
if [ "$_pc_uniq" -lt 1 ]; then
    echo "::error::本地索引 0 条：$_pc_n 个 ipk 一个都没进 Packages，真机上本地源是空源"
fi
# 【v.180.142】判据改成「条目数 vs ipk 数」。
# 原来比「去重包名数 vs ipk 数」，同名多版本（daed、hysteria、mosdns、xray-core…）
# 天然让包名数小于 ipk 数：实测 164 条 / 150 包名 / 164 ipk 时天天喊
# 「有 ipk 没进索引」，而 164 条恰好等于 164 个 ipk —— 一个都没漏，纯误报。
# 告警天天误报的下场是没人再看告警，真漏包时也一起被忽略。
# 真判据：每条索引对应一个 Filename，条目数 < ipk 数才说明有包被跳过（读不出 control）。
if [ "$_pc_idx" -lt "$_pc_n" ]; then
    echo "::warning::索引 $_pc_idx 条 < $_pc_n 个 ipk，有 ipk 没进索引"
fi

# --- ③ Packages.gz ---
# -n 不写时间戳：同一个 Packages 每次产出的 gz 字节一致，便于比对
if [ -s "$_PC_DIR/Packages" ]; then
    gzip -9 -n -c "$_PC_DIR/Packages" > "$_PC_DIR/Packages.gz" 2>/dev/null
    # 字节数非 0 只是必要条件：截断的 gz 也有字节数，opkg 解到一半就报错。
    # 所以再解一遍验证，过了才算真的可用。
    if [ -s "$_PC_DIR/Packages.gz" ] && gzip -t "$_PC_DIR/Packages.gz" 2>/dev/null; then
        echo "==> [pkg-cache] Packages.gz：$(wc -c < "$_PC_DIR/Packages.gz" | tr -d ' ') 字节，解压校验通过"
    else
        echo "::error::Packages.gz 生成失败或校验不过，本地源在真机上必然 update 失败"
        exit 1
    fi
else
    # 与 0 条索引同理：没有 Packages 就没有 gz，opkg 会报
    # copy_file: ///rom/root/pkg-cache/Packages.gz: No such file or directory
    echo "::error::Packages 为空，不生成 Packages.gz；本地源在真机上 update 必失败"
    exit 1
fi

# --- ④ 签名 Packages.sig ---
# 用构建机自带的 usign 现场生成密钥对，同一构建内配对：
# 私钥用完即删（不入库、不进固件），公钥按指纹命名写进 files/etc/opkg/keys/，
# 随第二遍 make image 进 squashfs，重刷后仍然自洽。
_PC_SIGNED=0
_PC_USIGN=""
if [ -x "staging_dir/host/bin/usign" ]; then
    _PC_USIGN="staging_dir/host/bin/usign"
fi
[ -n "$_PC_USIGN" ] || _PC_USIGN=$(command -v usign 2>/dev/null)
if [ -n "$_PC_USIGN" ] && [ -s "$_PC_DIR/Packages" ]; then
    _pc_kd=$(mktemp -d 2>/dev/null)
    [ -n "$_pc_kd" ] || _pc_kd="/tmp/pkgcache-keys.$$"
    mkdir -p "$_pc_kd"
    if "$_PC_USIGN" -G -s "$_pc_kd/k.sec" -p "$_pc_kd/k.pub" -c "pkgcache" >/dev/null 2>&1; then
        _pc_fp=$("$_PC_USIGN" -F -p "$_pc_kd/k.pub" 2>/dev/null | cut -f1)
        if [ -n "$_pc_fp" ] && "$_PC_USIGN" -S -m "$_PC_DIR/Packages" -s "$_pc_kd/k.sec" -x "$_PC_DIR/Packages.sig" >/dev/null 2>&1 && [ -s "$_PC_DIR/Packages.sig" ]; then
            mkdir -p files/etc/opkg/keys
            cp -f "$_pc_kd/k.pub" "files/etc/opkg/keys/$_pc_fp"
            _PC_SIGNED=1
            echo "==> [pkg-cache] 已签名 Packages.sig，公钥指纹 $_pc_fp 写入 /etc/opkg/keys/"
        fi
    fi
    rm -rf "$_pc_kd"
fi
if [ "$_PC_SIGNED" = "0" ]; then
    # 降级：写一份去掉 option check_signature 的 opkg.conf 覆盖件。
    # 只在签不出 Packages.sig 时才降级，避免白白削弱所有源的验签强度。
    echo "::warning::usign 不可用或签名失败，降级为关闭全局验签"
    mkdir -p files/etc
    {
        echo "dest root /"
        echo "dest ram /tmp"
        echo "lists_dir ext /var/opkg-lists"
        echo "option overlay_root /overlay"
    } > files/etc/opkg.conf
fi

# --- ⑤ manifest.txt：pkg-cache-restore.sh --all 的比对基准 ---
# 只写包名（去重），不写版本：判定「包在不在位」看包名，带版本比会在跨版本
# 升级后把整库都报成缺失。包名在 opkg 里不允许含下划线，所以从第一个下划线
# 截断即可 —— 文件名是 <包名>_<版本>_<架构>.ipk，而架构 x86_64 自己就带下划线，
# 用「去掉最后两段」的正则会截在 mosdns_5.3.3-r4 上。
# 刻意不含容器内组件：crowdsec 本体在 LXC 容器里由 tarball 提供，宿主机本来
# 就没有这个包，列进来会让 --all 天天报「crowdsec 缺失」，而它其实跑得好好的。
#
# 【v.180.145】口径收紧：只列「固件确实要装」的包，不再是包库全量。
# 原来直接取 ipk 文件名去重（真机实测 150 个），而 --all 的语义是「补齐缺失」，
# 于是它会把固件本来没装的包（dae、xray-core 的另一版、纯备用的依赖）
# 一个个装上去 —— 那不叫恢复，那叫扩容。
# 正确口径 = PACKAGES（已含 CUSTOM_PACKAGES）∩ 包库里有文件的包：
#   · 固件没选的包         -> 不在 PACKAGES，排除
#   · 选了但库里没文件的   -> 交集后排除（装不回来，列进去只会天天报缺）
_pc_all=$(ls "$_PC_DIR"/*.ipk 2>/dev/null | sed 's#.*/##; s/_.*//' | grep -v '^$' | sort -u)
: > /tmp/pc-want-inst.txt
for _pwi in $PACKAGES; do
    case "$_pwi" in -*) continue ;; esac
    echo "$_pwi"
done | sort -u > /tmp/pc-want-inst.txt
# busybox grep 的 -f 碰到空模式文件不是「一条都不匹配」，而是把整份输入全吐出来
# （夹具实测：want 文件 0 行 -> manifest 150 行全过）。那样 PACKAGES 为空时就
# 悄悄退回「包库全量」这个错行为，还看不出来。必须显式挡一道。
if [ -s /tmp/pc-want-inst.txt ]; then
    _pc_man=$(printf '%s\n' "$_pc_all" | grep -Fxf /tmp/pc-want-inst.txt 2>/dev/null)
else
    _pc_man=""
fi
_pc_alln=$(printf '%s\n' "$_pc_all" | grep -c .)
[ -n "$_pc_alln" ] || _pc_alln=0
printf '%s\n' "$_pc_man" > "$_PC_DIR/manifest.txt"
_pc_mn=$(printf '%s\n' "$_pc_man" | grep -c .)
[ -n "$_pc_mn" ] || _pc_mn=0
echo "==> [pkg-cache] manifest.txt：$_pc_mn 个包名（库内 $_pc_alln 个，只列本固件该装的；供 restore --all 比对）"
if [ "$_pc_mn" -lt 1 ]; then
    echo "::error::manifest 为空：PACKAGES 与包库没有交集，restore --all 将无事可做"
    exit 1
fi

ls "$_PC_DIR" | head -n 40

# ---- 第二遍：把缓存打进 rootfs ----
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files" ROOTFS_PARTSIZE=$ROOTFS_MB

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed (2nd pass: pkg-cache)!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."

echo "==> 离线恢复示例（固件刷好后，包被别人卸载时）："
echo "    单个包：opkg install --force-reinstall /rom/root/pkg-cache/smartdns_*.ipk"
echo "    整批装：opkg install --force-reinstall /rom/root/pkg-cache/*.ipk"
echo "    查库存：ls /rom/root/pkg-cache/ | wc -l"
echo "    说明：ipk 在 squashfs 只读层（/rom）里，删不掉；装完 opkg 记账正确、LuCI 可见"
echo "          脚本会自动把本地源写进 /etc/opkg/customfeeds.conf，不用手动 opkg update"
