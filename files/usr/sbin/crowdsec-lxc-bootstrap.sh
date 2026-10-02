#!/bin/sh
# =============================================================================
# /usr/sbin/crowdsec-lxc-bootstrap.sh
#
# 由 /etc/rc.local 后台拉起。全程幂等，每次开机跑一遍都安全。
#
# 流程：
#   0. 探测状态：容器在不在跑 / bouncer key 有没有
#   1. 一切都好 → 秒退（常规路径，避免每次开机都白等几分钟）
#   2. 从 /opt/lxc-ubuntu.tar.gz 解压 rootfs 到 /srv/lxc/ubuntu/rootfs
#   3. 写容器 config，等 lxcbr0 就绪，确保容器拉起来
#   4. 等容器 IP 通 + 容器内 CrowdSec LAPI 就绪
#   5. 仅首次：删 hub 私网白名单 → cscli bouncers add 取 key → 写回 uci
#   6. 每次：确保 bouncer 服务启用并已加载 nftables 规则
#
# ⚠️ 第 0 步不能只看 key：如果容器挂了但 key 还在，脚本会在最开头退出，
#    结果容器起不来、日志源断供，而固件完全无任何提示。必须同时检查容器状态。
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

# 版本标记：每次运行都写进日志。
# 排错时最怕的情况是「以为刷进去了、其实路由器上跑的还是旧脚本」——
# 有了这行，看一眼日志就知道路由器上是哪一版，不用去比对文件内容。
SCRIPT_VER="2026-10-03.2"

log() { echo "[$(date '+%F %T')] $*"; }

log "===== crowdsec-lxc-bootstrap 版本 $SCRIPT_VER 开始执行 ====="

# 在容器里执行一条命令
ct() { lxc-attach -P "$LXC_PATH" -n "$LXC_NAME" -- "$@"; }

# 容器是否在运行
ct_running() {
    lxc-ls -P "$LXC_PATH" --running 2>/dev/null | grep -qw "$LXC_NAME"
}

# ---------- 0. 状态探测 ----------
SEC=$(uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
HAS_KEY=0
if [ -n "$SEC" ] && [ -n "$(uci -q get "$SEC.api_key" 2>/dev/null)" ]; then
    HAS_KEY=1
fi

# 常规路径：容器在跑 + key 已有 → 什么都不用做，直接走人。
# 这条必须在最前面，否则下面那些最长 5 分钟的等待会把每次开机都拖慢。
if [ "$HAS_KEY" = 1 ] && ct_running; then
    log "容器在跑且 bouncer key 已存在，无需引导"
    exit 0
fi
[ "$HAS_KEY" = 1 ] || log "尚未注册 bouncer，执行首次引导"
ct_running || log "容器未在运行，尝试拉起"

# ---------- 1. 解压 rootfs ----------
FRESH=0
if [ ! -f "$ROOTFS/etc/crowdsec/config.yaml" ]; then
    [ -f "$TARBALL" ] || { log "!! 缺少 $TARBALL，放弃引导"; exit 1; }
    log "解压容器 rootfs（约 1-2 分钟）..."
    mkdir -p "$ROOTFS"
    tar -xzf "$TARBALL" -C "$ROOTFS" || { log "!! 解压失败"; exit 1; }
    log "解压完成"
    FRESH=1
fi

# ---------- 2. 容器 config ----------
CFG="$LXC_PATH/$LXC_NAME/config"
mkdir -p "$LXC_PATH/$LXC_NAME"

# 已知可用的最小 config，抽成函数：
#   - 首次生成时调用
#   - 下面自愈彻底失败时，用它兜底重写（旧文件先备份）
# 注意：这里故意不写 lxc.kmsg。OpenWrt 的 lxc 是裁剪编译的，
# 很多可选键没编进 confile.c（实测 lxc.kmsg 就不支持），一旦 config 里出现
# 不支持的键，整个文件解析失败，所有 lxc-* 命令都会 "Failed to load config"。
write_cfg() {
cat > "$CFG" <<EOF
lxc.start.auto = 1
lxc.start.order = 10
lxc.arch = amd64
lxc.include = /usr/share/lxc/config/common.conf
lxc.rootfs.path = dir:$ROOTFS
lxc.init.cmd = /sbin/init
lxc.autodev = 1
lxc.net.0.type = veth
lxc.net.0.link = lxcbr0
lxc.net.0.flags = up
lxc.net.0.hwaddr = 10:66:6A:7C:05:9A
lxc.tty.max = 4
lxc.pty.max = 1024
EOF
}

if [ ! -f "$CFG" ]; then
    write_cfg
    log "已写入容器 config"
else
    # 关键：老固件（或手工搭的容器）留下的 config 可能在，但内容带不支持的键。
    # 这里只提示不处理，下面的自愈会负责修。
    log "容器 config 已存在，先做兼容性校验"
fi

# ---------- 2.1 配置键兼容性自愈 ----------
# common.conf 由 lxc-configs 包提供。它没装上的话，include 这行本身就会让解析失败，
# 而且报错形式不是"某行不认识"，上面抠行号的办法抓不到，所以单独判一次。
if [ ! -f /usr/share/lxc/config/common.conf ]; then
    log "!! 缺少 /usr/share/lxc/config/common.conf（lxc-configs 包没装上），剔除 include 行"
    grep -v '^[[:space:]]*lxc.include' "$CFG" > "$CFG.tmp" 2>/dev/null && mv "$CFG.tmp" "$CFG"
    rm -f "$CFG.tmp"
fi

# 光靠"我写的时候避开已知不支持的键"不够——不同版本/不同机型裁掉的键不一样。
# 这里拿 lxc-info 当探测器：它会解析 config，解析失败就把出错的那一行抠出来删掉，再重试。
# 这样无论 LXC 编译时裁掉了哪个键，脚本都能自己收敛到一个能用的 config。
_trim=0
while [ $_trim -lt 20 ]; do
    if _err=$(lxc-info -P "$LXC_PATH" -n "$LXC_NAME" 2>&1); then
        break
    fi
    # 报错形如：... Failed to parse config file "..." at line "lxc.kmsg = 0"
    _bad=$(printf '%s\n' "$_err" | sed -n 's/.*at line "\([^"]*\)".*/\1/p' | head -n1)
    [ -n "$_bad" ] || { log "!! config 解析失败但取不到出错行，原文：$_err"; break; }
    log "剔除本机 LXC 不支持的配置键: $_bad"
    grep -v -F "$_bad" "$CFG" > "$CFG.tmp" 2>/dev/null && mv "$CFG.tmp" "$CFG"
    rm -f "$CFG.tmp"
    _trim=$((_trim+1))
done

# 二次兜底：抠行只能处理「报错里带了出错行」的情况。
# 如果 LXC 换了报错格式、或者 config 被别的东西改坏到抠不出来，
# 上面的循环会原地打转然后退出。这里直接把 config 换成已知可用的模板重写——
# 反正这份 config 是脚本自己生成的，没有任何用户手改内容需要保护（先备份）。
if ! lxc-info -P "$LXC_PATH" -n "$LXC_NAME" >/dev/null 2>&1; then
    log "!! 自愈未能修好 config，改用已知模板重写（旧文件已备份为 $CFG.bak）"
    cp -f "$CFG" "$CFG.bak" 2>/dev/null
    write_cfg
fi

if ! lxc-info -P "$LXC_PATH" -n "$LXC_NAME" >/dev/null 2>&1; then
    log "!! 容器 config 仍无法解析，放弃引导（现场排查：lxc-info -P $LXC_PATH -n $LXC_NAME）"
    exit 1
fi
log "容器 config 校验通过"

# ---------- 3. 确保容器在跑 ----------
# 先等 lxcbr0 出现（99-custom.sh 只是写了 uci，网桥要等 network 服务起来才有）
i=0
while [ $i -lt $MAX_WAIT ]; do
    ip link show lxcbr0 >/dev/null 2>&1 && break
    i=$((i+1)); sleep $SLEEP
done
[ $i -lt $MAX_WAIT ] || { log "!! lxcbr0 未出现，放弃"; exit 1; }

if ! ct_running; then
    log "启动容器 $LXC_NAME ..."
    lxc-start -P "$LXC_PATH" -n "$LXC_NAME" -d
    # 给它一点时间，避免后面紧跟着的探测全打空
    sleep 5
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

# 若本次是全新解压的 rootfs，容器里的 CrowdSec 是干净的（/var/lib/crowdsec 为空，
# 没有任何已注册的 bouncer），uci 里残留的旧 key 必然已失效。
# 此时绝不能因为 HAS_KEY=1 就跳过注册——否则 bouncer 会拿着失效 key 永久连不上。
# 强制按首次引导重新注册，下面 4.3 会把新 key 覆盖写回同一个 uci 段。
# （正常重启不会走到这：rootfs 在 overlay 持久层，不会被重新解压。）
if [ "$FRESH" = 1 ] && [ "$HAS_KEY" = 1 ]; then
    log "检测到全新 rootfs，uci 里的旧 bouncer key 已失效，重新注册"
    HAS_KEY=0
fi

# ---------- 4. 首次才会走到这里：注册 bouncer ----------
if [ "$HAS_KEY" = 0 ]; then

    # 4.1 移除 hub 的私网白名单
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

    # 4.2 生成 bouncer key
    KEY=$(ct $CSCLI bouncers add "$BOUNCER_NAME" -o raw 2>/dev/null | tr -d '\r\n\t ')
    if [ -z "$KEY" ]; then
        log "!! 生成 bouncer key 失败"
        exit 1
    fi
    log "已生成 bouncer key"

    # 4.3 写回路由器 /etc/config/crowdsec
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
fi

# ---------- 5. 每次都要确保 bouncer 生效 ----------
# 即使 key 早已存在，异常关机后服务也可能没起来，这里无条件兜一次
service crowdsec-firewall-bouncer enable 2>/dev/null
service crowdsec-firewall-bouncer restart 2>/dev/null
log "bouncer 已重启"

# ---------- 6. 收尾检查 ----------
sleep 3
if nft list table ip crowdsec >/dev/null 2>&1; then
    log "✅ nftables crowdsec 表已建立，链路打通"
else
    log "⚠️ 未看到 nft crowdsec 表，检查 bouncer 日志"
fi
log "引导结束"
exit 0
