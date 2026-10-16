#!/usr/bin/env bash
# =============================================================================
# shell/prepare-crowdsec-rootfs.sh
#
# 作用：在 GitHub Actions 编译机（ubuntu-22.04 / x86_64）上，预制一个「已经装好
#       CrowdSec 的 Ubuntu 22.04 rootfs」，打成 tar.gz 塞进固件，开机时由
#       /usr/sbin/crowdsec-lxc-bootstrap.sh 解压到 /srv/lxc/ubuntu/rootfs。
#
# 为什么必须在编译期做：
#   路由器首次开机时跑 99-custom.sh 的阶段（uci-defaults，START=10）网络还没起来，
#   wget / apt-get 全部会失败。所以下载 rootfs + apt 装包只能放在有网的编译机上。
#
# 为什么打成 tar.gz 而不是直接把目录塞进 files/：
#   x86-64 squashfs 固件的 / 是只读层 + overlay 可写层。把容器 rootfs 放在只读层，
#   systemd 启动时会踩 overlayfs 的 copy-up / capability 坑。落在可写层最稳。
#
# 产物：files/etc/crowdsec/lxc-ubuntu.tar.gz（CS_HOME，与 99-custom.sh / bootstrap 对齐）
#
# 纯净镜像原则：本脚本只装包（apt install crowdsec），不写任何定制配置。
# 网络(静态IP/DNS)、systemd 自启、CrowdSec 配置(解析器/日志源/listen_uri/trusted_ips)
# 全部由运行期 /usr/sbin/crowdsec-lxc-bootstrap.sh 在容器启动前生成。
# =============================================================================
set -euo pipefail

UBUNTU_BASE_URL="${UBUNTU_BASE_URL:-https://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release/ubuntu-base-22.04.5-base-amd64.tar.gz}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 归拢到 files/etc/crowdsec/ —— 与 99-custom.sh、bootstrap 脚本里的 CS_HOME 保持一致
OUT_DIR="${OUT_DIR:-$REPO_ROOT/files/etc/crowdsec}"
WORK="${WORK:-/tmp/lxc-ubuntu-build}"
R="$WORK/rootfs"

# ---------- 1. 下载并展开 ubuntu-base ----------
rm -rf "$WORK"
mkdir -p "$R" "$OUT_DIR"
echo "==> 下载 ubuntu-base"
curl -fsSL "$UBUNTU_BASE_URL" -o "$WORK/base.tar.gz"
sudo tar -xzf "$WORK/base.tar.gz" -C "$R"

# ---------- 2. 准备 chroot ----------
sudo cp /etc/resolv.conf "$R/etc/resolv.conf"
# policy-rc.d 阻止 deb 安装时拉起服务（chroot 里没有 running systemd）
printf '#!/bin/sh\nexit 101\n' | sudo tee "$R/usr/sbin/policy-rc.d" >/dev/null
sudo chmod +x "$R/usr/sbin/policy-rc.d"

sudo mount --bind /proc    "$R/proc"
sudo mount --bind /sys     "$R/sys"
sudo mount --bind /dev     "$R/dev"
sudo mount --bind /dev/pts "$R/dev/pts"
trap 'sudo umount -lf "$R/dev/pts" "$R/dev" "$R/sys" "$R/proc" 2>/dev/null || true' EXIT

# ---------- 3. chroot 内安装 CrowdSec ----------
echo "==> chroot 安装 CrowdSec（约 2-4 分钟）"
sudo chroot "$R" /bin/bash -eu -c '
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
apt-get update -qq

# ⚠️ 这里不要写 systemd-networkd：它是 Debian 12(bookworm) 才拆出来的独立包，
#    Ubuntu 22.04 / 24.04 里 networkd 的二进制和 service 都由 systemd 包提供。
#    写上会直接 "E: Unable to locate package systemd-networkd" 中断整个流水线。
PKGS="systemd systemd-sysv dbus curl ca-certificates gnupg iproute2 iputils-ping"

# 逐个校验包名：一次性 apt-get install 时，只要有一个包不存在，
# apt 会整批失败并只返回一个笼统的 exit 100，排查起来很费劲。
MISS=""
for p in $PKGS; do
    apt-cache show "$p" >/dev/null 2>&1 || MISS="$MISS $p"
done
if [ -n "$MISS" ]; then
    echo "!! 以下包在当前源里不存在，请检查包名或 base 版本:$MISS"
    exit 1
fi

apt-get install -y --no-install-recommends $PKGS

# CrowdSec 官方仓库
curl -fsSL https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash
apt-get install -y --no-install-recommends crowdsec

# networkd 二进制必须落地：后面第 4 步要靠它配静态 IP，缺了容器就上不了网
if [ ! -e /lib/systemd/systemd-networkd ] && ! command -v systemd-networkd >/dev/null 2>&1; then
    echo "!! systemd-networkd 二进制缺失，容器将无法配置静态 IP"
    exit 1
fi

apt-get clean
rm -rf /var/lib/apt/lists/*
'
sudo rm -f "$R/usr/sbin/policy-rc.d"

# ---------- 打包 ----------
# 注意：hub 的 crowdsecurity/whitelists 只能在容器跑起来后用 cscli 删除，
#       放到开机引导脚本里做（这里 cscli 连不上 LAPI）。

# ---- 6.1 必须先卸载第 2 步的 bind mount ----
# ⚠️ 这一步不能省。$R/proc $R/sys $R/dev 此刻还是**宿主机**（GitHub runner）的，
#    直接打包会带来两个后果：
#      1) 运行器是容器化环境，没有 CAP_SYS_ADMIN，一堆 /proc/sys 文件连 root 都读不了
#         → tar 刷 "Permission denied" 并返回非零，set -e 直接判整个 job 失败
#      2) 更糟的是它会真的去遍历宿主机的整个 procfs/sysfs（上百进程的伪文件），
#         巨慢无比，表现就是「卡住十几分钟没输出」，最后产出一个垃圾包。
echo "==> 卸载构建期挂载点"
for m in "$R/dev/pts" "$R/dev" "$R/sys" "$R/proc"; do
    sudo umount -l "$m" 2>/dev/null || true
done
# 复查一次真的卸干净了，没卸掉就要停下，别带着挂载点半成品往下走
LEFT=""
for d in dev/pts dev sys proc; do
    mountpoint -q "$R/$d" 2>/dev/null && LEFT="$LEFT $d"
done
[ -z "$LEFT" ] || { echo "!! 以下挂载点仍未卸载:$LEFT"; exit 1; }
echo "    已卸载干净"

# ---- 打包 ----
# 排除虚拟/临时文件系统：**内容**不要，但**目录本身**要保留
# （只写 './proc' 会把目录也排掉；'./proc/*' 才是留空目录的建议写法，
#  容器启动时 systemd 需要这些空目录作为挂载点）
echo "==> 打包 rootfs"
# ⚠️ tar 的选项必须放在文件列表（那个 "."）之前。
#    写在 "-C dir ." 之后时，--exclude 只对"后续参数"生效，而后面已经没有参数了，
#    tar 会刷 "has no effect" 警告并返回退出码 2 —— 上一次构建就是这么挂的。
# 同时加 --one-file-system：不跨越文件系统边界，即使忘了 umount，
# bind mount 的 /proc /sys /dev 也会被自动跳过（它们和 $R 分属不同 fs）。
sudo tar --one-file-system \
    --exclude='./proc/*' --exclude='./sys/*' --exclude='./dev/*' \
    --exclude='./run/*'  --exclude='./tmp/*' \
    -czf "$OUT_DIR/lxc-ubuntu.tar.gz" -C "$R" . || {
        echo "!! tar 打包失败（退出码 $?）"; exit 1; }
sudo chown "$(id -u):$(id -g)" "$OUT_DIR/lxc-ubuntu.tar.gz"

# ---- 6.4 打包结果校验 ----
# 包里如果还残留 proc/sys/dev 下的具体内容，说明上面某一道防线失效了，不能往下走
if tar -tzf "$OUT_DIR/lxc-ubuntu.tar.gz" | grep -qE '^\./(proc|sys|dev)/.'; then
    echo "!! 包里仍混有虚拟文件系统的内容，丢弃"
    exit 1
fi
[ -f "$OUT_DIR/lxc-ubuntu.tar.gz" ] || { echo "!! 产物不存在"; exit 1; }
SIZE=$(stat -c %s "$OUT_DIR/lxc-ubuntu.tar.gz")
# 正常范围 150MB ~ 600MB；小到几十 MB 说明 CrowdSec 根本没装进去
if [ "$SIZE" -lt 104857600 ]; then
    echo "!! 产物仅 ${SIZE} 字节（<100MB），明显不完整"
    exit 1
fi

echo "==> 完成：$OUT_DIR/lxc-ubuntu.tar.gz"
ls -lh "$OUT_DIR/lxc-ubuntu.tar.gz"
