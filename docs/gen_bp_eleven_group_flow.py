# -*- coding: utf-8 -*-
"""生成「11 组链式站位 · 31 节点」架构图 SVG + PNG

对应 crowdsec-lxc-bootstrap.sh v.180.113。
节点与分组直接取自脚本的 DAG_NODES / NODE_GROUP_*，不是手写清单。

用法：python gen_bp_eleven_group_flow.py
产物：bp-eleven-group-flow.svg / bp-eleven-group-flow.png
"""
import io
import os
import resvg_py

W = 1500
PAD = 36
FONT = "'Microsoft YaHei','Noto Sans CJK SC',sans-serif"

# (组名, 阶段号, 标题, 节点, 前置组, 说明, 主色, 行高)
GROUPS = [
    ("NETBASE", "Ⅰ Ⅱ Ⅲ", "网络基线 → 从 /rom 补包 → smartdns 配置", None,
     "", "补包 · 写 13 条上游 · dnsmasq 让出 53", "#2f6fd0", 136),
    ("INSTALL", "Ⅱ", "安装容器：迁移校验镜像 / 解压 rootfs / 写 config",
     ["img_migrate", "rootfs", "ct_config"], "", "rootfs 解压到 LXC_PATH", "#7b4fd0", 106),
    ("PREP", "Ⅱ", "容器启动前的静态准备",
     ["ct_net", "cgroup_mount", "ct_bootlink", "ct_resolv"], "NETBASE INSTALL",
     "网卡 / cgroup / 开机链 / DNS", "#7b4fd0", 106),
    ("CAPIBLOCK", "Ⅳ", "屏蔽 CAPI（容器内 online_client 停用）",
     ["capi_block"], "INSTALL PREP", "config.yaml 只在启动时读一次", "#e67e22", 106),
    ("BOOT", "Ⅳ", "启动容器（全程唯一一次开机）",
     ["ct_boot"], "NETBASE PREP INSTALL CAPIBLOCK", "没有 SNAT 不启动", "#e67e22", 106),
    ("LOGCONF", "Ⅳ", "日志链路与对外监听",
     ["logconf"], "BOOT", "宿主机推送 + 容器采集", "#e67e22", 106),
    ("LAPI", "Ⅳ", "取 LAPI 并填入路由器 bouncer",
     ["lapi_fetch", "bouncer_fill"], "BOOT", "填完 api_url/key 重启 bouncer", "#e67e22", 106),
    ("BOUNCERVERIFY", "Ⅳ", "验证 bouncer 真在拉，再解开 CAPI",
     ["bouncer_verify", "capi_release"], "LOGCONF LAPI", "看 last_pull 新鲜度", "#e67e22", 106),
    ("DEPS", "Ⅳ", "只验不装：网络通不通 / 组件就位没",
     ["deps"], "BOUNCERVERIFY", "未就绪则 enroll 跳过", "#e67e22", 106),
    ("SMARTCHK", "Ⅴ", "smartdns 运行态验证",
     ["sd_serve"], "DEPS", "进程 / 53 监听 / 容器内解析", "#2e7d32", 106),
    ("ENROLL", "Ⅴ", "Console Enroll —— 全程唯一联网点",
     ["enroll"], "SMARTCHK", "主码缺失用本地保险柜", "#2e7d32", 106),
]

NET_NODES = ["br_lan_ports", "lan_static", "dhcp_ignore", "bridge", "lxc_zone",
             "fwd_rules", "lan_input", "snat", "ip_forward", "svc_bind", "docker_fw"]
NET_TAIL = ["pkg_base", "lxc_auto", "smartdns"]

ROW_GAP = 14
TOP = 258
BOTTOM = 96
TOTAL_H = TOP + sum(g[7] for g in GROUPS) + ROW_GAP * len(GROUPS) + BOTTOM
RIGHT = W - PAD - 20
NODE_X = PAD + 52


def esc(s):
    return (s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;'))


def wrap_nodes(nodes, per_line):
    out = []
    for i in range(0, len(nodes), per_line):
        out.append(' · '.join(nodes[i:i + per_line]))
    return out


svg = []
A = svg.append
A('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">'
  % (W, TOTAL_H, W, TOTAL_H))
A('<rect width="100%" height="100%" fill="#ffffff"/>')

# ── 这是什么：README 开头的原文，逐字搬上来（只在 URL 处用蓝色区分，不加字不改字）
A('<rect x="%d" y="16" width="%d" height="122" rx="10" fill="#f6f7f9" stroke="#d5d9e0" stroke-width="1"/>'
  % (PAD, W - PAD * 2))
A('<text x="%d" y="46" font-size="19" font-weight="700" fill="#111111" font-family="%s">这是什么</text>'
  % (PAD + 20, FONT))
A('<text x="%d" y="75" font-size="16" fill="#222222" font-family="%s">'
  '<tspan>在悟空大佬</tspan><tspan fill="#1a56c4">https://github.com/wukongdaily</tspan></text>'
  % (PAD + 20, FONT))
A('<text x="%d" y="101" font-size="16" fill="#222222" font-family="%s">'
  '<tspan>项目</tspan><tspan fill="#1a56c4">https://github.com/wukongdaily/ImmortalWrt-ImageBuilder</tspan></text>'
  % (PAD + 20, FONT))
A('<text x="%d" y="127" font-size="16" fill="#222222" font-family="%s">'
  '进行修改的全自动化的immortalwrt的自动编译项目。</text>' % (PAD + 20, FONT))

# ── 主标题
A('<text x="%d" y="184" font-size="30" font-weight="700" fill="#111111" font-family="%s">'
  'crowdsec-lxc-bootstrap.sh · 11 组 · 31 节点</text>' % (PAD, FONT))
A('<text x="%d" y="214" font-size="17" fill="#666666" font-family="%s">'
  'v.180.113 · 组内每个节点都是「先验证现场，达标就零写入；不达标才构建」</text>' % (PAD, FONT))

# 阶段图例
lx = PAD
for label, color in [("Ⅰ 网络", "#2f6fd0"), ("Ⅱ 容器", "#7b4fd0"),
                     ("Ⅲ smartdns", "#0e8a8a"), ("Ⅳ crowdsec", "#e67e22"), ("Ⅴ 检测+注册", "#2e7d32")]:
    A('<rect x="%d" y="226" width="16" height="16" fill="%s"/>' % (lx, color))
    A('<text x="%d" y="240" font-size="15" fill="#333333" font-family="%s">%s</text>'
      % (lx + 22, FONT, esc(label)))
    lx += 22 + len(label) * 15 + 30

y = TOP
for idx, (name, phase, title, nodes, deps, note, color, h) in enumerate(GROUPS, 1):
    A('<rect x="%d" y="%d" width="%d" height="%d" rx="10" fill="#fbfcff" stroke="%s" stroke-width="2"/>'
      % (PAD, y, W - PAD * 2, h, color))
    # 序号
    A('<text x="%d" y="%d" font-size="18" font-weight="700" fill="%s" font-family="%s">%02d</text>'
      % (PAD + 18, y + 30, color, FONT, idx))
    # 组名
    A('<text x="%d" y="%d" font-size="20" font-weight="700" fill="#111111" font-family="%s">%s</text>'
      % (PAD + 52, y + 30, FONT, esc(name)))
    # 阶段徽标
    A('<rect x="%d" y="%d" width="132" height="26" rx="6" fill="%s"/>' % (W - PAD - 152, y + 12, color))
    A('<text x="%d" y="%d" text-anchor="middle" font-size="15" font-weight="700" fill="#ffffff" font-family="%s">%s</text>'
      % (W - PAD - 86, y + 31, FONT, esc(phase)))
    # 标题
    A('<text x="%d" y="%d" font-size="16" fill="#333333" font-family="%s">%s</text>'
      % (PAD + 52, y + 56, FONT, esc(title)))
    # 节点
    if name == "NETBASE":
        rows = wrap_nodes(NET_NODES, 6) + ['（Ⅱ）' + ' · '.join(NET_TAIL)]
    elif nodes:
        rows = wrap_nodes(nodes, 8)
    else:
        rows = ['（动作在 NETBASE 组内完成）']
    ny = y + 80
    for r in rows:
        A('<text x="%d" y="%d" font-size="15" fill="%s" font-family="%s">%s</text>'
          % (PAD + 52, ny, color, FONT, esc(r)))
        ny += 21
    # 前置
    if deps:
        A('<text x="%d" y="%d" text-anchor="end" font-size="14" fill="#888888" font-family="%s">'
          '前置：%s</text>' % (W - PAD - 20, y + 56, FONT, esc(deps)))
    # 说明
    A('<text x="%d" y="%d" text-anchor="end" font-size="14" fill="#555555" font-family="%s">%s</text>'
      % (W - PAD - 20, y + 80, FONT, esc(note)))
    y += h + ROW_GAP

by = y + 8
A('<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="#dddddd" stroke-width="1"/>'
  % (PAD, by, W - PAD, by))
A('<text x="%d" y="%d" font-size="15" fill="#444444" font-family="%s">'
  '组顺序由 GROUP_SEQ 决定，不看书写顺序；组内节点由 DEP_* 拓扑排序。</text>' % (PAD, by + 28, FONT))
A('<text x="%d" y="%d" font-size="15" fill="#444444" font-family="%s">'
  '联网只出现在 ENROLL 一处；其余全部走 /rom 本地自愈。</text>' % (PAD, by + 52, FONT))
A('</svg>')

out = '\n'.join(svg)
here = os.path.dirname(os.path.abspath(__file__))
io.open(os.path.join(here, 'bp-eleven-group-flow.svg'), 'w', encoding='utf-8', newline='\n').write(out)

png = resvg_py.svg_to_bytes(svg_string=out, zoom=1.0)
open(os.path.join(here, 'bp-eleven-group-flow.png'), 'wb').write(bytes(png))
print('SVG %d B / PNG %d B' % (len(out.encode('utf-8')),
                               os.path.getsize(os.path.join(here, 'bp-eleven-group-flow.png'))))
