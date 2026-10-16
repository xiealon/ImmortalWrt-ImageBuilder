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

# crowdsec 引导流程图（v.62）
每次开机 rc.local 触发引导脚本后的完整执行链路：**左=大步骤框，右=小步骤框（①.a 式编号）**，含每个小步骤失效后的去向。

![CrowdSec LXC 引导流程图](docs/crowdsec-flow.png)

- 灰实线 = 正常流向 ｜ 红虚线 = 失效 / 重试分支 ｜ 橙虚线 = exec 重跑回路 ｜ exit 0/1 = 脚本终止
- 失效主链：注册失败 → heal 2 轮 → CAPI 段复判 → repair（不重建）→ 重验 → 过了放出+enroll ／ 不过重建 exec 重跑（CS_REBUILT 限一次）
- 脚本本体：[files/usr/sbin/crowdsec-lxc-bootstrap.sh](files/usr/sbin/crowdsec-lxc-bootstrap.sh)
- 图源文件：[docs/crowdsec-flow.svg](docs/crowdsec-flow.svg)，改图用生成器 [docs/gen_flow.py](docs/gen_flow.py)（python3 gen_flow.py）

# 最后，感谢每一位项目贡献者。
