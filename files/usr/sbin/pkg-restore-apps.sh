#!/bin/sh
# pkg-restore-apps.sh — 观测应用的主程序检查与装回
#
# 为什么有这支脚本（用户 2026-10-29 定，判据取向见 crowdsec-lxc-probe.sh L219-231）：
#   探针只做两件事 —— 探测 + 拉脚本，自己不动手装包。
#   daed / mosdns / clashoo 这三个应用不像 smartdns 那样接管 53
#   （ssrp 已于 v.180.165 整组移除，理由见清单处的说明），
#   所以不判进程、不判端口，只判包在不在册；缺了由本脚本装回。
#   【v.180.164】判定粒度从「主程序一个包」扩到「主程序 + 依赖内核 + LuCI 界面」：
#   实测 opkg remove --force-depends clashoo 能一次删掉 44MB 内核而壳与 i18n 不动，
#   结果是库在、界面在、功能全死。只盯主程序包名覆盖不到这种半损坏态。
#   装包动作只写在这一处，探针里不出现任何 opkg/apk 调用 —— 两处实现迟早漂移。
#
# 用法：
#   pkg-restore-apps.sh --check     只判断（只读，一个字节都不写）
#                                   全部在位 0；有缺 1；判断不了 2
#                                   有缺时把包名打在一行（空格分隔），供探针写日志
#   pkg-restore-apps.sh --list      打印清单与逐项状态（排障用），始终 0
#   pkg-restore-apps.sh [--repair]  装回缺的那些，再复判一次
#                                   0 = 全部在位；1 = 仍有缺（或装不上）
#
# 判据只有一条：包管理器认不认（opkg list-installed / apk info -e）。
#   不看文件清单 —— 理由同 pkg-restore.sh 开头那三条：清单随版本漂、
#   文件缺失 ≠ 功能缺失、两个判据混用会死循环。
#
# 【关键】「该不该有」的门槛：只恢复固件里本来就带的那个应用。
#   否则一台根本没装 daed 的机器，探针每轮都判「缺」、每轮装一次，装上了再被
#   用户卸掉，又装 —— 就不是修复是强加。判据取 /rom 侧留下的痕迹：
#     · opkg：/rom/usr/lib/opkg/info/<包>.list —— 固件里装过它才有这份清单，
#             而且是只读基底，opkg remove 删不掉（运行侧那份会被删，不能用来判）
#     · apk ：/rom/root/apk-cache/<包>-*.apk —— build25.sh 收进固件的那批包库
#     · opkg 自建包：/rom/root/pkg-cache/<包>_*.ipk —— build24.sh 收的那批
#   三处都没有 → 这台机器的固件没带这个应用 → 什么都不做，也不报错。
#
# 环境变量：
#   CS_PROBE_APPS  应用（包名）清单，空格分隔。默认见 _PA_LIST
#   ROMDIR         只读基座，默认 /rom
#   RESTORE_BIN    装包执行体，默认 /usr/sbin/pkg-restore.sh
#
# 退出码：0 / 1 / 2（2 只在 --check 用于「判断不了」）

set -u
ROMDIR="${ROMDIR:-/rom}"
_RESTORE="${RESTORE_BIN:-/usr/sbin/pkg-restore.sh}"

# 应用清单。写固件里真实的包名，不是对外叫法。
#
# 【v.180.164】用户 2026-10-29 定：不只保护主程序，依赖内核和 LuCI 界面一起保护。
# 起因是实测 opkg remove --force-depends clashoo 一次就把 44MB 的 mihomo 内核删干净，
# 而 luci 壳与 i18n 完好 —— 库存在、界面在、功能全死，这种形态只看主程序包名不够。
# 分组维护，每组三块：
#   ① 主程序（内核跑在这个包里，或它本身就是服务）
#   ② 依赖（内核 / geo 数据 / eBPF 运行时）—— 少一个都是「装了但起不来」
#   ③ LuCI 界面（luci-app-* / luci-i18n-*）—— 少了用户看不见入口，等同于坏了
#
#   clashoo 组：内核就在主包里（control: Provides: mihomo, clash-meta，Installed-Size 46.5MB）
#   daed 组：  eBPF 程序，vmlinux-btf 是运行时前提，缺了 daed 直接起不来
#   mosdns 组：geo 数据包是规则来源，缺了 mosdns 空转
#   ssrp 组：已整组移除，见下方 v.180.165 说明
#
# 【v.180.165】ssrp 组整组删除（用户 2026-10-29 定）。理由两条：
#   ① daed 已经能替代它，没有必要再维护一套 ssr-plus；
#   ② ssr-plus 的依赖链太长 —— xray-core / xray-plugin / v2ray-plugin /
#      三套 shadowsocksr-libev / trojan-plus / tuic / shadow-tls / naiveproxy /
#      simple-obfs-client，每轮 _pa_missing 都要逐包问一次包管理器，
#      探针负担和它带来的价值完全不成正比。
# 两条构建线都不再装它：
#   · 24.10：shell/custom-packages.sh 里那一行已删；
#   · 25.12：本来就没装，但包库里有对应 apk（build25.sh 收的兜底包）。
# 所以即使包库还留着这些 apk，也不会再被判成「该有」—— 判据见 _pa_should。
#
# 门槛仍在 _pa_should：只有 /rom 侧留了痕迹（info/<包>.list 或包库里那份 ipk）
# 才判「该有」。所以这张表可以照全量写，固件没带的包会显示「固件未带」而不是
# 每轮触发一次装包 —— 不会把没选的应用强加给别的机器。
_PA_CLASHOO="clashoo luci-app-clashoo luci-i18n-clashoo-zh-cn"
# vmlinux-btf 只在 24.10 存在裸名包。25.12 线的 BTF 由内核自带
# （/sys/kernel/btf/vmlinux），run 包里那份叫 vmlinux-btf-6.12.79 且被
# build25.sh 刻意排除（与内核版本强绑定，装错 daed 的 eBPF 校验过不去）。
# 裸名在 25.12 固件里查不到 info/<包>.list，_pa_should 判「固件未带」自动跳过，
# 所以这行在两条线上都安全，不需要构建期分流。
_PA_DAED="daed daed-geoip daed-geosite vmlinux-btf luci-app-daed luci-i18n-daed-zh-cn"
# 【v.180.166】mosdns 组不再包含 v2ray-geoip / v2ray-geosite。
# 用户 2026-10-29 定：这两个是通用的 geo 数据包，上游一直在更新，不该被
# 「缺了就按本地包库装回旧版」的判据锁死 —— 那样用户换了新版反而会被探针
# 拽回去。它们仍然由构建装进固件（shell/custom-packages.sh），只是不再纳入
# 探针的保护范围：被卸掉时不补、不报缺失。
_PA_MOSDNS="mosdns luci-app-mosdns luci-i18n-mosdns-zh-cn"
# 通用件组（v.180.166）：不属于哪一个应用，但被多处依赖，缺了会安静地坏。
# ssrp 移除时这些包在构建清单里被刻意留下（shell/custom-packages.sh 有说明），
# 留下来就必须一起保护 —— 只留不护，被删掉时探针不会去装回来。
# sing-box 原先挂在 ssrp 组里，但它本身是通用代理内核，与 ssrp 无关。
# geo 数据（v2ray-geoip / v2ray-geosite）整体不进保护清单：它们是通用数据包，
# 上游一直在更新，「缺了就按本地包库装回旧版」的判据会把人拽回老版本。
# daed-geoip / daed-geosite 不在此列 —— 它们是 daed 自身的运行依赖，
# 跟着 daed 一起判。
_PA_COMMON="sing-box microsocks dns2socks ipt2socks chinadns-ng tcping libopenssl3"
_PA_LIST="${CS_PROBE_APPS:-$_PA_CLASHOO $_PA_DAED $_PA_MOSDNS $_PA_COMMON}"

log() { printf '[APP] %s\n' "$*"; }

# 包管理器：两个都不在 → 判断不了。返回 0 且置 _PA_PM，否则返回 1。
_PA_PM=""
_pa_pm() {
    if command -v opkg >/dev/null 2>&1; then _PA_PM=opkg; return 0; fi
    if command -v apk >/dev/null 2>&1;  then _PA_PM=apk;  return 0; fi
    return 1
}

# 已装包名表缓存：一次全表扫描，四次判定共用（同 pkg-restore.sh 的 _PR_CACHE）
_PA_CACHE=""
_pa_installed() {
    if [ "$_PA_PM" = "opkg" ]; then
        if [ -z "$_PA_CACHE" ]; then
            _PA_CACHE=$(opkg list-installed 2>/dev/null | sed -n 's/ - .*//p')
        fi
        printf '%s\n' "$_PA_CACHE" | grep -qx "$1"
        return $?
    fi
    apk info -e "$1" >/dev/null 2>&1
}

# 固件里本来就有这个应用吗 —— 见文件头「该不该有」的门槛
_pa_should() {
    # opkg：固件装过才有 info/<包>.list。只读基底，remove 删不掉运行侧那份。
    [ -f "$ROMDIR/usr/lib/opkg/info/$1.list" ] && return 0
    # apk：以**固件出厂的已安装数据库**为准。
    # 【v.180.165】原来这里拿「包库里有没有 <包>-*.apk」当判据，是错的：
    # 包库收的是兜底包，25.12 线 114 个 apk 远多于固件实际安装的 622 个包，
    # 于是包库里每一个「有包但没装」的包都被判成「该有」。
    # 2026-10-29 的 25.12 真机复现：ssrp 组 5 个包被判缺失，第 3 轮 --repair
    # 把 xray-core / xray-plugin 装了上去（运行时 624 vs 出厂 622）——
    # 这不是修复，是把用户没选的应用强加给机器。
    # /rom/lib/apk/db/installed 是出厂的已安装库（P:<包名> 一行一个），
    # 记录的是「固件带了什么」，与之后 user 装了什么都不相干，正好是判据。
    if [ -f "$ROMDIR/lib/apk/db/installed" ]; then
        grep -qxF "P:$1" "$ROMDIR/lib/apk/db/installed" 2>/dev/null
        return $?
    fi
    # 兜底：老固件没有 apk 数据库时才退回包库判据（24.10 线走不到这里，
    # 它的包都在 info/<包>.list 里命中了第一行）。
    for _pa_f in "$ROMDIR/root/apk-cache/$1"-*.apk "$ROMDIR/root/pkg-cache/$1"_*.ipk; do
        [ -f "$_pa_f" ] && return 0
    done
    return 1
}

# 输出「该有却没有」的包名（一行，空格分隔）。没有则输出空行。
_pa_missing() {
    _pa_m=""
    for _pa_p in $_PA_LIST; do
        _pa_should "$_pa_p" || continue
        _pa_installed "$_pa_p" && continue
        _pa_m="$_pa_m $_pa_p"
    done
    printf '%s\n' "$_pa_m" | sed 's/^ *//'
}

_pa_check() {
    _pa_cm=$(_pa_missing)
    [ -n "$_pa_cm" ] && printf '%s\n' "$_pa_cm"
    [ -z "$_pa_cm" ]
}

_pa_list() {
    for _pa_p in $_PA_LIST; do
        _pa_s="固件未带"
        if _pa_should "$_pa_p"; then
            if _pa_installed "$_pa_p"; then _pa_s="在位"; else _pa_s="缺失"; fi
        fi
        printf '%-34s %s\n' "$_pa_p" "$_pa_s"
    done
    return 0
}

_pa_repair() {
    _pa_n=0
    for _pa_p in $(_pa_missing); do
        _pa_n=$((_pa_n + 1))
        log "装回 $_pa_p"
        if "$_RESTORE" --tree "$_pa_p"; then
            log "装回完成 $_pa_p"
        else
            log "装回失败 $_pa_p（本地包库没有它，或包管理器不可用）"
        fi
    done
    [ "$_pa_n" -gt 0 ] || log "无需装回（没有「该有却缺失」的应用）"
    # 装完必须重判：清缓存，让刚装上的包体现在下一次判定里
    _PA_CACHE=""
    [ -z "$(_pa_missing)" ]
}

case "${1:---repair}" in
--check)
    _pa_pm || { log "判断不了：opkg 与 apk 都不在"; exit 2; }
    _pa_check && exit 0 || exit 1
    ;;
--list)
    _pa_pm || { log "判断不了：opkg 与 apk 都不在"; exit 2; }
    _pa_list
    exit 0
    ;;
--repair)
    _pa_pm || { log "判断不了：opkg 与 apk 都不在"; exit 2; }
    _pa_repair && exit 0 || exit 1
    ;;
-*)
    echo "用法：$0 --check | --list | --repair" >&2
    exit 2
    ;;
*)
    echo "用法：$0 --check | --list | --repair" >&2
    exit 2
    ;;
esac
