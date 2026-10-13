#!/bin/sh
# =============================================================================
# /usr/sbin/crowdsec-lxc-bootstrap.sh
# 由 /etc/rc.local 后台拉起，每次开机跑一遍，幂等安全。
#
# 结构：每个大步骤只用一个 if——判定条件留在主流程，动作收进各自函数，
#       步骤1 与步骤2 完全分开，互不嵌套，保证阅读性。
#   前置  容器 config 校验（缺失或与模板不一致才 reconcile + 抠不支持键 + 强制 lxc.start.auto）
#         容器整体恢复（没在跑且 rootfs 目录整个缺失 → tarball 解压重建 + 启动复验）
#         出厂配置基线：首启初始化 /srv/lxc/crowdsec-baseline/（用户修改入口），
#         每次开机把白名单配置同步进容器，被改坏自动覆盖回基线（修完复验）
#         容器侧健康验证 + 修复（rootfs/在跑/服务/LAPI，防止步骤1、2 空跑）
#   步骤1 step1_bootstrap()：创建 LXC 容器 + 注册 bouncer —— 本地，不联网
#         前置：本地 api（路由器侧 bouncer 配置）不存在才运行，存在则跳过
#   步骤2 step2_run()：控制台绑定 enroll             —— 远程 api，联网，必须等步骤1 完成
#         前置：ENROLL_KEY 存在才进入 if；内部条件1→6 顺序验证，
#         哪个失败就近修复哪个（修好立即复验），全部就绪才执行 enroll 动作；
#         任一条件最终无法满足则本轮放弃，直接落到收尾；
#         enroll 成功后必须复检通过才写 .enrolled 标记（绝不录入无效数据）
#   收尾  final_check()：本地链路心跳体检 + 文件/链路自检自愈（A文件/B配置文件/C认证/D端到端）+ nft 表
# =============================================================================

LXC_NAME="${LXC_NAME:-ubuntu}"
LXC_PATH="${LXC_PATH:-/srv/lxc}"
ROOTFS="$LXC_PATH/$LXC_NAME/rootfs"
TARBALL="${TARBALL:-/opt/lxc-ubuntu.tar.gz}"
CONTAINER_IP="${CONTAINER_IP:-10.0.0.10}"
LAPI_PORT="${LAPI_PORT:-8080}"
BOUNCER_NAME="${BOUNCER_NAME:-openwrt-fw}"
# 出厂配置基线（随固件 /opt/crowdsec-baseline/ 只读分发，首次开机初始化到可写层）：
#   BASELINE_RO 固件只读层 = 出厂基线，用户改不了
#   BASELINE_RW 可写层     = 首启从 RO 拷贝，之后保留用户改动 = 唯一修改入口
# 开机把 RW 白名单同步进容器 /etc/crowdsec/，配置被改坏自动覆盖回基线。
BASELINE_RO="${BASELINE_RO:-/opt/crowdsec-baseline}"
BASELINE_RW="${BASELINE_RW:-/srv/lxc/crowdsec-baseline}"
# 同步白名单：只收编译期写死的出厂文件。local/online_api_credentials.yaml、
# data/、database.db、用户自建规则是运行时状态或用户资产，一律不碰——
# 覆盖回去会直接搞断 enroll 账号绑定与 bouncer 注册。
BASELINE_FILES="config.yaml profiles.yaml simulations.yaml acquis.d/router.yaml parsers/s01-parse/openwrt-dropbear.yaml parsers/s02-enrich/openwrt-whitelist.yaml"
# 路由器在 lxcbr0 上的 IPv4：心跳体检的身份核对用——LAPI 记录的本机 bouncer
# 来源 IP 应等于它。探测失败留空则跳过核对（绝不因此误杀），不影响其他检查。
BRIDGE_IP=$(ip -4 addr show lxcbr0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -n1)
CSCLI=/usr/bin/cscli
MAX_WAIT="${MAX_WAIT:-60}"
SLEEP=5

SCRIPT_VER="2026-10-13.18"
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

baseline_init() {
    [ -d "$BASELINE_RW" ] && return 0
    if [ ! -d "$BASELINE_RO" ]; then
        log "⚠️ [基线] 固件无 $BASELINE_RO（旧固件或未打包基线），跳过基线功能"
        return 0
    fi
    mkdir -p "$(dirname "$BASELINE_RW")"
    if cp -a "$BASELINE_RO" "$BASELINE_RW"; then
        log "[基线] 已从出厂基线初始化 $BASELINE_RW（用户修改入口：改这里的文件，重启生效）"
    else
        log "!! [基线] 初始化 $BASELINE_RW 失败"
        return 1
    fi
}

baseline_stage() {
    if [ ! -d "$BASELINE_RW/etc/crowdsec" ]; then
        if ! baseline_init; then
            log "!! [基线] 初始化失败，本轮跳过基线同步"
            return 1
        fi
    fi
    [ -d "$BASELINE_RW/etc/crowdsec" ] || return 0
    
    for _bs_f in $BASELINE_FILES; do
        if [ ! -f "$BASELINE_RW/etc/crowdsec/$_bs_f" ]; then
            if [ -f "$BASELINE_RO/etc/crowdsec/$_bs_f" ]; then
                mkdir -p "$(dirname "$BASELINE_RW/etc/crowdsec/$_bs_f")"
                if cp -f "$BASELINE_RO/etc/crowdsec/$_bs_f" "$BASELINE_RW/etc/crowdsec/$_bs_f"; then
                    log "[基线] 可写层缺 $_bs_f，已从出厂基线补回"
                else
                    log "!! [基线] 补回失败: $_bs_f"
                fi
            else
                log "⚠️ [基线] 可写层与出厂基线均缺 $_bs_f，该文件本轮不同步"
            fi
        fi
    done

    if [ -f "$ROOTFS/etc/crowdsec/config.yaml" ]; then
        _bs_changed=0
        for _bs_f in $BASELINE_FILES; do
            [ -f "$BASELINE_RW/etc/crowdsec/$_bs_f" ] || continue
            if ! cmp -s "$BASELINE_RW/etc/crowdsec/$_bs_f" "$ROOTFS/etc/crowdsec/$_bs_f"; then
                mkdir -p "$(dirname "$ROOTFS/etc/crowdsec/$_bs_f")"
                if cp -f "$BASELINE_RW/etc/crowdsec/$_bs_f" "$ROOTFS/etc/crowdsec/$_bs_f"; then
                    log "[基线] 容器配置被改动，已覆盖回基线: $_bs_f"
                    _bs_changed=1
                else
                    log "!! [基线] 覆盖失败: $_bs_f"
                fi
            fi
        done
        
        if [ "$_bs_changed" -eq 1 ]; then
            _bs_left=0
            for _bs_f in $BASELINE_FILES; do
                [ -f "$BASELINE_RW/etc/crowdsec/$_bs_f" ] || continue
                cmp -s "$BASELINE_RW/etc/crowdsec/$_bs_f" "$ROOTFS/etc/crowdsec/$_bs_f" || _bs_left=1
            done
            if [ "$_bs_left" -eq 0 ]; then
                log "[基线] 复验通过：容器配置与基线全部一致"
                if ct_running; then
                    log "[基线] 重启 crowdsec 使基线配置生效"
                    ct /usr/bin/systemctl restart crowdsec >/dev/null 2>&1 || true
                fi
            else
                log "!! [基线] 复验未过：仍有文件与基线不一致（查 $ROOTFS/etc/crowdsec 权限/空间）"
            fi
        fi
    fi
}

container_restore() {
    log "[恢复] 容器不在（$ROOTFS 缺失），开始用 $TARBALL 整体恢复"
    if [ ! -f "$TARBALL" ]; then
        log "!! [恢复] 缺 $TARBALL，无法恢复（从 release 下载放回 /opt/ 后重启）"
        return 1
    fi
    mkdir -p "$ROOTFS"
    if ! tar -xzf "$TARBALL" -C "$ROOTFS"; then
        log "!! [恢复] 解压失败（$TARBALL 损坏？重新下载）"
        return 1
    fi
    log "[恢复] rootfs 已解压（$(du -sh "$ROOTFS" 2>/dev/null | cut -f1)）"
    baseline_stage || true
    if ! ip link show lxcbr0 >/dev/null 2>&1; then
        _cr_i=0
        while [ $_cr_i -lt $MAX_WAIT ]; do
            ip link show lxcbr0 >/dev/null 2>&1 && break
            _cr_i=$((_cr_i+1)); sleep $SLEEP
        done
        if [ $_cr_i -ge $MAX_WAIT ]; then
            log "!! [恢复] lxcbr0 未出现，rootfs 已就绪但未启动（下次开机会继续）"
            return 1
        fi
    fi
    if lxc-start -P "$LXC_PATH" -n "$LXC_NAME" -d 2>/dev/null; then
        log "[恢复] 已发起容器启动"
    else
        log "!! [恢复] lxc-start 失败（config 可能被删，主流程校验重写后会再拉起）"
    fi
    _cr_i=0
    until ct_running; do _cr_i=$((_cr_i+1)); [ $_cr_i -ge 12 ] && break; sleep 5; done
    if ct_running; then
        log "[恢复] 容器已恢复运行"
    else
        log "!! [恢复] 容器仍未运行（precheck/步骤1 会再尝试，收尾自检兜底）"
        return 1
    fi
}

precheck_container() {
    if [ ! -f "$ROOTFS/etc/crowdsec/config.yaml" ]; then
        log "[前置] rootfs 未解压（$ROOTFS），首次开机将由步骤1 解压"
        return 0
    fi
    
    if ! ct_running; then
        log "[前置] 容器未运行，等网桥后拉起"
        i=0
        while [ $i -lt $MAX_WAIT ] && ! ip link show lxcbr0 >/dev/null 2>&1; do
            i=$((i+1)); sleep $SLEEP
        done
        lxc-start -P "$LXC_PATH" -n "$LXC_NAME" -d 2>/dev/null \
            && log "[前置] 已发起容器拉起" \
            || log "!! [前置] 容器拉起命令失败（后续步骤会再尝试）"
        i=0
        until ct_running; do i=$((i+1)); [ $i -ge 12 ] && break; sleep 5; done
        if ct_running; then
            log "[前置] 已修复：容器在跑"
        else
            log "!! [前置] 容器仍未运行（步骤1/2 与收尾自检会再处理）"
            return 1
        fi
    fi
    
    if ! ct /usr/bin/systemctl is-active crowdsec >/dev/null 2>&1; then
        log "[前置] crowdsec 未 active，执行重启"
        ct /usr/bin/systemctl restart crowdsec >/dev/null 2>&1 || true
        i=0
        until ct /usr/bin/systemctl is-active crowdsec >/dev/null 2>&1; do
            i=$((i+1)); [ $i -ge 12 ] && break; sleep 5
        done
        ct /usr/bin/systemctl is-active crowdsec >/dev/null 2>&1 \
            && log "[前置] 已修复：crowdsec active" \
            || log "!! [前置] crowdsec 仍未 active（步骤1/2 与收尾自检会再处理）"
    fi
    
    if ! lapi_ready; then
        log "[前置] LAPI 未监听，等待后重启 crowdsec"
        i=0
        until lapi_ready; do i=$((i+1)); [ $i -ge 6 ] && break; sleep 5; done
        if ! lapi_ready; then
            ct /usr/bin/systemctl restart crowdsec >/dev/null 2>&1 || true
            i=0
            until lapi_ready; do i=$((i+1)); [ $i -ge 12 ] && break; sleep 5; done
        fi
        lapi_ready \
            && log "[前置] 已修复：LAPI 就绪" \
            || log "!! [前置] LAPI 仍未监听（步骤1/2 与收尾自检会再处理）"
    fi
}

SEC=$(uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
ENROLL_KEY_FILE="/etc/config/crowdsec_enroll_key.txt"
ENROLL_KEY=""
[ -f "$ENROLL_KEY_FILE" ] && ENROLL_KEY="$(head -n1 "$ENROLL_KEY_FILE" | tr -d ' \t\r\n')"
ENROLL_FLAG="$ROOTFS/var/lib/crowdsec/.enrolled"
ENROLL_REASON=1

if ! ct_running && [ ! -d "$ROOTFS" ]; then
    container_restore || log "!! 容器恢复未完成（后续步骤与收尾自检继续兜底）"
fi

CFG="$LXC_PATH/$LXC_NAME/config"
mkdir -p "$LXC_PATH/$LXC_NAME"
_TMPL="$CFG.tmpl"
write_cfg "$_TMPL"

if [ ! -f "$CFG" ] || ! cmp -s "$_TMPL" "$CFG"; then
    if [ ! -f "$CFG" ]; then
        mv "$_TMPL" "$CFG"; log "已写入容器 config"
    else
        mv "$_TMPL" "$CFG"
        log "config 不一致，已直接覆盖重写"
    fi

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
        
        if ! lxc-info -P "$LXC_PATH" -n "$LXC_NAME" >/dev/null 2>&1; then
            write_cfg
        fi
    fi
fi

if ! lxc-info -P "$LXC_PATH" -n "$LXC_NAME" >/dev/null 2>&1; then
    log "!! config 仍无法解析，放弃（排查：lxc-info -P $LXC_PATH -n $LXC_NAME）"; exit 1
fi

if [ -f "$CFG" ]; then
    baseline_stage
    precheck_container
fi

step1_bootstrap() {
    local i KEY

    if [ ! -f "$ROOTFS/etc/crowdsec/config.yaml" ]; then
        [ -f "$TARBALL" ] || { log "!! 缺少 $TARBALL，放弃引导"; return 1; }
        log "解压容器 rootfs..."
        mkdir -p "$ROOTFS"
        tar -xzf "$TARBALL" -C "$ROOTFS" || { log "!! 解压失败"; return 1; }
        log "解压完成"

        baseline_stage || true
    fi

    if ! ip link show lxcbr0 >/dev/null 2>&1; then
        i=0
        while [ $i -lt $MAX_WAIT ]; do
            ip link show lxcbr0 >/dev/null 2>&1 && break
            i=$((i+1)); sleep $SLEEP
        done
        [ $i -lt $MAX_WAIT ] || { log "!! lxcbr0 未出现，放弃"; return 1; }
    fi
    if ! ct_running; then
        log "启动容器 $LXC_NAME"
        lxc-start -P "$LXC_PATH" -n "$LXC_NAME" -d
        sleep 5
    fi

    if ! ping -c1 -W2 "$CONTAINER_IP" >/dev/null 2>&1; then
        i=0
        while [ $i -lt $MAX_WAIT ]; do
            ping -c1 -W2 "$CONTAINER_IP" >/dev/null 2>&1 && break
            i=$((i+1)); sleep $SLEEP
        done
        [ $i -lt $MAX_WAIT ] || { log "!! 容器 IP $CONTAINER_IP 不通，放弃"; return 1; }
    fi

    if ! lapi_ready; then
        i=0
        until lapi_ready; do
            i=$((i+1))
            [ $i -ge $MAX_WAIT ] && { log "!! LAPI 未就绪，放弃"; return 1; }
            sleep $SLEEP
        done
    fi

    ct $CSCLI bouncers delete "$BOUNCER_NAME" >/dev/null 2>&1 || true

    if ct $CSCLI parsers list 2>/dev/null | grep -q 'crowdsecurity/whitelists'; then
        ct $CSCLI parsers remove crowdsecurity/whitelists --force >/dev/null 2>&1 || true
        ct /usr/bin/systemctl restart crowdsec >/dev/null 2>&1 || true
        i=0
        until lapi_ready; do
            i=$((i+1)); [ $i -ge $MAX_WAIT ] && break; sleep $SLEEP
        done
    fi
    KEY=$(ct $CSCLI bouncers add "$BOUNCER_NAME" -o raw 2>/dev/null | tr -d '\r\n\t ')
    if [ -z "$KEY" ]; then log "!! 生成 bouncer key 失败"; return 1; fi
    if [ -z "$SEC" ]; then
        uci add crowdsec bouncer >/dev/null 2>&1
        SEC=$(uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
    fi
    if [ -z "$SEC" ]; then log "!! 没有 bouncer 段，包可能未打进固件"; return 1; fi
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
}

if [ -z "$SEC" ] || [ -z "$(uci -q get "$SEC.api_key" 2>/dev/null)" ]; then
    log "本地 api 未建立，进入步骤1"
    step1_bootstrap || { log "!! 步骤1 未完成，放弃后续引导"; exit 1; }
fi

net_online() {
    ct sh -c '
        if command -v ping >/dev/null 2>&1; then
            ping -c1 -W3 233.5.5.5 >/dev/null 2>&1 || ping -c1 -W3 119.29.29.29 >/dev/null 2>&1 || exit 1
        else
            # 容器没装 ping：退化成 curl 探 console API，收到任何 HTTP 响应即算通
            curl -s -m 8 -o /dev/null https://api.crowdsec.net 2>/dev/null || exit 1
        fi
        exit 0
    ' 2>/dev/null
}

remote_enroll_state() {
    ct sh -c '
        [ -s /etc/crowdsec/online_api_credentials.yaml ] || exit 1
        _out=$(cscli console status 2>&1)
        # 字段级对照 + 关键词兜底，自上而下第一个命中生效（顺序即优先级）：
        #   空输出                            → exit 5 执行失败（绝不把故障当 healthy）
        #   not registered/not enrolled/被拒词 → exit 2 需重连
        #     （"Error: not enrolled" 归此类而非执行失败：重连才是正确响应）
        #   Registered 字段明确 false/no      → exit 2 双保险（有的版本不打关键词只打字段）
        #   执行失败关键词                     → exit 5
        #   其余                              → exit 0 有效
        [ -z "$_out" ] && exit 5
        printf "%s\n" "$_out" | grep -qiE "not registered|not enrolled|unauthorized|forbidden|not authorized|invalid|revoked|401|403" && exit 2
        printf "%s\n" "$_out" | grep -iE "registered[[:space:]]*:[[:space:]]*(false|no)\b" && exit 2
        printf "%s\n" "$_out" | grep -qiE "failed to|connection refused|cannot|unable|no such file|error" && exit 5
        exit 0
    ' 2>/dev/null
}

enroll_recheck() {
    local _rv=5 _t=0
    while [ $_t -lt 6 ]; do
        _t=$((_t+1))
        lapi_ready || sleep 5
        remote_enroll_state; _rv=$?
        [ "$_rv" -ne 5 ] && break
        sleep 5
    done
    return $_rv
}

rollback_cred() {
    [ -n "$_CRED_BAK" ] && [ -f "$_CRED_BAK" ] || return 0
    mv -f "$_CRED_BAK" "$ROOTFS/etc/crowdsec/online_api_credentials.yaml"
    log "已回滚旧凭据（cscli bouncers 等本地功能不受影响）"
}

step2_run() {
    local _i _re
    if ! ct_running; then
        log "[步骤2·条件1] 容器未运行，尝试拉起"
        lxc-start -P "$LXC_PATH" -n "$LXC_NAME" -d 2>/dev/null || true
        _i=0
        until ct_running; do _i=$((_i+1)); [ $_i -ge 12 ] && break; sleep 5; done
        if ct_running; then
            log "[步骤2·条件1] 已修复：容器已拉起"
        else
            log "!! [步骤2·条件1] 容器拉不起来，本轮放弃步骤2（收尾自检会再兜底）"
            return 1
        fi
    fi
  
    if [ -z "$ENROLL_KEY" ]; then
        log "!! [步骤2·条件2] 无 enroll 密钥，本轮放弃（去 app.crowdsec.net 生成，更新 $ENROLL_KEY_FILE）"
        return 1
    fi
   
    if ! ct /usr/bin/systemctl is-active crowdsec >/dev/null 2>&1; then
        log "[步骤2·条件3] crowdsec 未 active，执行重启"
        ct /usr/bin/systemctl restart crowdsec >/dev/null 2>&1 || true
        _i=0
        until ct /usr/bin/systemctl is-active crowdsec >/dev/null 2>&1; do
            _i=$((_i+1)); [ $_i -ge 12 ] && break; sleep 5
        done
        if ct /usr/bin/systemctl is-active crowdsec >/dev/null 2>&1; then
            log "[步骤2·条件3] 已修复：crowdsec active"
        else
            log "!! [步骤2·条件3] crowdsec 重启后仍未 active，本轮放弃（容器内 journalctl -u crowdsec -n 50）"
            return 1
        fi
    fi
    
    if ! lapi_ready; then
        log "[步骤2·条件4] LAPI 未监听，等待后重启 crowdsec"
        _i=0
        until lapi_ready; do _i=$((_i+1)); [ $_i -ge 6 ] && break; sleep 5; done
        if ! lapi_ready; then
            ct /usr/bin/systemctl restart crowdsec >/dev/null 2>&1 || true
            _i=0
            until lapi_ready; do _i=$((_i+1)); [ $_i -ge 12 ] && break; sleep 5; done
        fi
        if lapi_ready; then
            log "[步骤2·条件4] 已修复：LAPI 就绪"
        else
            log "!! [步骤2·条件4] LAPI 仍未监听，本轮放弃"
            return 1
        fi
    fi
  
    if ! net_online; then
        log "[步骤2·条件5] 外网不通，凭据不动，本轮不判（下次开机再判）"
        return 1
    fi
    
    remote_enroll_state; _re=$?
    if [ "$_re" -eq 0 ]; then
        log "[步骤2·条件6] 远程 api 已绑定且有效，无需 enroll"
        return 0
    elif [ "$_re" -eq 5 ]; then
        log "!! [步骤2·条件6] console status 执行失败（cscli 异常），本轮放弃"
        return 1
    fi
    _ENROLL_REASON=$_re    
    
    step2_enroll
}

step2_enroll() {
    local _CRED_BAK=""
    if [ "$_ENROLL_REASON" -eq 2 ]; then
        log "远程 api 已失效（网页端删除/密钥被撤），备份旧凭据后重连"
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
        if enroll_recheck; then
            mkdir -p "$ROOTFS/var/lib/crowdsec"
            : > "$ENROLL_FLAG"
            [ -n "$_CRED_BAK" ] && rm -f "$_CRED_BAK"
            log "控制台绑定完成（复检确认）—— 记得回 app.crowdsec.net 点 Accept"
        else
            rollback_cred
            log "!! enroll 后复检未通过（状态 $?），已回滚旧凭据、未写 .enrolled 标记"
        fi
    else
        rollback_cred
        log "!! enroll 失败（enroll key 为一次性；去 app.crowdsec.net 重新生成，更新 /etc/config/crowdsec_enroll_key.txt）"
    fi
}

if [ -n "$ENROLL_KEY" ]; then
    step2_run
else
    log "未提供 enroll 密钥，跳过"
fi

local_lapi_state() {
    ct sh -c '
        _bn="$1"; _brip="$2"
        _out=$(cscli bouncers inspect "$_bn" -o json 2>/dev/null) || exit 10
        _rv=$(printf "%s\n" "$_out" | sed -n "s/.*\"revoked\"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p")
        _lp=$(printf "%s\n" "$_out" | sed -n "s/.*\"last_pull\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p")
        _ip=$(printf "%s\n" "$_out" | sed -n "s/.*\"ip_address\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p")
        _ip=${_ip%%:*}    # 去掉可能的 :port，只留 IPv4
        # 身份核对：来源 IP 必须是路由器桥接 IP（两端都有值才比对）
        if [ -n "$_brip" ] && [ -n "$_ip" ] && [ "$_ip" != "$_brip" ]; then exit 4; fi
        [ "$_rv" = "true" ] && exit 3
        [ -z "$_lp" ] && exit 1
        _now=$(date +%s)
        _ts=$(date -d "$_lp" +%s 2>/dev/null || echo 0)
        [ $((_now - _ts)) -gt 300 ] && exit 2
        exit 0
    ' _ "$1" "$2"
}

selfcheck_repair() {
    local _i _nk _nc _f

    if [ ! -d "$ROOTFS/etc/crowdsec" ]; then
        log "!! [自检A] $ROOTFS/etc/crowdsec 不存在（rootfs 未解压或损坏，重打镜像）"
    else
        for _f in crowdsec.yaml config.yaml; do
            [ -f "$ROOTFS/etc/crowdsec/$_f" ] || \
                log "!! [自检A] 缺 $ROOTFS/etc/crowdsec/$_f（重新解压 $TARBALL 或重打镜像）"
        done
        [ -f "$ROOTFS/etc/crowdsec/local_api_credentials.yaml" ] || \
            log "!! [自检A] 缺 local_api_credentials.yaml（前置阶段会尝试重启 crowdsec 自动重建）"
        if [ -f "$ENROLL_FLAG" ] && [ ! -s "$ROOTFS/etc/crowdsec/online_api_credentials.yaml" ]; then
            log "!! [自检A] .enrolled 标记在但 online_api_credentials.yaml 缺失/为空，清标记等下次重连"
            rm -f "$ENROLL_FLAG"
        fi
    fi
    [ -s "$ENROLL_KEY_FILE" ] || \
        log "⚠️ [自检A] 无 enroll 密钥 $ENROLL_KEY_FILE（网页端删 API 后将无法自动重连）"

    if ! ct_running; then
        log "!! [自检B] 容器未运行，跳过容器内自检"
    else
        for _f in config.yaml crowdsec.yaml; do
            ct sh -c "[ -f /etc/crowdsec/$_f ]" 2>/dev/null || \
                log "!! [自检B] 容器内缺 /etc/crowdsec/$_f"
        done

        if ! ct sh -c '[ -s /etc/crowdsec/online_api_credentials.yaml ]' 2>/dev/null; then
            log "⚠️ [自检C] 容器缺 online_api_credentials.yaml，跳过 cscli 链路检查"
        else
            if ! ct $CSCLI machines list >/dev/null 2>&1; then
                log "!! [自检C] cscli 加载本地凭据失败，重启 crowdsec 重建 local_api_credentials.yaml"
                ct /usr/bin/systemctl restart crowdsec >/dev/null 2>&1 || true
                _i=0
                until ct $CSCLI machines list >/dev/null 2>&1; do
                    _i=$((_i+1)); [ $_i -ge 12 ] && break; sleep 5
                done
                ct $CSCLI machines list >/dev/null 2>&1 \
                    && log "[自愈C] 本地凭据已恢复" \
                    || log "!! [自愈C] cscli 仍无法加载本地凭据"
            fi
            if ! ct $CSCLI bouncers list 2>/dev/null | grep -qw "$BOUNCER_NAME"; then
                log "!! [自检C] LAPI 中无 bouncer '$BOUNCER_NAME'，重新注册"
                ct $CSCLI bouncers delete "$BOUNCER_NAME" >/dev/null 2>&1 || true
                _nk=$(ct $CSCLI bouncers add "$BOUNCER_NAME" -o raw 2>/dev/null | tr -d '\r\n\t ')
                if [ -n "$_nk" ] && [ -n "$SEC" ]; then
                    uci set "$SEC.api_key=$_nk"
                    uci set "$SEC.api_url=http://${CONTAINER_IP}:${LAPI_PORT}/"
                    uci commit crowdsec
                    service crowdsec-firewall-bouncer restart 2>/dev/null || true
                    log "[自愈C] bouncer 已重新注册，api_key 同步 uci 并重启 bouncer"
                else
                    log "!! [自愈C] bouncer add 失败或无 bouncer 段，api_key 未同步"
                fi
            fi
            _nc=$(ct $CSCLI collections list -o json 2>/dev/null | grep -c '"name"')
            if [ "${_nc:-0}" -eq 0 ] 2>/dev/null; then
                log "⚠️ [自检C] collections 为空，尝试 hub update + upgrade"
                ct $CSCLI hub update >/dev/null 2>&1 || true
                ct $CSCLI hub upgrade >/dev/null 2>&1 || true
                _nc=$(ct $CSCLI collections list -o json 2>/dev/null | grep -c '"name"')
                if [ "${_nc:-0}" -gt 0 ] 2>/dev/null; then
                    log "[自愈C] collections 已恢复（${_nc} 个）"
                else
                    log "⚠️ [自愈C] collections 仍为空（查容器网络 / hub index）"
                fi
            fi
        fi
    fi

    if ! pgrep -x crowdsec-firewall-bouncer >/dev/null 2>&1; then
        log "!! [自检D] crowdsec-firewall-bouncer 进程不在，enable + restart"
        service crowdsec-firewall-bouncer enable 2>/dev/null || true
        service crowdsec-firewall-bouncer restart 2>/dev/null || true
        sleep 3
        if pgrep -x crowdsec-firewall-bouncer >/dev/null 2>&1; then
            log "[自愈D] bouncer 进程已恢复"
        else
            log "!! [自愈D] bouncer 进程仍未起来（logread -e firewall-bouncer）"
        fi
    fi
    if nft list table ip crowdsec >/dev/null 2>&1; then
        log "✅ [自检D] nftables crowdsec 表就绪"
    else
        log "⚠️ [自检D] nft crowdsec 表缺失，重启 bouncer 后再查"
        service crowdsec-firewall-bouncer restart 2>/dev/null || true
        sleep 3
        nft list table ip crowdsec >/dev/null 2>&1 \
            && log "[自愈D] nft crowdsec 表已建立" \
            || log "⚠️ [自愈D] 仍无 nft 表（查 bouncer 日志与 deny_action）"
    fi
}

final_check() {
    if [ -s "$ROOTFS/etc/crowdsec/online_api_credentials.yaml" ]; then
        local _i=0 _rc
        while :; do
            local_lapi_state "$BOUNCER_NAME" "$BRIDGE_IP"; _rc=$?
            [ "$_rc" -eq 0 ] && break
            [ "$_rc" -ne 1 ] && break
            [ "$_i" -ge 12 ] && break
            _i=$((_i+1)); sleep 5
        done
        case "$_rc" in
            0)  log "✅ 本地链路健康：bouncer '$BOUNCER_NAME' 身份核对通过（来源 IP $BRIDGE_IP）且正在拉取 decisions（last_pull 5 分钟内）" ;;
            1)  log "⚠️ bouncer '$BOUNCER_NAME' 从未成功 pull（查 api_url / api_key / 容器网络）" ;;
            2)  log "⚠️ bouncer '$BOUNCER_NAME' 超过 5 分钟没 pull，本地链路异常" ;;
            3)  log "⚠️ bouncer '$BOUNCER_NAME' 已被吊销（revoked），api_key 失效" ;;
            4)  log "⚠️ bouncer '$BOUNCER_NAME' 在册但来源 IP 非本机桥接 IP ${BRIDGE_IP:-（探测失败）}，疑似同名遗留/占名，未自动处理（人工：cscli bouncers inspect $BOUNCER_NAME）" ;;
            *)  log "⚠️ 查不到 bouncer '$BOUNCER_NAME'（cscli inspect 失败，查容器/LAPI 状态）" ;;
        esac
    fi
    selfcheck_repair
}

if [ -f "$ROOTFS/etc/crowdsec/config.yaml" ] && [ -n "$SEC" ]; then
    final_check
else
    log "rootfs 或 bouncer 段缺失，跳过 CrowdSec 自检"
fi

sleep 3
log "引导结束"
exit 0
