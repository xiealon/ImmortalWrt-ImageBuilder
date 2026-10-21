#!/usr/bin/env bash
# =============================================================================
# 极简 CrowdSec 容器 rootfs 构建（C 方案：不要发行版层）
#
# 与 prepare-crowdsec-rootfs.sh 的区别只有一个，但是根上的一个：
#   老脚本装的是「Ubuntu + systemd + crowdsec」，容器里 120MB 是发行版本身；
#   本脚本只放三样东西：静态 busybox（1.1MB，当 PID1 和所有工具）+ 静态 crowdsec
#   （约 224MB，Go 静态链接、已 strip）+ hub 内容（约 10-20MB）。
#   没有 libc、没有 dbus、没有 systemd、没有 apt、没有 rsyslog。
#
# 为什么能这么干（不是理论推演，是查过的事实）：
#   · crowdsec / cscli / notification-* 全是静态 ELF（无 .interp、无 DT_NEEDED），
#     所以不需要 rootfs 里有动态链接器和 libc；
#   · 宿主内核（ImmortalWrt imm25.config 的 CONFIG_KERNEL_*）NAMESPACES/CGROUPS/
#     SECCOMP/veth 都开着，容器只要能跑一个 PID1 就能起来，不依赖 systemd；
#   · 容器真正需要的能力只有三件：静态 IP、syslog 收日志、crowdsec 常驻。
#     这三件用 busybox init + 几个 20 行脚本就能给全，不需要 systemd 的 120MB。
#
# 产出契约（宿主侧引导脚本按这个认，改这里必须同步改 crowdsec-lxc-bootstrap.sh）：
#   /etc/inittab                  ::sysinit 跑 rcS，::respawn 看住 crowdsec
#   /etc/init.d/rcS               挂 proc/sys/devpts，起网络与 syslogd
#   /etc/init.d/crowdsec          start/stop/restart/status/run（run 供 inittab 用）
#   /etc/init.d/netconf           把 /etc/crowdsec-net.conf 套用到 eth0
#   /etc/init.d/syslogd           本地落盘 + 转发给本机 crowdsec 的 UDP 514
#   /etc/crowdsec-net.conf        ADDRESS=/GATEWAY=/DNS=（ct_net 节点写这份）
#   /etc/crowdsec/config.yaml     daemonize 必须是 false（前台跑，交给 supervise 看住）
#   /etc/crowdsec/acquis.d/       空目录，router 侧 setup_acquis 往里写 router.yaml
#   /sbin/init -> /bin/busybox    busybox init 当 PID1
#
# 环境变量：
#   CONTAINER_IP / BRIDGE_IP  写进 rootfs 的默认网络（运行期 ct_net 会按 UCI 重写）
#   COLLECTIONS               构建期装进 rootfs 的 collection（默认 linux + sshd）
#   OUT_DIR / OUT_NAME        产物位置（默认 files/etc/crowdsec/lxc-crowdsec.tar.gz）
#   MIN_MB                    产物体积下限（默认 40，低于此判为半截产物）
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 【v.108.45】容器内脚本的单一来源：rootfs-skel/ 既进 tarball（下面 install 进来），
# 也被 build24/25.sh 拷进固件 files/srv/lxc/ubuntu/rootfs/，供 crowdsec-guard 做只读基准。
# 为什么不能两处各写一遍：改了一处忘了另一处，guard 就会每分钟把旧版盖回去
# （和 v.108.44 那个 stat 事故同一形态：不是功能坏了，是判据永远对不上）。
SKEL="${SKEL:-$REPO_ROOT/rootfs-skel}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/files/etc/crowdsec}"
OUT_NAME="${OUT_NAME:-lxc-crowdsec.tar.gz}"
WORK="${WORK:-/tmp/lxc-crowdsec-minimal}"
R="$WORK/rootfs"

BUSYBOX_URL="${BUSYBOX_URL:-https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox}"
CA_URL="${CA_URL:-https://curl.se/ca/cacert.pem}"
CONTAINER_IP="${CONTAINER_IP:-10.1.0.10}"
BRIDGE_IP="${BRIDGE_IP:-10.1.0.1}"
COLLECTIONS="${COLLECTIONS:-crowdsecurity/linux crowdsecurity/sshd}"
MIN_MB="${MIN_MB:-40}"

say() { echo "==> $*"; }
die() { echo "!! $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. 前置检查：这套流程只在 Linux + root 下成立（chroot 要 root）
# ---------------------------------------------------------------------------
[ "$(id -u)" = "0" ] || die "需要 root（chroot 装 hub、写 /dev 节点）。用 sudo 跑本脚本"
[ "$(uname -m)" = "x86_64" ] || die "本脚本只产出 amd64 rootfs（当前 $(uname -m)）"
command -v dpkg-deb >/dev/null 2>&1 || die "缺 dpkg-deb（Debian/Ubuntu 宿主才有）"
command -v curl >/dev/null 2>&1 || die "缺 curl"

say "工作目录 $WORK / 产物 $OUT_DIR/$OUT_NAME"
rm -rf "$WORK"
mkdir -p "$R" "$OUT_DIR"

MOUNTS=""
cleanup() {
    # 卸载顺序必须由深到浅，否则 -l 卸载父挂载会让子挂载点悬空
    for m in $MOUNTS; do umount -l "$m" 2>/dev/null || true; done
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. 取静态 busybox：它就是容器里的 PID1 + shell + ip + ping + syslogd + logger
# ---------------------------------------------------------------------------
say "下载静态 busybox"
curl -fsSL --retry 3 --retry-delay 2 "$BUSYBOX_URL" -o "$WORK/busybox"
BB_SIZE=$(stat -c %s "$WORK/busybox")
[ "$BB_SIZE" -gt 900000 ] || die "busybox 只有 ${BB_SIZE} 字节，明显是半截下载"
# curl -o 建出来的文件是 0644，没有执行位 —— 直接跑会 "Permission denied"（不是 command not found）
chmod 0755 "$WORK/busybox"

# 校验它是静态 ELF，且带本方案依赖的 applet。两条不成立，整个方案的前提就没了。
if command -v readelf >/dev/null 2>&1; then
    if readelf -l "$WORK/busybox" 2>/dev/null | grep -q 'INTERP'; then
        die "busybox 是动态链接的，本方案要求静态版（换 musl 静态构建）"
    fi
fi
# 注意：裸执行 busybox 只会打印一段 usage，**不列 applet**（列 applet 要用 --list）。
# 上一版就是在这里写成了 `busybox | grep init`，必然判失败。
# 另外 /tmp 在某些 runner 上是 noexec，执行不了就退回「在二进制里找 applet 名」。
if "$WORK/busybox" --list > "$WORK/applets.txt" 2>/dev/null && [ -s "$WORK/applets.txt" ]; then
    for _a in init syslogd ip sh mount; do
        grep -qx "$_a" "$WORK/applets.txt" || die "该 busybox 未编入 $_a applet"
    done
    say "applet 校验通过（$(wc -l < "$WORK/applets.txt") 个 applet）"
else
    say "无法执行 busybox（$WORK 可能是 noexec），改用二进制内 applet 名做粗略校验"
    for _a in init syslogd ip; do
        grep -qa "$_a" "$WORK/busybox" || die "该 busybox 里找不到 $_a（不可用的构建）"
    done
fi

# ---------------------------------------------------------------------------
# 2. 取 crowdsec deb 并解包（不跑 postinst：postinst 里全是 systemd 动作）
# ---------------------------------------------------------------------------
say "添加 crowdsec 源并下载 deb"
curl -fsSL --retry 3 https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash
apt-get update -qq
( cd "$WORK" && apt-get download crowdsec ) >/dev/null 2>&1 \
    || die "apt-get download crowdsec 失败（packagecloud 源没配好或被限流）"
DEB="$(ls -1 "$WORK"/crowdsec_*.deb 2>/dev/null | head -n1)"
[ -n "$DEB" ] || die "没下到 crowdsec deb"
say "deb: $(basename "$DEB")（$(du -m "$DEB" | cut -f1)MB）"

say "解包 deb 到 rootfs"
dpkg-deb -x "$DEB" "$R"
[ -s "$R/usr/bin/crowdsec" ] || die "解包后没有 /usr/bin/crowdsec"
[ -s "$R/usr/bin/cscli" ] || die "解包后没有 /usr/bin/cscli"

# ---------------------------------------------------------------------------
# 3. 砍掉 notification 插件：6 个二进制约 105MB，路由器上没有任何通知出口
#    注意两件事：① 插件二进制在 usr/lib/crowdsec/plugins/，② 光删二进制不够，
#    还必须清掉 notifications/*.yaml，否则 crowdsec 启动时按 yaml 找插件、找不到就报错。
#    目录本身保留为空：config.yaml 里的 notification_dir / plugin_dir 路径仍然有效，
#    少一个「目录不存在」的潜在判定分支。
# ---------------------------------------------------------------------------
say "删除 notification 插件（约 105MB）"
rm -f "$R"/usr/lib/crowdsec/plugins/notification-* 2>/dev/null || true
mkdir -p "$R/usr/lib/crowdsec/plugins" "$R/etc/crowdsec/notifications"
rm -f "$R"/etc/crowdsec/notifications/*.yaml 2>/dev/null || true
# systemd 单元在极简 rootfs 里没有消费者，留着只会误导排查
rm -f "$R/lib/systemd/system/crowdsec.service" \
      "$R/usr/lib/systemd/system/crowdsec-hubupdate.service" \
      "$R/usr/lib/systemd/system/crowdsec-hubupdate.timer" 2>/dev/null || true
rmdir "$R/lib/systemd/system" "$R/lib/systemd" "$R/usr/lib/systemd/system" "$R/usr/lib/systemd" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 4. busybox 就位：/bin/busybox + applet 软链 + /sbin/init 指向它
# ---------------------------------------------------------------------------
say "安装 busybox 与 applet 软链"
# 顺序很关键（run #27 就死在这）：deb 只带 /usr/bin 与 /usr/lib，/bin、/sbin、/usr/sbin
# 根本不存在，而 install/ln 都不会替你造父目录 ——
# 先 install 后 mkdir 的写法会直接报
#   install: cannot create regular file '.../rootfs/bin/busybox': No such file or directory
mkdir -p "$R"/bin "$R"/sbin "$R"/usr/bin "$R"/usr/sbin "$R"/usr/lib "$R"/lib
install -m 0755 "$WORK/busybox" "$R/bin/busybox"
# --install -s 由 busybox 自己按 applet 表往 /bin /sbin /usr/bin /usr/sbin 铺软链，
# 比手写清单可靠：漏一个 applet 就是运行期一条「command not found」。
chroot "$R" /bin/busybox --install -s
[ -L "$R/bin/sh" ] || ln -sf busybox "$R/bin/sh"
# PID1 必须是 init 这个 applet 名，所以 /sbin/init 必须是 busybox 的软链
ln -sf ../bin/busybox "$R/sbin/init"
[ -e "$R/bin/sh" ] || die "busybox 软链没铺出来（/bin/sh 不存在）"

# ---------------------------------------------------------------------------
# 5. 目录骨架
# ---------------------------------------------------------------------------
say "创建目录骨架"
# /etc/init.d 必须在这里建：deb 的 payload 里没有它（上游用 systemd unit），
# 而脚本下面接连往 /etc/init.d/{netconf,syslogd,crowdsec,rcS} 写文件。
# run #28 就是漏了这一个目录，直接 `line 221: .../etc/init.d/netconf: No such file or directory`。
mkdir -p "$R"/{dev,proc,sys,run,tmp,root} \
         "$R/dev/pts" "$R/dev/shm" \
         "$R/var/log" "$R/var/lib/crowdsec/data" \
         "$R/etc/init.d" "$R/etc/profile.d" \
         "$R/etc/crowdsec/acquis.d" "$R/etc/crowdsec/notifications" \
         "$R/etc/ssl/certs"
chmod 1777 "$R/tmp"
chmod 0700 "$R/root"

# ---------------------------------------------------------------------------
# 6. CA 证书：crowdsec 要连 console/CAPI（https），Go 从 /etc/ssl/certs 找根证书
# ---------------------------------------------------------------------------
say "安装 CA 证书"
curl -fsSL --retry 3 "$CA_URL" -o "$R/etc/ssl/certs/ca-certificates.crt"
CA_SIZE=$(stat -c %s "$R/etc/ssl/certs/ca-certificates.crt")
[ "$CA_SIZE" -gt 100000 ] || die "CA bundle 只有 ${CA_SIZE} 字节，下载不完整"
grep -q 'BEGIN CERTIFICATE' "$R/etc/ssl/certs/ca-certificates.crt" || die "CA bundle 内容不对"

# ---------------------------------------------------------------------------
# 7. 系统身份文件（passwd/group 里必须有 nobody:nogroup —— config.yaml 的
#    plugin_config 指向它们；运行期 crowdsec 会解析这两个名字）
# ---------------------------------------------------------------------------
say "写 passwd/group/hosts/nsswitch/os-release"
install -m 0644 "$SKEL/etc/passwd" "$R/etc/passwd"
install -m 0644 "$SKEL/etc/group" "$R/etc/group"
cat > "$R/etc/hosts" <<EOF
127.0.0.1	localhost
$CONTAINER_IP	crowdsec
EOF
install -m 0644 "$SKEL/etc/nsswitch.conf" "$R/etc/nsswitch.conf"
# /etc/os-release：宿主引导脚本的 verify_rootfs 要求它有 ^ID= 行，别删
install -m 0644 "$SKEL/etc/os-release" "$R/etc/os-release"
echo crowdsec > "$R/etc/hostname"
cat > "$R/etc/resolv.conf" <<EOF
nameserver $BRIDGE_IP
EOF

# ---------------------------------------------------------------------------
# 8. 网络：默认配置 + 套用脚本
# ---------------------------------------------------------------------------
say "写容器网络配置与 netconf"
cat > "$R/etc/crowdsec-net.conf" <<EOF
ADDRESS=$CONTAINER_IP/24
GATEWAY=$BRIDGE_IP
DNS=$BRIDGE_IP
EOF
install -m 0755 "$SKEL/etc/init.d/netconf" "$R/etc/init.d/netconf"

# ---------------------------------------------------------------------------
# 9. syslogd：本地落盘 + 转发给本机 crowdsec 的 UDP 514
#    这一步是「日志链路」的关键：logger(1) 写 /dev/log → syslogd 收 → 一路进
#    /var/log/messages（排障用），一路转发到 127.0.0.1:514（crowdsec 的 syslog 源）。
#    老 Ubuntu 镜像上这条链路其实是断的（journald 收 /dev/log，crowdsec 听 UDP），
#    宿主侧 verify_log_pipeline 因此长期是「假绿」。
# ---------------------------------------------------------------------------
say "写 syslogd 启动脚本"
install -m 0755 "$SKEL/etc/init.d/syslogd" "$R/etc/init.d/syslogd"

# ---------------------------------------------------------------------------
# 10. crowdsec 看护：supervise 循环 + init.d 控制脚本
#     daemonize=false 后 crowdsec 是前台的，所以必须有人「等它死、再拉起来」。
#     busybox init 的 ::respawn 只会在 supervise 整个进程退出时重启它，
#     crowdsec 内部崩溃由 supervise 自己的退避循环兜住 —— 双层，且不会 fork 风暴。
# ---------------------------------------------------------------------------
say "写 crowdsec 看护脚本"
install -m 0755 "$SKEL/usr/sbin/crowdsec-supervise" "$R/usr/sbin/crowdsec-supervise"

install -m 0755 "$SKEL/etc/init.d/crowdsec" "$R/etc/init.d/crowdsec"

# ---------------------------------------------------------------------------
# 11. rcS / inittab：容器开机流程
# ---------------------------------------------------------------------------
say "写 rcS 与 inittab"
install -m 0755 "$SKEL/etc/init.d/rcS" "$R/etc/init.d/rcS"

install -m 0644 "$SKEL/etc/inittab" "$R/etc/inittab"

chmod +x "$R/etc/init.d/rcS" "$R/etc/init.d/crowdsec" "$R/etc/init.d/netconf" \
         "$R/etc/init.d/syslogd" "$R/usr/sbin/crowdsec-supervise"

# ---------------------------------------------------------------------------
# 12. crowdsec 配置调整
# ---------------------------------------------------------------------------
say "调整 crowdsec 配置"
CFG="$R/etc/crowdsec/config.yaml"
[ -s "$CFG" ] || die "缺 $CFG"

# ① daemonize 必须改 false：true 时 crowdsec 会 fork 到后台、父进程秒退，
#    supervise 的 wait 立刻返回 → 每 5 秒重拉一次的假循环，同时留下孤儿进程。
sed -i 's/^\([[:space:]]*daemonize:[[:space:]]*\)true[[:space:]]*$/\1false/' "$CFG"
grep -qE '^[[:space:]]*daemonize:[[:space:]]*false' "$CFG" \
    || die "config.yaml 的 daemonize 没改成功（上游配置格式变了？）"

# ② acquis.yaml：deb 不带这个文件，但 config 的 acquisition_path 指着它。
#    写一个「存在且合法」的占位源（空文件读不了，指向不存在的文件会告警），
#    真正的采集源由 router 侧 setup_acquis 写进 acquis.d/router.yaml。
install -m 0644 "$SKEL/etc/crowdsec/acquis.yaml" "$R/etc/crowdsec/acquis.yaml"
: > "$R/var/log/router.log"

# ---------------------------------------------------------------------------
# 13. chroot 内完成 postinst 该做但没做的事
#     dpkg-deb -x 不跑 postinst，而 postinst 里有 4 件事是运行期必须的：
#    machines add（生成 local_api_credentials.yaml）、hub update、装 collection、
#    配置自检。这里逐条补上，任何一条失败都直接中止构建。
# ---------------------------------------------------------------------------
say "chroot 装 hub 与本地机器凭证（约 1-3 分钟）"
cp /etc/resolv.conf "$R/etc/resolv.conf"

# 两个凭证文件必须先建成「空文件」，这是 deb 的 postinst 做的第一件事：
#     install -m 600 /dev/null /etc/crowdsec/local_api_credentials.yaml
#     install -m 600 /dev/null /etc/crowdsec/online_api_credentials.yaml
# 原因：cscli 启动时会同时加载 local（本机 LAPI）与 online（CAPI）两个客户端，
# 「文件不存在」是硬错误，「文件为空」才被容忍。我们走的是 dpkg-deb -x，
# postinst 一步都没跑，所以这行得自己补 —— run #29 就是死在这里：
#     Error: cscli machines add: failed to load Local API: loading online client
#     credentials: open /etc/crowdsec/online_api_credentials.yaml: no such file or directory
# 极简版只跑本地 LAPI，online 那份永远留空（不注册 CAPI，占位即可）。
for _f in local_api_credentials.yaml online_api_credentials.yaml; do
    [ -f "$R/etc/crowdsec/$_f" ] || install -m 600 /dev/null "$R/etc/crowdsec/$_f"
done

for m in proc sys dev dev/pts; do
    mkdir -p "$R/$m"
    mount --bind "/$m" "$R/$m"
    MOUNTS="$R/$m $MOUNTS"
done

if ! chroot "$R" /bin/sh -c "
set -e
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root
export LC_ALL=C
mkdir -p /var/lib/crowdsec/data /var/log /run
/usr/bin/cscli hub update
/usr/bin/cscli hub upgrade
/usr/bin/cscli machines add -a --force --error
for c in $COLLECTIONS; do
    /usr/bin/cscli collections install \"\$c\"
done
/usr/bin/crowdsec -c /etc/crowdsec/config.yaml -t -error
"; then
    die "chroot 内的 hub/凭证初始化失败（看上面输出）"
fi

chroot "$R" /bin/sh -c 'ls -1 /etc/crowdsec/hub >/dev/null 2>&1 && echo hub_entries=$(ls -1 /etc/crowdsec/hub | wc -l)'

# chroot 期间用的是 CI 宿主机的 DNS（要连 github 拉 hub），构建完必须换回容器该有的那份：
# 容器里 10.1.0.1 是路由器网桥，DNS 由路由器 dnsmasq 提供；带着 GitHub Runner 的
# resolv.conf 出厂，容器启动初期就会解析失败（ct_resolv 节点会改，但首启窗口内的
# enroll 会白跑一轮）。
cat > "$R/etc/resolv.conf" <<EOF
nameserver $BRIDGE_IP
EOF
chmod 644 "$R/etc/resolv.conf"

# ---------------------------------------------------------------------------
# 14. 产物自检：内容必须齐、daemonize 必须 false、体积不能是半截
# ---------------------------------------------------------------------------
say "产物自检"
for f in etc/inittab etc/init.d/rcS etc/init.d/crowdsec etc/init.d/netconf \
         etc/init.d/syslogd usr/sbin/crowdsec-supervise etc/crowdsec-net.conf \
         etc/crowdsec/config.yaml etc/crowdsec/acquis.d usr/bin/crowdsec usr/bin/cscli \
         etc/os-release etc/ssl/certs/ca-certificates.crt bin/busybox sbin/init; do
    [ -e "$R/$f" ] || die "自检失败：rootfs 缺 /$f"
done
grep -qE '^[[:space:]]*daemonize:[[:space:]]*false' "$R/etc/crowdsec/config.yaml" \
    || die "自检失败：daemonize 不是 false"
[ -s "$R/etc/crowdsec/local_api_credentials.yaml" ] || die "自检失败：缺 local_api_credentials.yaml（LAPI 密码没生成）"
if [ -d "$R/etc/crowdsec/hub" ] && [ -z "$(ls -A "$R/etc/crowdsec/hub" 2>/dev/null)" ]; then
    die "自检失败：hub 是空的（collections install 没生效，容器里不会有任何规则）"
fi
# 反向自检：notification 插件必须真的没了（不然白砍 105MB）
if [ -n "$(ls -A "$R/usr/lib/crowdsec/plugins" 2>/dev/null)" ]; then
    die "自检失败：plugins 目录还有东西，通知插件没删干净"
fi
if ls "$R"/etc/crowdsec/notifications/*.yaml >/dev/null 2>&1; then
    die "自检失败：notifications/*.yaml 还在，crowdsec 启动会去找不存在的插件"
fi

# ---------------------------------------------------------------------------
# 15. 打包（解开 chroot 挂载点后再打，避免把宿主 /proc /sys /dev 打进去）
# ---------------------------------------------------------------------------
say "卸载 chroot 挂载点"
for m in $MOUNTS; do umount -l "$m" 2>/dev/null || true; done
MOUNTS=""
LEFT=""
for d in dev/pts dev sys proc; do
    mountpoint -q "$R/$d" 2>/dev/null && LEFT="$LEFT $d"
done
[ -z "$LEFT" ] || die "以下挂载点仍未卸载:$LEFT"

say "打包 rootfs"
OUT_FILE="$OUT_DIR/$OUT_NAME"
# --owner/--group 归一到 0：dpkg-deb 解出来的个别条目可能带非 root 属主，
# 容器里 65534 属主是个隐患（plugin_config 指向 nobody），统一成 root 最安全。
tar --one-file-system --numeric-owner --owner=0 --group=0 \
    --exclude='./proc/*' --exclude='./sys/*' --exclude='./dev/*' \
    --exclude='./run/*'  --exclude='./tmp/*' \
    -czf "$OUT_FILE" -C "$R" . || die "tar 打包失败"
[ -f "$OUT_FILE" ] || die "产物不存在"

# 列表只解一次：后面 7 条断言都查同一份清单（每次都 tar -tzf 就是解压 7 遍 90MB）
tar -tzf "$OUT_FILE" > "$WORK/toc.txt" || die "包不可读（tar -tzf 失败）"
if grep -qE '^\./(proc|sys|dev)/.' "$WORK/toc.txt"; then
    die "包里混进了虚拟文件系统内容（$OUT_FILE 丢弃）"
fi
for f in ./etc/inittab ./etc/init.d/crowdsec ./etc/init.d/rcS ./sbin/init \
         ./usr/bin/crowdsec ./usr/bin/cscli ./etc/crowdsec/config.yaml; do
    grep -qx -- "$f" "$WORK/toc.txt" || die "包内缺 $f（打包路径有误）"
done
SIZE=$(stat -c %s "$OUT_FILE")
if [ "$SIZE" -lt $(( MIN_MB * 1024 * 1024 )) ]; then
    die "产物仅 ${SIZE} 字节（<${MIN_MB}MB），明显不完整"
fi

# 构建在 sudo 下跑，产物要还给调用者，否则后续 docker build 拿不到
[ -n "${SUDO_UID:-}" ] && chown "$SUDO_UID:$SUDO_GID" "$OUT_FILE" 2>/dev/null || true

say "完成：$OUT_FILE"
ls -lh "$OUT_FILE"
say "rootfs 解压后体积（估算）：$(du -sh "$R" | cut -f1)"
say "对照：老脚本产物 lxc-ubuntu.tar.gz 是 Ubuntu+systemd+同一份 crowdsec"
