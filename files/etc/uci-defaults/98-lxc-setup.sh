#!/bin/sh
# ============================================================
# 98-lxc-setup.sh —— 放进仓库 files/etc/uci-defaults/
# 作用：固件首次启动时自动配置 LXC 运行环境
#   - 挂载 cgroup2（procd 无 systemd，默认不挂，是 LXC 启动失败主因）
#   - 持久加载 veth/loop/macvlan 模块（仓库 config 里这些是 =m 需手动 modprobe）
#   - 写入 /etc/lxc/default.conf，网桥指向 br-lan
# 适配仓库：xiealon/ImmortalWrt-ImageBuilder (x86-64)
# ============================================================
# 仅当系统装了 lxc 才执行，否则跳过（本固件默认不带 LXC）
command -v lxc-start >/dev/null 2>&1 || exit 0

# 1) cgroup 挂载（开机 + 持久）
mkdir -p /sys/fs/cgroup
mountpoint -q /sys/fs/cgroup 2>/dev/null || \
  mount -t cgroup2 none /sys/fs/cgroup 2>/dev/null || \
  mount -t cgroup none /sys/fs/cgroup 2>/dev/null

cat > /etc/init.d/cgroup2 <<'EOF'
#!/bin/sh /etc/rc.common
START=10
boot() {
    mkdir -p /sys/fs/cgroup
    mountpoint -q /sys/fs/cgroup 2>/dev/null || mount -t cgroup2 none /sys/fs/cgroup 2>/dev/null || mount -t cgroup none /sys/fs/cgroup
}
EOF
chmod +x /etc/init.d/cgroup2
/etc/init.d/cgroup2 enable >/dev/null 2>&1

# 2) 模块开机自动加载（veth/loop 在仓库 .config 里是 =m，不写不会自动加载）
mkdir -p /etc/modules.d
for m in veth loop macvlan; do
  echo "$m" > /etc/modules.d/"$m" 2>/dev/null
done
modprobe veth 2>/dev/null
modprobe loop 2>/dev/null
modprobe macvlan 2>/dev/null

# 3) 默认容器配置：网桥指向本固件实际存在的 br-lan
#    并避开 v1 devices 语法（cgroup2 下 devices 控制器不存在）
mkdir -p /etc/lxc
cat > /etc/lxc/default.conf <<'CONF'
lxc.net.0.type = veth
lxc.net.0.link = br-lan
lxc.net.0.flags = up
lxc.apparmor.profile = unconfined
lxc.cgroup.devices.deny =
CONF

exit 0
