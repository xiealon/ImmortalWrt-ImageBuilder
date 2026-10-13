#!/bin/sh
# =============================================================================
# /usr/sbin/crowdsec-lxc-bootstrap.sh
# 由 /etc/rc.local 后台拉起，每次开机跑一遍，幂等安全。
#
# 步骤（每步各自包在 if 内，仅验证自己的前置条件，不做全局验证）：
#   前置  容器 config 校验（缺失或与模板不一致才 reconcile + 抠不支持键 + 强制 lxc.start.auto）
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

SCRIPT_VER="2026-10-13.10"
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

# ---------- 容器 config 校验 + 兼容性自愈（缺失或不一致才运行，受 if 守卫）----------
# 用 write_cfg 模板 cmp 比对 config：缺失或不同才重写（模板含 lxc.start.auto = 1，
# 等于强制开机自启），并抠掉本机 LXC 不支持的键，保证 config 一定能被解析通过。
# 只写入本脚本自己生成的键，不碰任何用户手改内容（不一致直接覆盖，不备份）。
CFG="$LXC_PATH/$LXC_NAME/config"
mkdir -p "$LXC_PATH/$LXC_NAME"
_TMPL="$CFG.tmpl"
write_cfg "$_TMPL"
# 仅当 config 缺失或与模板不一致时才 reconcile，否则跳过（不重复写、不空转）
if [ ! -f "$CFG" ] || ! cmp -s "$_TMPL" "$CFG"; then
    if [ ! -f "$CFG" ]; then
        mv "$_TMPL" "$CFG"; log "已写入容器 config"
    else
        mv "$_TMPL" "$CFG"
        log "config 不一致，已直接覆盖重写"
    fi
    # 抠掉本机 LXC 不支持的配置键，直到 config 可解析
    if [ -f "$CFG" ] && ! lxc-info -P "$LXC_PATH" -n "$LXC_NAME" >/dev/null 2>&1; then
        # 缺 common.conf 时剔除 include 行
        if [ ! -f /usr/share/lxc/config/common.conf ]; then
            grep -v '^[[:space:]]*lxc.include' "$CFG" > "$CFG.tmp" 2>/dev/null && mv "$CFG.tmp" "$CFG"
            rm -f "$CFG.tmp"
        fi
        _trim=0
        while [ $_trim -lt 20 ]; do
            if _err=$(lxc-info -P "$LXC_PATH" -n "$LXC_NAME" 2>&1); then break; fi
            _bad=$(printf '%s\n' "$_err" | sed -n 's/.*at line "\([^"]*\)".*/\1/p' | head -n1)
            [ -n "$_bad" ] || { log "!! config 解析失败取不到出错行"; break; }
            grep -v -F "$_bad" "$CFG" > "$CFG.tmp" 2>/dev/null && mv "$CFG.tmp" "$CFG"
            rm -f "$CFG.tmp"
            _trim=$((_trim+1))
        done
        # 仍失败则用已知模板兜底重写（直接覆盖）
        if ! lxc-info -P "$LXC_PATH" -n "$LXC_NAME" >/dev/null 2>&1; then
            write_cfg
        fi
    fi
fi
# 最终解析兜底：config 仍无法解析则放弃
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
# 有效性分级（修复"网页端删了 API、设备内不删 → 重启不重连"）：
#   老逻辑只看 .enrolled 标记文件，而网页端删除 API 不会动设备内任何文件，
#   于是重启永远走"已绑定，跳过 enroll"，本地凭据变成服务端不认识的孤儿，
#   crowdsec 推送 signals 一直 401，控制台再也不刷新。
#   现在先探容器外网，再按 console status 的实际结果分四态：
#     0 = 凭据在且有效
#     1 = 本地无凭据（首次 enroll）
#     2 = 凭据被服务端拒绝（console status 出现 not enrolled / 401/403/unauthorized/invalid/revoked → 需重连）
#     3 = 外网不通，本次不判（凭据原样不动，留给下次开机再判）
#   只有 2 才清理凭据+标记后重连。探测放在容器内跑（不是路由器侧）：
#   容器走 NAT 出网，必须测 cscli 真正会走的那条路径（SNAT 配错时路由器通、容器不通）。
remote_enroll_state() {
    ct sh -c '
        [ -s /etc/crowdsec/online_api_credentials.yaml ] || exit 1
        # 外网双探测：任一 DNS 通即算在线；全不通 → exit 3，整个检查跳过
        # （ICMP 被运营商封很常见，ping 不通只等于"这次不判"，绝不动凭据）
        if command -v ping >/dev/null 2>&1; then
            ping -c1 -W3 233.5.5.5 >/dev/null 2>&1 || ping -c1 -W3 119.29.29.29 >/dev/null 2>&1 || exit 3
        else
            # 容器没装 ping：退化成 curl 探 console API，收到任何 HTTP 响应即算通
            curl -s -m 8 -o /dev/null https://api.crowdsec.net 2>/dev/null || exit 3
        fi
        _out=$(cscli console status 2>&1)
        # 失效措辞各版本不同：401/unauthorized/invalid/revoked（多数版本）
        # 或 "not enrolled"（console status 的 Enroll API 段打 ✗ 时，实测输出）
        printf "%s\n" "$_out" | grep -qiE "unauthorized|forbidden|not authorized|invalid|revoked|401|403|not enrolled" && exit 2
        exit 0
    ' 2>/dev/null
}

if [ -n "$ENROLL_KEY" ]; then
    remote_enroll_state; _re=$?
    _CRED_BAK=""
    if [ "$_re" -eq 3 ]; then
        log "外网不通，跳过远程 api 健康检查（凭据不动，下次开机再判）"
    elif [ "$_re" -eq 0 ]; then
        log "远程 api 已绑定且有效，跳过 enroll"
    else
        if [ "$_re" -eq 2 ]; then
            log "远程 api 已失效（网页端删除/密钥被撤），备份旧凭据后重连"
            # 备份而非直接删：凭据文件缺失会让 require.LAPI 加载失败，
            # 连 cscli bouncers list 都用不了（实测报错）。enroll 失败必须能回滚。
            _CRED_BAK="$ROOTFS/etc/crowdsec/online_api_credentials.yaml.bak"
            mv -f "$ROOTFS/etc/crowdsec/online_api_credentials.yaml" "$_CRED_BAK" 2>/dev/null || true
            rm -f "$ENROLL_FLAG"
            ct /usr/bin/systemctl restart crowdsec >/dev/null 2>&1 || true
        else
            log "本地无 enroll 凭据，进入 enroll"
        fi
        if ct $CSCLI console enroll "$ENROLL_KEY" >/dev/null 2>&1; then
            ct /usr/bin/systemctl restart crowdsec >/dev/null 2>&1 || true
            ct $CSCLI console enable --all >/dev/null 2>&1 || true
            mkdir -p "$ROOTFS/var/lib/crowdsec"
            : > "$ENROLL_FLAG"
            [ -n "$_CRED_BAK" ] && rm -f "$_CRED_BAK"
            log "控制台绑定完成 —— 记得回 app.crowdsec.net 点 Accept"
        else
            if [ -n "$_CRED_BAK" ] && [ -f "$_CRED_BAK" ]; then
                mv -f "$_CRED_BAK" "$ROOTFS/etc/crowdsec/online_api_credentials.yaml"
                log "已回滚旧凭据（cscli bouncers 等本地功能不受影响）"
            fi
            log "!! enroll 失败（enroll key 为一次性；去 app.crowdsec.net 重新生成，更新 /etc/config/crowdsec_enroll_key.txt）"
        fi
    fi
else
    log "未提供 enroll 密钥，跳过"
fi

# ---------- 收尾：本地 LAPI 链路体检（bouncer ↔ 容器 LAPI）----------
# 与远程 console status 判定对称：不只看静态字段，看动态心跳。
# 判据是 cscli bouncers inspect 的 last_pull —— LAPI 每次收到 bouncer 的
# pull 请求就自动刷新这个墙钟时间（RFC3339）。它新鲜 ⇒ 路由器→容器网络 +
# api_key 认证 + LAPI 服务三者全通。name/valid/type/auth_type 只是静态佐证。
# bouncer 默认约 10s 拉一次；开机后首次 pull 需要一点时间，这里只对
# "从未 pull"继续等（最多 60 秒），其他失败立即出结论，避免无谓空等。
local_lapi_state() {
    # $1 = bouncer 名。返回：0 健康 / 1 从未 pull / 2 pull 过久(>5min) / 3 已吊销 / 10 查不到
    ct sh -c '
        _bn="$1"
        _out=$(cscli bouncers inspect "$_bn" -o json 2>/dev/null) || exit 10
        _rv=$(printf "%s\n" "$_out" | sed -n "s/.*\"revoked\"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p")
        _lp=$(printf "%s\n" "$_out" | sed -n "s/.*\"last_pull\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p")
        [ "$_rv" = "true" ] && exit 3
        [ -z "$_lp" ] && exit 1
        _now=$(date +%s)
        _ts=$(date -d "$_lp" +%s 2>/dev/null || echo 0)
        [ $((_now - _ts)) -gt 300 ] && exit 2
        exit 0
    ' _ "$1"
}

# 仅当固件真的带了容器（rootfs 已解压）且 bouncer 段存在时才体检，
# 没勾 include_crowdsec 的固件不刷噪声日志
if [ -f "$ROOTFS/etc/crowdsec/config.yaml" ] && [ -n "$SEC" ]; then
    _i=0
    while :; do
        local_lapi_state "$BOUNCER_NAME"; _rc=$?
        [ "$_rc" -eq 0 ] && break
        [ "$_rc" -ne 1 ] && break
        [ "$_i" -ge 12 ] && break
        _i=$((_i+1)); sleep 5
    done
    case "$_rc" in
        0)  log "✅ 本地链路健康：bouncer '$BOUNCER_NAME' 正在拉取 decisions（last_pull 5 分钟内）" ;;
        1)  log "⚠️ bouncer '$BOUNCER_NAME' 从未成功 pull（查 api_url / api_key / 容器网络）" ;;
        2)  log "⚠️ bouncer '$BOUNCER_NAME' 超过 5 分钟没 pull，本地链路异常" ;;
        3)  log "⚠️ bouncer '$BOUNCER_NAME' 已被吊销（revoked），api_key 失效" ;;
        *)  log "⚠️ 查不到 bouncer '$BOUNCER_NAME'（cscli inspect 失败，查容器/LAPI 状态）" ;;
    esac
fi

sleep 3
if nft list table ip crowdsec >/dev/null 2>&1; then
    log "✅ nftables crowdsec 表已建立，链路打通"
else
    log "⚠️ 未看到 nft crowdsec 表，检查 bouncer 日志"
fi
log "引导结束"
exit 0
