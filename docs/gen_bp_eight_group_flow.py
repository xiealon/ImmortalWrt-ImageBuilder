"""生成旁路由版「八组链式置位 · 大步骤 / 小步骤细分」架构图 SVG + PNG

对应 crowdsec-lxc-bootstrap.sh（旁路由版，2026-10-20.104-bp）。

本版（v2）相对上一版的修正：
  · ENROLL 组不再画虚构的 console_enroll 节点 —— 脚本里 ENROLL_NODES 为空，
    该组的 verify/build 是「注册码文件在 → 查是否已 Enrolled；不在 → 直接算就绪」；
  · 单步范式拆成两套真实语义：
        ensure   ：build 后「复核」一次，复核不过 → hard
        rg_step  ：build 后「复核」（重启态服务链，一次修复 → 复核 → 不过即 hard）
    以及 restart 逐组复验的语义；
  · 每组补「会真修 / 只验不写」标签（v.95 起全部会真修），标清谁写谁读；
  · 底部补「写入清单」与「引导锁 / 探针」两块，覆盖 rc.local 与运行期。

用法：python3 gen_bp_eight_group_flow.py
产物：bp-eight-group-flow.svg / bp-eight-group-flow.png
"""
import cairosvg

W = 1400
GX, GW = 40, W - 80
PER_ROW = 6

# 组定义：键、标题、小步骤、配色、前置组、备注（写什么 / 是否 hard）
GROUPS = [
    ("PREP", "容器启动前的全部静态准备（路由器网桥 / 容器网络 / cgroup / 防火墙）",
     ["br_lan_ports", "lan_static", "dhcp_ignore", "dns_domain",
      "bridge", "ct_net", "cgroup_mount", "ct_bootlink", "lxc_auto", "ct_resolv",
      "lxc_zone", "fwd_rules", "lan_input", "snat",
      "ip_forward", "svc_bind", "docker_fw"], "#2f855a", "",
     "17 项全部会真修 · 写 network/dhcp/firewall 三面 + ip_forward，改完 commit + 分组 reload 即生效"),
    ("INSTALL", "安装容器（校验镜像完整性 / 解压 rootfs / 校验 config）",
     ["img_migrate", "rootfs", "ct_config"], "#2b6cb0", "",
     "全部会真修 · img_migrate 不只查文件在，还要 gzip -t 过完整性"),
    ("CAPIBLOCK", "屏蔽 CAPI（容器内 online_client 停用）",
     ["capi_block"], "#b7791f", "INSTALL PREP",
     "会真修 · 必须在 BOOT 之前：config.yaml 是开机读一次的"),
    ("BOOT", "启动容器（全程唯一一次开机）",
     ["ct_boot"], "#6b46c1", "PREP INSTALL CAPIBLOCK",
     "会真修 · 依赖含 snat：没 SNAT 就不开机（开了也是出不去的容器）"),
    ("LOGCONF", "日志与解析器（宿主机推送 + 容器内采集解析）",
     ["acquis", "log_forward"], "#c05621", "BOOT",
     "会真修 · acquis 查内容级：5 个顶层键 / 3 处 failed-auth / 2 处 auth_success"),
    ("LAPI", "取 LAPI 地址并填入路由器 bouncer",
     ["lapi_fetch", "bouncer_fill"], "#2c7a7b", "BOOT",
     "会真修 · 填 api_url/api_key 后重启宿主机 bouncer（详见 lapi-group-flow 细部图）"),
    ("BOUNCERVERIFY", "验证 bouncer 真在拉，再解开 CAPI",
     ["bouncer_verify", "capi_release"], "#9c4221", "LOGCONF LAPI",
     "会真修 · 「注册过」≠「真的在拉」：看 last_pull 新鲜度（600s）"),
    ("ENROLL", "Console Enroll（注册码文件缺失即视为就绪，直接通过）",
     [], "#285e61", "BOUNCERVERIFY",
     "无独立小步骤 · 动作在 verify_ENROLL / build_ENROLL 里 · re_enroll 前会先 rebuild snat"),
]

P = []
A = P.append

# ---------- 先算总高度 ----------
ROW_BASE = 96          # 组头 + 首行小步骤
ROW_STEP = 30          # 每多一行小步骤
ROW_TAIL = 52          # 置位 + 前置 + 备注 三行
GAP = 18

y_probe = 152
h_probe = 72
_y = y_probe + h_probe + 14
for key, title, nodes, color, deps, note in GROUPS:
    n = max(1, len(nodes))
    _rows = (n + PER_ROW - 1) // PER_ROW
    _y += ROW_BASE + (_rows - 1) * ROW_STEP + ROW_TAIL + GAP

y = y_probe + h_probe + 14      # 绘制起点（不能复用上面累加后的 _y）
y_bottom = _y + 6
H = y_bottom + 150 + 132 + 30

A(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">')
A('''<style>
  .t  { font: 600 23px "Noto Sans CJK SC",sans-serif; fill:#1a202c; }
  .ts { font: 400 12.5px "Noto Sans CJK SC",sans-serif; fill:#4a5568; }
  .g  { font: 700 16px "JetBrains Mono","Consolas",monospace; }
  .gt { font: 500 12.5px "Noto Sans CJK SC",sans-serif; fill:#2d3748; }
  .n  { font: 400 11.5px "JetBrains Mono","Consolas",monospace; fill:#2d3748; }
  .lg { font: 400 12px "Noto Sans CJK SC",sans-serif; fill:#2d3748; }
  .lb { font: 600 12.5px "Noto Sans CJK SC",sans-serif; }
  .sm { font: 400 11px "Noto Sans CJK SC",sans-serif; fill:#4a5568; }
</style>''')
A(f'<rect width="{W}" height="{H}" fill="#ffffff"/>')

# ---------- 标题 ----------
A(f'<text x="{W//2}" y="38" text-anchor="middle" class="t">旁路由版 · 八组链式置位（大步骤 / 小步骤细分）</text>')
A(f'<text x="{W//2}" y="60" text-anchor="middle" class="ts">'
  'crowdsec-lxc-bootstrap.sh · 2026-10-20.104-bp · 8 个组 / 29 个小步骤 · '
  '每组先验前置组 GSET_*（非空）才执行，全通才置位</text>')

# ---------- 执行门禁条 ----------
A(f'<rect x="{GX}" y="78" width="{GW}" height="58" rx="7" fill="#f7fafc" stroke="#cbd5e0"/>')
A(f'<text x="{GX+18}" y="100" class="lb" fill="#2b6cb0">执行门禁：</text>')
A(f'<text x="{GX+18}" y="120" class="lg">'
  '遍历 GROUP_DEP_&lt;g&gt;：任一前置组 GSET_&lt;gd&gt; != 1 → 整组不执行、不置位（下游连带跳过）</text>')
A(f'<text x="{GX+700}" y="100" class="lb" fill="#2f855a">置位条件：</text>')
A(f'<text x="{GX+700}" y="120" class="lg">'
  '组内小步骤全部通过 → GSET_&lt;g&gt;=1；任一未通过 → 绝不置位</text>')

# ---------- 运行期探针（在最上方，因为它在安装完成后才起作用） ----------
A(f'<rect x="{GX}" y="{y_probe}" width="{GW}" height="{h_probe}" rx="7" fill="#faf5ff" stroke="#805ad5"/>')
A(f'<text x="{GX+18}" y="{y_probe+24}" class="lb" fill="#553c9a">运行期探针 crowdsec-lxc-probe（init.d START=99）</text>')
A(f'<text x="{GX+18}" y="{y_probe+48}" class="lg">'
  '每 60s 问 bootstrap --probe-check：无 installed 标记 → 静默等待 · 引导锁被占 → 本轮跳过 · '
  '连续 3 轮停滞且过 600s 冷却 → 持同一把锁拉起 bootstrap</text>')
A(f'<text x="{GX+GW-18}" y="{y_probe+34}" text-anchor="end" class="ts" fill="#c53030">'
  '只报不修 · 修复逻辑全部复用 bootstrap，永不同时跑两个</text>')

# ---------- 8 个组 ----------
for idx, (key, title, nodes, color, deps, note) in enumerate(GROUPS, 1):
    n = len(nodes)
    _rows = max(1, (n + PER_ROW - 1) // PER_ROW)
    ROW_H = ROW_BASE + (_rows - 1) * ROW_STEP + ROW_TAIL

    A(f'<rect x="{GX}" y="{y}" width="{GW}" height="{ROW_H}" rx="8" '
      f'fill="#ffffff" stroke="{color}" stroke-width="1.6"/>')
    A(f'<rect x="{GX}" y="{y}" width="6" height="{ROW_H}" rx="3" fill="{color}"/>')

    # 序号 + 组名 + 标题
    A(f'<circle cx="{GX+36}" cy="{y+28}" r="16" fill="{color}"/>')
    A(f'<text x="{GX+36}" y="{y+34}" text-anchor="middle" '
      f'font-weight="700" font-size="16" fill="#ffffff" font-family="sans-serif">{idx}</text>')
    A(f'<text x="{GX+62}" y="{y+34}" class="g" fill="{color}">{key}</text>')
    A(f'<text x="{GX+62}" y="{y+56}" class="gt">{title}</text>')

    # 右侧：小步骤数 + 前置
    A(f'<text x="{GX+GW-18}" y="{y+28}" text-anchor="end" class="lb" fill="{color}">'
      f'{n} 个小步骤</text>')
    A(f'<text x="{GX+GW-18}" y="{y+48}" text-anchor="end" class="sm">'
      f'前置：{deps if deps else "（无，独立入口）"}</text>')

    # 小步骤方块
    if nodes:
        for i, nd in enumerate(nodes):
            r, c = divmod(i, PER_ROW)
            bx = GX + 62 + c * 208
            by = y + 72 + r * ROW_STEP
            A(f'<rect x="{bx}" y="{by}" width="196" height="23" rx="4" '
              f'fill="#f7fafc" stroke="#e2e8f0"/>')
            A(f'<text x="{bx+9}" y="{by+16}" class="n">{nd}</text>')
    else:
        A(f'<rect x="{GX+62}" y="{y+72}" width="1180" height="23" rx="4" '
          f'fill="#f0fff4" stroke="#c6f6d5" stroke-dasharray="4 3"/>')
        A(f'<text x="{GX+71}" y="{y+88}" class="sm" fill="#276749">'
          '（ENROLL_NODES 为空：不排小步骤，动作由组自身 verify / build 承担）</text>')

    # 置位标注
    A(f'<text x="{GX+62}" y="{y+ROW_H-30}" class="lb" fill="{color}">'
      f'全通 → GSET_{key.lower()}=1</text>')
    # 备注
    A(f'<text x="{GX+62}" y="{y+ROW_H-11}" class="ts">{note}</text>')

    # 组间箭头
    if idx < len(GROUPS):
        cx = GX + GW // 2
        A(f'<path d="M {cx} {y+ROW_H} L {cx} {y+ROW_H+GAP-4}" stroke="#a0aec0" '
          f'stroke-width="1.6" marker-end="url(#ar)"/>')

    y += ROW_H + GAP

A('''<defs>
  <marker id="ar" markerWidth="9" markerHeight="9" refX="7" refY="4.5" orient="auto">
    <path d="M0,0 L9,4.5 L0,9 z" fill="#a0aec0"/>
  </marker>
</defs>''')

# ---------- 底部：单步范式 + 失败分支 ----------
BY = y_bottom
A(f'<rect x="{GX}" y="{BY}" width="650" height="142" rx="7" fill="#f0fff4" stroke="#38a169"/>')
A(f'<text x="{GX+18}" y="{BY+24}" class="lb" fill="#276749">单步范式（两套语义，别混）</text>')
A(f'<text x="{GX+18}" y="{BY+46}" class="lg">'
  'ensure（开机 DAG 用）：verify 通过 → 跳过；否则 build → <tspan font-weight="600">再复核一次</tspan></text>')
A(f'<text x="{GX+18}" y="{BY+67}" class="lg">'
  '　　build 失败 或 复核仍不符 → hard 失败，exit 1</text>')
A(f'<text x="{GX+18}" y="{BY+89}" class="lg">'
  'rg_step（重启态服务链用）：verify 通过 → 跳过；否则修复一次 → 复核</text>')
A(f'<text x="{GX+18}" y="{BY+110}" class="lg">'
  '　　复核不过 → hard 失败，引导终止</text>')
A(f'<text x="{GX+18}" y="{BY+132}" class="ts" fill="#c53030">'
  'v.95/v.97：18 个节点全部「验证 + 修改」，RO_ONLY_NODES 已清空，没有只验不写的了</text>')

A(f'<rect x="{GX+668}" y="{BY}" width="{GW-668}" height="142" rx="7" fill="#fffaf0" stroke="#dd6b20"/>')
A(f'<text x="{GX+686}" y="{BY+24}" class="lb" fill="#9c4221">失败分支与重装自愈</text>')
A(f'<text x="{GX+686}" y="{BY+46}" class="lg">小步骤 build 失败 → hard，引导终止</text>')
A(f'<text x="{GX+686}" y="{BY+67}" class="lg">重启态按组复验：缺哪个补哪个，补不上就彻底重装</text>')
A(f'<text x="{GX+686}" y="{BY+89}" class="lg">彻底重装 = 强停容器 → 抹 rootfs → 重新解压 → 自执行</text>')
A(f'<text x="{GX+686}" y="{BY+110}" class="ts" fill="#9c4200">'
  '五道门（任一不过即放弃重装）：</text>')
A(f'<text x="{GX+686}" y="{BY+132}" class="ts" fill="#9c4200">'
  'last_pull 已恢复 / 无 installed 标记 / 失败计数满 2 次 / 本次已是重装 / 镜像 gzip -t 不过</text>')

# ---------- 底部：写入清单 + 旁路由语义 ----------
BY2 = BY + 158
A(f'<rect x="{GX}" y="{BY2}" width="650" height="150" rx="7" fill="#ebf8ff" stroke="#3182ce"/>')
A(f'<text x="{GX+18}" y="{BY2+24}" class="lb" fill="#2c5282">脚本真正会写的东西（写完必 commit + 分组 reload）</text>')
A(f'<text x="{GX+18}" y="{BY2+46}" class="ts" fill="#2c5282">'
  'network：bridge ports / lan 静态地址 / 删 wan+wan6 段 → network reload</text>')
A(f'<text x="{GX+18}" y="{BY2+66}" class="ts" fill="#2c5282">'
  'dhcp：lan.ignore / time.android.com 的 domain 段 → dnsmasq restart</text>')
A(f'<text x="{GX+18}" y="{BY2+86}" class="ts" fill="#2c5282">'
  'firewall：lxc zone+3 条 forwarding / wan·lan input / SNAT / docker → firewall reload</text>')
A(f'<text x="{GX+18}" y="{BY2+106}" class="ts" fill="#2c5282">'
  'dropbear·ttyd 绑定接口 / system 的 log_ip / crowdsec 的 api_url·api_key</text>')
A(f'<text x="{GX+18}" y="{BY2+128}" class="ts" fill="#c53030">'
  'reload 失败只记日志不 hard（已落盘）；改完复核不过一定 hard，不设回滚</text>')
A(f'<text x="{GX+18}" y="{BY2+148}" class="ts" fill="#c53030">'
  '改 br-lan / lan 地址前先判 SSH 来源：可能失联就明确警告（不拦截）</text>')

A(f'<rect x="{GX+668}" y="{BY2}" width="{GW-668}" height="120" rx="7" fill="#fff5f5" stroke="#e53e3e"/>')
A(f'<text x="{GX+686}" y="{BY2+24}" class="lb" fill="#9b2c2c">旁路由专属语义（本仓锁定，无模式开关）</text>')
A(f'<text x="{GX+686}" y="{BY2+46}" class="lg">所有物理网口 → br-lan；WAN 段整段删除（不是 disabled=1）</text>')
A(f'<text x="{GX+686}" y="{BY2+67}" class="lg">lan.ignore=1（不跑 DHCP）；出口经上游网关，本机不拨号</text>')
A(f'<text x="{GX+686}" y="{BY2+88}" class="ts" fill="#c53030">'
  '为什么必须删：fw4（nft）不认 disabled，段还在就仍会起接口、挂 WAN zone</text>')
A(f'<text x="{GX+686}" y="{BY2+110}" class="ts" fill="#c53030">'
  'SNAT 是容器出网生命线：缺它上游不认识容器网段，包直接被丢</text>')

A('</svg>')

svg = "\n".join(P)
open("bp-eight-group-flow.svg", "w").write(svg)
cairosvg.svg2png(bytestring=svg.encode(), write_to="bp-eight-group-flow.png",
                 output_width=W * 2, output_height=H * 2, background_color="white")
print(f"已生成 bp-eight-group-flow.svg / bp-eight-group-flow.png  ({W}x{H})")
