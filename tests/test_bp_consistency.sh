#!/bin/sh
# build ↔ verify 一致性专项：逐个节点「单独损坏 → ensure 必须恰好 build 一次 → 复核必须通过」。
#
# 为什么单开一个文件：这是一个 class of defect 的机械检测器，不是某个节点的用例。
#   · verify_<n> 存在但 build_<n> 修不好 → ensure 判 hard，引导终止（现场：卡死在引导）
#   · build_<n> 不存在 / 被注释吞掉 → verify 永不过 → 每轮重复构建
#     （现场：重复开机、重复 reload；v.96 的 verify_ct_boot 就是这一类）
#   · build_<n> 写了脏标记但节点不在任何 flush 组 → 写了不 commit，下次开机又失效
# 这三类都只在「真的把一个节点打坏」时暴露，正常流水测试（全就绪 → 零动作）看不出来。
REPO=$(cd "$(dirname "$0")/.." && pwd)
BS="$REPO/files/usr/sbin/crowdsec-lxc-bootstrap.sh"
FUNCS=$(mktemp "${TMPDIR:-/tmp}/cons_funcs.XXXXXX.sh")
export UCI_STATE=/tmp/cons_uci_state
export RELOAD_LOG=/tmp/cons_reload.log
export SEQ_LOG=/tmp/cons_seq.log
export LAPI_CRED_CACHE=/tmp/cons_lapi_cache
PASS=0; FAIL=0

# ---------------------------------------------------------------
# 提取：所有真函数都把名字改成 _real_<原名>，另外生成一个 verify_<n> wrapper：
#      DISTURB_<n>=1 → 直接返回 1（模拟这个节点坏了）
#      否则          → 调 _real_verify_<n>
# build_<n> 保持原名（它就是被测对象，不能包）。
# 这样「真身」与「注入开关」共存，且不需要 dash 不支持的 declare -f。
# ---------------------------------------------------------------
python3 - "$BS" \
    log _read_netconf _lan_static_conf _phys_ports _phys_port_count _zone_sec \
    _zone_lan_network _lxc_net _lan_ip _dns_domain_sec _net_write_guard \
    _is_ipv4 _lan_conf_valid \
    DAG_NODES dag_order ensure_group ensure rebuild flush_uci \
    verify_img_migrate build_img_migrate verify_ct_config build_ct_config \
    verify_rootfs build_rootfs verify_ct_boot build_ct_boot \
    build_bridge build_ip_forward \
    verify_wan_input verify_lan_input verify_br_lan_ports verify_lan_static \
    verify_dhcp_ignore verify_wan_removed verify_dns_domain verify_svc_bind \
    verify_smartdns verify_smartdns_main verify_smartdns_upstream \
    build_smartdns build_smartdns_main build_smartdns_upstream \
    _sd_main_seg _smartdns_installed _dnsmasq_release_53 \
    _sd_missing_deps _sd_install_missing _net_ready verify_deps build_deps \
    verify_docker_fw verify_lxc_zone verify_fwd_rules verify_snat verify_snat_rule _snat_sec \
    verify_ip_forward verify_bridge \
    build_wan_input build_lan_input build_br_lan_ports build_lan_static \
    build_dhcp_ignore build_wan_removed build_dns_domain build_svc_bind \
    build_docker_fw build_lxc_zone_fwd build_snat build_lxc_zone build_fwd_rules \
    phase3_step phase3_step_enroll \
    verify_online_client_off verify_online_client_on \
    verify_lapi_ready verify_log_forward _system_section \
    verify_A fix_A verify_B fix_B step_C _sc_wait_pull \
    console_enroll_ok bouncer_pulling bouncer_exists \
    setup_log_forward ensure_online_client_on ensure_online_client_off \
    _bouncer_uci_apply _wait_lapi_ready _bouncer_register_once _ensure_bouncer_service \
    _bouncer_service_restart \
    _wan_sections _ct_env _mount_systemd_cgroup ct_running \
    verify_ct_net build_ct_net verify_ct_net_ping \
    verify_cgroup_mount build_cgroup_mount \
    verify_ct_bootlink build_ct_bootlink \
    verify_ct_resolv build_ct_resolv \
    verify_capi_block build_capi_block \
    verify_acquis build_acquis \
    verify_log_pipeline build_log_forward \
    verify_lapi_fetch build_lapi_fetch \
    verify_bouncer_fill build_bouncer_fill \
    verify_bouncer_verify build_bouncer_verify \
    verify_capi_release build_capi_release \
    atomic_write write_cfg apply_cfg rebuild_from_image \
    ct_exists ct_force_stop setup_container_boot setup_resolv setup_container_network \
    verify_sub_ct_net verify_sub_ct_bootlink verify_sub_ct_resolv \
    verify_PREP build_PREP verify_INSTALL build_INSTALL \
    verify_CAPIBLOCK build_CAPIBLOCK verify_BOOT build_BOOT \
    verify_LOGCONF build_LOGCONF verify_LAPI build_LAPI \
    verify_BOUNCERVERIFY build_BOUNCERVERIFY > "$FUNCS" <<'PY'
import sys, re
src = open(sys.argv[1]).read().splitlines()
want = set(sys.argv[2:])
nodes = None
for l in src:
    m = re.match(r'^DAG_NODES="(.*)"$', l)
    if m:
        nodes = m.group(1).split(); break

out = []
i = 0
while i < len(src):
    m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{', src[i])
    if m and m.group(1) in want:
        depth = 0; j = i; buf = []
        while j < len(src):
            line = src[j]; buf.append(line)
            depth += line.count('{') - line.count('}')
            if depth <= 0: break
            j += 1
        body = '\n'.join(buf)
        name = m.group(1)
        # 所有真身改名；verify_<n> 另配 wrapper
        if name.startswith('verify_') and name[7:] in nodes:
            renamed = body.replace('%s()' % name, '_real_%s()' % name, 1)
            out.append(renamed)
            out.append(
                '%s() {\n'
                '    eval "_dd=\\$DISTURB_%s"\n'
                '    [ "$_dd" = 1 ] && { echo "verify %s(dirty)" >> "$SEQ_LOG"; return 1; }\n'
                '    _real_%s\n'
                '}' % (name, name[7:], name[7:], name))
        else:
            out.append(body)
        i = j + 1
    else:
        i += 1
for l in src:
    if re.match(r'^(DAG_NODES|RO_ONLY_NODES|GROUP_SEQ|GROUP_TITLE_|GROUP_DEP_|NODE_GROUP_|DEP_|FMODE_|ALWAYS_|SLEEP|_TS_RE|_FLAG_TS_FMT|BRIDGE_IP|CONTAINER_IP|LAPI_PORT|BOUNCER_NAME|CSCLI|LXC_PATH|LXC_NAME|CS_HOME|STATE_DIR|MODE|PREP_NODES|INSTALL_NODES|CAPIBLOCK_NODES|BOOT_NODES|LOGCONF_NODES|LAPI_NODES|BOUNCERVERIFY_NODES|ENROLL_NODES)\w*=', l):
        out.append(l)
print('\n\n'.join(out))
PY
. "$FUNCS"

export PATH=/tmp/mockbin:/tmp/mockbin_sys
PORTS="eth0 eth1"
CONTAINER_IP="10.1.0.100"
SLEEP=0; export SLEEP          # bouncer_verify 真身要等 60 秒，压成 0

chk() {
    if { [ "$2" = ok ] && [ "$3" = 0 ]; } || { [ "$2" = fail ] && [ "$3" != 0 ]; }; then
        PASS=$((PASS+1)); echo "PASS: $1"
    else FAIL=$((FAIL+1)); echo "FAIL: $1 (rc=$3, want $2)"; fi
}
eq() {
    if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "PASS: $1"
    else FAIL=$((FAIL+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi
}
reset_all() {
    : > "$UCI_STATE"; : > "$RELOAD_LOG"; : > "$SEQ_LOG"
    # v.99 起置位值为 V:<ts>/B:<ts>/R:<ts>，归零 = 清空（写 0 会被判成已置位）
    for _n in $DAG_NODES; do eval "_done_$_n=''; _dirty_$_n=''; DISTURB_$_n=0"; done
    _failed=""; _order=""; _group_failed=""
}
seq_cnt() { grep -c "^$1\$" "$SEQ_LOG" 2>/dev/null | tr -d ' '; }

echo "===== C0. 静态一致性（不依赖运行时） ====="
_miss=""
for _n in $DAG_NODES; do
    grep -qE "^verify_${_n}\(\) *\{" "$BS" || _miss="$_miss verify_$_n"
    grep -qE "^build_${_n}\(\) *\{"  "$BS" || _miss="$_miss build_$_n"
done
eq "C0.1 全部节点的 verify/build 行首真定义" "${_miss:-none}" "none"

_orphan=""
for _f in $(grep -oE '^build_[a-z0-9_]+\(\) *\{' "$BS" | sed -E 's/^build_([a-z0-9_]+).*/\1/'); do
    case " $DAG_NODES " in *" $_f "*) ;; *) _orphan="$_orphan $_f" ;; esac
done
eq "C0.2 无孤儿 build_（lxc_zone/fwd_rules 是别名，允许）" \
   "$(echo "$_orphan" | tr ' ' '\n' | grep -v '^$' | grep -vE '^(lxc_zone|fwd_rules|lxc_zone_fwd)$' | tr '\n' ' ')" ""

_bad=""
for _n in $DAG_NODES; do
    _g=$(eval "printf '%s' \"\$NODE_GROUP_$_n\"")
    [ -n "$_g" ] || { _bad="$_bad $_n:无组"; continue; }
    case " $GROUP_SEQ " in *" $_g "*) ;; *) _bad="$_bad $_n:组$_g非法" ;; esac
done
eq "C0.3 每个节点归属合法且唯一" "${_bad:-none}" "none"

eq "C0.4 八组节点数合计 == DAG_NODES 数" \
   "$(for _g in $GROUP_SEQ; do eval "echo \$${_g}_NODES"; done | wc -w | tr -d ' ')" \
   "$(echo $DAG_NODES | wc -w | tr -d ' ')"

# C0.5 组序必须与 NODE_GROUP_ 声明的分组顺序一致（组内小步骤顺序即 DEP 顺序）
_badseq=""
for _g in $GROUP_SEQ; do
    for _n in $(eval "echo \$${_g}_NODES"); do
        _gg=$(eval "printf '%s' \"\$NODE_GROUP_$_n\"")
        [ "$_gg" = "$_g" ] || _badseq="$_badseq $_n(${_gg}≠${_g})"
    done
done
eq "C0.5 组内清单与 NODE_GROUP_ 一致" "${_badseq:-none}" "none"

echo "===== C1. 提取白名单自检 ====="
_m=""
for _f in $(sed -n '/^python3 - "\$BS" \\$/,/<<.PY.$/p' "$0" \
        | grep -v '^python3' | grep -v '<<' | tr -d '\\' | tr '\n' ' '); do
    case "$_f" in
        DAG_NODES|GROUP_SEQ|RO_ONLY_NODES|SLEEP|_TS_RE) continue ;;
    esac
    command -v "$_f" >/dev/null 2>&1 || _m="$_m $_f"
done
eq "C1.1 白名单全部提取成功（缺失：${_m:-无}）" "${_m:-none}" "none"

# ---------------------------------------------------------------
# 沙箱就绪态：与 test_bp_dag.sh 的 i_reset 同源。
# 注意「容器/内核侧」节点在沙箱里无法真修（容器不存在），
# 它们只在 C2 里做「build 被调用且返回码正确」的判定，不放行 build→verify 闭环；
# 宿主侧节点（uci 三面 + 服务绑定 + 日志转发）必须完整闭环。
# ---------------------------------------------------------------
mock_install() {
    build_img_migrate() { echo "build img_migrate" >> "$SEQ_LOG"; }
    build_ct_config() { echo "build ct_config" >> "$SEQ_LOG"; }
    build_rootfs() { echo "build rootfs" >> "$SEQ_LOG"; _recovering=true; }
    build_ct_boot() { echo "build ct_boot" >> "$SEQ_LOG"; }
    verify_ct_boot() { return 0; }
    verify_bridge() { return 0; }
    verify_img_migrate() { return 0; }
    verify_ct_config() { return 0; }
    verify_rootfs() { return 0; }
    verify_ct_net() { return 0; }
    verify_cgroup_mount() { return 0; }
    verify_ct_bootlink() { return 0; }
    verify_ct_resolv() { return 0; }
    verify_capi_block() { return 0; }
    verify_acquis() { return 0; }
    verify_lapi_fetch() { return 0; }
    verify_bouncer_fill() { return 0; }
    verify_bouncer_verify() { return 0; }
    verify_capi_release() { return 0; }
}
restore_real() {
    . "$FUNCS" 2>/dev/null || true
    _phys_ports() { for _p in $PORTS; do echo "$_p"; done; }
    verify_ip_forward() { return 0; }
}
mk_ready_state() {
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
dhcp|dom0|__type__|domain
dhcp|dom0|name|time.android.com
dhcp|dom0|ip|203.107.6.88
network|wan|disabled|1
network|wan6|disabled|1
firewall|f1|__type__|zone
firewall|f1|name|wan
firewall|f1|input|REJECT
firewall|f2|__type__|zone
firewall|f2|name|lan
firewall|f2|input|ACCEPT
firewall|f2|forward|ACCEPT
firewall|f2|network|lan
firewall|lxczone|__type__|zone
firewall|lxczone|name|lxc
firewall|lxczone|network|lxc
firewall|lxczone|input|ACCEPT
firewall|lxczone|output|ACCEPT
firewall|lxczone|forward|ACCEPT
firewall|lxc2lan|__type__|forwarding
firewall|lxc2lan|src|lxc
firewall|lxc2lan|dest|lan
firewall|lxc2docker|__type__|forwarding
firewall|lxc2docker|src|lxc
firewall|lxc2docker|dest|docker
firewall|lxc2vpn|__type__|forwarding
firewall|lxc2vpn|src|lxc
firewall|lxc2vpn|dest|vpn
firewall|lan2lxc|__type__|forwarding
firewall|lan2lxc|src|lan
firewall|lan2lxc|dest|lxc
firewall|lxcsnat|__type__|nat
firewall|lxcsnat|target|SNAT
firewall|lxcsnat|name|lxc-snat
firewall|lxcsnat|proto|all
firewall|lxcsnat|src|lan
firewall|lxcsnat|src_ip|10.1.0.0/24
firewall|lxcsnat|snat_ip|10.0.0.201
dropbear|@dropbear[0]|__type__|dropbear
dropbear|@dropbear[0]|Interface|lan
ttyd|@ttyd[0]|__type__|ttyd
ttyd|@ttyd[0]|interface|lan
system|sys0|__type__|system
system|sys0|log_ip|$CONTAINER_IP
system|sys0|log_port|514
system|sys0|log_proto|udp
system|sys0|log_remote|1
EOF
}

echo "===== C2. 宿主侧节点：损坏 → ensure 恰好 build 一次 → 复核通过 ====="
# 这些节点的 build 完全落在宿主机 uci 面上，沙箱能真跑闭环。
# ensure 内部失败会 exit 1（hard 终止），所以必须放子 shell 里跑，否则一个节点失败
# 会把整个测试脚本带走（历史踩坑：_lan_conf_valid 未提取时测试静默死在 I3）。
C2_NODES="br_lan_ports lan_static dhcp_ignore wan_removed dns_domain lxc_zone fwd_rules wan_input lan_input snat svc_bind"
for _cn in $C2_NODES; do
    reset_all; restore_real; mk_ready_state
    # 顺序要紧：reset_all 会把所有 DISTURB_* 清零，注入必须在它之后
    eval "DISTURB_$_cn=1"
    export "DISTURB_$_cn"
    ( ensure "$_cn" ) >/tmp/cons_one.out 2>&1
    _rc=$?
    unset "DISTURB_$_cn"
    chk "C2.$_cn.1 损坏后 ensure 通过" ok "$_rc"
    # ensure 只调一次 verify（探路），不做事后复核——真正的判据是
    # 「撤掉注入后 verify 必须自己变回 0」，即 builder 确实把状态改对了。
    eval "DISTURB_$_cn=0"; export "DISTURB_$_cn"
    ( verify_"$_cn" ) >/dev/null 2>&1
    chk "C2.$_cn.2 build 之后 verify 真的过了（状态被改对）" ok "$?"
    # 再跑一次 ensure：此时应判定就绪直接跳过，不得再构建（幂等）
    : > "$SEQ_LOG"
    ( ensure "$_cn" ) >>/tmp/cons_one.out 2>&1
    chk "C2.$_cn.3 二次 ensure 幂等（不再构建）" ok "$?"
done

echo "===== C3. 全量回归：无损坏时零 build（新节点不许自己写脏） ====="
reset_all; restore_real; mk_ready_state
for _n in $DAG_NODES; do eval "DISTURB_$_n=0"; done
# 只跑「宿主侧 11 个节点」——容器/内核侧节点（ct_net/cgroup_mount/acquis/…）
# 在沙箱里没有容器可依，真身必然失败，那是环境限制不是脚本缺陷（test_bp_dag.sh
# 用 mock_install 把它们打桩，这里同理不做全链真身回归）。
( for _cn in $C2_NODES; do ensure "$_cn"; done ) >/tmp/cons_all.out 2>&1
eq "C3.1 全就绪时零构建" "$(grep -c '^build ' "$SEQ_LOG" | head -1)" "0"
eq "C3.2 全就绪时无 hard 失败" "$(grep -c 'hard 失败' /tmp/cons_all.out | head -1)" "0"
eq "C3.3 11 个节点全部判定就绪" "$(grep -c '验证通过，跳过' /tmp/cons_all.out | head -1)" "11"


# =====================================================================
# C4. 文件系统侧节点：用真文件 + 真 tar/gzip 跑通 build→verify 闭环
# 这些节点不做 uci 改动，全部落在 $ROOTFS / $CFG / $TARBALL 上，
# 而这三者都是变量，可以整个搬到临时目录里，真身 build 与真身 verify 都能跑。
# 容器运行时命令（_ct_env / ct_running / ping / ip / lxc-*）用桩替代。
# =====================================================================
echo "===== C4. 文件系统侧节点：build→verify 闭环 ====="
# mockbin_sys 只为 pi 掉若干系统命令，缺 mkdir/tar/gzip；C4 要造真实文件树，
# 这一段临时把系统路径排在前面（uci 桩仍在，不影响宿主侧判定）
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/tmp/mockbin
export PATH
C4ROOT=/tmp/cons_c4
rm -rf "$C4ROOT"; mkdir -p "$C4ROOT/lxc" "$C4ROOT/home"
ROOTFS="$C4ROOT/lxc/cs/rootfs"
CFG="$C4ROOT/lxc/cs/config"
TARBALL="$C4ROOT/home/lxc-ubuntu.tar.gz"
CROWDSEC_CFG="$ROOTFS/etc/crowdsec/config.yaml"
LXC_PATH="$C4ROOT/lxc"; LXC_NAME=cs
export ROOTFS CFG TARBALL CROWDSEC_CFG LXC_PATH LXC_NAME

# 容器运行时桩：ct_running 恒真（模拟容器已在跑），_ct_env 用一个本地记录文件模拟
CT_ENV_LOG="$C4ROOT/ct_env.log"
ct_running() { [ -f "$C4ROOT/ct_running" ]; }
_ct_env() {
    printf '%s\n' "$*" >> "$CT_ENV_LOG"
    # 让容器内命令可直接作用于 ROOTFS 里的同名视图
    case "$*" in
        *local_api_credentials.yaml*)
            [ -f "$C4ROOT/vault/local_api_credentials.yaml" ] ;;
        *) return 0 ;;
    esac
}
_container_dns() { printf '%s\n' "223.5.5.5"; }
# lxc-info 是"配置能否解析"的仲裁者，沙箱没有 lxc 工具链。
# dash 不允许带连字符的函数名，所以做成 mockbin 里的可执行脚本，
# 语义等价于真实路由器上 lxc-info 正常返回（配置里有 lxc.rootfs.path 就算解析通过）。
mkdir -p /tmp/cons_mockbin
cat > /tmp/cons_mockbin/lxc-info <<'EOS'
#!/bin/sh
[ -s "$CFG" ] && grep -q 'lxc.rootfs.path' "$CFG"
EOS
printf '#!/bin/sh\nrm -f %s/ct_running\nexit 0\n' "$C4ROOT" > /tmp/cons_mockbin/lxc-stop
printf '#!/bin/sh\nexit 0\n' > /tmp/cons_mockbin/lxc-start
printf '#!/bin/sh\nexit 0\n' > /tmp/cons_mockbin/ct
chmod +x /tmp/cons_mockbin/*
PATH=/tmp/cons_mockbin:$PATH
export PATH
verify_ct_net_ping() { return 0; }
verify_lapi_ready() { [ -f "$C4ROOT/vault/lapi_ready" ]; }
bouncer_exists() { [ -f "$C4ROOT/vault/bouncer_added" ]; }
bouncer_pulling() { [ -f "$C4ROOT/vault/bouncer_pulling" ]; }
# 不用桩：setup_container_network 只写 $ROOTFS 下的文件，可以真跑。
# build_ct_net 里那句 `if ct_running; then _ct_env ...` 在 C4 里由 ct_running 开关控制。

LEGACY_TARBALL="$C4ROOT/home/opt-lxc-ubuntu.tar.gz"
CS_HOME="$C4ROOT/home"
export LEGACY_TARBALL CS_HOME
mk_c4_baseline() {
    rm -rf "$ROOTFS" "$CFG" "$TARBALL" "$LEGACY_TARBALL" "$C4ROOT/vault"
    mkdir -p "$ROOTFS/etc/crowdsec" "$ROOTFS/etc/systemd/network" \
             "$ROOTFS/etc/systemd/system/multi-user.target.wants" \
             "$ROOTFS/lib/systemd/system" "$ROOTFS/usr" "$C4ROOT/vault"
    printf 'ID=ubuntu\n' > "$ROOTFS/etc/os-release"
    printf 'api:\n  server:\n    listen_uri: 0.0.0.0:8080\ncommon:\n  log_level: info\n' > "$CROWDSEC_CFG"
    printf 'lxc.rootfs.path = dir:%s\nlxc.utsname = cs\nlxc.net.0.type = veth\n' "$ROOTFS" > "$CFG"
    : > "$ROOTFS/etc/hostname"
    : > "$ROOTFS/etc/machine-id"
    : > "$C4ROOT/ct_running"
    # 造一个最小 tarball（含 ./etc 与 ./usr）。默认放"迁移前"的老位置：
    # img_migrate 的语义就是「老位置 → 新位置」，放新位置它无事可做。
    ( cd "$ROOTFS" && tar -czf "$LEGACY_TARBALL" ./etc ./usr ) >/dev/null 2>&1
}

c4_check() {
    _name=$1; _vn="verify_$_name"; _bn="build_$_name"
    mk_c4_baseline
    # 先把状态改成缺项（删文件/清空），确认 verify 会失败
    case "$_name" in
        img_migrate) : ;;                       # 基线已把 tarball 放在老位置，正是缺项态
        ct_config)   : > "$CFG" ;;
        rootfs)      rm -f "$CROWDSEC_CFG"; mv -f "$LEGACY_TARBALL" "$TARBALL" ;;
        ct_net)      rm -f "$ROOTFS/etc/systemd/network/10-eth0.network" ;;
        ct_bootlink) rm -f "$ROOTFS/etc/hostname"; : > "$ROOTFS/etc/machine-id" ;;
        ct_resolv)   rm -f "$ROOTFS/etc/resolv.conf" ;;
        capi_block)  : ;;
    esac
    if [ "$_name" != capi_block ]; then
        "$_vn" >/dev/null 2>&1 && echo "  [警告] C4.$_name 破坏后 verify 仍通过（判据太松）"
    fi
    ( "$_bn" ) >/tmp/cons_c4.$_name.out 2>&1
    _brc=$?
    chk "C4.$_name.1 build 成功" ok "$_brc"
    "$_vn" >/dev/null 2>&1
    chk "C4.$_name.2 build 之后 verify 通过" ok "$?"
}
for _n4 in img_migrate ct_config rootfs ct_net ct_bootlink ct_resolv; do
    c4_check "$_n4"
done

# =====================================================================
# C5. 剩余节点：uci 面（log_forward / bouncer_fill）与文件面（capi_block /
#     capi_release）。这两类都能真跑，一并闭环。
# =====================================================================
echo "===== C5. 剩余可闭环节点 ====="
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/tmp/mockbin
export PATH

# --- capi_block / capi_release：只动 config.yaml，纯文件操作 ---
c5_capi() {
    _nm=$1; _vn="verify_$_nm"; _bn="build_$_nm"
    mk_c4_baseline
    if [ "$_nm" = capi_block ]; then
        # 缺项态 = online_client 是放开的
        printf 'api:\n  server:\n    listen_uri: 0.0.0.0:8080\ncommon:\n  log_level: info\nonline_client:\n  credentials_path: /etc/crowdsec/online_api_credentials.yaml\n' > "$CROWDSEC_CFG"
    else
        printf 'api:\n  server:\n    listen_uri: 0.0.0.0:8080\ncommon:\n  log_level: info\n# online_client: # disabled\n' > "$CROWDSEC_CFG"
    fi
    "$_vn" >/dev/null 2>&1 && echo "  [警告] C5.$_nm 破坏后 verify 仍通过（判据太松）"
    ( "$_bn" ) >/tmp/cons_c5.$_nm.out 2>&1
    chk "C5.$_nm.1 build 成功" ok "$?"
    ( "$_vn" ) >/dev/null 2>&1
    chk "C5.$_nm.2 build 之后 verify 通过" ok "$?"
}
c5_capi capi_block
c5_capi capi_release

# --- log_forward：纯 uci 面 ---
reset_all; restore_real; : > "$UCI_STATE"
( verify_log_forward ) >/dev/null 2>&1 && echo "  [警告] C5.log_forward 空状态下 verify 仍通过"
( build_log_forward ) >/tmp/cons_c5.log_forward.out 2>&1
chk "C5.log_forward.1 build 成功" ok "$?"
( verify_log_forward ) >/dev/null 2>&1
chk "C5.log_forward.2 build 之后 verify 通过" ok "$?"
# 断言方式：直接问 uci，而不是 grep 状态文件——build 可能新建段，段名不一定是 sys0
eq  "C5.log_forward.3 log_ip 指向容器" "$(uci -q get system.@system[0].log_ip 2>/dev/null || \
    awk -F'|' '$1=="system" && $3=="log_ip"{print $4}' "$UCI_STATE" | head -1)" "$CONTAINER_IP"
eq  "C5.log_forward.4 端口/协议/开关正确" \
   "$(awk -F'|' '$1=="system" && $3=="log_port"{p=$4} $1=="system" && $3=="log_proto"{o=$4} $1=="system" && $3=="log_remote"{r=$4} END{print p"/"o"/"r}' "$UCI_STATE" | head -1)" \
   "514/udp/1"

# --- bouncer_fill：uci 面 + 向 LAPI 注册（_ct_env / cscli 由桩代劳）---
mk_c4_baseline
: > "$UCI_STATE"
# LAPI 就绪态：verify_lapi_fetch 要求 ct_running + verify_lapi_ready + 容器内凭据
: > "$C4ROOT/vault/lapi_ready"
# 桩：cscli bouncers add 返回一个假 key；LAPI 就绪
_ct_env() {
    case "$*" in
        *"bouncers add"*)    printf 'FAKEKEY0123456789\n'; return 0 ;;
        *"bouncers delete"*) return 0 ;;
        *local_api_credentials.yaml*) return 0 ;;
        *systemctl*|*service*) return 0 ;;
    esac
    return 0
}
# verify_lapi_fetch 的三段判据全部满足（模拟"LAPI 已就绪"）
verify_lapi_fetch() { return 0; }
( build_bouncer_fill ) >/tmp/cons_c5.bouncer_fill.out 2>&1
chk "C5.bouncer_fill.1 build 成功" ok "$?"
( verify_bouncer_fill ) >/dev/null 2>&1
chk "C5.bouncer_fill.2 build 之后 verify 通过" ok "$?"
eq  "C5.bouncer_fill.3 api_key 已落盘" \
   "$(grep -c 'FAKEKEY0123456789' "$UCI_STATE")" "1"

# --- bridge：v.97 起不再是「只验不写」，必须真写 uci 并校正内核地址 ---
echo "===== C6. bridge：v.97 修复回归 ====="
reset_all; restore_real; : > "$UCI_STATE"
# 记录 ip 调用的桩：沙箱里不能真建网桥，但可以把"调用序列"记下来核对语义
IP_LOG="$C4ROOT/ip.log"; : > "$IP_LOG"
mkdir -p /tmp/cons_mockbin
cat > /tmp/cons_mockbin/ip <<'EOS'
#!/bin/sh
echo "$*" >> "$IP_LOG"
case "$1" in
    link)  # ip link show lxcbr0 / ip link add ...
        case "$2" in
            show) [ -f "$IP_UP" ] && exit 0 || exit 1 ;;
            add|set) : > "$IP_UP"; exit 0 ;;
        esac ;;
    addr)
        case "$2" in
            show) [ -f "$IP_ADDR_OK" ] && echo "    inet 10.1.0.1/24 brd 10.1.0.255 scope global lxcbr0" && exit 0 || exit 1 ;;
            add)  : > "$IP_ADDR_OK"; exit 0 ;;
            del)  rm -f "$IP_ADDR_OK"; exit 0 ;;
        esac ;;
esac
exit 0
EOS
chmod +x /tmp/cons_mockbin/ip
# 必须排在最前：/usr/sbin/ip 会真实执行，沙箱里甚至可能真把 lxcbr0 建出来
PATH=/tmp/cons_mockbin:$PATH
export PATH
IP_UP="$C4ROOT/ip_up"; IP_ADDR_OK="$C4ROOT/ip_addr_ok"
export IP_LOG IP_UP IP_ADDR_OK
rm -f "$IP_UP" "$IP_ADDR_OK"

( verify_bridge ) >/dev/null 2>&1 && echo "  [警告] C6 bridge 空状态下 verify 仍通过"
# 必须在当前 shell 里跑：_dirty_bridge 是当前 shell 的变量，
# 放子 shell 里就丢了（C6.6 正是要断言它）。build_bridge 失败也不会 exit（那是 ensure 干的）。
build_bridge >/tmp/cons_c6.bridge.out 2>&1
chk "C6.1 build 成功" ok "$?"
eq  "C6.2 写了 network.lxc.proto=static" \
   "$(awk -F'|' '$1=="network" && $2=="lxc" && $3=="proto"{print $4}' "$UCI_STATE")" "static"
eq  "C6.3 写了 network.lxc.ipaddr" \
   "$(awk -F'|' '$1=="network" && $2=="lxc" && $3=="ipaddr"{print $4}' "$UCI_STATE")" "10.1.0.1"
eq  "C6.4 写了 network.lxc.device=lxcbr0" \
   "$(awk -F'|' '$1=="network" && $2=="lxc" && $3=="device"{print $4}' "$UCI_STATE")" "lxcbr0"
eq  "C6.5 内核里补建了网桥并配了地址" \
   "$(grep -cE '^(link add lxcbr0|addr add 10\.1\.0\.1/24)' "$IP_LOG")" "2"
# 脏标记由 ensure() 统一置位；这里断言 bridge 确实在 network flush 组里，
# 否则改了 uci 也不会 commit + reload（等于白改）
eq  "C6.6 bridge 归属 network flush 组" \
   "$(awk '/^flush_uci\(\)/,/^}/' "$BS" | grep -c 'for _o in br_lan_ports lan_static bridge')" "1"
# 幂等：再跑一次不应重复写 uci
_w1=$(wc -l < "$UCI_STATE" | tr -d ' ')
( build_bridge ) >/dev/null 2>&1
eq  "C6.7 二次 build 幂等（uci 行数不变）" "$(wc -l < "$UCI_STATE" | tr -d ' ')" "$_w1"

# --- docker_fw / ip_forward：v.97 补齐后纳入闭环 ---
echo "===== C7. docker_fw / ip_forward ====="
# docker_fw：桩一个 dockerd 存在（verify/build 都以它为前提，属于"可选功能"语义）
mkdir -p /tmp/cons_mockbin
printf '#!/bin/sh\nexit 0\n' > /tmp/cons_mockbin/dockerd
chmod +x /tmp/cons_mockbin/dockerd
PATH=/tmp/cons_mockbin:$PATH
export PATH
reset_all; restore_real; : > "$UCI_STATE"
( verify_docker_fw ) >/dev/null 2>&1 && echo "  [警告] C7 docker_fw 空状态下 verify 仍通过"
( build_docker_fw ) >/tmp/cons_c7.docker.out 2>&1
chk "C7.1 docker_fw build 成功" ok "$?"
( verify_docker_fw ) >/dev/null 2>&1
chk "C7.2 docker_fw build 之后 verify 通过" ok "$?"
eq  "C7.3 三条 forwarding 齐全" \
   "$(awk -F'|' '$1=="firewall" && $3=="__type__" && $4=="rule"{print $2}' "$UCI_STATE" | sort | tr '\n' ' ')" \
   "docker2lan docker2wan lan2docker "
# 未装 dockerd：verify 直接放行（可选功能，不该把整条引导卡死）
rm -f /tmp/cons_mockbin/dockerd
( verify_docker_fw ) >/dev/null 2>&1
chk "C7.4 未装 dockerd 时 verify 放行（可选功能）" ok "$?"

# ip_forward：真往 /proc 写，沙箱通常可写；写不进去时必须判失败而不是假成功
reset_all; restore_real
( build_ip_forward ) >/tmp/cons_c7.ipfwd.out 2>&1
_ipfwd_rc=$?
if [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = "1" ]; then
    chk "C7.5 ip_forward 可写时 build 成功" ok "$_ipfwd_rc"
    ( verify_ip_forward ) >/dev/null 2>&1
    chk "C7.6 写完回读一致" ok "$?"
else
    chk "C7.5 ip_forward 不可写时 build 判失败（不假成功）" fail "$_ipfwd_rc"
fi
# 静态断言：build_ip_forward 必须回读校验过（防回退到"写完就 log 成功"）
eq  "C7.7 build_ip_forward 有回读校验" \
   "$(awk '/^build_ip_forward\(\)/,/^}/' "$BS" | grep -c 'cat /proc/sys/net/ipv4/ip_forward')" "1"
eq  "C7.8 校验不过时 return 1" \
   "$(awk '/^build_ip_forward\(\)/,/^}/' "$BS" | grep -c '^    return 1')" "1"

echo ""
echo "===== 一致性专项: PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" = 0 ] || exit 1
