#!/usr/bin/env python3
"""生成 BACKUP 仓「v.81 容器内构建七步 ensure+hard 全貌图」SVG + 高清 PNG
内容：crowdsec-lxc-bootstrap.sh（v.81 · 旁路由锁定线）boot 组 prepare_container
节点内部——「构建 crowdsec 的每一步」独立闭环：
  ① 容器网络文件（IP/网关/DNS）   ② 自启软链与机器身份   ③ resolv.conf
  ④ 日志源与解析器（acquis/parsers） ⑤ listen_uri 监听地址
  ⑥ trusted_ips 网桥地址          ⑦ 容器 config 落盘
    每步：verify 就绪跳过 → 一次构建+复核 → 不过即 hard（exit 1 终止引导）
    （v.81 起一次修复：安装顺序保证前置已就绪，多修一次没必要）
右侧：单步内部机制（ensure_sub）——与 DAG ensure() 同构，
  但不写 _done/_dirty/_failed（v.81 起外层 prepare_container 同为一次机会）
底部：设计理由 + 为什么只修一次 + 与阶段 3 A/B 的归口 + enroll 例外

用法: python3 gen_cs_build_flow.py
  输出: 同目录 cs-build-flow.svg / cs-build-flow.png（2x 高清，已裁精确尺寸）
"""
import os
import subprocess

W, H = 1020, 1080
OUT_DIR = os.path.dirname(os.path.abspath(__file__))
SVG = os.path.join(OUT_DIR, "cs-build-flow.svg")
PNG = os.path.join(OUT_DIR, "cs-build-flow.png")

# 配色（与 dag-flow 同源）：boot 组紫为构建链主色
MAIN_FG, MAIN_BG, MAIN_BD = "#6b46c1", "#faf5ff", "#d6bcfa"   # 紫（boot 组）
TAG_ENSURE = ("#2b6cb0", "#bee3f8")   # 蓝（ensure 语义）
HARD_FG, HARD_BG, HARD_BD = "#c53030", "#fff5f5", "#fc8181"  # 红（hard）

# 七步：编号、名称、验（verify 判定要点）、建（build 函数）、mono 备注
STEPS = [
    ("①", "容器网络文件（IP/网关/DNS）",
     "10-eth0.network 三值：Address=CONTAINER_IP/24 · Gateway=BRIDGE_IP · DNS 一致",
     "setup_container_network", "verify_sub_ct_net"),
    ("②", "自启软链与机器身份",
     "multi-user.target.wants 软链（rootfs 内有 service 文件才要求）· hostname=crowdsec · machine-id",
     "setup_container_boot", "verify_sub_ct_bootlink"),
    ("③", "resolv.conf",
     "内容 = nameserver「容器 DNS」（custom_router_dns.txt → BRIDGE_IP → 10.1.0.1 回落链）",
     "setup_resolv", "verify_sub_ct_resolv"),
    ("④", "日志源与解析器（acquis/parsers）",
     "acquis.d/router.yaml · parsers/s01-parse/openwrt-dropbear.yaml · parsers/s02-enrich/openwrt-whitelist.yaml",
     "setup_acquis", "verify_sub_cs_acquis"),
    ("⑤", "listen_uri 监听地址",
     "config.yaml 的 listen_uri = 0.0.0.0:LAPI_PORT（bouncer 要经网桥连进来）",
     "ensure_listen_uri", "verify_sub_cs_listen"),
    ("⑥", "trusted_ips 网桥地址",
     "config.yaml 的 trusted_ips 含 BRIDGE_IP（放行容器网段来源的 API 调用）",
     "ensure_trusted_ip", "verify_sub_cs_trusted"),
    ("⑦", "容器 config 落盘",
     "$CFG 内容完整：rootfs.path / utsname / net.0.type 三键在位（不只验文件名）",
     "apply_cfg（原子写 tmp + 非空校验才落盘；lxc-info 解析 trim）",
     "verify_sub_ct_cfg · apply_cfg"),
]

p = []
p.append(f'''<svg width="{W}" height="{H}" viewBox="0 0 {W} {H}" xmlns="http://www.w3.org/2000/svg" font-family="-apple-system,'PingFang SC','Microsoft YaHei','Noto Sans CJK SC',sans-serif">
  <defs>
    <marker id="ar" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
      <path d="M 0 0 L 10 5 L 0 10 z" fill="#94a3b8"/>
    </marker>
  </defs>
  <style>
    .t{{font-size:19px;font-weight:700;fill:#1a202c}}
    .ts{{font-size:11.5px;fill:#718096}}
    .b{{font-size:12px;font-weight:600;fill:#1a202c}}
    .s{{font-size:10px;fill:#4a5568}}
    .mono{{font-family:ui-monospace,'SFMono-Regular',Consolas,monospace}}
    .ln{{stroke:#94a3b8;stroke-width:1.5;fill:none}}
    .tag{{font-size:9px;font-weight:700}}
  </style>
  <rect x="0" y="0" width="{W}" height="{H}" fill="#ffffff"/>''')

# ---------- 标题 ----------
p.append(f'''
  <text x="{W//2}" y="30" text-anchor="middle" class="t">v.81 容器内构建七步 ensure+hard 全貌（构建 crowdsec 的每一步 · BACKUP 旁路由锁定线）</text>
  <text x="{W//2}" y="52" text-anchor="middle" class="ts">boot 组 prepare_container 节点内部：每步 verify 就绪跳过 → 构建 → 复核，至多一次，一次不过即 hard 终止引导</text>''')

LX, LW = 36, 640          # 左列（七步链）
RX, RW = 700, 284         # 右列（单步内部机制）
CY0, CH, CGAP = 96, 86, 26   # 卡起始 y / 卡高 / 卡间（箭头）距

def step_card(x, y, w, num, name, ver, build, note):
    p.append(f'''
  <rect x="{x}" y="{y}" width="{w}" height="{CH}" rx="8" fill="#ffffff" stroke="#cbd5e0" stroke-width="1"/>
  <circle cx="{x+24}" cy="{y+21}" r="12" fill="{MAIN_BG}" stroke="{MAIN_BD}" stroke-width="1.2"/>
  <text x="{x+24}" y="{y+25}" text-anchor="middle" class="b" fill="{MAIN_FG}" style="font-size:12px">{num}</text>
  <text x="{x+44}" y="{y+25}" class="b" style="font-size:12.5px">{name}</text>
  <rect x="{x+w-58}" y="{y+8}" width="46" height="15" rx="7" fill="{TAG_ENSURE[1]}"/>
  <text x="{x+w-35}" y="{y+19}" text-anchor="middle" class="tag" fill="{TAG_ENSURE[0]}">ensure</text>
  <text x="{x+16}" y="{y+46}" class="s" style="font-size:10px"><tspan class="b" fill="{MAIN_FG}">验</tspan>　{ver}</text>
  <text x="{x+16}" y="{y+63}" class="s" style="font-size:10px"><tspan class="b" fill="{MAIN_FG}">建</tspan>　{build}（产物不符才跑；就绪则整步跳过）</text>
  <text x="{x+16}" y="{y+79}" class="s mono" style="font-size:9px;fill:#a0aec0">{note} · {build}</text>''')

for i, (num, name, ver, build, note) in enumerate(STEPS):
    y = CY0 + i * (CH + CGAP)
    step_card(LX, y, LW, num, name, ver, build, note)
    if i < 6:
        # 竖箭头：本卡底 → 下一卡顶
        ay1 = y + CH + 3
        ay2 = y + CH + CGAP - 3
        p.append(f'<line x1="{LX+LW/2}" y1="{ay1}" x2="{LX+LW/2}" y2="{ay2}" class="ln" marker-end="url(#ar)"/>')

CHAIN_BOT = CY0 + 7 * CH + 6 * CGAP   # 链底 y = 96+602+156 = 854

# ---------- 右列：单步内部机制（ensure_sub） ----------
p.append(f'''
  <rect x="{RX}" y="{CY0}" width="{RW}" height="{CHAIN_BOT-CY0}" rx="8" fill="#f7fafc" stroke="#cbd5e0" stroke-width="1"/>
  <rect x="{RX}" y="{CY0}" width="{RW}" height="30" rx="8" fill="{MAIN_FG}"/>
  <rect x="{RX}" y="{CY0+20}" width="{RW}" height="10" fill="{MAIN_FG}"/>
  <text x="{RX+RW/2}" y="{CY0+20}" text-anchor="middle" class="gt" fill="#ffffff" style="font-size:12px;font-weight:700">单步内部机制 ensure_sub()</text>''')

# 右侧机制：分支结构（文字行 + 竖线 + 下箭头），与 DAG ensure() 同构但不写 DAG 状态
mx = RX + 18
p.append(f'<text x="{mx}" y="{CY0+50}" class="b" style="font-size:10.5px">verify 判定（即时探测产物）</text>')
p.append(f'<line x1="{mx+4}" y1="{CY0+58}" x2="{mx+4}" y2="{CY0+82}" class="ln"/>')
p.append(f'<text x="{mx+12}" y="{CY0+72}" class="s" style="font-size:9.5px">就绪 → 跳过，return 0</text>')
p.append(f'<line x1="{mx+4}" y1="{CY0+82}" x2="{mx+4}" y2="{CY0+104}" class="ln" marker-end="url(#ar)"/>')
p.append(f'<text x="{mx+12}" y="{CY0+96}" class="s" style="font-size:9.5px">不符 → 进入修复</text>')
p.append(f'<text x="{mx}" y="{CY0+122}" class="b" style="font-size:10.5px">一次构建 → 复核</text>')
p.append(f'<line x1="{mx+4}" y1="{CY0+130}" x2="{mx+4}" y2="{CY0+154}" class="ln"/>')
p.append(f'<text x="{mx+12}" y="{CY0+144}" class="s" style="font-size:9.5px">通过 → return 0</text>')
p.append(f'<line x1="{mx+4}" y1="{CY0+154}" x2="{mx+4}" y2="{CY0+176}" class="ln" marker-end="url(#ar)"/>')
p.append(f'<text x="{mx+12}" y="{CY0+168}" class="s" style="font-size:9.5px">失败/仍不符 ↓</text>')
p.append(f'''
  <rect x="{RX+12}" y="{CY0+186}" width="{RW-24}" height="34" rx="6" fill="{HARD_BG}" stroke="{HARD_BD}" stroke-width="1"/>
  <text x="{RX+RW/2}" y="{CY0+207}" text-anchor="middle" class="b" fill="{HARD_FG}" style="font-size:10.5px">hard：日志 + exit 1 终止引导</text>''')
p.append(f'<text x="{mx}" y="{CY0+248}" class="s" style="font-size:9.5px">与 DAG ensure() 同构（v.81</text>')
p.append(f'<text x="{mx}" y="{CY0+263}" class="s" style="font-size:9.5px">起均单次）；但不写</text>')
p.append(f'<text x="{mx}" y="{CY0+278}" class="s" style="font-size:9.5px">_done/_dirty/_failed——外层</text>')
p.append(f'<text x="{mx}" y="{CY0+293}" class="s" style="font-size:9.5px">prepare_container 同为一次</text>')
p.append(f'<text x="{mx}" y="{CY0+308}" class="s" style="font-size:9.5px">机会，内层状态不得残留误跳过</text>')
p.append(f'<text x="{mx}" y="{CY0+344}" class="b" style="font-size:10.5px" fill="{MAIN_FG}">失败定位到步</text>')
p.append(f'<text x="{mx}" y="{CY0+360}" class="s" style="font-size:9.5px">日志精确到步名；且后续步</text>')
p.append(f'<text x="{mx}" y="{CY0+375}" class="s" style="font-size:9.5px">不执行——失败即停，不跑无用步</text>')
# 为什么只修一次（v.81）
p.append(f'''
  <rect x="{RX+12}" y="{CY0+398}" width="{RW-24}" height="104" rx="6" fill="#fffaf0" stroke="#fbd38d" stroke-width="1"/>
  <text x="{RX+24}" y="{CY0+420}" class="b" style="font-size:10.5px" fill="#dd6b20">为什么只修一次（v.81）</text>
  <text x="{RX+24}" y="{CY0+439}" class="s" style="font-size:9.5px">安装顺序保证前置条件已就绪；</text>
  <text x="{RX+24}" y="{CY0+454}" class="s" style="font-size:9.5px">修一次不过 = 非瞬态故障，</text>
  <text x="{RX+24}" y="{CY0+469}" class="s" style="font-size:9.5px">再修一次大概率同样结果——</text>
  <text x="{RX+24}" y="{CY0+484}" class="s" style="font-size:9.5px">直接 hard 让人介入更快</text>''')
# 与阶段 3 A/B 的归口
p.append(f'''
  <rect x="{RX+12}" y="{CY0+520}" width="{RW-24}" height="128" rx="6" fill="{MAIN_BG}" stroke="{MAIN_BD}" stroke-width="1"/>
  <text x="{RX+24}" y="{CY0+542}" class="b" style="font-size:10.5px" fill="{MAIN_FG}">与阶段 3 A/B 的归口（v.81）</text>
  <text x="{RX+24}" y="{CY0+561}" class="s" style="font-size:9.5px">④ acquis+解析器 → 步骤 A 判据</text>
  <text x="{RX+24}" y="{CY0+576}" class="s" style="font-size:9.5px">⑤⑥ listen_uri/trusted_ips → 步骤 B</text>
  <text x="{RX+24}" y="{CY0+591}" class="s" style="font-size:9.5px">⑦ 容器 config → 步骤 B</text>
  <text x="{RX+24}" y="{CY0+610}" class="s" style="font-size:9.5px">组合函数 setup_crowdsec_config 与</text>
  <text x="{RX+24}" y="{CY0+625}" class="s" style="font-size:9.5px">深修链 _crowdsec_repair 已删——</text>
  <text x="{RX+24}" y="{CY0+640}" class="s" style="font-size:9.5px">重启态缺项由 fix_A/fix_B 按需补写</text>''')

# ---------- 底部说明 ----------
BY = CHAIN_BOT + 26
p.append(f'''
  <rect x="{LX}" y="{BY}" width="{W-LX*2}" height="176" rx="10" fill="#f7fafc" stroke="#cbd5e0" stroke-width="1"/>
  <text x="{LX+16}" y="{BY+22}" class="b" style="font-size:12.5px">为什么每一步都 hard</text>
  <text x="{LX+16}" y="{BY+44}" class="s" style="font-size:10px">非确定性步骤软容忍后，重跑还是会卡到同一处——与其带着坏产物继续（缺 parser 的 crowdsec 等于没防护），不如终止让人介入。</text>
  <text x="{LX+16}" y="{BY+64}" class="s" style="font-size:10px">原 prepare_container 一把梭五连写（任一子失败仅整体 return 1，难定位、且 verify 只认整体快照）已删除，七步判定标准与原整体 verify 完全一致。</text>
  <text x="{LX+16}" y="{BY+88}" class="b" style="font-size:11px" fill="{HARD_FG}">enroll 例外</text>
  <text x="{LX+16}" y="{BY+106}" class="s" style="font-size:10px">console enroll 不在此链——它需要人工到网站 Accept（命令成功但 10 秒内未显示 Enrolled 是合法中间态），保留阶段 3 原做法：一次 shot，不进 hard 循环。</text>
  <text x="{LX+16}" y="{BY+130}" class="b" style="font-size:11px">v.81 一次修复（三处循环单次化）</text>
  <text x="{LX+16}" y="{BY+148}" class="s" style="font-size:10px">ensure / ensure_sub / phase3_step 的「至多两次」全部改为一次：安装顺序保证前置条件已就绪，多修复一次没必要（用户已确认）。</text>
  <text x="{LX+16}" y="{BY+168}" class="s mono" style="font-size:9px;fill:#a0aec0">build_prepare_container() → ensure_sub "步名" verify_sub_* build_*（×7） · verify_prepare_container = 七者汇总（快照等价）</text>''')

p.append('</svg>')
svg = "\n".join(p)
with open(SVG, "w", encoding="utf-8") as f:
    f.write(svg)
print(f"written: {SVG} ({W}x{H})")

# ---- 渲染 PNG（2x 高清，crop 精确尺寸，quantize 压缩）----
html = os.path.join(OUT_DIR, "render-cs.html")
with open(html, "w", encoding="utf-8") as f:
    f.write(f'''<!DOCTYPE html><html><head><meta charset="utf-8"><style>
html,body{{margin:0;padding:0;background:#ffffff}}
img{{display:block;width:{W}px;height:{H}px}}
</style></head><body><img src="file://{SVG}"></body></html>''')

shot = os.path.join(OUT_DIR, "_cs_shot.png")
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
