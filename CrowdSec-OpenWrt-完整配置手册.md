# ImmortalWrt 旁路由 LXC 容器 CrowdSec SSH 爆破防护 — 完整配置手册

> 环境说明：
> - ImmortalWrt（OpenWrt 系）旁路由，LAN IP `192.168.3.201`，主路由 `192.168.3.1`
> - LXC 容器：Ubuntu 22.04（jammy），CrowdSec v1.8.1
> - 路由器 SSH 服务为 **dropbear**（非 sshd，非 PAM 编译）
>
> 架构：
> ```
> 路由器(dropbear日志) --UDP 514--> Ubuntu容器(CrowdSec Agent解析+检测)
>                                        |
> 路由器(bouncer) <---HTTP 8080 拉取封禁名单--- LAPI
>                                        |
> 路由器防火墙(nftables) <-- 实际拦截攻击IP
> ```

---

## 第一部分：容器内安装 CrowdSec

> 进入容器：在路由器上执行 `lxc-attach -n ubuntu`

### 1.1 安装

```sh
apt update && apt install -y curl
```
- `apt update`：刷新软件源索引
- `apt install -y curl`：安装 curl 下载工具（`-y` 表示自动确认）

```sh
curl -fsSL https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash
```
- 运行 CrowdSec 官方的 Debian/Ubuntu 仓库配置脚本，添加 packagecloud 的 apt 源并导入 GPG 密钥
- `-f` 失败即停、`-s` 静默进度、`-S` 显示错误、`-L` 跟随重定向；`| bash` 表示把脚本内容交给 bash 执行
- 注意：GitHub 直连和 gh-proxy 镜像都可能失败（HTTP2 framing 错误 / 返回错误页），packagecloud CDN 直连最稳

```sh
apt install -y crowdsec
```
- 从刚添加的源安装 CrowdSec 主程序（含 agent + cscli + LAPI）
- 安装脚本会自动：注册 systemd 服务、注册本机机器凭据、下载 hub 规则集（含 sshd 系列场景）

### 1.2 配置接收路由器日志（UDP 514）

```sh
cat > /etc/crowdsec/acquis.d/router.yaml <<'EOF'
source: syslog
listen_addr: 0.0.0.0
listen_port: 514
protocol: udp
labels:
  type: syslog
EOF
```
- `cat > 文件 <<'EOF' ... EOF`：heredoc 写文件方式，内容原样写入直到单独一行 `EOF`
- **`<<'EOF'` 的单引号必须带**，否则 `$`、`\` 会被 shell 解释导致内容变形
- 各行含义：
  - `source: syslog`：数据源类型为 syslog 服务器（写成 `udp` 会报 unknown data source）
  - `listen_addr: 0.0.0.0`：监听所有网卡（否则收不到外部日志）
  - `listen_port: 514`：标准 syslog 端口
  - `protocol: udp`：与路由器 syslogd 的发送方式一致
  - `labels.type: syslog`：给数据打标签，s00-raw 阶段的 syslog-logs 解析器依赖它

### 1.3 开放 LAPI 给 bouncer

```sh
sed -i 's|listen_uri: 127.0.0.1:8080|listen_uri: 0.0.0.0:8080|' /etc/crowdsec/config.yaml
```
- `sed -i`：直接修改文件（in-place）
- 把 LAPI 监听地址从 `127.0.0.1`（仅容器本机）改成 `0.0.0.0`（所有网卡）——路由器上的 bouncer 需要跨容器连接这个 API，不改会被拒绝连接

---

## 第二部分：自定义 dropbear 解析器（核心）

### 2.1 为什么必须自定义

hub 官方的 `crowdsecurity/dropbear-logs` 只匹配 **PAM 版**文案：
- `Bad PAM password attempt for 'x' from IP:port`

而 OpenWrt 的 dropbear 是非 PAM 编译，实际输出：
- `Bad password attempt for 'root' from IP:port`（少个 "PAM"）

官方解析器永远匹配不上，日志全部 unparsed，所以必须自写。

### 2.2 写入解析器文件

> ⚠️ 本文件对 YAML 缩进敏感。如果你的终端复制会丢行首空格，改用下文 2.3 的 base64 方案。

```sh
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
```

逐项解释：

- `filter: evt.Parsed.program == 'dropbear'`：只处理 program 字段为 dropbear 的日志（s00-raw 的 syslog-logs 解析器已把 `dropbear[1234]` 拆成 program+pid）
- `onsuccess: next_stage`：本解析器命中后进入下一阶段（s02-enrich）
- `nodes`：多个 grok 节点，**任何一个命中即成功**（OR 关系）
- 每个 grok：
  - `pattern`：Grok 正则。`%{DATA:x}` 非贪婪匹配任意文本，`%{IP:x}` 匹配 IP，`%{INT:x}` 匹配数字，`'?` 表示引号可有可无；匹配结果存入 `evt.Parsed.字段名`
  - `apply_on: message`：作用在消息体上（不含 syslog 信封）
  - `statics`：该 grok 命中后打的标。**失败类文案打 `ssh_failed-auth`，成功类打 `ssh_auth_success`** —— 放在节点级而非文件级条件表达式，保证失败/成功不会被误覆盖
  - 第三条 `Exit before auth`：dropbear 达到最大重试次数主动断开的记录，也视为失败
- 文件级 `statics`（所有命中的日志都追加）：
  - `service=ssh`：**ssh-bf 场景只认 service==ssh 的事件**，没有它爆破永远不触发
  - `source_ip` / `username`：从 Parsed 提取到 Meta，供场景和告警使用

### 2.3 防呆替代方案（base64 写入，推荐）

如果 heredoc 复制后缩进丢失（YAML 报错 / explain 结果不对），把上面内容在我这边编码成 base64 后一行写入：

```sh
echo '<base64字符串>' | base64 -d > /etc/crowdsec/parsers/s01-parse/openwrt-dropbear.yaml
```
- `echo '...'`：输出 base64 文本（一行、无空格，复制不会变形）
- `base64 -d`：解码
- `> 文件`：写入解析器文件

写完验证：

```sh
grep -c 'value: ssh_failed-auth' /etc/crowdsec/parsers/s01-parse/openwrt-dropbear.yaml
```
- 统计 `ssh_failed-auth` 出现次数，**必须输出 3**（三条失败规则各一次）。输出 1 或 0 说明文件是旧版/没写进去

---

## 第三部分：白名单（防误封自己）

```sh
mkdir -p /etc/crowdsec/parsers/s02-enrich
cat > /etc/crowdsec/parsers/s02-enrich/openwrt-whitelist.yaml <<'EOF'
name: openwrt/my-whitelist
whitelist:
  reason: my trusted devices
  ip:
    - 192.168.3.100
  cidr:
    - 192.168.3.0/28
EOF
```
- `mkdir -p`：创建目录（已存在不报错）
- 白名单作用：命中名单的 IP 即使触发爆破场景，也**不会生成封禁决策**
- `ip:`：精确 IP 列表 —— **改成你平时管理路由器的设备 IP**
- `cidr: 192.168.3.0/28`：网段 192.168.3.1~192.168.3.14，按需修改或删除

### ⚠️ 关键一步：移除 hub 自带的私网白名单

```sh
cscli parsers remove crowdsecurity/whitelists --force
```
- hub 默认装的这个解析器会把**所有 RFC1918 私网 IP（192.168.x.x 等）的事件加白丢弃**
- 局域网内防护场景下攻击者全是私网 IP → 不移除它任何告警都不会触发（metrics 里 Whitelist Metrics 会显示 "private ipv4/ipv6 ip/ranges" 命中）
- `--force`：跳过"属于某集合"的依赖检查强制移除

---

## 第四部分：重启与解析验证

```sh
systemctl restart crowdsec
```
- 重启 daemon。**改任何配置文件后必须重启才对运行中的服务生效**（`cscli explain` 是起新进程读磁盘，显示正确不代表 daemon 已生效——这是本次排查的最大坑）

```sh
systemctl status crowdsec --no-pager | head -3
```
- 确认服务状态 `active (running)`；`--no-pager` 禁用分页，`head -3` 只看前三行

```sh
ss -tlnp | grep 8080    # TCP 8080（LAPI）应在监听
ss -ulnp | grep 514     # UDP 514（syslog）应在监听（注意 -u）
```
- `-t` TCP / `-u` UDP、`-l` 监听中、`-n` 数字显示、`-p` 显示进程

```sh
cscli explain --type syslog --log "Sep 27 09:58:27 OpenWrt dropbear[1234]: Bad password attempt for 'root' from 1.2.3.4:55555" | grep -E "log_type|🟢|🔴"
```
- 用一条模拟日志走完整解析管线。验收标准：
  - s01 出现 🟢 `openwrt/dropbear-logs`
  - `evt.Meta.log_type : ssh_failed-auth`（不能是 ssh_auth_success）
  - 底下 `crowdsecurity/ssh-bf` 等场景 🟢

---

## 第五部分：路由器侧配置

### 5.1 查容器 IP 并绑定静态租约（防漂移）

```sh
cat /tmp/dhcp.leases | grep -i ubuntu
```
- 输出格式：`MAC IP 主机名 ...`，记下 MAC 和 IP

```sh
uci add dhcp host
uci set dhcp.@host[-1].name='ubuntu-crowdsec'
uci set dhcp.@host[-1].mac='上一步的MAC'
uci set dhcp.@host[-1].ip='10.0.0.233'
uci commit dhcp
/etc/init.d/dnsmasq restart
```
- `uci add dhcp host`：新增一条 DHCP 静态租约，`@host[-1]` 表示刚加的最后一条
- 绑定后容器重启永远拿同一个 IP（否则 IP 漂移会导致日志目标失联、bouncer 断连）
- LuCI 图形界面操作：网络 → DHCP/DNS → 静态地址分配

### 5.2 路由器日志发往容器

```sh
uci set system.@system[0].log_ip='10.0.0.233'
uci set system.@system[0].log_port='514'
uci set system.@system[0].log_proto='udp'
uci commit system
/etc/init.d/log restart
```
- 把系统日志（含 dropbear 登录记录）实时转发给容器
- 注意参数名是 `log_ip`（不是 log_remote）；IP 是容器的固定 IP
- LuCI 图形界面：系统 → 系统属性 → 日志 → 外部系统日志服务器

### 5.3 生成 bouncer 密钥（容器里执行）

```sh
cscli bouncers add openwrt-fw -o raw
```
- 注册一个名为 openwrt-fw 的 bouncer 并输出一串 API 密钥（`-o raw` 只输出密钥本体）
- **此命令必须在容器里执行**（路由器上没有 cscli）
- 复制输出的密钥

### 5.4 回填路由器 bouncer（LuCI 网页）

LuCI → 服务 → CrowdSec Firewall Bouncer：
- LAPI 地址：`http://10.0.0.233:8080`（容器固定 IP）
- API key：粘贴上一步的密钥
- 过滤接口按需勾选（如只拦 br-lan）

保存应用后，容器里验证：

```sh
cscli bouncers list
```
- `openwrt-fw` 应显示 Valid、last pull 时间持续刷新

---

## 第六部分：端到端测试

### 6.1 模拟爆破（在另一台设备上，不在白名单里）

```sh
ssh -o PubkeyAuthentication=no root@192.168.3.201
```
- `-o PubkeyAuthentication=no`：禁用密钥登录，强制走密码（否则配了密钥的设备直接进去了，产生不了失败记录）
- 密码处**乱输** ×3 → 被踢出 → 按 ↑ 重连 → 再乱输 ×3
- **2 分钟内做满 4 轮**（ssh-bf 桶容量 10、泄漏速度约 1 个/10 秒，即 100 秒窗口内要凑够 10 次失败）

### 6.2 验证（按链路顺序）

路由器侧确认失败日志已产生：

```sh
logread | grep -c "Bad password"    # 应 ≥ 12
```

容器侧验收：

```sh
cscli metrics        # Acquisition 段 "Lines poured to bucket" 必须 > 0
cscli alerts list    # 应出现 crowdsecurity/ssh-bf 告警
cscli decisions list # 应有 ban <攻击IP>，4h
```

- **"Lines poured to bucket" > 0 是告警出现前的先行指标**：大于 0 说明失败事件已进检测桶；为 0 说明事件没被正确打标（多半是 daemon 没重启加载新解析器）
- Scenario Metrics 段 `crowdsecurity/ssh-bf` 的 `Overflows` ≥ 1 即为触发

路由器侧确认防火墙写入：

```sh
nft list tables | grep -i crowd     # bouncer 自建表：ip crowdsec / ip6 crowdsec6
nft list table ip crowdsec          # blacklists 集合里应出现攻击 IP
```
- 注意 bouncer 的表**不在 fw4 表里**，是自建的 `ip crowdsec`

被封设备此时连 SSH/LuCI 会直接超时——封禁生效的现场演示。

### 6.3 解封

```sh
lxc-attach -n ubuntu -- cscli decisions delete --ip 192.168.3.41
```
- `lxc-attach -n ubuntu -- 命令`：不进容器直接在容器里执行单条命令
- 删除指定 IP 的封禁决策，bouncer 几秒内同步、防火墙放行

---

## 第七部分：日常运维速查

| 命令 | 位置 | 用途 |
|---|---|---|
| `cscli metrics` | 容器 | 看日志量、解析命中率、进桶数、场景触发 |
| `cscli alerts list` | 容器 | 查看告警历史 |
| `cscli decisions list` | 容器 | 查看当前生效的封禁 |
| `cscli decisions delete --ip x.x.x.x` | 容器 | 手动解封 |
| `cscli bouncers list` | 容器 | 确认 bouncer 连接状态 |
| `cscli explain --type syslog --log "某行日志"` | 容器 | 调试解析器（起新进程，不需重启） |
| `systemctl restart crowdsec` | 容器 | **改配置后必须执行** |
| `logread \| grep dropbear` | 路由器 | 查看原始 dropbear 日志 |
| `nft list table ip crowdsec` | 路由器 | 查看防火墙黑名单实际内容 |

## 踩坑总结（重要度排序）

1. **hub 的 dropbear 解析器只认 PAM 文案**，OpenWrt 非 PAM dropbear 永远匹配不上 → 必须自写解析器
2. **hub 自带 `crowdsecurity/whitelists` 把所有私网 IP 加白**，局域网防护必须移除
3. **改配置文件后必须 `systemctl restart crowdsec`**；`cscli explain` 起新进程读磁盘，显示正确 ≠ daemon 已生效（本次 poured=0 排查的核心）
4. **log_type 打标要在 grok 节点级 statics 里做**，不要用文件级条件表达式（会出现失败被标成成功）
5. heredoc 复制到终端容易丢缩进 → YAML 报错；用 base64 一行式传输最稳
6. `cscli explain` 必须喂完整 syslog 行（带信封）
7. GitHub 直连/gh-proxy 下载都可能失败，packagecloud CDN 直连最稳
8. syslog 数据源写法：`source: syslog` + `listen_port` + `protocol: udp`（写 `source: udp` 会报错）
9. 查 bouncer 黑名单不在 fw4 表，在自建的 `ip crowdsec` 表
10. 容器 IP 一定做 DHCP 静态租约绑定，否则漂移后日志和 bouncer 全断
