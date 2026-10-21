#!/bin/sh
# v.108.42 回归：cgroup 根必须落到 cgroup2，否则 dockerd 必然起不来
#
# 现场（2026-10-21，ImmortalWrt 24.10.6 x86_64）：
#   dockerd 反复报 `failed to start daemon: Devices cgroup isn't mounted`，
#   docker0 从不创建，LuCI「Docker → 网络」页因此全空。
#
# 因果链（三层，缺一条都推不出来）：
#   ① 内核 `# CONFIG_CGROUP_DEVICE is not set`：/proc/cgroups 只有 8 个控制器
#      （cpuset cpu cpuacct blkio memory net_cls pids rdma），没有 devices；
#      `mount -t cgroup -o devices none ...` 直接回 Unknown subsys name（rc=32）。
#   ② cgroupfs-mount 的 boot() 第一件事就是 umount procd 挂好的 cgroup2，
#      再按 /proc/cgroups 挂 v1 —— 官方脚本自己写着这份注释。
#   ③ dockerd 用 statfs("/sys/fs/cgroup") 判 v1/v2：根是 tmpfs → 走 v1 →
#      找 /sys/fs/cgroup/devices → 不存在 → 退出。
#
# 删掉 cgroupfs-mount 后 procd 的 cgroup2 保住，实测：
#   cgroup2 on /sys/fs/cgroup type cgroup2 (...)
#   cgroup.controllers = cpuset cpu io memory pids rdma
#   dockerd status = running，docker network ls 有 bridge/host/none
#   LXC 容器 ubuntu 仍 RUNNING、IP 10.1.0.10（LXC 6.0.5 原生支持 v2）
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
PKGS="$REPO/shell/custom-packages.sh"
APKS="$REPO/shell/apk-custom-packages.sh"
GUARD="$REPO/files/etc/init.d/cgroup2-guard"

R=0
ck() {
    if [ "$2" = "$3" ]; then
        echo "PASS: $1"
    else
        echo "FAIL: $1  got=[$2] want=[$3]"
        R=$((R + 1))
    fi
}

echo "== 30a 包列表：不能再装 cgroupfs-mount =="
ck "R30.1 custom-packages.sh 非注释行不含 cgroupfs-mount" \
   "$(grep -v '^[[:space:]]*#' "$PKGS" | grep -c 'cgroupfs-mount')" "0"
ck "R30.2 custom-packages.sh 仍保留 cgroup-tools" \
   "$(grep -v '^[[:space:]]*#' "$PKGS" | grep -c 'cgroup-tools')" "1"
ck "R30.3 apk-custom-packages.sh 也不含 cgroupfs-mount（两版一致）" \
   "$(grep -v '^[[:space:]]*#' "$APKS" | grep -c 'cgroupfs-mount')" "0"

echo "== 30b 兜底 init：cgroup2-guard =="
ck "R30.4 cgroup2-guard 存在" \
   "$([ -f "$GUARD" ] && echo 1 || echo 0)" "1"
ck "R30.5 shebang 是 /etc/rc.common（否则 rc.d 不会接管）" \
   "$(head -1 "$GUARD" | grep -c '^#!/bin/sh /etc/rc.common$')" "1"
ck "R30.6 START=02（必须排在 cgroupfs-mount 的 01 之后）" \
   "$(grep -c '^START=02$' "$GUARD")" "1"
ck "R30.7 真的去挂 cgroup2 到 /sys/fs/cgroup" \
   "$(grep -c 'mount -t cgroup2 none /sys/fs/cgroup' "$GUARD")" "1"
ck "R30.8 判据读 /proc/mounts，不依赖 mountpoint/stat（busybox 不保证有）" \
   "$(grep -v '^[[:space:]]*#' "$GUARD" | grep -c '/proc/mounts')" "1"
ck "R30.9 两条失败路径都 return 1，不许吞" \
   "$(grep -c '^[[:space:]]*return 1$' "$GUARD")" "2"
ck "R30.10 controllers 为空时必须告警（v1 占着控制器时 docker 可用但资源限制不可用）" \
   "$(grep -c 'controllers 为空' "$GUARD")" "1"
ck "R30.11 已在 cgroup2 上就直接跳过，不重复挂" \
   "$(grep -c 'cgroup2 已在 /sys/fs/cgroup，跳过' "$GUARD")" "1"

echo "== 30c 不许有第二个东西去挂 v1 =="
ck "R30.12 仓库脚本里没有任何非注释行调用 cgroupfs-mount" \
   "$(grep -rn --include='*.sh' 'cgroupfs-mount' "$REPO/shell" 2>/dev/null \
       | grep -vc ':[0-9]*:[[:space:]]*#')" "0"

[ "$R" = 0 ] && echo "ALL PASS" || echo "FAILED: $R"
exit "$R"
