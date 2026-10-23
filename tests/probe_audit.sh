#!/bin/sh
# R19【v.108.25】：全量体检（--verify-only）+ 静态配置 sha 基线 + 探针周期体检
#
# 出发点：既然每个节点都已经是「先验现场、有就过」，整个脚本随时可以退化成一次体检。
# 探针每隔 N 轮跑一次 --verify-only，就知道这台机器有没有漂移；有项不符就拉起正常
# 引导去补（正常引导自己会按需补那几项）。
#
# 另一条：解析器只验「文件在 / 键齐全 / 条数对」是形式判据 —— 少一个字节照样过，
# 但规则可能已经不生效。所以再加一层 sha：和上次写的那份逐字节比。
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
BS="$REPO/files/usr/sbin/crowdsec-lxc-bootstrap.sh"
PR="$REPO/files/usr/sbin/crowdsec-lxc-probe.sh"
BS_C="$REPO/tests/.r19.body.$$"
grep -v '^[[:space:]]*#' "$BS" > "$BS_C" || { echo "FATAL: 无法生成活代码副本"; exit 2; }
PR_C="$REPO/tests/.r19.probe.$$"
grep -v '^[[:space:]]*#' "$PR" > "$PR_C" || { echo "FATAL: 无法生成活代码副本"; exit 2; }
trap 'rm -f "$BS_C" "$PR_C"' EXIT INT TERM
R=0
ck() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 got=[$2] want=[$3]"; R=$((R+1)); fi; }
body() {
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\)[[:space:]]*\\{" { inside = 1 }
        inside { print }
        inside && /^}/ { exit }
    ' "$2"
}

echo "== 19.1 --verify-only 只验不写 =="
ck "R19.1a bootstrap 有 --verify-only 入口" \
   "$(grep -c '\-\-verify-only' "$BS_C")" "1"
ck "R19.1b _audit_all 遍历 DAG_NODES（不是硬编码清单）" \
   "$(body _audit_all "$BS_C" | grep -c 'for _n in \$DAG_NODES')" "1"
ck "R19.1c _audit_all 只调 verify_，一个 build_ 都不调" \
   "$(body _audit_all "$BS_C" | grep -c 'build_')" "0"
ck "R19.1d _audit_all 调的是 verify_\$_n" \
   "$(body _audit_all "$BS_C" | grep -c '"verify_\$_n"')" "1"
ck "R19.1e 有项不符时返回非 0（-eq 0 判断）" \
   "$(body _audit_all "$BS_C" | grep -c '\[ "\$_ab" -eq 0 \]')" "1"

echo "== 19.2 静态配置 sha 基线 =="
ck "R19.2a 有 sha 基线文件变量" \
   "$(grep -c '^CFG_SHA_FILE=' "$BS_C")" "1"
ck "R19.2b 覆盖的正是脚本自己写的四份文件" \
   "$(grep -A4 '^CFG_SHA_LIST=' "$BS_C" | grep -c 'etc/crowdsec/')" "4"
ck "R19.2c 用 sha256sum 算（不是只看文件在不在）" \
   "$(body _cfg_sha_now "$BS_C" | grep -c 'sha256sum' | awk '{print ($1>=1)?"1":"0"}')" "1"
ck "R19.2d 基线首行钉版本号（换版本则旧基线作废）" \
   "$(body _cfg_sha_write "$BS_C" | grep -c 'ver=%s')" "1"
ck "R19.2e 无基线 / 版本不符时不下结论（返回 0）" \
   "$(body verify_cfg_sha "$BS_C" | grep -c 'return 0')" "2"
ck "R19.2f 采集配置的 verify 里真的调了 sha 判据" \
   "$(body verify_sub_cs_acquis "$BS_C" | grep -c 'verify_cfg_sha')" "1"
ck "R19.2g 一轮跑通（stamp 落盘）时写基线" \
   "$(body _stamp_write "$BS_C" | grep -c '_cfg_sha_write')" "1"

echo "== 19.3 探针周期体检 =="
ck "R19.3a 有全量体检间隔（可用 CS_PROBE_AUDIT_EVERY 覆盖）" \
   "$(grep -c 'CS_PROBE_AUDIT_EVERY' "$PR_C")" "1"
ck "R19.3b tick 里按轮数取模触发" \
   "$(body probe_tick "$PR_C" | grep -c 'P_ROUND % PROBE_AUDIT_EVERY')" "1"
ck "R19.3c 体检跑的是 --verify-only（首检 + 复检共 2 次）" \
   "$(body probe_tick "$PR_C" | grep -c '_boot --verify-only')" "2"
ck "R19.3d 首检不符先问 ②：last_pull 此刻有效吗" \
   "$(body probe_tick "$PR_C" | grep -c '_boot --probe-check')" "3"
# 3 处 = ① 审计分支（首检不符时先问链路）② 主判定 ③ 【v.108.58】触发后复核退出码
# （bootstrap 退出 0 不代表 last_pull 修好了：bouncer_verify 是 SOFT 节点，不参与退出码）
ck "R19.3e last_pull 无效时不抢跑（交给停滞判定）" \
   "$(body probe_tick "$PR_C" | grep -c 'audit-wait-bouncer')" "1"
ck "R19.3f 两次都不符才重跑引导（修复只走一个入口）" \
   "$(body probe_tick "$PR_C" | grep -c '首检与复检都不符')" "1"
ck "R19.3g 复检通过则认定偶发、不动现场" \
   "$(body probe_tick "$PR_C" | grep -c '复检通过（偶发）')" "1"
ck "R19.3h 轮数与体检失败次数跨重启保留" \
   "$(body _probe_save "$PR_C" | grep -c 'round=%s audit_bad=%s')" "1"
ck "R19.3i 载入侧也解析这两个字段" \
   "$(body _probe_load "$PR_C" | grep -c 'round=\|audit_bad=')" "2"

echo "------------------------------------------------------------------"
echo "R19 RESULT: $R 项失败"
exit $R
