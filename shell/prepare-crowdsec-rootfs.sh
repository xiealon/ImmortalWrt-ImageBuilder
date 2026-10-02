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
# 产物：files/opt/lxc-ubuntu.tar.gz
# =============================================================================
set -euo pipefail

UBUNTU_BASE_URL="${UBUNTU_BASE_URL:-https://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release/ubuntu-base-22.04.5-base-amd64.tar.gz}"
CONTAINER_IP="${CONTAINER_IP:-10.0.0.10}"   # 容器固定 IP，要和 99-custom.sh 一致
BRIDGE_IP="${BRIDGE_IP:-10.0.0.1}"          # lxcbr0 网桥 IP，同时是容器网关/DNS

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/files/opt}"
WORK="${WORK:-/tmp/lxc-ubuntu-build}"
R="$WORK/rootfs"

echo "==> 目标容器 IP=${CONTAINER_IP}  网桥 IP=${BRIDGE_IP}"

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
apt-get install -y --no-install-recommends \
    systemd systemd-sysv systemd-networkd dbus \
    curl ca-certificates gnupg iproute2 iputils-ping

# CrowdSec 官方仓库
curl -fsSL https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash
apt-get install -y --no-install-recommends crowdsec

apt-get clean
rm -rf /var/lib/apt/lists/*
'
sudo rm -f "$R/usr/sbin/policy-rc.d"

# ---------- 4. 容器网络：静态 IP（不走 DHCP，IP 永不漂移）----------
sudo mkdir -p "$R/etc/systemd/network" "$R/etc/systemd/system/multi-user.target.wants"
sudo tee "$R/etc/systemd/network/10-eth0.network" >/dev/null <<EOF
[Match]
Name=eth0

[Network]
Address=${CONTAINER_IP}/24
Gateway=${BRIDGE_IP}
DNS=${BRIDGE_IP}
EOF

# 开机自启 networkd + crowdsec（chroot 里 systemctl enable 不可用，手动建软链）
if [ -f "$R/lib/systemd/system/systemd-networkd.service" ]; then
    sudo ln -sf /lib/systemd/system/systemd-networkd.service \
        "$R/etc/systemd/system/multi-user.target.wants/systemd-networkd.service"
fi
if [ -f "$R/lib/systemd/system/crowdsec.service" ]; then
    sudo ln -sf /lib/systemd/system/crowdsec.service \
        "$R/etc/systemd/system/multi-user.target.wants/crowdsec.service"
fi

echo "nameserver ${BRIDGE_IP}" | sudo tee "$R/etc/resolv.conf" >/dev/null
echo "crowdsec" | sudo tee "$R/etc/hostname" >/dev/null
# 清空 machine-id，让每台路由器首次开机各自生成，避免多机同 ID
: | sudo tee "$R/etc/machine-id" >/dev/null

# ---------- 5. CrowdSec 配置 ----------
sudo mkdir -p "$R/etc/crowdsec/acquis.d" \
              "$R/etc/crowdsec/parsers/s01-parse" \
              "$R/etc/crowdsec/parsers/s02-enrich"

# 5.1 LAPI 对外监听，否则路由器上的 bouncer 连不上
sudo sed -i 's|listen_uri: 127.0.0.1:8080|listen_uri: 0.0.0.0:8080|' "$R/etc/crowdsec/config.yaml"
# 5.2 把容器网段加进 LAPI 信任列表（保险，bouncer 实际用 api_key 认证）
#     用 awk 而不是 sed 'a\text'：sed 的 a 命令对前导空格/转义换行处理不一致
sudo awk '
    /^[[:space:]]*trusted_ips:/ { print; print "      - '${BRIDGE_IP}'"; print "      - 10.0.0.0/24"; next }
    { print }
' "$R/etc/crowdsec/config.yaml" > "$WORK/config.yaml.new"
sudo mv "$WORK/config.yaml.new" "$R/etc/crowdsec/config.yaml"
grep -q "listen_uri: 0.0.0.0:8080" "$R/etc/crowdsec/config.yaml" \
    || { echo "!! listen_uri 修改失败，检查 crowdsec 版本"; exit 1; }

# 5.3 日志源：UDP 514 收路由器 syslog
sudo tee "$R/etc/crowdsec/acquis.d/router.yaml" >/dev/null <<'EOF'
source: syslog
listen_addr: 0.0.0.0
listen_port: 514
protocol: udp
labels:
  type: syslog
EOF

# 5.4 dropbear 解析器（hub 自带那条只认 PAM 文案，OpenWrt 是非 PAM，必须自己写）
#     这里是在 .sh 文件里用 heredoc 写盘，缩进不会被吃掉，比网页复制粘贴可靠
sudo tee "$R/etc/crowdsec/parsers/s01-parse/openwrt-dropbear.yaml" >/dev/null <<'EOF'
name: openwrt/dropbear-logs
description: Parse OpenWrt non-PAM dropbear logs
filter: evt.Parsed.program == 'dropbear'
onsuccess: next_stage
nodes:
  - grok:
      pattern: "Bad password attempt for '?%{DATA:username}'? from %{IP:source_ip}:%{INT:source_port}"
      apply_on: message
    statics:
      - meta: log_type
        value: ssh_failed-auth
  - grok:
      pattern: "Login attempt for nonexistent user %{GREEDYDATA:username} from %{IP:source_ip}:%{INT:source_port}"
      apply_on: message
    statics:
      - meta: log_type
        value: ssh_failed-auth
  - grok:
      pattern: "Exit before auth from <%{IP:source_ip}:%{INT:source_port}>"
      apply_on: message
    statics:
      - meta: log_type
        value: ssh_failed-auth
  - grok:
      pattern: "Password auth succeeded for '?%{DATA:username}'? from %{IP:source_ip}:%{INT:source_port}"
      apply_on: message
    statics:
      - meta: log_type
        value: ssh_auth_success
  - grok:
      pattern: "Pubkey auth succeeded for '?%{DATA:username}'? with key %{DATA:key_type} from %{IP:source_ip}:%{INT:source_port}"
      apply_on: message
    statics:
      - meta: log_type
        value: ssh_auth_success
statics:
  - meta: service
    value: ssh
  - meta: source_ip
    expression: evt.Parsed.source_ip
  - meta: username
    expression: evt.Parsed.username
EOF

# 5.5 白名单占位（等于不白名单任何 IP）
sudo tee "$R/etc/crowdsec/parsers/s02-enrich/openwrt-whitelist.yaml" >/dev/null <<'EOF'
name: openwrt/my-whitelist
description: 'No whitelist configured - placeholder only'
whitelist:
  reason: placeholder, nothing is whitelisted
  ip:
    - 127.0.0.1
  cidr:
    - 240.0.0.0/4
EOF

# 5.6 校验：必须是 3，少一条说明规则写坏了
N=$(grep -c 'value: ssh_failed-auth' "$R/etc/crowdsec/parsers/s01-parse/openwrt-dropbear.yaml")
echo "==> 解析器校验 ssh_failed-auth 条数 = ${N}（应为 3）"
[ "$N" -eq 3 ] || { echo "!! 解析器写入异常"; exit 1; }

# ---------- 6. 打包 ----------
# 注意：hub 的 crowdsecurity/whitelists 只能在容器跑起来后用 cscli 删除，
#       放到开机引导脚本里做（这里 cscli 连不上 LAPI）。
sudo tar -czf "$OUT_DIR/lxc-ubuntu.tar.gz" -C "$R" .
sudo chown "$(id -u):$(id -g)" "$OUT_DIR/lxc-ubuntu.tar.gz"

echo "==> 完成：$OUT_DIR/lxc-ubuntu.tar.gz"
ls -lh "$OUT_DIR/lxc-ubuntu.tar.gz"
