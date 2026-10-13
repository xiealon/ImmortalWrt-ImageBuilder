#!/bin/sh
# =============================================================================
# /usr/sbin/crowdsec-lxc-bootstrap.sh
# 由 /etc/rc.local 后台拉起，每次开机跑一遍，幂等安全。
#
# 步骤（每步各自包在 if 内，仅验证自己的前置条件，不做全局验证）：
#   前置  每次开机统一 reconcile 容器 config（cmp 比对 + 抠不支持键 + 强制 lxc.start.auto）
#   步骤1 创建 LXC 容器 + 注册 bouncer —— 本地，不联网
#         前置：本地 api（路由器侧 bouncer 配置）不存在才运行，存在则跳过
#   步骤2 控制台绑定 enroll            —— 远程 api，联网，必须等步骤1 完成
#         前置：远程 api（.enrolled 标记）不存在才建立，存在则跳过
#   收尾  检查 nft 表
# =============================================================================

LXC_NAME="${LXC_NAME:-ubuntu}"
LXC_PATH="${LXC_PATH:-/srv/lxc}"
ROOTFS="$LXC_PATH/$LXC_NAME/rootfs"
TARBALL="${TARBALL:-/opt/lxc-ubuntu.tar.gz}"
CONTAINER_IP="${CONTAINER_IP:-10.0.0.10}"
LAPI_PORT="${LAPI_PORT:-8080}"
BOUNCER_NAME="${BOUNCER_NAME:-openwrt-fw}"
CSCLI=/usr/bin/cscli
MAX_WAIT="${MAX_WAIT:-60}"
SLEEP=5

SCRIPT_VER="2026-10-13.5"
log() { echo "[$(date '+%F %T')] $*"; }
log "===== crowdsec-lxc-bootstrap 版本 $SCRIPT_VER 开始执行 ====="

ct() { lxc-attach -P "$LXC_PATH" -n "$LXC_NAME" -- "$@"; }
ct_running() { lxc-ls -P "$LXC_PATH" --running 2>/dev/null | grep -qw "$LXC_NAME"; }

# 本地 bouncers API（LAPI）就绪判定：直接探端点本身，不跑 bouncers list
# （list 是一条需联网认证的慢查询，开机容器未拉起时会反复空转浪费时间）
lapi_ready() {
    ct sh -c '
        [ -S /var/lib/crowdsec/data/crowdsec-cli.sock ] && exit 0
        command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":8080" && exit 0
        exit 1
    ' 2>/dev/null
}

write_cfg() {
    local _dst="${1:-$LXC_PATH/$LXC_NAME/config}"
    cat > "$_dst" <<EOF
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

# 定位路由器侧 bouncer 段 + 读取 enroll 密钥（仅读取，不做任何验证）
SEC=$(uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
ENROLL_KEY_FILE="/etc/config/crowdsec_enroll_key.txt"
ENROLL_KEY=""
[ -f "$ENROLL_KEY_FILE" ] && ENROLL_KEY="$(head -n1 "$ENROLL_KEY_FILE" | tr -d ' \t\r\n')"
ENROLL_FLAG="$ROOTFS/var/lib/crowdsec/.enrolled"

# ---------- 容器 config 一致性校验 + 兼容性自愈（每次开机都跑，不受步骤1 跳过影响）----------
# 每次开机用 write_cfg 模板 cmp 比对 config：不一致就重写（模板含 lxc.start.auto = 1，
# 等于强制开机自启），并抠掉本机 LXC 不支持的键，保证 config 一定能被解析通过。
# 只写入本脚本自己生成的键，不碰任何用户手改内容（旧文件先备份）。
CFG="$LXC_PATH/$LXC_NAME/config"
mkdir -p "$LXC_PATH/$LXC_NAME"
_TMPL="$CFG.tmpl"
write_cfg "$_TMPL"
if [ ! -f "$CFG" ]; then
    mv "$_TMPL" "$CFG"; log "已写入容器 config"
elif ! cmp -s "$_TMPL" "$CFG"; then
    cp -f "$CFG" "$CFG.bak" 2>/dev/null; mv "$_TMPL" "$CFG"
    log "config 不一致，已备份旧配置并重写"
else
    rm -f "$_TMPL"
fi
if [ -f "$CFG" ] && ! lxc-info -P "$LXC_PATH" -n "$LXC_NAME" >/dev/null 2>&1; then
    # 缺 common.conf 时剔除 include 行
    if [ ! -f /usr/share/lxc/config/common.conf ]; then
        grep -v '^[[:space:]]*lxc.include' "$CFG" > "$CFG.tmp" 2>/dev/null && mv "$CFG.tmp" "$CFG"
        rm -f "$CFG.tmp"
    fi
    # 抠掉本机 LXC 不支持的配置键，直到 config 可解析
    _trim=0
    while [ $_trim -lt 20 ]; do
        if _err=$(lxc-info -P "$LXC_PATH" -n "$LXC_NAME" 2>&1); then break; fi
        _bad=$(printf '%s\n' "$_err" | sed -n 's/.*at line "\([^"]*\)".*/\1/p' | head -n1)
        [ -n "$_bad" ] || { log "!! config 解析失败取不到出错行"; break; }
        grep -v -F "$_bad" "$CFG" > "$CFG.tmp" 2>/dev/null && mv "$CFG.tmp" "$CFG"
        rm -f "$CFG.tmp"
        _trim=$((_trim+1))
    done
    # 仍失败则用已知模板兜底重写（旧文件先备份）
    if ! lxc-info -P "$LXC_PATH" -n "$LXC_NAME" >/dev/null 2>&1; then
        cp -f "$CFG" "$CFG.bak" 2>/dev/null; write_cfg
    fi
fi
if ! lxc-info -P "$LXC_PATH" -n "$LXC_NAME" >/dev/null 2>&1; then
    log "!! config 仍无法解析，放弃（排查：lxc-info -P $LXC_PATH -n $LXC_NAME）"; exit 1
fi

# ---------- 容器在线兜底（每次开机，config 已就绪且容器没跑就拉起）----------
if [ -f "$CFG" ] && [ -f "$ROOTFS/etc/crowdsec/config.yaml" ] && ! ct_running; then
    i=0
    while [ $i -lt $MAX_WAIT ] && ! ip link show lxcbr0 >/dev/null 2>&1; do
        i=$((i+1)); sleep $SLEEP
    done
    lxc-start -P "$LXC_PATH" -n "$LXC_NAME" -d 2>/dev/null && log "已拉起容器（开机自启兜底）"
fi

# ---------- 步骤1：创建 LXC 容器 + 注册 bouncer（本地，不联网）----------
# 前置：本地 api（bouncer 段 api_key 已写）存在则跳过，否则运行
if [ -z "$SEC" ] || [ -z "$(uci -q get "$SEC.api_key" 2>/dev/null)" ]; then
    log "本地 api 未建立，进入步骤1"

    # 1.1 解压 rootfs（仅首次）
    if [ ! -f "$ROOTFS/etc/crowdsec/config.yaml" ]; then
        [ -f "$TARBALL" ] || { log "!! 缺少 $TARBALL，放弃引导"; exit 1; }
        log "解压容器 rootfs..."
        mkdir -p "$ROOTFS"
        tar -xzf "$TARBALL" -C "$ROOTFS" || { log "!! 解压失败"; exit 1; }
        log "解压完成"
    fi

    # 1.2 等网桥 + 启动容器（已就绪则跳过）
    if ! ip link show lxcbr0 >/dev/null 2>&1; then
        i=0
        while [ $i -lt $MAX_WAIT ]; do
            ip link show lxcbr0 >/dev/null 2>&1 && break
            i=$((i+1)); sleep $SLEEP
        done
        [ $i -lt $MAX_WAIT ] || { log "!! lxcbr0 未出现，放弃"; exit 1; }
    fi
    if ! ct_running; then
        log "启动容器 $LXC_NAME"
        lxc-start -P "$LXC_PATH" -n "$LXC_NAME" -d
        sleep 5
    fi

    # 1.3 等容器 IP 通（已通则跳过）
    if ! ping -c1 -W2 "$CONTAINER_IP" >/dev/null 2>&1; then
        i=0
        while [ $i -lt $MAX_WAIT ]; do
            ping -c1 -W2 "$CONTAINER_IP" >/dev/null 2>&1 && break
            i=$((i+1)); sleep $SLEEP
        done
        [ $i -lt $MAX_WAIT ] || { log "!! 容器 IP $CONTAINER_IP 不通，放弃"; exit 1; }
    fi

    # 1.4 等本地 bouncers API（LAPI）就绪：直接探端点，比 bouncers list 快
    if ! lapi_ready; then
        i=0
        until lapi_ready; do
            i=$((i+1))
            [ $i -ge $MAX_WAIT ] && { log "!! LAPI 未就绪，放弃"; exit 1; }
            sleep $SLEEP
        done
    fi

    # 1.5 注册 bouncer（本地 api 缺失才进到此，直接建立；先删同名再 add 保证可覆写）
    ct $CSCLI bouncers delete "$BOUNCER_NAME" >/dev/null 2>&1 || true
    # 移除 hub 私网白名单：不删则 192.168/10 段全当自己人，局域网爆破不报警
    if ct $CSCLI parsers list 2>/dev/null | grep -q 'crowdsecurity/whitelists'; then
        ct $CSCLI parsers remove crowdsecurity/whitelists --force >/dev/null 2>&1 || true
        ct /usr/bin/systemctl restart crowdsec >/dev/null 2>&1 || true
        i=0
        until lapi_ready; do
            i=$((i+1)); [ $i -ge $MAX_WAIT ] && break; sleep $SLEEP
        done
    fi
    KEY=$(ct $CSCLI bouncers add "$BOUNCER_NAME" -o raw 2>/dev/null | tr -d '\r\n\t ')
    if [ -z "$KEY" ]; then log "!! 生成 bouncer key 失败"; exit 1; fi
    if [ -z "$SEC" ]; then
        uci add crowdsec bouncer >/dev/null 2>&1
        SEC=$(uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
    fi
    if [ -z "$SEC" ]; then log "!! 没有 bouncer 段，包可能未打进固件"; exit 1; fi
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
    log "已写入本地 api（$SEC）"
    if ! pgrep -x crowdsec-firewall-bouncer >/dev/null 2>&1 || ! nft list table ip crowdsec >/dev/null 2>&1; then
        service crowdsec-firewall-bouncer enable 2>/dev/null
        service crowdsec-firewall-bouncer restart 2>/dev/null
        log "bouncer 已生效"
    fi
fi

# ---------- 步骤2：控制台绑定 enroll（远程 API，联网）----------
# 前置：远程 api（.enrolled 标记）存在则跳过，否则建立
if [ -n "$ENROLL_KEY" ] && [ ! -f "$ENROLL_FLAG" ]; then
    log "进入步骤2：enroll"
    if ct $CSCLI console enroll "$ENROLL_KEY" >/dev/null 2>&1; then
        ct /usr/bin/systemctl restart crowdsec >/dev/null 2>&1 || true
        ct $CSCLI console enable --all >/dev/null 2>&1 || true
        mkdir -p "$ROOTFS/var/lib/crowdsec"
        : > "$ENROLL_FLAG"
        log "控制台绑定完成 —— 记得回 app.crowdsec.net 点 Accept"
    else
        log "!! enroll 失败（检查密钥是否正确 / 容器是否能联网）"
    fi
elif [ -n "$ENROLL_KEY" ]; then
    log "远程 api 已绑定，跳过 enroll"
else
    log "未提供 enroll 密钥，跳过"
fi

# ---------- 收尾 ----------
sleep 3
if nft list table ip crowdsec >/dev/null 2>&1; then
    log "✅ nftables crowdsec 表已建立，链路打通"
else
    log "⚠️ 未看到 nft crowdsec 表，检查 bouncer 日志"
fi
log "引导结束"
exit 0
