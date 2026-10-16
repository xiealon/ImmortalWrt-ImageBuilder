# 这是什么
在悟空大佬https://github.com/wukongdaily

项目https://github.com/wukongdaily/ImmortalWrt-ImageBuilder

进行修改的全自动化的immortalwrt的自动编译项目。

# 在action里面输入的IP,掩码,网关,DNS会直接输入到脚本内部修改
# 默认为旁路模式【所有接口加入br-lan】如需要wan请自行添加接口即可

默认地址为：192.168.3.201/24 225.225.225.0 --192.168.3.1。

关于网关与DNS:【如不修改会自动设置为设置地址的默认第一个IP地址，DNS留空会自动跟随网关设置】。

# 这个能做什么
通过原生集成功能，去除了原项目能去除的部分平台的pppoe地址输入换为集成LXC原生自带crowdsec的容器【ban ip √】。

优化crowdsec的使用，也修复了LXC容器因为网络无法启动的问题:【原项目虽然有了lxc但是没有建立lxc接口也没有将lxc接口移到br-lan】。

本项目使用的是额外的接口LXC与VETH设备:【全自动建立，无需自行设置一次，仅需要首次安装后先重启设备一次获取到所有的接口即可】。

# 关于crowdsec
通过编译过程全自动填写获取的API，自动填入到bouncer界面，到手即用无需敲击一行代码，实现crowdsec全自动化运行。

**注意 1
开机需要先进行一次重启，刷新设备的网络接口。

**注意 2
crowdsec的初次运行需要时间自动进行初始化安装，无需网络也可以自动集成【大概30s】。

**注意 3
防火墙里面的NAT规则LXC-SNAT不要动它，它会在编译时会自动修改对应IP地址到出接口的IP。

# crowdsec 引导流程图（v.63）
每次开机 rc.local 触发引导脚本后的完整执行链路：**左=大步骤框，右=小步骤框（①.a 式编号）**，含每个小步骤失效后的去向。

![CrowdSec LXC 引导流程图](docs/crowdsec-flow.png)

- 灰实线 = 正常流向 ｜ 红虚线 = 失效 / 重试分支 ｜ 橙虚线 = exec 重跑回路 ｜ exit 0/1 = 脚本终止
- 失效主链：注册失败 → heal 2 轮 → CAPI 段复判 → repair（不重建）→ 重验 → 过了放出+enroll ／ 不过重建 exec 重跑（CS_REBUILT 限一次）
- 时间参数：`BOUNCER_PULL_MAX_AGE=600s` 是 last_pull **陈旧阈值**（超龄未更新才判失效，不是等待）；heal 每轮验证窗口 **60s**；repair 重验 **30s**
- 脚本本体：[files/usr/sbin/crowdsec-lxc-bootstrap.sh](files/usr/sbin/crowdsec-lxc-bootstrap.sh)
- 图源文件：[docs/crowdsec-flow.svg](docs/crowdsec-flow.svg)，改图用生成器 [docs/gen_flow.py](docs/gen_flow.py)（python3 gen_flow.py）

## 从开机到放出的时间线（v.63）

引导脚本每次开机由 rc.local 触发。下表把每一段的**等待性质**写明白（都是上限，条件满足立即通过）：

| 阶段 | 代码位置 | 等待性质 | 上限 |
|---|---|---|---|
| rc.local 触发 → 判锁/查镜像 | main 开头 | 无等待；镜像和 rootfs 都无 → exit 0 跳过 | 0s |
| 写容器 config / 解压 rootfs（仅首次/恢复） | ③④ | 无 sleep；强停旧容器 + tar 解压，耗时看镜像大小 | 分钟级 |
| 运行期配置（网桥/网络/采集/监听/UCI） | ⑤⑧ | 纯文件 + uci 操作，无 sleep | 秒级 |
| 启动容器 | ⑦ | lxc-start -d 后轮询 `ct_running`（`_wait_ct_running`，12×5s） | **≤60s** |
| 等容器内 LAPI 就绪 | ⑦ | 每秒查 `cscli bouncers list`，通了立即返回；容器停了立即中止 | **≤90s** |
| bouncer 链路检查 | ⑨ | `bouncer_pulling()` 直接判定，无等待 | 0s |
| 健康路径：放出 + enroll + nft 检查 | ⑩⑪ | `sleep 3` 后查 nft 表；已注册（Enrolled）则跳过 enroll；未注册才走 enroll：先等 `api.crowdsec.net` 可解析（**≤30s 墙钟，就绪即止**，治开机 DNS/mosdns 未就绪的秒退）→ enroll（输出进日志）→ 复检 12×5s | 3s（+30s+60s） |

**健康重启通常 1 分钟内走完前 6 行**（等容器几秒 + 等 LAPI 十几到几十秒）。

失效路径（last_pull 空/错位/陈旧）继续加时：

| 阶段 | 等待构成 | 上限 |
|---|---|---|
| heal 每轮（最多 2 轮） | 等 LAPI ≤90s → 注册（不 sleep，失败立即下一轮）→ 容器内重启 crowdsec → 再等 LAPI ≤90s → 重启路由器 bouncer + sleep 12 → **此后才计 60s 验证窗口**（12×5s 查 last_pull） | ≤90+90+12+60s/轮 |
| repair（heal 2 轮不过） | 容器施救/重启（等容器 ≤60s）→ 配置校验 → 等 LAPI ≤90s → 重注册 → 重启两端 → 6×5s 重验 | ≤60+90+30s |
| 重建（repair 不过） | 强停容器（最多 3 轮）→ 删 rootfs → `exec` 重跑脚本（CS_REBUILT=1 限一次），从时间线第一步重走 | 全流程重来 |

三个关键点：

- **60s 验证窗口从哪开始计**：不是开机、不是容器起来、不是注册成功，而是本轮 heal 里「重启路由器 bouncer + sleep 12」**完成之后**才开始 12×5s 倒计时——bouncer 没重启完，last_pull 本来就不会动，提前计时只会误判
- 两个 90s 是 LAPI 就绪闸门（`_wait_lapi_ready`），超时只告警不退出；注册本身零等待，成败交验证窗口判定
- `BOUNCER_PULL_MAX_AGE=600s` 是 last_pull **陈旧阈值**（超龄未更新才判失效），不是任何地方的等待

enroll 判定（v.63 起简化）：

- 开机判定**只看 Enrolled**：`cscli console status` 的 Enrolled 行不是否定态（`not enrolled`/`false`）就算已注册。**authenticated 不查**——`cscli console enroll` 后必须先到网页端 app.crowdsec.net 点 Accept enroll，之前本来就是未 authenticated，拿它当开机判据只会每次误判异常、反复重注册
- enroll 前先等 `api.crowdsec.net` 可解析（≤30s 墙钟、每秒一探、就绪即止），治开机时 DNS/mosdns 未就绪导致的**秒退**；enroll 命令的输出和 `cscli capi status` 都写进日志，失败有据可查
- 注册码**固定有效、不消耗**，反复 enroll 无代价；enroll 成功后等网页端 Accept 即可，无需脚本干预

# mosdns 与容器 DNS（redirect 开启后容器解析失败的排查）

固件里 mosdns 默认开了两个开关（`files/etc/uci-defaults/99-custom.sh`）：`redirect=1` 和 `local_dns_redirect=1`。它们对容器 DNS 的影响是**源码级**的（luci-app-mosdns init 脚本）：

| 开关 | 实际动作 | 对容器的意义 |
|---|---|---|
| `redirect=1` | dnsmasq 被改成 `server=127.0.0.1#5335` + `noresolv=1` + `cachesize=0`，dnsmasq 继续听 53，把所有查询转给 mosdns | 容器 DNS=10.0.0.1 的查询走 dnsmasq → mosdns，**这条路本来就是通的** |
| `local_dns_redirect=1` | 加 nft 规则 `inet mosdns prerouting: udp dport 53 redirect to :5335`，**所有** UDP 53 流量（不管目的地是路由器还是外网 DNS）统统改投本机 5335 的 mosdns | 容器在 `custom_router_dns.txt` 里填任何公网 DNS 都会被拉回来，**填了也白填**；且多了一条对 lxcbr0 流量的劫持依赖 |

排查顺序（从现象反推）：

1. **超时无响应** → 查 mosdns 监听：`netstat -lnp | grep 5335` 必须是 `0.0.0.0:5335`（不能只听 127.0.0.1，劫持包目标是 10.0.0.1:5335）；再查 lxc 防火墙区 input 是否为 ACCEPT（引导脚本 `setup_lxc_firewall` 默认已建，手动改过防火墙的注意）
2. **还是不通** → A/B 二分：`uci set mosdns.config.local_dns_redirect='0' && uci commit mosdns && /etc/init.d/mosdns restart`，容器恢复即说明是劫持规则对 lxcbr0 的副作用，保持关闭即可（容器 DNS 本来就该走 dnsmasq 路径，不需要劫持）
3. **解析错/被污染** → 查 mosdns 分流规则：上游用 IP 形式（固件默认 223.5.5.5/119.29.29.29），别用域名形式的 DoH 上游（自身解析可能成环）
4. **内网域名（\*.lan/hostname）解析失败** → `forward_local` 指向 dnsmasq:53，而 redirect=1 又把 dnsmasq 全部转回 mosdns:5335，**成环**。此场景建议只开 `redirect=1`、关掉 `local_dns_redirect`

推荐配置：容器 DNS 保持默认 `10.0.0.1`（`custom_router_dns.txt` 留空，引导脚本 `_container_dns()` 自动回落桥 IP），mosdns 只开 `redirect=1`；确需"矫正硬编码 DNS 的设备"再开 `local_dns_redirect`，但须确认监听在 `0.0.0.0:5335` 且 lxc 区放行。

# 最后，感谢每一位项目贡献者。
