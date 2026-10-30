#!/usr/bin/env python3
# 生成「编译期 / 运行期」两栏对照流程图
import cairosvg

W, H = 1000, 780
FONT = '"Noto Sans CJK SC","Noto Serif CJK SC",sans-serif'

CSS = """
.side{font-family:%s;font-size:13px;font-weight:700;letter-spacing:2px}
.t{font-family:%s;font-size:15px;font-weight:700}
.s{font-family:%s;font-size:12px}
.n{font-family:%s;font-size:11px;fill:#6b7280}
""" % (FONT, FONT, FONT, FONT)

def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

# 框：(序号, 标题, 副行)
LEFT = [
    ("1", "手动 Run workflow", "选 24.10.x 或 25.12.x，填 12 个输入"),
    ("2", "参数校验", "容器 IP / 网桥 IP / profile 合法性"),
    ("3", "写入 custom/*.txt", "路由 IP / 掩码 / 网关 / DNS / 容器 IP"),
    ("4", "准备 CrowdSec rootfs", "Ubuntu 22.04 base + apt 装 crowdsec"),
    ("5", "Docker 里跑 build.sh", "immortalwrt/imagebuilder 拉源码编镜像"),
    ("6", "发布 Release", "tag Autobuild-x86-64 + img.gz 产物"),
]

RIGHT = [
    ("7", "刷机开机 → rc.local", "前置检查：脚本在、镜像/rootfs 在"),
    ("8", "抢引导锁", "残留超 30 分钟强夺，防并发双跑"),
    ("9", "bootstrap 七大步骤", "逐组验证→缺就建→全通才置位"),
    ("10", "INSTALL→NETWORK→BOOT", "解压 rootfs / 验 LuCI 网络 / 起容器"),
    ("11", "CONFIGURE→BOUNCER", "容器内日志解析器 / bouncer 注册联动"),
    ("12", "VERIFY→ENROLL", "列表生效解 CAPI / Console 账号绑定"),
]

# 旁路
SIDE_R = [
    ("probe 守护", "每 60s 看 last_pull，停滞 3 轮触发 bootstrap，冷却 600s"),
    ("clean-workflow", "手动清 N 天前的 Actions 运行记录"),
]

BW, BH = 400, 68
LX, RX = 40, 540
Y0, GAP = 92, 92

out = []
out.append(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">')
out.append(f'<style>{CSS}</style>')
out.append(f'<rect width="{W}" height="{H}" fill="#ffffff"/>')

# 标题
out.append(f'<text x="{W/2}" y="38" text-anchor="middle" class="t" font-size="19">ImmortalWrt-ImageBuilder-24.10 整体流程</text>')
out.append(f'<text x="{W/2}" y="60" text-anchor="middle" class="n">编译期产出固件 · 运行期固件自举容器</text>')

# 分栏标识
out.append(f'<rect x="{LX-14}" y="74" width="{BW+28}" height="4" rx="2" fill="#2563eb"/>')
out.append(f'<text x="{LX-14}" y="70" class="side" fill="#2563eb">编译期 · GitHub Actions</text>')
out.append(f'<rect x="{RX-14}" y="74" width="{BW+28}" height="4" rx="2" fill="#059669"/>')
out.append(f'<text x="{RX-14}" y="70" class="side" fill="#059669">运行期 · 路由器开机</text>')

def draw_col(items, x, stroke, fill, badge):
    elems = []
    for i, (num, title, sub) in enumerate(items):
        y = Y0 + i * GAP
        elems.append(f'<rect x="{x}" y="{y}" width="{BW}" height="{BH}" rx="8" '
                     f'fill="{fill}" stroke="{stroke}" stroke-width="1.5"/>')
        elems.append(f'<circle cx="{x+26}" cy="{y+BH/2}" r="15" fill="{stroke}"/>')
        elems.append(f'<text x="{x+26}" y="{y+BH/2+5}" text-anchor="middle" '
                     f'class="s" fill="#ffffff" font-weight="700">{num}</text>')
        elems.append(f'<text x="{x+52}" y="{y+27}" class="t" fill="#111827">{esc(title)}</text>')
        elems.append(f'<text x="{x+52}" y="{y+48}" class="s" fill="#4b5563">{esc(sub)}</text>')
        # 箭头
        if i < len(items) - 1:
            ay = y + BH
            elems.append(f'<path d="M{x+BW/2} {ay} L{x+BW/2} {ay+GAP-BH-8}" '
                         f'stroke="{stroke}" stroke-width="2" marker-end="url(#ar_{badge})"/>')
    return elems

out.append('<defs>')
for name, color in (("l", "#2563eb"), ("r", "#059669")):
    out.append(f'<marker id="ar_{name}" markerWidth="8" markerHeight="8" refX="6" refY="3" '
               f'orient="auto"><path d="M0,0 L0,6 L7,3 z" fill="{color}"/></marker>')
out.append('</defs>')

out += draw_col(LEFT, LX, "#2563eb", "#eff6ff", "l")
out += draw_col(RIGHT, RX, "#059669", "#ecfdf5", "r")

# 中间过渡箭头（6 → 7）
y6 = Y0 + 5 * GAP + BH / 2
y7 = Y0 + 0 * GAP + BH / 2
mx = (LX + BW + RX) / 2
out.append(f'<path d="M{LX+BW} {y6} L{mx-6} {y6} L{mx-6} {y7} L{RX-6} {y7}" '
           f'fill="none" stroke="#9ca3af" stroke-width="2" stroke-dasharray="5 3" marker-end="url(#ar_r)"/>')
out.append(f'<text x="{mx-10}" y="{y6-8}" text-anchor="middle" class="n" fill="#6b7280">产物</text>')
out.append(f'<text x="{mx-10}" y="{y6+8}" text-anchor="middle" class="n" fill="#6b7280">img.gz</text>')

# 侧挂流程
sy = Y0 + 6 * GAP + 8
out.append(f'<text x="{LX}" y="{sy}" class="side" fill="#7c3aed">旁挂</text>')
for i, (title, sub) in enumerate(SIDE_R):
    y = sy + 12 + i * 54
    out.append(f'<rect x="{LX}" y="{y}" width="{W-LX*2}" height="44" rx="6" '
               f'fill="#faf5ff" stroke="#a855f7" stroke-width="1.2" stroke-dasharray="4 3"/>')
    out.append(f'<text x="{LX+16}" y="{y+19}" class="t" font-size="13" fill="#6b21a8">{esc(title)}</text>')
    out.append(f'<text x="{LX+16}" y="{y+36}" class="s" fill="#4b5563">{esc(sub)}</text>')

out.append('</svg>')
svg = "\n".join(out)
open("docs/repo-flow.svg", "w", encoding="utf-8").write(svg)
cairosvg.svg2png(bytestring=svg.encode(), write_to="docs/repo-flow.png", scale=2)
print("已生成 docs/repo-flow.svg / .png")
