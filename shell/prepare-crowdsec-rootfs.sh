#!/usr/bin/env bash
set -euo pipefail

UBUNTU_BASE_URL="${UBUNTU_BASE_URL:-https://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release/ubuntu-base-22.04.5-base-amd64.tar.gz}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/files/etc/crowdsec}"
WORK="${WORK:-/tmp/lxc-ubuntu-build}"
R="$WORK/rootfs"

rm -rf "$WORK"
mkdir -p "$R" "$OUT_DIR"
echo "==> 下载 ubuntu-base"
curl -fsSL "$UBUNTU_BASE_URL" -o "$WORK/base.tar.gz"
sudo tar -xzf "$WORK/base.tar.gz" -C "$R"

sudo cp /etc/resolv.conf "$R/etc/resolv.conf"
printf '#!/bin/sh\nexit 101\n' | sudo tee "$R/usr/sbin/policy-rc.d" >/dev/null
sudo chmod +x "$R/usr/sbin/policy-rc.d"

sudo mount --bind /proc    "$R/proc"
sudo mount --bind /sys     "$R/sys"
sudo mount --bind /dev     "$R/dev"
sudo mount --bind /dev/pts "$R/dev/pts"
trap 'sudo umount -lf "$R/dev/pts" "$R/dev" "$R/sys" "$R/proc" 2>/dev/null || true' EXIT

echo "==> chroot 安装 CrowdSec（约 2-4 分钟）"
sudo chroot "$R" /bin/bash -eu -c '
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
apt-get update -qq

PKGS="systemd systemd-sysv dbus curl ca-certificates gnupg iproute2 iputils-ping"

MISS=""
for p in $PKGS; do
    apt-cache show "$p" >/dev/null 2>&1 || MISS="$MISS $p"
done
if [ -n "$MISS" ]; then
    echo "!! 以下包在当前源里不存在，请检查包名或 base 版本:$MISS"
    exit 1
fi

apt-get install -y --no-install-recommends $PKGS

curl -fsSL https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash
apt-get install -y --no-install-recommends crowdsec

if [ ! -e /lib/systemd/systemd-networkd ] && ! command -v systemd-networkd >/dev/null 2>&1; then
    echo "!! systemd-networkd 二进制缺失，容器将无法配置静态 IP"
    exit 1
fi

apt-get clean
rm -rf /var/lib/apt/lists/*
'
sudo rm -f "$R/usr/sbin/policy-rc.d"


echo "==> 卸载构建期挂载点"
for m in "$R/dev/pts" "$R/dev" "$R/sys" "$R/proc"; do
    sudo umount -l "$m" 2>/dev/null || true
done
LEFT=""
for d in dev/pts dev sys proc; do
    mountpoint -q "$R/$d" 2>/dev/null && LEFT="$LEFT $d"
done
[ -z "$LEFT" ] || { echo "!! 以下挂载点仍未卸载:$LEFT"; exit 1; }
echo "    已卸载干净"

echo "==> 打包 rootfs"
sudo tar --one-file-system \
    --exclude='./proc/*' --exclude='./sys/*' --exclude='./dev/*' \
    --exclude='./run/*'  --exclude='./tmp/*' \
    -czf "$OUT_DIR/lxc-ubuntu.tar.gz" -C "$R" . || {
        echo "!! tar 打包失败（退出码 $?）"; exit 1; }
sudo chown "$(id -u):$(id -g)" "$OUT_DIR/lxc-ubuntu.tar.gz"

if tar -tzf "$OUT_DIR/lxc-ubuntu.tar.gz" | grep -qE '^\./(proc|sys|dev)/.'; then
    echo "!! 包里仍混有虚拟文件系统的内容，丢弃"
    exit 1
fi
[ -f "$OUT_DIR/lxc-ubuntu.tar.gz" ] || { echo "!! 产物不存在"; exit 1; }
SIZE=$(stat -c %s "$OUT_DIR/lxc-ubuntu.tar.gz")
if [ "$SIZE" -lt 104857600 ]; then
    echo "!! 产物仅 ${SIZE} 字节（<100MB），明显不完整"
    exit 1
fi

echo "==> 完成：$OUT_DIR/lxc-ubuntu.tar.gz"
ls -lh "$OUT_DIR/lxc-ubuntu.tar.gz"
