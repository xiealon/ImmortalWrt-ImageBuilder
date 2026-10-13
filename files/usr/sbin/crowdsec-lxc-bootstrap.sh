#!/bin/sh
# =============================================================================
# /usr/sbin/crowdsec-lxc-bootstrap.sh
# 由 /etc/rc.local 后台拉起，每次开机跑一遍，幂等安全。
#
# 结构：每个大步骤只用一个 if——判定条件留在主流程，动作收进各自函数，
#       步骤1 与步骤2 完全分开，互不嵌套，保证阅读性。
#   前置  容器 config 校验（缺失或与模板不一致才 reconcile + 抠不支持键 + 强制 lxc.start.auto）
#         容器整体恢复（没在跑且 rootfs 目录整个缺失 → tarball 解压重建 + 快照恢复 + 启动复验）
#         容器侧健康验证 + 修复（rootfs/在跑/服务/LAPI，防止步骤1、2 空跑）
#   步骤1 step1_bootstrap()：创建 LXC 容器 + 注册 bouncer —— 本地，不联网
#         前置：本地 api（路由器侧 bouncer 配置）不存在才运行，存在则跳过
#   步骤2 step2_run()：控制台绑定 enroll             —— 远程 api，联网，必须等步骤1 完成
#         前置：ENROLL_KEY 存在才进入 if；内部条件1→6 顺序验证，
#         哪个失败就近修复哪个（修好立即复验），全部就绪才执行 enroll 动作；
#         任一条件最终无法满足则本轮放弃，直接落到收尾；
#         enroll 成功后必须复检通过才写 .enrolled 标记（绝不录入无效数据）
#   收尾  final_check()：本地链路心跳体检 + 文件/链路自检自愈（A文件/B配置文件/C认证/D端到端）+ nft 表
#   快照  snapshot_sync()：final_check 全过（状态健康）后，才把容器 /etc/crowdsec 全量 *.yaml
#         收集成快照存 $SNAPSHOT_DIR；之后每次开机检查一致性——不一致直接用备份覆盖容器
#         （备份即唯一真理，要改配置改 $SNAPSHOT_DIR/etc/crowdsec/ 下的文件，重启生效）。
#         容器整体丢失时由 snapshot_restore() 恢复（含 enroll 凭据）
# =============================================================================

LXC_NAME="${LXC_NAME:-ubuntu}"
LXC_PATH="${LXC_PATH:-/srv/lxc}"
ROOTFS="$LXC_PATH/$LXC_NAME/rootfs"
TARBALL="${TARBALL:-/opt/lxc-ubuntu.tar.gz}"
CONTAINER_IP="${CONTAINER_IP:-10.0.0.10}"
LAPI_PORT="${LAPI_PORT:-8080}"
BOUNCER_NAME="${BOUNCER_NAME:-openwrt-fw}"
# 运行后配置快照（编译期不打包任何配置，装机后由脚本自行收集）：
#   时机   final_check 全过（bouncer 身份核对通过 + 自检自愈完成）才收集，
#          即"第一次开机 → 脚本打入配置 → 状态健康 → 制作备份"链路的最后一环
#   内容  $SNAPSHOT_DIR/etc/crowdsec/ 镜像容器 /etc/crowdsec 全部 *.yaml：
#         出厂静态（config/profiles/simulations/acquis.d/parsers）+
#         运行时凭据（local/online_api_credentials.yaml，每台不同，丢了要重注册/重 enroll）
#   不同步 /etc/crowdsec/data/（socket/pid）、/var/lib/crowdsec/（database.db）等运行时状态
#   同步规则（单向：备份是唯一真理，cp -p 保留 mtime 不制造假差异）：
#         备份不存在/缺文件（首次建立）     → 从容器收集
#         容器缺文件、内容与备份不一致       → 一律用备份覆盖容器（含开机检查出的漂移）
#         完全一致                          → 零动作
#   修改入口：要改配置改 $SNAPSHOT_DIR/etc/crowdsec/ 下的文件，重启后覆盖进容器生效；
#         直接改容器内文件，下次开机健康体检后会被告知"与备份不一致"并被备份覆盖
SNAPSHOT_DIR="${SNAPSHOT_DIR:-/srv/lxc/crowdsec-baseline}"
SNAP_ETC="$SNAPSHOT_DIR/etc/crowdsec"
# 路由器在 lxcbr0 上的 IPv4：心跳体检的身份核对用——LAPI 记录的本机 bouncer
# 来源 IP 应等于它。探测失败留空则跳过核对（绝不因此误杀），不影响其他检查。
BRIDGE_IP=$(ip -4 addr show lxcbr0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -n1)
CSCLI=/usr/bin/cscli
MAX_WAIT="${MAX_WAIT:-60}"
SLEEP=5

SCRIPT_VER="2026-10-14.2"
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

# ---------- 运行后配置快照：一个大阶段，内部小步骤各自 if -----------
# 时机链：编译 → 装机 → 第一次开机 → 脚本打入配置 → final_check 全过（状态健康）
#         → snapshot_sync 收集/同步 → 之后每次开机检查一致性，不一致直接用备份覆盖。
# 同步规则（单向，备份即唯一真理；cp -p 保留 mtime 不制造假差异）：
#   小步骤1 快照根目录就绪？不在 → 建；建不好 return 1 本轮跳过
#   小步骤2 枚举两侧全部 *.yaml 分三类，哪个不对修哪个：
#             快照没有、容器有（首次建立/容器新增）→ 从容器收集
#             容器没有、快照有（被误删）           → 用备份补回容器
#             两侧都有但内容不一致                 → 一律用备份覆盖容器
#             内容一致                            → 零动作
#   小步骤3 修过才复验：重比对确认全部一致，容器在跑才 restart 生效
# 凭据说明：local/online_api_credentials.yaml 是运行时凭据，随健康态一起收集——
#   容器整体丢失后恢复（snapshot_restore）时凭据还在，bouncer/enroll 无需重做。
# 修改入口：要改配置改 $SNAPSHOT_DIR/etc/crowdsec/ 下的文件，重启后自动覆盖进容器；
#   直接改容器内文件，下次开机健康后会按"与备份不一致"被备份覆盖（日志会提示）。
snapshot_sync() {
    # ---- 小步骤1：快照根目录就绪（不在 → 建；建不好本轮跳过） ----
    if [ ! -d "$SNAP_ETC" ]; then
        mkdir -p "$SNAP_ETC" || { log "!! [快照] 创建 $SNAP_ETC 失败，本轮跳过快照"; return 1; }
        log "[快照] 首次创建快照目录 $SNAP_ETC（健康态收集，之后每次开机检查一致性并覆盖）"
    fi
    # 容器 /etc/crowdsec 不存在（rootfs 未解压）：无对象可收集
    [ -d "$ROOTFS/etc/crowdsec" ] || return 0

    _snap_changed=0
    # ---- 小步骤2：枚举两侧全部 *.yaml（含新增/删除），按"备份是否唯一真理"分类处理 ----
    {
        ( cd "$ROOTFS/etc/crowdsec" 2>/dev/null && find . -type f -name '*.yaml' 2>/dev/null )
        ( cd "$SNAP_ETC" 2>/dev/null && find . -type f -name '*.yaml' 2>/dev/null )
    } | sed 's|^\./||' | sort -u > /tmp/.cs-snap-list.$$
    while IFS= read -r _rel; do
        [ -n "$_rel" ] || continue
        _ct_f="$ROOTFS/etc/crowdsec/$_rel"
        _sn_f="$SNAP_ETC/$_rel"
        if [ -f "$_ct_f" ] && [ ! -f "$_sn_f" ]; then
            # 快照没有（首次建立备份或容器新增文件）→ 从容器收集
            mkdir -p "$(dirname "$_sn_f")"
            if cp -p "$_ct_f" "$_sn_f" 2>/dev/null; then
                log "[快照] 收集: $_rel"; _snap_changed=1
            else
                log "!! [快照] 收集失败: $_rel"
            fi
        elif [ ! -f "$_ct_f" ] && [ -f "$_sn_f" ]; then
            # 容器没有（被误删）→ 用备份补回容器
            mkdir -p "$(dirname "$_ct_f")"
            if cp -p "$_sn_f" "$_ct_f" 2>/dev/null; then
                log "[快照] 容器缺 $_rel，已从备份补回"; _snap_changed=1
            else
                log "!! [快照] 补回失败: $_rel"
            fi
        elif [ -f "$_ct_f" ] && [ -f "$_sn_f" ]; then
            if cmp -s "$_ct_f" "$_sn_f"; then
                continue   # 内容一致，零动作
            else
                # 两侧都有但不一致 → 一律用备份覆盖容器（备份是唯一真理）
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

    # ---- 小步骤3：修过才复验——重比对确认全部一致，容器在跑才 restart 生效 ----
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

# ---------- 前置：容器整体恢复（"容器不在了" ≠ "没在跑"） ----------
# 判定：没在跑 且 rootfs 整个目录缺失（lxc-destroy / 误删 / 刷机保留配置场景）。
#   只没在跑但 rootfs 在 → 归 precheck_container 的 P2 拉起，不在此列。
# 恢复动作（小步骤各自 if，哪个失败就地报告，不阻断后续）：
#   tarball 检查 → 解压 rootfs → 快照恢复 → 等网桥启动 → 复验在跑。
# 后续闭环：快照含 enroll 凭据与用户配置，恢复后步骤2 会凭 .enrolled 标记直接跳过；
#   无快照（首次健康前就丢了）则恢复成出厂态，bouncer 重注册由收尾自检 C2 兜底，
#   enroll 由步骤2 重连（旧一次性 key 失败时日志会提示去 app.crowdsec.net 重新生成）。
snapshot_restore() {
    [ -d "$SNAP_ETC" ] || { log "[快照] 无快照目录，跳过恢复（保持 tarball 出厂态）"; return 0; }
    [ -d "$ROOTFS/etc/crowdsec" ] || { log "!! [快照] rootfs 未解压，无法恢复快照"; return 1; }
    local _rel _sn_f _ct_f _restored=0
    # 只恢复快照里有的文件；tarball 出厂态里没有的新文件由快照补齐（含凭据）
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

container_restore() {
    log "[恢复] 容器不在（$ROOTFS 缺失），开始用 $TARBALL 整体恢复"
    # 小步骤1：备份 tarball 在？
    if [ ! -f "$TARBALL" ]; then
        log "!! [恢复] 缺 $TARBALL，无法恢复（从 release 下载放回 /opt/ 后重启）"
        return 1
    fi
    # 小步骤2：解压 rootfs
    mkdir -p "$ROOTFS"
    if ! tar -xzf "$TARBALL" -C "$ROOTFS"; then
        log "!! [恢复] 解压失败（$TARBALL 损坏？重新下载）"
        return 1
    fi
    log "[恢复] rootfs 已解压（$(du -sh "$ROOTFS" 2>/dev/null | cut -f1)）"
    # 小步骤3：新 rootfs 是出厂态，用快照恢复上次运行态（含凭据；无快照则保持出厂态）
    snapshot_restore || true
    # 小步骤4：等网桥 + 启动 + 复验（config 若也被删，随后主流程校验会重写再拉起）
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

# ---------- 前置：容器侧健康验证 + 修复（放在步骤1/2 前面，防止空跑） -----------
# 后面所有步骤都默认"容器就绪"；这里先把容器侧前提验证+修好：
#   P1 rootfs 已解压    —— 没解压属正常首次开机，交给步骤1，不算故障
#   P2 容器在跑         —— 没跑则等网桥后 lxc-start 拉起
#   P3 crowdsec active  —— 没起则 restart + 复验
#   P4 LAPI 就绪        —— 没监听则先等、再 restart + 复验
# 修不好不终止脚本：步骤1/2 内部各有等待与退出逻辑，收尾自检还会兜底。
precheck_container() {
    # P1 rootfs 未解压：正常首次开机，交给步骤1
    if [ ! -f "$ROOTFS/etc/crowdsec/config.yaml" ]; then
        log "[前置] rootfs 未解压（$ROOTFS），首次开机将由步骤1 解压"
        return 0
    fi
    # P2 容器在跑：没跑则等网桥后拉起
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
    # P3 crowdsec active：没起则 restart + 复验
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
    # P4 LAPI 就绪：没监听则先等、再 restart + 复验
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

# 定位路由器侧 bouncer 段 + 读取 enroll 密钥（仅读取，不做任何验证）
SEC=$(uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
ENROLL_KEY_FILE="/etc/config/crowdsec_enroll_key.txt"
ENROLL_KEY=""
[ -f "$ENROLL_KEY_FILE" ] && ENROLL_KEY="$(head -n1 "$ENROLL_KEY_FILE" | tr -d ' \t\r\n')"
ENROLL_FLAG="$ROOTFS/var/lib/crowdsec/.enrolled"
# 步骤2 门禁（remote_enroll_needed）写入的 enroll 原因：1=首次无凭据 / 2=被拒重连，
# step2_enroll 据此决定是否备份回滚旧凭据
ENROLL_REASON=1

# ---------- 前置：容器整体恢复（一个大 if：容器"不在了"才进） ----------
# "不在了"= 没在跑 且 rootfs 目录整个缺失；只没在跑归 P2 拉起，不在此列。
# 恢复失败不终止：config 校验/precheck/步骤1/收尾自检会继续兜底。
if ! ct_running && [ ! -d "$ROOTFS" ]; then
    container_restore || log "!! 容器恢复未完成（后续步骤与收尾自检继续兜底）"
fi

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

# ---------- 前置：容器侧健康验证 + 修复（防止步骤1/2 空跑） -----------
# rootfs 未解压时 precheck_container 内部直接放行（交给步骤1），
# 故这里无需再判 rootfs；config 在上面已保证存在
if [ -f "$CFG" ]; then
    precheck_container
fi

# ---------- 步骤1：创建 LXC 容器 + 注册 bouncer（本地，不联网）----------
# 前置判定：本地 api（bouncer 段 api_key 已写）不存在才运行。
# 全部动作收进 step1_bootstrap()：主流程只留一个 if，与步骤2 完全分开；
# 函数内失败一律 return 1（不是 exit），由调用处统一决定终止，保住阅读性。
step1_bootstrap() {
    local i KEY

    # 1.1 解压 rootfs（仅首次）
    if [ ! -f "$ROOTFS/etc/crowdsec/config.yaml" ]; then
        [ -f "$TARBALL" ] || { log "!! 缺少 $TARBALL，放弃引导"; return 1; }
        log "解压容器 rootfs..."
        mkdir -p "$ROOTFS"
        tar -xzf "$TARBALL" -C "$ROOTFS" || { log "!! 解压失败"; return 1; }
        log "解压完成"
        # 解压出来的是 tarball 出厂态；无快照时保持出厂态交给步骤1/2 引导，
        # 有快照时等 final_check 健康后由 snapshot_sync 双向同步（含覆盖修复）
    fi

    # 1.2 等网桥 + 启动容器（已就绪则跳过）
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

    # 1.3 等容器 IP 通（已通则跳过）
    if ! ping -c1 -W2 "$CONTAINER_IP" >/dev/null 2>&1; then
        i=0
        while [ $i -lt $MAX_WAIT ]; do
            ping -c1 -W2 "$CONTAINER_IP" >/dev/null 2>&1 && break
            i=$((i+1)); sleep $SLEEP
        done
        [ $i -lt $MAX_WAIT ] || { log "!! 容器 IP $CONTAINER_IP 不通，放弃"; return 1; }
    fi

    # 1.4 等本地 bouncers API（LAPI）就绪：直接探端点，比 bouncers list 快
    if ! lapi_ready; then
        i=0
        until lapi_ready; do
            i=$((i+1))
            [ $i -ge $MAX_WAIT ] && { log "!! LAPI 未就绪，放弃"; return 1; }
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

# ---------- 步骤2：控制台绑定 enroll（远程 API，联网）----------
# 背景（修复"网页端删了 API、设备内不删 → 重启不重连"）：
#   老逻辑只看 .enrolled 标记文件，而网页端删除 API 不会动设备内任何文件，
#   于是重启永远走"已绑定，跳过 enroll"，本地凭据变成服务端不认识的孤儿，
#   crowdsec 推送 signals 一直 401，控制台再也不刷新。
# 现在把步骤2 需要的验证全部写成条件链（step2_run 内，条件1→6 顺序验证，
# 哪个失败就近修复哪个，修好复验；全部就绪才 enroll）：
#   条件1 容器在跑          → 不在则 lxc-start 拉起 + 复验
#   条件2 ENROLL_KEY 在     → 一次性 key 无法自动生成，缺则本轮放弃
#   条件3 crowdsec active   → 不在则 restart + 复验
#   条件4 LAPI 就绪         → 不在则先等、再 restart + 复验
#   条件5 容器外网通        → 不通则本轮不判（凭据原样不动，下次开机再判）
#   条件6 凭据状态四态      → 0 有效(跳过) / 1 无凭据(首次 enroll) /
#                            2 被拒(备份后重连) / 5 cscli 执行失败(放弃本轮)
# 探测全部放在容器内跑（不是路由器侧）：容器走 NAT 出网，必须测 cscli
# 真正会走的那条路径（SNAT 配错时路由器通、容器不通）。

# 容器外网探测（步骤2 条件5）：任一 DNS 通即算在线。
# ICMP 被运营商封很常见，ping 不通只等于"这次不判"，绝不动凭据。
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

# 凭据状态判定（步骤2 条件6）：调用前须已确认外网通（net_online）与
# LAPI 就绪——本函数只回答"凭据在不在、服务端认不认"，四态：
#   0 = 凭据在且有效
#   1 = 本地无凭据文件（首次 enroll）
#   2 = 凭据被服务端拒绝（not registered / not enrolled / 401/403/unauthorized/invalid/revoked
#       或 Registered 字段为 false → 需重连）
#   5 = cscli 自身执行失败（输出为空/连不上 LAPI）
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

# enroll 成功后的复检：命令返回成功 ≠ 服务端认账。再跑一次凭据状态判定，
# 确认真的 registered/enrolled 才写 .enrolled 标记、才删备份——
# 确保绝不把无效数据录入标记文件。复检容忍瞬态（cscli 刚 restart 完还没起来，
# exit 5），最多重试 6 次；其余结论（0 有效 / 2 仍被拒）立即出。
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

# 回滚旧凭据（_CRED_BAK 由 step2_enroll 设置，dash 动态作用域可见）；
# 没有备份则什么都不做。回滚后 cscli bouncers 等本地功能不受影响。
rollback_cred() {
    [ -n "$_CRED_BAK" ] && [ -f "$_CRED_BAK" ] || return 0
    mv -f "$_CRED_BAK" "$ROOTFS/etc/crowdsec/online_api_credentials.yaml"
    log "已回滚旧凭据（cscli bouncers 等本地功能不受影响）"
}

# 步骤2 主函数：条件1→6 顺序验证，哪个失败就近修复哪个（修好立即复验），
# 全部就绪才调 step2_enroll 执行 enroll 动作；任一条件最终无法满足则
# return 1 本轮放弃，主流程自然落到收尾。
step2_run() {
    local _i _re
    # ---- 条件1：容器在跑（不在 → 拉起 + 复验） ----
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
    # ---- 条件2：ENROLL_KEY 在（一次性 key 无法自动生成，缺则本轮放弃） ----
    if [ -z "$ENROLL_KEY" ]; then
        log "!! [步骤2·条件2] 无 enroll 密钥，本轮放弃（去 app.crowdsec.net 生成，更新 $ENROLL_KEY_FILE）"
        return 1
    fi
    # ---- 条件3：crowdsec 服务 active（不在 → restart + 复验） ----
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
    # ---- 条件4：LAPI 就绪（不在 → 先等，再 restart + 复验） ----
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
    # ---- 条件5：容器外网通（不通 → 本轮不判，凭据原样不动） ----
    if ! net_online; then
        log "[步骤2·条件5] 外网不通，凭据不动，本轮不判（下次开机再判）"
        return 1
    fi
    # ---- 条件6：凭据状态（四态）→ 决定是否需要 enroll ----
    remote_enroll_state; _re=$?
    if [ "$_re" -eq 0 ]; then
        log "[步骤2·条件6] 远程 api 已绑定且有效，无需 enroll"
        return 0
    elif [ "$_re" -eq 5 ]; then
        log "!! [步骤2·条件6] console status 执行失败（cscli 异常），本轮放弃"
        return 1
    fi
    _ENROLL_REASON=$_re    # 1 = 首次无凭据 / 2 = 被拒重连
    # ---- 条件1~6 全部就绪 → 执行步骤2 动作 ----
    step2_enroll
}

# 步骤2 全部动作（进入此处 = step2_run 已确认条件1~6 就绪且需要 enroll）：
# 按 _ENROLL_REASON 决定备份与否 → enroll → 复检 → 录入/回滚。
step2_enroll() {
    local _CRED_BAK=""
    if [ "$_ENROLL_REASON" -eq 2 ]; then
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

# ---------- 步骤2 主流程：整个步骤在一个 if 结构里 -----------
# 有 ENROLL_KEY 才进入；内部条件1→6 顺序验证 + 就近修复 + 复验，
# 全部就绪才 enroll；任一条件最终无法满足则本轮放弃，直接落到收尾。
if [ -n "$ENROLL_KEY" ]; then
    step2_run
else
    log "未提供 enroll 密钥，跳过"
fi

# ---------- 收尾：本地 LAPI 链路体检（bouncer ↔ 容器 LAPI）----------
# 与远程 console status 判定对称：不只看静态字段，看动态心跳。
# 判据是 cscli bouncers inspect 的 last_pull —— LAPI 每次收到 bouncer 的
# pull 请求就自动刷新这个墙钟时间（RFC3339）。它新鲜 ⇒ 路由器→容器网络 +
# api_key 认证 + LAPI 服务三者全通。name/valid/type/auth_type 只是静态佐证。
# 多 bouncer 环境下的身份核对：inspect 按名单查（LAPI 的 name 唯一），
# 再要求记录的来源 IP 等于路由器 lxcbr0 桥 IP——坐实"这条就是我本机注册的"，
# 防止同名历史遗留/占名时张冠李戴。任一侧 IP 为空则不比对，只警告不修复。
# bouncer 默认约 10s 拉一次；开机后首次 pull 需要一点时间，这里只对
# "从未 pull"继续等（最多 60 秒），其他失败立即出结论，避免无谓空等。
local_lapi_state() {
    # $1 = bouncer 名，$2 = 路由器 lxcbr0 IPv4（可空）
    # 返回：0 健康 / 1 从未 pull / 2 pull 过久(>5min) / 3 已吊销 / 4 来源IP非本机 / 10 查不到
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

# ---------- 收尾：CrowdSec 文件与链路自检 + 自愈（每次开机） -----------
# 分四层，由静到动、从容器内到路由器侧，逐层体检，异常立即自愈：
#   A 层 静态文件：rootfs / 容器内配置与凭据文件是否齐全（路由器侧直接看）
#   B 层 容器内配置文件：config/crowdsec.yaml 在不在（纯报告；
#       服务/LAPI 的修复已在前置 precheck_container 做过，此处不重复修）
#   C 层 认证链路：cscli 能否加载本地凭据、bouncer 是否注册在 LAPI、hub 内容是否在
#   D 层 端到端：路由器侧 bouncer 进程、nft crowdsec 表
# 原则：能自动修的才修（重建凭据/重新注册 bouncer/补 hub）；
#       修不了的只报警（rootfs 损坏、缺 enroll key），绝不重新解压 rootfs、
#       绝不删数据，避免"自愈"变"自杀"。
selfcheck_repair() {
    local _i _nk _nc _f

    # ===== A 层：静态文件（路由器侧直接检查，不惊动容器） =====
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

    # ===== B 层：容器内配置文件（纯报告；服务/LAPI 修复已在前置做过） =====
    if ! ct_running; then
        log "!! [自检B] 容器未运行，跳过容器内自检"
    else
        for _f in config.yaml crowdsec.yaml; do
            ct sh -c "[ -f /etc/crowdsec/$_f ]" 2>/dev/null || \
                log "!! [自检B] 容器内缺 /etc/crowdsec/$_f"
        done

        # ===== C 层：认证链路 =====
        # online 凭据缺失时所有 cscli 命令都挂（require.LAPI 连带加载，实测报错），
        # 此时跳过 C 层：有 enroll key 的交给步骤2 重连，没有的只能人工补 key
        if ! ct sh -c '[ -s /etc/crowdsec/online_api_credentials.yaml ]' 2>/dev/null; then
            log "⚠️ [自检C] 容器缺 online_api_credentials.yaml，跳过 cscli 链路检查"
        else
            # C1 cscli 能否加载本地凭据（失败 → 重启 crowdsec 自动重建 local credentials）
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
            # C2 bouncer 是否注册在 LAPI（不在 → 重新 add + 同步 uci + 重启路由器侧 bouncer）
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
            # C3 hub 内容是否为空（collections 全丢 = 一条日志都不解析）
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

    # ===== D 层：路由器侧 bouncer 进程 + nft 表 =====
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

# ---------- 收尾：本地链路心跳体检 + 文件/服务自检自愈 -----------
# 心跳（local_lapi_state，动态活性 + 身份核对）与自检（selfcheck_repair，
# 静态文件/容器内配置/认证注册/端到端）收进同一个 final_check()，主流程只留一个 if。
# 注意：这里的检查与步骤1/2 的门禁验证不重复——门禁看"配置/注册在不在"，
# 心跳看"链路通不通"，自检看"缺什么补什么"，三者对象不同、各跑一次。
# 返回值即"本轮是否状态健康"（供快照收编判定）：
#   0 = 健康：已 enroll 且心跳 rc=0（bouncer 身份核对通过 + 正在拉取 decisions）
#   1 = 未就绪：未 enroll / 心跳异常 / rootfs 缺失——不收编快照，下次开机再试
final_check() {
    local _fc_hb=1
    # 心跳体检仅限已 enroll（online 凭据在）时：没 enroll 时 cscli 自身
    # 加载不了凭据，查了也是误报。只对"从未 pull"等待，其他立即出结论。
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
    # rootfs/容器侧硬缺失时心跳结论无意义，直接判未就绪
    [ -d "$ROOTFS/etc/crowdsec" ] || _fc_hb=1
    selfcheck_repair
    [ "$_fc_hb" -eq 0 ] && return 0 || return 1
}

# 仅当固件真的带了容器（rootfs 已解压）且 bouncer 段存在才收尾，
# 没勾 include_crowdsec 的固件不刷噪声日志
if [ -f "$ROOTFS/etc/crowdsec/config.yaml" ] && [ -n "$SEC" ]; then
    # 时机链最后一环：final_check 全过（状态健康、步骤全部成功）才收集/同步快照；
    # 未就绪则不收编也不覆盖——避免把半成品存成"备份"，下次开机健康后再处理
    if final_check; then
        snapshot_sync
    else
        log "⚠️ 收尾体检未全部通过，本轮不收集/不覆盖快照（下次开机状态健康后再处理）"
    fi
else
    log "rootfs 或 bouncer 段缺失，跳过 CrowdSec 自检"
fi

sleep 3
log "引导结束"
exit 0
