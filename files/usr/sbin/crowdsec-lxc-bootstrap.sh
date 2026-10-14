#!/bin/sh

LXC_NAME="${LXC_NAME:-ubuntu}"
LXC_PATH="${LXC_PATH:-/srv/lxc}"
ROOTFS="$LXC_PATH/$LXC_NAME/rootfs"
TARBALL="${TARBALL:-/opt/lxc-ubuntu.tar.gz}"
LAPI_PORT="${LAPI_PORT:-8080}"
BOUNCER_NAME="${BOUNCER_NAME:-openwrt-fw}"
if [ -z "${CONTAINER_IP:-}" ] && [ -f /etc/config/custom_container_ip.txt ]; then
    CONTAINER_IP="$(head -n1 /etc/config/custom_container_ip.txt | tr -d ' \t\r\n')"
fi
CONTAINER_IP="${CONTAINER_IP:-10.0.0.10}"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-/srv/lxc/crowdsec-baseline}"
SNAP_ETC="$SNAPSHOT_DIR/etc/crowdsec"
BRIDGE_IP=$(ip -4 addr show lxcbr0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -n1)
CSCLI=/usr/bin/cscli
MAX_WAIT="${MAX_WAIT:-60}"
SLEEP=5

SCRIPT_VER="2026-10-14.4"
log() { echo "[$(date '+%F %T')] $*"; }
log "===== crowdsec-lxc-bootstrap 版本 $SCRIPT_VER 开始执行 ====="

ct() { lxc-attach -P "$LXC_PATH" -n "$LXC_NAME" -- "$@"; }
ct_running() { lxc-ls -P "$LXC_PATH" --running 2>/dev/null | grep -qw "$LXC_NAME"; }

lapi_ready() {
    ct sh -c '
        [ -S /var/lib/crowdsec/data/crowdsec-cli.sock ] && exit 0
        command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":8080" && exit 0
        exit 1
    ' 2>/dev/null
}

_wait_bridge() {
    _i=0
    until ip link show lxcbr0 >/dev/null 2>&1; do
        _i=$((_i+1)); [ $_i -ge $MAX_WAIT ] && return 1; sleep $SLEEP
    done
    return 0
}

_wait_ct_running() {
    _i=0
    until ct_running; do
        _i=$((_i+1)); [ $_i -ge 12 ] && return 1; sleep 5
    done
    return 0
}

_wait_lapi() {
    _i=0
    until lapi_ready; do
        _i=$((_i+1)); [ $_i -ge $MAX_WAIT ] && return 1; sleep $SLEEP
    done
    return 0
}

_wait_ping() {
    _i=0
    until ping -c1 -W2 "$CONTAINER_IP" >/dev/null 2>&1; do
        _i=$((_i+1)); [ $_i -ge $MAX_WAIT ] && return 1; sleep $SLEEP
    done
    return 0
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

snapshot_sync() {
    if [ ! -d "$SNAP_ETC" ]; then
        mkdir -p "$SNAP_ETC" || { log "!! [快照] 创建 $SNAP_ETC 失败，本轮跳过快照"; return 1; }
        log "[快照] 首次创建快照目录 $SNAP_ETC（健康态收集，之后每次开机检查一致性并覆盖）"
    fi
    [ -d "$ROOTFS/etc/crowdsec" ] || return 0

    _snap_changed=0
    {
        ( cd "$ROOTFS/etc/crowdsec" 2>/dev/null && find . -type f -name '*.yaml' 2>/dev/null )
        ( cd "$SNAP_ETC" 2>/dev/null && find . -type f -name '*.yaml' 2>/dev/null )
    } | sed 's|^\./||' | sort -u > /tmp/.cs-snap-list.$$
    while IFS= read -r _rel; do
        [ -n "$_rel" ] || continue
        _ct_f="$ROOTFS/etc/crowdsec/$_rel"
        _sn_f="$SNAP_ETC/$_rel"
        if [ -f "$_ct_f" ] && [ ! -f "$_sn_f" ]; then
            mkdir -p "$(dirname "$_sn_f")"
            if cp -p "$_ct_f" "$_sn_f" 2>/dev/null; then
                log "[快照] 收集: $_rel"; _snap_changed=1
            else
                log "!! [快照] 收集失败: $_rel"
            fi
        elif [ ! -f "$_ct_f" ] && [ -f "$_sn_f" ]; then
            mkdir -p "$(dirname "$_ct_f")"
            if cp -p "$_sn_f" "$_ct_f" 2>/dev/null; then
                log "[快照] 容器缺 $_rel，已从备份补回"; _snap_changed=1
            else
                log "!! [快照] 补回失败: $_rel"
            fi
        elif [ -f "$_ct_f" ] && [ -f "$_sn_f" ]; then
            if cmp -s "$_ct_f" "$_sn_f"; then
                continue
            else
                mkdir -p "$(dirname "$_ct_f")"
                if cp -p "$_sn_f" "$_ct_f" 2>/dev/null; then
                    log "[快照] 与备份不一致，已用备份覆盖: $_rel（要改配置请改 $SNAP_ETC/$_rel）"
                    _snap_changed=1
                else
                    log "!! [快照] 覆盖失败: $_rel"
                fi
            fi
        fi
    done < /tmp/.cs-snap-list.$$
    rm -f /tmp/.cs-snap-list.$$

    if [ "$_snap_changed" -eq 1 ]; then
        _snap_left=0
        {
            ( cd "$ROOTFS/etc/crowdsec" 2>/dev/null && find . -type f -name '*.yaml' 2>/dev/null )
            ( cd "$SNAP_ETC" 2>/dev/null && find . -type f -name '*.yaml' 2>/dev/null )
        } | sed 's|^\./||' | sort -u > /tmp/.cs-snap-verify.$$
        while IFS= read -r _rel; do
            [ -n "$_rel" ] || continue
            cmp -s "$ROOTFS/etc/crowdsec/$_rel" "$SNAP_ETC/$_rel" || _snap_left=1
        done < /tmp/.cs-snap-verify.$$
        rm -f /tmp/.cs-snap-verify.$$
        if [ "$_snap_left" -eq 0 ]; then
            log "[快照] 复验通过：容器配置与快照全部一致"
            if ct_running; then
                log "[快照] 重启 crowdsec 使最新配置生效"
                ct /usr/bin/systemctl restart crowdsec >/dev/null 2>&1 || true
            fi
        else
            log "!! [快照] 复验未过：仍有文件不一致（查 $ROOTFS/etc/crowdsec 权限/空间）"
        fi
    fi
}

snapshot_restore() {
    [ -d "$SNAP_ETC" ] || { log "[快照] 无快照目录，跳过恢复（保持 tarball 出厂态）"; return 0; }
    [ -d "$ROOTFS/etc/crowdsec" ] || { log "!! [快照] rootfs 未解压，无法恢复快照"; return 1; }
    local _rel _sn_f _ct_f _restored=0
    while IFS= read -r _rel; do
        [ -n "$_rel" ] || continue
        _sn_f="$SNAP_ETC/$_rel"
        _ct_f="$ROOTFS/etc/crowdsec/$_rel"
        [ -f "$_sn_f" ] || continue
        mkdir -p "$(dirname "$_ct_f")"
        if cp -p "$_sn_f" "$_ct_f" 2>/dev/null; then
            log "[快照] 恢复: $_rel"; _restored=1
        else
            log "!! [快照] 恢复失败: $_rel"
        fi
    done <<EOF
$(cd "$SNAP_ETC" 2>/dev/null && find . -type f -name '*.yaml' 2>/dev/null | sed 's|^\./||')
EOF
    if [ "$_restored" -eq 1 ]; then
        log "[快照] 已用 $SNAP_ETC 恢复上次运行态配置（含 enroll 凭据，无需重新注册）"
        if ct_running; then
            ct /usr/bin/systemctl restart crowdsec >/dev/null 2>&1 || true
        fi
    fi
    return 0
}

_ensure_bouncer_service() {
    if ! pgrep -x crowdsec-firewall-bouncer >/dev/null 2>&1 || ! nft list table ip crowdsec >/dev/null 2>&1; then
        service crowdsec-firewall-bouncer enable 2>/dev/null
        service crowdsec-firewall-bouncer restart 2>/dev/null
        log "bouncer 已生效"
    fi
}

net_online() {
    ct sh -c '
        if command -v ping >/dev/null 2>&1; then
            ping -c1 -W3 233.5.5.5 >/dev/null 2>&1 || ping -c1 -W3 119.29.29.29 >/dev/null 2>&1 || exit 1
        else
            curl -s -m 8 -o /dev/null https://api.crowdsec.net 2>/dev/null || exit 1
        fi
        exit 0
    ' 2>/dev/null
}

remote_enroll_state() {
    ct sh -c '
        [ -s /etc/crowdsec/online_api_credentials.yaml ] || exit 1
        _out=$(cscli console status 2>&1)
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
    if ! ct $CSCLI machines list >/dev/null 2>&1; then
        log "[步骤2·条件2] LAPI 不可用，重启 crowdsec"
        ct /usr/bin/systemctl restart crowdsec >/dev/null 2>&1 || true
        _wait_lapi \
            && log "[步骤2·条件2] 已修复：LAPI 就绪" \
            || { log "!! [步骤2·条件2] LAPI 仍未监听，本轮放弃"; return 1; }
    fi
    if ! lapi_ready; then
        log "[步骤2·条件4] LAPI 未监听，等待后重启 crowdsec"
        _wait_lapi
        if ! lapi_ready; then
            ct /usr/bin/systemctl restart crowdsec >/dev/null 2>&1 || true
            _wait_lapi
        fi
        lapi_ready \
            && log "[步骤2·条件4] 已修复：LAPI 就绪" \
            || { log "!! [步骤2·条件4] LAPI 仍未监听，本轮放弃"; return 1; }
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

local_lapi_state() {
    local _bip="$2"
    ct sh -c '
        _bn="$1"; _brip="$2"
        _out=$(cscli bouncers inspect "$_bn" -o json 2>/dev/null) || exit 10
        _rv=$(printf "%s\n" "$_out" | sed -n "s/.*\"revoked\"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p")
        _lp=$(printf "%s\n" "$_out" | sed -n "s/.*\"last_pull\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p")
        _ip=$(printf "%s\n" "$_out" | sed -n "s/.*\"ip_address\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p")
        _ip=${_ip%%:*}
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
    if ! ct_running; then
        log "[自检A] 容器未运行，拉起"
        lxc-start -P "$LXC_PATH" -n "$LXC_NAME" -d 2>/dev/null || true
        _wait_ct_running \
            && log "[自愈A] 容器已恢复运行" \
            || log "⚠️ [自愈A] 容器仍未运行（下次开机再试）"
    fi
    if ! lapi_ready; then
        log "[自检B] LAPI 未就绪，重启 crowdsec"
        ct /usr/bin/systemctl restart crowdsec >/dev/null 2>&1 || true
        _wait_lapi \
            && log "[自愈B] LAPI 已恢复" \
            || log "⚠️ [自愈B] LAPI 仍未就绪（下次开机再试）"
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
        log "⚠️ [自检D] collections 为空，尝试 hub update + upgrade"
        ct $CSCLI hub update >/dev/null 2>&1 || true
        ct $CSCLI hub upgrade >/dev/null 2>&1 || true
        _nc=$(ct $CSCLI collections list -o json 2>/dev/null | grep -c '"name"')
        if [ "${_nc:-0}" -gt 0 ] 2>/dev/null; then
            log "[自愈D] collections 已补齐"
        else
            log "⚠️ [自愈D] collections 仍为空（查 hub 索引/网络）"
        fi
    fi
    if nft list table ip crowdsec >/dev/null 2>&1; then
        log "✅ [自检E] nftables crowdsec 表就绪"
    else
        log "⚠️ [自检E] nft crowdsec 表缺失，重启 bouncer 后再查"
        service crowdsec-firewall-bouncer restart 2>/dev/null || true
        sleep 3
        nft list table ip crowdsec >/dev/null 2>&1 \
            && log "[自愈E] nft 表已建立" \
            || log "⚠️ [自愈E] 仍无 nft 表（查 bouncer 日志与 deny_action）"
    fi
}

final_check() {
    local _fc_hb=1
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
            0)  log "✅ 本地链路健康：bouncer '$BOUNCER_NAME' 身份核对通过（来源 IP $BRIDGE_IP）且正在拉取 decisions（last_pull 5 分钟内）"; _fc_hb=0 ;;
            1)  log "⚠️ bouncer '$BOUNCER_NAME' 从未成功 pull（查 api_url / api_key / 容器网络）" ;;
            2)  log "⚠️ bouncer '$BOUNCER_NAME' 超过 5 分钟没 pull，本地链路异常" ;;
            3)  log "⚠️ bouncer '$BOUNCER_NAME' 已被吊销（revoked），api_key 失效" ;;
            4)  log "⚠️ bouncer '$BOUNCER_NAME' 在册但来源 IP 非本机桥接 IP ${BRIDGE_IP:-（探测失败）}，疑似同名遗留/占名，未自动处理（人工：cscli bouncers inspect $BOUNCER_NAME）" ;;
            *)  log "⚠️ 查不到 bouncer '$BOUNCER_NAME'（cscli inspect 失败，查容器/LAPI 状态）" ;;
        esac
    else
        log "⚠️ 未 enroll（无 online_api_credentials.yaml），快照收编条件未满足"
    fi
    [ -d "$ROOTFS/etc/crowdsec" ] || _fc_hb=1
    selfcheck_repair
    [ "$_fc_hb" -eq 0 ] && return 0 || return 1
}

SEC=$(uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
ENROLL_KEY_FILE="/etc/config/crowdsec_enroll_key.txt"
ENROLL_KEY=""
[ -f "$ENROLL_KEY_FILE" ] && ENROLL_KEY="$(head -n1 "$ENROLL_KEY_FILE" | tr -d ' \t\r\n')"
ENROLL_FLAG="$ROOTFS/var/lib/crowdsec/.enrolled"
ENROLL_REASON=1
CFG="$LXC_PATH/$LXC_NAME/config"

if [ -f "$TARBALL" ] || [ -d "$ROOTFS" ]; then
    _s1_ct=0; _s1_lapi=0; _s1_bouncer=0; _s1_protect=0; _s1_pull=0
    log "===== 段一：LXC 创建 → 本地 API → bouncer 注册 → 本地保护 ====="

    if [ -f "$ROOTFS/etc/crowdsec/config.yaml" ]; then
        log "[1/8] rootfs 已就绪（$ROOTFS）"
    elif [ -f "$TARBALL" ]; then
        log "[1/8] 首次解压容器 rootfs（$TARBALL）..."
        if mkdir -p "$ROOTFS" && tar -xzf "$TARBALL" -C "$ROOTFS"; then
            log "[1/8] 解压完成（$(du -sh "$ROOTFS" 2>/dev/null | cut -f1)）"
            snapshot_restore || true
        else
            log "⚠️ [1/8] 解压失败（后续步骤继续尝试）"
        fi
    else
        log "⚠️ [1/8] 无 tarball 且 rootfs 缺失，容器无法创建"
    fi

    if ip link show lxcbr0 >/dev/null 2>&1; then
        log "[2/8] lxcbr0 网桥已就绪"
    else
        log "[2/8] 等待 lxcbr0 网桥（上限 ${MAX_WAIT}×${SLEEP}s）..."
        if _wait_bridge; then
            log "[2/8] lxcbr0 网桥已就绪"
        else
            log "⚠️ [2/8] lxcbr0 未出现（99-custom.sh 的 network.lxc 是否配置生效），后续步骤继续"
        fi
    fi

    mkdir -p "$LXC_PATH/$LXC_NAME"
    write_cfg "$CFG.tmpl"
    if [ ! -f "$CFG" ] || ! cmp -s "$CFG.tmpl" "$CFG"; then
        mv "$CFG.tmpl" "$CFG"
        log "[3/8] 容器 config 已写入/覆盖重写"
        if [ -f "$CFG" ] && ! lxc-info -P "$LXC_PATH" -n "$LXC_NAME" >/dev/null 2>&1; then
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
    else
        rm -f "$CFG.tmpl"
    fi
    if ! lxc-info -P "$LXC_PATH" -n "$LXC_NAME" >/dev/null 2>&1; then
        log "⚠️ [3/8] config 仍无法解析（排查：lxc-info -P $LXC_PATH -n $LXC_NAME），后续步骤继续"
    fi
    if ct_running; then
        log "[3/8] 容器已在运行"
        _s1_ct=1
    else
        log "[3/8] 启动容器 $LXC_NAME..."
        lxc-start -P "$LXC_PATH" -n "$LXC_NAME" -d 2>/dev/null
        if _wait_ct_running; then
            log "[3/8] 容器已启动并运行"
            _s1_ct=1
        else
            log "⚠️ [3/8] 容器未运行（查 lxc-start 报错），后续步骤继续"
        fi
    fi

    if [ "$_s1_ct" = "1" ]; then
        if ! ct /usr/bin/systemctl is-active crowdsec >/dev/null 2>&1; then
            log "[4/8] crowdsec 未 active，重启"
            ct /usr/bin/systemctl restart crowdsec >/dev/null 2>&1 || true
            _i=0
            until ct /usr/bin/systemctl is-active crowdsec >/dev/null 2>&1; do
                _i=$((_i+1)); [ $_i -ge 12 ] && break; sleep 5
            done
        fi
        ct /usr/bin/systemctl is-active crowdsec >/dev/null 2>&1 \
            && log "[4/8] crowdsec 服务 active" \
            || log "⚠️ [4/8] crowdsec 仍未 active，后续步骤继续"
    else
        log "[4/8] 容器未运行，跳过 crowdsec 服务检查"
    fi

    if [ "$_s1_ct" = "1" ]; then
        if ping -c1 -W2 "$CONTAINER_IP" >/dev/null 2>&1; then
            log "[5/8] 容器 IP $CONTAINER_IP 可达"
        elif _wait_ping; then
            log "[5/8] 容器 IP $CONTAINER_IP 可达"
        else
            log "⚠️ [5/8] 容器 IP $CONTAINER_IP 不通（查容器网络/netplan 与网桥），后续步骤继续"
        fi
    else
        log "[5/8] 容器未运行，跳过 IP 探测"
    fi

    if [ "$_s1_ct" = "1" ]; then
        if lapi_ready; then
            log "[6/8] 本地 API（LAPI :$LAPI_PORT）已就绪"
            _s1_lapi=1
        elif _wait_lapi; then
            log "[6/8] 本地 API（LAPI :$LAPI_PORT）已就绪"
            _s1_lapi=1
        else
            log "⚠️ [6/8] LAPI 未就绪（查容器内 crowdsec 服务），后续步骤继续"
        fi
    else
        log "[6/8] 容器未运行，跳过 LAPI 检查"
    fi

    if [ "$_s1_lapi" = "1" ]; then
        if [ -n "$SEC" ] && [ -n "$(uci -q get "$SEC.api_key" 2>/dev/null)" ] \
            && ct $CSCLI bouncers list 2>/dev/null | grep -qw "$BOUNCER_NAME"; then
            _want="http://${CONTAINER_IP}:${LAPI_PORT}/"
            if [ "$(uci -q get "$SEC.api_url" 2>/dev/null)" != "$_want" ]; then
                uci set "$SEC.api_url=$_want"
                uci commit crowdsec
                log "[7/8] bouncer '$BOUNCER_NAME' 已在册，api_url 已校正为 $_want"
            else
                log "[7/8] bouncer '$BOUNCER_NAME' 已在册且 api_url 正确，跳过重新注册"
            fi
            _s1_bouncer=1
        else
            log "[7/8] LAPI 中无 bouncer '$BOUNCER_NAME' 或本地无 key，执行注册"
            ct $CSCLI bouncers delete "$BOUNCER_NAME" >/dev/null 2>&1 || true
            if ct $CSCLI parsers list 2>/dev/null | grep -q 'crowdsecurity/whitelists'; then
                ct $CSCLI parsers remove crowdsecurity/whitelists --force >/dev/null 2>&1 || true
                ct /usr/bin/systemctl restart crowdsec >/dev/null 2>&1 || true
                _wait_lapi || true
            fi
            KEY=$(ct $CSCLI bouncers add "$BOUNCER_NAME" -o raw 2>/dev/null | tr -d '\r\n\t ')
            if [ -n "$KEY" ]; then
                if [ -z "$SEC" ]; then
                    uci add crowdsec bouncer >/dev/null 2>&1
                    SEC=$(uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
                fi
                if [ -n "$SEC" ]; then
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
                    log "[7/8] 已写入本地 api（$SEC），bouncer 注册成功"
                    _s1_bouncer=1
                else
                    log "⚠️ [7/8] 没有 bouncer 段，包可能未打进固件"
                fi
            else
                log "⚠️ [7/8] 生成 bouncer key 失败（查 LAPI 状态）"
            fi
        fi
    else
        log "[7/8] LAPI 未就绪，跳过 bouncer 注册"
    fi

    if [ "$_s1_bouncer" = "1" ]; then
        _ensure_bouncer_service
        if pgrep -x crowdsec-firewall-bouncer >/dev/null 2>&1 && nft list table ip crowdsec >/dev/null 2>&1; then
            log "[8/8] 本地保护已建立（bouncer 运行中 + nftables crowdsec 表就绪）"
            _s1_protect=1
        else
            log "⚠️ [8/8] 本地保护未完全建立（bouncer 进程或 nft 表缺失，重启后再查）"
            service crowdsec-firewall-bouncer restart 2>/dev/null || true
            sleep 3
            if pgrep -x crowdsec-firewall-bouncer >/dev/null 2>&1 && nft list table ip crowdsec >/dev/null 2>&1; then
                log "[8/8] 本地保护已建立（重启后确认）"
                _s1_protect=1
            fi
        fi
    else
        log "[8/8] bouncer 未注册，跳过本地保护检查"
    fi

    if [ "$_s1_protect" = "1" ]; then
        log "----- 验证：bouncers list -----"
        ct $CSCLI bouncers list
        _lp1=$(ct $CSCLI bouncers inspect "$BOUNCER_NAME" -o raw 2>/dev/null | sed -n 's/^[[:space:]]*last_pull:[[:space:]]*//p' | head -n1)
        log "当前 last_pull=$_lp1，等待 12s 复拉验证..."
        sleep 12
        _lp2=$(ct $CSCLI bouncers inspect "$BOUNCER_NAME" -o raw 2>/dev/null | sed -n 's/^[[:space:]]*last_pull:[[:space:]]*//p' | head -n1)
        if [ -n "$_lp1" ] && [ "$_lp1" != "$_lp2" ]; then
            log "----- 验证通过：last_pull 已变动（$_lp1 → $_lp2），bouncer 正在拉取 decisions -----"
            _s1_pull=1
        else
            log "----- 验证告警：last_pull 未变动（$_lp1 → $_lp2），bouncer 拉取异常 -----"
        fi
    else
        log "----- 本地保护未建立，跳过 last_pull 验证 -----"
    fi

    if [ "$_s1_ct" = "1" ] && [ "$_s1_lapi" = "1" ] && [ "$_s1_bouncer" = "1" ] \
        && [ "$_s1_protect" = "1" ] && [ "$_s1_pull" = "1" ]; then
        log "✅ 段一完成：LXC/本地API/bouncer/本地保护/last_pull 全部就绪"
    else
        log "⚠️ 段一未完全通过（ct=$_s1_ct lapi=$_s1_lapi bouncer=$_s1_bouncer protect=$_s1_protect pull=$_s1_pull），不影响已建立的部分"
    fi
else
    log "!! 无 $TARBALL 且无 $ROOTFS，段一无法执行（从 release 下载 tarball 放回 /opt/ 后重启）"
fi

if [ "${_s1_ct:-0}" = "1" ] && [ "${_s1_lapi:-0}" = "1" ] && [ -n "$ENROLL_KEY" ]; then
    log "===== 段二：远程 API（console enroll） ====="
    step2_run || log "⚠️ 段二未完成（本地保护不受影响，下次开机或联网后再试）"
else
    log "===== 段二：跳过（本地未就绪或未填写 enroll key） ====="
fi

if [ "${_s1_ct:-0}" = "1" ] && [ -f "$ROOTFS/etc/crowdsec/config.yaml" ] && [ -n "$SEC" ]; then
    log "===== 段三：健康检查与备份 ====="
    if final_check; then
        snapshot_sync
    else
        log "⚠️ 收尾体检未全部通过，本轮不收集/不覆盖快照（下次开机状态健康后再处理）"
    fi
else
    log "===== 段三：跳过（rootfs 或 bouncer 段缺失） ====="
fi

log "===== 引导结束 ====="
exit 0
