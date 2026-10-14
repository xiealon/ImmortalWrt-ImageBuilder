#!/bin/sh
# ==============================================================================
# crowdsec-lxc-bootstrap.sh  ——  CrowdSec + LXC 全自动引导（v5 架构）
#
# 设计原则（务必保持，改动前先读）：
#
#  1. 阶段 0「状态采集」把所有判定所需的数据一次性收集成 ST_* 全局变量。
#     之后每个大步骤只读自己关心的那几项 ST_*，各判各的，互不依赖。
#     好处：某个探测失败不会污染其他步骤的判断（历史 bug 就是
#     _s1_lapi 没置位导致后续步骤连锁跳过，密钥永远为空）。
#
#  2. 每个大步骤是一个独立的顶层 if —— 入口条件只判定「本步骤的前置」，
#     内部子步骤用小 if 各自判定。步骤之间通过 ST_* 传递结论，不互相 gate。
#
#  3. 五个大步骤：
#     步骤1  用本地镜像文件建立/修复 LXC 容器
#     步骤2  安装 crowdsec（镜像 yaml 内已预装，这里只做校验与按需修复）
#     步骤3  设置 crowdsec 功能：本地 LAPI、syslog 投递、bouncer list + api_key
#     步骤4  建立远程 enroll 链接（注册码用过即存，供后续开机复用）
#     步骤5  备份容器配置（仅在全部校验通过后才写备份）
#
#  4. 备份目录 /etc/crowdsec/ 下：
#        lxc-ubuntu.tar.gz   容器镜像（可从 /opt 迁移过来）
#        baseline/etc/...    稳定跑通后的容器配置快照
#        baseline/STATE      一份「校验通过」的标记，含 bouncer 名称/IP/last_pull
#     每次开机先校验本地 rootfs 与 baseline 的一致性，不一致用备份覆盖；
#     容器不存在、或覆盖后仍起不来，则直接用镜像重建 —— 保证持续稳定运行。
#
#  5. 首次开机没有 baseline，所有步骤通过后才创建备份。
# ==============================================================================

SCRIPT_VER="2026-10-14.6"

# ============================== 可调参数 ==============================
LXC_NAME="${LXC_NAME:-ubuntu}"
CS_HOME="${CS_HOME:-/etc/crowdsec}"                  # 集中存放镜像与备份
LXC_PATH="${LXC_PATH:-/srv/lxc}"
ROOTFS="$LXC_PATH/$LXC_NAME/rootfs"
CFG="$LXC_PATH/$LXC_NAME/config"
TARBALL="${TARBALL:-$CS_HOME/lxc-ubuntu.tar.gz}"
LEGACY_TARBALL="/opt/lxc-ubuntu.tar.gz"               # 兼容旧路径
BASELINE="$CS_HOME/baseline"
SNAP_ETC="$BASELINE/etc/crowdsec"
STATE_FILE="$BASELINE/STATE"
LAPI_PORT="${LAPI_PORT:-8080}"
BOUNCER_NAME="${BOUNCER_NAME:-openwrt-fw}"
ENROLL_KEY_FILE="${ENROLL_KEY_FILE:-/etc/config/crowdsec_enroll_key.txt}"
ENROLL_USED_FILE="$CS_HOME/enroll.used"              # 注册码使用记录（一次性码防重复消耗）
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

# ==============================================================================
# 权限自愈 —— 必须放在最前面
# ==============================================================================
# 这几个脚本在 git index 里是 100644，make image FILES= 原样打进固件 → 固件里是 644。
# 调用方全部用显式解释器（/etc/init.d/done 是 `sh /etc/rc.local`，uci-defaults 是 source），
# 所以不依赖可执行位；但这里再自愈一次，保证任何直接执行场景也正常。
case "$0" in
    /*) _SELF="$_0" ;;
    */*) _SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")" ;;
    *) _SELF="$(command -v "$0" 2>/dev/null)" ;;
esac
[ -n "$_SELF" ] && chmod +x "$_SELF" 2>/dev/null
chmod +x /etc/rc.local 2>/dev/null

log "===== crowdsec-lxc-bootstrap v$SCRIPT_VER 开始（容器 $LXC_NAME / 镜像 $TARBALL）====="

# ==============================================================================
# 基础工具函数
# ==============================================================================
ct() { lxc-attach -P "$LXC_PATH" -n "$LXC_NAME" -- "$@"; }
ct_running() { lxc-ls -P "$LXC_PATH" --running 2>/dev/null | grep -qw "$LXC_NAME"; }
ct_exists() { lxc-info -P "$LXC_PATH" -n "$LXC_NAME" >/dev/null 2>&1; }

# pgrep -x 在 Linux 上按 /proc/<pid>/comm 匹配，comm 上限 15 字节。
# "crowdsec-firewall-bouncer" 有 26 字符，-x 永远匹配不到 → 必须用 -f 匹配全命令行。
_pgrep_bouncer() { pgrep -f "crowdsec-firewall-bouncer" >/dev/null 2>&1; }

# lxc-attach 不保证传递宿主 PATH，容器内一律用绝对路径 + 显式 PATH
_ct_env() {
    ct sh -c 'export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; '"$1"
}

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
    # _wait <描述> <探测函数名> [最大轮数]
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
_wait_ping() {
    _wp() { ping -c1 -W2 "$CONTAINER_IP" >/dev/null 2>&1; }
    _wait "容器IP" _wp
}
_wait_bridge() {
    _wb() { ip link show lxcbr0 >/dev/null 2>&1; }
    _wait "网桥" _wb
}

# ==============================================================================
# 步骤 1 用的写盘 / 一致性比对
# ==============================================================================
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

# 写容器 config 并逐条剔除 LXC 不支持的键（不同版本支持的键不同）
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

# 容器 rootfs 与 baseline 快照的一致性检查；不一致则用备份覆盖
# 用法：sync_from_baseline  → 打印被覆盖的文件数，返回 0=一致/已恢复
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
        case "$_rel" in
            *whitelists*) continue ;;   # 运行时会被移除，不纳入一致性比对
        esac
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
                && { log "[步骤1] 配置与备份不一致，已覆盖: $_rel（要改配置请改 $SNAP_ETC/$_rel）"; _sb_changed=1; } \
                || log "[步骤1] !! 覆盖失败: $_rel"
        fi
    done < "$_sb_list"
    rm -f "$_sb_list"
    return "$_sb_changed"
}

# 用镜像彻底重建容器（rootfs 损坏 / 覆盖后仍起不来时的最后手段）
rebuild_from_image() {
    log "[步骤1] 尝试从镜像重建容器 rootfs：$TARBALL"
    [ -f "$TARBALL" ] || { log "[步骤1] !! 镜像文件不存在，无法重建"; return 1; }
    ct_running && lxc-stop -P "$LXC_PATH" -n "$LXC_NAME" -k -f >/dev/null 2>&1
    sleep 2
    rm -rf "$ROOTFS" 2>/dev/null
    mkdir -p "$ROOTFS" || return 1
    # 解压锁：并发实例只有一个能真正解 tar
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

# ==============================================================================
# 阶段 0：状态采集 —— 一次性收集所有判定所需数据
# ==============================================================================
collect_state() {
    log "----- 阶段 0：状态采集 -----"

    # 镜像：优先 CS_HOME，其次兼容旧的 /opt
    if [ ! -f "$TARBALL" ] && [ -f "$LEGACY_TARBALL" ]; then
        if mkdir -p "$CS_HOME" 2>/dev/null && mv -f "$LEGACY_TARBALL" "$TARBALL" 2>/dev/null; then
            log "[采集] 已把镜像从 $LEGACY_TARBALL 迁移到 $TARBALL"
        else
            log "[采集] 旧镜像 $LEGACY_TARBALL 迁移失败，仍按 $TARBALL 判定"
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

    # 后续步骤各自需要的原始数据，一次性取出
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
# 步骤 1：用本地镜像文件建立 / 修复 LXC 容器
# ==============================================================================
step1_container() {
    log "===== 步骤 1：建立/修复 LXC 容器 ====="
    local _r=1

    if [ "$ST_IMAGE" = "0" ] && [ "$ST_ROOTFS" = "0" ]; then
        log "[步骤1] 无镜像且无 rootfs，无法建立容器 —— 本机不带 CrowdSec，跳过全部后续步骤"
        return 1
    fi

    # ---- 1.1 首次建立 ----
    if [ "$ST_ROOTFS" = "0" ]; then
        if rebuild_from_image; then
            ST_ROOTFS=1
        else
            log "[步骤1] !! 首次解压失败"
            return 1
        fi
    else
        log "[步骤1] rootfs 已存在"
    fi

    # ---- 1.2 配置一致性：与 baseline 不符则覆盖 ----
    if [ "$ST_BASE" = "1" ]; then
        sync_from_baseline
        _sr=$?
        if [ "$_sr" = "0" ]; then
            log "[步骤1] 配置与备份一致"
        else
            log "[步骤1] 配置已按备份校正（改动数标记）"
            ct_running && _ct_env 'systemctl restart crowdsec >/dev/null 2>&1' || true
            sleep 3
        fi
    else
        log "[步骤1] 首次开机无备份，跳过一致性校验（全部通过后才会创建备份）"
    fi

    # ---- 1.3 容器 config ----
    if [ "$ST_CFG_OK" = "0" ] || ! apply_cfg; then
        log "[步骤1] 重写容器 config"
        mkdir -p "$LXC_PATH/$LXC_NAME" 2>/dev/null
        if apply_cfg; then
            ST_CFG_OK=1
        else
            log "[步骤1] !! config 仍无法解析（人工查：lxc-info -P $LXC_PATH -n $LXC_NAME）"
            return 1
        fi
    else
        log "[步骤1] 容器 config 正常"
    fi

    # ---- 1.4 网桥 ----
    if [ "$ST_BRIDGE_OK" = "0" ]; then
        log "[步骤1] 等待 lxcbr0 网桥..."
        if _wait_bridge; then
            ST_BRIDGE_OK=1
            ST_BRIDGE_IP=$(ip -4 addr show lxcbr0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -n1)
            log "[步骤1] 网桥就绪 ($ST_BRIDGE_IP)"
        else
            log "[步骤1] !! lxcbr0 未出现（查 network.lxc 是否配置生效）"
        fi
    else
        log "[步骤1] 网桥就绪 ($ST_BRIDGE_IP)"
    fi

    # ---- 1.5 拉起容器 ----
    if ct_running; then
        log "[步骤1] 容器已在运行"
    else
        log "[步骤1] 启动容器..."
        lxc-start -P "$LXC_PATH" -n "$LXC_NAME" -d 2>/dev/null
        if _wait_ct_running; then
            log "[步骤1] 容器已启动"
        else
            # ---- 1.6 起不来 → 重建后重试 ----
            log "[步骤1] !! 容器起不来，尝试重建后再试"
            if rebuild_from_image && apply_cfg; then
                lxc-start -P "$LXC_PATH" -n "$LXC_NAME" -d 2>/dev/null
                _wait_ct_running \
                    && log "[步骤1] 重建后容器已启动" \
                    || { log "[步骤1] !! 重建后仍起不来（查 lxc-start 报错）"; return 1; }
            else
                log "[步骤1] !! 重建失败"
                return 1
            fi
        fi
    fi

    ST_CT_RUNNING=1
    _r=0
    log "===== 步骤 1 完成 ====="
    return $_r
}

# ==============================================================================
# 步骤 2：安装 crowdsec（镜像 yaml 内已预装，这里只校验 + 按需修复）
# ==============================================================================
step2_install_crowdsec() {
    log "===== 步骤 2：校验 crowdsec 安装状态 ====="

    # ---- 2.1 服务是否 active ----
    if ct_crowdsec_active; then
        log "[步骤2] crowdsec 服务 active"
    else
        log "[步骤2] crowdsec 未 active，重启"
        _ct_env 'systemctl restart crowdsec >/dev/null 2>&1' || true
        _wait_ct_crowdsec() { ct_crowdsec_active; }
        _wait "crowdsec" _wait_ct_crowdsec 12 \
            && log "[步骤2] 服务已就绪" \
            || { log "[步骤2] !! 服务仍未 active（查容器内 journalctl -u crowdsec）"; return 1; }
    fi

    # ---- 2.2 配置完整性：镜像内已预装 yaml，这里校验关键项 ----
    if [ ! -f "$CROWDSEC_CFG" ]; then
        log "[步骤2] !! 容器内无 /etc/crowdsec/config.yaml，镜像不完整"
        return 1
    fi
    if grep -q "listen_uri: 0.0.0.0:$LAPI_PORT" "$CROWDSEC_CFG" 2>/dev/null; then
        log "[步骤2] LAPI 已配置对外监听 0.0.0.0:$LAPI_PORT"
    else
        log "[步骤2] !! listen_uri 未对外监听，bouncer 连不上（检查 prepare-crowdsec-rootfs.sh）"
        return 1
    fi
    if grep -q "$ST_BRIDGE_IP" "$CROWDSEC_CFG" 2>/dev/null; then
        log "[步骤2] trusted_ips 含桥接地址 $ST_BRIDGE_IP"
    else
        log "[步骤2] ⚠️ trusted_ips 未含 $ST_BRIDGE_IP（bouncer 靠 api_key 认证，通常不影响）"
    fi

    # ---- 2.3 syslog 投递配置在路由器侧（99-custom.sh 已写），这里确认 ----
    if uci -q get system.@system[0].log_ip | grep -q .; then
        log "[步骤2] 路由器 syslog 目标: $(uci -q get system.@system[0].log_ip):$(uci -q get system.@system[0].log_port)"
    else
        log "[步骤2] ⚠️ 路由器 syslog 外发未配置，容器收不到日志源"
    fi

    # ---- 2.4 hub 索引 / 场景库 ----
    _ncoll=$(_ct_env "$CSCLI collections list -o json 2>/dev/null | grep -c '"name"'")
    if [ "${_ncoll:-0}" -gt 0 ] 2>/dev/null; then
        log "[步骤2] 场景库已就绪（$_ncoll 个 collection）"
    else
        log "[步骤2] 场景库为空，执行 hub update + upgrade"
        _ct_env "$CSCLI hub update >/dev/null 2>&1" || true
        _ct_env "$CSCLI hub upgrade >/dev/null 2>&1" || true
        _ncoll=$(_ct_env "$CSCLI collections list -o json 2>/dev/null | grep -c '"name"'")
        [ "${_ncoll:-0}" -gt 0 ] 2>/dev/null \
            && log "[步骤2] 场景库已补齐（$_ncoll 个）" \
            || log "[步骤2] ⚠️ 场景库仍为空（查容器网络与 hub 索引）"
    fi

    log "===== 步骤 2 完成 ====="
    return 0
}

# ==============================================================================
# 步骤 3：设置 crowdsec 功能 —— 本地 LAPI + bouncer list + api_key
# ==============================================================================
step3_setup_crowdsec() {
    log "===== 步骤 3：设置本地 API 与 bouncer ====="

    # ---- 3.1 容器 IP 可达 ----
    if ping -c1 -W2 "$ST_CT_IP" >/dev/null 2>&1 || _wait_ping; then
        log "[步骤3] 容器 IP $ST_CT_IP 可达"
    else
        log "[步骤3] !! 容器 IP $ST_CT_IP 不通（查容器网络/netplan 与网桥）"
        return 1
    fi

    # ---- 3.2 本地 LAPI 就绪（只等本步骤，不牵连其他步骤）----
    if lapi_ready; then
        log "[步骤3] 本地 API（LAPI :$LAPI_PORT）已就绪"
    elif _wait_lapi; then
        log "[步骤3] 本地 API 已就绪"
    else
        log "[步骤3] LAPI 未就绪，重启 crowdsec 再等一次"
        _ct_env 'systemctl restart crowdsec >/dev/null 2>&1' || true
        if _wait_lapi; then
            log "[步骤3] 重启后 LAPI 已就绪"
        else
            log "[步骤3] !! LAPI 仍未监听（查容器内 systemctl status crowdsec）"
            return 1
        fi
    fi

    # ---- 3.3 bouncer 段存在性（配置文件本身缺失要响亮报错）----
    if [ "$ST_CROWDSECCFG" = "0" ]; then
        log "[步骤3] !! /etc/config/crowdsec 不存在 —— crowdsec-firewall-bouncer 包未装进固件，无法写入 api_key"
        return 1
    fi
    if [ -z "$ST_SEC" ]; then
        uci add crowdsec bouncer >/dev/null 2>&1
        ST_SEC=$(uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
    fi
    if [ -z "$ST_SEC" ]; then
        log "[步骤3] !! 无法创建 bouncer 配置段，api_key 无处可写"
        return 1
    fi

    # ---- 3.4 bouncer 在册 + 本地 key 的双重判定 ----
    if ct $CSCLI bouncers list 2>/dev/null | grep -qw "$BOUNCER_NAME" && [ -n "$ST_UCI_KEY" ]; then
        log "[步骤3] bouncer '$BOUNCER_NAME' 在册且本地 key 完整"
        if [ "$ST_UCI_URL" != "$ST_API_URL_WANT" ]; then
            uci set "$ST_SEC.api_url=$ST_API_URL_WANT"
            uci commit crowdsec
            log "[步骤3] api_url 已校正为 $ST_API_URL_WANT"
        else
            log "[步骤3] api_url 正确，跳过重新注册"
        fi
    else
        # 在册但本地无 key —— 历史 bug 面，明确记录并强制重注册
        if ct $CSCLI bouncers list 2>/dev/null | grep -qw "$BOUNCER_NAME"; then
            log "[步骤3] !! bouncer 在册但本地 api_key 为空，强制重新注册"
        else
            log "[步骤3] LAPI 中无 bouncer '$BOUNCER_NAME'，执行注册"
        fi

        # 移除白名单解析器会触发重启，LAPI 会短暂消失
        if ct $CSCLI parsers list 2>/dev/null | grep -q 'crowdsecurity/whitelists'; then
            ct $CSCLI parsers remove crowdsecurity/whitelists --force >/dev/null 2>&1 || true
            _ct_env 'systemctl restart crowdsec >/dev/null 2>&1' || true
            _wait_lapi || true
        fi

        ct $CSCLI bouncers delete "$BOUNCER_NAME" >/dev/null 2>&1 || true
        # 只取形如 key 的片段，避免把 lxc-attach 的杂项输出粘进 api_key
        _KEY=$(ct $CSCLI bouncers add "$BOUNCER_NAME" -o raw 2>/dev/null \
               | sed -e 's/\r$//' | grep -Eo '[A-Za-z0-9+/=_-]{16,}' | tail -n1)
        if [ -z "$_KEY" ]; then
            sleep 3
            ct $CSCLI bouncers delete "$BOUNCER_NAME" >/dev/null 2>&1 || true
            _KEY=$(ct $CSCLI bouncers add "$BOUNCER_NAME" -o raw 2>/dev/null \
                   | sed -e 's/\r$//' | grep -Eo '[A-Za-z0-9+/=_-]{16,}' | tail -n1)
        fi
        if [ -z "$_KEY" ]; then
            log "[步骤3] !! 两次生成 bouncer key 都失败，api_key 未写入"
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
        log "[步骤3] bouncer 注册成功，api_key 已写入 $ST_SEC"
    fi

    # ---- 3.5 验证 bouncer list 有确定输出（名称 / IP / last_pull）----
    _vout=$(ct $CSCLI bouncers inspect "$BOUNCER_NAME" -o raw 2>/dev/null)
    if [ -z "$_vout" ]; then
        log "[步骤3] ⚠️ bouncers inspect 无输出，稍后再查"
    else
        _vname=$(printf '%s\n' "$_vout" | sed -n 's/^[[:space:]]*name:[[:space:]]*//p' | head -n1)
        _vip=$(printf '%s\n' "$_vout" | sed -n 's/^[[:space:]]*ip_address:[[:space:]]*//p' | head -n1)
        _vlp=$(printf '%s\n' "$_vout" | sed -n 's/^[[:space:]]*last_pull:[[:space:]]*//p' | head -n1)
        log "[步骤3] bouncers list 校验 → 名称=${_vname:-?} IP=${_vip:-?} last_pull=${_vlp:-?}"
        [ -n "$_vname" ] || log "[步骤3] ⚠️ bouncer 名称读不到"
        [ -n "$_vip" ]   || log "[步骤3] ⚠️ 来源 IP 读不到"
        [ -n "$_vlp" ]   || log "[步骤3] ⚠️ last_pull 为空 —— bouncer 尚未拉取 decisions"
    fi

    # ---- 3.6 本地保护（宿主侧 bouncer 服务 + nft 表）----
    _ensure_bouncer_service
    if cs_active_on_host && nft_table_ready; then
        log "[步骤3] 本地保护已建立（bouncer 运行中 + nftables crowdsec 表就绪）"
    else
        log "[步骤3] ⚠️ 本地保护未完全建立（进程或 nft 表缺失），已重启 bouncer，稍后复查"
        service crowdsec-firewall-bouncer restart 2>/dev/null || true
        sleep 3
        cs_active_on_host && nft_table_ready \
            && log "[步骤3] 重启后本地保护已建立" \
            || log "[步骤3] !! 仍无 nft crowdsec 表（查 bouncer 日志与 deny_action）"
    fi

    log "===== 步骤 3 完成 ====="
    return 0
}

# ==============================================================================
# 步骤 4：建立远程 enroll 链接
# ==============================================================================
step4_remote_enroll() {
    log "===== 步骤 4：远程 enroll ====="

    # ---- 4.1 网络 ----
    if net_online; then
        log "[步骤4] 外网可达"
    else
        log "[步骤4] 外网不通，本轮不判 enroll（下次开机再试）"
        return 1
    fi

    # ---- 4.2 当前凭据状态 ----
    _rst() {
        _ct_env '[ -s /etc/crowdsec/online_api_credentials.yaml ] || exit 1
                  /usr/bin/cscli console status 2>&1' 2>/dev/null
    }
    _console_status() { _rst; }

    _out=$(_console_status); _rc=$?
    if [ "$_rc" -eq 0 ] && [ -n "$_out" ]; then
        if printf '%s\n' "$_out" | grep -qiE "not registered|not enrolled|unauthorized|forbidden|invalid|revoked"; then
            log "[步骤4] 远程 API 已失效（网页端删除/密钥被撤），需重新 enroll"
            _need=2
        else
            log "[步骤4] 远程 API 已绑定且有效"
            printf '%s\n' "$_out" | sed -n '1,6p' | while IFS= read -r _l; do log "[步骤4]   $_l"; done
            return 0
        fi
    else
        log "[步骤4] 无凭据或 console status 异常，判定为需要 enroll"
        _need=1
    fi

    # ---- 4.3 注册码：一次性，用过就记下来 ----
    if [ -z "$ST_ENROLL_KEY" ]; then
        if [ -s "$ENROLL_USED_FILE" ] && [ "$_need" = "1" ]; then
            log "[步骤4] 注册码已用尽（一次性），去 app.crowdsec.net 重新生成后写入 $ENROLL_KEY_FILE"
            return 1
        fi
        log "[步骤4] 未配置注册码，跳过（写入 $ENROLL_KEY_FILE 后下次开机生效）"
        return 1
    fi
    if [ -s "$ENROLL_USED_FILE" ] && [ "$(head -n1 "$ENROLL_USED_FILE")" = "$ST_ENROLL_KEY" ] && [ "$_need" = "1" ]; then
        log "[步骤4] 该注册码上次已用过且 enroll 未成功，不再重复消耗（去 app.crowdsec.net 换新码）"
        return 1
    fi

    # ---- 4.4 凭据失效则先备份旧的（保留本地 bouncer 可用）----
    _CRED_BAK=""
    if [ "$_need" = "2" ]; then
        _CRED_BAK="$ROOTFS/etc/crowdsec/online_api_credentials.yaml.bak"
        mv -f "$ROOTFS/etc/crowdsec/online_api_credentials.yaml" "$_CRED_BAK" 2>/dev/null || true
        log "[步骤4] 旧凭据已备份到 .bak"
    fi

    # ---- 4.5 执行 enroll ----
    if ! _ct_env "/usr/bin/cscli console enroll $ST_ENROLL_KEY >/dev/null 2>&1"; then
        [ -n "$_CRED_BAK" ] && mv -f "$_CRED_BAK" "$ROOTFS/etc/crowdsec/online_api_credentials.yaml"
        mkdir -p "$CS_HOME" 2>/dev/null
        printf '%s\n' "$ST_ENROLL_KEY" > "$ENROLL_USED_FILE" 2>/dev/null
        log "[步骤4] !! enroll 失败（注册码是一次性的，已记入 $ENROLL_USED_FILE；需去 app.crowdsec.net 重新生成）"
        return 1
    fi

    # ---- 4.6 注册后复检（不通过则回滚，不污染本地功能）----
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
        log "[步骤4] ✅ 控制台绑定完成（复检确认）—— 记得回 app.crowdsec.net 点 Accept"
    else
        [ -n "$_CRED_BAK" ] && mv -f "$_CRED_BAK" "$ROOTFS/etc/crowdsec/online_api_credentials.yaml"
        log "[步骤4] !! enroll 后复检未通过，已回滚旧凭据（本地 bouncer 不受影响）"
        return 1
    fi

    log "===== 步骤 4 完成 ====="
    return 0
}

net_online() {
    _ct_env '[ -x /bin/ping ] && { ping -c1 -W3 233.5.5.5 >/dev/null 2>&1 || ping -c1 -W3 119.29.29.29 >/dev/null 2>&1; } && exit 0
              [ -x /usr/bin/curl ] && curl -s -m 8 -o /dev/null https://api.crowdsec.net 2>/dev/null && exit 0
              exit 1' 2>/dev/null
}

# ==============================================================================
# 步骤 5：备份容器配置（仅在步骤 1-4 全部校验通过后才写）
# ==============================================================================
step5_backup() {
    log "===== 步骤 5：备份容器配置 ====="

    # ---- 5.1 备份前的健康门禁：不健康绝不覆盖已有备份 ----
    _hp=1
    [ -n "$ST_UCI_KEY" ] || { log "[步骤5] !! api_key 为空，拒绝备份"; return 1; }

    _sout=$(ct $CSCLI bouncers inspect "$BOUNCER_NAME" -o raw 2>/dev/null)
    _sname=$(printf '%s\n' "$_sout" | sed -n 's/^[[:space:]]*name:[[:space:]]*//p' | head -n1)
    _sip=$(printf '%s\n' "$_sout" | sed -n 's/^[[:space:]]*ip_address:[[:space:]]*//p' | head -n1)
    _slp=$(printf '%s\n' "$_sout" | sed -n 's/^[[:space:]]*last_pull:[[:space:]]*//p' | head -n1)
    _srvk=$(printf '%s\n' "$_sout" | sed -n 's/^[[:space:]]*revoked:[[:space:]]*//p' | head -n1)

    [ -n "$_sname" ] || { log "[步骤5] !! bouncer 名称读不到，拒绝备份"; return 1; }
    [ -n "$_sip" ]   || { log "[步骤5] !! bouncer 来源 IP 读不到，拒绝备份"; return 1; }
    [ -n "$_slp" ]   || { log "[步骤5] !! last_pull 为空（bouncer 未拉取 decisions），拒绝备份"; return 1; }
    [ "$_srvk" = "false" ] || { log "[步骤5] !! bouncer 已吊销，拒绝备份"; return 1; }

    if [ "$ST_ENROLL_CRED" = "1" ]; then
        _cst=$(ct $CSCLI console status 2>&1)
        if printf '%s\n' "$_cst" | grep -qiE "not registered|not enrolled|unauthorized|forbidden|invalid|revoked"; then
            log "[步骤5] ⚠️ console status 显示凭据异常，仍会备份配置（本地功能可用）"
        else
            log "[步骤5] console status 有效"
        fi
    else
        log "[步骤5] 未 enroll（无凭据），只备份本地配置"
    fi

    # ---- 5.2 写快照 ----
    if ! mkdir -p "$SNAP_ETC" 2>/dev/null; then
        log "[步骤5] !! 无法创建 $SNAP_ETC"
        return 1
    fi
    _bc=0
    for _rel in $( cd "$ROOTFS/etc/crowdsec" 2>/dev/null && find . -type f -name '*.yaml' 2>/dev/null | sed 's|^\./||' ); do
        case "$_rel" in *whitelists*) continue ;; esac
        _dst="$SNAP_ETC/$_rel"
        mkdir -p "$(dirname "$_dst")" 2>/dev/null
        cp -p "$ROOTFS/etc/crowdsec/$_rel" "$_dst" 2>/dev/null \
            && _bc=$((_bc+1)) \
            || log "[步骤5] !! 备份失败: $_rel"
    done
    log "[步骤5] 已备份 $_bc 个配置文件到 $SNAP_ETC"

    # ---- 5.3 写 STATE 标记（记录校验通过的现场，供下次开机比对）----
    cat > "$STATE_FILE" <<EOF
# crowdsec 稳定态标记 —— 由 crowdsec-lxc-bootstrap.sh 自动生成
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
    log "[步骤5] 稳定态标记已写入 $STATE_FILE"

    # ---- 5.4 复验 ----
    _bad=0
    for _rel in $( cd "$SNAP_ETC" 2>/dev/null && find . -type f -name '*.yaml' 2>/dev/null | sed 's|^\./||' ); do
        cmp -s "$ROOTFS/etc/crowdsec/$_rel" "$SNAP_ETC/$_rel" || _bad=1
    done
    [ "$_bad" -eq 0 ] \
        && log "[步骤5] ✅ 复验通过，配置与备份完全一致" \
        || log "[步骤5] !! 复验未过，仍有文件不一致（查 rootfs 权限/空间）"

    log "===== 步骤 5 完成 ====="
    return 0
}

# bouncer 本地服务：只有真没起来才重启，重启后复查再报告
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
        log "[bouncer] ⚠️ 重启后仍未就绪（查 /etc/init.d/crowdsec-firewall-bouncer 与 uci 配置）"
    fi
    return 0
}

# ==============================================================================
# 主流程：五个大步骤各自独立判定，互不 gate
# ==============================================================================
main() {
    collect_state

    step1_container;  R1=$?
    step2_install_crowdsec; R2=$?
    step3_setup_crowdsec;   R3=$?
    step4_remote_enroll;    R4=$?
    step5_backup;           R5=$?

    log "----- 汇总 -----"
    log "步骤1 容器=$R1  步骤2安装=$R2  步骤3设置=$R3  步骤4enroll=$R4  步骤5备份=$R5"

    # 终局门禁：只认「本地 uci api_key 非空」这一个标准
    _final_key=""
    _final_sec=$(uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
    [ -n "$_final_sec" ] && _final_key="$(uci -q get "$_final_sec.api_key" 2>/dev/null)"
    if [ -z "$_final_key" ]; then
        log "!! 终局检查：api_key 仍为空"
        log "   排查顺序：① /etc/config/crowdsec 是否存在（bouncer 包是否装进固件）"
        log "            ② 容器是否在跑：lxc-ls -P $LXC_PATH --running"
        log "            ③ LAPI 是否监听：lxc-attach -P $LXC_PATH -n $LXC_NAME -- ss -ltn | grep $LAPI_PORT"
        log "            ④ 完整日志：/root/crowdsec-lxc-bootstrap.log"
        exit 1
    fi
    log "✅ 终局检查通过：api_key 已就绪（$R1$R2$R3$R4$R5）"
    exit 0
}

main "$@"
