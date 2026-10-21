#!/bin/sh
# BACKUP 旁路由锁定版（v.78-bp）网络基线测试
REPO=$(cd "$(dirname "$0")/.." && pwd)
BS="$REPO/files/usr/sbin/crowdsec-lxc-bootstrap.sh"
FUNCS=$(mktemp "${TMPDIR:-/tmp}/bp_net_funcs.XXXXXX.sh")
export UCI_STATE=/tmp/bk_uci_state
export RELOAD_LOG=/tmp/bk_reload.log
PASS=0; FAIL=0

python3 - "$BS" \
    _read_netconf _lan_static_conf _is_ipv4 _lan_conf_valid _norm_list _phys_ports _phys_port_count _zone_sec \
    _zone_lan_network _wan_sections _snat_sec _lxc_net _lan_ip \
    verify_wan_input verify_lan_input verify_br_lan_ports verify_lan_static \
    verify_dhcp_ignore verify_wan_removed verify_dns_domain verify_svc_bind \
    verify_docker_fw \
    build_wan_input build_lan_input build_br_lan_ports build_lan_static \
    build_dhcp_ignore build_wan_removed build_dns_domain build_svc_bind \
    build_docker_fw ensure flush_uci log _bs_flag_set _bs_flag_clear _bs_flag_on _bs_flag_tag _bs_flag_count verify_snat_rule verify_snat build_snat verify_ip_forward \
    ct_running verify_ct_net_ping verify_ct_net build_ct_net \
    verify_cgroup_mount verify_ct_bootlink verify_ct_resolv \
    verify_capi_block verify_acquis verify_log_forward verify_log_pipeline \
    verify_lapi_fetch verify_bouncer_fill verify_bouncer_verify verify_capi_release \
    verify_lapi_ready bouncer_exists bouncer_pulling \
    verify_online_client_off verify_online_client_on \
    verify_sub_ct_net verify_sub_ct_bootlink verify_sub_ct_resolv verify_sub_cs_acquis \
    _system_section > "$FUNCS" <<'PY'
import sys, re
src = open(sys.argv[1]).read().splitlines()
want = set(sys.argv[2:])
out = []
i = 0
while i < len(src):
    m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{', src[i])
    if m and m.group(1) in want:
        depth = 0
        j = i
        buf = []
        while j < len(src):
            line = src[j]
            buf.append(line)
            depth += line.count('{') - line.count('}')
            if depth <= 0:
                break
            j += 1
        out.append('\n'.join(buf))
        i = j + 1
    else:
        i += 1
for l in src:
    if re.match(r'^(DAG_NODES|RO_ONLY_NODES|DEP_|FMODE_|ALWAYS_)\w*=', l):
        out.append(l)
print('\n\n'.join(out))
PY
. "$FUNCS"

export PATH=/tmp/mockbin:/tmp/mockbin_sys
docker_off() { PATH=/tmp/mockbin:/tmp/mockbin_sys; export PATH; }
docker_on()  { PATH=/tmp/mockbin_docker:/tmp/mockbin:/tmp/mockbin_sys; export PATH; }
docker_off

PORTS="eth0 eth1"
_phys_ports() { for _p in $PORTS; do echo "$_p"; done; }

mkdir -p /etc/config 2>/dev/null
printf 'bypass\n' > /etc/config/custom_router_mode.txt

_FAKE_MADE=""
mkfake() {
    [ -e "/etc/init.d/$1" ] && return 0
    cat > "/etc/init.d/$1" <<EOF
#!/bin/sh
echo "$1 \$*" >> "\$RELOAD_LOG"
exit 0
EOF
    chmod +x "/etc/init.d/$1"
    _FAKE_MADE="$_FAKE_MADE $1"
}
for _s in network dnsmasq firewall dropbear ttyd; do mkfake "$_s"; done

_wconf() { printf '%s\n' "$2" > "/etc/config/$1"; }
# 直接向 mock uci 状态追加一条（绕过 uci 命令，用于精确构造远端/用户侧配置）
_uci_add() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >> "$UCI_STATE"; }
# 声明段类型（等价 uci set cfg.sec=type）
_uci_type() { printf '%s|%s|__type__|%s\n' "$1" "$2" "$3" >> "$UCI_STATE"; }
reset_state() {
    : > "$UCI_STATE"; : > "$RELOAD_LOG"
    # v.99 起置位值是 V:<ts>/B:<ts>/R:<ts>，归零 = 清空；写成 0 会让 _bs_flag_on 判成「已置位」
    for _n in $DAG_NODES; do eval "_done_$_n=''; _dirty_$_n=''"; done
    _failed=""; _order=""; _ro_missing=""
}
clear_conf()  { rm -f /etc/config/custom_router_ip.txt /etc/config/custom_router_netmask.txt \
                        /etc/config/custom_router_gateway.txt /etc/config/custom_router_dns.txt; }
clear_conf

chk() {
    if { [ "$2" = ok ] && [ "$3" = 0 ]; } || { [ "$2" = fail ] && [ "$3" != 0 ]; }; then
        PASS=$((PASS+1)); echo "PASS: $1"
    else
        FAIL=$((FAIL+1)); echo "FAIL: $1 (rc=$3, want $2)"
    fi
}
eq() { # eq <desc> <got> <want>
    if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "PASS: $1"
    else FAIL=$((FAIL+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi
}

# ============ A. 管理地址推导（保持 BACKUP 原默认值 10.0.0.201/10.0.0.10） ============
echo "--- A. 推导 ---"
reset_state
eq "A1 默认四值" "$(_lan_static_conf)" "10.0.0.201 255.255.255.0 10.0.0.10 10.0.0.10"
_wconf custom_router_ip.txt "10.0.0.55"
eq "A2 自定义IP+/24 推网关DNS" "$(_lan_static_conf)" "10.0.0.55 255.255.255.0 10.0.0.1 10.0.0.1"
_wconf custom_router_netmask.txt "255.255.0.0"
eq "A3 非/24 不推导网关" "$(_lan_static_conf)" "10.0.0.55 255.255.0.0 10.0.0.10 10.0.0.10"
_wconf custom_router_gateway.txt "10.0.0.9"
eq "A4 显式网关，DNS跟随" "$(_lan_static_conf)" "10.0.0.55 255.255.0.0 10.0.0.9 10.0.0.9"
_wconf custom_router_dns.txt "223.5.5.5"
eq "A5 显式DNS优先" "$(_lan_static_conf)" "10.0.0.55 255.255.0.0 10.0.0.9 223.5.5.5"
rm -f /etc/config/custom_router_ip.txt /etc/config/custom_router_netmask.txt \
      /etc/config/custom_router_gateway.txt /etc/config/custom_router_dns.txt

# v.95：四值来自编译期文件，写坏了必须先拦住，绝不能喂给 uci（写错即失联）
eq "A6 默认四值合法" "$(_lan_conf_valid 10.0.0.201 255.255.255.0 10.0.0.10 10.0.0.10 && echo ok)" "ok"
eq "A7 非法 IP（>255）被拦" "$(_lan_conf_valid 10.0.0.1000 255.255.255.0 10.0.0.1 10.0.0.1 || echo bad)" "bad"
eq "A8 IP 与网关相同被拦" "$(_lan_conf_valid 10.0.0.1 255.255.255.0 10.0.0.1 10.0.0.1 || echo bad)" "bad"
eq "A9 空 DNS 被拦（空值写进 uci 等于没配 DNS）" "$(_lan_conf_valid 10.0.0.201 255.255.255.0 10.0.0.10 \"\" || echo bad)" "bad"
eq "A10 0.0.0.0 被拦" "$(_lan_conf_valid 0.0.0.0 255.255.255.0 10.0.0.1 10.0.0.1 || echo bad)" "bad"

# A11~A13：真实链路 —— 文件写坏后 ensure 必须 hard，且 uci 一个字都不能改
reset_state
_wconf custom_router_ip.txt "10.0.0.999"
_before_ip=$(uci -q get network.lan.ipaddr 2>/dev/null)
_out=$( { ensure lan_static; } 2>&1 ); _rc=$?
eq "A11 坏 IP 时 ensure hard 终止（rc=1）" "$_rc" "1"
eq "A12 坏 IP 时 uci 未被写入" "$(uci -q get network.lan.ipaddr 2>/dev/null)" "$_before_ip"
printf '%s\n' "$_out" | grep -q '期望值不合法'; chk "A13 日志指明期望值不合法" ok $?
printf '%s\n' "$_out" | grep -q 'custom_router_'; chk "A14 日志指明去查哪个文件" ok $?
rm -f /etc/config/custom_router_ip.txt

# ============ B. zone 定责 ============
echo "--- B. zone 定责 ---"
reset_state
cat >> "$UCI_STATE" <<EOF
firewall|cfg1|__type__|zone
firewall|cfg1|name|wan
firewall|cfg1|input|ACCEPT
firewall|cfg2|__type__|zone
firewall|cfg2|name|lan
firewall|cfg2|input|ACCEPT
firewall|cfg2|forward|ACCEPT
firewall|cfg2|network|lan
EOF
eq "B1 _zone_sec wan" "$(_zone_sec wan)" "cfg1"
eq "B2 _zone_sec lan" "$(_zone_sec lan)" "cfg2"
eq "B3 _zone_lan_network" "$(_zone_lan_network)" "lan"
verify_wan_input; chk "B4 wan input ACCEPT 判不符（应REJECT）" fail $?
verify_lan_input; chk "B5 lan input/forward ACCEPT 就绪" ok $?
build_wan_input
# v.95：wan_input 改为「验证 + 修改」，build 必须真把多网口下的 wan zone 收紧
eq "B6 build_wan_input 写入 REJECT（多网口）" "$(uci -q get firewall.cfg1.input)" "REJECT"
verify_wan_input; chk "B7 改完复核即通过（不再挂待办）" ok $?
# 单网口场景：用户在 LuCI 设成 ACCEPT 才判就绪
PORTS="eth0"
uci -q set firewall.cfg1.input='ACCEPT'
verify_wan_input; chk "B8 单网口 ACCEPT 就绪" ok $?
verify_wan_input; chk "B9 单网口 verify 就绪" ok $?
PORTS="eth0 eth1"
# 无 name=lan zone 时跳过
reset_state
verify_lan_input; chk "B10 无 lan zone 跳过" ok $?
verify_svc_bind; chk "B11 无 lan zone svc 跳过" ok $?

# ============ C. 旁路基线五对象 ============
echo "--- C. 旁路基线 ---"
reset_state
PORTS=""
verify_br_lan_ports; chk "C1 空枚举跳过（防误建空桥）" ok $?
PORTS="eth0 eth1"
verify_br_lan_ports; chk "C1b 两口枚举+空状态不符" fail $?
PORTS="eth0 eth1"
cat >> "$UCI_STATE" <<EOF
network|br_lan|__type__|device
network|br_lan|type|bridge
network|br_lan|name|br-lan
network|br_lan|ports|eth0
network|br_lan|ports|eth1
network|lan|device|br-lan
network|lan|proto|static
network|lan|ipaddr|10.0.0.201
network|lan|netmask|255.255.255.0
network|lan|gateway|10.0.0.10
network|lan|dns|10.0.0.10
dhcp|lan|ignore|1
dhcp|dm0|__type__|dnsmasq
dhcp|dom0|__type__|domain
dhcp|dom0|name|time.android.com
dhcp|dom0|ip|203.107.6.88
firewall|cfg2|__type__|zone
firewall|cfg2|name|lan
firewall|cfg2|input|ACCEPT
firewall|cfg2|forward|ACCEPT
firewall|cfg2|network|lan
dropbear|@dropbear[0]|__type__|dropbear
dropbear|@dropbear[0]|Interface|lan
ttyd|@ttyd[0]|__type__|ttyd
ttyd|@ttyd[0]|interface|lan
EOF
verify_br_lan_ports; chk "C2 桥就绪" ok $?
verify_lan_static; chk "C3 LAN静态就绪" ok $?
verify_dhcp_ignore; chk "C4 DHCP让权就绪" ok $?
uci -q delete network.wan; uci -q delete network.wan6
verify_wan_removed; chk "C5 wan/wan6 段已删除 → 就绪" ok $?
verify_dns_domain; chk "C6 DNS劫持就绪" ok $?
verify_svc_bind; chk "C7 svc_bind就绪" ok $?

# 破坏若干网络项 → v.95 起脚本「验证 + 修改 + commit + 分组 reload」，全部会真修
uci -q delete network.br_lan.ports
uci -q set dhcp.lan.ignore='0'
uci -q set network.wan='interface'; uci -q set network.wan.proto='dhcp'
uci -q set network.wan6='interface'; uci -q set network.wan6.proto='dhcp'
uci -q delete dhcp.dom0
: > "$RELOAD_LOG"
for _n in br_lan_ports lan_static dhcp_ignore wan_removed dns_domain; do ensure "$_n"; done
flush_uci
verify_br_lan_ports; chk "C8 桥缺项→ensure 补建并复核通过" ok $?
verify_dhcp_ignore; chk "C9 ignore=0→ensure 改回 1 并复核通过" ok $?
verify_dns_domain; chk "C10 domain 缺失→ensure 补建并复核通过" ok $?
[ -z "$(_wan_sections)" ]; chk "C10a ensure 后 wan/wan6 段被删除" ok $?
eq "C10b 桥 ports 被补回物理口（不再保持空）" "$(uci -q get network.br_lan.ports 2>/dev/null | sort | tr '\n' ' ')" "eth0 eth1 "
eq "C10c wan_removed 删掉 wan 段" "$(uci -q get network.wan 2>/dev/null)" ""
eq "C10d 只删 wan，lan 桥配置原样保留" "$(uci -q get network.lan.device 2>/dev/null)" "br-lan"
# network 与 dhcp 两组各 reload 一次，firewall 没动不该被带跑
eq "C11 network reload 1 次" "$(grep -c '^network reload' "$RELOAD_LOG")" "1"
eq "C11b dnsmasq restart 1 次" "$(grep -c '^dnsmasq restart' "$RELOAD_LOG")" "1"
eq "C11c firewall 未被本轮带跑" "$(grep -c '^firewall reload' "$RELOAD_LOG")" "0"

# C11a~C11c：源码级结构断言（v.95：允许写，但写入必须收口在 build_* 里由 ensure 调度）
_BS="$BS"
# 只允许删「字段」（docker.subnet 这类单值），不允许删整段（firewall.<sec> 无点）
_nf=$(grep -oE 'uci -q delete firewall\.[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)?' "$_BS" 2>/dev/null | grep -vc '\.')
eq "C11a 源码零整段 firewall 删除（只删字段、不删用户 zone）" "$_nf" "0"
_rl=$(awk '/^flush_uci\(\)/,/^}/' "$_BS" | grep -cE 'init\.d/(network|dnsmasq|firewall) (reload|restart)')
eq "C11d flush_uci 三组各至多一次 reload/restart（共 3 行）" "$_rl" "3"
_cn=$(awk '/^flush_uci\(\)/,/^}/' "$_BS" | grep -cE '^\s*uci -q commit (network|dhcp|firewall)')
eq "C11e flush_uci 三组各一次 commit（共 3 行）" "$_cn" "3"
_wr=$(awk '/^build_(br_lan_ports|lan_static|dhcp_ignore|dns_domain|lxc_zone|fwd_rules|wan_input|lan_input|snat|docker_fw)\(\)/,/^}/' "$_BS" | grep -cE '^\s*uci (-q )?(set|delete|add_list|add)')
[ "$_wr" -gt 0 ]; chk "C11f 这些 builder 确实会写 uci（v.95 起不再只验）" ok $?
_wd=$(awk '/^build_wan_removed\(\)/,/^}/' "$_BS" | grep -cE '^\s*uci (-q )?set')
eq "C11g wan_removed 只 delete 不 set（不做 disable 改写）" "$_wd" "0"
# 脏标记清零必须扫全 DAG：曾经手写清单漏了 bridge/svc_bind，残留脏标记会让下一轮
# 无改动也 reload，破坏「零改动零 reload」这条不变量
_awk='/^flush_uci\(\)/,/^}/'
_cl=$(awk "$_awk" "$_BS" | grep -c 'for _o in \$DAG_NODES')
eq "C11h flush 按 DAG_NODES 全量清脏标记（不手写清单）" "$_cl" "1"

# 全就绪时早退不 reload（_done_* 已置 1 的节点直接跳过）
: > "$RELOAD_LOG"
for _n in br_lan_ports lan_static dhcp_ignore wan_removed dns_domain; do ensure "$_n"; done
flush_uci
eq "C12 全就绪无reload" "$(wc -l < "$RELOAD_LOG" | tr -d ' ')" "0"

# ============ D. docker 防火墙 ============
echo "--- D. docker ---"
reset_state
verify_docker_fw; chk "D1 无dockerd跳过" ok $?
docker_on
verify_docker_fw; chk "D2 空状态判不符" fail $?
ensure docker_fw
flush_uci
# v.95：docker_fw 改为「验证 + 修改」，装了 dockerd 就真把 zone/rule 补出来
verify_docker_fw; chk "D3 build 后 docker 防火墙就绪" ok $?
eq "D4 docker zone 与三条转发规则已写入" "$(uci -q get firewall.docker.name)/$(wc -l < "$UCI_STATE" | tr -d ' ')" "docker/$(wc -l < "$UCI_STATE" | tr -d ' ')"
docker_off

# ============ E. rc.local 引导锁残留自愈（v.80） ============
RC_LOCAL=/tmp/bp/files/etc/rc.local
RCL_DIR=/tmp/bknet_rcl
rm -rf "$RCL_DIR"; /usr/bin/mkdir -p "$RCL_DIR"
dash -n "$RC_LOCAL" 2>/dev/null; chk "E0 rc.local 语法" ok $?
# 提取锁逻辑段（【引导锁】阶段起，到【执行引导】阶段前），以临时 LOG/LOCK 实跑
/usr/bin/awk '/^# ---- 阶段【引导锁】/{f=1; next} /^# ---- 阶段【执行引导】/{f=0} f' "$RC_LOCAL" > "$RCL_DIR/stanza.sh"
E_LOG="$RCL_DIR/log"; E_LOCK="$RCL_DIR/lock"
# E1 残留锁（mtime 超 30 分钟）：强夺后继续，不跳过
: > "$E_LOG"; rm -rf "$E_LOCK"; /usr/bin/mkdir -p "$E_LOCK"; /usr/bin/touch -d '2 hours ago' "$E_LOCK"
PATH=/tmp/mockbin:/tmp/mockbin_sys:/usr/bin:/bin LOG="$E_LOG" LOCK="$E_LOCK" dash "$RCL_DIR/stanza.sh" >/dev/null 2>&1
docker_off
grep -q "强夺后继续" "$E_LOG"; chk "E1 残留锁被强夺" ok $?
[ -d "$E_LOCK" ]; chk "E1 强夺后重新持锁" ok $?
grep -q "本次跳过" "$E_LOG"; chk "E1 不误走跳过分支" fail $?
# E2 新鲜锁（刚建）：不抢，走"上一次仍在执行"
: > "$E_LOG"; rm -rf "$E_LOCK"; /usr/bin/mkdir -p "$E_LOCK"
PATH=/tmp/mockbin:/tmp/mockbin_sys:/usr/bin:/bin LOG="$E_LOG" LOCK="$E_LOCK" dash "$RCL_DIR/stanza.sh" >/dev/null 2>&1
docker_off; _e2=$?
grep -q "上一次引导仍在执行，本次跳过" "$E_LOG"; chk "E2 新鲜锁不抢、走跳过" ok $?
eq "E2 跳过分支退出码 0" "$_e2" "0"
# E3 锁不存在：直接持锁通过，无强夺也无跳过
: > "$E_LOG"; rm -rf "$E_LOCK"
PATH=/tmp/mockbin:/tmp/mockbin_sys:/usr/bin:/bin LOG="$E_LOG" LOCK="$E_LOCK" dash "$RCL_DIR/stanza.sh" >/dev/null 2>&1
docker_off
[ -d "$E_LOCK" ]; chk "E3 无锁时正常持锁" ok $?

# C13~C18：旁路由必须把 WAN/WAN6 段整段删除（新 nft 不认 disabled）
: > "$UCI_STATE"
_uci_type network wan interface; _uci_add network wan proto dhcp
_uci_add network wan device eth0
_uci_type network wan6 interface; _uci_add network wan6 proto dhcp
verify_wan_removed; chk "C13 wan/wan6 段存在 → 判不符" fail $?
build_wan_removed
eq "C14 build 后 wan 段已删除" "$(uci -q get network.wan 2>/dev/null)" ""
eq "C15 build 后 wan6 段已删除" "$(uci -q get network.wan6 2>/dev/null)" ""
eq "C16 build 用的是 delete 不是 disable（disabled 键也不该出现）" "$(uci -q get network.wan.disabled 2>/dev/null)" ""
verify_wan_removed; chk "C17 删除后判就绪" ok $?
# 删干净了再跑一次：不应产生任何新写入（幂等）
: > "$UCI_STATE"
build_wan_removed
eq "C18 段已不存在时 build 幂等（零写入）" "$(wc -l < "$UCI_STATE" | tr -d ' ')" "0"
# 用户在 LuCI 重建 WAN（可重建，不影响）→ 下次引导再次删除，旁路由语义闭环
_uci_type network wan interface; _uci_add network wan proto pppoe
verify_wan_removed; chk "C19 重建 WAN 后再次判不符（会再删）" fail $?
build_wan_removed
eq "C20 重建的 WAN 被再次删除（闭环）" "$(uci -q get network.wan 2>/dev/null)" ""

# ============ G. 旁路由拓扑：所有物理口进 br-lan，WAN 一律禁用 ============
echo "--- G. 旁路由拓扑 ---"
reset_state
PORTS="eth0 eth1 eth2"
_phys_ports() { for _p in $PORTS; do echo "$_p"; done; }
eq "G1 三口全枚举" "$(_phys_port_count)" "3"
build_br_lan_ports
# v.95：build 直接建段 + 把三口全塞进桥，不再等用户在 LuCI 里配
eq "G2 build 后三口全进桥" "$(uci -q get network.br_lan.ports 2>/dev/null | sort | tr '\n' ' ')" "eth0 eth1 eth2 "
verify_br_lan_ports; chk "G3 三口全在桥内 → 判就绪" ok $?
reset_state
cat >> "$UCI_STATE" <<EOF
network|br_lan|__type__|device
network|br_lan|type|bridge
network|br_lan|name|br-lan
network|br_lan|ports|eth1
network|br_lan|ports|eth2
network|lan|device|br-lan
EOF
verify_br_lan_ports; chk "G4 首口缺失(仅eth1,eth2) → 判不符" fail $?
reset_state
PORTS="eth0 eth1"
_phys_ports() { for _p in $PORTS; do echo "$_p"; done; }
# 模拟 userspace 已配好的双口桥 + 一个待删的 WAN 段（先不 build，避免端口叠加）
_uci_type network br_lan device
_uci_add network br_lan type bridge
_uci_add network br_lan name br-lan
for _p in eth0 eth1; do uci -q add_list network.br_lan.ports="$_p"; done
_uci_add network lan device br-lan
# G5~G8：双口机删除 WAN 段，桥接配置不受影响
_uci_type network wan interface; _uci_add network wan proto dhcp
build_wan_removed
eq "G5 双口 build 后 wan 段被删" "$(uci -q get network.wan 2>/dev/null)" ""
eq "G6 双口 build 后桥 ports 未被波及" "$(uci -q get network.br_lan.ports 2>/dev/null | sort | tr '\n' ' ')" "eth0 eth1 "
eq "G7 双口 build 后 lan.device 仍是 br-lan" "$(uci -q get network.lan.device 2>/dev/null)" "br-lan"
eq "G8 双口 build 后 wan/dis 无残留（不写 disabled 位）" "$(uci -q get network.wan.disabled 2>/dev/null)" ""
PORTS="eth0 eth1"
_phys_ports() { for _p in $PORTS; do echo "$_p"; done; }
_phys_ports() { for _p in $PORTS; do echo "$_p"; done; }

# ============ H 层：v.93 八组新增节点 ============
# H1：宿主机↔容器双向 ping（模拟：桩掉 ping 与 _ct_env，只验判定逻辑）
echo "===== H1. 宿主机↔容器双向 ping 判定 ====="
_CT_UP=1; _P1=0; _P2=0
ct_running() { [ "$_CT_UP" = 1 ]; }
ping() { return "$_P1"; }
_ct_env() { case "$1" in ping*) return "$_P2" ;; *) return 0 ;; esac; }
CONTAINER_IP="10.1.0.100"; BRIDGE_IP="10.1.0.1"

_CT_UP=0
verify_ct_net_ping >/dev/null 2>&1
eq "H1.1 容器未启动 → 不判 ping 直接放行" "$?" "0"

_CT_UP=1; _P1=0; _P2=0
out=$(verify_ct_net_ping 2>&1); rc=$?
eq "H1.2 双向通 → 判就绪" "$rc" "0"

_P1=1; _P2=0
out=$(verify_ct_net_ping 2>&1); rc=$?
eq "H1.3 宿主机 ping 容器失败 → 判不符" "$rc" "1"
echo "$out" | grep -q "宿主机 ping 容器 10.1.0.100 失败"; chk "H1.4 失败日志点名方向" ok $?

_P1=0; _P2=1
out=$(verify_ct_net_ping 2>&1); rc=$?
eq "H1.5 容器 ping 网桥失败 → 判不符" "$rc" "1"
echo "$out" | grep -q "容器 ping 网桥 10.1.0.1 失败"; chk "H1.6 失败日志点名方向" ok $?

_P1=1; _P2=1
verify_ct_net_ping >/dev/null 2>&1
eq "H1.7 双向都不通 → 仍判不符（不误放行）" "$?" "1"

# H2：标记日志 → 查 crowdsec 是否入库（模拟：桩掉 _ct_env 的三种回显）
echo "===== H2. 标记日志入库判定（alerts / metrics / syslog 三级） ====="
LOG_MARK_PREFIX="csprobe"
_MODE="alerts"
ct_running() { return 0; }
_ct_env() {
    case "$1" in
        logger*) echo "$1" | sed -E "s/.*'([^']+)'.*/\1/" > /tmp/bp_net_mark ;;
        *"alerts list -o raw"*) [ "$_MODE" = alerts ] && cat /tmp/bp_net_mark 2>/dev/null; return 0 ;;
        *"metrics show"*)       [ "$_MODE" = metrics ] && cat /tmp/bp_net_mark 2>/dev/null; return 0 ;;
        grep*)                  [ "$_MODE" = syslog ] && cat /tmp/bp_net_mark 2>/dev/null | grep -q csprobe ;;
        *) return 0 ;;
    esac
}
sleep() { :; }
for _m in alerts metrics syslog; do
    _MODE=$_m
    verify_log_pipeline >/dev/null 2>&1
    eq "H2.$([ "$_m" = alerts ] && echo 1 || { [ "$_m" = metrics ] && echo 2 || echo 3; }) 命中 $_m 层 → 判通" "$?" "0"
done
_MODE="none"
verify_log_pipeline >/dev/null 2>&1
eq "H2.4 三级都不命中 → 判不通（不误报成功）" "$?" "1"

# H3：cgroup 挂载判定（容器启动前必须挂好）
# 注意：判定内部用 grep 读 /proc/mounts，必须回到真实 PATH，
# 否则 mockbin 里的 grep 桩会把 /proc/mounts 读空而误判（曾踩）
echo "===== H3. cgroup 挂载判定 ====="
_SAVED_PATH="$PATH"; PATH=/usr/bin:/bin; export PATH
verify_cgroup_mount >/dev/null 2>&1
eq "H3.1 沙箱已挂 cgroup2 统一层级 → 判就绪" "$?" "0"
PATH="$_SAVED_PATH"; export PATH

# H4：屏蔽 CAPI 必须在开机前（config.yaml 只在 crowdsec 启动时读一次）
echo "===== H4. CAPI 屏蔽/放出是独立节点，职责互斥 ====="
grep -q '^verify_capi_block()' "$BS"; chk "H4.1 capi_block 独立成节点" ok $?
grep -q '^verify_capi_release()' "$BS"; chk "H4.2 capi_release 独立成节点" ok $?
awk '/^verify_capi_block\(\)/,/^\}$/' "$BS" | grep -q 'verify_online_client_off'
chk "H4.3 capi_block 只做屏蔽（off）" ok $?
awk '/^verify_capi_block\(\)/,/^\}$/' "$BS" | grep -q 'online_client_on'
chk "H4.4 capi_block 不含放出动作" fail $?
awk '/^verify_capi_release\(\)/,/^\}$/' "$BS" | grep -q 'verify_online_client_on'
chk "H4.5 capi_release 只做放出（on）" ok $?
# 组顺序：CAPIBLOCK 必须排在 BOOT 之前（启动后再改 config 等于没改）
awk '/^GROUP_SEQ=/{print}' "$BS" | grep -qE 'CAPIBLOCK[[:space:]]+BOOT'
chk "H4.6 GROUP_SEQ 中 CAPIBLOCK 先于 BOOT（静态配置先于启动）" ok $?
awk '/^GROUP_SEQ=/{print}' "$BS" | grep -qE 'BOOT[[:space:]]+LOGCONF'
chk "H4.7 BOOT 先于 LOGCONF（先有容器才能采集容器日志）" ok $?
awk '/^GROUP_SEQ=/{print}' "$BS" | grep -qE 'LAPI[[:space:]]+BOUNCERVERIFY'
chk "H4.8 LAPI 先于 BOUNCERVERIFY（先填入再验生效）" ok $?
awk '/^GROUP_SEQ=/{print}' "$BS" | grep -qE 'BOUNCERVERIFY[[:space:]]+ENROLL'
chk "H4.9 BOUNCERVERIFY 先于 ENROLL" ok $?

# H5：LAPI 填入 bouncer 的判定必须内容级（段名对不够，还要 url/enabled/api_key）
echo "===== H5. LAPI → bouncer 填入判定（内容级） ====="
: > "$UCI_STATE"
LAPI_PORT=8080
CONTAINER_IP="10.1.0.100"
verify_bouncer_fill >/dev/null 2>&1
eq "H5.1 无 bouncer 段 → 判不符" "$?" "1"
printf 'crowdsec|bouncer|__type__|bouncer\ncrowdsec|bouncer|api_url|http://10.1.0.100:8080/\ncrowdsec|bouncer|enabled|1\n' >> "$UCI_STATE"
verify_bouncer_fill >/dev/null 2>&1
eq "H5.2 缺 api_key → 仍判不符（不认空壳段）" "$?" "1"
printf 'crowdsec|bouncer|api_key|deadbeefkey\n' >> "$UCI_STATE"
verify_bouncer_fill >/dev/null 2>&1
eq "H5.3 url+enabled+api_key 齐 → 判就绪" "$?" "0"
sed -i '/api_url/d' "$UCI_STATE"
printf 'crowdsec|bouncer|api_url|http://127.0.0.1:8080/\n' >> "$UCI_STATE"
verify_bouncer_fill >/dev/null 2>&1
eq "H5.4 api_url 指向错（非容器 IP）→ 判不符" "$?" "1"

# H6：宿主机日志转发四值（含段名带点的情况）
echo "===== H6. 日志转发判定抗段名变体 ====="
: > "$UCI_STATE"
printf 'system|system000001|__type__|system\nsystem|system000001|log_ip|10.1.0.100\nsystem|system000001|log_port|514\nsystem|system000001|log_proto|udp\nsystem|system000001|log_remote|1\n' >> "$UCI_STATE"
verify_log_forward >/dev/null 2>&1
eq "H6.1 段名带点（system000001）也判就绪" "$?" "0"
sed -i '/log_remote/d' "$UCI_STATE"
verify_log_forward >/dev/null 2>&1
eq "H6.2 缺 log_remote → 判不符" "$?" "1"

# H7：verify 与 build 必须用同一套段定位（防「一个判就绪、一个又去写」的抖动）
echo "===== H7. 段定位单一来源 ====="
_n=$(grep -c "uci show system 2>/dev/null | grep '=system\$'" "$BS" | tr -d ' ')
eq "H7.1 uci show system 解析只出现在 _system_section 一处" "$_n" "1"
grep -q '^_system_section()' "$BS"; chk "H7.2 _system_section 已定义" ok $?

# ============ S 层：SNAT 规则（容器出网的生命线） ============
# 背景：SNAT 一缺，容器就上不了网 → 拉不到 LAPI → 每小时探针都判失败 → 反复重装。
# 所以 SNAT 必须在 PREP 组里、且判定必须覆盖到每个字段。
echo "===== S1. SNAT 段定位不赌段名（LuCI 重建会换名字） ====="
: > "$UCI_STATE"
CONTAINER_IP="10.1.0.100"
_snat_add() {   # $1=段名
    printf 'firewall|%s|__type__|nat\n' "$1" >> "$UCI_STATE"
}
_snat_seed() {  # $1=段名 $2=src_ip $3=snat_ip
    cat >> "$UCI_STATE" <<EOF
firewall|$1|target|SNAT
firewall|$1|name|lxc-snat
firewall|$1|proto|all
firewall|$1|src|lan
firewall|$1|src_ip|$2
firewall|$1|snat_ip|$3
EOF
}

_snat_add lxcsnat; _snat_seed lxcsnat 10.1.0.0/24 10.0.0.201
eq "S1.1 段名 lxcsnat → 命中" "$(_snat_sec)" "lxcsnat"

: > "$UCI_STATE"
_snat_add cfg0a1b2c; _snat_seed cfg0a1b2c 10.1.0.0/24 10.0.0.201
eq "S1.2 LuCI 重建后段名变 cfg0a1b2c → 仍命中" "$(_snat_sec)" "cfg0a1b2c"
verify_snat_rule >/dev/null 2>&1
eq "S1.3 段名变但内容对 → 判就绪（v.93 修的就是这条）" "$?" "0"

: > "$UCI_STATE"
printf 'firewall|@nat[0]|__type__|nat\n' >> "$UCI_STATE"
_snat_seed '@nat[0]' 10.1.0.0/24 10.0.0.201
verify_snat_rule >/dev/null 2>&1
eq "S1.4 匿名段名 @nat[0] → 判就绪" "$?" "0"

: > "$UCI_STATE"
eq "S1.5 无 nat 段 → _snat_sec 失败" "$(_snat_sec; echo "rc=$?")" "rc=1"
verify_snat_rule >/dev/null 2>&1
eq "S1.6 无 nat 段 → 判不符" "$?" "1"

# ============ S2. 每个字段都必须核（少一个就放行 = 容器悄悄上不了网） ============
echo "===== S2. SNAT 逐字段判定 ====="
for _f in target proto src src_ip snat_ip; do
    : > "$UCI_STATE"
    _snat_add lxcsnat
    _snat_seed lxcsnat 10.1.0.0/24 10.0.0.201
    sed -i "/firewall|lxcsnat|$_f|/d" "$UCI_STATE"
    verify_snat_rule >/dev/null 2>&1
    eq "S2 缺 $_f → 判不符" "$?" "1"
done
: > "$UCI_STATE"
_snat_add lxcsnat; _snat_seed lxcsnat 10.1.0.0/24 10.0.0.201
verify_snat_rule >/dev/null 2>&1
eq "S2.6 五字段齐全 → 判就绪" "$?" "0"

# ============ S3. 取值必须与容器网络对齐（写反了等于没配） ============
echo "===== S3. src_ip / snat_ip 与容器网络对齐 ====="
eq "S3.1 _lxc_net 由 CONTAINER_IP 推出网段" "$(_lxc_net)" "10.1.0.0/24"
: > "$UCI_STATE"
_snat_add lxcsnat; _snat_seed lxcsnat 10.2.0.0/24 10.0.0.201
verify_snat_rule >/dev/null 2>&1
eq "S3.2 src_ip 网段错（10.2.0.0/24）→ 判不符" "$?" "1"
: > "$UCI_STATE"
_snat_add lxcsnat; _snat_seed lxcsnat 10.1.0.0/24 10.0.0.99
verify_snat_rule >/dev/null 2>&1
eq "S3.3 snat_ip 不是本机 LAN 地址 → 判不符" "$?" "1"

# ============ S4. SNAT 改为「验证 + 修改」（v.95） ============
echo "===== S4. SNAT 验证 + 修改 ====="
: > "$UCI_STATE"
# 先造一条错的 SNAT（src_ip 写错），build 必须把它校准回来
_snat_add lxcsnat; _snat_seed lxcsnat 10.9.9.0/24 10.9.9.9
build_snat >/dev/null 2>&1
eq "S4.1 build_snat 把 src_ip 校准回容器网段" "$(uci -q get firewall.lxcsnat.src_ip)" "10.1.0.0/24"
eq "S4.2 build_snat 把 snat_ip 校准回本机 LAN 地址" "$(uci -q get firewall.lxcsnat.snat_ip)" "10.0.0.201"
eq "S4.3 build_snat 补齐 target/proto" "$(uci -q get firewall.lxcsnat.target)/$(uci -q get firewall.lxcsnat.proto)" "SNAT/all"
verify_snat; chk "S4.4 改完复核即通过" ok $?
# 幂等：再 build 一次不该产生第二条 SNAT 段
build_snat >/dev/null 2>&1
eq "S4.5 重复 build 不新增 SNAT 段（幂等）" "$(uci show firewall | grep -c '=nat$')" "1"
awk '/^verify_snat_rule\(\)/,/^\}$/' "$BS" | grep -qE 'uci -q (set|delete|add)'
chk "S4.6 verify_snat_rule 内部零 uci 写（验证不越权）" fail $?

# ============ S5. SNAT 在 PREP 组、且在容器启动之前 ============
echo "===== S5. SNAT 的位置与依赖 ====="
grep -q '^NODE_GROUP_snat=PREP$' "$BS"; chk "S5.1 snat 归 PREP 组（容器启动前）" ok $?
grep -qE '^DAG_NODES=.*\bsnat\b' "$BS"; chk "S5.2 snat 在 DAG_NODES 里" ok $?
grep -qE '^PREP_NODES=.*\bsnat\b' "$BS"; chk "S5.3 snat 在 PREP_NODES 里（组级 verify 会覆盖）" ok $?
# v.95：只验不写清单已清空，snat 与其它网络节点一样会真修
grep -qE '^RO_ONLY_NODES=""' "$BS"; chk "S5.4 只验不写清单已清空（v.95 全部可写）" ok $?
awk '/^DEP_ct_boot=/{print}' "$BS" | grep -qE '\bsnat\b'
chk "S5.5 ct_boot 依赖 snat（没 SNAT 不开机）" ok $?
grep -q 'rebuild snat' "$BS"; chk "S5.6 enroll 段有 SNAT 重建兜底" ok $?
grep -q '^verify_snat()' "$BS"; chk "S5.7 verify_snat 节点函数在位" ok $?
grep -q '^build_snat()' "$BS"; chk "S5.8 build_snat 节点函数在位" ok $?

# ============ B 层：写完 api_key 必须重启宿主机 bouncer ============
# 背景（v.94）：build_bouncer_fill 只 uci commit crowdsec 不重启服务，
# 宿主机 bouncer 进程仍持旧 key → 紧接着的 BOUNCERVERIFY 白等 60 秒再判 hard。
# 修法：commit 之后调 _bouncer_service_restart，只重启宿主机那一个。
echo "===== RB1. bouncer_fill 写完 api_key 后重启宿主机服务 ====="
# 取 build_bouncer_fill 函数体
_BF=$(awk '/^build_bouncer_fill\(\)/,/^\}$/' "$BS")
printf '%s\n' "$_BF" | grep -q '_bouncer_uci_apply'
chk "RB1.0 build_bouncer_fill 体已正确提取（前置自检）" ok $?
printf '%s\n' "$_BF" | grep -q 'uci commit crowdsec'
chk "RB1.1 写完 api_key 有 uci commit crowdsec" ok $?
printf '%s\n' "$_BF" | grep -q '_bouncer_service_restart'
chk "RB1.2 commit 之后调用了 _bouncer_service_restart" ok $?
# 顺序：commit 必须在 restart 之前
_ln_commit=$(printf '%s\n' "$_BF" | grep -n 'uci commit crowdsec' | head -n1 | cut -d: -f1)
_ln_restart=$(printf '%s\n' "$_BF" | grep -n '_bouncer_service_restart' | head -n1 | cut -d: -f1)
[ -n "$_ln_commit" ] && [ -n "$_ln_restart" ] && [ "$_ln_commit" -lt "$_ln_restart" ]
chk "RB1.3 先 commit 再重启（顺序不可颠倒）" ok $?

echo "===== RB2. 重启函数本身：只碰宿主机，不重启容器内 crowdsec ====="
_BSR=$(awk '/^_bouncer_service_restart\(\)/,/^\}$/' "$BS")
# v.103 同步大肥鱼改动后：服务名收敛到 BOUNCER_INIT（默认 /etc/init.d/crowdsec-firewall-bouncer），
# 本函数改调 bouncer_svc restart，不再自己拼服务名 —— 断言跟着改口径，
# 但「重启的是宿主机 bouncer」这个保护意图不变：函数体经 bouncer_svc，默认值指向 init 脚本
printf '%s\n' "$_BSR" | grep -q 'bouncer_svc restart' \
    && grep -q 'BOUNCER_INIT:-/etc/init.d/crowdsec-firewall-bouncer' "$BS"
chk "RB2.1 重启宿主机 crowdsec-firewall-bouncer（经 BOUNCER_INIT）" ok $?
printf '%s\n' "$_BSR" | grep -q 'cs_active_on_host'
chk "RB2.2 先判宿主机服务是否在跑（不在跑不抢跑）" ok $?
# 关键：不得重启容器内 crowdsec —— 那会断掉 last_pull，反而害得 BOUNCERVERIFY 判失败
printf '%s\n' "$_BSR" | grep -qE 'systemctl restart crowdsec|_ct_env .*restart crowdsec'
chk "RB2.3 不重启容器内 crowdsec（避免 last_pull 断档）" fail $?
printf '%s\n' "$_BSR" | grep -q 'nft_table_ready'
chk "RB2.4 重启后等 nft 表就位" ok $?

echo "===== RB3. 死代码 _ct_restart_services 已删净 ====="
grep -q '_ct_restart_services' "$BS"
chk "RB3.1 全脚本无 _ct_restart_services 残留（含调用与定义）" fail $?
# 顺带确认「服务重载」这组日志标签也不再出自该函数
grep -q '容器内 systemd-networkd / crowdsec 已重载' "$BS"
chk "RB3.2 原死函数的日志文案已移除" fail $?

# ============ R 层：重启态复验必须跟着 GROUP_SEQ 走 ============
# 背景（v.93 踩过）：rg_restart_verify 曾写死旧 7 组名，改成 8 组后
# GSET_NETWORK 永远是空值 → 重启后第一轮就判「前置组未置位」→ 直接抹容器重装。
# 这是「每小时抹一次容器」级别的故障，必须源码级钉死。
echo "===== R1. 重启态不写死组名 ====="
# 断言的是「遍历 GROUP_SEQ」这件事，不是循环变量叫什么名字——
# 早先写成匹配 `for _g in $GROUP_SEQ`，结果一改循环变量名（_rg_g）就误报。
# 现在放开变量名，只钉「in 的右边必须是 $GROUP_SEQ」。
awk '/^rg_restart_verify\(\)/,/^\}$/' "$BS" | grep -qE 'for +[A-Za-z_]+ +in +\$GROUP_SEQ;? *do'
chk "R1.1 rg_restart_verify 遍历 GROUP_SEQ（不写死组名）" ok $?
for _bad in NETWORK CONFIGURE BOUNCER VERIFY; do
    awk '/^rg_restart_verify\(\)/,/^\}$/' "$BS" | grep -qE "for _g in .*\b$_bad\b"
    chk "R1.2 重启态不含废弃组名 $_bad" fail $?
done

echo "===== R2. 脚本内不残留废弃组名（注释除外） ====="
# 只查「会执行的代码行」：去掉注释行后，抽出所有 verify_X / build_X 词形，
# 再按整词精确比对废弃组名集合。
# 不能一刀切写 BOUNCER/VERIFY/INSTALL：INSTALL 与 BOUNCERVERIFY 都是 v.93 合法组名，
# 而 BOUNCERVERIFY 在子串匹配下会被 BOUNCER 命中，必须整词比对才能区分。
_n=$(grep -vE '^[[:space:]]*#' "$BS" \
     | grep -oE '(verify|build)_[A-Z][A-Z0-9_]*' \
     | grep -cE '^(verify|build)_(NETWORK|CONFIGURE|BOUNCER|VERIFY)$' || true)
_n=${_n:-0}
eq "R2.1 无 verify_/build_ 形式的废弃组名调用" "$_n" "0"

echo "===== R3. 8 组函数成对存在 ====="
for _g in PREP INSTALL CAPIBLOCK BOOT LOGCONF LAPI BOUNCERVERIFY ENROLL; do
    grep -q "^verify_$_g() {" "$BS" && grep -q "^build_$_g() {" "$BS"
    chk "R3 $_g 的 verify/build 都在位" ok $?
done

# ============ 汇总 ============
echo ""
echo "===== BACKUP 旁路由版: PASS=$PASS FAIL=$FAIL ====="
# 清理测试假 init.d，保持沙箱系统干净
for _s in network dnsmasq firewall dropbear ttyd; do rm -f "/etc/init.d/$_s"; done
[ "$FAIL" = 0 ]
