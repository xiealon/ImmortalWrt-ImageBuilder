#!/bin/sh
# CrowdSec LXC 开机引导：步骤1 建容器+crowdsec跑通+本地API；步骤2 远程enroll；步骤3 备份
SCRIPT_VER="2026-10-14.8"

LXC_NAME="${LXC_NAME:-ubuntu}"
CS_HOME="${CS_HOME:-/etc/crowdsec}"
LXC_PATH="${LXC_PATH:-/srv/lxc}"
ROOTFS="$LXC_PATH/$LXC_NAME/rootfs"
CFG="$LXC_PATH/$LXC_NAME/config"
TARBALL="${TARBALL:-$CS_HOME/lxc-ubuntu.tar.gz}"
LEGACY_TARBALL="/opt/lxc-ubuntu.tar.gz"
BASELINE="$CS_HOME/baseline"
SNAP_ETC="$BASELINE/etc/crowdsec"
STATE_FILE="$BASELINE/STATE"
LAPI_PORT="${LAPI_PORT:-8080}"
BOUNCER_NAME="${BOUNCER_NAME:-openwrt-fw}"
ENROLL_KEY_FILE="${ENROLL_KEY_FILE:-/etc/config/crowdsec_enroll_key.txt}"
ENROLL_USED_FILE="$CS_HOME/enroll.used"
MAX_WAIT="${MAX_WAIT:-60}"
SLEEP=5
CROWDSEC_CFG="$ROOTFS/etc/crowdsec/config.yaml"
CSCLI=/usr/bin/cscli

if [ -z "${CONTAINER_IP:-}" ] && [ -f /etc/config/custom_container_ip.txt ]; then
    CONTAINER_IP="$(head -n1 /etc/config/custom_container_ip.txt | tr -d ' \t\r\n')"
fi
CONTAINER_IP="${CONTAINER_IP:-10.0.0.10}"
BRIDGE_IP=$(ip -4 addr show lxcbr0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -n1)

log() { echo "[$(date '+%F %T')] $*"; }

# 权限自愈：脚本在固件里是 644，直接执行场景再补一次
case "$0" in
    /*) _SELF="$_0" ;;
    */*) _SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")" ;;
    *) _SELF="$(command -v "$0" 2>/dev/null)" ;;
esac
[ -n "$_SELF" ] && chmod +x "$_SELF" 2>/dev/null
chmod +x /etc/rc.local 2>/dev/null

log "===== crowdsec-lxc-bootstrap v$SCRIPT_VER 开始（容器 $LXC_NAME）====="

# ---------- 工具 ----------
ct() { lxc-attach -P "$LXC_PATH" -n "$LXC_NAME" -- "$@"; }
ct_running() { lxc-ls -P "$LXC_PATH" --running 2>/dev/null | grep -qw "$LXC_NAME"; }
ct_exists() { lxc-info -P "$LXC_PATH" -n "$LXC_NAME" >/dev/null 2>&1; }
# bouncer 进程名 26 字符超过 comm 上限 15，必须用 -f
_pgrep_bouncer() { pgrep -f "crowdsec-firewall-bouncer" >/dev/null 2>&1; }
_ct_env() { ct sh -c 'export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; '"$1"; }

lapi_ready() {
    _ct_env '[ -S /var/lib/crowdsec/data/crowdsec-cli.sock ] && exit 0
              [ -x /usr/bin/ss ] && ss -ltn 2>/dev/null | grep -q ":'"$LAPI_PORT"'" && exit 0
              exit 1' 2>/dev/null
}
ct_crowdsec_active() {
    _ct_env '[ -x /bin/systemctl ] && systemctl is-active crowdsec >/dev/null 2>&1 && exit 0
              pgrep -x crowdsec >/dev/null 2>&1 && exit 0
              exit 1' 2>/dev/null
}
cs_active_on_host() { _pgrep_bouncer; }
nft_table_ready() { nft list table ip crowdsec >/dev/null 2>&1; }

_wait() {
    _wd="$1"; _wf="$2"; _wn="${3:-$MAX_WAIT}"
    _wi=0
    until "$_wf"; do
        _wi=$((_wi+1))
        [ "$_wi" -ge "$_wn" ] && return 1
        sleep $SLEEP
    done
    return 0
}
_wait_ct_running() { _wait "容器" ct_running 12; }
_wait_lapi()       { _wait "LAPI" lapi_ready; }
_wait_ping()  { _wp() { ping -c1 -W2 "$CONTAINER_IP" >/dev/null 2>&1; }; _wait "容器IP" _wp; }
_wait_bridge() { _wb() { ip link show lxcbr0 >/dev/null 2>&1; }; _wait "网桥" _wb; }

net_online() {
    _ct_env '[ -x /bin/ping ] && { ping -c1 -W3 233.5.5.5 >/dev/null 2>&1 || ping -c1 -W3 119.29.29.29 >/dev/null 2>&1; } && exit 0
              [ -x /usr/bin/curl ] && curl -s -m 8 -o /dev/null https://api.crowdsec.net 2>/dev/null && exit 0
              exit 1' 2>/dev/null
}

# ---------- 写盘 / 重建 ----------
write_cfg() {
    _dst="${1:-$CFG}"
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

# 写 config 并逐条剔除当前 LXC 版本不支持的键
apply_cfg() {
    write_cfg "$CFG.tmp0"
    if [ -f "$CFG" ] && [ ! -f /usr/share/lxc/config/common.conf ]; then
        grep -v '^[[:space:]]*lxc.include' "$CFG.tmp0" > "$CFG" 2>/dev/null \
            && rm -f "$CFG.tmp0" || { rm -f "$CFG.tmp0"; return 1; }
    else
        mv -f "$CFG.tmp0" "$CFG" 2>/dev/null || return 1
    fi
    _trim=0
    while [ "$_trim" -lt 20 ]; do
        _err=$(lxc-info -P "$LXC_PATH" -n "$LXC_NAME" 2>&1) && return 0
        _bad=$(printf '%s\n' "$_err" | sed -n 's/.*at line "\([^"]*\)".*/\1/p' | head -n1)
        [ -n "$_bad" ] || break
        grep -v -F "$_bad" "$CFG" > "$CFG.tmp1" 2>/dev/null && mv -f "$CFG.tmp1" "$CFG" || break
        _trim=$((_trim+1))
    done
    ct_exists
}

# rootfs 与 baseline 快照比对，不一致用备份覆盖；返回 0=一致/已恢复
sync_from_baseline() {
    [ -d "$SNAP_ETC" ] || { log "[步骤1] 无 baseline 快照，跳过一致性覆盖"; return 2; }
    [ -d "$ROOTFS/etc/crowdsec" ] || { log "[步骤1] rootfs 未就绪，无法比对"; return 1; }

    _sb_changed=0
    _sb_list=/tmp/.cs-base-list.$$
    { ( cd "$SNAP_ETC" 2>/dev/null && find . -type f -name '*.yaml' 2>/dev/null )
      ( cd "$ROOTFS/etc/crowdsec" 2>/dev/null && find . -type f -name '*.yaml' 2>/dev/null )
    } | sed 's|^\./||' | sort -u > "$_sb_list"

    while IFS= read -r _rel; do
        [ -n "$_rel" ] || continue
        case "$_rel" in *whitelists*) continue ;; esac
        _sn_f="$SNAP_ETC/$_rel"
        _ct_f="$ROOTFS/etc/crowdsec/$_rel"
        if [ -f "$_sn_f" ] && [ ! -f "$_ct_f" ]; then
            mkdir -p "$(dirname "$_ct_f")"
            cp -p "$_sn_f" "$_ct_f" 2>/dev/null \
                && { log "[步骤1] 补回缺失配置: $_rel"; _sb_changed=1; } \
                || log "[步骤1] !! 补回失败: $_rel"
        elif [ -f "$_ct_f" ] && [ -f "$_sn_f" ]; then
            cmp -s "$_ct_f" "$_sn_f" && continue
            mkdir -p "$(dirname "$_ct_f")"
            cp -p "$_sn_f" "$_ct_f" 2>/dev/null \
                && { log "[步骤1] 配置与备份不一致，已覆盖: $_rel"; _sb_changed=1; } \
                || log "[步骤1] !! 覆盖失败: $_rel"
        fi
    done < "$_sb_list"
    rm -f "$_sb_list"
    return "$_sb_changed"
}

rebuild_from_image() {
    log "[步骤1] 尝试从镜像重建 rootfs：$TARBALL"
    [ -f "$TARBALL" ] || { log "[步骤1] !! 镜像文件不存在，无法重建"; return 1; }
    ct_running && lxc-stop -P "$LXC_PATH" -n "$LXC_NAME" -k -f >/dev/null 2>&1
    sleep 2
    rm -rf "$ROOTFS" 2>/dev/null
    mkdir -p "$ROOTFS" || return 1
    # 解压锁：并发实例只有一个真正解 tar
    if ( set -C; : > "$ROOTFS/.extracting" ) 2>/dev/null; then
        if tar -xzf "$TARBALL" -C "$ROOTFS"; then
            rm -f "$ROOTFS/.extracting"
            log "[步骤1] 重建完成（$(du -sh "$ROOTFS" 2>/dev/null | cut -f1)）"
            return 0
        fi
        rm -f "$ROOTFS/.extracting"
        log "[步骤1] !! 解压失败"
        return 1
    fi
    log "[步骤1] 另一实例正在解压，等待完成"
    _i=0
    while [ -f "$ROOTFS/.extracting" ]; do
        _i=$((_i+1)); [ "$_i" -ge $MAX_WAIT ] && break; sleep $SLEEP
    done
    [ -f "$CROWDSEC_CFG" ]
}

# 在 trusted_ips 列表里补「- <ip>」，缩进跟随已有列表项
_cs_append_trusted_ip() {
    _tip="${1:-$ST_BRIDGE_IP}"
    _tf="$CROWDSEC_CFG"
    [ -f "$_tf" ] || return 1
    awk -v tip="$_tip" '
        BEGIN { in_ti=0; ti_indent=0; indent="      " }
        /^[[:space:]]*trusted_ips:/ { match($0, /^[[:space:]]*/); ti_indent=RLENGTH; in_ti=1; print; next }
        in_ti && /^[[:space:]]*-[[:space:]]/ { match($0, /^[[:space:]]*/); indent=substr($0, 1, RLENGTH); print; next }
        in_ti && /^[[:space:]]*#/ { match($0, /^[[:space:]]*/); if (RLENGTH <= ti_indent) { print indent "- " tip; in_ti=0 } print; next }
        in_ti && /^[[:space:]]*$/ { print; next }
        in_ti { print indent "- " tip; in_ti=0; print; next }
        { print }
        END { if (in_ti) print indent "- " tip }
    ' "$_tf" > "$_tf.tmp" && mv "$_tf.tmp" "$_tf" || return 1
    grep -qE "^[[:space:]]*-[[:space:]]*$_tip([[:space:]]|$)" "$_tf"
}

_ensure_bouncer_service() {
    if cs_active_on_host && nft_table_ready; then
        return 0
    fi
    service crowdsec-firewall-bouncer enable 2>/dev/null
    service crowdsec-firewall-bouncer restart 2>/dev/null
    sleep 3
    if cs_active_on_host && nft_table_ready; then
        log "[bouncer] 已生效"
    else
        log "[bouncer] ⚠️ 重启后仍未就绪（查 /etc/init.d/crowdsec-firewall-bouncer）"
    fi
    return 0
}

# ---------- 状态采集（一次性收集，各步骤只读自己关心的） ----------
collect_state() {
    log "----- 阶段 0：状态采集 -----"

    if [ ! -f "$TARBALL" ] && [ -f "$LEGACY_TARBALL" ]; then
        if mkdir -p "$CS_HOME" 2>/dev/null && mv -f "$LEGACY_TARBALL" "$TARBALL" 2>/dev/null; then
            log "[采集] 镜像已从 $LEGACY_TARBALL 迁移到 $TARBALL"
        else
            log "[采集] 旧镜像迁移失败，仍按 $TARBALL 判定"
        fi
    fi

    ST_IMAGE=0;    [ -f "$TARBALL" ] && ST_IMAGE=1
    ST_ROOTFS=0;   [ -f "$CROWDSEC_CFG" ] && ST_ROOTFS=1
    ST_CFG_OK=0;   ct_exists && ST_CFG_OK=1
    ST_BASE=0;     [ -d "$SNAP_ETC" ] && ST_BASE=1
    ST_STATE=0;    [ -f "$STATE_FILE" ] && ST_STATE=1
    ST_CROWDSECCFG=0; [ -f /etc/config/crowdsec ] && ST_CROWDSECCFG=1

    ST_BRIDGE_OK=0; ip link show lxcbr0 >/dev/null 2>&1 && ST_BRIDGE_OK=1
    ST_BRIDGE_IP="$BRIDGE_IP"
    ST_CT_RUNNING=0; ct_running && ST_CT_RUNNING=1
    ST_CT_IP="$CONTAINER_IP"

    ST_SEC=$(uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
    ST_UCI_KEY="";  [ -n "$ST_SEC" ] && ST_UCI_KEY="$(uci -q get "$ST_SEC.api_key" 2>/dev/null)"
    ST_UCI_URL="";  [ -n "$ST_SEC" ] && ST_UCI_URL="$(uci -q get "$ST_SEC.api_url" 2>/dev/null)"
    ST_API_URL_WANT="http://${CONTAINER_IP}:${LAPI_PORT}/"

    ST_ENROLL_KEY=""
    [ -f "$ENROLL_KEY_FILE" ] && ST_ENROLL_KEY="$(head -n1 "$ENROLL_KEY_FILE" | tr -d ' \t\r\n')"
    ST_ENROLL_CRED=0; [ -s "$ROOTFS/etc/crowdsec/online_api_credentials.yaml" ] && ST_ENROLL_CRED=1

    log "[采集] 镜像=$ST_IMAGE rootfs=$ST_ROOTFS config=$ST_CFG_OK baseline=$ST_BASE 标记=$ST_STATE"
    log "[采集] bouncer段=${ST_SEC:-无} 本地key=${ST_UCI_KEY:+已填}${ST_UCI_KEY:-为空} url=$ST_UCI_URL"
    log "[采集] 网桥=$ST_BRIDGE_OK($ST_BRIDGE_IP) 容器运行=$ST_CT_RUNNING IP=$ST_CT_IP"
    log "[采集] enroll凭据=$ST_ENROLL_CRED 注册码=${ST_ENROLL_KEY:+已配置}${ST_ENROLL_KEY:-未配置}"
}

# ==============================================================================
# 步骤1：建立容器 + crowdsec 跑通 + 本地 API 打通（验证容器/服务/LAPI/bouncer）
# ==============================================================================
step1_container_and_local() {
    log "===== 步骤 1：建容器 + crowdsec 跑通 + 本地 API ====="

    if [ "$ST_IMAGE" = "0" ] && [ "$ST_ROOTFS" = "0" ]; then
        log "[步骤1] 无镜像且无 rootfs，本机不带 CrowdSec，跳过"
        return 1
    fi

    # ---- 建/修容器 ----
    if [ "$ST_ROOTFS" = "0" ]; then
        rebuild_from_image || { log "[步骤1] !! 首次解压失败"; return 1; }
        ST_ROOTFS=1
    else
        log "[步骤1] rootfs 已存在"
    fi

    if [ "$ST_BASE" = "1" ]; then
        sync_from_baseline; _sr=$?
        if [ "$_sr" = "0" ]; then
            log "[步骤1] 配置与备份一致"
        else
            log "[步骤1] 配置已按备份校正"
            ct_running && _ct_env 'systemctl restart crowdsec >/dev/null 2>&1' || true
            sleep 3
        fi
    else
        log "[步骤1] 首次开机无备份，跳过一致性校验"
    fi

    if [ "$ST_CFG_OK" = "0" ] || ! apply_cfg; then
        log "[步骤1] 重写容器 config"
        mkdir -p "$LXC_PATH/$LXC_NAME" 2>/dev/null
        if apply_cfg; then
            ST_CFG_OK=1
        else
            log "[步骤1] !! config 仍无法解析（查 lxc-info -P $LXC_PATH -n $LXC_NAME）"
            return 1
        fi
    else
        log "[步骤1] 容器 config 正常"
    fi

    if [ "$ST_BRIDGE_OK" = "0" ]; then
        log "[步骤1] 等待 lxcbr0 网桥..."
        if _wait_bridge; then
            ST_BRIDGE_OK=1
            ST_BRIDGE_IP=$(ip -4 addr show lxcbr0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -n1)
            log "[步骤1] 网桥就绪 ($ST_BRIDGE_IP)"
        else
            log "[步骤1] !! lxcbr0 未出现（查 network.lxc）"
        fi
    else
        log "[步骤1] 网桥就绪 ($ST_BRIDGE_IP)"
    fi

    if ct_running; then
        log "[步骤1] 容器已在运行"
    else
        log "[步骤1] 启动容器..."
        lxc-start -P "$LXC_PATH" -n "$LXC_NAME" -d 2>/dev/null
        if _wait_ct_running; then
            log "[步骤1] 容器已启动"
        else
            log "[步骤1] !! 容器起不来，重建后重试"
            if rebuild_from_image && apply_cfg; then
                lxc-start -P "$LXC_PATH" -n "$LXC_NAME" -d 2>/dev/null
                _wait_ct_running \
                    && log "[步骤1] 重建后容器已启动" \
                    || { log "[步骤1] !! 重建后仍起不来"; return 1; }
            else
                log "[步骤1] !! 重建失败"
                return 1
            fi
        fi
    fi
    ST_CT_RUNNING=1

    # ---- crowdsec 服务 ----
    if ct_crowdsec_active; then
        log "[步骤1] crowdsec 服务 active"
    else
        log "[步骤1] crowdsec 未 active，重启"
        _ct_env 'systemctl restart crowdsec >/dev/null 2>&1' || true
        _wait_ct_crowdsec() { ct_crowdsec_active; }
        _wait "crowdsec" _wait_ct_crowdsec 12 \
            && log "[步骤1] 服务已就绪" \
            || { log "[步骤1] !! 服务仍未 active（查容器内 journalctl -u crowdsec）"; return 1; }
    fi

    # ---- config.yaml 关键项强制校正（第一次编译配置不可信，发现不对直接覆盖） ----
    if [ ! -f "$CROWDSEC_CFG" ]; then
        log "[步骤1] !! 容器内无 /etc/crowdsec/config.yaml，镜像不完整"
        return 1
    fi

    _cs_restart=0
    if grep -qE "^[[:space:]]*listen_uri:[[:space:]]*['\"]?0\.0\.0\.0:$LAPI_PORT" "$CROWDSEC_CFG" 2>/dev/null; then
        log "[步骤1] LAPI 已对外监听 0.0.0.0:$LAPI_PORT"
    else
        log "[步骤1] listen_uri 不对，覆盖为 0.0.0.0:$LAPI_PORT"
        sed -i -E "s|^([[:space:]]*listen_uri:)[[:space:]]*.*|\\1 0.0.0.0:${LAPI_PORT}|" "$CROWDSEC_CFG" 2>/dev/null
        _cs_restart=1
    fi

    if [ -z "$ST_BRIDGE_IP" ]; then
        log "[步骤1] ⚠️ 未取到网桥 IP，跳过 trusted_ips 校正"
    elif grep -qE "^[[:space:]]*-[[:space:]]*$ST_BRIDGE_IP([[:space:]]|$)" "$CROWDSEC_CFG" 2>/dev/null; then
        log "[步骤1] trusted_ips 已含桥接地址 $ST_BRIDGE_IP"
    else
        log "[步骤1] trusted_ips 未含 $ST_BRIDGE_IP，补上"
        _cs_append_trusted_ip "$ST_BRIDGE_IP" && _cs_restart=1 \
            || log "[步骤1] ⚠️ 补 trusted_ips 失败（非必需）"
    fi

    if [ "$_cs_restart" = "1" ]; then
        _ct_env 'systemctl restart crowdsec >/dev/null 2>&1' || true
        log "[步骤1] 已重启 crowdsec 使覆盖后的配置生效"
    fi

    # ---- syslog 投递（路由器侧 99-custom.sh 已写） ----
    if uci -q get system.@system[0].log_ip | grep -q .; then
        log "[步骤1] 路由器 syslog 目标: $(uci -q get system.@system[0].log_ip):$(uci -q get system.@system[0].log_port)"
    else
        log "[步骤1] ⚠️ 路由器 syslog 外发未配置，容器收不到日志源"
    fi

    # ---- hub 场景库 ----
    _ncoll=$(_ct_env "$CSCLI collections list -o json 2>/dev/null | grep -c '"name"'")
    if [ "${_ncoll:-0}" -gt 0 ] 2>/dev/null; then
        log "[步骤1] 场景库已就绪（$_ncoll 个 collection）"
    else
        log "[步骤1] 场景库为空，执行 hub update + upgrade"
        _ct_env "$CSCLI hub update >/dev/null 2>&1" || true
        _ct_env "$CSCLI hub upgrade >/dev/null 2>&1" || true
        _ncoll=$(_ct_env "$CSCLI collections list -o json 2>/dev/null | grep -c '"name"'")
        [ "${_ncoll:-0}" -gt 0 ] 2>/dev/null \
            && log "[步骤1] 场景库已补齐（$_ncoll 个）" \
            || log "[步骤1] ⚠️ 场景库仍为空（查容器网络与 hub 索引）"
    fi

    # ---- 本地 API 打通 ----
    if ping -c1 -W2 "$ST_CT_IP" >/dev/null 2>&1 || _wait_ping; then
        log "[步骤1] 容器 IP $ST_CT_IP 可达"
    else
        log "[步骤1] !! 容器 IP $ST_CT_IP 不通（查容器网络与网桥）"
        return 1
    fi

    if lapi_ready; then
        log "[步骤1] 本地 API（LAPI :$LAPI_PORT）已就绪"
    elif _wait_lapi; then
        log "[步骤1] 本地 API 已就绪"
    else
        log "[步骤1] LAPI 未就绪，重启 crowdsec 再等一次"
        _ct_env 'systemctl restart crowdsec >/dev/null 2>&1' || true
        if _wait_lapi; then
            log "[步骤1] 重启后 LAPI 已就绪"
        else
            log "[步骤1] !! LAPI 仍未监听（查容器内 systemctl status crowdsec）"
            return 1
        fi
    fi

    # ---- bouncer 段 + api_key 写入 uci ----
    if [ "$ST_CROWDSECCFG" = "0" ]; then
        log "[步骤1] !! /etc/config/crowdsec 不存在，bouncer 包未装进固件，无法写 api_key"
        return 1
    fi
    if [ -z "$ST_SEC" ]; then
        uci add crowdsec bouncer >/dev/null 2>&1
        ST_SEC=$(uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
    fi
    if [ -z "$ST_SEC" ]; then
        log "[步骤1] !! 无法创建 bouncer 配置段"
        return 1
    fi

    if ct $CSCLI bouncers list 2>/dev/null | grep -qw "$BOUNCER_NAME" && [ -n "$ST_UCI_KEY" ]; then
        log "[步骤1] bouncer '$BOUNCER_NAME' 在册且本地 key 完整"
        if [ "$ST_UCI_URL" != "$ST_API_URL_WANT" ]; then
            uci set "$ST_SEC.api_url=$ST_API_URL_WANT"
            uci commit crowdsec
            log "[步骤1] api_url 已校正为 $ST_API_URL_WANT"
        fi
    else
        if ct $CSCLI bouncers list 2>/dev/null | grep -qw "$BOUNCER_NAME"; then
            log "[步骤1] !! bouncer 在册但本地 api_key 为空，强制重注册"
        else
            log "[步骤1] LAPI 中无 bouncer '$BOUNCER_NAME'，执行注册"
        fi

        if ct $CSCLI parsers list 2>/dev/null | grep -q 'crowdsecurity/whitelists'; then
            ct $CSCLI parsers remove crowdsecurity/whitelists --force >/dev/null 2>&1 || true
            _ct_env 'systemctl restart crowdsec >/dev/null 2>&1' || true
            _wait_lapi || true
        fi

        ct $CSCLI bouncers delete "$BOUNCER_NAME" >/dev/null 2>&1 || true
        _KEY=$(ct $CSCLI bouncers add "$BOUNCER_NAME" -o raw 2>/dev/null \
               | sed -e 's/\r$//' | grep -Eo '[A-Za-z0-9+/=_-]{16,}' | tail -n1)
        if [ -z "$_KEY" ]; then
            sleep 3
            ct $CSCLI bouncers delete "$BOUNCER_NAME" >/dev/null 2>&1 || true
            _KEY=$(ct $CSCLI bouncers add "$BOUNCER_NAME" -o raw 2>/dev/null \
                   | sed -e 's/\r$//' | grep -Eo '[A-Za-z0-9+/=_-]{16,}' | tail -n1)
        fi
        if [ -z "$_KEY" ]; then
            log "[步骤1] !! 两次生成 bouncer key 都失败"
            return 1
        fi

        uci set "$ST_SEC.enabled=1"
        uci set "$ST_SEC.api_url=$ST_API_URL_WANT"
        uci set "$ST_SEC.api_key=$_KEY"
        uci set "$ST_SEC.ipv4=1"
        uci set "$ST_SEC.ipv6=0"
        uci set "$ST_SEC.deny_action=drop"
        uci set "$ST_SEC.filter_input=1"
        uci set "$ST_SEC.filter_forward=1"
        uci -q del "$ST_SEC.interface"
        uci add_list "$ST_SEC.interface=br-lan"
        uci commit crowdsec
        ST_UCI_KEY="$_KEY"
        ST_UCI_URL="$ST_API_URL_WANT"
        log "[步骤1] bouncer 注册成功，api_key 已写入 $ST_SEC"
    fi

    # ---- 验证 bouncer 状态 ----
    _vout=$(ct $CSCLI bouncers inspect "$BOUNCER_NAME" -o raw 2>/dev/null)
    if [ -z "$_vout" ]; then
        log "[步骤1] ⚠️ bouncers inspect 无输出，稍后再查"
    else
        _vname=$(printf '%s\n' "$_vout" | sed -n 's/^[[:space:]]*name:[[:space:]]*//p' | head -n1)
        _vip=$(printf '%s\n' "$_vout" | sed -n 's/^[[:space:]]*ip_address:[[:space:]]*//p' | head -n1)
        _vlp=$(printf '%s\n' "$_vout" | sed -n 's/^[[:space:]]*last_pull:[[:space:]]*//p' | head -n1)
        log "[步骤1] bouncer 校验 → 名称=${_vname:-?} IP=${_vip:-?} last_pull=${_vlp:-?}"
        [ -n "$_vname" ] || log "[步骤1] ⚠️ bouncer 名称读不到"
        [ -n "$_vip" ]   || log "[步骤1] ⚠️ 来源 IP 读不到"
        [ -n "$_vlp" ]   || log "[步骤1] ⚠️ last_pull 为空，bouncer 尚未拉取 decisions"
    fi

    # ---- 本地保护（宿主 bouncer + nft） ----
    _ensure_bouncer_service
    if cs_active_on_host && nft_table_ready; then
        log "[步骤1] 本地保护已建立（bouncer + nftables crowdsec 表）"
    else
        log "[步骤1] ⚠️ 本地保护未完全建立，重启 bouncer 复查"
        service crowdsec-firewall-bouncer restart 2>/dev/null || true
        sleep 3
        cs_active_on_host && nft_table_ready \
            && log "[步骤1] 重启后本地保护已建立" \
            || log "[步骤1] !! 仍无 nft crowdsec 表（查 bouncer 日志与 deny_action）"
    fi

    log "===== 步骤 1 完成 ====="
    return 0
}

# ==============================================================================
# 步骤2：远程 enroll（验证外网/凭据/console status）
# ==============================================================================
step2_remote_enroll() {
    log "===== 步骤 2：远程 enroll ====="

    if net_online; then
        log "[步骤2] 外网可达"
    else
        log "[步骤2] 外网不通，本轮不判 enroll（下次开机再试）"
        return 1
    fi

    _rst() {
        _ct_env '[ -s /etc/crowdsec/online_api_credentials.yaml ] || exit 1
                  /usr/bin/cscli console status 2>&1' 2>/dev/null
    }
    _console_status() { _rst; }

    _out=$(_console_status); _rc=$?
    if [ "$_rc" -eq 0 ] && [ -n "$_out" ]; then
        if printf '%s\n' "$_out" | grep -qiE "not registered|not enrolled|unauthorized|forbidden|invalid|revoked"; then
            log "[步骤2] 远程 API 已失效，需重新 enroll"
            _need=2
        else
            log "[步骤2] 远程 API 已绑定且有效"
            printf '%s\n' "$_out" | sed -n '1,6p' | while IFS= read -r _l; do log "[步骤2]   $_l"; done
            return 0
        fi
    else
        log "[步骤2] 无凭据或 console status 异常，判定为需要 enroll"
        _need=1
    fi

    if [ -z "$ST_ENROLL_KEY" ]; then
        if [ -s "$ENROLL_USED_FILE" ] && [ "$_need" = "1" ]; then
            log "[步骤2] 注册码已用尽（一次性），去 app.crowdsec.net 重新生成后写入 $ENROLL_KEY_FILE"
            return 1
        fi
        log "[步骤2] 未配置注册码，跳过（写入 $ENROLL_KEY_FILE 后下次开机生效）"
        return 1
    fi
    if [ -s "$ENROLL_USED_FILE" ] && [ "$(head -n1 "$ENROLL_USED_FILE")" = "$ST_ENROLL_KEY" ] && [ "$_need" = "1" ]; then
        log "[步骤2] 该注册码上次已用过且未成功，不再重复消耗（去换新码）"
        return 1
    fi

    _CRED_BAK=""
    if [ "$_need" = "2" ]; then
        _CRED_BAK="$ROOTFS/etc/crowdsec/online_api_credentials.yaml.bak"
        mv -f "$ROOTFS/etc/crowdsec/online_api_credentials.yaml" "$_CRED_BAK" 2>/dev/null || true
        log "[步骤2] 旧凭据已备份到 .bak"
    fi

    if ! _ct_env "/usr/bin/cscli console enroll $ST_ENROLL_KEY >/dev/null 2>&1"; then
        [ -n "$_CRED_BAK" ] && mv -f "$_CRED_BAK" "$ROOTFS/etc/crowdsec/online_api_credentials.yaml"
        mkdir -p "$CS_HOME" 2>/dev/null
        printf '%s\n' "$ST_ENROLL_KEY" > "$ENROLL_USED_FILE" 2>/dev/null
        log "[步骤2] !! enroll 失败（注册码一次性，已记入 $ENROLL_USED_FILE）"
        return 1
    fi

    _ct_env 'systemctl restart crowdsec >/dev/null 2>&1' || true
    _ct_env '/usr/bin/cscli console enable --all >/dev/null 2>&1' || true
    _i=0; _ok=1
    while [ "$_i" -lt 6 ]; do
        _i=$((_i+1))
        lapi_ready || { sleep 5; continue; }
        _o2=$(_console_status); _r2=$?
        if [ "$_r2" -eq 0 ] && [ -n "$_o2" ] \
           && ! printf '%s\n' "$_o2" | grep -qiE "not registered|not enrolled|unauthorized|forbidden|invalid|revoked"; then
            _ok=0; break
        fi
        sleep 5
    done

    if [ "$_ok" -eq 0 ]; then
        mkdir -p "$CS_HOME" 2>/dev/null
        printf '%s\n' "$ST_ENROLL_KEY" > "$ENROLL_USED_FILE" 2>/dev/null
        ST_ENROLL_CRED=1
        log "[步骤2] ✅ 控制台绑定完成（记得回 app.crowdsec.net 点 Accept）"
    else
        [ -n "$_CRED_BAK" ] && mv -f "$_CRED_BAK" "$ROOTFS/etc/crowdsec/online_api_credentials.yaml"
        log "[步骤2] !! enroll 后复检未通过，已回滚旧凭据"
        return 1
    fi

    log "===== 步骤 2 完成 ====="
    return 0
}

# ==============================================================================
# 步骤3：备份配置（健康门禁 → 写快照 → 复验一致性）
# ==============================================================================
step3_backup() {
    log "===== 步骤 3：备份容器配置 ====="

    [ -n "$ST_UCI_KEY" ] || { log "[步骤3] !! api_key 为空，拒绝备份"; return 1; }

    _sout=$(ct $CSCLI bouncers inspect "$BOUNCER_NAME" -o raw 2>/dev/null)
    _sname=$(printf '%s\n' "$_sout" | sed -n 's/^[[:space:]]*name:[[:space:]]*//p' | head -n1)
    _sip=$(printf '%s\n' "$_sout" | sed -n 's/^[[:space:]]*ip_address:[[:space:]]*//p' | head -n1)
    _slp=$(printf '%s\n' "$_sout" | sed -n 's/^[[:space:]]*last_pull:[[:space:]]*//p' | head -n1)
    _srvk=$(printf '%s\n' "$_sout" | sed -n 's/^[[:space:]]*revoked:[[:space:]]*//p' | head -n1)

    [ -n "$_sname" ] || { log "[步骤3] !! bouncer 名称读不到，拒绝备份"; return 1; }
    [ -n "$_sip" ]   || { log "[步骤3] !! bouncer 来源 IP 读不到，拒绝备份"; return 1; }
    [ -n "$_slp" ]   || { log "[步骤3] !! last_pull 为空，拒绝备份"; return 1; }
    [ "$_srvk" = "false" ] || { log "[步骤3] !! bouncer 已吊销，拒绝备份"; return 1; }

    if [ "$ST_ENROLL_CRED" = "1" ]; then
        _cst=$(ct $CSCLI console status 2>&1)
        if printf '%s\n' "$_cst" | grep -qiE "not registered|not enrolled|unauthorized|forbidden|invalid|revoked"; then
            log "[步骤3] ⚠️ console status 凭据异常，仍备份本地配置"
        else
            log "[步骤3] console status 有效"
        fi
    else
        log "[步骤3] 未 enroll，只备份本地配置"
    fi

    if ! mkdir -p "$SNAP_ETC" 2>/dev/null; then
        log "[步骤3] !! 无法创建 $SNAP_ETC"
        return 1
    fi
    _bc=0
    for _rel in $( cd "$ROOTFS/etc/crowdsec" 2>/dev/null && find . -type f -name '*.yaml' 2>/dev/null | sed 's|^\./||' ); do
        case "$_rel" in *whitelists*) continue ;; esac
        _dst="$SNAP_ETC/$_rel"
        mkdir -p "$(dirname "$_dst")" 2>/dev/null
        cp -p "$ROOTFS/etc/crowdsec/$_rel" "$_dst" 2>/dev/null \
            && _bc=$((_bc+1)) \
            || log "[步骤3] !! 备份失败: $_rel"
    done
    log "[步骤3] 已备份 $_bc 个配置文件到 $SNAP_ETC"

    cat > "$STATE_FILE" <<EOF
VER=$SCRIPT_VER
TIME=$(date '+%F %T')
CONTAINER=$LXC_NAME
CONTAINER_IP=$ST_CT_IP
BRIDGE_IP=$ST_BRIDGE_IP
LAPI_PORT=$LAPI_PORT
BOUNCER_NAME=$_sname
BOUNCER_IP=$_sip
LAST_PULL=$_slp
API_URL=$ST_UCI_URL
UCI_SECTION=$ST_SEC
ENROLLED=$ST_ENROLL_CRED
EOF
    log "[步骤3] 稳定态标记已写入 $STATE_FILE"

    _bad=0
    for _rel in $( cd "$SNAP_ETC" 2>/dev/null && find . -type f -name '*.yaml' 2>/dev/null | sed 's|^\./||' ); do
        cmp -s "$ROOTFS/etc/crowdsec/$_rel" "$SNAP_ETC/$_rel" || _bad=1
    done
    [ "$_bad" -eq 0 ] \
        && log "[步骤3] ✅ 复验通过，配置与备份完全一致" \
        || log "[步骤3] !! 复验未过，仍有文件不一致"

    log "===== 步骤 3 完成 ====="
    return 0
}

main() {
    collect_state

    step1_container_and_local; R1=$?
    step2_remote_enroll;      R2=$?
    step3_backup;             R3=$?

    log "----- 汇总 -----"
    log "步骤1容器+本地=$R1 步骤2enroll=$R2 步骤3备份=$R3"

    _final_key=""
    _final_sec=$(uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
    [ -n "$_final_sec" ] && _final_key="$(uci -q get "$_final_sec.api_key" 2>/dev/null)"
    if [ -z "$_final_key" ]; then
        log "!! 终局检查：api_key 仍为空"
        log "   ① /etc/config/crowdsec 是否存在  ② 容器是否在跑：lxc-ls -P $LXC_PATH --running"
        log "   ③ LAPI 是否监听：lxc-attach -P $LXC_PATH -n $LXC_NAME -- ss -ltn | grep $LAPI_PORT"
        log "   ④ 完整日志：/root/crowdsec-lxc-bootstrap.log"
        exit 1
    fi
    log "✅ 终局检查通过：api_key 已就绪（$R1$R2$R3）"
    exit 0
}

main "$@"
