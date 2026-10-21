#!/usr/bin/env python3
"""生成 BACKUP 仓「v.82 层级 DAG + 阶段 3 A/B/C 服务链全貌图」SVG + 高清 PNG
内容：crowdsec-lxc-bootstrap.sh（v.82 · 旁路由锁定线）——
  阶段 1+2：4 个大步骤(GROUP) / 19 个小步骤(node) 两级依赖图：
    ① container 容器就绪（img_migrate→ct_config→rootfs）
    ② net 网络就绪（路由器网桥 br_lan_ports→lan_static 先，
      并列 dhcp_ignore/dns_domain（wan/wan6 段在主流程开头无条件删除，不是节点），
      容器网络 bridge→lxc_zone→fwd_rules 后）
    ③ fw 防火墙与服务（lan_input/snat/ip_forward/svc_bind/docker_fw）
    ④ boot 容器启动（prepare_container→ct_boot；prepare_container 为容器内
      构建七步，各自 ensure+hard：网络文件/自启软链/resolv/日志源解析器/
      listen_uri/trusted_ips/容器 config，每步至多一次，不过即 hard）
  组间 GROUP_SEQ 序列 + 组绑定（fw 绑 net；boot 绑 container+net+fw）
  阶段 3：A/B/C 步骤化服务链（shield→stamp 分流→A→B→C→online_client→enroll，
    verify 就绪跳过 → fix 一次 → 复核，与 DAG ensure 同构至多一次，不过即 hard；
    enroll 除外，保留之前做法；开机步并入 DAG boot 组（build_ct_boot 启动链
    前置检查：缺链不开机）；C 失败走 step_C 决策树：复验 A/B → 一次修复 →
    A/B 正常仍拉不到 = 容器损坏 → tier 3 重装自愈（五道门，见 _escalate_reinstall））
  底部：机制图例（含 v.82 运行期 last_pull 探针行）+ 「声明即架构」校验要点

用法: python3 gen_dag_flow.py
  输出: 同目录 dag-flow.svg / dag-flow.png（2x 高清，已裁精确尺寸）
"""
import os
import subprocess

W, H = 1760, 1260
OUT_DIR = os.path.dirname(os.path.abspath(__file__))
SVG = os.path.join(OUT_DIR, "dag-flow.svg")
PNG = os.path.join(OUT_DIR, "dag-flow.png")

# 大步骤配色（浅底 + 深字 + 中色边）
GC = {
    "container": ("#ebf8ff", "#2b6cb0", "#90cdf4"),   # 蓝
    "net":       ("#f0fff4", "#276749", "#9ae6b4"),   # 绿
    "fw":        ("#fffaf0", "#c05621", "#fbd38d"),   # 橙
    "boot":      ("#faf5ff", "#6b46c1", "#d6bcfa"),   # 紫
}

# 节点：key=名, (说明, 类型标签)
INSTALL, ENSURE, ALWAYS = "install", "ensure", "ALWAYS"
TAG_STYLE = {
    INSTALL: ("#dd6b20", "#feebc8"),   # 橙
    ENSURE:  ("#2b6cb0", "#bee3f8"),   # 蓝
    "hard":  ("#c53030", "#fed7d7"),   # 红（统一 hard 语义）
}
HARD = "hard"

NODES = {
    "img_migrate": ("镜像迁移到 LXC 目录（tarball 就位）", INSTALL, None),
    "ct_config":   ("容器 config 落盘（lxc.conf 等）", INSTALL, None),
    "rootfs":      ("rootfs 解压 / 恢复（置 _recovering）", INSTALL, None),
    "br_lan_ports": ("br-lan 桥 + 挂载全部物理口", ENSURE, None),
    "lan_static":  ("LAN 静态地址 10.0.0.201/24", ENSURE, None),
    "dhcp_ignore": ("DHCP 让权 ignore=1", ENSURE, None),
    "dns_domain":  ("DNS 劫持 time.android.com", ENSURE, None),
    "bridge":      ("容器网桥 lxcbr0 10.1.0.1", ENSURE, None),
    "lxc_zone":    ("防火墙 lxc zone（ACCEPT）", ENSURE, None),
    "fwd_rules":   ("lxc↔lan/docker/vpn 转发", ENSURE, None),
    "lan_input":   ("LAN zone 放行 ACCEPT", ENSURE, None),
    "snat":        ("SNAT snat_ip←lan.ipaddr", ENSURE, None),
    "ip_forward":  ("ip_forward=1", ENSURE, None),
    "svc_bind":    ("dropbear/ttyd 绑 LAN 口", ENSURE, None),
    "docker_fw":   ("docker zone + 三向转发", ENSURE, None),
    "prepare_container": ("容器内配置生成（五子步骤产物校验）", ENSURE, None),
    "ct_boot":     ("启动链前置检查 + lxc-autostart", ENSURE, None),
}

# 组内布局：每列 x、组框、标题
COLS = [
    ("container", "①", "容器就绪", 30),
    ("net",       "②", "网络就绪（路由器网桥 → 容器网络）", 470),
    ("fw",        "③", "防火墙与服务就绪", 910),
    ("boot",      "④", "容器启动", 1350),
]
COL_W = 380
GX, GY, GH = None, 96, 556          # 组框 y 起点/高度
NODE_H, NODE_GAP = 44, 13
NX = 15                               # 节点左边距（相对组框）

p = []
p.append(f'''<svg width="{W}" height="{H}" viewBox="0 0 {W} {H}" xmlns="http://www.w3.org/2000/svg" font-family="-apple-system,'PingFang SC','Microsoft YaHei','Noto Sans CJK SC',sans-serif">
  <defs>
    <marker id="ar" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
      <path d="M 0 0 L 10 5 L 0 10 z" fill="#94a3b8"/>
    </marker>
    <marker id="arg" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
      <path d="M 0 0 L 10 5 L 0 10 z" fill="#a0aec0"/>
    </marker>
  </defs>
  <style>
    .t{{font-size:19px;font-weight:700;fill:#1a202c}}
    .ts{{font-size:11.5px;fill:#718096}}
    .gt{{font-size:13.5px;font-weight:700}}
    .gts{{font-size:10.5px}}
    .b{{font-size:12px;font-weight:600;fill:#1a202c}}
    .s{{font-size:10px;fill:#4a5568}}
    .mono{{font-family:ui-monospace,'SFMono-Regular',Consolas,monospace}}
    .ln{{stroke:#94a3b8;stroke-width:1.5;fill:none}}
    .lng{{stroke:#a0aec0;stroke-width:1.3;fill:none;stroke-dasharray:4 3}}
    .tag{{font-size:9px;font-weight:700}}
  </style>
  <rect x="0" y="0" width="{W}" height="{H}" fill="#ffffff"/>''')

p.append(f'''
  <text x="{W//2}" y="30" text-anchor="middle" class="t">v.81 层级 DAG + 阶段 3 A/B/C 服务链全貌（统一 ensure + hard 一次修复 + tier 3 重装自愈 · BACKUP 旁路由锁定线 · crowdsec-lxc-bootstrap.sh）</text>
  <text x="{W//2}" y="52" text-anchor="middle" class="ts">大步骤(GROUP) → 小步骤(node)：GROUP_SEQ 定先后，GROUP_DEP 定绑定，DEP_ 定组内依赖；每个小步骤必须 NODE_GROUP 归属一个大步骤</text>''')

# ---------- 组框 + 标题 ----------
def group_frame(x, gkey, num, title, count):
    bg, fg, bd = GC[gkey]
    p.append(f'''
  <rect x="{x}" y="{GY}" width="{COL_W}" height="{GH}" rx="10" fill="{bg}" stroke="{bd}" stroke-width="1.2"/>
  <rect x="{x}" y="{GY}" width="{COL_W}" height="34" rx="10" fill="{fg}"/>
  <rect x="{x}" y="{GY+24}" width="{COL_W}" height="10" fill="{fg}"/>
  <text x="{x+14}" y="{GY+22}" class="gt" fill="#ffffff">大步骤 {num} {gkey} · {title}</text>
  <text x="{x+COL_W-14}" y="{GY+22}" text-anchor="end" class="gts" fill="#ffffff">{count} 个小步骤</text>''')

# ---------- 节点框 ----------
def node(x, y, key, w=COL_W - NX * 2):
    desc, tag, hard = NODES[key]
    tfg, tbg = TAG_STYLE[tag]
    p.append(f'''
  <rect x="{x}" y="{y}" width="{w}" height="{NODE_H}" rx="6" fill="#ffffff" stroke="#cbd5e0" stroke-width="1"/>
  <rect x="{x+7}" y="{y+7}" width="52" height="15" rx="7" fill="{tbg}"/>
  <text x="{x+33}" y="{y+18}" text-anchor="middle" class="tag" fill="{tfg}">{tag}</text>
  <text x="{x+66}" y="{y+19}" class="b">{key}</text>
  <text x="{x+66}" y="{y+35}" class="s">{desc}</text>''')
    if hard:
        p.append(f'<text x="{x+w-8}" y="{y+18}" text-anchor="end" class="tag" fill="#c53030">✕ hard</text>')

def varrow(x, y1, y2, label=""):
    p.append(f'<line x1="{x}" y1="{y1}" x2="{x}" y2="{y2}" class="ln" marker-end="url(#ar)"/>')
    if label:
        p.append(f'<text x="{x+8}" y="{(y1+y2)//2+3}" class="s" style="font-size:9.5px">{label}</text>')

def harrow(x1, x2, y, color="#94a3b8", cls="ln", marker="ar"):
    p.append(f'<line x1="{x1}" y1="{y}" x2="{x2}" y2="{y}" class="{cls}" marker-end="url(#{marker})"/>')

# ================= ① container =================
x0 = COLS[0][3]
group_frame(x0, "container", "①", "容器就绪", 3)
cx = x0 + COL_W / 2
y = GY + 46
node(x0 + NX, y, "img_migrate"); varrow(cx, y + NODE_H, y + NODE_H + NODE_GAP)
y += NODE_H + NODE_GAP
node(x0 + NX, y, "ct_config"); varrow(cx, y + NODE_H, y + NODE_H + NODE_GAP)
y += NODE_H + NODE_GAP
node(x0 + NX, y, "rootfs")
p.append(f'''
  <rect x="{x0+14}" y="{GY+GH-118}" width="{COL_W-28}" height="104" rx="6" fill="#ffffff" stroke="#90cdf4" stroke-dasharray="4 3"/>
  <text x="{x0+26}" y="{GY+GH-98}" class="b" fill="#2b6cb0">install 类 · 一次性</text>
  <text x="{x0+26}" y="{GY+GH-82}" class="s">verify = 产物在不在（tarball / config / rootfs）</text>
  <text x="{x0+26}" y="{GY+GH-66}" class="s">ct_config / rootfs 为 hard：失败即终止引导</text>
  <text x="{x0+26}" y="{GY+GH-50}" class="s">日志：[container] 容器就绪 完成（3/3）</text>
  <text x="{x0+26}" y="{GY+GH-30}" class="s mono" style="font-size:9.5px">DEP_ct_config=img_migrate</text>
  <text x="{x0+26}" y="{GY+GH-16}" class="s mono" style="font-size:9.5px">DEP_rootfs=img_migrate</text>''')

# ================= ② net =================
x0 = COLS[1][3]
group_frame(x0, "net", "②", "网络就绪（路由器网桥 → 容器网络）", 8)
cx = x0 + COL_W / 2
y = GY + 46
node(x0 + NX, y, "br_lan_ports"); varrow(cx, y + NODE_H, y + NODE_H + NODE_GAP)
y += NODE_H + NODE_GAP
node(x0 + NX, y, "lan_static")
# 并列三兄弟
sy = y + NODE_H + NODE_GAP + 4
sub_w = (COL_W - NX * 2 - 16) / 2
mid = x0 + COL_W / 2
left_c = x0 + NX + sub_w / 2
right_c = x0 + NX + (sub_w + 8) + sub_w / 2
# 分叉：lan_static 底 → 竖线 → 横线 → 三兄弟顶
p.append(f'<line x1="{mid:.0f}" y1="{y+NODE_H}" x2="{mid:.0f}" y2="{sy-12}" class="ln"/>')
p.append(f'<line x1="{left_c:.0f}" y1="{sy-12}" x2="{right_c:.0f}" y2="{sy-12}" class="ln"/>')
for i, k in enumerate(["dhcp_ignore", "dns_domain"]):
    sx = x0 + NX + i * (sub_w + 8)
    desc, tag, hard = NODES[k]
    tfg, tbg = TAG_STYLE[tag]
    p.append(f'''
  <rect x="{sx:.0f}" y="{sy}" width="{sub_w:.0f}" height="52" rx="6" fill="#ffffff" stroke="#cbd5e0" stroke-width="1"/>
  <rect x="{sx+6:.0f}" y="{sy+6}" width="44" height="13" rx="6" fill="{tbg}"/>
  <text x="{sx+28:.0f}" y="{sy+16}" text-anchor="middle" class="tag" fill="{tfg}">{tag}</text>
  <text x="{sx+sub_w/2:.0f}" y="{sy+32}" text-anchor="middle" class="b" style="font-size:10.5px">{k}</text>
  <text x="{sx+sub_w/2:.0f}" y="{sy+45}" text-anchor="middle" class="s" style="font-size:9px">{desc}</text>''')
    p.append(f'<line x1="{sx+sub_w/2:.0f}" y1="{sy-12}" x2="{sx+sub_w/2:.0f}" y2="{sy}" class="ln" marker-end="url(#ar)"/>')
p.append(f'<text x="{x0+NX+4}" y="{sy-18}" class="s" style="font-size:9.5px">并列（无依赖，同轮 verify）</text>')
# 汇合：三兄弟底 → 横线 → bridge
by = sy + 52 + NODE_GAP + 4
for _c in (left_c, right_c):
    p.append(f'<line x1="{_c:.0f}" y1="{sy+52}" x2="{_c:.0f}" y2="{sy+62}" class="ln"/>')
p.append(f'<line x1="{left_c:.0f}" y1="{sy+62}" x2="{right_c:.0f}" y2="{sy+62}" class="ln"/>')
p.append(f'<line x1="{mid:.0f}" y1="{sy+62}" x2="{mid:.0f}" y2="{by}" class="ln" marker-end="url(#ar)"/>')
node(x0 + NX, by, "bridge"); varrow(cx, by + NODE_H, by + NODE_H + NODE_GAP, "DEP_bridge=lan_static")
by += NODE_H + NODE_GAP
node(x0 + NX, by, "lxc_zone"); varrow(cx, by + NODE_H, by + NODE_H + NODE_GAP)
by += NODE_H + NODE_GAP
node(x0 + NX, by, "fwd_rules")
p.append(f'''
  <rect x="{x0+14}" y="{GY+GH-118}" width="{COL_W-28}" height="104" rx="6" fill="#ffffff" stroke="#9ae6b4" stroke-dasharray="4 3"/>
  <text x="{x0+26}" y="{GY+GH-98}" class="b" fill="#276749">绑定 + 先后（开机引导的核心约束）</text>
  <text x="{x0+26}" y="{GY+GH-82}" class="s">路由器网桥(br_lan_ports→lan_static) 先于容器网络</text>
  <text x="{x0+26}" y="{GY+GH-66}" class="s">(bridge→lxc_zone→fwd_rules)：SNAT/防火墙依赖 LAN 侧</text>
  <text x="{x0+26}" y="{GY+GH-50}" class="s">组内任一失败 → 整组未完成 → boot 组整组跳过</text>
  <text x="{x0+26}" y="{GY+GH-30}" class="s mono" style="font-size:9.5px">DEP_bridge=lan_static  DEP_lxc_zone=bridge</text>
  <text x="{x0+26}" y="{GY+GH-16}" class="s mono" style="font-size:9.5px">DEP_fwd_rules=lxc_zone</text>''')

# ================= ③ fw =================
x0 = COLS[2][3]
group_frame(x0, "fw", "③", "防火墙与服务就绪", 6)
cx = x0 + COL_W / 2
y = GY + 46
for i, k in enumerate(["lan_input", "snat", "ip_forward", "svc_bind", "docker_fw"]):
    node(x0 + NX, y, k)
    if i < 5:
        varrow(cx, y + NODE_H, y + NODE_H + NODE_GAP)
    y += NODE_H + NODE_GAP
p.append(f'''
  <rect x="{x0+14}" y="{GY+GH-118}" width="{COL_W-28}" height="104" rx="6" fill="#ffffff" stroke="#fbd38d" stroke-dasharray="4 3"/>
  <text x="{x0+26}" y="{GY+GH-98}" class="b" fill="#c05621">组绑定：fw 绑 net</text>
  <text x="{x0+26}" y="{GY+GH-82}" class="s">snat 的 snat_ip 读 _lan_ip()（net 组 lan_static）</text>
  <text x="{x0+26}" y="{GY+GH-66}" class="s">net 组未完成 → 本组整组跳过（不建半截防火墙）</text>
  <text x="{x0+26}" y="{GY+GH-50}" class="s">svc_bind 局部 commit，不进 flush 分组</text>
  <text x="{x0+26}" y="{GY+GH-30}" class="s mono" style="font-size:9.5px">GROUP_DEP_fw=net   DEP_snat=lan_static</text>
  <text x="{x0+26}" y="{GY+GH-16}" class="s mono" style="font-size:9.5px">docker 无 dockerd → verify 直接跳过</text>''')

# ================= ④ boot =================
x0 = COLS[3][3]
group_frame(x0, "boot", "④", "容器启动", 2)
cx = x0 + COL_W / 2
y = GY + 46
node(x0 + NX, y, "prepare_container"); varrow(cx, y + NODE_H, y + NODE_H + NODE_GAP)
y += NODE_H + NODE_GAP
node(x0 + NX, y, "ct_boot")
p.append(f'''
  <rect x="{x0+14}" y="{GY+GH-118}" width="{COL_W-28}" height="104" rx="6" fill="#ffffff" stroke="#d6bcfa" stroke-dasharray="4 3"/>
  <text x="{x0+26}" y="{GY+GH-98}" class="b" fill="#6b46c1">组绑定：boot 绑 ①+②+③ · 七步各自 ensure+hard</text>
  <text x="{x0+26}" y="{GY+GH-82}" class="s">每步 verify 就绪跳过 → 构建 → 复核，至多一次，不过即 hard</text>
  <text x="{x0+26}" y="{GY+GH-66}" class="s">ct_boot：启动链内容级前置检查，缺链不开机不重建（v.81）</text>
  <text x="{x0+26}" y="{GY+GH-50}" class="s">开机引导的最终断言：容器+网络+防火墙就绪才启动容器</text>
  <text x="{x0+26}" y="{GY+GH-30}" class="s mono" style="font-size:9.5px">GROUP_DEP_boot="container net fw"</text>
  <text x="{x0+26}" y="{GY+GH-16}" class="s mono" style="font-size:9.5px">DEP_ct_boot=ct_config rootfs prepare_container lxc_zone snat</text>''')

# ---------- 组间箭头 + 绑定标注 ----------
ay = GY + GH / 2 - 40
for i in range(3):
    x1 = COLS[i][3] + COL_W
    x2 = COLS[i + 1][3]
    harrow(x1 + 4, x2 - 6, ay)
labels = [
    (COLS[0][3] + COL_W + 8, "GROUP_SEQ ①②③④"),
    (COLS[1][3] + COL_W + 8, "fw 绑 net"),
    (COLS[2][3] + COL_W + 8, "boot 绑 ①+②+③"),
]
for lx, lt in labels:
    p.append(f'<text x="{lx}" y="{ay-8}" class="s" style="font-size:9.5px;font-weight:600">{lt}</text>')

# ---------- 底部：机制图例 ----------
ly = GY + GH + 26
p.append(f'''
  <rect x="30" y="{ly}" width="{W-60}" height="142" rx="10" fill="#f7fafc" stroke="#cbd5e0" stroke-width="1"/>
  <text x="48" y="{ly+24}" class="b" style="font-size:13px">机制图例</text>''')
# 第一行：三类节点标签
lx = 48
for tag, desc in [(INSTALL, "install 类：verify=产物存在，缺才 build（一次性）"),
                  (ENSURE, "ensure 类：verify=目标状态，不符才 build（每次校准）"),
                  ("hard", "统一 hard：build 后复核，至多一次，一次不过即终止引导")]:
    tfg, tbg = TAG_STYLE[tag]
    p.append(f'<rect x="{lx}" y="{ly+36}" width="52" height="15" rx="7" fill="{tbg}"/>'
             f'<text x="{lx+26}" y="{ly+47}" text-anchor="middle" class="tag" fill="{tfg}">{tag}</text>'
             f'<text x="{lx+60}" y="{ly+47}" class="s">{desc}</text>')
    lx += 560
p.append(f'<text x="48" y="{ly+75}" class="s"><tspan class="b" fill="#c53030">阶段 3 A/B/C</tspan>：与 DAG ensure 同构一次修复——verify 就绪跳过 → fix 一次 → 复核，不过即 exit 1；开机并入 DAG boot 组（build_ct_boot 启动链前置检查），深修链 9 函数已删，修复止于 A/B 文件补写与注册</text>')
p.append(f'<text x="48" y="{ly+98}" class="s"><tspan class="b">失败沿链传播</tspan>：依赖未就绪 → 本级跳过且入 _failed → 下游连带跳过（跳过即未完成，不建半截）</text>'
         f'<text x="880" y="{ly+98}" class="s"><tspan class="b">flush_uci</tspan>：按 _dirty_* 分 network / dhcp / firewall 三组，每组至多一次 commit+reload，flush 后清脏标志</text>')
p.append(f'<text x="48" y="{ly+121}" class="s"><tspan class="b" fill="#c53030">运行期探针（v.82）</tspan>：只验证 last_pull（--probe-check 复用 bouncer_pulling 600s 新鲜度，与 step_C 同一判据），60s 巡检、连续停滞 3 轮 → 持同一把引导锁重跑 bootstrap 复验/修复；探针零修复动作，持锁期与开机引导互斥（lock-busy）</text>')

# ---------- 底部：声明即架构 ----------
py = ly + 142 + 22
p.append(f'''
  <rect x="30" y="{py}" width="{W-60}" height="86" rx="10" fill="#fff5f5" stroke="#fc8181" stroke-width="1"/>
  <text x="48" y="{py+24}" class="b" style="font-size:13px" fill="#c53030">声明即架构：dag_order() 三层校验（不合法直接终止，不带病引导）</text>
  <text x="48" y="{py+46}" class="s">① 每个小步骤必须 NODE_GROUP_&lt;node&gt; 归属一个大步骤——漏声明 / 归属组不在 GROUP_SEQ → 终止</text>
  <text x="48" y="{py+66}" class="s">② 组间依赖不得倒置：GROUP_DEP_&lt;g&gt; 绑定的组必须排在本组之前（fw 依赖 boot=倒置 → 终止）</text>
  <text x="880" y="{py+46}" class="s">③ 组内 Kahn 迭代拓扑排序：环 / 跨组依赖未就绪 → 终止</text>
  <text x="880" y="{py+66}" class="s">扩展方式：新步骤=写 verify_/build_ + 声明 NODE_GROUP/DEP，调度器零改动</text>''')

# ---------- 底部：阶段 3 A/B/C 服务链 ----------
qy = py + 86 + 24
p.append(f'''
  <rect x="30" y="{qy}" width="{W-60}" height="252" rx="10" fill="#fff5f5" stroke="#fc8181" stroke-width="1.2"/>
  <rect x="30" y="{qy}" width="{W-60}" height="32" rx="10" fill="#c53030"/>
  <rect x="30" y="{qy+22}" width="{W-60}" height="10" fill="#c53030"/>
  <text x="46" y="{qy+21}" class="gt" fill="#ffffff">阶段 3 · A/B/C 步骤化服务链（DAG 调度完成后执行：verify 就绪跳过 → fix 一次 → 复核，与 DAG ensure 同构，一次不过即 hard 终止）</text>
  <text x="{W-46}" y="{qy+21}" text-anchor="end" class="gts" fill="#ffffff">shield 仅 _recovering（新装/重恢复）时执行 · enroll 除外 · C 失败判损坏 → tier 3 重装自愈</text>''')

P3_STEPS = [
    ("shield", "新装恢复中先断中央 API", "online_client 已注释", "ensure_online_client_off", "仅 _recovering 时执行"),
    ("stamp 分流", "阶段 3 入口判别", "安装态：A→B→C 依序构造", "_stamp_present：有 stamp→重启态", "重启态 A/B 不治理，直接 C"),
    ("A 容器内配置", "网络文件/自启/resolv/acquis/日志", "fix_A 按需补写+重启 crowdsec", "verify_A · fix_A", "幂等写入，缺啥补啥"),
    ("B 配置与 bouncer 链路", "三文件+服务活+nft+注册态", "fix_B：补写+屏蔽 CAPI+注册+起服务", "verify_B · fix_B", "LAPI 不可达→记日志放行"),
    ("C last_pull 验证", "等 LAPI 90s + pull 600s 新鲜度", "无修复：60s 纯等待 → 决策树", "step_C · _sc_wait_pull", "复验 A/B→一次修复→判损坏"),
    ("online_client 放出", "config 中 online_client 未注释", "ensure_online_client_on", "verify_online_client_on", "取消注释放出 CAPI"),
    ("console enroll", "capi status 已 Enrolled", "re_enroll", "phase3_step_enroll", "等网站 Accept 算过"),
]
_cw = 222; _cgap = 17; _cx0 = 52
_cy = qy + 46
for i, (nm, ver, fix, note, note2) in enumerate(P3_STEPS):
    x = _cx0 + i * (_cw + _cgap)
    p.append(f'''
  <rect x="{x}" y="{_cy}" width="{_cw}" height="82" rx="6" fill="#ffffff" stroke="#cbd5e0" stroke-width="1"/>
  <text x="{x+10}" y="{_cy+16}" class="b" style="font-size:11px">{nm}</text>
  <text x="{x+10}" y="{_cy+32}" class="s" style="font-size:8.5px">验：{ver}</text>
  <text x="{x+10}" y="{_cy+47}" class="s" style="font-size:8.5px">修：{fix}</text>
  <text x="{x+10}" y="{_cy+62}" class="s mono" style="font-size:8px;fill:#a0aec0">{note}</text>
  <text x="{x+10}" y="{_cy+76}" class="s mono" style="font-size:8px;fill:#a0aec0">{note2}</text>''')
    if i < 6:
        p.append(f'<line x1="{x+_cw+3}" y1="{_cy+41}" x2="{x+_cw+_cgap-3}" y2="{_cy+41}" class="ln" marker-end="url(#ar)"/>')

_ey = _cy + 82 + 22
p.append(f'<text x="46" y="{_ey}" class="s" style="font-size:10px"><tspan class="b">与 DAG 同构（一次修复）</tspan>：verify 就绪跳过 → fix 一次 → 复核，不过即 hard；开机并入 DAG boot 组（build_ct_boot 启动链内容级前置检查：缺链不开机、不重写、不重建），深修链 9 函数已删</text>')
p.append(f'<text x="46" y="{_ey+20}" class="s" style="font-size:10px"><tspan class="b">A/B/C 划分</tspan>：A=容器内配置治理（网络文件/自启软链/resolv/acquis+解析器/日志转发）；B=crowdsec 配置与 bouncer 链路（listen_uri/trusted_ips/容器 config/宿主机服务活/nft 表/注册态）；C=last_pull 验证（纯等待 + 600s 新鲜度）</text>')
p.append(f'<text x="46" y="{_ey+40}" class="s" style="font-size:10px"><tspan class="b">合法中间态与门</tspan>：enroll 命令成功但 10 秒内未显示 Enrolled（等网站人工 Accept）算通过；未配置注册码（$ENROLL_KEY_FILE 为空）→ 明确记日志跳过，本地防护不受影响</text>')
p.append(f'<text x="46" y="{_ey+60}" class="s" style="font-size:10px"><tspan class="b">日志形态</tspan>：[阶段3] 无 installed 标记：安装态，依序执行 A → B → C ／ [步骤C] A/B 状态均正常：容器配置正确，判定容器损坏，转入重装自愈 ／ [步骤A] 一次修复未通过复核，hard 失败，引导终止</text>')
p.append(f'<text x="46" y="{_ey+80}" class="s" style="font-size:10px"><tspan class="b" fill="#c53030">tier 3 重装自愈（v.81）</tspan>：C 失败且 A/B 复验正常（含一次修复后仍失效）= 配置正确但 LAPI 不可达 = 容器损坏 → 五道门（last_pull 仍失效 / installed 标记在位 / 失败计数 &lt; 2 / 非重装后流程 / 镜像 gzip -t）全过才抹 rootfs 重跑；安装态门② 必拒，防开机反复重置</text>')

p.append('</svg>')
svg = "\n".join(p)
with open(SVG, "w", encoding="utf-8") as f:
    f.write(svg)
print(f"written: {SVG} ({W}x{H})")

# ---- 渲染 PNG（2x 高清，crop 精确尺寸，quantize 压缩）----
html = os.path.join(OUT_DIR, "render-dag.html")
with open(html, "w", encoding="utf-8") as f:
    f.write(f'''<!DOCTYPE html><html><head><meta charset="utf-8"><style>
html,body{{margin:0;padding:0;background:#ffffff}}
img{{display:block;width:{W}px;height:{H}px}}
</style></head><body><img src="file://{SVG}"></body></html>''')

shot = os.path.join(OUT_DIR, "_dag_shot.png")
subprocess.run([
    "chromium", "--headless", "--disable-gpu", "--no-sandbox",
    "--hide-scrollbars", "--default-background-color=FFFFFFFF",
    f"--window-size={W},{H + 100}", "--force-device-scale-factor=2",
    f"--screenshot={shot}", f"file://{html}",
], check=True, capture_output=True, timeout=180)

from PIL import Image  # noqa: E402

im = Image.open(shot).convert("RGB")
im = im.crop((0, 0, W * 2, H * 2))
im = im.quantize(colors=256, method=Image.MEDIANCUT, dither=Image.FLOYDSTEINBERG).convert("RGB")
im.save(PNG, optimize=True)
print(f"written: {PNG} ({im.size[0]}x{im.size[1]}, {os.path.getsize(PNG) // 1024} KB)")

os.remove(html)
os.remove(shot)
print("done")
