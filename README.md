# CrowdSec 部署步骤速览（8 步）

> 每步只给**主干命令**。想看每条的完整版和原理，看同目录的 `CrowdSec-手搓命令手册.md`。
>
> 环境取值：路由器 `10.1.1.201`、网桥 `10.0.0.1`、容器 `10.0.0.10`（网段 `10.0.0.0/24`）。与你的不符就全局替换。
> `路由#` = 路由器上执行，`容器#` = 容器里执行。

---

## 第 1 步 · 路由器装软件 ✅
**干什么**：装 LXC 工具链（跑容器用）和 bouncer（执行封禁用）。**不装** crowdsec 主包，主程序放容器里。

```sh
# 路由#
opkg update
opkg install lxc lxc-common lxc-configs lxc-attach lxc-info lxc-start lxc-stop lxc-ls lxc-console
opkg install xz tar kmod-veth crowdsec-firewall-bouncer luci-app-crowdsec-firewall-bouncer
```

## 第 2 步 · 建 LXC 网络 ✅
**干什么**：建网桥 `lxcbr0` 给容器用，配上 DHCP、防火墙区，再做 SNAT 让容器能出网。

```sh
# 路由#
uci set network.lxcbr0=device
uci set network.lxcbr0.name='lxcbr0'
uci set network.lxcbr0.type='bridge'
uci set network.lxcbr0.bridge_empty='1'
uci set network.lxc=interface
uci set network.lxc.device='lxcbr0'
uci set network.lxc.proto='static'
uci set network.lxc.ipaddr='10.0.0.1'
uci set network.lxc.netmask='255.255.255.0'

uci set dhcp.lxc=dhcp
uci set dhcp.lxc.interface='lxc'
uci set dhcp.lxc.start='100'
uci set dhcp.lxc.limit='150'
uci set dhcp.lxc.leasetime='1h'

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

# SNAT：src 按新写法填出接口侧 lan；若容器出网不通再改成 'lxc' 试
uci set firewall.lxcsnat=nat
uci set firewall.lxcsnat.name='lxc-snat'
uci add_list firewall.lxcsnat.proto='all'
uci set firewall.lxcsnat.src='lan'
uci set firewall.lxcsnat.src_ip='10.0.0.0/24'
uci set firewall.lxcsnat.target='SNAT'
uci set firewall.lxcsnat.snat_ip='10.1.1.201'

uci commit
service network restart; service firewall restart; service dnsmasq restart
```

## 第 3 步 · 建 Ubuntu 容器
**干什么**：解压 Ubuntu rootfs 建容器，给它固定 IP（写在容器 OS 里，不走 DHCP，IP 永不漂移），然后启动。

```sh
# 路由#
mkdir -p /srv/lxc/ubuntu/rootfs
wget -O /tmp/ubuntu-base.tar.gz https://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release/ubuntu-base-22.04.5-base-amd64.tar.gz
tar -xzf /tmp/ubuntu-base.tar.gz -C /srv/lxc/ubuntu/rootfs

cat > /srv/lxc/ubuntu/config <<'EOF'
lxc.start.auto = 1
lxc.arch = amd64
lxc.include = /usr/share/lxc/config/common.conf
lxc.rootfs.path = dir:/srv/lxc/ubuntu/rootfs
lxc.net.0.type = veth
lxc.net.0.link = lxcbr0
lxc.net.0.flags = up
lxc.net.0.hwaddr = 10:66:6A:7C:05:9A
EOF

mkdir -p /srv/lxc/ubuntu/rootfs/etc/systemd/network /srv/lxc/ubuntu/rootfs/etc/systemd/system/multi-user.target.wants
cat > /srv/lxc/ubuntu/rootfs/etc/systemd/network/10-eth0.network <<'EOF'
[Match]
Name=eth0
[Network]
Address=10.0.0.10/24
Gateway=10.0.0.1
DNS=10.0.0.1
EOF
ln -sf /lib/systemd/system/systemd-networkd.service /srv/lxc/ubuntu/rootfs/etc/systemd/system/multi-user.target.wants/systemd-networkd.service
echo "nameserver 10.0.0.1" > /srv/lxc/ubuntu/rootfs/etc/resolv.conf

lxc-start -P /srv/lxc -n ubuntu
ping -c2 10.0.0.10
```

> 容器放 `/srv/lxc`，别放 `/var/lib/lxc`（OpenWrt 的 /var 是内存盘，重启就丢）。

## 第 4 步 · 容器里装 CrowdSec
**干什么**：装 Agent（负责看日志、做判断），并把它的 API 端口对外开放，否则路由器的 bouncer 连不上。

```sh
# 路由# 进容器
lxc-attach -P /srv/lxc -n ubuntu

# 容器#
apt-get update && apt-get install -y curl ca-certificates gnupg
curl -fsSL https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash
apt-get install -y crowdsec
sed -i 's|listen_uri: 127.0.0.1:8080|listen_uri: 0.0.0.0:8080|' /etc/crowdsec/config.yaml
systemctl restart crowdsec
```

## 第 5 步 · 喂配置：日志源 + 解析器 + 白名单
> 这一步另拆了两个独立文件，方便整段复制：`CrowdSec-第5步-配置-heredoc.md`（可读版）和 `CrowdSec-第5步-配置-base64.md`（防丢缩进版，推荐）。内容与本步完全相同，二选一即可。
**干什么**：告诉 CrowdSec 去 UDP 514 收路由器的日志；给它一条能看懂 OpenWrt dropbear 日志的解析器（hub 自带的只认 PAM 版，匹配不上）；再删掉 hub 那条把私网全加白的规则，否则局域网永远不告警。

```sh
# 容器#
cat > /etc/crowdsec/acquis.d/router.yaml <<'EOF'
source: syslog
listen_addr: 0.0.0.0
listen_port: 514
protocol: udp
labels:
  type: syslog
EOF

mkdir -p /etc/crowdsec/parsers/s01-parse /etc/crowdsec/parsers/s02-enrich

# 用 base64 单行写入（从网页复制 heredoc 会丢行首空格，YAML 缩进一乱规则就失效）
echo 'bmFtZTogb3BlbndydC9kcm9wYmVhci1sb2dzCmRlc2NyaXB0aW9uOiBQYXJzZSBPcGVuV3J0IG5vbi1QQU0gZHJvcGJlYXIgbG9ncwpmaWx0ZXI6IGV2dC5QYXJzZWQucHJvZ3JhbSA9PSAnZHJvcGJlYXInCm9uc3VjY2VzczogbmV4dF9zdGFnZQpub2RlczoKICAtIGdyb2s6CiAgICAgIHBhdHRlcm46ICJCYWQgcGFzc3dvcmQgYXR0ZW1wdCBmb3IgJz8le0RBVEE6dXNlcm5hbWV9Jz8gZnJvbSAle0lQOnNvdXJjZV9pcH06JXtJTlQ6c291cmNlX3BvcnR9IgogICAgICBhcHBseV9vbjogbWVzc2FnZQogICAgc3RhdGljczoKICAgICAgLSBtZXRhOiBsb2dfdHlwZQogICAgICAgIHZhbHVlOiBzc2hfZmFpbGVkLWF1dGgKICAtIGdyb2s6CiAgICAgIHBhdHRlcm46ICJMb2dpbiBhdHRlbXB0IGZvciBub25leGlzdGVudCB1c2VyICV7R1JFRURZREFUQTp1c2VybmFtZX0gZnJvbSAle0lQOnNvdXJjZV9pcH06JXtJTlQ6c291cmNlX3BvcnR9IgogICAgICBhcHBseV9vbjogbWVzc2FnZQogICAgc3RhdGljczoKICAgICAgLSBtZXRhOiBsb2dfdHlwZQogICAgICAgIHZhbHVlOiBzc2hfZmFpbGVkLWF1dGgKICAtIGdyb2s6CiAgICAgIHBhdHRlcm46ICJFeGl0IGJlZm9yZSBhdXRoIGZyb20gPCV7SVA6c291cmNlX2lwfTole0lOVDpzb3VyY2VfcG9ydH0+IgogICAgICBhcHBseV9vbjogbWVzc2FnZQogICAgc3RhdGljczoKICAgICAgLSBtZXRhOiBsb2dfdHlwZQogICAgICAgIHZhbHVlOiBzc2hfZmFpbGVkLWF1dGgKICAtIGdyb2s6CiAgICAgIHBhdHRlcm46ICJQYXNzd29yZCBhdXRoIHN1Y2NlZWRlZCBmb3IgJz8le0RBVEE6dXNlcm5hbWV9Jz8gZnJvbSAle0lQOnNvdXJjZV9pcH06JXtJTlQ6c291cmNlX3BvcnR9IgogICAgICBhcHBseV9vbjogbWVzc2FnZQogICAgc3RhdGljczoKICAgICAgLSBtZXRhOiBsb2dfdHlwZQogICAgICAgIHZhbHVlOiBzc2hfYXV0aF9zdWNjZXNzCiAgLSBncm9rOgogICAgICBwYXR0ZXJuOiAiUHVia2V5IGF1dGggc3VjY2VlZGVkIGZvciAnPyV7REFUQTp1c2VybmFtZX0nPyB3aXRoIGtleSAle0RBVEE6a2V5X3R5cGV9IGZyb20gJXtJUDpzb3VyY2VfaXB9OiV7SU5UOnNvdXJjZV9wb3J0fSIKICAgICAgYXBwbHlfb246IG1lc3NhZ2UKICAgIHN0YXRpY3M6CiAgICAgIC0gbWV0YTogbG9nX3R5cGUKICAgICAgICB2YWx1ZTogc3NoX2F1dGhfc3VjY2VzcwpzdGF0aWNzOgogIC0gbWV0YTogc2VydmljZQogICAgdmFsdWU6IHNzaAogIC0gbWV0YTogc291cmNlX2lwCiAgICBleHByZXNzaW9uOiBldnQuUGFyc2VkLnNvdXJjZV9pcAogIC0gbWV0YTogdXNlcm5hbWUKICAgIGV4cHJlc3Npb246IGV2dC5QYXJzZWQudXNlcm5hbWUK' | base64 -d > /etc/crowdsec/parsers/s01-parse/openwrt-dropbear.yaml

echo 'IyDkvZznlKjvvJpzMDItZW5yaWNoIOmYtuauteeahOiHquWumuS5ieeZveWQjeWNleino+aekOWZqOOAggojIOWmguaenOS9oOOAjOS4jemcgOimgeS7u+S9leeZveWQjeWNleOAje+8jOS/neaMgeS4i+mdoui/meS4quWNoOS9jeWGmeazleWNs+WPr++8iDEyNy4wLjAuMSDmmK/mnKzmnLrlm57njq/vvIwKIyDmsLjov5zkuI3kvJrmiJDkuLrml6Xlv5fph4znmoQgc291cmNlX2lw77yM562J5LqO5LiA5p2h5LiN55Sf5pWI55qE6KeE5YiZ77yJ77yM5LiN6KaB5YaZ5oiQ56m65YiX6KGo5oiW5Yig5o6JCiMgaXAvY2lkciDlrZfmrrXigJTigJRDcm93ZFNlYyDliqDovb3ml7blr7nlrZfmrrXnvLrlpLHnmoTlrrnlv43luqbkuI3lpoLljaDkvY3lgLznqLPjgIIKIwojIOaDs+W9u+W6leWOu+aOiei/meS4quaWh+S7tu+8muebtOaOpeWIoOmZpOWug+WNs+WPr++8jGJvb3RzdHJhcCDohJrmnKzlt7LlgZrlrZjlnKjmgKfliKTmlq3vvIzkuI3kvJrmiqXplJnjgIIKbmFtZTogb3BlbndydC9teS13aGl0ZWxpc3QKZGVzY3JpcHRpb246ICdObyB3aGl0ZWxpc3QgY29uZmlndXJlZCAtIHBsYWNlaG9sZGVyIG9ubHknCndoaXRlbGlzdDoKICByZWFzb246IHBsYWNlaG9sZGVyLCBub3RoaW5nIGlzIHdoaXRlbGlzdGVkCiAgaXA6CiAgICAtIDEyNy4wLjAuMQogIGNpZHI6CiAgICAtIDI0MC4wLjAuMC80Cg==' | base64 -d > /etc/crowdsec/parsers/s02-enrich/openwrt-whitelist.yaml

# 验证：必须输出 3，少一条说明文件写坏了
grep -c 'value: ssh_failed-auth' /etc/crowdsec/parsers/s01-parse/openwrt-dropbear.yaml

cscli parsers remove crowdsecurity/whitelists --force
systemctl restart crowdsec
```

## 第 6 步 · 路由器把日志发过来
**干什么**：把路由器的系统日志（含 dropbear 的登录记录）通过 UDP 514 发到容器，这是整个检测链路的数据源头。

```sh
# 路由#
uci set system.@system[0].log_ip='10.0.0.10'
uci set system.@system[0].log_port='514'
uci set system.@system[0].log_proto='udp'
uci commit system
service log restart
```

## 第 7 步 · 对接 bouncer（生成密钥并自动填进插件）
**干什么**：在容器里注册一个 bouncer 拿到密钥，写进路由器的 `/etc/config/crowdsec`，bouncer 就能定时来拉封禁名单并写进 nftables。**LuCI 里不用手填**。

```sh
# 容器# 生成密钥，把输出的那串记下来
cscli bouncers add openwrt-fw -o raw
```

```sh
# 路由# 写进配置（bouncer 段是匿名段，必须用 @bouncer[n]）
SEC=$(uci show crowdsec | grep '=bouncer$' | head -n1 | cut -d= -f1)
uci set "$SEC.enabled=1"
uci set "$SEC.api_url=http://10.0.0.10:8080/"
uci set "$SEC.api_key=粘贴上一步的key"
uci set "$SEC.ipv4=1"; uci set "$SEC.ipv6=0"
uci set "$SEC.filter_input=1"; uci set "$SEC.filter_forward=1"
uci -q del "$SEC.interface"; uci add_list "$SEC.interface=br-lan"
uci commit crowdsec

service crowdsec-firewall-bouncer enable
service crowdsec-firewall-bouncer restart
```

## 第 8 步 · 验证
**干什么**：确认日志进来了、密钥有效、真能封禁。

```sh
# 容器#
cscli metrics            # syslog:10.0.0.1 有 reads = 日志到了
cscli bouncers list      # openwrt-fw 显示 Valid

# 路由#
nft list table ip crowdsec
```

**实测**：拿一台不在白名单的电脑 `ssh -o PubkeyAuthentication=no root@10.1.1.201` 连输错密码 12 次 →
容器里 `cscli alerts list` 出现 `crowdsecurity/ssh-bf`，`cscli decisions list` 出现 ban。

> 别用 ping 验证，bouncer 只拦 TCP/UDP，ICMP 照样通。

---

## 常用维护

```sh
lxc-attach -P /srv/lxc -n ubuntu              # 路由# 进容器
cscli decisions list                          # 容器# 看封禁
cscli decisions delete --ip 10.1.1.41      # 容器# 解封（误封自己用这条）
systemctl restart crowdsec                    # 容器# 改配置后必做
lxc-ls -P /srv/lxc --running                  # 路由# 容器在不在跑
```

## 排错速查

| 现象 | 原因 |
|---|---|
| metrics 里 syslog 无 reads | 路由器 log_ip 没指对 / 没 `service log restart` / 容器 IP 变了 |
| 日志到了但全 unparsed | 解析器没放对目录，或没重启 crowdsec |
| explain 正确就是不告警 | daemon 跑旧配置 → `systemctl restart crowdsec` |
| poured to bucket 恒为 0 | hub 的 `crowdsecurity/whitelists` 没删 |
| LuCI 显示已配置但不生效 | uci 段名写错，要用 `crowdsec.@bouncer[0]` |
| 容器出不了网 | SNAT 的 `src` 要填**出接口侧** `lan`（新写法），写成 `lxc` 才不通 |
| 路由器上 `cscli: not found` | 正常，cscli 只在容器里 |
