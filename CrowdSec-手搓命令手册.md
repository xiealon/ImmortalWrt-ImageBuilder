# CrowdSec 手搓命令手册（ImmortalWrt 旁路由 + Ubuntu LXC 容器）

> 全部是可以直接复制粘贴执行的命令，按章节从上往下做即可。
> 已按这套流程端到端跑通：SSH 爆破 → 告警 → 封禁 → bouncer 实际丢包。
>
> **开始前先确认这 4 个值，全文照抄即可，若与你的环境不同请全局替换：**
>
> | 变量 | 本文取值 | 说明 |
> |---|---|---|
> | 路由器 LAN IP | `192.168.3.201` | 旁路由自身地址（SNAT 源、SSH 测试目标） |
> | 容器网段 | `10.0.0.0/24` | lxcbr0 网段 |
> | 网桥 IP | `10.0.0.1` | 容器的网关和 DNS |
> | 容器 IP | `10.0.0.233` | CrowdSec Agent 所在地址 |

约定：命令前标 `路由#` 的在路由器上执行，标 `容器#` 的在容器里执行（用 `lxc-attach` 进去）。

---

## 1. 路由器装包

```sh
# 路由#
opkg update
opkg install lxc lxc-common lxc-configs lxc-attach lxc-info lxc-start lxc-stop lxc-ls lxc-console
opkg install xz tar cgroupfs-mount kmod-veth
opkg install crowdsec-firewall-bouncer luci-app-crowdsec-firewall-bouncer
```

> 只装 bouncer，**不要**在路由器上装 `crowdsec` 主包（主程序跑在容器里，路由器上没有 `cscli`）。

## 2. 建 LXC 网络（网桥 + 接口 + DHCP + 防火墙 + SNAT）

```sh
# 路由# ---------- 网桥与接口 ----------
uci set network.lxcbr0=device
uci set network.lxcbr0.name='lxcbr0'
uci set network.lxcbr0.type='bridge'
uci set network.lxcbr0.bridge_empty='1'
uci set network.lxc=interface
uci set network.lxc.device='lxcbr0'
uci set network.lxc.proto='static'
uci set network.lxc.ipaddr='10.0.0.1'
uci set network.lxc.netmask='255.255.255.0'

# 路由# ---------- DHCP ----------
uci set dhcp.lxc=dhcp
uci set dhcp.lxc.interface='lxc'
uci set dhcp.lxc.start='100'
uci set dhcp.lxc.limit='150'
uci set dhcp.lxc.leasetime='1h'

# 路由# ---------- 防火墙区 ----------
uci set firewall.lxczone=zone
uci set firewall.lxczone.name='lxc'
uci set firewall.lxczone.network='lxc'
uci set firewall.lxczone.input='ACCEPT'
uci set firewall.lxczone.output='ACCEPT'
uci set firewall.lxczone.forward='ACCEPT'
uci set firewall.lxc2lan=forwarding
uci set firewall.lxc2lan.src='lxc'
uci set firewall.lxc2lan.dest='lan'
uci set firewall.lan2lxc=forwarding
uci set firewall.lan2lxc.src='lan'
uci set firewall.lan2lxc.dest='lxc'

# 路由# ---------- SNAT（src 必须是 lxc，写 lan 容器出不了网）----------
uci set firewall.lxcsnat=nat
uci set firewall.lxcsnat.name='lxc-snat'
uci add_list firewall.lxcsnat.proto='all'
uci set firewall.lxcsnat.src='lxc'
uci set firewall.lxcsnat.src_ip='10.0.0.0/24'
uci set firewall.lxcsnat.target='SNAT'
uci set firewall.lxcsnat.snat_ip='192.168.3.201'

uci commit
service network restart
service firewall restart
service dnsmasq restart
```

## 3. 创建 Ubuntu 容器

```sh
# 路由#
mkdir -p /srv/lxc/ubuntu/rootfs
cd /tmp
wget -O ubuntu-base.tar.gz https://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release/ubuntu-base-22.04.5-base-amd64.tar.gz
tar -xzf ubuntu-base.tar.gz -C /srv/lxc/ubuntu/rootfs

cat > /srv/lxc/ubuntu/config <<'EOF'
lxc.start.auto = 1
lxc.start.order = 10
lxc.arch = amd64
lxc.include = /usr/share/lxc/config/common.conf
lxc.rootfs.path = dir:/srv/lxc/ubuntu/rootfs
lxc.net.0.type = veth
lxc.net.0.link = lxcbr0
lxc.net.0.flags = up
lxc.net.0.hwaddr = 10:66:6A:7C:05:9A
lxc.tty.max = 4
lxc.pty.max = 1024
EOF

# 容器内静态 IP（不走 DHCP，IP 永不漂移）
mkdir -p /srv/lxc/ubuntu/rootfs/etc/systemd/network /srv/lxc/ubuntu/rootfs/etc/systemd/system/multi-user.target.wants
cat > /srv/lxc/ubuntu/rootfs/etc/systemd/network/10-eth0.network <<'EOF'
[Match]
Name=eth0

[Network]
Address=10.0.0.233/24
Gateway=10.0.0.1
DNS=10.0.0.1
EOF
ln -sf /lib/systemd/system/systemd-networkd.service /srv/lxc/ubuntu/rootfs/etc/systemd/system/multi-user.target.wants/systemd-networkd.service
echo "nameserver 10.0.0.1" > /srv/lxc/ubuntu/rootfs/etc/resolv.conf
echo "ubuntu" > /srv/lxc/ubuntu/rootfs/etc/hostname

lxc-start -P /srv/lxc -n ubuntu
ping -c2 10.0.0.233
```

> 容器必须放 `/srv/lxc`（OpenWrt 的 `/var` 是 tmpfs，放 `/var/lib/lxc` 重启就没了）。
> 若 `lxc-start` 报 veth 相关错误 → `opkg install kmod-veth` 后重试。

## 4. 容器里装 CrowdSec

```sh
# 路由# 进容器
lxc-attach -P /srv/lxc -n ubuntu

# 容器#
apt-get update
apt-get install -y curl ca-certificates gnupg
curl -fsSL https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash
apt-get install -y crowdsec

# LAPI 必须对外开放，否则路由器上的 bouncer 连不上
sed -i 's|listen_uri: 127.0.0.1:8080|listen_uri: 0.0.0.0:8080|' /etc/crowdsec/config.yaml
systemctl restart crowdsec
```

## 5. 配置日志源 / 解析器 / 白名单

```sh
# 容器# ---------- 收路由器 syslog ----------
mkdir -p /etc/crowdsec/acquis.d
cat > /etc/crowdsec/acquis.d/router.yaml <<'EOF'
source: syslog
listen_addr: 0.0.0.0
listen_port: 514
protocol: udp
labels:
  type: syslog
EOF

# 容器# ---------- dropbear 解析器（hub 自带的只认 PAM 文案，OpenWrt 是非 PAM）----------
mkdir -p /etc/crowdsec/parsers/s01-parse
cat > /etc/crowdsec/parsers/s01-parse/openwrt-dropbear.yaml <<'EOF'
name: openwrt/dropbear-logs
description: Parse OpenWrt non-PAM dropbear logs
filter: evt.Parsed.program == 'dropbear'
onsuccess: next_stage
nodes:
  - grok:
      pattern: "Bad password attempt for '?%{DATA:username}'? from %{IP:source_ip}:%{INT:source_port}"
      apply_on: message
    statics:
      - meta: log_type
        value: ssh_failed-auth
  - grok:
      pattern: "Login attempt for nonexistent user %{GREEDYDATA:username} from %{IP:source_ip}:%{INT:source_port}"
      apply_on: message
    statics:
      - meta: log_type
        value: ssh_failed-auth
  - grok:
      pattern: "Exit before auth from <%{IP:source_ip}:%{INT:source_port}>"
      apply_on: message
    statics:
      - meta: log_type
        value: ssh_failed-auth
  - grok:
      pattern: "Password auth succeeded for '?%{DATA:username}'? from %{IP:source_ip}:%{INT:source_port}"
      apply_on: message
    statics:
      - meta: log_type
        value: ssh_auth_success
  - grok:
      pattern: "Pubkey auth succeeded for '?%{DATA:username}'? with key %{DATA:key_type} from %{IP:source_ip}:%{INT:source_port}"
      apply_on: message
    statics:
      - meta: log_type
        value: ssh_auth_success
statics:
  - meta: service
    value: ssh
  - meta: source_ip
    expression: evt.Parsed.source_ip
  - meta: username
    expression: evt.Parsed.username
EOF

# 容器# ---------- 白名单（不需要就把 127.0.0.1 / 240.0.0.0/4 留着占位即可）----------
mkdir -p /etc/crowdsec/parsers/s02-enrich
cat > /etc/crowdsec/parsers/s02-enrich/openwrt-whitelist.yaml <<'EOF'
name: openwrt/my-whitelist
description: 'placeholder, nothing whitelisted'
whitelist:
  reason: placeholder
  ip:
    - 127.0.0.1
  cidr:
    - 240.0.0.0/4
EOF
```

```sh
# 容器# ---------- 关键：移除 hub 的私网白名单，否则局域网永不告警 ----------
cscli parsers remove crowdsecurity/whitelists --force

# 容器# ---------- 改完配置必须重启（daemon 读内存，explain 读磁盘）----------
systemctl restart crowdsec
```

## 6. 路由器把日志发过来 + 对接 bouncer

```sh
# 路由# ---------- 日志指向容器 ----------
uci set system.@system[0].log_ip='10.0.0.233'
uci set system.@system[0].log_port='514'
uci set system.@system[0].log_proto='udp'
uci commit system
service log restart

# 容器# ---------- 生成 bouncer 密钥（记下输出的那串）----------
cscli bouncers add openwrt-fw -o raw
```

```sh
# 路由# ---------- 把 key 写进 bouncer 配置（LuCI 里也能看到，不用手填）----------
# 注意：OpenWrt 的 bouncer 段是匿名段，必须用 @bouncer[n]，不能写 crowdsec.bouncer.xxx
SEC=$(uci show crowdsec | grep '=bouncer$' | head -n1 | cut -d= -f1)
uci set "$SEC.enabled=1"
uci set "$SEC.api_url=http://10.0.0.233:8080/"
uci set "$SEC.api_key=这里粘贴上一步生成的key"
uci set "$SEC.ipv4=1"
uci set "$SEC.ipv6=0"
uci set "$SEC.deny_action=drop"
uci set "$SEC.filter_input=1"
uci set "$SEC.filter_forward=1"
uci -q del "$SEC.interface"
uci add_list "$SEC.interface=br-lan"
uci commit crowdsec

service crowdsec-firewall-bouncer enable
service crowdsec-firewall-bouncer restart
```

## 7. 验证

```sh
# 容器#
cscli metrics            # syslog:10.0.0.1 有 reads = 日志链路通；poured to bucket > 0 = 进了场景桶
cscli bouncers list      # openwrt-fw 应为 Valid
cscli alerts list
cscli decisions list

# 路由#
nft list table ip crowdsec      # 应能看到 crowdsec-blacklists 集合
uci show crowdsec               # 确认 api_url / api_key 已写入
```

**端到端测试**：找一台**不在白名单**的电脑，连输错密码 12 次以上：

```sh
ssh -o PubkeyAuthentication=no root@192.168.3.201
```

然后容器里 `cscli alerts list` 应出现 `crowdsecurity/ssh-bf`，`cscli decisions list` 出现 ban 记录。

> 别用 ping 验证封禁——bouncer 只拦 TCP/UDP，ICMP 照样通。

## 8. 开机自启

```sh
# 路由#
cat > /etc/init.d/lxc-autostart <<'EOF'
#!/bin/sh /etc/rc.common
START=95
STOP=10
start() { lxc-start -P /srv/lxc -n ubuntu; }
stop()  { lxc-stop  -P /srv/lxc -n ubuntu; }
EOF
chmod +x /etc/init.d/lxc-autostart
/etc/init.d/lxc-autostart enable
```

容器内的 crowdsec 由 systemd 自己拉起来，不用管。

## 9. 常用维护命令

```sh
# 容器# 进容器
lxc-attach -P /srv/lxc -n ubuntu

# 容器#
cscli decisions list                      # 看当前封禁
cscli decisions delete --ip 192.168.3.41  # 解封某个 IP（误封自己时用这条）
cscli alerts list
cscli parsers list                        # 看解析器是否加载
cscli scenarios list                      # 确认 ssh-bf 场景存在
systemctl restart crowdsec                # 改配置后必做
systemctl status crowdsec

# 路由#
logread | grep dropbear                   # 看 SSH 登录日志
lxc-ls -P /srv/lxc --running              # 容器是否在跑
service crowdsec-firewall-bouncer restart
```

## 10. 排错速查

| 现象 | 原因 / 处理 |
|---|---|
| `cscli metrics` 里 syslog 无 reads | 路由器 `log_ip` 没指对 / `service log restart` 没执行 / 容器 IP 变了 |
| 日志到了但全 unparsed | 解析器没放对目录或没重启 crowdsec |
| `cscli explain` 结果正确但就是不告警 | daemon 跑着旧配置 → `systemctl restart crowdsec` |
| poured to bucket 一直是 0 | hub 的 `crowdsecurity/whitelists` 没移除（私网全被加白） |
| bouncer 不起 / LuCI 显示已配置但不生效 | uci 段名写错，要用 `crowdsec.@bouncer[0]` |
| 容器出不了网 | SNAT 的 `src` 写成了 `lan`，应为 `lxc` |
| 告警有了但没真封 | 看 `nft list table ip crowdsec` 有没有集合；bouncer 是否 `filter_input=1` |
| 路由器上 `cscli: not found` | 正常，cscli 只在容器里，先进容器 |
