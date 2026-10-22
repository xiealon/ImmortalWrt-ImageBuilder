#!/bin/sh
# R14：自建 network 段必须声明段类型
#
# 背景：`uci -q set network.br_lan.type='bridge'` 只写选项、不声明段类型时，uci 会把
# 一个不存在的段建成 `config br_lan 'br_lan'`。netifd 只认 config device /
# config interface，遇到别的类型直接跳过该段。结果：运行中的 br-lan 还在（内核里
# 没被拆），一重启 br-lan 就消失——而 verify 只查 .type='bridge' 是查不出来的，
# 因为 uci 层面那个段确实存在、选项也确实对。所以这里盯的是「段类型声明」本身，
# 不是它的任何一个选项值。
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
BS="$REPO/files/usr/sbin/crowdsec-lxc-bootstrap.sh"
# 只含活代码的副本：整行注释（行首可有空白 + #）不算命中。
# 注释里提到某关键字（例如记录「曾经 disable lxc-auto」）不该被断言当成
# 「代码里在做这件事」，否则断言会假红或假绿。断言一律 grep 这份副本。
BS_C="$(mktemp)"
grep -v '^[[:space:]]*#' "$BS" > "$BS_C"
trap 'rm -f "$BS_C"' EXIT INT TERM
R=0
ck() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 got=[$2] want=[$3]"; R=$((R+1)); fi; }

# 抽函数体：从 `<name>() {` 到同层第一个顶格的 `}`
body() {
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\)[[:space:]]*\\{" { inside = 1 }
        inside { print }
        inside && /^}/ { exit }
    ' "$BS_C"
}

BB=$(body build_br_lan_ports)
VB=$(body verify_br_lan_ports)

echo "== 1 函数体抽取（抽不到会让后面全部假通过）=="
ck "R14.1 build_br_lan_ports 抽到函数体" "$([ -n "$BB" ] && echo yes || echo no)" "yes"
ck "R14.2 verify_br_lan_ports 抽到函数体" "$([ -n "$VB" ] && echo yes || echo no)" "yes"

echo "== 2 段类型声明（本缺陷的根）=="
ck "R14.3 build 声明 br_lan 为 device 段" \
   "$(printf '%s\n' "$BB" | grep -cF "uci -q set network.br_lan='device'")" "1"
ck "R14.4 verify 校验 br_lan 段类型" \
   "$(printf '%s\n' "$VB" | grep -c 'network\.br_lan 2>/dev/null)" = "device"')" "1"

echo "== 3 声明必须排在选项写入之前 =="
_d=$(printf '%s\n' "$BB" | grep -nF "network.br_lan='device'" | cut -d: -f1)
_t=$(printf '%s\n' "$BB" | grep -nF "network.br_lan.type='bridge'" | cut -d: -f1)
ck "R14.5 device 声明在 .type 之前" \
   "$([ -n "$_d" ] && [ -n "$_t" ] && [ "$_d" -lt "$_t" ] && echo ok || echo bad)" "ok"

echo "== 4 不再硬编码段名 =="
ck "R14.6 无 uci -q delete network.cfg030f15" \
   "$(grep -cF 'uci -q delete network.cfg030f15' "$BS_C")" "0"
ck "R14.7 重复段按 name 匹配（build）" \
   "$(printf '%s\n' "$BB" | grep -cF '$_ds.name')" "1"
ck "R14.8 重复段按 name 匹配（verify）" \
   "$(printf '%s\n' "$VB" | grep -cF '$_ds.name')" "1"

echo "== 5 通用扫描：自建 network 段都要有段类型声明 =="
_secs=$(grep -oE 'uci -q set network\.[a-z_0-9]+\.' "$BS_C" \
        | sed 's/^uci -q set network\.//' | sed 's/\.$//' | sort -u)
_decl=$(grep -oE "uci -q set network\.[a-z_0-9]+='(device|interface)'" "$BS_C" \
        | sed 's/^uci -q set network\.//' | sed 's/=.*//' | sort -u)
for _sec in $_secs; do
    case "$_sec" in
        lan|loopback|globals|wan|wan6) continue ;;
    esac
    ck "R14.9 network.$_sec 有段类型声明" \
       "$(printf '%s\n' "$_decl" | grep -cx "$_sec")" "1"
done

echo "== 6 lxcbr0 对照项 =="
ck "R14.10 network.lxc 仍是 =interface" \
   "$(grep -cF "uci -q set network.lxc='interface'" "$BS_C")" "1"

echo "== 7 rootfs 包校验不得因截断误判 =="
# 同一家族：运行时看不出、装机/重启才暴露。tar 深度优先打包（-C "$R" .），
# ./usr 排在 ./etc 的上万条文件之后，用 head -n 200 分别要求 etc/ 和 usr/ 出现，
# 前 200 条永远到不了 usr → 完好的包被判成半截 → 容器永远建不起来。
IB=$(body verify_img_migrate)
ck "R14.11 verify_img_migrate 抽到函数体" "$([ -n "$IB" ] && echo yes || echo no)" "yes"
ck "R14.12 不再分别要求 etc/ 与 usr/" \
   "$(printf '%s\n' "$IB" | grep -c '^(\.\/)?usr/')" "0"
ck "R14.13 合并成任一顶层目录即通过" \
   "$(printf '%s\n' "$IB" | grep -cF '(etc|usr|bin|lib)/')" "1"

echo "== 8 副本缺失/损坏必须能从 /rom 只读基准恢复 =="
# /rom 是 squashfs 只读挂载，原件删不掉也改不掉，是比 LEGACY_TARBALL 更硬的基准。
GB=$(body build_img_migrate)
ck "R14.14 build_img_migrate 抽到函数体" "$([ -n "$GB" ] && echo yes || echo no)" "yes"
ck "R14.15 有 /rom 恢复分支" \
   "$(printf '%s\n' "$GB" | grep -cF '/rom$TARBALL')" "2"
_r=$(printf '%s\n' "$GB" | grep -nF '/rom$TARBALL' | head -n1 | cut -d: -f1)
_l=$(printf '%s\n' "$GB" | grep -nF 'LEGACY_TARBALL' | head -n1 | cut -d: -f1)
ck "R14.16 /rom 恢复排在 LEGACY 之前" \
   "$([ -n "$_r" ] && [ -n "$_l" ] && [ "$_r" -lt "$_l" ] && echo ok || echo bad)" "ok"
ck "R14.17 恢复后要过 gzip 校验才算成功" \
   "$(printf '%s\n' "$GB" | grep -cF 'gzip -t "$TARBALL"')" "2"

echo "== 9 DAG：INSTALL（解压 rootfs）必须排在第一位 =="
# rootfs 是 ct_net / ct_bootlink / ct_resolv 与 capi_block / ct_boot 的硬前置。
# 曾经 INSTALL 排在 PREP 之后，而 PREP 里 ct_net 就要写 rootfs 内文件 → 必失败
# → hard 终止 → INSTALL 永不执行 → rootfs 永不解压（自锁，新刷机首次开机必挂）。
_SEQ=$(grep -m1 '^GROUP_SEQ=' "$BS_C" | sed 's/^GROUP_SEQ="//' | sed 's/"$//')
ck "R14.18 GROUP_SEQ 首位是 INSTALL" "$(echo "$_SEQ" | cut -d' ' -f1)" "INSTALL"
ck "R14.19 PREP_NODES 含 ct_net（rootfs 已先行）" \
   "$(grep -m1 '^PREP_NODES=' "$BS_C" | grep -c 'ct_net')" "1"
for _n in ct_net ct_bootlink ct_resolv; do
    ck "R14.20 $_n 依赖 rootfs" \
       "$(grep -m1 "^DEP_$_n=" "$BS_C" | grep -c 'rootfs')" "1"
done

echo "== 10 网络基线模式：不装 Crowdsec 也要配好网络 =="
# 场景：Action 里 Include Crowdsec=no → 185MB 镜像不生成。但 Router IP / 掩码 /
# 网关 / DNS 已经写进 /etc/config/custom_router_*.txt，消费者是 bootstrap 的 PREP 组。
# 老逻辑两道门都把它挡死：rc.local 的「无镜像且无 rootfs → exit 0」，以及 bootstrap
# 自己的同款判定。结果是用户填的地址永不生效，固件停在默认 192.168.1.1。
RC="$REPO/files/etc/rc.local"
ck "R15.1 rc.local 无镜像时不再直接 exit" \
   "$(grep -c '无镜像且无 rootfs，跳过引导' "$RC")" "0"
ck "R15.2 rc.local 无镜像时切 --net-only" \
   "$(grep -cF 'BOOT_MODE="--net-only"' "$RC")" "1"
ck "R15.3 rc.local 按 BOOT_MODE 调用 bootstrap" \
   "$(grep -cF '"$BOOT" $BOOT_MODE' "$RC")" "1"
ck "R15.4 bootstrap 有 --net-only 入口" \
   "$(grep -cF '"--net-only"' "$BS_C")" "1"
ck "R15.5 net-only 把组链缩成 PREP" \
   "$(grep -cF 'GROUP_SEQ="PREP"' "$BS_C")" "1"
# 取赋值右侧再按词边界比对：$NET_ONLY_SKIP 的值以引号开头，直接 grep " bridge"
# 永远匹配不到第一个词（引号不是空格）。
_skip=$(grep -m1 '^NET_ONLY_SKIP=' "$BS_C" | sed 's/^NET_ONLY_SKIP="//' | sed 's/"$//')
for _n in bridge ct_net ct_bootlink ct_resolv lxc_zone fwd_rules snat; do
    ck "R15.6 NET_ONLY_SKIP 含 $_n" \
       "$(echo " $_skip " | grep -c " $_n ")" "1"
done
# cgroup_mount 反过来必须留下：它挂 /sys/fs/cgroup/systemd 是容器内 systemd 的硬前置，
# 不碰 rootfs；verify_cgroup_mount 在 cgroup2 下第二判据直接通过，实际很少动手；
# 真要动手，build_cgroup_mount 结尾是 `_mount_systemd_cgroup; return 0`，
# 无论如何都返回 0，不会 hard 终止。摘掉它零收益，还会让「镜像补上后头一次起容器」
# 多一跳补挂。
ck "R15.6b net-only 仍保留 cgroup_mount" \
   "$(echo " $_skip " | grep -c ' cgroup_mount ')" "0"
ck "R15.6c cgroup_mount 仍归属 PREP" \
   "$(grep -m1 '^NODE_GROUP_cgroup_mount=' "$BS_C" | grep -c 'PREP')" "1"
# 原断言查「函数体里有 return 0」，命中的其实是注释里那句「原先无条件 return 0」——
# 去注释后立刻露馅。真正的保障是两条：build_cgroup_mount 原样透传挂载结果，
# 而 _mount_systemd_cgroup 在 unified 宿主上跳过 v1 层并 return 0，不会把 PREP hard 掉。
ck "R15.6d build_cgroup_mount 透传挂载结果" \
   "$(awk '/^build_cgroup_mount\(\)/,/^}/' "$BS_C" | grep -c 'return \$?')" "1"
ck "R15.6e unified 宿主跳过 v1 层" \
   "$(awk '/^_mount_systemd_cgroup\(\)/,/^}/' "$BS_C" | grep -c 'unified')" "1"
# v.108.15：只 grep 路径会误判「子层级挂载」和「同路径挂了别的东西」。
# 判据必须落到 /proc/mounts 的列上：$2 挂载点、$3 类型、$4 里的 name=systemd。
ck "R15.6f 宿主判据要求 cgroup 类型 + name=systemd" \
   "$(sed -n '/^_cg_host_ok() {/,/^}/p' "$BS_C" | grep -c 'name=systemd')" "1"
ck "R15.6g verify_cgroup_mount 用精确判据" \
   "$(sed -n '/^verify_cgroup_mount() {/,/^}/p' "$BS_C" | grep -c '_cg_host_ok')" "1"
ck "R15.6h 挂载后回读也用精确判据（开头+回读=2）" \
   "$(sed -n '/^_mount_systemd_cgroup() {/,/^}/p' "$BS_C" | grep -c '_cg_host_ok')" "2"
ck "R15.6i 形态不对先卸载再重挂" \
   "$(sed -n '/^_mount_systemd_cgroup() {/,/^}/p' "$BS_C" | grep -c 'umount "\$_cg"')" "1"
# 宿主挂对不等于容器里能用：容器内 cgroup.procs 可读、PID 1 是 systemd，两条都要。
ck "R15.6j 容器内核对 cgroup.procs（v1 层级 + unified 两条路径）" \
   "$(sed -n '/^verify_ct_cgroup() {/,/^}/p' "$BS_C" | grep -c 'cgroup.procs')" "2"
ck "R15.6k 容器内核对 PID 1 是 systemd" \
   "$(sed -n '/^verify_ct_cgroup() {/,/^}/p' "$BS_C" | grep -c '/proc/1/comm')" "1"
ck "R15.6l ct_boot 调用容器内核对（初次+复核=2）" \
   "$(sed -n '/^build_ct_boot() {/,/^}/p' "$BS_C" | grep -c 'verify_ct_cgroup')" "2"
ck "R15.6m ct_boot 的 return 1 恰好 4 处（启动链缺失×2 / cgroup 不可用×2；listen_uri 已挪出开机）" \
   "$(sed -n '/^build_ct_boot() {/,/^}/p' "$BS_C" | grep -c 'return 1')" "4"
# 同一判断不能有两套标准：bootstrap 升级成按列比之后，init.d/lxc-auto 的 boot()
# 若还留着裸路径 grep，等于开一条后门 —— 那条只看「路径上有东西」。
ck "R15.6n init.d/lxc-auto 的 cgroup 判据按列比（判断+回读=2）" \
   "$(grep -cF '$2=="/sys/fs/cgroup/systemd" && $3=="cgroup"' "$REPO/files/etc/init.d/lxc-auto")" "2"
ck "R15.6o init.d/lxc-auto 不再用裸路径 grep" \
   "$(grep -c 'grep -qE' "$REPO/files/etc/init.d/lxc-auto")" "0"
ck "R15.6p init.d/lxc-auto 挂载后回读失败要留痕" \
   "$(grep -c 'cgroup systemd 层级挂载后回读失败' "$REPO/files/etc/init.d/lxc-auto")" "1"
# 缺文件判过：原来 `-f service || continue` 让「容器里没有 crowdsec」也算自启就绪。
ck "R15.6t 缺 crowdsec.service 判不符（不再 continue）" \
   "$(sed -n '/^verify_sub_ct_bootlink() {/,/^}/p' "$BS_C" | grep -c '容器内缺 crowdsec.service')" "1"
ck "R15.6u networkd 缺失仍允许放行" \
   "$(sed -n '/^verify_sub_ct_bootlink() {/,/^}/p' "$BS_C" | grep -c 'continue')" "1"
# ensure() 在 build 成功之后不复核 verify —— 所以 build 必须自己判到底，
# 否则「verify 说不符 / build 说修好了」会同时成立，假绿一路带到阶段 3。
ck "R15.6v build_ct_bootlink 缺 crowdsec.service 时返回 1" \
   "$(sed -n '/^setup_container_boot() {/,/^}/p' "$BS_C" | grep -c '无法建自启软链')" "1"
ck "R15.6w build_ct_bootlink 建软链失败也返回 1" \
   "$(sed -n '/^setup_container_boot() {/,/^}/p' "$BS_C" | grep -c '建 crowdsec 自启软链失败')" "1"
# 口径：不看日志，直接重置。资产残缺（缺 crowdsec.service）要能自动转彻底重装，
# 不能停在「rootfs 残缺」让人去翻日志。full_reinstall 自己还有 stamp/计数/防递归/镜像门。
ck "R15.6x 缺 crowdsec.service 判结构性损坏" \
   "$(sed -n '/^_structurally_broken() {/,/^}/p' "$BS_C" | grep -c 'crowdsec.service')" "1"
ck "R15.6y ensure 的 build 失败分支会转彻底重装" \
   "$(sed -n '/^ensure() {/,/^}/p' "$BS_C" | grep -c 'full_reinstall')" "1"
ck "R15.6z 转重装前必须先过 installed 标记（防首次安装反复重置）" \
   "$(sed -n '/^ensure() {/,/^}/p' "$BS_C" | grep -c '_stamp_present && _structurally_broken')" "1"
ck "R15.7 net-only 放行本机判定（无镜像也进 DAG）" \
   "$(grep -cF '[ "$NET_ONLY" != "1" ] && [ ! -f "$TARBALL" ]' "$BS_C")" "1"
# 收工点必须在 flush_uci 之后：commit/reload 都在 flush_uci 里，提前 exit 会让改好的
# network 停在内存里，重启即丢——那等于白配。
_l_fl=$(grep -n '^    flush_uci$' "$BS_C" | tail -n1 | cut -d: -f1)
_l_ok=$(grep -n '_NET_ONLY_OK=1' "$BS_C" | head -n1 | cut -d: -f1)
ck "R15.8 net-only 收工排在 flush_uci 之后" \
   "$([ -n "$_l_fl" ] && [ -n "$_l_ok" ] && [ "$_l_ok" -gt "$_l_fl" ] && echo ok || echo bad)" "ok"
# ip_forward：net-only 走不到写 installed 标记那条路，_bs_stamped 恒 0，
# 若不加 _NET_ONLY_OK 这道放行，退出时会把 ip_forward 还原成 0，整机不能上网。
ck "R15.9 _ipfwd_restore 认 _NET_ONLY_OK" \
   "$(grep -cF '[ "${_NET_ONLY_OK:-0}" = 1 ] && return 0' "$BS_C")" "1"

echo "== 10b 验证返回码：验不过必须是 1，不能假阳性 =="
# 曾经 verify_br_lan_ports 在「物理网口枚举为空」时 return 0（判通过）：
# ensure 判通过就不会去 build，br-lan 桥从没建过，却一路标完成、组置位、
# --net-only 分支 exit 0 —— 网络没配好却报成功，日志干干净净。
# build 那边同条件是 return 1（「不敢建空桥」），两处必须一致：
# 「无法确认」就是「不通过」。
ck "R15.10 网口枚举不到时 verify 判不通过（return 1）" \
   "$(sed -n '/^verify_br_lan_ports() {/,/^}/p' "$BS_C" | grep -c '\[ -n "\$_vp" \] || return 1')" "1"
# flush_uci 曾经把 commit/reload 失败只写日志、仍 return 0，等于「日志说失败、
# 退出码说成功」。现在逐项收集到 _fu_bad，末尾统一 return 1。
ck "R15.11 flush_uci 收集 network-commit 失败" \
   "$(grep -c 'network-commit' "$BS_C")" "1"
ck "R15.11b flush_uci 收集 network-reload 失败" \
   "$(grep -c 'network-reload' "$BS_C")" "1"
ck "R15.11c flush_uci 按 _fu_bad 返回 1" \
   "$(grep -c '以下动作失败：\$_fu_bad' "$BS_C")" "1"
ck "R15.11d net-only 检查 flush 结果并 exit 1" \
   "$(grep -c '配置提交/重载失败，详见上方 \[flush\] 行' "$BS_C")" "1"
# 「不适用」可以 return 0（不触发每轮重建），但必须留痕，不许完全静默。
# v.108.27 起 wan_input 整个节点已删，不在这份清单里 —— 它的「不适用」日志随函数一起没了。
for _pair in \
    "verify_lan_input:本轮不校验 input/forward" \
    "verify_svc_bind:本轮不校验管理服务绑定" \
    "verify_docker_fw:本轮不校验 docker 防火墙"
do
    _vf=${_pair%%:*}
    _vt=${_pair#*:}
    ck "R15.12 $_vf 跳过时留日志" "$(grep -c "$_vt" "$BS_C")" "1"
done

echo "== 10c 容器常驻走 lxc-auto 服务，不许再 disable =="
# v.56 起为了「容器只由本脚本负责」，build_ct_boot 里 disable lxc-auto 再自己 lxc-start。
# 副作用：files/etc/init.d/lxc-auto 的 boot() 里那段 systemd cgroup 挂载一起废掉，
# 且开机自启只剩 rc.local 一条路，失败就再没有别的手接管。v.108 回退。
ck "R15.13 不再 disable lxc-auto" \
   "$(grep -c 'lxc-auto disable' "$BS_C")" "0"
ck "R15.14 build_ct_boot 拉起 lxc-auto" \
   "$(sed -n '/^build_ct_boot() {/,/^}/p' "$BS_C" | grep -c '/etc/init.d/lxc-auto start')" "1"
ck "R15.15 校验 /etc/config/lxc-auto 里的容器名" \
   "$(grep -c 'lxc-auto.@container\[0\].name' "$BS_C" | awk '{print ($1>=1)?"1":"0"}')" "1"
# lxc-auto 包自带的 /etc/config/lxc-auto 整份都是注释（#config container / #option name
# container1 / ...），config_foreach 遍历不到 container 段，start() 直接 return 0 什么都不做。
# 「只校验不 commit」= 永远拉不起来，必须能补写（v.108.8 反转 v.108.7）。
ck "R15.15b 能补写 /etc/config/lxc-auto" \
   "$(sed -n '/^_ensure_lxc_auto() {/,/^}/p' "$BS_C" | grep -c 'uci -q commit lxc-auto')" "1"
# v.108.9 起配置重新固化进镜像：workflow 不再把 custom/ 盖在 files/etc/config 上
# （Docker bind mount 会整体遮蔽该目录），改成挂到 immortalwrt/custom 再由构建脚本拷入。
ck "R15.15c 固化的 files/etc/config/lxc-auto 存在" \
   "$([ -f "$REPO/files/etc/config/lxc-auto" ] && echo yes || echo no)" "yes"
ck "R15.15d 固化配置里容器名是 ubuntu" \
   "$(grep -c "^	option name 'ubuntu'$" "$REPO/files/etc/config/lxc-auto")" "1"
# 挂载点必须避开 files/etc/config，否则上面那份文件照样进不了镜像
ck "R15.15e workflow 不把 custom 挂到 files/etc/config" \
   "$(grep -c 'custom:/home/build/immortalwrt/files/etc/config' "$REPO/.github/workflows/build-x86-64-24.10.x.yml" "$REPO/.github/workflows/build-x86-64-25.12.x.yml" | awk -F: '{s+=$2} END{print s+0}')" "0"
ck "R15.15f build24.sh 把 custom/* 拷进 files/etc/config" \
   "$(grep -c 'cp -f "$_cf" /home/build/immortalwrt/files/etc/config/' "$REPO/x86-64/build24.sh")" "1"
ck "R15.15g build25.sh 把 custom/* 拷进 files/etc/config" \
   "$(grep -c 'cp -f "$_cf" /home/build/immortalwrt/files/etc/config/' "$REPO/x86-64/build25.sh")" "1"
# uci-defaults 保留为兜底（幂等：名字已对就 exit 0，不动固化好的配置）
ck "R15.15h uci-defaults 兜底脚本仍在" \
   "$(grep -c 'lxc-auto.@container\[-1\].name=$_LXC_NAME' "$REPO/files/etc/uci-defaults/98-lxc-auto.sh")" "1"
ck "R15.15i build24.sh chmod 98-lxc-auto.sh" \
   "$(grep -c 'files/etc/uci-defaults/98-lxc-auto.sh' "$REPO/x86-64/build24.sh")" "1"
ck "R15.15j build25.sh chmod 98-lxc-auto.sh" \
   "$(grep -c 'files/etc/uci-defaults/98-lxc-auto.sh' "$REPO/x86-64/build25.sh")" "1"
# 容器名现在有三处来源：bootstrap 的 LXC_NAME 默认值、uci-defaults 兜底、固化配置。
# 改名时漏一处就是「服务拉错容器」或「两票互相覆盖」，三个名字必须收敛成一个。
ck "R15.15k 三处容器名一致" \
   "$({ grep -o 'LXC_NAME:-[A-Za-z0-9_-]*' "$BS_C" | sed 's/.*:-//'
        sed -n "s/.*name=\([a-zA-Z0-9_-]*\)\"$/\\1/p" "$REPO/files/etc/uci-defaults/98-lxc-auto.sh"
        sed -n "s/^[[:space:]]*option name '\(.*\)'$/\\1/p" "$REPO/files/etc/config/lxc-auto"
      } | sort -u | wc -l | tr -d ' ')" "1"
# custom/ 的拷贝排在 make image 之前，谁拷谁赢：注入的 lxc-auto 能覆盖固化配置，
# 把容器名改掉且现场毫无报错。两个构建脚本都必须显式跳过它。
ck "R15.15l build24.sh 跳过 custom/lxc-auto" \
   "$(grep -c 'case "$(basename "$_cf")"' "$REPO/x86-64/build24.sh")" "1"
ck "R15.15m build25.sh 跳过 custom/lxc-auto" \
   "$(grep -c 'case "$(basename "$_cf")"' "$REPO/x86-64/build25.sh")" "1"
# files/etc/init.d/lxc-auto 的 start_container() 会执行段里的 `list command`。
# 镜像固化的容器段没有这一项，出现即为被注入，_ensure_lxc_auto 必须清掉它。
ck "R15.15n _ensure_lxc_auto 清除注入的 command" \
   "$(sed -n '/^_ensure_lxc_auto() {/,/^}/p' "$BS_C" | grep -c 'delete lxc-auto.@container\[0\].command')" "1"
ck "R15.15o 服务端确实会执行 command（清理的理由）" \
   "$(grep -c 'config_list_foreach "$cfg" command run_command' "$REPO/files/etc/init.d/lxc-auto")" "1"
ck "R15.15p _ensure_lxc_auto 校正 timeout" \
   "$(sed -n '/^_ensure_lxc_auto() {/,/^}/p' "$BS_C" | grep -c 'timeout 已校正为 300')" "1"
ck "R15.15q 多余段只告警不删" \
   "$(sed -n '/^_ensure_lxc_auto() {/,/^}/p' "$BS_C" | grep -c '只维护第一段')" "1"
# 旧固件（v107-bp）的启动链是断的，现场靠手工建 /etc/init.d/lxcboot + S99lxcboot 兜底。
# 这份兜底不在 GUARD_FILES 里，没有任何步骤回收它；「保留配置」刷到新版后
# S99lxc-auto 与 S99lxcboot 会抢同一个容器，且它带的手工 cgroup 挂载会再叠一份。
# 所以必须在 lxc-auto 链路就位后主动清，并且只在那个分支里清（否则等于砍掉唯一活路）。
ck "R15.15r _purge_legacy_lxcboot 会删旧 init 脚本" \
   "$(sed -n '/^_purge_legacy_lxcboot() {/,/^}/p' "$BS_C" | grep -c 'rm -f "$_lb_init"')" "1"
ck "R15.15s 清理只在 _ensure_lxc_auto 成功分支内调用" \
   "$(sed -n '/^build_ct_boot() {/,/^}/p' "$BS_C" | awk '/if _ensure_lxc_auto; then/{f=1;next} f&&/^    fi$/{f=0} f' | grep -c '_purge_legacy_lxcboot')" "1"
ck "R15.15t 清理失败不硬终止（函数内无 return 1）" \
   "$(sed -n '/^_purge_legacy_lxcboot() {/,/^}/p' "$BS_C" | grep -c 'return 1')" "0"
ck "R15.15u 清理覆盖 rc.d 里的残留链接" \
   "$(sed -n '/^_purge_legacy_lxcboot() {/,/^}/p' "$BS_C" | grep -c '/etc/rc.d/\*lxcboot\*')" "1"
ck "R15.16 verify_ct_config 不硬查 lxc.utsname" \
   "$(sed -n '/^verify_ct_config() {/,/^}/p' "$BS_C" | grep -c 'lxc\.utsname')" "0"
# write_cfg 写死 lxc.utsname 时，LXC 6.x 判它无效、apply_cfg 整行删掉，
# 现场 cat 出来就是「config 里没有 utsname」→ verify 判不完整 → BOOT hard。
ck "R15.17 write_cfg 按 LXC 版本选容器名键" \
   "$(grep -c '_wm_key="lxc.uts.name"' "$BS_C")" "1"
ck "R15.18 write_cfg 不再写死 lxc.utsname" \
   "$(grep -c '^lxc\.utsname = ' "$BS_C")" "0"

echo "== 10d 管理服务绑定：只钉 dropbear，ttyd 整块移除（v.108.40） =="
# 原来那两条 ttyd 判据是「interface 必须 all」+「netstat -lnt 查端口真在听」。
# 翻车点是后者：ImmortalWrt 默认固件通常不带 netstat 这个 applet，命令不存在 →
# 管道为空 → grep 必失败 → 配置写得完全正确也被判成「写了没生效」，收口复核直接
# exit 1，连带 _stamp_write 不执行、installed 永远写不下，每次开机全量重跑并重赌
# bouncer_verify 的 60 秒窗口 —— 这才是「时好时坏」的根源。
# 本机不用网页终端，verify/build 两侧的 ttyd 全部删除，判据只剩 dropbear 一条。
ck "R15.19 build_svc_bind 不再写 ttyd" \
   "$(sed -n '/^build_svc_bind() {/,/^}/p' "$BS_C" | grep -c 'ttyd')" "0"
ck "R15.20 verify_svc_bind 不再引用 ttyd" \
   "$(sed -n '/^verify_svc_bind() {/,/^}/p' "$BS_C" | grep -c 'ttyd')" "0"
ck "R15.21 verify_svc_bind 不再依赖 netstat" \
   "$(sed -n '/^verify_svc_bind() {/,/^}/p' "$BS_C" | grep -c 'netstat')" "0"
ck "R15.21b verify_svc_bind 仍校验 dropbear 绑定 LAN 网络" \
   "$(sed -n '/^verify_svc_bind() {/,/^}/p' "$BS_C" | grep -c 'dropbear.@dropbear\[0\].Interface')" "1"

echo "== 10e cgroup：判据必须是真挂载，不是目录可写 =="
# 现场：容器内 systemd 报 Failed to mount cgroup at /sys/fs/cgroup/systemd:
# Operation not permitted → Failed to mount API filesystems → Exiting PID 1。
# 宿主的 _mount_systemd_cgroup 却认为自己「已就绪」——因为 /sys/fs/cgroup 是
# tmpfs，mkdir 出来的目录天生可写，touch 一定成功。
ck "R15.22 _mount_systemd_cgroup 不再用 touch 判可写" \
   "$(sed -n '/^_mount_systemd_cgroup() {/,/^}/p' "$BS_C" | grep -c 'touch ')" "0"
ck "R15.23 _mount_systemd_cgroup 回读 /proc/mounts" \
   "$(sed -n '/^_mount_systemd_cgroup() {/,/^}/p' "$BS_C" | grep -c '/proc/mounts' | awk '{print ($1>=2)?"1":"0"}')" "1"
ck "R15.24 build_cgroup_mount 不吞返回值" \
   "$(sed -n '/^build_cgroup_mount() {/,/^}/p' "$BS_C" | grep -c 'return \$?')" "1"
ck "R15.25 lxc-auto boot 判到选项层（name=systemd）" \
   "$(grep -cF 'name=systemd(,|$)' "$REPO/files/etc/init.d/lxc-auto" | awk '{print ($1>=1)?"1":"0"}')" "1"
# hybrid 宿主（cgroup v1 + v2 都在）曾被「只要 cgroup2 存在就判通过」放行，
# systemd 子树永远不挂，容器内 systemd 起不来。只有纯 unified 才允许跳过。
ck "R15.26 verify_cgroup_mount 不再单凭 cgroup2 放行" \
   "$(sed -n '/^verify_cgroup_mount() {/,/^}/p' "$BS_C" | grep -c 'type cgroup\[\[:space:\]\]')" "1"
ck "R15.27 lxc-auto start 失败留痕" \
   "$(grep -c 'lxc-auto: 容器' "$REPO/files/etc/init.d/lxc-auto")" "1"
# lxc-start 不带 -P 时按 /etc/lxc/lxc.conf 的 lxc.lxcpath 找容器；镜像里那份配置
# 若没写 /srv/lxc，就会去 /var/lib/lxc 找不到、静默失败。脚本自己探一下更稳。
ck "R15.28 lxc-auto 探测 lxcpath" \
   "$(grep -c '\-P /srv/lxc' "$REPO/files/etc/init.d/lxc-auto" | awk '{print ($1>=1)?"1":"0"}')" "1"
# 其他容器（用户自己建的）只会写 lxc.start.auto=1，config_foreach 看不到，
# 认这个标记的是 lxc-autostart。start() 末尾必须带上它，否则别人的容器永远不自启。
ck "R15.29 lxc-auto 兼容 lxc.start.auto" \
   "$(grep -c 'lxc-autostart -a' "$REPO/files/etc/init.d/lxc-auto")" "1"

echo "== 11 编译期锁死：容器恒内置，没有开关可关 =="
# 只要「能选择不内置」这个口子还在，就会有人选它，然后得到一个「填了 Router IP
# 却不生效」的固件。开关删掉、1G 选项删掉、空间不足直接失败——不给这个组合留门。
W24="$REPO/.github/workflows/build-x86-64-24.10.x.yml"
W25="$REPO/.github/workflows/build-x86-64-25.12.x.yml"
for _w in "$W24" "$W25"; do
    _n=$(basename "$_w" .yml)
    ck "R16.1 $_n 无 Include Crowdsec 输入项" \
       "$(grep -c '^      Include Crowdsec:' "$_w")" "0"
    ck "R16.2 $_n 无 CS_INCLUDE 开关" \
       "$(grep -c 'CS_INCLUDE' "$_w")" "0"
    ck "R16.3 $_n Prepare 步骤无 if 条件" \
       "$(grep -c 'if: env.CS_INCLUDE' "$_w")" "0"
    ck "R16.4 $_n Profile 无 1G 选项" \
       "$(grep -c "          - '1G'" "$_w")" "0"
    ck "R16.5 $_n 空间不足直接失败（不自动跳过）" \
       "$(grep -c '请把 Profile 调到 2G / 3G / 4G / 10G 后重跑' "$_w")" "1"
done
# 两种结构都算过：master 只有 Download（v.108.59 删掉了 Prepare 回退），
# patch-1 这类「纯本地构建」分支只有 Prepare —— 判据是「至少有一条产出容器的路」。
for _w in "$W24" "$W25"; do
    ck "R16.6 $(basename "$_w" .yml) 仍会取容器 rootfs（Download 或 Prepare 至少一条在）" \
       "$(grep -cE 'Download prebuilt Crowdsec LXC tarball|Prepare Crowdsec LXC Rootfs' "$_w" \
          | awk '{ print ($1 >= 1) ? "1" : "0" }')" "1"
done

echo "== 17 断言自身不许再被注释糊弄 =="
# v.108.10 的教训：先是用 grep -c 'lxc-auto disable' 判「有没有在禁用」，
# 结果命中注释里那句「曾经 disable」，得出「没有 disable」的错误结论；
# 反过来 R15.6d 又靠注释里「原先无条件 return 0」假绿了一整年。
# 现在针对脚本文件的断言一律走 BS_C（去注释副本），原始 $BS 只剩生成副本那一处。
ck "R17.1 断言普遍改走去注释副本" \
   "$(grep -c 'BS_C' "$0" | awk '{print ($1>=30)?"1":"0"}')" "1"
ck "R17.2 副本里确实没有整行注释" \
   "$(grep -c '^[[:space:]]*#' "$BS_C")" "0"
ck "R17.3 副本非空（否则所有断言假通过）" \
   "$([ -s "$BS_C" ] && echo yes || echo no)" "yes"

echo "== 18 v.108.24：每个节点先验现场，且判据必须是配置一致性 =="
# 原来 ensure() 第一行是 _bs_flag_on "_done_$_o" && return 0：上一轮留过完成标记
# 就直接认定没问题，连现场都不看。标记说做了、现场说没做，永远发现不了。
ck "R18.1 ensure 不再用 _done_ 短路（每次都先验现场）" \
   "$(awk '/^ensure\(\) \{/,/^}/' "$BS_C" | grep -c '_bs_flag_on "_done_')" "0"
ck "R18.2 ensure 里 verify 出现在 build 之前" \
   "$(awk '/^ensure\(\) \{/,/^}/' "$BS_C" | awk '/verify_\$_o/{a=NR} /build_\$_o/{b=NR} END{ if(a>0 && b>a) print "ok"; else print "bad" }')" "ok"
# 转发规则：build 写 段类型+src+dest+target 四项，verify 必须四项都比
ck "R18.3 fwd_rules 比 target=ACCEPT（不能只比 src/dest）" \
   "$(awk '/^verify_fwd_rules\(\)/,/^}/' "$BS_C" | grep -c 'target)" = "ACCEPT"')" "4"
ck "R18.4 fwd_rules 比段类型 rule（段类型不对 = 规则不生效）" \
   "$(awk '/^verify_fwd_rules\(\)/,/^}/' "$BS_C" | grep -c ')" = "rule"')" "4"
# lxc zone：builder 按 name 找段，verify 不能写死段名（LuCI 重建会改名）
ck "R18.5 lxc_zone 按 name 定位段（与 builder 同一个找法）" \
   "$(awk '/^verify_lxc_zone\(\)/,/^}/' "$BS_C" | grep -c '_zone_sec lxc')" "1"
ck "R18.6 lxc_zone 不写死 firewall.lxczone" \
   "$(awk '/^verify_lxc_zone\(\)/,/^}/' "$BS_C" | grep -c 'firewall\.lxczone')" "0"
# 删除项也要验：ignore=1 对、但 ra 又被打开，等于一边不发地址一边发 RA
ck "R18.7 dhcp_ignore 验删除项（ra/dhcpv6/ndp/ra_management 都在列表里）" \
   "$(awk '/^verify_dhcp_ignore\(\)/,/^}/' "$BS_C" | grep -c 'for _k in ra dhcpv6 ndp ra_management')" "1"
ck "R18.8 dhcp_ignore 验 dnsmasq 段无 authoritative" \
   "$(awk '/^verify_dhcp_ignore\(\)/,/^}/' "$BS_C" | grep -c 'authoritative')" "1"
# 网桥：uci 三项 + 内核地址，缺一不可（device 被改坏时重启桥就没了）
ck "R18.9 bridge 比 device=lxcbr0 与 ipaddr" \
   "$(awk '/^verify_bridge\(\)/,/^}/' "$BS_C" | grep -c 'network\.lxc\.device\|network\.lxc\.ipaddr')" "2"
# 首跑检测只服务重装/bouncer 处置，前面节点不许引用它
ck "R18.10 _BS_FIRST_RUN 只出现在 4 处（定义/main×2/_escalate_reinstall）" \
   "$(grep -c '_BS_FIRST_RUN' "$BS_C")" "4"
ck "R18.11 组级 build 不再清 _done_（ensure 反正会验）" \
   "$(grep -c '_bs_flag_clear "_done_\$_n"' "$BS_C")" "0"

echo "== 20 v.108.27：WAN 直接锁死 —— 两个节点删掉，删段变成无条件动作 =="
# 目标就是旁路由：WAN 口永远不该存在。于是「检测有没有 wan 段」对这台机器恒等于
# 「还没有，那就删」，多一个 DAG 节点只是多一行日志 —— 连节点一起删，删段降级成
# main 开头的一次无条件、幂等、删完复核的动作。
ck "R20.1 DAG 里不再有 wan_removed 节点" \
   "$(sed -n '/^DAG_NODES=/p' "$BS_C" | grep -c ' wan_removed ')" "0"
ck "R20.2 DAG 里不再有 wan_input 节点" \
   "$(sed -n '/^DAG_NODES=/p' "$BS_C" | grep -c ' wan_input ')" "0"
ck "R20.3 PREP 组节点清单同步移除这两个" \
   "$(sed -n '/^PREP_NODES=/p' "$BS_C" | grep -c 'wan_removed\|wan_input')" "0"
ck "R20.4 flush_uci 不再收 wan_removed 的 _dirty_" \
   "$(grep -c 'for _o in br_lan_ports lan_static bridge wan_removed' "$BS_C")" "0"
ck "R20.5 flush_uci 不再收 wan_input 的 _dirty_" \
   "$(grep -c 'fwd_rules wan_input' "$BS_C")" "0"
ck "R20.6 四个 wan 相关函数已全删" \
   "$(grep -cE '^(verify|build)_wan_(removed|input)\(\)' "$BS_C")" "0"
ck "R20.7 按活接口判适用性的 _wan_live_ifaces 一并删掉" \
   "$(grep -c '_wan_live_ifaces' "$BS_C")" "0"
ck "R20.8 按物理口数的 _phys_port_count 不留死代码" \
   "$(grep -c '_phys_port_count' "$BS_C")" "0"
ck "R20.9 有 purge_wan_sections：无条件删段的那一步" \
   "$(grep -c '^purge_wan_sections()' "$BS_C")" "1"
ck "R20.10 删之前先问「还在不在」（幂等：没有就不动）" \
   "$(awk '/^purge_wan_sections\(\)/,/^}/' "$BS_C" | grep -c '(_wan_sections)')" "2"
ck "R20.11 删的是整段（uci delete），不是 disabled=1" \
   "$(awk '/^purge_wan_sections\(\)/,/^}/' "$BS_C" | grep -c 'uci -q delete "network\.\$_pw_n"')" "1"
ck "R20.12 不写 disabled=1 这种替代写法" \
   "$(awk '/^purge_wan_sections\(\)/,/^}/' "$BS_C" | grep -cE 'set .*\.disabled')" "0"
ck "R20.13 commit 失败要判失败（不许只在内存里改）" \
   "$(awk '/^purge_wan_sections\(\)/,/^}/' "$BS_C" | grep -c 'uci -q commit network')" "1"
ck "R20.14 删完立刻 reload（内核里那口才真的没了；抽成 _net_reload 才数得到）" \
   "$(awk '/^purge_wan_sections\(\)/,/^}/' "$BS_C" | grep -c '^    _net_reload$')" "1"
ck "R20.14b _net_reload 就是 /etc/init.d/network reload" \
   "$(grep -c '^_net_reload() { /etc/init.d/network reload' "$BS_C")" "1"
ck "R20.15 main 里两处无条件调用：开头建前提 + 结尾收口（v.108.32），失败即终止" \
   "$(grep -c 'if ! purge_wan_sections; then' "$BS_C")" "2"
ck "R20.16 调用点在组循环之前（网络组的前提先成立）" \
   "$(awk '/^main\(\) \{/,0' "$BS_C" | awk '/purge_wan_sections; then/{p=NR} /for _g in \$GROUP_SEQ; do/{g=NR; exit} END{print (p>0 && g>p) ? "yes" : "no"}')" "yes"

echo "== 23 v.108.29：WAN 段虽不在 DAG 里，体检仍要能发现它还在 =="
# v.108.27 把 wan_removed 节点删了（删段改为主流程无条件动作）。副作用是：
# --verify-only 只遍历 DAG_NODES，于是「WAN 面还开着」这件事没人报，体检会说「全达标」。
# 这一组钉住：体检里必须有独立的 wan_purged 项，且它只读。
ck "R23.1 有 audit_wan_purged：体检专用的一项" \
   "$(grep -c '^audit_wan_purged()' "$BS_C")" "1"
ck "R23.2 判据是「_wan_sections 为空」" \
   "$(awk '/^audit_wan_purged\(\)/,/^}/' "$BS_C" | grep -c '\[ -z "\$(_wan_sections)" \]')" "1"
ck "R23.3 network 解析失败判不符（读不出来 ≠ 没有 wan 段）" \
   "$(awk '/^audit_wan_purged\(\)/,/^}/' "$BS_C" | grep -c 'uci show network >/dev/null 2>&1 || return 1')" "1"
ck "R23.4 audit 项只读：不写 uci" \
   "$(awk '/^audit_wan_purged\(\)/,/^}/' "$BS_C" | grep -cE 'uci (-q )?(set|delete|commit|add)')" "0"
ck "R23.5 _audit_all 真的把 wan_purged 算进汇总" \
   "$(awk '/^_audit_all\(\)/,/^}/' "$BS_C" | grep -c 'audit_wan_purged')" "1"
ck "R23.6 不符时计入 _ab（不是只打印）" \
   "$(awk '/^_audit_all\(\)/,/^}/' "$BS_C" | sed -n '/audit_wan_purged/,$p' | grep -c '_ab=\$((_ab + 1))')" "1"
ck "R23.7 purge 也先确认 network 能解析（写坏的配置不算「已清空」）" \
   "$(awk '/^purge_wan_sections\(\)/,/^}/' "$BS_C" | grep -c '无法解析 /etc/config/network')" "1"
ck "R23.8 --net-only 同时裁 PREP_NODES（组内执行看的是它，不是 DAG_NODES）" \
   "$(awk '/^main\(\) \{/,0' "$BS_C" | grep -c 'PREP_NODES="\$_no_prep"')" "1"
ck "R23.9 NET_ONLY_SKIP 含 lxc_auto（那是容器启动链，不是网络基线）" \
   "$(sed -n '/^NET_ONLY_SKIP=/p' "$BS_C" | grep -c ' lxc_auto ')" "1"

echo "------------------------------------------------------------------"
echo "R14 RESULT: $R 项失败"
exit $R
