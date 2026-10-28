#!/bin/sh
# pkg-restore-apps.sh — 观测应用的主程序检查与装回
#
# 为什么有这支脚本（用户 2026-10-29 定，判据取向见 crowdsec-lxc-probe.sh L219-231）：
#   探针只做两件事 —— 探测 + 拉脚本，自己不动手装包。
#   daed / ssrp / mosdns / clashoo 这四个应用不像 smartdns 那样接管 53，
#   所以不判进程、不判端口，只判主程序包在不在册；缺了由本脚本装回。
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

# 应用清单。写固件里真实的包名，不是对外叫法：
#   daed     → daed             eBPF 代理，主程序就是它自己
#   ssrp     → luci-app-ssr-plus  26.x 的 ssr-plus 是 LuCI 应用，内核
#                                 （xray-core / mihomo / sing-box）由它 Depends 拉。
#                                 主程序被删时 Depends 里的内核多半还在，所以只判
#                                 应用包能覆盖「界面没了/规则不生效」这个用户能感知的故障。
#   mosdns   → mosdns
#   clashoo  → clashoo          自带 mihomo 内核
_PA_LIST="${CS_PROBE_APPS:-daed luci-app-ssr-plus mosdns clashoo}"

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
    [ -f "$ROMDIR/usr/lib/opkg/info/$1.list" ] && return 0
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
        printf '%-22s %s\n' "$_pa_p" "$_pa_s"
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
