#!/usr/bin/env python3
"""生成网络切换说明图 SVG + 高清 PNG（v.77）
内容：crowdsec-lxc-bootstrap.sh 的网络切换全貌——
  _router_mode() 读 custom_router_mode.txt → gw / bypass / auto(按物理口数)
  → 各对象独立 verify → 按需 build → 分派；模式互切双向闭环。

用法: python3 gen_net_flow.py
  输出: 同目录 net-switch-flow.svg / net-switch-flow.png（2x 高清，已裁精确尺寸）

渲染管线（照 gen_flow.py 踩坑结论）：
  Chromium 有效视口比 --window-size 低 88px，直渲 SVG 裁底部 →
  先写 render.html：body 白底，内嵌 <img style="display:block;width:680px;height:Hpx">，
  窗口按 680×(H+100) 开（--force-device-scale-factor=2），
  截图后 PIL crop((0,0,1360,2*H)) 裁回精确尺寸，再 quantize 压缩。
"""
import os
import subprocess
import sys

W, H = 680, 730
OUT_DIR = os.path.dirname(os.path.abspath(__file__))
SVG = os.path.join(OUT_DIR, "net-switch-flow.svg")
PNG = os.path.join(OUT_DIR, "net-switch-flow.png")

parts = []
parts.append(f'''<svg width="{W}" height="{H}" viewBox="0 0 {W} {H}" xmlns="http://www.w3.org/2000/svg" font-family="-apple-system,'PingFang SC','Microsoft YaHei','Noto Sans CJK SC',sans-serif">
  <defs>
    <marker id="ar" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
      <path d="M 0 0 L 10 5 L 0 10 z" fill="#94a3b8"/>
    </marker>
    <marker id="ard" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
      <path d="M 0 0 L 10 5 L 0 10 z" fill="#64748b"/>
    </marker>
  </defs>
  <style>
    .t{{font-size:15px;font-weight:700;fill:#1a202c}}
    .ts{{font-size:10.5px;fill:#718096}}
    .b{{font-size:12px;font-weight:600;fill:#1a202c}}
    .s{{font-size:11px;fill:#4a5568}}
    .mono{{font-family:ui-monospace,'SFMono-Regular',Consolas,monospace;font-size:10px;fill:#4a5568}}
    .ln{{stroke:#94a3b8;stroke-width:1.5;fill:none}}
    .lnd{{stroke:#64748b;stroke-width:1.5;fill:none;stroke-dasharray:5 4}}
  </style>
  <rect x="0" y="0" width="{W}" height="{H}" fill="#ffffff"/>''')

parts.append('''
  <text x="340" y="24" text-anchor="middle" class="t">网络切换逻辑总览（v.77 · crowdsec-lxc-bootstrap.sh）</text>
  <text x="340" y="41" text-anchor="middle" class="ts">每对象独立 verify → 按需 build → 分派；custom_router_mode.txt 编译期可调、运行时可改免重编译</text>

  <rect x="170" y="52" width="340" height="46" rx="8" fill="#f7fafc" stroke="#cbd5e0" stroke-width="1"/>
  <text x="340" y="71" text-anchor="middle" class="b">_router_mode() 读 custom_router_mode.txt</text>
  <text x="340" y="88" text-anchor="middle" class="s">gw / bypass / 空或非法 → auto</text>

  <line x1="340" y1="98" x2="340" y2="108" class="ln"/>
  <line x1="100" y1="108" x2="580" y2="108" class="ln"/>
  <line x1="100" y1="108" x2="100" y2="120" class="ln" marker-end="url(#ar)"/>
  <line x1="340" y1="108" x2="340" y2="120" class="ln" marker-end="url(#ar)"/>
  <line x1="580" y1="108" x2="580" y2="120" class="ln" marker-end="url(#ar)"/>

  <rect x="10" y="120" width="180" height="32" rx="6" fill="#ebf4ff" stroke="#90cdf4"/>
  <text x="100" y="140" text-anchor="middle" class="b" fill="#2b6cb0">= gw → 主路由</text>
  <rect x="250" y="120" width="180" height="32" rx="6" fill="#f7fafc" stroke="#cbd5e0"/>
  <text x="340" y="140" text-anchor="middle" class="b" fill="#64748b">空/非法 → auto</text>
  <rect x="490" y="120" width="180" height="32" rx="6" fill="#fffaf0" stroke="#f6ad55"/>
  <text x="580" y="140" text-anchor="middle" class="b" fill="#dd6b20">= bypass → 旁路</text>

  <rect x="10" y="176" width="320" height="196" rx="10" fill="#ebf4ff" stroke="#90cdf4" stroke-width="1"/>
  <text x="170" y="198" text-anchor="middle" class="b" fill="#2b6cb0">setup_router_net() → gw 分支</text>
  <text x="26" y="220" class="s">verify_lan_dhcp：ignore=0 + start/limit/leasetime</text>
  <text x="26" y="238" class="s">LAN 口 DHCP 开启 = 主路由命脉</text>
  <text x="26" y="256" class="s">兜底 100/150/12h，自定义值不覆盖</text>
  <text x="26" y="280" class="s">不符 → build_lan_dhcp → commit dhcp</text>
  <text x="26" y="298" class="s">→ dnsmasq reload</text>
  <rect x="22" y="314" width="296" height="44" rx="6" fill="#ffffff" stroke="#90cdf4"/>
  <text x="34" y="332" class="mono" fill="#2b6cb0">只校准 LAN DHCP + dnsmasq reload</text>
  <text x="34" y="348" class="s">旁路基线一概不应用（避免抢网关/DNS）</text>

  <rect x="350" y="176" width="320" height="196" rx="10" fill="#fffaf0" stroke="#f6ad55" stroke-width="1"/>
  <text x="510" y="198" text-anchor="middle" class="b" fill="#dd6b20">setup_router_net() → bypass 分支</text>
  <text x="366" y="220" class="s">5 对象各自 verify → 不符才 build：</text>
  <text x="366" y="238" class="s">br_lan_ports / lan_static /</text>
  <text x="366" y="256" class="s">dhcp_ignore(ignore=1) / wan_disabled /</text>
  <text x="366" y="274" class="s">dns_domain（DNS 劫持 203.107.6.88）</text>
  <rect x="362" y="286" width="296" height="30" rx="6" fill="#ffffff" stroke="#f6ad55"/>
  <text x="374" y="305" class="s">_ok_b/_ok_p/_ok_d/_ok_w/_ok_n 全 0 → 早退</text>
  <text x="366" y="334" class="s">有缺 → build_* → commit network/dhcp</text>
  <text x="366" y="352" class="s">→ reload network + dnsmasq</text>

  <path d="M 340 152 L 340 162 L 100 162 L 100 176" class="lnd" marker-end="url(#ard)"/>
  <path d="M 340 162 L 580 162 L 580 176" class="lnd" marker-end="url(#ard)"/>
  <text x="222" y="158" text-anchor="middle" class="ts">物理口 ≥2 → gw</text>
  <text x="462" y="158" text-anchor="middle" class="ts">物理口 &lt;2 → bypass</text>

  <rect x="10" y="396" width="660" height="64" rx="10" fill="#f0fff4" stroke="#9ae6b4"/>
  <text x="340" y="417" text-anchor="middle" class="b" fill="#276749">setup_svc_bind()：管理面定责（两模式都跑）</text>
  <text x="340" y="434" text-anchor="middle" class="s">_zone_lan_network 按 name='lan' 定位 zone 取 network 首值</text>
  <text x="340" y="451" text-anchor="middle" class="mono" fill="#276749">dropbear.@dropbear[0].Interface = ttyd.@ttyd[0].interface = 该网络名</text>

  <rect x="10" y="478" width="660" height="54" rx="10" fill="#f0fff4" stroke="#9ae6b4"/>
  <text x="340" y="499" text-anchor="middle" class="b" fill="#276749">setup_docker_fw()：两模式都跑</text>
  <text x="340" y="517" text-anchor="middle" class="s">src/dest=docker ACCEPT + lan2docker + docker 转发清理（按段名定责）</text>

  <rect x="10" y="550" width="660" height="58" rx="10" fill="#f7fafc" stroke="#cbd5e0"/>
  <text x="340" y="571" text-anchor="middle" class="b">公共块（模式无关）</text>
  <text x="340" y="589" text-anchor="middle" class="s">setup_bridge()：_phys_ports 空则跳过（防开机早期误建空桥断外网）</text>
  <text x="340" y="603" text-anchor="middle" class="s">setup_lxc_firewall()：6 项分派 _ok_z/_ok_f/_ok_s/_ok_i/_ok_w/_ok_l</text>

  <rect x="10" y="626" width="660" height="66" rx="10" fill="#fffaf0" stroke="#dd6b20" stroke-dasharray="6 4"/>
  <text x="340" y="647" text-anchor="middle" class="b" fill="#dd6b20">模式互切双向闭环（互斥语义，对方 verify 兜底）</text>
  <text x="340" y="665" text-anchor="middle" class="s">gw→bypass：verify_dhcp_ignore 判 ignore≠1 → 修正让权</text>
  <text x="340" y="682" text-anchor="middle" class="s">bypass→gw：verify_lan_dhcp 判 ignore≠0 → 修正开启（重跑即自愈）</text>

  <line x1="170" y1="372" x2="170" y2="396" class="ln" marker-end="url(#ar)"/>
  <line x1="510" y1="372" x2="510" y2="396" class="ln" marker-end="url(#ar)"/>
  <line x1="340" y1="460" x2="340" y2="478" class="ln" marker-end="url(#ar)"/>
  <line x1="340" y1="532" x2="340" y2="550" class="ln" marker-end="url(#ar)"/>
  <line x1="340" y1="608" x2="340" y2="626" class="ln" marker-end="url(#ar)"/>
</svg>''')

svg = "\n".join(parts)
with open(SVG, "w", encoding="utf-8") as f:
    f.write(svg)
print(f"written: {SVG} ({W}x{H})")

# ---- 渲染 PNG（2x 高清，crop 精确尺寸，quantize 压缩）----
html = os.path.join(OUT_DIR, "render-net.html")
with open(html, "w", encoding="utf-8") as f:
    f.write(f'''<!DOCTYPE html><html><head><meta charset="utf-8"><style>
html,body{{margin:0;padding:0;background:#ffffff}}
img{{display:block;width:{W}px;height:{H}px}}
</style></head><body><img src="file://{SVG}"></body></html>''')

shot = os.path.join(OUT_DIR, "_net_shot.png")
subprocess.run([
    "chromium", "--headless", "--disable-gpu", "--no-sandbox",
    "--hide-scrollbars", "--default-background-color=FFFFFFFF",
    f"--window-size={W},{H + 100}", "--force-device-scale-factor=2",
    f"--screenshot={shot}", f"file://{html}",
], check=True, capture_output=True, timeout=120)

from PIL import Image  # noqa: E402

im = Image.open(shot).convert("RGB")
im = im.crop((0, 0, W * 2, H * 2))
im = im.quantize(colors=256, method=Image.MEDIANCUT, dither=Image.FLOYDSTEINBERG).convert("RGB")
im.save(PNG, optimize=True)
print(f"written: {PNG} ({im.size[0]}x{im.size[1]}, {os.path.getsize(PNG) // 1024} KB)")

os.remove(html)
os.remove(shot)
print("done")
