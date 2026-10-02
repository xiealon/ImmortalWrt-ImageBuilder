#!/bin/sh
# =============================================================================
# /usr/sbin/crowdsec-lxc-bootstrap.sh
#
# 首次开机引导（由 /etc/rc.local 后台拉起）：
#   1. 从 /opt/lxc-ubuntu.tar.gz 解压容器 rootfs 到 /srv/lxc/ubuntu/rootfs
#   2. 写容器 config，lxc-start 拉起容器
#   3. 等容器内 systemd + CrowdSec LAPI 就绪
#   4. 删掉 hub 的私网白名单（否则局域网爆破一个都不报）
#   5. cscli bouncers add 生成 LAPI key
#   6. 把 key 写回路由器 /etc/config/crowdsec 的 bouncer 段并重启 bouncer
#
# 全程幂等：api_key 已经存在就直接退出，重复开机不会重复注册。
# =============================================================================

LXC_NAME="${LXC_NAME:-ubuntu}"
LXC_PATH="${LXC_PATH:-/srv/lxc}"
ROOTFS="$LXC_PATH/$LXC_NAME/rootfs"
TARBALL="${TARBALL:-/opt/lxc-ubuntu.tar.gz}"
CONTAINER_IP="${CONTAINER_IP:-10.0.0.10}"
LAPI_PORT="${LAPI_PORT:-8080}"
BOUNCER_NAME="${BOUNCER_NAME:-openwrt-fw}"
CSCLI=/usr/bin/cscli
MAX_WAIT="${MAX_WAIT:-60}"     # 每个等待阶段最多重试 60 次 × 5s = 5 分钟
SLEEP=5

log() { echo "[$(date '+%F %T')] $*"; }

# 在容器里执行一条命令
ct() { lxc-attach -P "$LXC_PATH" -n "$LXC_NAME" -- "$@"; }

# ---------- 0. 幂等：key 已经在就走人 ----------
SEC=$(uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
if [ -n "$SEC" ] && [ -n "$(uci -q get "$SEC.api_key" 2>/dev/null)" ]; then
    log "bouncer api_key 已存在，跳过引导"
    exit 0
fi

# ---------- 1. 解压 rootfs ----------
if [ ! -f "$ROOTFS/etc/crowdsec/config.yaml" ]; then
    [ -f "$TARBALL" ] || { log "!! 缺少 $TARBALL，放弃引导"; exit 1; }
    log "解压容器 rootfs（约 1-2 分钟）..."
    mkdir -p "$ROOTFS"
    tar -xzf "$TARBALL" -C "$ROOTFS" || { log "!! 解压失败"; exit 1; }
    log "解压完成"
fi

# ---------- 2. 容器 config ----------
mkdir -p "$LXC_PATH/$LXC_NAME"
if [ ! -f "$LXC_PATH/$LXC_NAME/config" ]; then
cat > "$LXC_PATH/$LXC_NAME/config" <<EOF
lxc.start.auto = 1
lxc.start.order = 10
lxc.arch = amd64
lxc.include = /usr/share/lxc/config/common.conf
lxc.rootfs.path = dir:$ROOTFS
lxc.init.cmd = /sbin/init
lxc.autodev = 1
lxc.kmsg = 0
lxc.net.0.type = veth
lxc.net.0.link = lxcbr0
lxc.net.0.flags = up
lxc.net.0.hwaddr = 10:66:6A:7C:05:9A
lxc.tty.max = 4
lxc.pty.max = 1024
EOF
log "已写入容器 config"
fi

# ---------- 3. 拉起容器 ----------
# 先等 lxcbr0 出现（99-custom.sh 只是写了 uci，网桥要等 network 服务起来才有）
i=0
while [ $i -lt $MAX_WAIT ]; do
    ip link show lxcbr0 >/dev/null 2>&1 && break
    i=$((i+1)); sleep $SLEEP
done
[ $i -lt $MAX_WAIT ] || { log "!! lxcbr0 未出现，放弃"; exit 1; }

if ! (lxc-ls -P "$LXC_PATH" --running 2>/dev/null | grep -qw "$LXC_NAME"); then
    log "启动容器 $LXC_NAME ..."
    lxc-start -P "$LXC_PATH" -n "$LXC_NAME" -d
fi

# ---------- 3.1 等容器 IP 通 ----------
i=0
while [ $i -lt $MAX_WAIT ]; do
    ping -c1 -W2 "$CONTAINER_IP" >/dev/null 2>&1 && break
    i=$((i+1)); sleep $SLEEP
done
[ $i -lt $MAX_WAIT ] || { log "!! 容器 IP $CONTAINER_IP 不通，放弃"; exit 1; }
log "容器已在线"

# ---------- 3.2 等 CrowdSec LAPI 就绪（用 cscli 探测，比 curl /health 兼容）----------
i=0
until ct $CSCLI bouncers list >/dev/null 2>&1; do
    i=$((i+1))
    [ $i -ge $MAX_WAIT ] && { log "!! LAPI 长时间未就绪，放弃"; exit 1; }
    sleep $SLEEP
done
log "CrowdSec LAPI 已就绪"

# ---------- 4. 移除 hub 的私网白名单 ----------
# 不删这条，192.168.x.x / 10.x.x.x 全被当成自己人，局域网爆破一个都不报
if ct $CSCLI parsers list 2>/dev/null | grep -q 'crowdsecurity/whitelists'; then
    log "移除 hub 私网白名单"
    ct $CSCLI parsers remove crowdsecurity/whitelists --force >/dev/null 2>&1 || true
    ct /usr/bin/systemctl restart crowdsec >/dev/null 2>&1 || true
    i=0
    until ct $CSCLI bouncers list >/dev/null 2>&1; do
        i=$((i+1)); [ $i -ge $MAX_WAIT ] && break; sleep $SLEEP
    done
fi

# ---------- 5. 生成 bouncer key ----------
KEY=$(ct $CSCLI bouncers add "$BOUNCER_NAME" -o raw 2>/dev/null | tr -d '\r\n\t ')
if [ -z "$KEY" ]; then
    log "!! 生成 bouncer key 失败"
    exit 1
fi
log "已生成 bouncer key: ${KEY}"

# ---------- 6. 写回路由器 /etc/config/crowdsec ----------
# 注意：bouncer 是匿名段，必须用 @bouncer[n]，不能写 crowdsec.bouncer.xxx
if [ -z "$SEC" ]; then
    uci add crowdsec bouncer >/dev/null 2>&1
    SEC=$(uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
fi
if [ -z "$SEC" ]; then
    log "!! /etc/config/crowdsec 没有 bouncer 段，bouncer 包可能没打进固件"
    exit 1
fi

uci set "$SEC.enabled=1"
uci set "$SEC.api_url=http://${CONTAINER_IP}:${LAPI_PORT}/"
uci set "$SEC.api_key=$KEY"
uci set "$SEC.ipv4=1"
uci set "$SEC.ipv6=0"
uci set "$SEC.deny_action=drop"
uci set "$SEC.filter_input=1"
uci set "$SEC.filter_forward=1"
uci -q del "$SEC.interface"
uci add_list "$SEC.interface=br-lan"
uci commit crowdsec
log "已写入 $SEC"

# ---------- 7. 启 bouncer ----------
service crowdsec-firewall-bouncer enable 2>/dev/null
service crowdsec-firewall-bouncer restart 2>/dev/null
log "bouncer 已重启"

# ---------- 8. 收尾 ----------
sleep 3
if nft list table ip crowdsec >/dev/null 2>&1; then
    log "✅ nftables crowdsec 表已建立，链路打通"
else
    log "⚠️ 未看到 nft crowdsec 表，检查 bouncer 日志"
fi
log "引导结束"
exit 0
