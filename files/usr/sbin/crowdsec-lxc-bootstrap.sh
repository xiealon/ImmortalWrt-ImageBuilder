#!/bin/sh
SCRIPT_VER="2026-10-14.9"

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
MAX_WAIT="${MAX_WAIT:-60}"
SLEEP=5
CROWDSEC_CFG="$ROOTFS/etc/crowdsec/config.yaml"
CSCLI=/usr/bin/cscli

if [ -z "${CONTAINER_IP:-}" ] && [ -f /etc/config/custom_container_ip.txt ]; then
    CONTAINER_IP="$(head -n1 /etc/config/custom_container_ip.txt | tr -d ' \t\r\n')"
fi
CONTAINER_IP="${CONTAINER_IP:-10.0.0.10}"
if [ -z "${BRIDGE_IP:-}" ] && [ -f /etc/config/custom_bridge_ip.txt ]; then
    BRIDGE_IP="$(head -n1 /etc/config/custom_bridge_ip.txt | tr -d ' \t\r\n')"
fi
BRIDGE_IP="${BRIDGE_IP:-10.0.0.1}"

log() { echo "[$(date '+%F %T')] $*"; }

case "$0" in
    /*) _SELF="$0" ;;
    */*) _SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")" ;;
    *) _SELF="$(command -v "$0" 2>/dev/null)" ;;
esac
[ -n "$_SELF" ] && chmod +x "$_SELF" 2>/dev/null
chmod +x /etc/rc.local 2>/dev/null

ct() { lxc-attach -P "$LXC_PATH" -n "$LXC_NAME" -- "$@"; }
ct_running() { lxc-ls -P "$LXC_PATH" --running 2>/dev/null | grep -qw "$LXC_NAME"; }
ct_exists() { lxc-info -P "$LXC_PATH" -n "$LXC_NAME" >/dev/null 2>&1; }
_pgrep_bouncer() { pgrep -f "crowdsec-firewall-bouncer" >/dev/null 2>&1; }
_ct_env() { ct sh -c 'export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; '"$1"; }

lapi_ready() {
    _ct_env "[ -S /var/lib/crowdsec/data/crowdsec-cli.sock ] && exit 0
              [ -x /usr/bin/ss ] && ss -ltn 2>/dev/null | grep -q :$LAPI_PORT && exit 0
              exit 1" 2>/dev/null
}
ct_crowdsec_active() {
    _ct_env '[ -x /bin/systemctl ] && systemctl is-active crowdsec >/dev/null 2>&1 && exit 0
              pgrep -x crowdsec >/dev/null 2>&1 && exit 0
              exit 1' 2>/dev/null
}
cs_active_on_host() { _pgrep_bouncer; }
nft_table_ready() { nft list table ip crowdsec >/dev/null 2>&1; }

_wait() {
    _wf="$1"; _wn="${2:-$MAX_WAIT}"
    _wi=0
    until "$_wf"; do
        _wi=$((_wi+1))
        [ "$_wi" -ge "$_wn" ] && return 1
        sleep $SLEEP
    done
    return 0
}
_wait_ct_running() { _wait ct_running 12; }
_wait_lapi() { _wait lapi_ready; }
_wait_ping() { _wp() { ping -c1 -W2 "$CONTAINER_IP" >/dev/null 2>&1; }; _wait _wp; }
_wait_bridge() { _wb() { ip link show lxcbr0 >/dev/null 2>&1; }; _wait _wb; }

net_online() {
    _ct_env '[ -x /bin/ping ] && { ping -c1 -W3 223.5.5.5 >/dev/null 2>&1 || ping -c1 -W3 119.29.29.29 >/dev/null 2>&1; } && exit 0
              [ -x /usr/bin/curl ] && curl -s -m 8 -o /dev/null https://api.crowdsec.net 2>/dev/null && exit 0
              exit 1' 2>/dev/null
}

setup_bridge() {
    _br=$(ip -4 addr show lxcbr0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -n1)
    if ip link show lxcbr0 >/dev/null 2>&1 \
       && [ "$(uci -q get network.lxc.proto 2>/dev/null)" = "static" ] \
       && [ -n "$_br" ] && [ "$_br" = "$BRIDGE_IP" ]; then
        log "[网桥] 已就绪 lxcbr0=${BRIDGE_IP}/24，跳过重建"
        return 0
    fi
    _lsc_net=$(echo "$CONTAINER_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')
    _lan_ip=$(uci -q get network.lan.ipaddr 2>/dev/null)
    if [ -z "$_lan_ip" ] && [ -f /etc/config/custom_router_ip.txt ]; then
        _lan_ip=$(head -n1 /etc/config/custom_router_ip.txt | tr -d ' \t\r\n')
    fi
    [ -n "$_lan_ip" ] || _lan_ip='192.168.3.201'

    uci -q set network.lxcbr0=device
    uci -q set network.lxcbr0.name='lxcbr0'
    uci -q set network.lxcbr0.type='bridge'
    uci -q set network.lxcbr0.bridge_empty='1'
    uci -q set network.lxc=interface
    uci -q set network.lxc.device='lxcbr0'
    uci -q set network.lxc.proto='static'
    uci -q set network.lxc.ipaddr="${BRIDGE_IP}"
    uci -q set network.lxc.netmask='255.255.255.0'
    uci -q set dhcp.lxc=dhcp
    uci -q set dhcp.lxc.interface='lxc'
    uci -q set dhcp.lxc.start='100'
    uci -q set dhcp.lxc.limit='150'
    uci -q set dhcp.lxc.leasetime='1h'
    uci -q set firewall.lxczone=zone
    uci -q set firewall.lxczone.name='lxc'
    uci -q set firewall.lxczone.network='lxc'
    uci -q set firewall.lxczone.input='ACCEPT'
    uci -q set firewall.lxczone.output='ACCEPT'
    uci -q set firewall.lxczone.forward='ACCEPT'
    uci -q set firewall.lxc2lan=forwarding
    uci -q set firewall.lxc2lan.src='lxc'
    uci -q set firewall.lxc2lan.dest='lan'
    uci -q set firewall.lxc2docker=forwarding
    uci -q set firewall.lxc2docker.src='lxc'
    uci -q set firewall.lxc2docker.dest='docker'
    uci -q set firewall.lxc2vpn=forwarding
    uci -q set firewall.lxc2vpn.src='lxc'
    uci -q set firewall.lxc2vpn.dest='vpn'
    uci -q set firewall.lan2lxc=forwarding
    uci -q set firewall.lan2lxc.src='lan'
    uci -q set firewall.lan2lxc.dest='lxc'
    uci -q set firewall.lxcsnat=nat
    uci -q set firewall.lxcsnat.name='lxc-snat'
    uci -q del_list firewall.lxcsnat.proto='all'
    uci -q add_list firewall.lxcsnat.proto='all'
    uci -q set firewall.lxcsnat.src='lan'
    uci -q set firewall.lxcsnat.src_ip="${_lsc_net}"
    uci -q set firewall.lxcsnat.target='SNAT'
    uci -q set firewall.lxcsnat.snat_ip="${_lan_ip}"
    uci -q commit network
    uci -q commit dhcp
    uci -q commit firewall

    /etc/init.d/network reload >/dev/null 2>&1
    /etc/init.d/firewall reload >/dev/null 2>&1

    if ! ip link show lxcbr0 >/dev/null 2>&1; then
        ip link add lxcbr0 type bridge 2>/dev/null
    fi
    ip addr add "${BRIDGE_IP}/24" dev lxcbr0 2>/dev/null
    ip link set lxcbr0 up 2>/dev/null
    echo 1 >/proc/sys/net/ipv4/ip_forward 2>/dev/null

    BRIDGE_IP=$(ip -4 addr show lxcbr0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -n1)
    log "[网桥] lxcbr0=${BRIDGE_IP}/24 容器=${CONTAINER_IP} 网段=${_lsc_net}"
}

write_cfg() {
    _dst="${1:-$CFG}"
    cat > "$_dst" <<EOF
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

rebuild_from_image() {
    log "[步骤1] 尝试从镜像重建 rootfs：$TARBALL"
    [ -f "$TARBALL" ] || { log "[步骤1] 镜像文件不存在，无法重建"; return 1; }
    ct_running && lxc-stop -P "$LXC_PATH" -n "$LXC_NAME" -k -f >/dev/null 2>&1
    sleep 2
    rm -rf "$ROOTFS" 2>/dev/null
    mkdir -p "$ROOTFS" || return 1
    if ( set -C; : > "$ROOTFS/.extracting" ) 2>/dev/null; then
        if tar -xzf "$TARBALL" -C "$ROOTFS"; then
            rm -f "$ROOTFS/.extracting"
            log "[步骤1] 重建完成（$(du -sh "$ROOTFS" 2>/dev/null | cut -f1)）"
            return 0
        fi
        rm -f "$ROOTFS/.extracting"
        log "[步骤1] 解压失败"
        return 1
    fi
    log "[步骤1] 另一实例正在解压，等待完成"
    _i=0
    while [ -f "$ROOTFS/.extracting" ]; do
        _i=$((_i+1)); [ "$_i" -ge $MAX_WAIT ] && break; sleep $SLEEP
    done
    [ -f "$CROWDSEC_CFG" ]
}

_cs_append_trusted_ip() {
    _tip="${1:-$BRIDGE_IP}"
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
        log "[bouncer] 重启后仍未就绪"
    fi
    return 0
}

sync_from_baseline() {
    [ -d "$ROOTFS/etc/crowdsec" ] || { log "[步骤1] rootfs 未就绪，无法比对"; return 2; }
    _changed=0
    _list=/tmp/.cs-base-list.$$
    { ( cd "$SNAP_ETC" 2>/dev/null && find . -type f -name '*.yaml' 2>/dev/null )
      ( cd "$ROOTFS/etc/crowdsec" 2>/dev/null && find . -type f -name '*.yaml' 2>/dev/null )
    } | sed 's|^\./||' | sort -u > "$_list"
    while IFS= read -r _rel; do
        [ -n "$_rel" ] || continue
        case "$_rel" in *whitelists*) continue ;; esac
        _sn_f="$SNAP_ETC/$_rel"
        _ct_f="$ROOTFS/etc/crowdsec/$_rel"
        if [ -f "$_sn_f" ] && [ ! -f "$_ct_f" ]; then
            mkdir -p "$(dirname "$_ct_f")"
            cp -p "$_sn_f" "$_ct_f" 2>/dev/null \
                && { log "[步骤1] 补回缺失配置: $_rel"; _changed=1; } \
                || log "[步骤1] 补回失败: $_rel"
        elif [ -f "$_ct_f" ] && [ -f "$_sn_f" ]; then
            cmp -s "$_ct_f" "$_sn_f" && continue
            mkdir -p "$(dirname "$_ct_f")"
            cp -p "$_sn_f" "$_ct_f" 2>/dev/null \
                && { log "[步骤1] 配置与备份不一致，已覆盖: $_rel"; _changed=1; } \
                || log "[步骤1] 覆盖失败: $_rel"
        fi
    done < "$_list"
    rm -f "$_list"
    return "$_changed"
}

step1_local() {
    log "===== 步骤 1：建容器 + 本地 API + bouncer ====="

    _image=0; [ -f "$TARBALL" ] && _image=1
    _rootfs=0; [ -f "$CROWDSEC_CFG" ] && _rootfs=1

    if [ "$_image" = "0" ] && [ "$_rootfs" = "0" ]; then
        log "[步骤1] 无镜像且无 rootfs，本机不带 CrowdSec，跳过"
        return 1
    fi

    if [ "$_rootfs" = "0" ]; then
        rebuild_from_image || { log "[步骤1] 首次解压失败"; return 1; }
    fi

    if ! apply_cfg; then
        log "[步骤1] 重写容器 config"
        mkdir -p "$LXC_PATH/$LXC_NAME" 2>/dev/null
        apply_cfg || { log "[步骤1] config 仍无法解析"; return 1; }
    else
        log "[步骤1] 容器 config 正常"
    fi

    setup_bridge

    if ct_running; then
        log "[步骤1] 校验a：容器自启成功（运行中）"
    else
        log "[步骤1] 启动容器"
        if ! lxc-start -P "$LXC_PATH" -n "$LXC_NAME" -d 2>/dev/null || ! _wait_ct_running; then
            log "[步骤1] 容器起不来，重建后重试"
            if rebuild_from_image && apply_cfg; then
                lxc-start -P "$LXC_PATH" -n "$LXC_NAME" -d 2>/dev/null
                _wait_ct_running || { log "[步骤1] 重建后仍起不来"; return 1; }
            else
                log "[步骤1] 重建失败"
                return 1
            fi
        fi
        log "[步骤1] 校验a：容器已启动"
    fi

    if [ "$FIRST_BOOT" = "0" ]; then
        sync_from_baseline; _sr=$?
        if [ "$_sr" = "0" ]; then
            log "[步骤1] 配置与备份一致"
        else
            log "[步骤1] 配置已按备份校正"
            _ct_env 'systemctl restart crowdsec >/dev/null 2>&1' || true
            sleep 3
        fi
    else
        log "[步骤1] 首次开机无备份，跳过一致性校验"
    fi

    if ct_crowdsec_active; then
        log "[步骤1] crowdsec 服务 active"
    else
        log "[步骤1] crowdsec 未 active，重启"
        _ct_env 'systemctl restart crowdsec >/dev/null 2>&1' || true
        _wait_ct_cs() { ct_crowdsec_active; }
        _wait _wait_ct_cs 12 || { log "[步骤1] 服务仍未 active"; return 1; }
    fi

    [ -f "$CROWDSEC_CFG" ] || { log "[步骤1] 容器内无 /etc/crowdsec/config.yaml，镜像不完整"; return 1; }

    _cs_restart=0
    if grep -qE "^[[:space:]]*listen_uri:[[:space:]]*['\"]?0\.0\.0\.0:$LAPI_PORT" "$CROWDSEC_CFG" 2>/dev/null; then
        log "[步骤1] LAPI 已对外监听 0.0.0.0:$LAPI_PORT"
    else
        log "[步骤1] listen_uri 不对，覆盖为 0.0.0.0:$LAPI_PORT"
        sed -i -E "s|^([[:space:]]*listen_uri:)[[:space:]]*.*|\\1 0.0.0.0:${LAPI_PORT}|" "$CROWDSEC_CFG" 2>/dev/null
        _cs_restart=1
    fi

    if [ -z "$BRIDGE_IP" ]; then
        log "[步骤1] 未取到网桥 IP，跳过 trusted_ips 校正"
    elif grep -qE "^[[:space:]]*-[[:space:]]*$BRIDGE_IP([[:space:]]|$)" "$CROWDSEC_CFG" 2>/dev/null; then
        log "[步骤1] trusted_ips 已含 $BRIDGE_IP"
    else
        log "[步骤1] trusted_ips 未含 $BRIDGE_IP，补上"
        _cs_append_trusted_ip "$BRIDGE_IP" && _cs_restart=1 || log "[步骤1] 补 trusted_ips 失败"
    fi

    if [ "$_cs_restart" = "1" ]; then
        _ct_env 'systemctl restart crowdsec >/dev/null 2>&1' || true
        log "[步骤1] 已重启 crowdsec 使覆盖生效"
    fi

    _ncoll=$(_ct_env "$CSCLI collections list -o json 2>/dev/null | grep -c '\"name\"'")
    if [ "${_ncoll:-0}" -gt 0 ] 2>/dev/null; then
        log "[步骤1] 场景库就绪（$_ncoll 个 collection）"
    else
        log "[步骤1] 场景库为空，执行 hub update + upgrade"
        _ct_env "$CSCLI hub update >/dev/null 2>&1" || true
        _ct_env "$CSCLI hub upgrade >/dev/null 2>&1" || true
        _ncoll=$(_ct_env "$CSCLI collections list -o json 2>/dev/null | grep -c '\"name\"'")
        [ "${_ncoll:-0}" -gt 0 ] 2>/dev/null \
            && log "[步骤1] 场景库已补齐（$_ncoll 个）" \
            || log "[步骤1] 场景库仍为空"
    fi

    if ping -c1 -W2 "$CONTAINER_IP" >/dev/null 2>&1 || _wait_ping; then
        log "[步骤1] 容器 IP $CONTAINER_IP 可达"
    else
        log "[步骤1] 容器 IP $CONTAINER_IP 不通"
        return 1
    fi

    if lapi_ready; then
        log "[步骤1] 校验b：本地 API（LAPI :$LAPI_PORT）已就绪"
    elif _wait_lapi; then
        log "[步骤1] 校验b：本地 API 已就绪"
    else
        log "[步骤1] LAPI 未就绪，重启 crowdsec 再等"
        _ct_env 'systemctl restart crowdsec >/dev/null 2>&1' || true
        _wait_lapi || { log "[步骤1] 校验b：LAPI 仍未监听"; return 1; }
        log "[步骤1] 校验b：重启后 LAPI 已就绪"
    fi

    [ -f /etc/config/crowdsec ] || { log "[步骤1] /etc/config/crowdsec 不存在，bouncer 包未装进固件"; return 1; }

    _sec=$(uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
    if [ -z "$_sec" ]; then
        uci add crowdsec bouncer >/dev/null 2>&1
        _sec=$(uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
    fi
    [ -n "$_sec" ] || { log "[步骤1] 无法创建 bouncer 配置段"; return 1; }

    _uci_key="$(uci -q get "$_sec.api_key" 2>/dev/null)"
    _api_url_want="http://${CONTAINER_IP}:${LAPI_PORT}/"

    uci set "$_sec.enabled=1"
    uci set "$_sec.api_url=$_api_url_want"
    uci set "$_sec.ipv4=1"
    uci set "$_sec.ipv6=0"
    uci set "$_sec.deny_action=drop"
    uci set "$_sec.filter_input=1"
    uci set "$_sec.filter_forward=1"
    uci -q del "$_sec.interface"
    uci add_list "$_sec.interface=br-lan"
    uci commit crowdsec
    log "[步骤1] bouncer 段已预填（api_url=$_api_url_want）"

    if ct $CSCLI bouncers list 2>/dev/null | grep -qw "$BOUNCER_NAME" && [ -n "$_uci_key" ]; then
        log "[步骤1] bouncer '$BOUNCER_NAME' 在册且本地 key 完整"
    else
        if ct $CSCLI bouncers list 2>/dev/null | grep -qw "$BOUNCER_NAME"; then
            log "[步骤1] bouncer 在册但本地 api_key 为空，强制重注册"
        else
            log "[步骤1] LAPI 中无 bouncer '$BOUNCER_NAME'，执行注册"
        fi

        if ct $CSCLI parsers list 2>/dev/null | grep -q 'crowdsecurity/whitelists'; then
            ct $CSCLI parsers remove crowdsecurity/whitelists --force >/dev/null 2>&1 || true
            _ct_env 'systemctl restart crowdsec >/dev/null 2>&1' || true
            _wait_lapi || true
        fi

        ct $CSCLI bouncers delete "$BOUNCER_NAME" >/dev/null 2>&1 || true
        _key=$(ct $CSCLI bouncers add "$BOUNCER_NAME" -o raw 2>/dev/null \
               | sed -e 's/\r$//' | grep -Eo '[A-Za-z0-9+/=_-]{16,}' | tail -n1)
        if [ -z "$_key" ]; then
            sleep 3
            ct $CSCLI bouncers delete "$BOUNCER_NAME" >/dev/null 2>&1 || true
            _key=$(ct $CSCLI bouncers add "$BOUNCER_NAME" -o raw 2>/dev/null \
                   | sed -e 's/\r$//' | grep -Eo '[A-Za-z0-9+/=_-]{16,}' | tail -n1)
        fi
        [ -n "$_key" ] || { log "[步骤1] 两次生成 bouncer key 都失败"; return 1; }

        uci set "$_sec.api_key=$_key"
        uci commit crowdsec
        log "[步骤1] bouncer 注册成功，api_key 已写入 $_sec"
    fi

    _blist=$(ct $CSCLI bouncers list 2>/dev/null)
    _vout=$(ct $CSCLI bouncers inspect "$BOUNCER_NAME" -o raw 2>/dev/null)
    if printf '%s\n' "$_blist" | grep -qw "$BOUNCER_NAME" && [ -n "$_vout" ]; then
        _vname=$(printf '%s\n' "$_vout" | sed -n 's/^[[:space:]]*name:[[:space:]]*//p' | head -n1)
        _vip=$(printf '%s\n' "$_vout" | sed -n 's/^[[:space:]]*ip_address:[[:space:]]*//p' | head -n1)
        _vlp=$(printf '%s\n' "$_vout" | sed -n 's/^[[:space:]]*last_pull:[[:space:]]*//p' | head -n1)
        log "[步骤1] 校验c：bouncers list 有详细数据 → 名称=${_vname:-?} IP=${_vip:-?} last_pull=${_vlp:-?}"
    else
        log "[步骤1] 校验c：bouncers list 无详细数据，稍后再查"
    fi

    _ensure_bouncer_service
    if cs_active_on_host && nft_table_ready; then
        log "[步骤1] 本地保护已建立（bouncer + nftables crowdsec 表）"
    else
        log "[步骤1] 本地保护未完全建立，重启 bouncer 复查"
        service crowdsec-firewall-bouncer restart 2>/dev/null || true
        sleep 3
        cs_active_on_host && nft_table_ready \
            && log "[步骤1] 重启后本地保护已建立" \
            || log "[步骤1] 仍无 nft crowdsec 表"
    fi

    log "===== 步骤 1 完成 ====="
    return 0
}

step2_enroll() {
    log "===== 步骤 2：远程 enroll ====="

    _enroll_key=""
    [ -f "$ENROLL_KEY_FILE" ] && _enroll_key="$(head -n1 "$ENROLL_KEY_FILE" | tr -d ' \t\r\n')"
    _cred_file="$ROOTFS/etc/crowdsec/online_api_credentials.yaml"

    if ! net_online; then
        log "[步骤2] 外网不通，本轮跳过 enroll（下次开机再试）"
        return 1
    fi

    _status() {
        _ct_env '[ -s /etc/crowdsec/online_api_credentials.yaml ] || exit 1
                  /usr/bin/cscli console status 2>&1' 2>/dev/null
    }

    _out=$(_status); _rc=$?

    if [ "$_rc" = "0" ] && [ -n "$_out" ]; then
        _capi=0; _enroll=0
        if printf '%s\n' "$_out" | grep -qiE "unauthorized|forbidden|invalid|revoked"; then
            :
        else
            printf '%s\n' "$_out" | grep -qiE "Central API.*authenticated" && _capi=1
            if ! printf '%s\n' "$_out" | grep -qiE "not enrolled"; then
                printf '%s\n' "$_out" | grep -qiE "[Ee]nrolled" && _enroll=1
            fi
        fi
        if [ "$_capi" = "1" ] && [ "$_enroll" = "1" ]; then
            log "[步骤2] CAPI 已认证 + 已 enroll，均有效"
            return 0
        fi
        log "[步骤2] CAPI=$([ "$_capi" = "1" ] && echo 已认证 || echo 未认证)  enroll=$([ "$_enroll" = "1" ] && echo 已绑定 || echo 未绑定)"
    else
        log "[步骤2] 无凭据或 console status 异常，需要 enroll"
    fi

    if [ -z "$_enroll_key" ]; then
        log "[步骤2] 未配置注册码，跳过（写入 $ENROLL_KEY_FILE 后下次开机生效）"
        return 1
    fi

    _bak=""
    if [ -s "$_cred_file" ]; then
        _bak="$_cred_file.bak"
        mv -f "$_cred_file" "$_bak" 2>/dev/null || true
    fi

    if ! _ct_env "/usr/bin/cscli console enroll $_enroll_key >/dev/null 2>&1"; then
        [ -n "$_bak" ] && mv -f "$_bak" "$_cred_file"
        log "[步骤2] enroll 执行失败（注册码未消耗），下次开机重试"
        return 1
    fi

    _ct_env 'systemctl restart crowdsec >/dev/null 2>&1' || true
    _ct_env '/usr/bin/cscli console enable --all >/dev/null 2>&1' || true

    _i=0; _ok=1
    while [ "$_i" -lt 6 ]; do
        _i=$((_i+1))
        lapi_ready || { sleep 5; continue; }
        _o2=$(_status); _r2=$?
        if [ "$_r2" = "0" ] && [ -n "$_o2" ] \
           && ! printf '%s\n' "$_o2" | grep -qiE "not registered|not enrolled|unauthorized|forbidden|invalid|revoked"; then
            _ok=0; break
        fi
        sleep 5
    done

    if [ "$_ok" = "0" ]; then
        log "[步骤2] 控制台绑定已提交（请在 app.crowdsec.net 点 Accept）"
    else
        [ -n "$_bak" ] && mv -f "$_bak" "$_cred_file"
        log "[步骤2] enroll 复检未通过，已回滚旧凭据"
        return 1
    fi

    log "===== 步骤 2 完成 ====="
    return 0
}

step3_backup() {
    log "===== 步骤 3：备份 ====="

    _sec=$(uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
    _key=""
    [ -n "$_sec" ] && _key="$(uci -q get "$_sec.api_key" 2>/dev/null)"

    [ -n "$_key" ] || { log "[步骤3] api_key 为空，拒绝备份"; return 1; }

    _sout=$(ct $CSCLI bouncers inspect "$BOUNCER_NAME" -o raw 2>/dev/null)
    _sname=$(printf '%s\n' "$_sout" | sed -n 's/^[[:space:]]*name:[[:space:]]*//p' | head -n1)
    _sip=$(printf '%s\n' "$_sout" | sed -n 's/^[[:space:]]*ip_address:[[:space:]]*//p' | head -n1)
    _slp=$(printf '%s\n' "$_sout" | sed -n 's/^[[:space:]]*last_pull:[[:space:]]*//p' | head -n1)
    _srvk=$(printf '%s\n' "$_sout" | sed -n 's/^[[:space:]]*revoked:[[:space:]]*//p' | head -n1)

    [ -n "$_sname" ] || { log "[步骤3] bouncer 名称读不到，拒绝备份"; return 1; }
    [ -n "$_sip" ]   || { log "[步骤3] bouncer 来源 IP 读不到，拒绝备份"; return 1; }
    [ -n "$_slp" ]   || { log "[步骤3] last_pull 为空，拒绝备份"; return 1; }
    [ "$_srvk" = "false" ] || { log "[步骤3] bouncer 已吊销，拒绝备份"; return 1; }

    _enrolled=0
    if [ -s "$ROOTFS/etc/crowdsec/online_api_credentials.yaml" ]; then
        _cst=$(ct $CSCLI console status 2>&1)
        if printf '%s\n' "$_cst" | grep -qiE "not registered|not enrolled|unauthorized|forbidden|invalid|revoked"; then
            log "[步骤3] console 凭据异常，仍备份本地配置"
        else
            log "[步骤3] console 状态有效"
            _enrolled=1
        fi
    else
        log "[步骤3] 未 enroll，只备份本地配置"
    fi

    mkdir -p "$SNAP_ETC" 2>/dev/null || { log "[步骤3] 无法创建 $SNAP_ETC"; return 1; }

    _bc=0
    for _rel in $( cd "$ROOTFS/etc/crowdsec" 2>/dev/null && find . -type f -name '*.yaml' 2>/dev/null | sed 's|^\./||' ); do
        case "$_rel" in *whitelists*) continue ;; esac
        _dst="$SNAP_ETC/$_rel"
        mkdir -p "$(dirname "$_dst")" 2>/dev/null
        cp -p "$ROOTFS/etc/crowdsec/$_rel" "$_dst" 2>/dev/null \
            && _bc=$((_bc+1)) \
            || log "[步骤3] 备份失败: $_rel"
    done
    log "[步骤3] 已备份 $_bc 个配置文件到 $SNAP_ETC"

    cat > "$STATE_FILE" <<EOF
VER=$SCRIPT_VER
TIME=$(date '+%F %T')
CONTAINER=$LXC_NAME
CONTAINER_IP=$CONTAINER_IP
BRIDGE_IP=$BRIDGE_IP
LAPI_PORT=$LAPI_PORT
BOUNCER_NAME=$_sname
BOUNCER_IP=$_sip
LAST_PULL=$_slp
API_URL=$(uci -q get "$_sec.api_url" 2>/dev/null)
UCI_SECTION=$_sec
ENROLLED=$_enrolled
EOF
    log "[步骤3] 稳定态标记已写入 $STATE_FILE"

    _bad=0
    for _rel in $( cd "$SNAP_ETC" 2>/dev/null && find . -type f -name '*.yaml' 2>/dev/null | sed 's|^\./||' ); do
        cmp -s "$ROOTFS/etc/crowdsec/$_rel" "$SNAP_ETC/$_rel" || _bad=1
    done
    [ "$_bad" -eq 0 ] \
        && log "[步骤3] 复验通过，配置与备份完全一致" \
        || log "[步骤3] 复验未过，仍有文件不一致"

    log "===== 步骤 3 完成 ====="
    return 0
}

main() {
    log "===== crowdsec-lxc-bootstrap v$SCRIPT_VER 开始（容器 $LXC_NAME）====="

    if [ ! -f "$TARBALL" ] && [ -f "$LEGACY_TARBALL" ]; then
        mkdir -p "$CS_HOME" 2>/dev/null && mv -f "$LEGACY_TARBALL" "$TARBALL" 2>/dev/null \
            && log "镜像已从 $LEGACY_TARBALL 迁移到 $TARBALL"
    fi

    if [ -f "$STATE_FILE" ] && [ -d "$SNAP_ETC" ]; then
        FIRST_BOOT=0
        log "检测到备份基线，进入恢复判定流程"
    else
        FIRST_BOOT=1
        log "首次开机：无备份基线，执行完整构建"
    fi

    step1_local; R1=$?

    if [ "$R1" = "0" ]; then
        step2_enroll; R2=$?
    else
        R2=1
    fi

    if [ "$R1" = "0" ]; then
        step3_backup; R3=$?
    else
        R3=1
    fi

    log "----- 汇总 -----"
    log "步骤1容器+本地=$R1 步骤2enroll=$R2 步骤3备份=$R3"

    _final_key=""
    _final_sec=$(uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
    [ -n "$_final_sec" ] && _final_key="$(uci -q get "$_final_sec.api_key" 2>/dev/null)"
    if [ -z "$_final_key" ]; then
        log "终局检查失败：api_key 仍为空"
        exit 1
    fi
    log "终局检查通过：api_key 已就绪（$R1$R2$R3）"
    exit 0
}

main "$@"
