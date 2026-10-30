#!/bin/sh
# pkg-restore-smartdns.sh — smartdns 专用恢复
#
# 为什么单独一份：通用恢复只管「包在不在」，smartdns 还多两块状态，通用路径修不了。
#
#   ① /etc/smartdns/ 下的规则文件
#      address.conf / blacklist-ip.conf / custom.conf / domain-block.list /
#      domain-forwarding.list —— 它们在 conffiles 里，通用恢复按「不覆盖用户配置」
#      一律跳过。可文件真没了的时候，那条保护就退化成「永远不修」：
#      真机 2026-10-28 就是这么挂的 —— smartdns: open config file
#      '/etc/smartdns/address.conf' failed -> procd 记 crash loop -> 53 端口全空 ->
#      探针判进程不在 -> 重跑 bootstrap -> 再挂，死循环。
#      这里单独开口子，判据是「不存在才补」：存在就一律不动，哪怕被清成 0 字节。
#
#   ② LuCI 界面 luci-app-smartdns（menu.d + smartdns-call）
#      纯前端包，无二进制、无 init。只调单包恢复、不递归 —— 它的 Depends 里有
#      luci-base，递归会一路碰 rpcd / ubus / ucode 一大片基础系统，那是砸系统。
#
#   ③ uci 配置（主段 + 13 条写死上游）
#      2026-10-29 起从 bootstrap 整段搬来。bootstrap 只保留六件事：网络配置（含防火墙）、
#      网桥配置、容器网络配置、lxc 与 bouncer 恢复、crowdsec 容器恢复、
#      crowdsec 与 bouncer 的本地联动配置。smartdns 归本脚本 + 探针。
#      dnsmasq 让出 53 不在这里做：port=53 且 auto_set_dnsmasq=1 时由 smartdns
#      的 init 自己完成（见下方「不再手动让位」那段的依据）。53 只归 smartdns，
#      失败也不回滚给 dnsmasq（v.180.198，用户 2026-10-31 定）。
#      判据是「验证包在位就写」，不逐项比对配置差异 —— 上游表写死，
#      覆盖式写入。副作用：在 LuCI 里手改的上游会被下一轮冲掉（与原
#      bootstrap 的 build_smartdns_upstream 行为一致）。
#      注意：--config 直接用系统的 uci，不吃 PKGROOT，只对真机生效。
#
# 用法：
#   pkg-restore-smartdns.sh              全量：本体 + 依赖 + /etc/smartdns + 界面
#   pkg-restore-smartdns.sh --check      只判服务生效（pidof + 53 端口），0=生效
#   pkg-restore-smartdns.sh --check-pkg  只判包在不在（二进制 + init），0=在
#   pkg-restore-smartdns.sh --pkg        只装本体（含依赖树）
#   pkg-restore-smartdns.sh --conf       只补 /etc/smartdns/ 规则文件
#   pkg-restore-smartdns.sh --luci       只补界面
#   pkg-restore-smartdns.sh --config     写 uci 配置（主段 + 13 条写死上游）并 commit/重启 smartdns
#                                        （dnsmasq 让位由 smartdns 的 init 自动完成，本脚本不碰 dhcp）
#   pkg-restore-smartdns.sh --repair     整体自愈：装包 + 规则文件 + 配置 + 重启（探针用）
#
# 环境变量：ROMDIR（默认 /rom）、PKGROOT（默认空）、RESTORE_BIN（默认 pkg-restore.sh）
#
# 退出码：0 成功或本来就不缺 / 1 失败 / 2 用法错误

set -u
ROMDIR="${ROMDIR:-/rom}"
PKGROOT="${PKGROOT:-}"

# 通用恢复脚本的查找顺序（v.180.147）：
#   ① 显式 RESTORE_BIN
#   ② /usr/sbin/pkg-restore.sh —— 固件里的正式位置
#   ③ 与本脚本同目录 —— 两个脚本一起被拷到 /tmp 单独验时的情况。
#      写死 ② 的后果在 2026-10-29 真机暴露过：从 /tmp 跑这个脚本，
#      _sd_pkg 直接报「找不到 /usr/sbin/pkg-restore.sh」并返回 1，
#      smartdns 本体一个都没装回来，只剩 --conf 补了规则文件 —— 半残。
RESTORE_BIN="${RESTORE_BIN:-}"
if [ -z "$RESTORE_BIN" ]; then
    if [ -x /usr/sbin/pkg-restore.sh ]; then
        RESTORE_BIN=/usr/sbin/pkg-restore.sh
    else
        RESTORE_BIN="$(dirname "$0")/pkg-restore.sh"
    fi
fi

log() { printf '[PKG] %s\n' "$*"; }

# /etc/smartdns/ 下必须存在的规则文件（与构建期固化进固件的那批一致）
SD_CONF_FILES="address.conf blacklist-ip.conf custom.conf domain-block.list domain-forwarding.list"

# 【v.180.148】两个判据分开，绝不混用：
#
#   --check-pkg   包在不在：二进制 + init 可执行，再做一次冒烟。
#                 回答的是「要不要装包」。装完就结束，不管服务起没起。
#
#   --check       服务生不生效：pidof + 53 端口。
#                 回答的是「功能通不通」。不生效就重启/报错，绝不再装包 ——
#                 否则配置写错会变成「判缺 -> 装包 -> 还是不通 -> 再判缺 -> 再装」的死循环。
#
# 服务判据与 bootstrap 的 verify_sd_serve 同口径（那边 v.180.106 已改用 pidof，
# 注释记了弃用 pgrep -x 的原因：busybox 拿 argv[0] 整串比对，"smartdns" 恒不相等）。
# 冒烟只为抓动态库缺口：opkg remove libopenssl3 之后两个 -x 判断依然为真，
# 只有真跑才看得见。取向仍是「只有明确加载错误才判缺」，其余异常一律放过。
_sd_pkg_ok() {
    [ -x "$PKGROOT/usr/sbin/smartdns" ] && [ -x "$PKGROOT/etc/init.d/smartdns" ] || return 1
    case "$("$PKGROOT/usr/sbin/smartdns" -v 2>&1)" in
        *"Error loading"*|*"No such file"*|*"not found"*|*"cannot open shared object"*)
            return 1 ;;
    esac
    return 0
}

# 只读判定，不启动、不重启。重启只发生在 --config / --repair 走到末尾 _sd_apply 时。
# 【v.180.186】判据补上「53 是谁在听」：
#   pidof 有进程 + netstat 里有 :53 这两条是独立的，合起来并不能说明
#   「smartdns 真的绑上了 53」—— dnsmasq 占着 53 时旧判据照样通过。
#   现在按 socket inode 反查：/proc/net/udp{,6} 里 local port=0035 且 st=07
#   的 inode，再在 /proc/<smartdns pid>/fd/* 里找 socket:[<inode>]。
# 【v.180.198】探针已不再判 53（它只数 uci 上游段），这条判据现在只服务本脚本
#   自己：_sd_apply 写完配置后用它确认「53 真的到了 smartdns 手上」，失败就
#   log + return 1，不再把 53 还给 dnsmasq。
_sd_serve() {
    _ss_pid=$(pidof smartdns 2>/dev/null | awk '{print $1}')
    [ -n "$_ss_pid" ] || return 1
    _ss_ino=$(awk 'NR>1 && $4=="07" { n=split($2,a,":"); if (a[n]=="0035") print $10 }' \
        /proc/net/udp /proc/net/udp6 2>/dev/null)
    [ -n "$_ss_ino" ] || return 1
    for _ss_i in $_ss_ino; do
        for _ss_f in /proc/"$_ss_pid"/fd/*; do
            [ "$(readlink "$_ss_f" 2>/dev/null)" = "socket:[$_ss_i]" ] && return 0
        done
    done
    return 1
}

# 本体：走通用恢复的依赖树，两个依赖都是普通包，递归即可
_sd_pkg() {
    [ -x "$RESTORE_BIN" ] || { log "找不到 $RESTORE_BIN"; return 1; }
    "$RESTORE_BIN" --tree smartdns
}

# 规则文件：不存在才补，存在一律不动
_sd_conf() {
    _n=0
    for _f in $SD_CONF_FILES; do
        [ -e "$PKGROOT/etc/smartdns/$_f" ] && continue
        [ -e "$ROMDIR/etc/smartdns/$_f" ] || continue
        mkdir -p "$PKGROOT/etc/smartdns" 2>/dev/null
        cp -a "$ROMDIR/etc/smartdns/$_f" "$PKGROOT/etc/smartdns/$_f" 2>/dev/null \
            && _n=$((_n + 1))
    done
    [ "$_n" -gt 0 ] && log "从只读基座恢复 smartdns 规则文件：$_n 个（/etc/smartdns/）"
    return 0
}

# 界面是否可用。三段判据，都不碰包管理器（apk / opkg 通用）：
#   ① 运行期在位                                   → 0
#   ② 只读基座里有、运行期没有（该有却没有）        → 1，要恢复
#   ③ 基座里也没有（固件压根没编界面）             → 0，不报警
# ③ 是为老固件留的：它本来就没界面，每轮白恢复一次没有意义。
#
# 【v.180.159】② 原来判的是 /usr/lib/opkg/info/luci-app-smartdns.list，
# 那是 opkg 的安装清单。25.12 换 apk 后该路径永远不存在，于是那一行
# `|| return 0` 恒触发 → 本函数恒返 0（静默通过）→ 界面真丢了也漏报，
# 而且 _sd_luci 永远不跑。这不是误报，是漏报 + 永不恢复。
# 换成判基座里的两个界面文件，跨包管理器，且与 _sd_luci 的恢复来源同一份东西。
_sd_luci_ok() {
    if [ -f "$PKGROOT/usr/share/luci/menu.d/luci-app-smartdns.json" ] \
       && [ -f "$PKGROOT/usr/libexec/smartdns-call" ]; then
        return 0
    fi
    if [ -f "$ROMDIR/usr/share/luci/menu.d/luci-app-smartdns.json" ] \
       && [ -f "$ROMDIR/usr/libexec/smartdns-call" ]; then
        return 1
    fi
    return 0
}

_sd_luci() {
    _sd_luci_ok && return 0
    [ -x "$RESTORE_BIN" ] || return 1
    "$RESTORE_BIN" luci-app-smartdns || return 1
    return 0
}

# ====================================================================
# 【v.180.155】配置写入与整体修复：smartdns 从 bootstrap 全面接管
#
# 架构口径（用户 2026-10-29 定）：bootstrap 只负责「网络 / 网桥 / 容器网络 /
# lxc 与 bouncer 恢复 / crowdsec 容器恢复 / crowdsec 与 bouncer 联动配置」六件事。
# smartdns 的包、配置、服务全部由本脚本 + 探针负责，bootstrap 不再参与。
#
# 配置口径：验证 smartdns 存在之后**即写入**，不做逐项比对 —— 上游表写死 13 条
# （国内 9 UDP / 境外 4 DoT，用户明确说「完全够用」）。覆盖式写入的副作用是
# 在 LuCI 里手改的上游会被下一轮冲掉；这与原 bootstrap 的
# build_smartdns_upstream 行为完全一致，不是退步。
#
# 与 bootstrap 的关键差别：本脚本是独立进程，没人替它 commit / 重启，
# 所以 _sd_apply 自己 commit + 重启 + 等端口。
# ====================================================================

# smartdns 主配置段（config smartdns）的段名；没有则回空
_sd_main_seg() {
    uci -q show smartdns 2>/dev/null \
        | sed -n 's/^smartdns\.\([^.=]*\)=smartdns$/\1/p' | head -n1
}

# 【v.180.156】不再手动把 dnsmasq 的 53 让出来 —— smartdns 的 init 自己会做。
#
# 依据（pymumu/smartdns，Release46.1 与 Release48.4 的 package/openwrt/files/
# etc/init.d/smartdns 逐字相同，ImmortalWrt 24.10 用 48.4）：
#   L733  config_get auto_set_dnsmasq "$section" "auto_set_dnsmasq" "1"   ← 默认开
#   L891  [ "$auto_set_dnsmasq" = "1" ] && set_main_dns                    ← port=53 时
#   L78   [ "$dnsmasq_port" = "53" ] && set dhcp.@dnsmasq[0].port=0        ← 就是这里让的位
# 随后它还会补 dhcp.lan.dhcp_option="6,$hostip"、把 dns_redirect 关掉、
# uci commit dhcp 并 restart dnsmasq；且幂等（uci_batch 为空直接 return，不重启）。
# LuCI 那句「端口设为 53 时自动配置为主 DNS」说的就是这段。
#
# 所以本脚本只要保证 port=53 且 auto_set_dnsmasq=1，restart smartdns 时由 init
# 完成让位。原来的 _sd_release_53 是重复劳动（还会让 dnsmasq 多重启一次），已删。
#
# 前提（init 里的硬条件）：set_main_dns 开头 `[ -z "$hostip" ] && return`，
# hostip 取自 network.lan.ipaddr。lan 没静态地址时 init 静默跳过、谁都不让位，
# 那时 53 仍被 dnsmasq 占着 —— 这种情形由 _sd_apply 的失败分支报出来。
#
# 【v.180.198】删除回滚：smartdns 必须占 53（用户 2026-10-31 定）。
#
# 旧行为是「init 让出 53 后若 smartdns 起不来，就把 53 还给 dnsmasq」。删掉的理由：
#   · 与本固件的 DNS 取向冲突 —— 这台机器就是拿 smartdns 当主 DNS 用，
#     53 一旦被 dnsmasq 拿回去，分流与拦截全部失效，而没有任何机制再把它拿回来：
#     init 的 set_main_dns 只在 restart smartdns 时判断，dnsmasq 占着 53 就不会再让位。
#   · 回滚把「起不来」这件必须立刻知道的事，变成一条「已回滚」日志就算了结 ——
#     表面上有 DNS，实际 smartdns 的规则一条都没生效。
# 现在失败只报错并返回 1，由探针下一轮重试（--config 会重写 uci 并重启）。
# 对应地，探针不再检查 53，只检查上游条数（见 crowdsec-lxc-probe.sh 的 _up_watch）。

# 主配置段：不存在就建，逐项写死
_sd_cfg_main() {
    _sdc_seg=$(_sd_main_seg)
    if [ -z "$_sdc_seg" ]; then
        uci -q add smartdns >/dev/null 2>&1
        _sdc_seg=$(_sd_main_seg)
        [ -n "$_sdc_seg" ] || { log "无法创建 smartdns 主配置段"; return 1; }
    fi
    uci -q set "smartdns.$_sdc_seg.enabled=1" || return 1
    uci -q set "smartdns.$_sdc_seg.port=53" || return 1
    # bind 不是 UCI 选项：init 脚本只读 port / bind_device，历史残留的 bind 顺手清掉，
    # 否则会让人误以为在控制监听地址。
    uci -q delete "smartdns.$_sdc_seg.bind" 2>/dev/null
    # bind_device=0 → 只生成 `bind [::]:53`，br-lan / lxcbr0 / docker0 一律可达。
    # 设成 1 时 init 只绑 br-lan + lo，容器拿 lxcbr0 地址来查会被丢掉。
    uci -q set "smartdns.$_sdc_seg.bind_device=0" || return 1
    # auto_set_dnsmasq=1（init 的默认值，这里显式写死）：port=53 时由 init 负责
    # 把 dhcp.@dnsmasq[0].port 置 0 并重启 dnsmasq。显式写是为了防止在 LuCI 里
    # 误关一次就永久失效 —— 与本脚本其它字段「写死纠正」的口径一致。
    uci -q set "smartdns.$_sdc_seg.auto_set_dnsmasq=1" || return 1
    uci -q set "smartdns.$_sdc_seg.cache_size=32768" || return 1
    uci -q set "smartdns.$_sdc_seg.serve_expired=1" || return 1
    uci -q set "smartdns.$_sdc_seg.prefetch_domain=1" || return 1
    return 0
}

# 上游 13 条写死。按 ip 定位段：有就修正字段，没有就新建；同 ip 重复段只留第一个。
# 表外用户自己加的上游原样保留（不删除）。
_sd_cfg_upstream() {
    # 先建「ip=段名」索引，避免每条都重扫一遍 uci show（13 条 × 13 段 = 169 次 fork）
    _sdc_map=" "
    for _sdc_s in $(uci -q show smartdns 2>/dev/null | grep -E '=server$' | cut -d. -f2 | cut -d= -f1); do
        _sdc_map="$_sdc_map$(uci -q get "smartdns.$_sdc_s.ip" 2>/dev/null)=$_sdc_s "
    done
    _sdc_n=0
    while read -r _sdc_name _sdc_ip _sdc_tp _sdc_grp _sdc_host; do
        [ -n "$_sdc_ip" ] || continue
        _sdc_hit=""
        _sdc_dup=""
        for _sdc_p in $_sdc_map; do
            [ "${_sdc_p%%=*}" = "$_sdc_ip" ] || continue
            if [ -z "$_sdc_hit" ]; then
                _sdc_hit=${_sdc_p#*=}
            else
                _sdc_dup="$_sdc_dup ${_sdc_p#*=}"
            fi
        done
        for _sdc_d in $_sdc_dup; do
            uci -q delete "smartdns.$_sdc_d" 2>/dev/null
        done
        if [ -z "$_sdc_hit" ]; then
            uci -q add smartdns server >/dev/null 2>&1
            _sdc_hit="@server[-1]"
        fi
        uci -q set "smartdns.$_sdc_hit.enabled=1"
        uci -q set "smartdns.$_sdc_hit.name=$_sdc_name"
        uci -q set "smartdns.$_sdc_hit.ip=$_sdc_ip"
        uci -q set "smartdns.$_sdc_hit.type=$_sdc_tp"
        uci -q set "smartdns.$_sdc_hit.server_group=$_sdc_grp"
        # DoT 必须带 SNI，否则证书主机名校验必然失败（8.8.8.8 的证书是 dns.google）
        if [ "$_sdc_tp" = "tls" ] && [ "$_sdc_host" != "-" ]; then
            uci -q set "smartdns.$_sdc_hit.host_name=$_sdc_host"
        else
            # UDP 段不该带 SNI：历史残留清掉，否则每轮都会判不符
            uci -q delete "smartdns.$_sdc_hit.host_name" 2>/dev/null
        fi
        _sdc_n=$((_sdc_n + 1))
    done <<'SD_UPSTREAM_EOF'
alidns 223.5.5.5 udp Cn -
alidns 223.6.6.6 udp Cn -
dnspod 119.29.29.29 udp Cn -
baidu 180.76.76.76 udp Cn -
360dns 101.226.4.6 udp Cn -
360dns 218.30.118.6 udp Cn -
360dns 123.125.81.6 udp Cn -
360dns 140.207.198.6 udp Cn -
cnnic 1.2.4.8 udp Cn -
google 8.8.8.8 tls Out dns.google
google 8.8.4.4 tls Out dns.google
cloudflare 1.1.1.1 tls Out cloudflare-dns.com
cloudflare 1.0.0.1 tls Out cloudflare-dns.com
SD_UPSTREAM_EOF
    [ "$_sdc_n" -eq 13 ] || { log "上游按表处理条数异常（$_sdc_n ≠ 13），不接管 DNS"; return 1; }
    return 0
}

# commit + 重启 + 等端口。
# 不再手动 restart dnsmasq：init 的 start_service 只要见到 port=53 且
# auto_set_dnsmasq=1，就会自己把 dnsmasq 的 port 置 0 并重启它，顺序由 init 保证。
# 我们只 restart smartdns，然后等 53 真的在听。
_sd_apply() {
    uci commit smartdns || { log "uci commit smartdns 失败"; _sd_discard; return 1; }
    [ -x /etc/init.d/smartdns ] || { log "没有 /etc/init.d/smartdns，无法重启"; return 1; }
    /etc/init.d/smartdns restart >/dev/null 2>&1
    _sda_i=0
    while [ "$_sda_i" -lt 15 ]; do
        _sd_serve && return 0
        sleep 1
        _sda_i=$((_sda_i + 1))
    done
    log "配置已写入，但 53 端口 15 秒内没有监听（端口被占、配置语法或动态库问题）"
    # 【v.180.198】不回滚：smartdns 必须占 53（用户 2026-10-31 定）。
    # 此时 dnsmasq 的 53 已被 smartdns 的 init 让出，机器确实没有可用 DNS ——
    # 这条错误必须被看见，而不是用「把 53 还给 dnsmasq」把它掩盖成一条「已回滚」。
    # 重试由探针的 _up_watch 承担（它只判上游条数，不看 53）。
    return 1
}

# 丢弃尚未 commit 的 smartdns 改动。/tmp/.uci 是 uci 的暂存目录，本进程 exit 后
# 脏数据仍在，下次任何人 commit smartdns 都会把它带进去 —— 半套配置上线的后果比不写更糟。
# 只 revert smartdns：dhcp 由 smartdns 的 init 改，本脚本不再碰它，
# 贸然 revert dhcp 会把别人（LuCI 编辑中）尚未提交的改动一起丢掉。
# 只用在「还没 commit 就失败」的路径；已经 commit 的失败由 _sd_apply 报错返回，
# 不回滚（53 必须归 smartdns，v.180.198）。
_sd_discard() {
    uci -q revert smartdns 2>/dev/null
    return 0
}

# --config 主流程：验证存在 → 补规则文件 → 写主段 → 写上游 → commit/重启
_sd_config() {
    command -v uci >/dev/null 2>&1 || { log "没有 uci，无法写配置"; return 1; }
    if ! _sd_pkg_ok; then
        log "smartdns 不在位，先从只读基座装回"
        _sd_pkg || { log "装包失败（只读基座里没有 smartdns）"; return 1; }
        _sd_pkg_ok || { log "装包后仍判不在位，放弃写配置"; return 1; }
    fi
    _sd_conf
    _sd_cfg_main || { log "主配置段写入失败"; _sd_discard; return 1; }
    _sd_cfg_upstream || { log "上游表写入失败，不接管 DNS"; _sd_discard; return 1; }
    _sd_apply || return 1
    log "smartdns 已接管 DNS：13 条上游（国内 9 UDP / 境外 4 DoT），dnsmasq 由 init 让出 53"
    return 0
}

case "${1:-}" in
"")
    _rc=0
    _sd_pkg || _rc=1
    _sd_conf
    if _sd_luci_ok; then
        :
    else
        log "界面 luci-app-smartdns 缺失 —— 单独补，不影响本体"
        _sd_luci || log "界面未恢复（只读基座里没有它的安装清单，只影响网页配置）"
    fi
    exit $_rc
    ;;
# --config 与 --repair 现在等价：_sd_config 内部已经按「缺包先装包」的顺序走完，
# 保留两个名字是为了调用点语义清楚（rc.local 开机配一次用 --config，
# probe 在「DNS 不正常」（53 未接管 或 上游 0 条）时兜底用 --repair。
# bootstrap 自 v.180.157 起不再调用本脚本）。
--config|--repair)
    _sd_config && exit 0 || exit 1
    ;;
--check)
    _sd_serve && exit 0 || exit 1
    ;;
--check-pkg)
    _sd_pkg_ok && exit 0 || exit 1
    ;;
--pkg)
    _sd_pkg && exit 0 || exit 1
    ;;
--conf)
    _sd_conf && exit 0 || exit 1
    ;;
--luci)
    _sd_luci && exit 0 || exit 1
    ;;
*)
    echo "用法：$0 [--check|--pkg|--conf|--luci]" >&2
    exit 2
    ;;
esac
