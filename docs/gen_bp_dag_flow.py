"""生成旁路由版「七大步骤链式置位」架构图 SVG + PNG

对应 crowdsec-lxc-bootstrap.sh（旁路由版，2026-10-19.90-bp）。
内容：7 个大步骤链式门禁（GSET_* 置位）、19 个小步骤归属、
      无复核范式（验 → 缺则建一次 → 返回）、失败分支与重装自愈。

用法：python3 gen_bp_dag_flow.py
产物：bp-seven-step-flow.svg / bp-seven-step-flow.png
"""
import cairosvg

W, H = 1240, 1560

# 7 大步骤：键、标题、小步骤、配色
GROUPS = [
    ("INSTALL", "安装容器（含 CrowdSec）并验证安装",
     ["img_migrate", "rootfs", "ct_config"], "#2b6cb0"),
    ("NETWORK", "验证桥信息 / 容器网络 config / 系统日志推送",
     ["br_lan_ports", "lan_static", "dhcp_ignore", "wan_port", "dns_domain",
      "bridge", "lxc_zone", "fwd_rules", "wan_input", "lan_input", "snat",
      "ip_forward"], "#2f855a"),
    ("BOOT", "启动容器并验证 cgroup 挂载", ["ct_boot"], "#6b46c1"),
    ("CONFIGURE", "验证容器内日志 / 解析器 / 白名单 / 屏蔽 CAPI",
     ["prepare_container", "svc_bind", "docker_fw"], "#b7791f"),
    ("BOUNCER", "获取 bouncer 并与路由器 bouncer 联动",
     ["bouncer_ensure", "bouncer_link"], "#c05621"),
    ("VERIFY", "验证 bouncer 列表生效并解开 CAPI",
     ["lapi_ready", "bouncer_list"], "#9c4221"),
    ("ENROLL", "Console Enroll", ["console_enroll"], "#285e61"),
]

P = []
A = P.append

A(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">')
A('''<style>
  .t  { font: 600 21px "Noto Sans CJK SC",sans-serif; fill:#1a202c; }
  .ts { font: 400 12.5px "Noto Sans CJK SC",sans-serif; fill:#4a5568; }
  .g  { font: 700 15px "JetBrains Mono","Consolas",monospace; }
  .gt { font: 500 12px "Noto Sans CJK SC",sans-serif; fill:#2d3748; }
  .n  { font: 400 11px "JetBrains Mono","Consolas",monospace; fill:#2d3748; }
  .lg { font: 400 12px "Noto Sans CJK SC",sans-serif; fill:#2d3748; }
  .lb { font: 600 12px "Noto Sans CJK SC",sans-serif; }
</style>''')
A(f'<rect width="{W}" height="{H}" fill="#ffffff"/>')

# 标题
A(f'<text x="{W//2}" y="38" text-anchor="middle" class="t">旁路由版 · 七大步骤链式置位</text>')
A(f'<text x="{W//2}" y="60" text-anchor="middle" class="ts">'
  'crowdsec-lxc-bootstrap.sh（旁路由版 · 2026-10-19.90-bp）· '
  '每组先验前面所有组 GSET_* = 1 才执行，全通才置位</text>')

# 顶部决策条
A('<rect x="40" y="80" width="1160" height="54" rx="7" fill="#f7fafc" stroke="#cbd5e0"/>')
A('<text x="60" y="102" class="lb" fill="#2b6cb0">执行门禁：</text>')
A('<text x="60" y="122" class="lg">'
  'for gd in $GROUP_DEP_&lt;g&gt;：若 GSET_&lt;gd&gt; != 1 → 整组跳过，不置位（后续组连带跳过）</text>')
A('<text x="700" y="102" class="lb" fill="#2f855a">置位条件：</text>')
A('<text x="700" y="122" class="lg">组内 19→N 个小步骤全部通过 → GSET_&lt;g&gt;=1；任一失败 → 绝不置位</text>')

y = 158
GX, GW = 40, 1160
ROW_H = 150

for idx, (key, title, nodes, color) in enumerate(GROUPS, 1):
    n = len(nodes)
    A(f'<rect x="{GX}" y="{y}" width="{GW}" height="{ROW_H}" rx="8" '
      f'fill="#ffffff" stroke="{color}" stroke-width="1.6"/>')
    A(f'<rect x="{GX}" y="{y}" width="6" height="{ROW_H}" rx="3" fill="{color}"/>')

    # 序号圆
    A(f'<circle cx="{GX+34}" cy="{y+27}" r="15" fill="{color}"/>')
    A(f'<text x="{GX+34}" y="{y+32}" text-anchor="middle" '
      f'font="700 15px sans-serif" fill="#ffffff">{idx}</text>')
    # 组键（全大写）
    A(f'<text x="{GX+58}" y="{y+33}" class="g" fill="{color}">{key}</text>')
    # 组标题
    A(f'<text x="{GX+58}" y="{y+54}" class="gt">{title}</text>')
    # 小步骤计数
    A(f'<text x="{GX+GW-16}" y="{y+33}" text-anchor="end" class="ts">{n} 个小步骤</text>')

    # 小步骤标签（自动换行）
    per_row = 6
    for i, nd in enumerate(nodes):
        r, c = divmod(i, per_row)
        bx = GX + 58 + c * 178
        by = y + 72 + r * 30
        A(f'<rect x="{bx}" y="{by}" width="168" height="23" rx="4" '
          f'fill="#f7fafc" stroke="#e2e8f0"/>')
        A(f'<text x="{bx+8}" y="{by+16}" class="n">{nd}</text>')

    # 置位标注
    A(f'<text x="{GX+58}" y="{y+ROW_H-12}" class="lb" fill="{color}">'
      f'全通 → GSET_{key.lower()}=1</text>')
    A(f'<text x="{GX+300}" y="{y+ROW_H-12}" class="ts">'
      f'前置：{"（无，首组）" if idx == 1 else " + ".join(g[0] for g in GROUPS[:idx-1])}</text>')

    # 组间箭头
    if idx < len(GROUPS):
        cx = GX + GW // 2
        A(f'<path d="M {cx} {y+ROW_H} L {cx} {y+ROW_H+14}" stroke="#a0aec0" '
          f'stroke-width="1.6" marker-end="url(#ar)"/>')
        A(f'<text x="{cx+10}" y="{y+ROW_H+11}" class="ts">GSET 已置位？</text>')

    y += ROW_H + 18

# 箭头定义
A('''<defs>
  <marker id="ar" markerWidth="9" markerHeight="9" refX="7" refY="4.5" orient="auto">
    <path d="M0,0 L9,4.5 L0,9 z" fill="#a0aec0"/>
  </marker>
</defs>''')

# 底部两块：无复核范式 + 失败分支
BY = y + 6
A(f'<rect x="40" y="{BY}" width="565" height="118" rx="7" fill="#f0fff4" stroke="#38a169"/>')
A(f'<text x="58" y="{BY+24}" class="lb" fill="#276749">单步范式（无复核）</text>')
A(f'<text x="58" y="{BY+46}" class="lg">verify 内容一致 → 跳过，零构建</text>')
A(f'<text x="58" y="{BY+68}" class="lg">verify 不符 → build 一次 → 直接返回</text>')
A(f'<text x="58" y="{BY+90}" class="lg">build 返回非零 → hard 失败，exit 1</text>')
A(f'<text x="58" y="{BY+110}" class="ts" fill="#c53030">'
  '关键：构建后不再复查，避免重启时重复构建</text>')

A(f'<rect x="625" y="{BY}" width="575" height="118" rx="7" fill="#fffaf0" stroke="#dd6b20"/>')
A(f'<text x="643" y="{BY+24}" class="lb" fill="#9c4221">失败分支</text>')
A(f'<text x="643" y="{BY+46}" class="lg">小步骤 build 失败 → hard，引导终止</text>')
A(f'<text x="643" y="{BY+68}" class="lg">重启时 rg_restart_verify 逐组复验</text>')
A(f'<text x="643" y="{BY+90}" class="lg">不可修复 → full_reinstall 彻底重建容器</text>')
A(f'<text x="643" y="{BY+110}" class="ts" fill="#9c4200">'
  '五道门：last_pull 恢复 / 无 stamp / 计数满 / 递归 / 镜像坏 → 全拒</text>')

# 旁路由专属标注
BY2 = BY + 132
A(f'<rect x="40" y="{BY2}" width="1160" height="74" rx="7" fill="#ebf8ff" stroke="#3182ce"/>')
A(f'<text x="58" y="{BY2+24}" class="lb" fill="#2c5282">旁路由专属语义（本仓锁定，无模式开关）</text>')
A(f'<text x="58" y="{BY2+46}" class="lg">'
  '所有物理网口 → br-lan；wan / wan6 一律 disabled=1（不抢上游拨号）；lan.ignore=1（不跑 DHCP 服务）</text>')
A(f'<text x="58" y="{BY2+66}" class="lg">'
  '不写 wan.proto、不设 wan.device —— 只禁用不重配，出口经上游网关</text>')

A('</svg>')

svg = "\n".join(P)
open("bp-seven-step-flow.svg", "w").write(svg)
cairosvg.svg2png(bytestring=svg.encode(), write_to="bp-seven-step-flow.png",
                 output_width=W * 2, output_height=H * 2, background_color="white")
print("已生成 bp-seven-step-flow.svg / bp-seven-step-flow.png")
