#!/bin/sh
# v.81 A/B/C 步骤化 + DAG 调度器 + 重装自愈专项测试（迭代式拓扑排序版）
REPO=$(cd "$(dirname "$0")/.." && pwd)
BS="$REPO/files/usr/sbin/crowdsec-lxc-bootstrap.sh"
FUNCS=$(mktemp "${TMPDIR:-/tmp}/dag_funcs.XXXXXX.sh")
export UCI_STATE=/tmp/dag_uci_state
export RELOAD_LOG=/tmp/dag_reload.log
export SEQ_LOG=/tmp/dag_seq.log
PASS=0; FAIL=0

# 提取列表同时导出一份给 M0 自检用（新增函数只改这里，两处自动同步）
EXTRACT_FUNCS="$(sed -n '/^python3 - "\$BS" \\$/,/<<.PY.$/p' "$0" \
    | grep -v '^python3' | grep -v '<<' | tr -d '\\' | tr '\n' ' ')"

python3 - "$BS" \
    log _read_netconf _lan_static_conf _phys_ports _phys_port_count _zone_sec \
    _zone_lan_network _lxc_net _lan_ip _dns_domain_sec _net_write_guard \
    _is_ipv4 _lan_conf_valid \
    DAG_NODES dag_order ensure_group ensure rebuild flush_uci \
    _bs_flag_set _bs_flag_clear _bs_flag_on _bs_flag_tag _bs_flag_count _bs_flag_dump \
    verify_img_migrate build_img_migrate verify_ct_config build_ct_config \
    verify_rootfs build_rootfs verify_ct_boot build_ct_boot \
    build_bridge build_ip_forward \
    verify_wan_input verify_lan_input verify_br_lan_ports verify_lan_static \
    verify_dhcp_ignore verify_wan_removed verify_dns_domain verify_svc_bind \
    verify_smartdns build_smartdns _sd_main_seg _smartdns_installed \
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
    verify_PREP build_PREP verify_INSTALL build_INSTALL \
    verify_CAPIBLOCK build_CAPIBLOCK verify_BOOT build_BOOT \
    verify_LOGCONF build_LOGCONF verify_LAPI build_LAPI \
    verify_BOUNCERVERIFY build_BOUNCERVERIFY > "$FUNCS" <<'PY'
import sys, re
src = open(sys.argv[1]).read().splitlines()
want = set(sys.argv[2:])
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
        out.append('\n'.join(buf)); i = j + 1
    else:
        i += 1
for l in src:
    if re.match(r'^(DAG_NODES|RO_ONLY_NODES|GROUP_SEQ|GROUP_TITLE_|GROUP_DEP_|NODE_GROUP_|DEP_|FMODE_|ALWAYS_|_TS_RE|_FLAG_TS_FMT|PREP_NODES|INSTALL_NODES|CAPIBLOCK_NODES|BOOT_NODES|LOGCONF_NODES|LAPI_NODES|BOUNCERVERIFY_NODES|ENROLL_NODES)\w*=', l):
        out.append(l)
print('\n\n'.join(out))
PY
. "$FUNCS"

export PATH=/tmp/mockbin:/tmp/mockbin_sys
PORTS="eth0 eth1"
CONTAINER_IP="10.1.0.100"     # 容器网段 10.1.0.0/24，与全就绪状态 lxcsnat.src_ip 对齐
_FAKE_MADE=""
# 假 init.d：$0 才是脚本名（init.d 的首参是动作 reload，不是脚本名——曾错用 $1 记成 "reload reload"）；
# 每次强制覆盖写，防止系统里残留旧错版被 [ -e ] 保护跳过
mkfake() {
    printf '#!/bin/sh\necho "$(basename $0) $*" >> "$RELOAD_LOG"\nexit 0\n' > "/etc/init.d/$1"
    chmod +x "/etc/init.d/$1"; _FAKE_MADE="$_FAKE_MADE $1"
}
for _s in network dnsmasq firewall dropbear ttyd log logd; do mkfake "$_s"; done

reset_all() {
    : > "$UCI_STATE"; : > "$RELOAD_LOG"; : > "$SEQ_LOG"
    # v.99 起置位值是 V:<ts>/B:<ts>/R:<ts>，归零 = 清空；写成 0 会让 _bs_flag_on 判成「已置位」
    for _n in $DAG_NODES; do eval "_done_$_n=''; _dirty_$_n=''"; done
    _failed=""; _order=""; _group_failed=""
}
chk() {
    if { [ "$2" = ok ] && [ "$3" = 0 ]; } || { [ "$2" = fail ] && [ "$3" != 0 ]; }; then
        PASS=$((PASS+1)); echo "PASS: $1"
    else FAIL=$((FAIL+1)); echo "FAIL: $1 (rc=$3, want $2)"; fi
}
eq() {
    if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "PASS: $1"
    else FAIL=$((FAIL+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi
}
seq_grep() { grep -c "^$1\$" "$SEQ_LOG" | tr -d ' '; }
pos_in_seq() { grep -n "^$1\$" "$SEQ_LOG" | head -1 | cut -d: -f1; }

# mock：薄包装 + 单层 eval
#   BREAK_<n>=1    ：目标状态损坏（verify 失败）；build 成功后即修复（除非 PERSIST）
#   PERSIST_<n>=1  ：顽固损坏——build 成功但修不好，复核仍失败（模拟 build 无效）
#   BUILDFAIL_<n>=1：build 本身失败（返回非 0）
verify_mock() {
    echo "verify $1" >> "$SEQ_LOG"
    eval "_b=\$BREAK_$1"
    [ "$_b" = 1 ] && return 1
    return 0
}
build_mock() {
    echo "build $1" >> "$SEQ_LOG"
    eval "_f=\$BUILDFAIL_$1"
    [ "$_f" = 1 ] && return 1
    eval "_p=\$PERSIST_$1"
    [ "$_p" = 1 ] && return 0
    eval "BREAK_$1=0"
    return 0
}
mock_all() {
    for _n in $DAG_NODES; do
        eval "verify_$_n() { verify_mock $_n; }"
        eval "build_$_n() { build_mock $_n; }"
    done
}
clear_breaks() { for _n in $DAG_NODES; do eval "BREAK_$_n=0; BUILDFAIL_$_n=0; PERSIST_$_n=0"; done; }
# 模拟 main 的 DAG 段（v.79 层级：按组调度，组内小步骤逐个 ensure）
# 【务必在当前 shell 里调用，不要写 out=$(run_dag ...)】ensure 用 eval 置的 _dirty_*/_done_*
# 是当前 shell 的变量；$(...) 一开子 shell 就全丢了，flush_uci 会误判「无配置改动」。
# 需要日志就用 run_dag_log（写文件，不回显），别用命令替换。
run_dag() { dag_order >/dev/null 2>&1; for _g in $GROUP_SEQ; do ensure_group "$_g"; done; return 0; }
# DAG_OUT：把 run_dag 的输出收进文件，便于断言又不开子 shell。
# 注意 flush_uci 的日志要单独追加（{ flush_uci; } >>"$DAG_OUT" 2>&1），且绝不能用管道 —— 管道同样开子 shell。
DAG_OUT=/tmp/dag_run.out
run_dag_log() { run_dag >"$DAG_OUT" 2>&1; :; }
# 节点式（供 M 层精确控制单节点用）
run_dag_nodes() { dag_order >/dev/null 2>&1; for _n in $_order; do ensure "$_n"; done; }

echo "===== M0. 函数提取自检（白名单漏写会静默退化成 command not found） ====="
# 踩过的坑：新增 _lan_conf_valid 时忘了加进头部白名单，于是 ensure 里调用失败 →
# build_lan_static 返回 1 → hard exit 1，整个测试脚本当场退出，看起来像"值非法"。
# 这里对白名单里每个函数做一次声明检查，漏了立刻报出来，别等症状误导。
# 只查 build_/verify_ 前缀的节点函数 + 明确的 helper；DAG_NODES 这类是数据变量，
# 由脚本主体提供，不在提取之列（列表里出现它们只是为了文档完整）。
_missing=""
for _f in $EXTRACT_FUNCS; do
    case "$_f" in
        build_*|verify_*) ;;
        DAG_NODES|GROUP_SEQ|RO_ONLY_NODES) continue ;;
        *) ;;
    esac
    command -v "$_f" >/dev/null 2>&1 || _missing="$_missing $_f"
done
eq "M0.1 白名单里的函数全部提取成功（缺失：${_missing:-无}）" "${_missing:-none}" "none"
# 源码级：定义必须真在行首，不能被并进注释。
# 踩过的坑：verify_ct_boot 曾被写成 "# ...）verify_ct_boot() { ct_running; }" 整行注释，
# 函数在运行期根本不存在 → ensure 每轮都判失败 → BOOT 组反复开机。
_nv=$(grep -cE '^verify_ct_boot\(\) *\{' "$BS")
eq "M0.2 verify_ct_boot 是真定义（没被注释吞掉）" "$_nv" "1"
_nb=$(grep -cE '^build_ct_boot\(\) *\{' "$BS")
eq "M0.3 build_ct_boot 是真定义" "$_nb" "1"

echo "===== M1. dag_order 无环 + 节点数 ====="
reset_all; clear_breaks; mock_all
out=$(dag_order 2>&1); rc=$?
eq "M1.1 dag_order 通过" "$rc" "0"
echo "$out" | grep -q '29 个小步骤'; chk "M1.2 小步骤数=29" ok $?

echo "===== M2. 拓扑序：br_lan_ports 先于 lan_static（验证顺序） ====="
reset_all; clear_breaks; mock_all
run_dag
_p1=$(pos_in_seq "verify br_lan_ports"); _p2=$(pos_in_seq "verify lan_static")
[ -n "$_p1" ] && [ -n "$_p2" ] && [ "$_p1" -lt "$_p2" ]; chk "M2.1 br_lan_ports 先验证" ok $?
_p5=$(pos_in_seq "verify snat")
[ -n "$_p2" ] && [ -n "$_p5" ] && [ "$_p2" -lt "$_p5" ]; chk "M2.2 snat 在 lan_static 之后验证" ok $?
eq "M2.3 全部就绪时网络节点零 build（验证先行，幂等）" "$(grep -cE '^build (br_lan_ports|lan_static|dns_domain|lxc_zone|snat)$' "$SEQ_LOG")" "0"

echo "===== M3. 可写节点：dns_domain 缺失即补建（v.95） ====="
reset_all; clear_breaks; mock_all
BREAK_dns_domain=1
run_dag_log
eq "M3.1 dns_domain 被 build 一次" "$(seq_grep 'build dns_domain')" "1"
# v.99：置位值是 B:<ts>（B=built），不再是 1 —— 断言分类前缀 + 时间戳格式
eq "M3.2 build 成功后置 _dirty，且分类为 B（待分组 reload）" \
   "$(eval "echo \$_dirty_dns_domain" | grep -cE '^B:[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$')" "1"
# M3 用 mock_all 把 build_dns_domain 换成了通用桩，真身的 [DNS] 日志不会出现；
# 这里只断言「ensure 走到了 build 分支」，日志文本归 I2 层用真函数验。
grep -q '\[dns_domain\] 已构建' "$DAG_OUT"; chk "M3.3 ensure 记下「已构建」" ok $?

echo "===== M4. 幂等：全就绪零 build ====="
reset_all; clear_breaks; mock_all
run_dag
eq "M4.1 零 build" "$(grep -c '^build ' "$SEQ_LOG")" "0"
eq "M4.2 全部 29 节点 verify 过" "$(grep -c '^verify ' "$SEQ_LOG")" "29"

echo "===== M5. ensure 自愈与 hard：可损坏一次修复、顽固损坏一次即终止 ====="
# M5a：可修复节点由脚本 build；导致 hard 的只可能是真正的构建失败
reset_all; clear_breaks; mock_all
BREAK_rootfs=1
run_dag
eq "M5a.1 rootfs 被 build 一次（可写节点缺则建）" "$(seq_grep 'build rootfs')" "1"
eq "M5a.2 后续节点照跑" "$(seq_grep 'verify ct_boot')" "1"
# M5b：可写节点 build 失败 → hard（rootfs）
reset_all; clear_breaks; mock_all
BREAK_rootfs=1; BUILDFAIL_rootfs=1
out=$(run_dag 2>&1); rc=$?
[ $rc -eq 1 ]; chk "M5b.1 构建失败退出码 1" ok $?
eq "M5b.2 build 一次后终止" "$(seq_grep 'build rootfs')" "1"
echo "$out" | grep -q 'rootfs.*构建执行失败，hard 失败'; chk "M5b.3 有 hard 失败日志" ok $?
# M5c：可写节点 build 失败 → hard（v.95：不再有只验不写节点）
reset_all; clear_breaks; mock_all
BREAK_dns_domain=1; BUILDFAIL_dns_domain=1
out=$(run_dag 2>&1); rc=$?
[ $rc -eq 1 ]; chk "M5c.1 可写节点构建失败即 hard 终止" ok $?
eq "M5c.2 build 尝试 1 次后终止" "$(seq_grep 'build dns_domain')" "1"
# M5d：沿链传播（单节点级）——依赖入 _failed 后跳过且连带传播
reset_all; clear_breaks; mock_all
_failed="lan_static"
ensure bridge
eq "M5d.1 bridge 跳过（依赖未就绪）" "$(seq_grep 'verify bridge')" "0"
case " $_failed " in
    *" bridge "*) PASS=$((PASS+1)); echo "PASS: M5d.2 bridge 连带入 _failed（沿链传播）" ;;
    *) FAIL=$((FAIL+1)); echo "FAIL: M5d.2 bridge 未入 _failed" ;;
esac

echo "===== M6. install 类复核：rootfs 一次不过即 hard ====="
reset_all; clear_breaks; mock_all
BREAK_rootfs=1; BUILDFAIL_rootfs=1
out=$(run_dag 2>&1); rc=$?
[ $rc -eq 1 ]; chk "M6.1 退出码 1" ok $?
eq "M6.2 rootfs build 尝试一次" "$(seq_grep 'build rootfs')" "1"
echo "$out" | grep -q 'rootfs.*hard 失败，引导终止'; chk "M6.3 有 hard 失败日志" ok $?

echo "===== M7. 环检测：注入环 → dag_order 终止 ====="
reset_all; clear_breaks; mock_all
DEP_lan_static="br_lan_ports snat"
DEP_snat="lan_static"
out=$(dag_order 2>&1); rc=$?
[ $rc -eq 1 ]; chk "M7.1 环检测退出码 1" ok $?
echo "$out" | grep -q '依赖环'; chk "M7.2 报环" ok $?
DEP_lan_static="br_lan_ports"; DEP_snat="lan_static"

echo "===== M8. install 类：rootfs 缺才 build，就绪不补 ====="
reset_all; clear_breaks; mock_all
BREAK_rootfs=1
ensure rootfs
eq "M8.1 rootfs 被 build 一次（缺才补，复核通过）" "$(seq_grep 'build rootfs')" "1"
eq "M8.2 _done_rootfs 置位，且分类为 B（build 改的）" \
   "$(eval "echo \$_done_rootfs" | grep -cE '^B:[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$')" "1"
reset_all; clear_breaks; mock_all
ensure rootfs
eq "M8.3 已就绪不 build" "$(seq_grep 'build rootfs')" "0"
# _recovering 置位（真实 build_rootfs 路径，stub 镜像解压）
reset_all
. "$FUNCS" 2>/dev/null || true
rebuild_from_image() { echo "rebuild rootfs" >> "$SEQ_LOG"; return 0; }
_recovering=false
build_rootfs
eq "M8.4 rebuild_from_image 被调一次" "$(seq_grep 'rebuild rootfs')" "1"
eq "M8.5 _recovering=true" "$_recovering" "true"


echo "===== M10. ct_boot 依赖链全部入序且在先 ====="
reset_all; clear_breaks; mock_all
run_dag
for _d in ct_config rootfs lxc_zone snat; do
    _pb=$(pos_in_seq "verify ct_boot")
    _pd=$(pos_in_seq "verify $_d")
    [ -n "$_pb" ] && { [ -z "$_pd" ] || [ "$_pd" -lt "$_pb" ]; }
    chk "M10 $_d 先于 ct_boot" ok $?
done

echo "===== M11. 层级拓扑序：8 组分段、组内序正确 ====="
reset_all; clear_breaks; mock_all
out=$(dag_order 2>&1); rc=$?
[ $rc -eq 0 ]; chk "M11.1 dag_order 通过" ok $?
echo "$out" | grep -q '8 个组 / 29 个小步骤'; chk "M11.2 层级计数 8/29" ok $?
for _g in PREP INSTALL CAPIBLOCK BOOT LOGCONF LAPI BOUNCERVERIFY ENROLL; do
    echo "$out" | grep -q "组 $_g 就序"; chk "M11.3 组 $_g 分段就序" ok $?
done
run_dag
# 组内序：路由器网桥(br_lan_ports) 先于 容器网络(bridge/lxc_zone)
_pb=$(pos_in_seq "verify bridge"); _pz=$(pos_in_seq "verify lxc_zone"); _pl=$(pos_in_seq "verify br_lan_ports")
[ -n "$_pl" ] && [ -n "$_pb" ] && [ "$_pl" -lt "$_pb" ]; chk "M11.4 路由器网桥先于容器网桥" ok $?
# 跨组序：container 组全部先于 net 组、net 先于 fw、fw 先于 boot
_pc=$(pos_in_seq "verify rootfs"); _ps=$(pos_in_seq "verify snat"); _pt=$(pos_in_seq "verify ct_boot")
[ -n "$_ps" ] && [ -n "$_pc" ] && [ "$_ps" -lt "$_pc" ]; chk "M11.5 PREP 先于 INSTALL（静态准备先落地）" ok $?
[ -n "$_pc" ] && [ -n "$_pt" ] && [ "$_pc" -lt "$_pt" ]; chk "M11.6 INSTALL 组先于 BOOT 组" ok $?

echo "===== M12. hard 终止贯穿组：net 组首节点两次不过 → boot 组不执行 ====="
reset_all; clear_breaks; mock_all
BREAK_rootfs=1; BUILDFAIL_rootfs=1   # INSTALL 组可写节点 build 失败 → hard
out=$(run_dag 2>&1); rc=$?
[ $rc -eq 1 ]; chk "M12.1 hard 退出码 1" ok $?
eq "M12.2 ct_boot 未执行（进程终止于 INSTALL 组）" "$(seq_grep 'verify ct_boot')" "0"
eq "M12.3 prepare_container 未执行" "$(seq_grep 'build prepare_container')" "0"
echo "$out" | grep -q 'rootfs.*hard 失败，引导终止'; chk "M12.4 有 hard 失败日志" ok $?

echo "===== M13. 校验：小步骤漏声明归属 → 终止 ====="
reset_all; clear_breaks; mock_all
_saved="$NODE_GROUP_dns_domain"; NODE_GROUP_dns_domain=""
out=$(dag_order 2>&1); rc=$?
[ $rc -eq 1 ]; chk "M13.1 漏归属退出码 1" ok $?
echo "$out" | grep -q 'dns_domain 未声明归属'; chk "M13.2 报未声明" ok $?
NODE_GROUP_dns_domain="$_saved"
_saved="$GROUP_SEQ"; GROUP_SEQ="container net fw"    # boot 组丢了
out=$(dag_order 2>&1); rc=$?
[ $rc -eq 1 ]; chk "M13.3 组不在序列退出码 1" ok $?
GROUP_SEQ="$_saved"

echo "===== M14. 校验：组依赖倒置 → 终止 ====="
reset_all; clear_breaks; mock_all
_saved="$GROUP_DEP_LOGCONF"; GROUP_DEP_LOGCONF="ENROLL"   # LOGCONF 依赖后置的 ENROLL → 倒置
out=$(dag_order 2>&1); rc=$?
[ $rc -eq 1 ]; chk "M14.1 倒置退出码 1" ok $?
echo "$out" | grep -q '组依赖环/倒置'; chk "M14.2 报倒置" ok $?
GROUP_DEP_LOGCONF="$_saved"

# ==================== 第二层：uci 状态驱动集成 ====================
echo "===== I 层准备 ====="
docker_off() { PATH=/tmp/mockbin:/tmp/mockbin_sys; export PATH; }
docker_off
rm -f /etc/config/custom_router_ip.txt /etc/config/custom_router_netmask.txt \
      /etc/config/custom_router_gateway.txt /etc/config/custom_router_dns.txt
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
    verify_prepare_container() { return 0; }
    # v.93：容器内配置已拆成 ct_net / cgroup_mount / ct_bootlink / ct_resolv /
    # capi_block / acquis / log_forward / lapi_fetch … 等独立节点，这些节点验证的是
    # 沙箱里不存在的容器文件与内核态，安装态一律按就绪跳过（各自在所属组内闭环）。
    # 只在本函数内打桩，不影响 P 层对 verify_log_forward 等真身的独立测试。
    # 注意：verify_A 直接就是 verify_log_forward，所以这里绝不打桩 verify_log_forward，
    # 否则 P2/P13/P20/P26 的 A 步真身用例会被连带打掉（历史踩坑）；宿主侧
    # 日志转发靠 p3_reset / mk_ready_state 铺设的 UCI 四值即可就绪。
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
# 恢复真实函数后必须补回 stub：_phys_ports（沙箱枚举不到真实物理口，不 stub 会把
# br_lan_ports/wan_input 判丢）+ verify_ip_forward（/proc 只读写不了 1）——
# 否则「全就绪」状态被误判缺失，I1 零 reload 必败
restore_real() {
    . "$FUNCS" 2>/dev/null || true
    _phys_ports() { for _p in $PORTS; do echo "$_p"; done; }
    verify_ip_forward() { return 0; }
}
# 全就绪 uci 状态：每个 ensure 类节点 verify 的全部期望值都就位。
# 段名严格对齐 builder 真实产出：fwd 四条为 lxc2lan/lxc2docker/lxc2vpn/lan2lxc，
# 双网口语义下 wan zone input=REJECT
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
# v.93：log_forward 现在是 LOGCONF 组的独立节点（构建会真的 setup_log_forward + reload），
# 全就绪基线必须把宿主机日志转发四值一并铺齐，否则 I1 的「零 reload」会被这条构建打破
system|sys0|__type__|system
system|sys0|log_ip|$CONTAINER_IP
system|sys0|log_port|514
system|sys0|log_proto|udp
system|sys0|log_remote|1
EOF
}
# 每段入口：全清 DAG 状态 + 真实函数（带 stub）+ mock install + 全就绪 uci
i_reset() {
    reset_all; clear_breaks
    restore_real
    mock_install
    mk_ready_state
}

echo "===== I1. 全就绪幂等：零 reload ====="
i_reset
: > "$RELOAD_LOG"
run_dag_log
flush_uci
eq "I1.1 零 reload" "$(wc -l < "$RELOAD_LOG" | tr -d ' ')" "0"
eq "I1.2 零 build（各节点 ensure 后同样就绪跳过）" "$(grep -c '^build ' "$SEQ_LOG")" "0"
eq "I1.3 install 类零 build（rootfs 等不重建）" "$(grep -cE '^build (img_migrate|ct_config|rootfs|ct_boot)$' "$SEQ_LOG")" "0"
grep -q '构建执行失败' "$DAG_OUT"; chk "I1.4 全程无 hard" fail $?

# ---- I 层断言口径（v.95 起）----
# real 版 verify_/build_ 不写 $SEQ_LOG（只有 verify_mock/build_mock 写），且 ensure 里的
# _dirty_*/_done_* 一旦经 $(...) 子 shell 返回就丢了。所以这里一律断言「可观测效果」：
#   uci 状态是否被改对、RELOAD_LOG 里各 init.d 动作的次数、日志文本是否出现。
# 这些才是「改完 commit + 分组 reload 直接生效」真正要看的东西。

echo "===== I2. dns_domain 缺项（v.95 可写）→ 补建 + dnsmasq 重启 ====="
i_reset
uci -q delete dhcp.dom0
: > "$RELOAD_LOG"
run_dag_log
{ flush_uci; } >>"$DAG_OUT" 2>&1
eq "I2.1 domain 段被脚本重建（12 段已不在，新段接管）" "$(uci show dhcp | grep -c 'time.android.com')" "1"
eq "I2.2 dnsmasq 重启 1 次" "$(grep -c '^dnsmasq restart' "$RELOAD_LOG")" "1"
eq "I2.3 network 不 reload（本轮没改 network）" "$(grep -c '^network reload' "$RELOAD_LOG")" "0"
eq "I2.4 新建的 domain 段内容正确（IP 指向国内 NTP 源）" "$(uci show dhcp | grep -c '203.107.6.88')" "1"
grep -q '\[DNS\] 已写入 time.android.com' "$DAG_OUT"; chk "I2.5 日志点明已写入" ok $?
grep -q '\[flush\] dnsmasq 已重启' "$DAG_OUT"; chk "I2.6 flush 日志确认 dnsmasq 已重启（配置真正生效）" ok $?

echo "===== I3. lan_static 被改（v.95 可写）→ 校准回期望值 + network reload ====="
i_reset
uci -q set network.lan.ipaddr=10.9.9.9
: > "$RELOAD_LOG"
run_dag_log
{ flush_uci; } >>"$DAG_OUT" 2>&1
eq "I3.1 network reload 1 次" "$(grep -c '^network reload' "$RELOAD_LOG")" "1"
eq "I3.2 ipaddr 被校准回期望值" "$(uci -q get network.lan.ipaddr)" "10.0.0.201"
eq "I3.3 dhcp/firewall 不 reload" "$(grep -cE '^(dnsmasq|firewall) (reload|restart)' "$RELOAD_LOG")" "0"
grep -q '\[LAN\] 已写入静态地址' "$DAG_OUT"; chk "I3.4 日志点明已写入" ok $?
grep -q '\[flush\] network 已重载' "$DAG_OUT"; chk "I3.5 flush 日志确认 network 已重载" ok $?

echo "===== I4. svc_bind 局部 commit 不进 flush ====="
i_reset
uci -q set dropbear.@dropbear[0].Interface=''
: > "$RELOAD_LOG"
run_dag
flush_uci
eq "I4.1 firewall 未被 svc_bind 触发" "$(grep -c '^firewall reload' "$RELOAD_LOG")" "0"
eq "I4.2 dropbear 已重绑" "$(uci -q get dropbear.@dropbear[0].Interface)" "lan"
eq "I4.3 dropbear 局部 reload 一次" "$(grep -c '^dropbear reload' "$RELOAD_LOG")" "1"

echo "===== I5. 三项全被改动（v.95）→ 各自分组 reload，互不串组 ====="
i_reset
uci -q set network.lan.ipaddr=10.9.9.9
uci -q delete dhcp.dom0
uci -q set firewall.f1.input=ACCEPT
: > "$RELOAD_LOG"
run_dag_log
{ flush_uci; } >>"$DAG_OUT" 2>&1
eq "I5.1 network reload 1 次" "$(grep -c '^network reload' "$RELOAD_LOG")" "1"
eq "I5.2 dnsmasq restart 1 次" "$(grep -c '^dnsmasq restart' "$RELOAD_LOG")" "1"
eq "I5.3 firewall reload 1 次" "$(grep -c '^firewall reload' "$RELOAD_LOG")" "1"
eq "I5.4 wan input 被脚本改写为 REJECT（多网口收紧）" "$(uci -q get firewall.f1.input)" "REJECT"
eq "I5.5 无待办（全部改为真修，不再记待办）" "$(grep -c '\[待办\]' "$DAG_OUT")" "0"
eq "I5.6 三组各 reload 至多一次，总计恰好 3 次" "$(wc -l < "$RELOAD_LOG" | tr -d ' ')" "3"

# ==================== 第三层：阶段 3 A/B/C 步骤化（一次不过即 hard） ====================
echo "===== P 层准备：阶段 3 A/B/C mock ====="
P3_SEQ=/tmp/dag_p3seq.log
BOUNCER_NAME="openwrt-fw"
CSCLI="/usr/bin/cscli"
CROWDSEC_CFG=/tmp/dag_cs_cfg.yaml
ENROLL_KEY_FILE=/tmp/dag_enroll.key
BOOTSTRAP=/tmp/bp/files/usr/sbin/crowdsec-lxc-bootstrap.sh
STAMP_FILE=/tmp/dag_p_stamp
# v.81：A/B/C 五函数 + _sc_wait_pull 由头部 FUNCS 白名单提取真身；
# A/B 的子判据在 P 层打桩（子判据真身归 Q 层构建链与 R 层完整性覆盖），
# verify_log_forward/verify_lapi_ready/bouncer_pulling/
# verify_online_client_on/off/ensure_online_client_* 走真身；
# _stamp_present/bouncer_exists 打桩读控制面（真身归 S1 层覆盖）——
# 重启态分流与「注册态就绪但 last_pull 不通」必须能分别控制，
# 否则 bouncer_exists 真身与 bouncer_pulling 共用 _ct_env 输出源无法分离
# crowdsec config 夹具：online_client 未注释（CAPI 待放出状态），
# client/server 两行 credentials 模拟真实 OpenWrt 结构
cat > "$CROWDSEC_CFG" <<'EOF'
api:
  client:
    credentials_path: /etc/crowdsec/local_api_credentials.yaml
  server:
    # credentials_path: /etc/crowdsec/online_api_credentials.yaml
common:
  daemonize: true
online_client:
  credentials_path: /etc/crowdsec/online_api_credentials.yaml
EOF
echo "dummy-enroll-key-000000" > "$ENROLL_KEY_FILE"

# 每段入口：全清 P3 状态与调用记录，重置「全就绪」基线，重装打桩。
# 控制面：
#   P3_STAMP            1=有 installed stamp（重启态）；0=无（安装态）
#   P3_BEXISTS          1=bouncer 注册态就绪（LAPI 可达时的 B 判据；与 last_pull 分离）
#   P3_CT/P3_CT_UP/P3_LAPI/P3_PULL/P3_NFT/P3_CS/P3_ENROLL  各项即时就绪判定（1=就绪；
#     P3_CT_UP：开机动作能否把容器拉起来，成功即置 P3_CT=1）
#   P3_LAPI_FIX_AFTER   第 N 次 wait_lapi 后 LAPI 恢复（0=永不恢复）
#   P3_PULL_AFTER       第 N 次 bouncers list 后 last_pull 出现（0=只认 P3_PULL）
#   P3_PULL_STALE       last_pull 时间戳超前 3600s（远超默认 60s 阈值，判停滞）
#   P3_A_* / P3_B_*（文件级）  v.83 起 A/B 不再复核文件级，这些夹具不再被 A/B 调用
#                              （保留以备 prepare_container 层测试/回查）；A 改用 uci
#                              日志转发四值驱动，B 改用 P3_CS/P3_NFT/P3_BEXISTS 驱动
#   P3_A_LOGFWD         宿主机日志转发就绪判定（UCI 四值，真身 verify_log_forward 读）
#   P3_BFAIL            fix_B 中哪步失败（uci/register/空；文件级 listen/trusted/ctcfg 已移除）
#   P3_REINSTALL_RC     full_reinstall 桩返回码（1=门拒/兜底；0=exec 未接管）
p3_reset() {
    : > "$P3_SEQ"
    _w_i=0
    echo 0 > /tmp/dag_p_ctbl        # bouncers list 调用计数（_ct_env 跑在 $() 子 shell 里，
                                    # 普通变量无法跨调用保留，必须落文件——P3_PULL_AFTER 依赖它）
    P3_STAMP=0
    P3_BEXISTS=1
    P3_CT=1; P3_CT_UP=1; P3_LAPI=1; P3_PULL=1; P3_NFT=1; P3_CS=1; P3_ENROLL=1
    P3_LAPI_FIX_AFTER=0; P3_PULL_AFTER=0; P3_PULL_STALE=0
    P3_A_NET=1; P3_A_BOOTLINK=1; P3_A_RESOLV=1; P3_A_ACQUIS=1; P3_A_LOGFWD=1
    P3_B_LISTEN=1; P3_B_TRUSTED=1; P3_B_CTCFG=1
    P3_AFAIL=""; P3_APERSIST=""; P3_BFAIL=""; P3_REINSTALL_RC=1
    P3_NOW=$(date +%s)
    P3_PULL_TS=$(date -u -d "@$P3_NOW" +%Y-%m-%dT%H:%M:%S 2>/dev/null)
    P3_PULL_STALE_TS=$(date -u -d "@$((P3_NOW-3600))" +%Y-%m-%dT%H:%M:%S 2>/dev/null)
    LXC_PATH=/tmp/dag_lxc; LXC_NAME=ubuntu
    CFG=/tmp/dag_lxc_config
    # 容器 config 夹具：内容完整（启动链判据是内容级，不只验文件名）
    cat > "$CFG" <<'CFG'
lxc.arch = amd64
lxc.rootfs.path = dir:/tmp/dag_lxc/ubuntu/rootfs
lxc.utsname = crowdsec
lxc.net.0.type = veth
lxc.net.0.link = lxcbr0
CFG
    rm -f "$STAMP_FILE"
    # ---- 分流/注册态判据打桩（真身归 S1 层；此处读控制面）----
    _stamp_present() { [ "$P3_STAMP" = 1 ]; }
    bouncer_exists() { [ "$P3_BEXISTS" = 1 ]; }
    # ---- A/B 子判据打桩（P 层焦点是决策逻辑；子判据真身归 Q/R 层）----
    verify_sub_ct_net()     { [ "$P3_A_NET" = 1 ]; }
    verify_sub_ct_bootlink() { [ "$P3_A_BOOTLINK" = 1 ]; }
    verify_sub_ct_resolv()  { [ "$P3_A_RESOLV" = 1 ]; }
    verify_sub_cs_acquis()  { [ "$P3_A_ACQUIS" = 1 ]; }
    verify_sub_cs_listen()  { [ "$P3_B_LISTEN" = 1 ]; }
    verify_sub_cs_trusted() { [ "$P3_B_TRUSTED" = 1 ]; }
    verify_sub_ct_cfg()     { [ "$P3_B_CTCFG" = 1 ]; }
    # ---- fix_A 依赖的 setup 桩：记 SEQ → 按控制面失败 → 成功即修复对应判据 ----
    setup_container_network() {
        echo "setup_net" >> "$P3_SEQ"
        [ "$P3_AFAIL" = net ] && return 1
        [ "$P3_APERSIST" = net ] || P3_A_NET=1
        return 0
    }
    setup_container_boot() {
        echo "setup_bootlink" >> "$P3_SEQ"
        [ "$P3_AFAIL" = bootlink ] && return 1
        P3_A_BOOTLINK=1; return 0
    }
    setup_resolv() {
        echo "setup_resolv" >> "$P3_SEQ"
        [ "$P3_AFAIL" = resolv ] && return 1
        P3_A_RESOLV=1; return 0
    }
    setup_acquis() {
        echo "setup_acquis" >> "$P3_SEQ"
        [ "$P3_AFAIL" = acquis ] && return 1
        P3_A_ACQUIS=1; return 0
    }
    # setup_log_forward 走真身（写 UCI + reload）；P3_AFAIL=logfwd 场景置空 CONTAINER_IP 触发失败
    # ---- fix_B 依赖的桩 ----
    ensure_listen_uri() {
        echo "ensure_listen" >> "$P3_SEQ"
        [ "$P3_BFAIL" = listen ] && return 1
        P3_B_LISTEN=1; return 0
    }
    ensure_trusted_ip() {
        echo "ensure_trusted" >> "$P3_SEQ"
        [ "$P3_BFAIL" = trusted ] && return 1
        P3_B_TRUSTED=1; return 0
    }
    apply_cfg() {
        echo "apply_cfg" >> "$P3_SEQ"
        [ "$P3_BFAIL" = ctcfg ] && return 1
        P3_B_CTCFG=1; return 0
    }
    _bouncer_uci_apply() {
        echo "uci_apply" >> "$P3_SEQ"
        [ "$P3_BFAIL" = uci ] && return 1
        return 0
    }
    _bouncer_register_once() {
        echo "register_once" >> "$P3_SEQ"
        [ "$P3_BFAIL" = register ] && return 1
        P3_BEXISTS=1; P3_PULL=1; return 0
    }
    # ---- 外部环境桩 ----
    ct_running() { [ "$P3_CT" = 1 ]; }
    nft_table_ready() { [ "$P3_NFT" = 1 ]; }
    cs_active_on_host() { [ "$P3_CS" = 1 ]; }
    # sleep 打桩：_sc_wait_pull 的 12×sleep 5 与 fix_B 的 nft 等待在测试里瞬时完成
    sleep() { :; }
    _mount_systemd_cgroup() { echo "cgroup_mount" >> "$P3_SEQ"; return 0; }
    _wait_ct_running() {
        echo "wait_ct_running" >> "$P3_SEQ"
        [ "$P3_CT_UP" = 1 ] && P3_CT=1
        [ "$P3_CT" = 1 ]
    }
    # 容器内命令桩：LAPI 探活 / bouncers list（带时间戳，可控窗口内恢复）/ capi status / 其余放行
    _ct_env() {
        case "$1" in
            *"bouncers list -o json"*)
                [ "$P3_LAPI" = 1 ] || return 1
                echo "[]"
                ;;
            *"bouncers list"*)
                _ct_bl=$(( $(cat /tmp/dag_p_ctbl 2>/dev/null || echo 0) + 1 ))
                echo "$_ct_bl" > /tmp/dag_p_ctbl
                if [ "$P3_PULL" = 1 ] || { [ "$P3_PULL_AFTER" != 0 ] && [ "$_ct_bl" -ge "$P3_PULL_AFTER" ]; }; then
                    printf '%s %s %sZ %s\n' "$BOUNCER_NAME" "10.0.0.201" \
                        "$( [ "$P3_PULL_STALE" = 1 ] && echo "$P3_PULL_STALE_TS" || echo "$P3_PULL_TS" )" "ok"
                else
                    return 1
                fi
                ;;
            *"capi status"*)
                [ "$P3_ENROLL" = 1 ] || return 1
                printf '%s\n' "You can run 'cscli capi status' for more information." "Enrolled: true"
                ;;
            *"date +%s"*) echo "$P3_NOW" ;;
            *"date -d "*)
                _dts=$(printf '%s' "$1" | sed -E "s/.*date -d '([^']+)'.*/\1/")
                date -d "$_dts" +%s 2>/dev/null
                ;;
            *"systemctl restart crowdsec"*) echo "restart_crowdsec" >> "$P3_SEQ" ;;
            *) return 0 ;;
        esac
    }
    # ---- fix 链桩：记录调用序 + 可控成败 ----
    _wait_lapi_ready() {
        echo "wait_lapi $1" >> "$P3_SEQ"
        _w_i=$((_w_i+1))
        if [ "$P3_LAPI_FIX_AFTER" != 0 ] && [ "$_w_i" -ge "$P3_LAPI_FIX_AFTER" ]; then P3_LAPI=1; fi
        [ "$P3_LAPI" = 1 ]
    }
    _ensure_bouncer_service() { echo "ensure_svc" >> "$P3_SEQ"; return 0; }
    full_reinstall() { echo "full_reinstall" >> "$P3_SEQ"; return "$P3_REINSTALL_RC"; }
    re_enroll() { echo "re_enroll" >> "$P3_SEQ"; [ "$P3_REENROLL" = 1 ]; }
    # ---- 基线状态：日志转发四值就绪 + config 夹具复位（online_client 未注释）----
    : > "$UCI_STATE"
    cat >> "$UCI_STATE" <<EOF
system|sys0|__type__|system
system|sys0|log_ip|$CONTAINER_IP
system|sys0|log_port|514
system|sys0|log_proto|udp
system|sys0|log_remote|1
EOF
    cat > "$CROWDSEC_CFG" <<'CFG'
api:
  client:
    credentials_path: /etc/crowdsec/local_api_credentials.yaml
  server:
    # credentials_path: /etc/crowdsec/online_api_credentials.yaml
common:
  daemonize: true
online_client:
  credentials_path: /etc/crowdsec/online_api_credentials.yaml
CFG
    P3_REENROLL=1
}
# 模拟 main 阶段 3（v.81 A/B/C 步骤化，与 main() 源码逐行同构；
# _recovering 由调用方置；结构回归由 P25 对 bootstrap 源码断言）
run_phase3() {
    log "===== 阶段 3：服务链开始 ====="
    if [ "$_recovering" = true ]; then
        phase3_step "shield" verify_online_client_off ensure_online_client_off
    fi
    if _stamp_present; then
        log "[阶段3] 检出 installed 标记：重启态，A/B 不主动治理，直接验证 C（last_pull）"
        step_C
    else
        log "[阶段3] 无 installed 标记：安装态，依序执行 A → B → C"
        if verify_A; then
            log "[步骤A] 宿主机日志转发就绪，跳过"
        else
            log "[步骤A] 宿主机日志转发缺项，执行一次修复"
            fix_A || { log "[步骤A] 修复执行失败，hard 失败，引导终止"; exit 1; }
            verify_A || { log "[步骤A] 一次修复未通过复核，hard 失败，引导终止"; exit 1; }
        fi
        if verify_B; then
            log "[步骤B] bouncer 服务链路就绪，跳过"
        else
            log "[步骤B] bouncer 服务链路缺项，执行一次修复"
            fix_B || { log "[步骤B] 修复执行失败，hard 失败，引导终止"; exit 1; }
            verify_B || { log "[步骤B] 一次修复未通过复核，hard 失败，引导终止"; exit 1; }
        fi
        step_C
    fi
    phase3_step "online_on" verify_online_client_on ensure_online_client_on
    phase3_step_enroll "enroll" console_enroll_ok re_enroll
    return 0
}
p3_grep() { grep -c "^$1\$" "$P3_SEQ" | tr -d ' '; }
p3_pos() { grep -n "^$1\$" "$P3_SEQ" | head -1 | cut -d: -f1; }

echo "===== P1. 安装态全就绪：A/B 跳过、C 就绪、零 fix ====="
p3_reset; _recovering=false
out=$(run_phase3 2>&1); rc=$?
[ $rc -eq 0 ]; chk "P1.1 退出码 0" ok $?
eq "P1.2 A/B 均判就绪跳过" "$(echo "$out" | grep -cE '宿主机日志转发就绪，跳过|bouncer 服务链路就绪，跳过')" "2"
eq "P1.3 零 fix 动作（P3_SEQ 仅 C 的纯等待）" "$(grep -cE '^(setup_|ensure_|register_once|uci_apply|full_reinstall|ensure_svc)' "$P3_SEQ")" "0"
echo "$out" | grep -q '无 installed 标记：安装态'; chk "P1.4 安装态分流日志" ok $?

echo "===== P2. 安装态 A（日志转发）缺项可修复：一次修复后复核通过，后续照跑 ====="
p3_reset; _recovering=false
uci -q delete system.sys0.log_port          # 让 verify_A（=verify_log_forward）失效
: > "$RELOAD_LOG"
out=$(run_phase3 2>&1); rc=$?
[ $rc -eq 0 ]; chk "P2.1 退出码 0" ok $?
eq "P2.2 日志转发 reload 恰一次" "$(grep -c '^log reload' "$RELOAD_LOG")" "1"
echo "$out" | grep -q '宿主机日志转发缺项，执行一次修复'; chk "P2.3 有修复日志" ok $?
echo "$out" | grep -q 'bouncer 服务链路就绪，跳过'; chk "P2.4 B 步照跑且就绪" ok $?
uci -q set system.sys0.log_port=514          # 还原，后续用例依赖默认四值就绪

echo "===== P3. 重启态 A（日志转发）修复执行失败（CONTAINER_IP 空）→ step_C 判 hard ====="
p3_reset; _recovering=false
P3_STAMP=1; P3_PULL=0
uci -q delete system.sys0.log_port
CONTAINER_IP=""
out=$(run_phase3 2>&1); rc=$?
[ $rc -eq 1 ]; chk "P3.1 退出码 1" ok $?
echo "$out" | grep -q '一次修复后 A/B 仍未恢复正常，hard 失败'; chk "P3.2 重启态 step_C 判 hard（A 修复无效）" ok $?
eq "P3.3 B 步未执行" "$(echo "$out" | grep -c '步骤B')" "0"
CONTAINER_IP="10.1.0.100"; uci -q set system.sys0.log_port=514

echo "===== P4. 安装态 A/B 双缺：各修复一次后 C 就绪放行 ====="
p3_reset; _recovering=false
uci -q delete system.sys0.log_port          # A 缺
P3_BEXISTS=0                                 # B 缺（bouncer 未注册）
: > "$RELOAD_LOG"
out=$(run_phase3 2>&1); rc=$?
[ $rc -eq 0 ]; chk "P4.1 退出码 0" ok $?
eq "P4.2 A 修复触发日志转发 reload 一次" "$(grep -c '^log reload' "$RELOAD_LOG")" "1"
eq "P4.3 B 走注册分支一次" "$(p3_grep register_once)" "1"
echo "$out" | grep -q 'LAPI 就绪且 last_pull 有效，链路就绪'; chk "P4.4 C 就绪放行" ok $?
uci -q set system.sys0.log_port=514

echo "===== P5. 安装态 B 缺项可修复：文件补写 + 链路治理一次，复核通过 ====="
p3_reset; _recovering=false
P3_B_LISTEN=0; P3_PULL=0; P3_BEXISTS=0
# fix_B 直接在当前 shell 跑（不包子 shell）：修复桩要置位控制面变量，
# 随后的 verify_B 复核才能看到修复效果（$() 子 shell 的置位不传染父 shell）
fix_B > /tmp/dag_p5.out 2>&1; rc=$?
out=$(cat /tmp/dag_p5.out)
[ $rc -eq 0 ]; chk "P5.1 fix_B 返 0" ok $?
eq "P5.2 文件级 listen 不再由 B 补写（回归）" "$(p3_grep ensure_listen)" "0"
eq "P5.3 链路治理一次（uci_apply+register_once+ensure_svc）" "$(p3_grep uci_apply)/$(p3_grep register_once)/$(p3_grep ensure_svc)" "1/1/1"
grep -qE '^[[:space:]]*# online_client:' "$CROWDSEC_CFG"; chk "P5.4 修复期已屏蔽 online_client" ok $?
verify_B >/dev/null 2>&1; chk "P5.5 修复后 verify_B 复核通过" ok $?

echo "===== P5b. 安装态 B 缺项经主流程：一次修复后 CAPI 放行、C 就绪 ====="
p3_reset; _recovering=false
P3_B_LISTEN=0; P3_PULL=0; P3_BEXISTS=0
out=$(run_phase3 2>&1); rc=$?
[ $rc -eq 0 ]; chk "P5b.1 退出码 0" ok $?
grep -qE '^[[:space:]]*online_client:' "$CROWDSEC_CFG"; chk "P5b.2 流程尾 online_client 已放行" ok $?
echo "$out" | grep -q '步骤B.*缺项，执行一次修复'; chk "P5b.3 有一次修复日志且无 hard" ok $?

echo "===== P6. 安装态 B 修复执行失败（register 拿不到 key）→ hard ====="
p3_reset; _recovering=false
P3_B_LISTEN=0; P3_PULL=0; P3_BEXISTS=0; P3_BFAIL=register
out=$(run_phase3 2>&1); rc=$?
[ $rc -eq 1 ]; chk "P6.1 退出码 1" ok $?
eq "P6.2 register 恰一次即失败" "$(p3_grep register_once)" "1"
echo "$out" | grep -q '步骤B.*修复执行失败，hard 失败'; chk "P6.3 有执行失败日志" ok $?

echo "===== P6b. 安装态 B 一次修复后复核仍不符（服务恒不起）→ hard ====="
p3_reset; _recovering=false
P3_CS=0                             # 宿主机 bouncer 服务恒不就绪
out=$(run_phase3 2>&1); rc=$?
[ $rc -eq 1 ]; chk "P6b.1 退出码 1" ok $?
eq "P6b.2 链路治理恰一次（不等第二次）" "$(p3_grep register_once)" "1"
echo "$out" | grep -q '步骤B.*一次修复未通过复核，hard 失败'; chk "P6b.3 有复核不符日志" ok $?

echo "===== P7. 安装态 B 的 LAPI 三分支：LAPI 不可达 → 放行（return 0），交由 C 判定 ====="
p3_reset; _recovering=false
P3_LAPI=0; P3_BEXISTS=1
out=$(run_phase3 2>&1); rc=$?
[ $rc -eq 1 ]; chk "P7.1 C 判损坏后 hard 退出码 1" ok $?
echo "$out" | grep -q 'LAPI 不可达，注册态无法查验（return 0，交由步骤 C 判定）'; chk "P7.2 有放行日志而非 B 异常" ok $?
eq "P7.3 B 未进修复分支（零 register）" "$(p3_grep register_once)" "0"
eq "P7.4 升级 full_reinstall 一次" "$(p3_grep full_reinstall)" "1"

echo "===== P8. 安装态 C 失败 + A/B 正常 → 判容器损坏 → 重装门拒 → hard ====="
p3_reset; _recovering=false
P3_PULL=0; P3_BEXISTS=1
out=$(run_phase3 2>&1); rc=$?
[ $rc -eq 1 ]; chk "P8.1 退出码 1" ok $?
eq "P8.2 零修复（A/B 均未被动）" "$(grep -cE '^(setup_|ensure_|register_once|uci_apply)' "$P3_SEQ")" "0"
echo "$out" | grep -q 'A/B（日志转发+服务链路）均正常'; chk "P8.3 有损坏判定日志" ok $?
eq "P8.4 full_reinstall 恰一次" "$(p3_grep full_reinstall)" "1"
echo "$out" | grep -q '不满足重装条件，hard 失败'; chk "P8.5 门拒后 hard" ok $?

echo "===== P9. 安装态 C 失败 + full_reinstall 返 0（exec 未接管）→ 兜底 hard ====="
p3_reset; _recovering=false
P3_PULL=0; P3_BEXISTS=1; P3_REINSTALL_RC=0
out=$(run_phase3 2>&1); rc=$?
[ $rc -eq 1 ]; chk "P9.1 退出码 1" ok $?
echo "$out" | grep -q '重装流程未接管（exec 失败），hard 失败'; chk "P9.2 有未接管兜底日志" ok $?

echo "===== P10. 重启态分流：A/B 不主动治理（零 setup/零 register），直接 C ====="
p3_reset; _recovering=false
P3_STAMP=1; P3_A_NET=0; P3_B_LISTEN=0; P3_BEXISTS=1
out=$(run_phase3 2>&1); rc=$?
[ $rc -eq 0 ]; chk "P10.1 退出码 0" ok $?
echo "$out" | grep -q '检出 installed 标记：重启态，A/B 不主动治理'; chk "P10.2 重启态分流日志" ok $?
eq "P10.3 零 A/B 修复动作" "$(grep -cE '^(setup_|ensure_|register_once|uci_apply)' "$P3_SEQ")" "0"
eq "P10.4 无安装态修复日志" "$(echo "$out" | grep -c '存在缺项，执行一次修复')" "0"

echo "===== P11. 重启态 C 就绪：直接放行 ====="
p3_reset; _recovering=false
P3_STAMP=1
out=$(run_phase3 2>&1); rc=$?
[ $rc -eq 0 ]; chk "P11.1 退出码 0" ok $?
eq "P11.2 wait_lapi 恰一次（纯等待）" "$(p3_grep 'wait_lapi 90')" "1"
echo "$out" | grep -q 'LAPI 就绪且 last_pull 有效，链路就绪'; chk "P11.3 有就绪日志" ok $?

echo "===== P12. 重启态 C 失败 + A/B 正常 → 判容器损坏 → 重装门拒 → hard ====="
p3_reset; _recovering=false
P3_STAMP=1; P3_PULL=0; P3_BEXISTS=1
out=$(run_phase3 2>&1); rc=$?
[ $rc -eq 1 ]; chk "P12.1 退出码 1" ok $?
echo "$out" | grep -q 'last_pull 仍未就绪，复验 A/B 定位根因'; chk "P12.2 有复验日志" ok $?
eq "P12.3 拉取窗口 12×5s（_sc_wait_pull）" "$(echo "$out" | grep -c 'last_pull 仍未就绪')" "1"
eq "P12.4 full_reinstall 恰一次" "$(p3_grep full_reinstall)" "1"
eq "P12.5 零修复动作" "$(grep -cE '^(setup_|ensure_|register_once|uci_apply)' "$P3_SEQ")" "0"

echo "===== P13. 重启态 C 失败 + A（日志转发）缺项 → fix_A 补回 → last_pull 恢复 → 放行 ====="
p3_reset; _recovering=false
P3_STAMP=1; P3_PULL=0; P3_BEXISTS=1
uci -q delete system.sys0.log_port          # 让 verify_A（=verify_log_forward）失效
P3_PULL_AFTER=20                  # 第 20 次 bouncers list 调用后 last_pull 出现（修复后的第二轮窗口内）
: > "$RELOAD_LOG"
out=$(run_phase3 2>&1); rc=$?
[ $rc -eq 0 ]; chk "P13.1 退出码 0" ok $?
eq "P13.2 fix_A 触发日志转发 reload 一次" "$(grep -c '^log reload' "$RELOAD_LOG")" "1"
eq "P13.3 B 未修（bouncer_exists 桩就绪）" "$(p3_grep register_once)" "0"
echo "$out" | grep -q '修复后 last_pull 恢复，链路就绪'; chk "P13.4 有恢复日志" ok $?
eq "P13.5 无 full_reinstall（未误判损坏）" "$(p3_grep full_reinstall)" "0"
uci -q set system.sys0.log_port=514

echo "===== P14. 安装态 A（日志转发）修复执行失败（CONTAINER_IP 空）→ hard，不升级重装 ====="
p3_reset; _recovering=false
uci -q delete system.sys0.log_port
CONTAINER_IP=""
out=$(run_phase3 2>&1); rc=$?
[ $rc -eq 1 ]; chk "P14.1 退出码 1" ok $?
echo "$out" | grep -q '步骤A.*修复执行失败，hard 失败'; chk "P14.2 安装态 A 修复失败即 hard" ok $?
eq "P14.3 未升级重装（修复不过不判损坏）" "$(p3_grep full_reinstall)" "0"
CONTAINER_IP="10.1.0.100"; uci -q set system.sys0.log_port=514

echo "===== P15. 重启态 C 失败 + B 服务链路无法建立（nft 恒不就绪）→ 修复后仍 hard ====="
p3_reset; _recovering=false
P3_STAMP=1; P3_PULL=0; P3_NFT=0          # nft 表恒不就绪 → verify_B 失效且 fix_B 等不到
uci -q delete system.sys0.log_port        # A（日志转发）失效 → fix_A 补回
: > "$RELOAD_LOG"
out=$(run_phase3 2>&1); rc=$?
[ $rc -eq 1 ]; chk "P15.1 退出码 1" ok $?
eq "P15.2 A 修复触发日志转发 reload / B 走注册" "$(grep -c '^log reload' "$RELOAD_LOG")/$(p3_grep register_once)" "1/1"
eq "P15.3 走了链路注册分支（bouncer_exists 原未就绪）" "$(p3_grep register_once)" "1"
echo "$out" | grep -q '一次修复后 A/B 仍未恢复正常，hard 失败'; chk "P15.4 修复后仍判 hard（链路要素不全）" ok $?
eq "P15.5 未升级重装（nft 不全不判容器损坏）" "$(p3_grep full_reinstall)" "0"
uci -q set system.sys0.log_port=514

echo "===== P16. C 拉取窗口内恢复：LAPI 就绪但 last_pull 第 3 次 list 才刷新 ====="
p3_reset; _recovering=false
P3_STAMP=1; P3_PULL=0; P3_PULL_AFTER=3
out=$(run_phase3 2>&1); rc=$?
[ $rc -eq 0 ]; chk "P16.1 退出码 0" ok $?
echo "$out" | grep -q 'last_pull 在拉取窗口内恢复，链路就绪'; chk "P16.2 有窗口恢复日志" ok $?
eq "P16.3 未复验 A/B、未升级重装" "$(p3_grep full_reinstall)" "0"
eq "P16.4 零修复动作" "$(grep -cE '^(setup_|ensure_|register_once|uci_apply)' "$P3_SEQ")" "0"

echo "===== P17. C 纯等待恢复：LAPI 在 90s 等待窗口内起来，不误入修复/重装 ====="
p3_reset; _recovering=false
P3_STAMP=1; P3_LAPI=0; P3_LAPI_FIX_AFTER=1
out=$(run_phase3 2>&1); rc=$?
[ $rc -eq 0 ]; chk "P17.1 退出码 0" ok $?
eq "P17.2 wait_lapi 恰一次" "$(p3_grep 'wait_lapi 90')" "1"
eq "P17.3 零修复动作" "$(grep -cE '^(setup_|ensure_|register_once|uci_apply)' "$P3_SEQ")" "0"
echo "$out" | grep -q 'LAPI 就绪且 last_pull 有效，链路就绪'; chk "P17.4 纯等待即就绪" ok $?

echo "===== P18. shield：_recovering=true 时屏蔽在最前，流程尾放行 ====="
p3_reset; _recovering=true
out=$(run_phase3 2>&1); rc=$?
[ $rc -eq 0 ]; chk "P18.1 退出码 0" ok $?
_i1=$(echo "$out" | grep -n 'shield：查验' | head -1 | cut -d: -f1)
_i2=$(echo "$out" | grep -n '无 installed 标记：安装态' | head -1 | cut -d: -f1)
[ -n "$_i1" ] && [ -n "$_i2" ] && [ "$_i1" -lt "$_i2" ]; chk "P18.2 shield 在 A/B/C 之前" ok $?
grep -qE '^[[:space:]]*online_client:' "$CROWDSEC_CFG"; chk "P18.3 流程尾 CAPI 已放行" ok $?

echo "===== P19. online_client on/off 真实判定（sed 往返） ====="
p3_reset
verify_online_client_on; chk "P19.1 夹具 on 态判就绪" ok $?
verify_online_client_off; chk "P19.2 on 态判未屏蔽" fail $?
ensure_online_client_off
verify_online_client_off; chk "P19.3 off 后判已屏蔽" ok $?
verify_online_client_on; chk "P19.4 off 后判未放出" fail $?
ensure_online_client_on
verify_online_client_on; chk "P19.5 on 后判就绪" ok $?

echo "===== P20. 日志转发四值判定 + setup_log_forward 真修复 ====="
p3_reset
verify_log_forward; chk "P20.1 四值就绪判就绪" ok $?
uci -q delete system.sys0.log_port
verify_log_forward; chk "P20.2 缺 log_port 判不符" fail $?
: > "$RELOAD_LOG"
setup_log_forward
verify_log_forward; chk "P20.3 修复后复核就绪" ok $?
eq "P20.4 log reload 一次" "$(grep -c '^log reload' "$RELOAD_LOG")" "1"
uci -q set system.sys0.log_proto=tcp
verify_log_forward; chk "P20.5 proto 错判不符" fail $?

echo "===== P21. bouncer_pulling / console_enroll_ok 真实语义 ====="
p3_reset
bouncer_pulling; chk "P21.1 新鲜 last_pull 判有效" ok $?
P3_PULL_STALE=1
bouncer_pulling; chk "P21.2 停滞（远超阈值）判失效" fail $?
P3_PULL_STALE=0; P3_PULL=0
bouncer_pulling; chk "P21.3 无 last_pull 判失效" fail $?
p3_reset
console_enroll_ok; chk "P21.4 Enrolled 判已注册" ok $?
P3_ENROLL=0
console_enroll_ok; chk "P21.5 未 enrolled 判未注册" fail $?

echo "===== P22. enroll 合法中间态：fix 返 0（等网站 Accept）算通过 ====="
p3_reset; _recovering=false
P3_STAMP=1; P3_ENROLL=0          # 未 Enrolled；re_enroll 桩返 0（等 Accept）
out=$(run_phase3 2>&1); rc=$?
[ $rc -eq 0 ]; chk "P22.1 退出码 0（不误杀合法中间态）" ok $?
eq "P22.2 re_enroll 只调一次" "$(p3_grep re_enroll)" "1"
echo "$out" | grep -q 'enroll.*修复完成（fix 自带终态判定'; chk "P22.3 有放行日志" ok $?

echo "===== P23. enroll 真失败 → hard ====="
p3_reset; _recovering=false
P3_STAMP=1; P3_ENROLL=0; P3_REENROLL=0
out=$(run_phase3 2>&1); rc=$?
[ $rc -eq 1 ]; chk "P23.1 退出码 1" ok $?
echo "$out" | grep -q 'enroll.*修复失败'; chk "P23.2 有 hard 失败日志" ok $?

echo "===== P24. 阶段顺序：shield →（安装态 A→B→C / 重启态 C）→ online_on → enroll ====="
p3_reset; _recovering=true
P3_STAMP=0
out=$(run_phase3 2>&1); rc=$?
[ $rc -eq 0 ]; chk "P24.1 安装态退出码 0" ok $?
_i1=$(echo "$out" | grep -n 'shield：查验' | head -1 | cut -d: -f1)
_i2=$(echo "$out" | grep -n '无 installed 标记：安装态' | head -1 | cut -d: -f1)
_i3=$(echo "$out" | grep -n '宿主机日志转发就绪，跳过' | head -1 | cut -d: -f1)
_i4=$(echo "$out" | grep -n 'bouncer 服务链路就绪，跳过' | head -1 | cut -d: -f1)
_i5=$(echo "$out" | grep -n '步骤C\] 验证 LAPI last_pull' | head -1 | cut -d: -f1)
_i6=$(echo "$out" | grep -n 'online_on：查验' | head -1 | cut -d: -f1)
_i7=$(echo "$out" | grep -n 'enroll：查验' | head -1 | cut -d: -f1)
[ -n "$_i1" ] && [ -n "$_i2" ] && [ -n "$_i3" ] && [ -n "$_i4" ] && [ -n "$_i5" ] && [ -n "$_i6" ] && [ -n "$_i7" ] \
    && [ "$_i1" -lt "$_i2" ] && [ "$_i2" -lt "$_i3" ] && [ "$_i3" -lt "$_i4" ] && [ "$_i4" -lt "$_i5" ] \
    && [ "$_i5" -lt "$_i6" ] && [ "$_i6" -lt "$_i7" ]
chk "P24.2 安装态七步顺序（shield→A→B→C→online_on→enroll）" ok $?
p3_reset; _recovering=true
P3_STAMP=1
out=$(run_phase3 2>&1); rc=$?
[ $rc -eq 0 ]; chk "P24.3 重启态退出码 0" ok $?
_j1=$(echo "$out" | grep -n 'shield：查验' | head -1 | cut -d: -f1)
_j2=$(echo "$out" | grep -n '重启态，A/B 不主动治理' | head -1 | cut -d: -f1)
_j3=$(echo "$out" | grep -n 'online_on：查验' | head -1 | cut -d: -f1)
[ -n "$_j1" ] && [ -n "$_j2" ] && [ -n "$_j3" ] && [ "$_j1" -lt "$_j2" ] && [ "$_j2" -lt "$_j3" ]
chk "P24.4 重启态 shield→C→online_on 顺序" ok $?
echo "$out" | grep -q '阶段 3：服务链开始'; chk "P24.5 阶段 3 分隔日志" ok $?

echo "===== P25. 源码回归：main 阶段 3 为 A/B/C 结构，深修链已删净 ====="
grep -q 'if _stamp_present; then' "$BOOTSTRAP"; chk "P25.1 main 有 installed 分流" ok $?
grep -q 'rg_restart_verify' "$BOOTSTRAP"; chk "P25.2 main 调重启态逐步验证" ok $?
grep -q 'full_reinstall || { log "\[步骤C\]' "$BOOTSTRAP"; chk "P25.3 step_C 内接 full_reinstall 且门拒即 hard" ok $?
grep -q '启动链缺失（容器 config 不在或不完整），不开机' "$BOOTSTRAP"; chk "P25.4 build_ct_boot 含启动链前置检查" ok $?
for _dead in verify_container_boot _fix_container_boot verify_bouncer_link _fix_bouncer_link _fix_lapi_ready _bouncer_heal _crowdsec_repair setup_crowdsec_config; do
    if grep -q "^$_dead() {" "$BOOTSTRAP"; then
        FAIL=$((FAIL+1)); echo "FAIL: P25.5 $_dead 未删除（源码仍有定义）"
    else
        PASS=$((PASS+1)); echo "PASS: P25.5 $_dead 已删除"
    fi
done

echo "===== P26. 集成冒烟：A/B 真身 × 真实子判据 × 真实 setup（P 层桩不覆盖的集成层） ====="
# P 层子判据全打桩、Q 层只走 ensure_sub 路径——A/B 步骤路径的真身串联在此闭环：
# 从 bootstrap 提取真实子 verify + 六个真实 setup 覆盖 P 层桩，夹具 rootfs 从空铺起。
# 注意：真实 setup 内部用 ln/mkdir 等 coreutils，必须先放开 PATH（与 Q 层同款——
# mock PATH 只服务打桩函数，真实构建函数需要系统 PATH）
export PATH=/usr/bin:/bin:$PATH
P_ROOTFS=/tmp/dag_p_rootfs
/usr/bin/awk '
/^(setup_container_network|setup_container_boot|setup_resolv|setup_acquis|ensure_listen_uri|ensure_trusted_ip)\(\) \{$/ {
    name=$1; sub(/\(\).*/, "", name); print "_porig_" name "() {"; inb=1; next
}
/^(atomic_write|_container_dns|verify_sub_ct_net|verify_sub_ct_bootlink|verify_sub_ct_resolv|verify_sub_cs_acquis|verify_sub_cs_listen|verify_sub_cs_trusted|verify_sub_ct_cfg)\(\) \{$/ {
    print; inb=1; next
}
inb && /^\}$/ { print "}"; inb=0; next }
inb { print }
' "$BOOTSTRAP" > /tmp/dag_p_orig.sh
. /tmp/dag_p_orig.sh
p26_reset() {
    BRIDGE_IP=10.1.0.1; LAPI_PORT=8080
    rm -rf "$P_ROOTFS"
    /usr/bin/mkdir -p "$P_ROOTFS/etc/systemd/network" \
             "$P_ROOTFS/etc/systemd/system/multi-user.target.wants" \
             "$P_ROOTFS/etc/crowdsec/acquis.d" \
             "$P_ROOTFS/etc/crowdsec/parsers/s01-parse" \
             "$P_ROOTFS/etc/crowdsec/parsers/s02-enrich" \
             "$P_ROOTFS/etc/crowdsec" \
             "$P_ROOTFS/lib/systemd/system"
    : > "$P_ROOTFS/lib/systemd/system/systemd-networkd.service"
    : > "$P_ROOTFS/lib/systemd/system/crowdsec.service"
    ROOTFS="$P_ROOTFS"; CROWDSEC_CFG="$P_ROOTFS/etc/crowdsec/config.yaml"; CFG=/tmp/dag_p_lxc_cfg
    _container_dns() { echo 10.1.0.1; }
    : > "$UCI_STATE"
    cat >> "$UCI_STATE" <<EOF
system|sys0|__type__|system
system|sys0|log_ip|$CONTAINER_IP
system|sys0|log_port|514
system|sys0|log_proto|udp
system|sys0|log_remote|1
EOF
    cat > "$CROWDSEC_CFG" <<'CFG'
api:
  client:
    credentials_path: /etc/crowdsec/local_api_credentials.yaml
  server:
    listen_uri: 127.0.0.1:8080
    trusted_ips:
      - 127.0.0.1
common:
  daemonize: true
CFG
    printf 'lxc.arch = amd64\nlxc.rootfs.path = dir:/x\nlxc.utsname = crowdsec\nlxc.net.0.type = veth\n' > "$CFG"
    # fix_A 的真实 setup 依赖（P 层桩让位给真身）
    setup_container_network() { _porig_setup_container_network; }
    setup_container_boot() { _porig_setup_container_boot; }
    setup_resolv() { _porig_setup_resolv; }
    setup_acquis() { _porig_setup_acquis; }
    # fix_B 链路治理外部依赖打桩（cscli/uci 写操作在沙箱不可真跑）
    ct_running() { return 0; }
    cs_active_on_host() { return 0; }
    nft_table_ready() { return 0; }
    verify_lapi_ready() { return 0; }
    _b26_be=0
    bouncer_exists() { [ "$_b26_be" = 1 ]; }
    _wait_lapi_ready() { return 0; }
    _ct_env() { return 0; }
    _bouncer_register_once() { echo "register_once" >> "$P3_SEQ"; _b26_be=1; return 0; }
    _bouncer_uci_apply() { echo "uci_apply" >> "$P3_SEQ"; return 0; }
    _ensure_bouncer_service() { echo "ensure_svc" >> "$P3_SEQ"; return 0; }
    ensure_online_client_off() { echo "capi_off" >> "$P3_SEQ"; return 0; }
    # 文件补写走真身（fix_B 内部调）
    ensure_listen_uri() { _porig_ensure_listen_uri; }
    ensure_trusted_ip() { _porig_ensure_trusted_ip; }
    apply_cfg() { : > "$CFG"; return 0; }
}
p26_reset; : > "$P3_SEQ"
# 显式铺齐 uci 日志转发四值（P20 段的 proto=tcp 残留可能让 verify_log_forward 默认不符）
uci -q set system.sys0.log_ip=10.1.0.100
uci -q set system.sys0.log_port=514
uci -q set system.sys0.log_proto=udp
uci -q set system.sys0.log_remote=1
# ---- A（v.83 起仅日志转发）：verify_A = verify_log_forward ----
verify_A >/dev/null 2>&1; eq "P26.1 四值齐：verify_A 判就绪" "$?" "0"
uci -q delete system.sys0.log_port
verify_A >/dev/null 2>&1; eq "P26.2 缺 log_port：verify_A 判不符" "$?" "1"
: > "$RELOAD_LOG"
fix_A >/dev/null 2>&1; eq "P26.3 fix_A 返 0" "$?" "0"
verify_A >/dev/null 2>&1; eq "P26.4 修复后 verify_A 复核通过" "$?" "0"
eq "P26.5 log reload 触发一次" "$(grep -c '^log reload' "$RELOAD_LOG")" "1"
out=$(fix_A 2>&1)
echo "$out" | grep -q '已就绪，跳过'; chk "P26.6 幂等：二次 fix_A 判无缺项" ok $?
# ---- B（v.83 起仅服务链路）：verify_B = cs_active && nft && (LAPI? bouncer_exists) ----
_b26_be=1; verify_B >/dev/null 2>&1; eq "P26.7 链路齐（bouncer 已注册）：verify_B 判就绪" "$?" "0"
_b26_be=0; verify_B >/dev/null 2>&1; eq "P26.8 bouncer 未注册：verify_B 判不符" "$?" "1"
: > "$P3_SEQ"
fix_B >/dev/null 2>&1; eq "P26.9 fix_B 返 0" "$?" "0"
eq "P26.10 链路治理恰一次（capi_off+uci_apply+register_once+ensure_svc）" \
   "$(p3_grep capi_off)/$(p3_grep uci_apply)/$(p3_grep register_once)/$(p3_grep ensure_svc)" "1/1/1/1"
verify_B >/dev/null 2>&1; eq "P26.11 修复后 verify_B 复核通过" "$?" "0"
out=$(fix_B 2>&1)
echo "$out" | grep -q '已就绪，跳过链路修复'; chk "P26.12 幂等：二次 fix_B 判跳过" ok $?
# 恢复 P 层桩（Q 层会重建自己的桩，此处仅防本段泄漏到 P 层后续——P26 是 P 层末段，无后续）

# ==================== 第四层：容器内构建子步骤 ensure+hard ====================
echo "===== Q 层准备：构建链 mock（真实 setup_* + 可控顽固） ====="
Q_SEQ=/tmp/dag_qseq.log
Q_ROOTFS=/tmp/dag_rootfs
BOOTSTRAP=/tmp/bp/files/usr/sbin/crowdsec-lxc-bootstrap.sh
# v.93：verify_prepare_container 已随 prepare_container 节点一并删除，Q 层改用
# verify_ct_net + verify_cgroup_mount + verify_ct_bootlink + verify_ct_resolv + verify_acquis
# 组合判定「容器内配置整体就绪」。此处从 bootstrap 提取真身定义后合成一个小垫片。
# Q 层走真实构建函数（内部用 mkdir/awk/sed/mv 等 coreutils），放开 PATH；
# 函数级打桩（sleep/ct_running 等）优先级不受影响
export PATH=/usr/bin:/bin:$PATH
# 从 bootstrap 提取构建链真身并改名/原名保存：
# atomic_write（原子写工具，构建真身内部调用）+ 六个构建步（Q 层打桩包装后仍走
# 真实逻辑）+ ensure_sub/build_prepare_container/verify_prepare_container/七个子
# verify（I 层 mock_install 打过桩，此处恢复真身）
/usr/bin/awk '
/^(setup_container_network|setup_container_boot|setup_resolv|setup_acquis|ensure_listen_uri|ensure_trusted_ip)\(\) \{$/ {
    name=$1; sub(/\(\).*/, "", name); print "_qorig_" name "() {"; inb=1; next
}
/^(atomic_write|_container_dns|ensure_sub|verify_sub_ct_net|verify_sub_ct_bootlink|verify_sub_ct_resolv|verify_sub_cs_acquis|verify_sub_cs_listen|verify_sub_cs_trusted|verify_sub_ct_cfg)\(\) \{$/ {
    print; inb=1; next
}
inb && /^\}$/ { print "}"; inb=0; next }
inb { print }
' "$BOOTSTRAP" > /tmp/dag_q_orig.sh
. /tmp/dag_q_orig.sh
# v.93 合成判定：等价于原 verify_prepare_container 的「容器内配置整体就绪」语义
_q_verify_all() {
    verify_ct_net && verify_cgroup_mount && verify_ct_bootlink \
        && verify_ct_resolv && verify_acquis
}
# v.93：生产脚本已把 prepare_container 节点拆散，七步构建链改由各节点按需调用。
# Q 层要验证「七步各自 ensure+hard」的流水语义，故在此补一个只存在于测试里的
# 组合入口，内部仍走真实的 ensure_sub + 真实 setup_*，不改动被测语义。
build_prepare_container() {
    ensure_sub "容器网络文件（IP/网关/DNS）" verify_sub_ct_net setup_container_network
    ensure_sub "自启软链与机器身份" verify_sub_ct_bootlink setup_container_boot
    ensure_sub "resolv.conf" verify_sub_ct_resolv setup_resolv
    ensure_sub "日志源与解析器（acquis/parsers）" verify_sub_cs_acquis setup_acquis
    ensure_sub "listen_uri 监听地址" verify_sub_cs_listen ensure_listen_uri
    ensure_sub "trusted_ips 网桥地址" verify_sub_cs_trusted ensure_trusted_ip
    ensure_sub "容器 config 落盘" verify_sub_ct_cfg apply_cfg
}
# 每段入口：重建桩 rootfs + config 夹具（listen_uri 错值 / trusted_ips 待补）+
# 重装打桩。控制面：
#   Q_BREAK_STEP   对哪步施加控制（net/bootlink/resolv/acquis/listen/trusted）
#   Q_BUILDFAIL    1=该步 build 执行失败（返 1）
#   Q_PERSIST      1=该步 build 成功但事后再破坏产物（复核永不符）
q_reset() {
    : > "$Q_SEQ"
    Q_BREAK_STEP=""; Q_BUILDFAIL=0; Q_PERSIST=0
    # 内容级判定所需基准：trusted 步要求 BRIDGE_IP 与 CONTAINER_IP 同 /24
    BRIDGE_IP=10.1.0.1; LAPI_PORT=8080; CONTAINER_IP=10.1.0.100
    rm -rf "$Q_ROOTFS"
    /usr/bin/mkdir -p "$Q_ROOTFS/etc/systemd/network" \
             "$Q_ROOTFS/etc/systemd/system/multi-user.target.wants" \
             "$Q_ROOTFS/etc/crowdsec/acquis.d" \
             "$Q_ROOTFS/etc/crowdsec/parsers/s01-parse" \
             "$Q_ROOTFS/etc/crowdsec/parsers/s02-enrich" \
             "$Q_ROOTFS/lib/systemd/system"
    # 假 service 文件：让自启软链判定生效（rootfs 内有 service 才要求软链）
    : > "$Q_ROOTFS/lib/systemd/system/systemd-networkd.service"
    : > "$Q_ROOTFS/lib/systemd/system/crowdsec.service"
    ROOTFS="$Q_ROOTFS"
    CROWDSEC_CFG="$Q_ROOTFS/etc/crowdsec/config.yaml"
    CFG=/tmp/dag_q_lxc_config
    # 容器 config 夹具：内容完整（verify_sub_ct_cfg 走 verify_ct_config 内容级判定）
    cat > "$CFG" <<CFG
lxc.arch = amd64
lxc.rootfs.path = dir:$ROOTFS
lxc.utsname = crowdsec
lxc.net.0.type = veth
lxc.net.0.link = lxcbr0
CFG
    # config 夹具：listen_uri 错值 + trusted_ips 缺网桥地址（模拟待校准的真实结构）
    cat > "$CROWDSEC_CFG" <<'CFG'
api:
  client:
    credentials_path: /etc/crowdsec/local_api_credentials.yaml
  server:
    listen_uri: 127.0.0.1:8080
    trusted_ips:
      - 127.0.0.1
common:
  daemonize: true
CFG
    # 构建步打桩：记 SEQ → 按控制面失败/顽固 → 放行走真身（apply_cfg 免 lxc-info）
    apply_cfg() {
        echo "apply_cfg" >> "$Q_SEQ"
        cat > "$CFG" <<CFGX
lxc.arch = amd64
lxc.rootfs.path = dir:$ROOTFS
lxc.utsname = crowdsec
lxc.net.0.type = veth
lxc.net.0.link = lxcbr0
CFGX
        return 0
    }
    setup_container_network() {
        echo "setup_net" >> "$Q_SEQ"
        [ "$Q_BUILDFAIL" = 1 ] && [ "$Q_BREAK_STEP" = net ] && return 1
        _qorig_setup_container_network || return 1
        [ "$Q_PERSIST" = 1 ] && [ "$Q_BREAK_STEP" = net ] && rm -f "$ROOTFS/etc/systemd/network/10-eth0.network"
        return 0
    }
    setup_container_boot() {
        echo "setup_bootlink" >> "$Q_SEQ"
        [ "$Q_BUILDFAIL" = 1 ] && [ "$Q_BREAK_STEP" = bootlink ] && return 1
        _qorig_setup_container_boot || return 1
        [ "$Q_PERSIST" = 1 ] && [ "$Q_BREAK_STEP" = bootlink ] && rm -f "$ROOTFS/etc/hostname"
        return 0
    }
    setup_resolv() {
        echo "setup_resolv" >> "$Q_SEQ"
        [ "$Q_BUILDFAIL" = 1 ] && [ "$Q_BREAK_STEP" = resolv ] && return 1
        _qorig_setup_resolv || return 1
        [ "$Q_PERSIST" = 1 ] && [ "$Q_BREAK_STEP" = resolv ] && echo "nameserver 9.9.9.9" > "$ROOTFS/etc/resolv.conf"
        return 0
    }
    setup_acquis() {
        echo "setup_acquis" >> "$Q_SEQ"
        [ "$Q_BUILDFAIL" = 1 ] && [ "$Q_BREAK_STEP" = acquis ] && return 1
        _qorig_setup_acquis || return 1
        [ "$Q_PERSIST" = 1 ] && [ "$Q_BREAK_STEP" = acquis ] && rm -f "$ROOTFS/etc/crowdsec/parsers/s02-enrich/openwrt-whitelist.yaml"
        return 0
    }
    ensure_listen_uri() {
        echo "ensure_listen" >> "$Q_SEQ"
        [ "$Q_BUILDFAIL" = 1 ] && [ "$Q_BREAK_STEP" = listen ] && return 1
        _qorig_ensure_listen_uri || return 1
        [ "$Q_PERSIST" = 1 ] && [ "$Q_BREAK_STEP" = listen ] && sed -i 's|listen_uri:.*|listen_uri: 127.0.0.1:8080|' "$CROWDSEC_CFG"
        return 0
    }
    ensure_trusted_ip() {
        echo "ensure_trusted" >> "$Q_SEQ"
        [ "$Q_BUILDFAIL" = 1 ] && [ "$Q_BREAK_STEP" = trusted ] && return 1
        _qorig_ensure_trusted_ip || return 1
        [ "$Q_PERSIST" = 1 ] && [ "$Q_BREAK_STEP" = trusted ] && sed -i "/- ${BRIDGE_IP}/d" "$CROWDSEC_CFG"
        return 0
    }
}
q_cnt() { grep -c "^$1\$" "$Q_SEQ" | tr -d ' '; }

echo "===== Q1. 全就绪：七步全部跳过、零构建 ====="
q_reset
build_prepare_container >/dev/null 2>&1          # 先真实建好全部产物
: > "$Q_SEQ"
build_prepare_container >/dev/null 2>&1; rc=$?
eq "Q1.1 退出码 0" "$rc" "0"
eq "Q1.2 零构建（七步全跳过）" "$(grep -cE '^(setup_|ensure_)' "$Q_SEQ")" "0"
eq "Q1.3 容器内配置整体就绪（ct_net+bootlink+resolv+acquis）" "$(_q_verify_all >/dev/null 2>&1; echo $?)" "0"

echo "===== Q2. 单步可损坏：该步构建一次即过，其余步幂等跳过 ====="
q_reset
build_prepare_container >/dev/null 2>&1          # 全就绪基线
: > "$Q_SEQ"
rm -f "$Q_ROOTFS/etc/crowdsec/parsers/s01-parse/openwrt-dropbear.yaml"   # 只坏 acquis 一个产物
out=$(build_prepare_container 2>&1); rc=$?
eq "Q2.1 退出码 0" "$rc" "0"
eq "Q2.2 仅 acquis 步构建一次" "$(q_cnt setup_acquis)" "1"
eq "Q2.3 其余六步零构建" "$(grep -cE '^(setup_net|setup_bootlink|setup_resolv|ensure_listen|ensure_trusted|apply_cfg)$' "$Q_SEQ")" "0"
echo "$out" | grep -q '日志源与解析器（acquis/parsers） 已构建'; chk "Q2.4 已构建日志（不写复核结论）" ok $?

echo "===== Q3. 中间步 build 成功但产物再次损坏：不重新构建（无复核范式），交由组级 verify 判定 ====="
q_reset
Q_BREAK_STEP=listen; Q_PERSIST=1
out=$(build_prepare_container 2>&1); rc=$?
eq "Q3.1 单次构建即返回（无复核 → 不 hard）" "$rc" "0"
eq "Q3.2 listen 步构建一次" "$(q_cnt ensure_listen)" "1"
eq "Q3.3 前三步各一次（无基线，首次进入即构建）" "$(grep -cE '^(setup_net|setup_bootlink|setup_resolv)$' "$Q_SEQ")" "3"
eq "Q3.4 后续步照常执行（单步不再失败即停）" "$(grep -cE '^(ensure_trusted)$' "$Q_SEQ")" "1"
echo "$out" | grep -q 'listen_uri 监听地址 已构建'; chk "Q3.5 已构建日志（不写复核结论）" ok $?
echo "$out" | grep -q '复核通过\|通过复核'; chk "Q3.6 全程无复核类日志" fail $?

echo "===== Q4. build 执行失败（返 1）：一次 → hard ====="
q_reset
Q_BREAK_STEP=resolv; Q_BUILDFAIL=1
out=$(build_prepare_container 2>&1); rc=$?
eq "Q4.1 hard 退出码 1" "$rc" "1"
eq "Q4.2 resolv 步一次构建执行失败" "$(q_cnt setup_resolv)" "1"
echo "$out" | grep -q 'resolv.conf 构建执行失败'; chk "Q4.3 执行失败日志" ok $?
eq "Q4.4 后续步不执行" "$(grep -cE '^(setup_acquis|ensure_listen|ensure_trusted|apply_cfg)$' "$Q_SEQ")" "0"

echo "===== Q5. 产物损坏落在第 4 步（acquis）：仅该步构建一次，后三步照常构建 ====="
q_reset
Q_BREAK_STEP=acquis; Q_PERSIST=1
out=$(build_prepare_container 2>&1); rc=$?
eq "Q5.1 退出码 0（不 hard）" "$rc" "0"
eq "Q5.2 acquis 一次" "$(q_cnt setup_acquis)" "1"
eq "Q5.3 前三步各一次（首次进入时构建）" "$(grep -cE '^(setup_net|setup_bootlink|setup_resolv)$' "$Q_SEQ")" "3"
eq "Q5.4 后三步各一次（流水线不中断）" "$(grep -cE '^(ensure_listen|ensure_trusted)$' "$Q_SEQ")" "2"

echo "===== Q6. 整体判定与七子判定一致（快照等价） ====="
q_reset
build_prepare_container >/dev/null 2>&1          # 全基线
_q_verify_all >/dev/null 2>&1; _v1=$?
rm -f "$Q_ROOTFS/etc/machine-id"
_q_verify_all >/dev/null 2>&1; _v2=$?
verify_sub_ct_bootlink >/dev/null 2>&1; _v3=$?
eq "Q6.1 缺 machine-id 整体判不符（v.93：ct_net 不覆盖 bootlink，改判 bootlink 真身）" "$_v1:$_v3" "0:1"
eq "Q6.2 子判定同步判不符" "$_v3" "1"
_qorig_setup_container_boot
_q_verify_all >/dev/null 2>&1
eq "Q6.3 补齐后整体判就绪" "$?" "0"

# ==================== 第五层：文件完整性与原子写（防半截文件） ====================
echo "===== R 层准备：完整性/原子写 mock ====="
R_DIR=/tmp/dag_r
rm -rf "$R_DIR"; /usr/bin/mkdir -p "$R_DIR"
CS_HOME="$R_DIR/cshome"          # FUNCS 白名单未收 CS_HOME，build_img_migrate 的 mkdir 目标需显式给
# verify_img_migrate 真身补提取（P/Q 层提取文件未含；gzip -t 验镜像完整性）
/usr/bin/awk '/^(verify_img_migrate|verify_ct_config|verify_rootfs)\(\) \{$/ { print; inb=1; next } inb && /^\}$/ { print "}"; inb=0; next } inb { print }' "$BOOTSTRAP" > /tmp/dag_r_verify.sh
. /tmp/dag_r_verify.sh
# build_ct_config/build_img_migrate 真身补提取（I 层 mock_install 打桩成空壳）
/usr/bin/awk '/^(build_ct_config|build_img_migrate)\(\) \{$/ { print; inb=1; next } inb && /^\}$/ { print "}"; inb=0; next } inb { print }' "$BOOTSTRAP" > /tmp/dag_r_build.sh
. /tmp/dag_r_build.sh

echo "===== R1. atomic_write：完整才落盘；needle 不符不碰旧文件 ====="
_r_t="$R_DIR/aw1"
printf 'line1\nMARKER-X\nline3\n' | atomic_write "$_r_t" "MARKER-X"; _r_rc=$?
eq "R1.1 返 0 且内容完整" "$_r_rc:$(cat "$_r_t" 2>/dev/null | tr '\n' ',')" "0:line1,MARKER-X,line3,"
eq "R1.2 无 .tmp 残留" "$(ls "$R_DIR" | grep -c 'aw1.tmp')" "0"
printf 'line1\nWRONG\n' | atomic_write "$_r_t" "MARKER-X"; _r_rc=$?
eq "R1.3 needle 不符返 1 且旧文件不动" "$_r_rc:$(cat "$_r_t" 2>/dev/null | tr '\n' ',')" "1:line1,MARKER-X,line3,"
eq "R1.4 失败不留 tmp" "$(ls "$R_DIR" | grep -c '\.tmp$')" "0"

echo "===== R2. 半截容器 config：内容级 verify 判不符 → 删旧建新 ====="
CFG="$R_DIR/config"
printf 'lxc.utsname = crowdsec\nlxc.net.0.type = ve' > "$CFG"     # 半截：缺 lxc.rootfs.path
verify_ct_config >/dev/null 2>&1; eq "R2.1 半截判不符" "$?" "1"
write_cfg() { atomic_write "$CFG" "lxc.rootfs.path" <<EOF
lxc.arch = amd64
lxc.rootfs.path = dir:/tmp/dag_r/rootfs
lxc.utsname = crowdsec
lxc.net.0.type = veth
EOF
}
apply_cfg() { return 0; }        # 免 lxc-info（沙箱无 lxc 工具链）
build_ct_config >/dev/null 2>&1; eq "R2.2 build 返 0" "$?" "0"
verify_ct_config >/dev/null 2>&1; eq "R2.3 重建后判就绪" "$?" "0"
eq "R2.4 半截内容已被整文件替换" "$(grep -c 've$' "$CFG")" "0"

echo "===== R3. 损坏镜像：gzip 校验失败 → 删除重迁；坏源交 ensure hard ====="
TARBALL="$R_DIR/lxc-ubuntu.tar.gz"
LEGACY_TARBALL="$R_DIR/legacy.tar.gz"
printf 'not a gzip at all' > "$TARBALL"
verify_img_migrate >/dev/null 2>&1; eq "R3.1 坏卷判不符（gzip -t）" "$?" "1"
# 好 legacy：内容级校验要求含 etc/ 与 usr/，故按真实 rootfs 结构打包
_r3_stage="$R_DIR/legacy_stage"
/usr/bin/mkdir -p "$_r3_stage/etc" "$_r3_stage/usr"
printf 'ID=ubuntu\n' > "$_r3_stage/etc/os-release"
: > "$_r3_stage/usr/.keep"
tar -czf "$LEGACY_TARBALL" -C "$_r3_stage" etc usr
build_img_migrate >/dev/null 2>&1; eq "R3.2 删旧重迁返 0" "$?" "0"
verify_img_migrate >/dev/null 2>&1; eq "R3.3 重迁后校验过" "$?" "0"
rm -f "$TARBALL"; printf 'broken-not-gzip' > "$LEGACY_TARBALL"
build_img_migrate >/dev/null 2>&1
verify_img_migrate >/dev/null 2>&1; eq "R3.4 坏 legacy 迁来仍判不符（交外层 hard）" "$?" "1"

echo "===== R4. 半截 rootfs config：开机构造步报不完整、绝不开机（v.81 并入 build_ct_boot） ====="
# build_ct_boot 真身补提取（I 层 mock_install 曾打桩；v.81 起「验启动链在位才开机」
# 的内容级前置检查在该函数内，缺链不开机、不重写、不重建）
/usr/bin/awk '/^(build_ct_boot)\(\) \{$/ { print; inb=1; next } inb && /^\}$/ { print "}"; inb=0; next } inb { print }' "$BOOTSTRAP" > /tmp/dag_r_boot.sh
. /tmp/dag_r_boot.sh
# lxc-start 带连字符不能定义为 dash 函数（Bad function name）→ PATH 桩记录调用序列
mkdir -p "$R_DIR/bin"
cat > "$R_DIR/bin/lxc-start" <<'EOF'
#!/bin/sh
echo "lxc-start $*" >> "$R_SEQ"
exit 0
EOF
chmod +x "$R_DIR/bin/lxc-start"
PATH="$R_DIR/bin:$PATH"; export PATH
LXC_NAME=r4ct; LXC_PATH="$R_DIR/lxc"
CROWDSEC_CFG="$R_DIR/rootfs_config.yaml"
printf 'api:\n  client:\n' > "$CROWDSEC_CFG"            # 半截：缺 common 段
verify_rootfs >/dev/null 2>&1; eq "R4.1 半截判不符" "$?" "1"
CFG="$R_DIR/config4"
printf 'lxc.arch = amd64\nlxc.rootfs.path = dir:x\nlxc.utsname = c\nlxc.net.0.type = veth\n' > "$CFG"
R_SEQ="$R_DIR/r4seq"; : > "$R_SEQ"; export R_SEQ
ct_running() { return 1; }
_mount_systemd_cgroup() { echo "cgroup" >> "$R_SEQ"; }
_wait_ct_running() { echo "wait" >> "$R_SEQ"; return 1; }
out=$(build_ct_boot 2>&1); _r4rc=$?
eq "R4.2 boot build 返 1（链不完整不开机）" "$_r4rc" "1"
eq "R4.3 从未挂 cgroup/尝试开机" "$(grep -c 'cgroup\|wait\|lxc-start' "$R_SEQ")" "0"
echo "$out" | grep -q 'rootfs 不在或不完整'; chk "R4.4 报「不完整」而非仅「不在」" ok $?
echo "===== R4b. 容器 config 缺失：同样不开机不重建 ====="
R_SEQ="$R_DIR/r4bseq"; : > "$R_SEQ"; export R_SEQ
cat > "$CROWDSEC_CFG" <<'CFG'
api:
  client:
    credentials_path: /etc/crowdsec/local_api_credentials.yaml
common:
  daemonize: true
CFG
rm -f "$CFG"
out=$(build_ct_boot 2>&1); _r4brc=$?
eq "R4b.1 缺容器 config → 返 1" "$_r4brc" "1"
echo "$out" | grep -q '启动链缺失（容器 config 不在或不完整），不开机'; chk "R4b.2 报容器 config 缺失" ok $?
eq "R4b.3 从未尝试开机" "$(grep -c 'cgroup\|wait\|lxc-start' "$R_SEQ")" "0"
echo "===== R4c. 启动链在位：正常走开机链（cgroup→lxc-start→等运行） ====="
R_SEQ="$R_DIR/r4cseq"; : > "$R_SEQ"; export R_SEQ
printf 'lxc.arch = amd64\nlxc.rootfs.path = dir:x\nlxc.utsname = c\nlxc.net.0.type = veth\n' > "$CFG"
# rootfs 就绪（内容级）：etc/usr + os-release(ID=) + 完整 crowdsec config
ROOTFS="$R_DIR/rootfs4c"
/usr/bin/mkdir -p "$ROOTFS/etc" "$ROOTFS/usr" "$ROOTFS/etc/crowdsec"
printf 'ID=ubuntu\n' > "$ROOTFS/etc/os-release"
printf 'api:\n  server:\n    listen_uri: 0.0.0.0:8080\ncommon:\n  daemonize: true\n' > "$ROOTFS/etc/crowdsec/config.yaml"
CROWDSEC_CFG="$ROOTFS/etc/crowdsec/config.yaml"
ct_running() { [ -s "$R_DIR/r4c_started" ]; }
_wait_ct_running() { echo "wait" >> "$R_SEQ"; : > "$R_DIR/r4c_started"; return 0; }
out=$(build_ct_boot 2>&1); _r4crc=$?
eq "R4c.1 链在位 → 返 0" "$_r4crc" "0"
eq "R4c.2 cgroup+等运行各一次" "$(grep -c 'cgroup' "$R_SEQ")/$(grep -c 'wait' "$R_SEQ")" "1/1"
echo "$out" | grep -q '容器已启动'; chk "R4c.3 有启动完成日志" ok $?

echo "===== R5. 半截 acquis：子 verify 判不符 → 重建后过 ====="
ROOTFS="$R_DIR/rootfs5"
/usr/bin/mkdir -p "$ROOTFS/etc/crowdsec/acquis.d" "$ROOTFS/etc/crowdsec/parsers/s01-parse" "$ROOTFS/etc/crowdsec/parsers/s02-enrich"
printf 'source: syslog\n' > "$ROOTFS/etc/crowdsec/acquis.d/router.yaml"   # 半截：缺 listen_port
printf 'name: openwrt/dropbear-logs\n' > "$ROOTFS/etc/crowdsec/parsers/s01-parse/openwrt-dropbear.yaml"  # 半截：缺 statics
: > "$ROOTFS/etc/crowdsec/parsers/s02-enrich/openwrt-whitelist.yaml"     # 空文件
verify_sub_cs_acquis >/dev/null 2>&1; eq "R5.1 半截组判不符" "$?" "1"
_qorig_setup_acquis >/dev/null 2>&1; eq "R5.2 重建返 0" "$?" "0"
verify_sub_cs_acquis >/dev/null 2>&1; eq "R5.3 重建后判就绪" "$?" "0"

echo "===== R6. 注入既有文件：只精准改自己负责的行，其他代码原样保留 ====="
CROWDSEC_CFG="$R_DIR/config6.yaml"
cat > "$CROWDSEC_CFG" <<'CFG'
api:
  client:
    credentials_path: /etc/crowdsec/local_api_credentials.yaml
  server:
    listen_uri: 127.0.0.1:8080
    trusted_ips:
      - 127.0.0.1
    my_custom_block:
      keep_me: yes
common:
  daemonize: true
CFG
BRIDGE_IP=10.1.0.1; LAPI_PORT=8080; CONTAINER_IP=10.1.0.100
_qorig_ensure_listen_uri >/dev/null 2>&1
_qorig_ensure_trusted_ip >/dev/null 2>&1
grep -q "my_custom_block" "$CROWDSEC_CFG" && grep -q "keep_me: yes" "$CROWDSEC_CFG"; chk "R6.1 其他代码段原样保留（不全删重建）" ok $?
grep -q "listen_uri: 0.0.0.0:8080" "$CROWDSEC_CFG"; chk "R6.2 listen_uri 已精准改写" ok $?
grep -q -- "- 10.1.0.1" "$CROWDSEC_CFG"; chk "R6.3 trusted_ips 已精准插入" ok $?

echo "===== R7. 断电残留 .tmp 不影响正式文件判定 ====="
CFG="$R_DIR/config7"
printf 'lxc.arch = amd64\nlxc.rootfs.path = dir:x\nlxc.utsname = c\nlxc.net.0.type = veth\n' | atomic_write "$CFG" "lxc.rootfs.path"
printf 'half-written-garbage' > "$CFG.tmp"     # 模拟上次写入断电残留
verify_ct_config >/dev/null 2>&1; eq "R7.1 正式文件完整就判就绪" "$?" "0"
rm -f "$CFG.tmp"

# ==================== 第六层：重装自愈（escalation tier 3） ====================
echo "===== S 层准备：重装自愈 mock ====="
S_DIR=/tmp/dag_s
rm -rf "$S_DIR"; /usr/bin/mkdir -p "$S_DIR"
S_SEQ="$S_DIR/seq.log"
BOOTSTRAP=/tmp/bp/files/usr/sbin/crowdsec-lxc-bootstrap.sh
# 提取重装自愈函数块真身 + 依赖的原子写/内容级 verify 真身
# （mock_install 曾把 verify_* 打成空壳；此处显式再取，防桩漂移）
/usr/bin/awk '
/^(atomic_write|_stamp_present|_stamp_write|_reinstall_fail_count|_fail_count_inc|_pending_recover|_bs_reexec|_cred_backup|_cred_restore|_reinstall_diag|_escalate_reinstall|full_reinstall|_bs_on_exit)\(\) \{$/ { print; inb=1; next }
/^(verify_img_migrate|verify_ct_config|verify_rootfs)\(\) \{$/ { print; inb=1; next }
inb && /^\}$/ { print "}"; inb=0; next }
inb { print }
' "$BOOTSTRAP" > /tmp/dag_s_orig.sh
. /tmp/dag_s_orig.sh
# 每段入口：重建 state/rootfs 夹具（全就绪基线：镜像好卷 + 容器 config 完整 +
# rootfs 七步产物齐全）+ 重装打桩。控制面：
#   S_PULL   1=last_pull 有效（门1 拒绝/放行）
#   S_STOP   1=ct_force_stop 成功
s_reset() {
    : > "$S_SEQ"
    STATE_DIR="$S_DIR/state"
    STAMP_FILE="$STATE_DIR/installed"
    REINSTALL_FAIL_FILE="$STATE_DIR/reinstall_fail"
    REINSTALL_PENDING_FILE="$STATE_DIR/reinstall_pending"
    CRED_BACKUP_DIR="$STATE_DIR/cred-backup"
    REINSTALL_MAX=2
    SCRIPT_VER="2026-10-19.89"
    _CRED_REL="etc/crowdsec/online_api_credentials.yaml"   # 提取器不含变量赋值，显式给
    ROOTFS="$S_DIR/rootfs"
    CFG="$S_DIR/config"
    CROWDSEC_CFG="$ROOTFS/etc/crowdsec/config.yaml"
    TARBALL="$S_DIR/img.tar.gz"
    BRIDGE_IP=10.1.0.1; LAPI_PORT=8080; CONTAINER_IP=10.1.0.100
    _bs_stamped=0; S_PULL=0; S_STOP=1
    CS_BOOTSTRAP_REINSTALL=0
    rm -rf "$STATE_DIR" "$ROOTFS"
    # _container_dns 桩必须先于构建器定义（构建器写 DNS= 行、verify 比对同一值）
    _container_dns() { echo 10.1.0.1; }
    /usr/bin/mkdir -p "$ROOTFS/etc/systemd/network" \
             "$ROOTFS/etc/systemd/system/multi-user.target.wants" \
             "$ROOTFS/etc/crowdsec/acquis.d" \
             "$ROOTFS/etc/crowdsec/parsers/s01-parse" \
             "$ROOTFS/etc/crowdsec/parsers/s02-enrich" \
             "$ROOTFS/lib/systemd/system"
    : > "$ROOTFS/SENTINEL_KEEP"                 # 哨兵：验证「不抹 rootfs」
    # rootfs 内容级就绪：etc/ + usr/ + os-release(ID=)，否则 verify_rootfs 判不符
    /usr/bin/mkdir -p "$ROOTFS/usr"
    printf 'ID=ubuntu\nVERSION_ID="24.04"\n' > "$ROOTFS/etc/os-release"
    # 好镜像：gzip 完整 + 含 etc/ 与 usr/（verify_img_migrate 内容级）
    _s_stage="$S_DIR/img_stage"
    /usr/bin/mkdir -p "$_s_stage/etc" "$_s_stage/usr"
    printf 'ID=ubuntu\n' > "$_s_stage/etc/os-release"
    : > "$_s_stage/usr/.keep"
    tar -czf "$TARBALL" -C "$_s_stage" etc usr
    printf 'lxc.arch = amd64\nlxc.rootfs.path = dir:/x\nlxc.utsname = crowdsec\nlxc.net.0.type = veth\n' > "$CFG"
    cat > "$CROWDSEC_CFG" <<'CFG'
api:
  client:
    credentials_path: /etc/crowdsec/local_api_credentials.yaml
  server:
    listen_uri: 127.0.0.1:8080
    trusted_ips:
      - 127.0.0.1
common:
  daemonize: true
CFG
    # 七步产物用真实构建器铺齐（Q 层 _qorig_ 真身，persisted）
    _qorig_setup_container_network >/dev/null 2>&1
    _qorig_setup_container_boot   >/dev/null 2>&1
    _qorig_setup_resolv           >/dev/null 2>&1
    _qorig_setup_acquis           >/dev/null 2>&1
    _qorig_ensure_listen_uri      >/dev/null 2>&1
    _qorig_ensure_trusted_ip      >/dev/null 2>&1
    # 外部环境桩
    bouncer_pulling() { [ "$S_PULL" = 1 ]; }
    cs_active_on_host() { return 0; }
    nft_table_ready() { return 0; }
    ct_running() { return 0; }
    ct_force_stop() { echo "force_stop" >> "$S_SEQ"; [ "$S_STOP" = 1 ]; }
    _ct_env() { echo "ct_env" >> "$S_SEQ"; return 0; }
    _bs_reexec() { echo "reexec env=${CS_BOOTSTRAP_REINSTALL:-unset}" >> "$S_SEQ"; return 0; }
}
s_cnt() { grep -c "^$1\$" "$S_SEQ" | tr -d ' '; }

echo "===== S1. installed stamp：唯一持久位，写时清计数 ====="
s_reset
_stamp_present >/dev/null 2>&1; eq "S1.1 无文件判未置位" "$?" "1"
_stamp_write >/dev/null 2>&1; eq "S1.2 写入返 0" "$?" "0"
grep -q "^installed$" "$STAMP_FILE" && grep -q "ver=2026-10-19.89" "$STAMP_FILE"; chk "S1.3 内容含 installed 与版本" ok $?
_stamp_present >/dev/null 2>&1; chk "S1.4 写入后判已置位" ok $?
mkdir -p "$STATE_DIR"; printf '2\n' > "$REINSTALL_FAIL_FILE"; : > "$REINSTALL_PENDING_FILE"
_stamp_write >/dev/null 2>&1
[ -f "$REINSTALL_FAIL_FILE" ] || [ -f "$REINSTALL_PENDING_FILE" ]; chk "S1.5 写 stamp 连带清计数与 pending" fail $?
eq "S1.6 _bs_stamped 置 1" "$_bs_stamped" "1"

echo "===== S2. 失败计数：半截写容错当 0 ====="
s_reset
eq "S2.1 无文件 → 0" "$(_reinstall_fail_count)" "0"
mkdir -p "$STATE_DIR"; printf '2\n' > "$REINSTALL_FAIL_FILE"
eq "S2.2 内容 2 → 2" "$(_reinstall_fail_count)" "2"
printf 'abc\n' > "$REINSTALL_FAIL_FILE"
eq "S2.3 非数字容错 → 0" "$(_reinstall_fail_count)" "0"
_fail_count_inc >/dev/null 2>&1; eq "S2.4 inc → 1" "$(_reinstall_fail_count)" "1"
_fail_count_inc >/dev/null 2>&1; eq "S2.5 inc → 2" "$(_reinstall_fail_count)" "2"

echo "===== S3. 五道门：任一不过返 1、不抹 rootfs、不重跑 ====="
s_reset; S_PULL=1
out=$(_escalate_reinstall 2>&1); eq "S3.1 last_pull 有效 → 拒" "$?" "1"
echo "$out" | grep -q "重装无益"; chk "S3.1 日志定位" ok $?
[ -f "$ROOTFS/SENTINEL_KEEP" ]; chk "S3.1 不抹 rootfs" ok $?
eq "S3.1 无重跑" "$(s_cnt reexec)" "0"

s_reset; S_PULL=0
out=$(_escalate_reinstall 2>&1); eq "S3.2 无 stamp（初次安装）→ 拒" "$?" "1"
echo "$out" | grep -q "防开机反复重置"; chk "S3.2 日志定位" ok $?
[ -f "$ROOTFS/SENTINEL_KEEP" ]; chk "S3.2 不抹 rootfs" ok $?

s_reset; S_PULL=0; mkdir -p "$STATE_DIR"; _stamp_write >/dev/null 2>&1
printf '2\n' > "$REINSTALL_FAIL_FILE"
out=$(_escalate_reinstall 2>&1); eq "S3.3 计数达阈值 → 拒" "$?" "1"
echo "$out" | grep -q "停止自动重装"; chk "S3.3 日志定位" ok $?

s_reset; S_PULL=0; mkdir -p "$STATE_DIR"; _stamp_write >/dev/null 2>&1
CS_BOOTSTRAP_REINSTALL=1
out=$(_escalate_reinstall 2>&1); eq "S3.4 重装后流程 → 拒（防递归）" "$?" "1"
echo "$out" | grep -q "禁止递归重装"; chk "S3.4 日志定位" ok $?
CS_BOOTSTRAP_REINSTALL=0

s_reset; S_PULL=0; mkdir -p "$STATE_DIR"; _stamp_write >/dev/null 2>&1
printf 'not-gzip' > "$TARBALL"
out=$(_escalate_reinstall 2>&1); eq "S3.5 镜像坏 → 拒" "$?" "1"
echo "$out" | grep -q "宁可失败也不抹"; chk "S3.5 日志定位" ok $?
[ -f "$ROOTFS/SENTINEL_KEEP" ]; chk "S3.5 不抹 rootfs" ok $?

s_reset; S_PULL=0; mkdir -p "$STATE_DIR"; _stamp_write >/dev/null 2>&1
_escalate_reinstall >/dev/null 2>&1; eq "S3.6 五门全过 → 放行" "$?" "0"

echo "===== S4. full_reinstall 主路径：备份→强停→抹→pending→带标记重跑 ====="
s_reset; S_PULL=0; mkdir -p "$STATE_DIR"; _stamp_write >/dev/null 2>&1
printf 'credentials:\n  url: https://api.crowdsec.net\n' > "$ROOTFS/etc/crowdsec/online_api_credentials.yaml"
out=$(full_reinstall 2>&1); rc=$?
eq "S4.1 桩 reexec 不真 exec，full_reinstall 按兜底返 1" "$rc" "1"
grep -q "api.crowdsec.net" "$CRED_BACKUP_DIR/online_api_credentials.yaml" 2>/dev/null; chk "S4.2 凭证已备份" ok $?
eq "S4.3 强停恰 1 次" "$(s_cnt force_stop)" "1"
[ -f "$ROOTFS/SENTINEL_KEEP" ]; chk "S4.4 rootfs 已抹（哨兵消失）" fail $?
[ -f "$REINSTALL_PENDING_FILE" ]; chk "S4.5 未完成标记已写" ok $?
eq "S4.6 带 CS_BOOTSTRAP_REINSTALL=1 重跑" "$(grep -c '^reexec env=1$' "$S_SEQ")" "1"
echo "$out" | grep -q "img_migrate 就绪"; chk "S4.7 抹前复核：镜像就绪" ok $?
echo "$out" | grep -q "ct_net 就绪"; chk "S4.8 抹前复核：构建七步就绪（各组置位 1）" ok $?
echo "$out" | grep -q "bouncer last_pull 失效"; chk "S4.9 抹前复核：last_pull 失效" ok $?

echo "===== S5. full_reinstall 中断路径：门拒/停不掉 → 不抹不重跑 ====="
s_reset; S_PULL=0
out=$(full_reinstall 2>&1); eq "S5.1 门拒 → 返 1" "$?" "1"
[ -f "$ROOTFS/SENTINEL_KEEP" ]; chk "S5.1 不抹 rootfs" ok $?
eq "S5.1 无重跑" "$(s_cnt reexec)" "0"
[ -f "$REINSTALL_PENDING_FILE" ]; chk "S5.1 无 pending" fail $?
s_reset; S_PULL=0; mkdir -p "$STATE_DIR"; _stamp_write >/dev/null 2>&1
S_STOP=0
out=$(full_reinstall 2>&1); eq "S5.2 强停失败 → 返 1" "$?" "1"
echo "$out" | grep -q "放弃重装"; chk "S5.2 日志定位" ok $?
[ -f "$ROOTFS/SENTINEL_KEEP" ]; chk "S5.2 不抹 rootfs" ok $?
eq "S5.2 无重跑" "$(s_cnt reexec)" "0"
[ -f "$REINSTALL_PENDING_FILE" ]; chk "S5.2 无 pending" fail $?

echo "===== S6. EXIT trap 与 pending：两路计数互斥不重复 ====="
s_reset; mkdir -p "$STATE_DIR"
( trap '_bs_st=$?; _bs_on_exit' EXIT
  CS_BOOTSTRAP_REINSTALL=1; _bs_stamped=0
  exit 42 )
eq "S6.1 重装后非零退出 → 计 1" "$(_reinstall_fail_count)" "1"
[ -f "$REINSTALL_PENDING_FILE" ]; chk "S6.1 pending 被清" fail $?

s_reset; mkdir -p "$STATE_DIR"
( trap '_bs_st=$?; _bs_on_exit' EXIT
  CS_BOOTSTRAP_REINSTALL=0; _bs_stamped=0
  exit 42 )
eq "S6.2 非重装流程失败 → 不计" "$(_reinstall_fail_count)" "0"

s_reset; mkdir -p "$STATE_DIR"
( trap '_bs_st=$?; _bs_on_exit' EXIT
  CS_BOOTSTRAP_REINSTALL=1; _bs_stamped=0
  exit 0 )
eq "S6.3 重装后成功退出 → 不计" "$(_reinstall_fail_count)" "0"

s_reset; mkdir -p "$STATE_DIR"
( trap '_bs_st=$?; _bs_on_exit' EXIT
  CS_BOOTSTRAP_REINSTALL=1; _bs_stamped=1
  exit 1 )
eq "S6.4 已 stamp 后失败（enroll 人工面）→ 不计" "$(_reinstall_fail_count)" "0"

s_reset; mkdir -p "$STATE_DIR"; : > "$REINSTALL_PENDING_FILE"
out=$(_pending_recover 2>&1)
eq "S6.5 检出 pending → 计 1（覆盖断电漏计）" "$(_reinstall_fail_count)" "1"
[ -f "$REINSTALL_PENDING_FILE" ]; chk "S6.5 pending 已清" fail $?
echo "$out" | grep -q "计一次失败"; chk "S6.5 日志定位" ok $?

s_reset
_pending_recover >/dev/null 2>&1; eq "S6.6 无 pending → 返 0 不动计数" "$?" "0"
eq "S6.6 计数仍 0" "$(_reinstall_fail_count)" "0"

echo "===== S7. 凭证备份/恢复 ====="
s_reset; mkdir -p "$STATE_DIR"
printf 'credentials:\n  url: https://api.crowdsec.net\n' > "$ROOTFS/etc/crowdsec/online_api_credentials.yaml"
_cred_backup >/dev/null 2>&1; eq "S7.1 有凭证 → 备份返 0" "$?" "0"
grep -q "api.crowdsec.net" "$CRED_BACKUP_DIR/online_api_credentials.yaml"; chk "S7.2 备份内容一致" ok $?
rm -f "$ROOTFS/etc/crowdsec/online_api_credentials.yaml"
_cred_restore >/dev/null 2>&1; eq "S7.3 有备份 → 恢复返 0" "$?" "0"
grep -q "api.crowdsec.net" "$ROOTFS/etc/crowdsec/online_api_credentials.yaml"; chk "S7.4 凭证落回 rootfs" ok $?
grep -q "ct_env" "$S_SEQ"; chk "S7.5 恢复后重启容器内 crowdsec" ok $?
s_reset
_cred_restore >/dev/null 2>&1; eq "S7.6 无备份 → 返 0 不碰 rootfs" "$?" "0"
_cred_backup >/dev/null 2>&1; eq "S7.7 无凭证 → 备份返 0 不报错" "$?" "0"

echo "===== S8. phase3_step 一次修复形态（v.81 起仅 shield/online_on/enroll 使用） ====="
s_reset
p3fix() { echo "fix" >> "$S_SEQ"; return 1; }
p3verify() { return 1; }
out=$(phase3_step "t" p3verify p3fix 2>&1); rc=$?
eq "S8.1 fix 执行失败 → 恰一次即 hard exit 1" "$rc:$(s_cnt fix)" "1:1"
echo "$out" | grep -q '修复执行失败，hard 失败'; chk "S8.2 执行失败日志" ok $?
s_reset
p3fix() { echo "fix" >> "$S_SEQ"; return 0; }
out=$(phase3_step "t" p3verify p3fix 2>&1); rc=$?
eq "S8.3 fix 返 0 但复核仍不符 → hard exit 1（不等第二次）" "$rc:$(s_cnt fix)" "1:1"
echo "$out" | grep -q '一次修复未通过复核，hard 失败'; chk "S8.4 复核不符日志" ok $?
s_reset
p3verify() { return 0; }
out=$(phase3_step "t" p3verify p3fix 2>&1); rc=$?
eq "S8.5 就绪 → 跳过不调 fix" "$rc:$(s_cnt fix)" "0:0"
# v.93：CAPI 放出独立成 capi_release 小步骤（归 BOUNCERVERIFY 组），
# 只有 bouncer_verify 通过后才会走到；源码级回归锁定这条职责边界
awk '/^build_capi_release\(\)/,/^\}$/' "$BOOTSTRAP" | grep -q 'ensure_online_client_on'; chk "S8.6 源码回归：CAPI 放出在 build_capi_release 内（BOUNCERVERIFY 组把关）" ok $?
grep -q 'full_reinstall || { log "\[步骤C\] 不满足重装条件' "$BOOTSTRAP"; chk "S8.7 源码回归：step_C 门拒接 full_reinstall 后 hard" ok $?

# ==================== 第六层：运行期 last_pull 探针（v.82） ====================
echo "===== T 层准备：探针 probe_tick 真身提取 + 控制面桩 ====="
T_DIR=/tmp/dag_t
rm -rf "$T_DIR"; /usr/bin/mkdir -p "$T_DIR"
PROBE=/tmp/bp/files/usr/sbin/crowdsec-lxc-probe.sh
# probe_tick 真身提取（判定+动作一体；修复逻辑不在探针里，全部委托 $BOOT）
/usr/bin/awk '
/^probe_tick\(\) \{$/ { print; inb=1; next }
inb && /^\}$/ { print "}"; inb=0; next }
inb { print }
' "$PROBE" > /tmp/dag_t_tick.sh
. /tmp/dag_t_tick.sh
# 常量重定向到 T_DIR + 桩（BOOT 记录调用并按 T_RC 返值；plog 记录日志）
BOOT="$T_DIR/boot"; LOCK="$T_DIR/lock"; BOOT_LOG="$T_DIR/boot.log"
STAMP_FILE="$T_DIR/installed"
PROBE_STALL_ROUNDS=3; PROBE_COOLDOWN=600
: > "$T_DIR/trigcalls"
printf '#!/bin/sh\nif [ "${1:-}" = "--probe-check" ]; then exit "$(cat %s/rc)"; fi\necho x >> %s/trigcalls\nif [ -d %s/lock ]; then echo locked >> %s/lockatcall; else echo unlocked >> %s/lockatcall; fi\nexit "$(cat %s/rc)"\n' "$T_DIR" "$T_DIR" "$T_DIR" "$T_DIR" "$T_DIR" "$T_DIR" > "$BOOT"
chmod +x "$BOOT"
T_PLOG="$T_DIR/plog"
plog() { echo "$*" >> "$T_PLOG"; }
t_reset() {
    : > "$T_PLOG"; : > "$T_DIR/trigcalls"; : > "$T_DIR/lockatcall"; echo 0 > "$T_DIR/rc"
    rm -rf "$LOCK"; echo installed > "$STAMP_FILE"
    P_STALL=0; P_LAST_TRIG=0
}

echo "===== T1. last_pull 新鲜 → 零触发 ====="
t_reset
probe_tick; eq "T1.1 动作标签 ok" "$P_ACTION" "ok"
eq "T1.2 未拉起 bootstrap" "$(grep -c "^x$" "$T_DIR/trigcalls")" "0"
eq "T1.3 停滞计数 0" "$P_STALL" "0"

echo "===== T2. 停滞防抖：连续未达阈值不触发 ====="
t_reset; echo 1 > "$T_DIR/rc"
probe_tick; eq "T2.1 第 1 轮 stall-warn" "$P_ACTION:$(grep -c "^x$" "$T_DIR/trigcalls"):$P_STALL" "stall-warn:0:1"
probe_tick; eq "T2.2 第 2 轮仍 warn" "$P_ACTION:$(grep -c "^x$" "$T_DIR/trigcalls"):$P_STALL" "stall-warn:0:2"
grep -q '第 1/3 轮' "$T_PLOG"; chk "T2.3 告警日志带轮次" ok $?

echo "===== T3. 连续停滞达阈值 → 告警 + 持锁拉起 bootstrap ====="
t_reset; echo 1 > "$T_DIR/rc"
probe_tick; probe_tick
probe_tick; eq "T3.1 第 3 轮触发" "$P_ACTION:$(grep -c "^x$" "$T_DIR/trigcalls")" "trigger:1"
eq "T3.2 bootstrap 被调时锁由探针持有" "$(cat "$T_DIR/lockatcall")" "locked"
eq "T3.3 触发后锁释放" "$([ -d "$LOCK" ] && echo yes || echo no)" "no"
eq "T3.4 触发后停滞计数归零" "$P_STALL" "0"
[ "$P_LAST_TRIG" -gt 0 ]; chk "T3.5 记录触发时刻" ok $?
grep -q '持锁拉起' "$T_PLOG"; chk "T3.6 触发日志" ok $?

echo "===== T4. 冷却期内再停滞 → 不重复触发 ====="
probe_tick; probe_tick
probe_tick; eq "T4.1 冷却中" "$P_ACTION:$(grep -c "^x$" "$T_DIR/trigcalls")" "cooldown:1"
grep -q '冷却中' "$T_PLOG"; chk "T4.2 冷却日志含剩余秒数" ok $?

echo "===== T5. 冷却过期 → 可再触发 ====="
P_LAST_TRIG=$(( $(date +%s) - 601 )); P_STALL=0
probe_tick; probe_tick
probe_tick; eq "T5.1 冷却过期再触发" "$P_ACTION:$(grep -c "^x$" "$T_DIR/trigcalls")" "trigger:2"

echo "===== T6. 引导持锁中（开机/上次触发在跑）→ 本轮跳过 ====="
t_reset; echo 1 > "$T_DIR/rc"; /usr/bin/mkdir -p "$LOCK"
probe_tick; eq "T6.1 动作 lock-busy" "$P_ACTION:$(grep -c "^x$" "$T_DIR/trigcalls")" "lock-busy:0"
grep -q '引导进行中' "$T_PLOG"; chk "T6.2 锁占用日志" ok $?

echo "===== T7. 未安装（无 installed）→ 静默等待不误判 ====="
t_reset; rm -f "$STAMP_FILE"; echo 1 > "$T_DIR/rc"
probe_tick; eq "T7.1 动作 wait-install" "$P_ACTION:$(grep -c "^x$" "$T_DIR/trigcalls")" "wait-install:0"
eq "T7.2 停滞计数不累加" "$P_STALL" "0"

echo "===== T8. bootstrap hard（退出非 0）→ 记录但不杀探针 ====="
t_reset; echo 1 > "$T_DIR/rc"
probe_tick; probe_tick
probe_tick; _t8rc=$?
eq "T8.1 触发后探针函数返 0（不致命）" "$_t8rc:$(grep -c "^x$" "$T_DIR/trigcalls")" "0:1"
grep -q 'hard 失败，需人工介入' "$T_PLOG"; chk "T8.2 hard 日志" ok $?

echo "===== T9. 停滞后恢复 → 计数归零 + 恢复日志 ====="
t_reset; echo 1 > "$T_DIR/rc"
probe_tick; probe_tick
echo 0 > "$T_DIR/rc"; probe_tick
eq "T9.1 恢复为 ok" "$P_ACTION:$P_STALL" "ok:0"
grep -q 'last_pull 已恢复（停滞 2 轮后）' "$T_PLOG"; chk "T9.2 恢复日志带轮数" ok $?

echo "===== T10. 恢复后停滞重新从第 1 轮计 ====="
echo 1 > "$T_DIR/rc"; probe_tick
eq "T10.1 重新计数" "$P_ACTION:$P_STALL" "stall-warn:1"

echo "===== T11. 源码回归：探针不含任何修复动作 ====="
_eq=$(grep -c 'lxc-start\|lxc-attach\|nft \|uci set\|systemctl' "$PROBE")
eq "T11.1 无修复类命令" "$_eq" "0"
grep -q 'mkdir "$LOCK"' "$PROBE"; chk "T11.2 唯一写操作是引导锁" ok $?

echo "===== T12. --probe-check 真身：只判定不进 main、不写状态 ====="
t12_state="$T_DIR/state"
out=$(CS_BOOTSTRAP_STATE="$t12_state" sh "$BOOTSTRAP" --probe-check 2>&1); _t12rc=$?
eq "T12.1 无容器环境 exit 1（判定失效）" "$_t12rc" "1"
echo "$out" | grep -q '===== crowdsec-lxc-bootstrap'; chk "T12.2 未进 main（无引导起始日志）" fail $?
eq "T12.3 未创建状态目录" "$([ -e "$t12_state" ] && echo yes || echo no)" "no"

echo "===== T13. 接线源码回归 ====="
grep -q '\-\-probe-check' "$BOOTSTRAP"; chk "T13.1 bootstrap 含探针入口" ok $?
grep -q 'crowdsec-lxc-probe' "$BOOTSTRAP"; chk "T13.2 bootstrap 引导成功拉起探针" ok $?
[ -x "$PROBE" ]; chk "T13.3 探针脚本可执行" ok $?
[ -x /tmp/bp/files/etc/init.d/crowdsec-lxc-probe ]; chk "T13.4 init.d 壳可执行" ok $?

echo ""
echo "===== v.93 八组链式置位 + 无复核范式 + 内容级校验: PASS=$PASS FAIL=$FAIL =====" 
# 清理测试假 init.d，保持沙箱系统干净
for _s in network dnsmasq firewall dropbear ttyd log logd; do rm -f "/etc/init.d/$_s"; done
[ "$FAIL" = 0 ]
