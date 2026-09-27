# 第 5 步 · 写 CrowdSec 配置（方法一：heredoc）

> 整段复制、粘到**容器**终端里执行（先 `lxc-attach -P /srv/lxc -n ubuntu` 进容器）。
>
> ⚠️ 这个方式依赖**行首空格**。有些浏览器或终端复制时会把缩进吃掉，YAML 缩进一乱规则就失效。
> 如果写完后 `grep -c` 校验不通过，改用方法二：`CrowdSec-第5步-配置-base64.md`。

---

## 1. 日志源：让 CrowdSec 在 UDP 514 收路由器的日志

```sh
mkdir -p /etc/crowdsec/acquis.d
cat > /etc/crowdsec/acquis.d/router.yaml <<'EOF'
source: syslog
listen_addr: 0.0.0.0
listen_port: 514
protocol: udp
labels:
  type: syslog
EOF
```

## 2. dropbear 解析器：教它看懂 OpenWrt 的 SSH 日志

hub 自带那条只认 `Bad PAM password attempt`（服务器 Linux 的写法），而 OpenWrt 的 dropbear 是非 PAM，
实际打出来的是 `Bad password attempt`，所以必须自己写一条。

```sh
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
```

## 3. 白名单（不需要白名单就保持原样，127.0.0.1 / 240.0.0.0/4 是永不命中的占位）

```sh
mkdir -p /etc/crowdsec/parsers/s02-enrich
cat > /etc/crowdsec/parsers/s02-enrich/openwrt-whitelist.yaml <<'EOF'
# 作用：s02-enrich 阶段的自定义白名单解析器。
# 如果你「不需要任何白名单」，保持下面这个占位写法即可（127.0.0.1 是本机回环，
# 永远不会成为日志里的 source_ip，等于一条不生效的规则），不要写成空列表或删掉
# ip/cidr 字段——CrowdSec 加载时对字段缺失的容忍度不如占位值稳。
#
# 想彻底去掉这个文件：直接删除它即可，bootstrap 脚本已做存在性判断，不会报错。
name: openwrt/my-whitelist
description: 'No whitelist configured - placeholder only'
whitelist:
  reason: placeholder, nothing is whitelisted
  ip:
    - 127.0.0.1
  cidr:
    - 240.0.0.0/4
EOF
```

## 4. 写完必须校验（别省这一步）

```sh
grep -c 'value: ssh_failed-auth' /etc/crowdsec/parsers/s01-parse/openwrt-dropbear.yaml
```

**必须输出 `3`**（`Bad password` / `nonexistent user` / `Exit before auth` 三条）。
输出 1 或 2 说明复制时被截断了，重贴一次，或改用 base64 方法二。

## 5. 删掉 hub 的私网白名单 + 重启

```sh
cscli parsers remove crowdsecurity/whitelists --force
systemctl restart crowdsec
```

- 不删那条，192.168.x.x / 10.x.x.x 全被当成"自己人"，局域网爆破一个都不报。
- 改完配置必须重启——正在跑的进程用的是内存里的旧配置。
