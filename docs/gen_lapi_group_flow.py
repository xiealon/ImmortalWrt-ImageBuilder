"""生成「LAPI 组」细部流程图 SVG + PNG

对应 crowdsec-lxc-bootstrap.sh（旁路由版）LAPI 组：
    lapi_fetch   —— 取 LAPI 地址与密钥
    bouncer_fill —— 填进路由器 bouncer，并重启宿主机 bouncer 服务

本图重点是两点容易被忽略的时序：
  1. 填完 api_key 后必须重启宿主机 bouncer（v.94 补），否则 BOUNCERVERIFY 白等 60 秒；
  2. 刻意不重启容器内 crowdsec —— 它不读宿主机 uci，重启只会让 last_pull 断档。

用法：python3 gen_lapi_group_flow.py
产物：lapi-group-flow.svg / lapi-group-flow.png
"""
import cairosvg

W = 1360

P = []
A = P.append

C_FETCH = "#2c7a7b"
C_FILL = "#b7791f"
C_REST = "#c53030"
C_NOTE = "#805ad5"

# ---------- 布局常量 ----------
GX = 40
GW = W - 80

# 顶部：组入口
Y_GATE = 96
H_GATE = 74

# 步骤 1
Y_S1 = Y_GATE + H_GATE + 56
H_S1 = 214

# 步骤 2
Y_S2 = Y_S1 + H_S1 + 64
H_S2 = 320

# 重启（步骤 2 内部最后一段，单独框出）
Y_REST = Y_S2 + 214
H_REST = 146

# 底部：为什么这么排
Y_WHY = Y_REST + H_REST + 46
H_WHY = 168

# 底部：判据速查
Y_TAB = Y_WHY + H_WHY + 22
H_TAB = 132

H = Y_TAB + H_TAB + 34

A(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">')
A('''<style>
  .t   { font: 600 22px "Noto Sans CJK SC",sans-serif; fill:#1a202c; }
  .ts  { font: 400 12.5px "Noto Sans CJK SC",sans-serif; fill:#4a5568; }
  .g   { font: 700 15px "JetBrains Mono","Consolas",monospace; }
  .gt  { font: 500 12.5px "Noto Sans CJK SC",sans-serif; fill:#2d3748; }
  .n   { font: 400 11.5px "JetBrains Mono","Consolas",monospace; fill:#2d3748; }
  .lg  { font: 400 12.5px "Noto Sans CJK SC",sans-serif; fill:#2d3748; }
  .lb  { font: 600 12.5px "Noto Sans CJK SC",sans-serif; }
  .sm  { font: 400 11px "Noto Sans CJK SC",sans-serif; fill:#4a5568; }
  .code{ font: 400 11px "JetBrains Mono","Consolas",monospace; fill:#2d3748; }
</style>''')
A(f'<rect width="{W}" height="{H}" fill="#ffffff"/>')

# ---------- 标题 ----------
A(f'<text x="{W//2}" y="38" text-anchor="middle" class="t">LAPI 组细部：取 LAPI → 填入 bouncer → 重启宿主机服务</text>')
A(f'<text x="{W//2}" y="60" text-anchor="middle" class="ts">'
  'crowdsec-lxc-bootstrap.sh · LAPI 组 · lapi_fetch + bouncer_fill · 排在 BOOT 之后、BOUNCERVERIFY 之前</text>')

A('''<defs>
  <marker id="ar" markerWidth="9" markerHeight="9" refX="7" refY="4.5" orient="auto">
    <path d="M0,0 L9,4.5 L0,9 z" fill="#a0aec0"/>
  </marker>
  <marker id="arR" markerWidth="9" markerHeight="9" refX="7" refY="4.5" orient="auto">
    <path d="M0,0 L9,4.5 L0,9 z" fill="#c53030"/>
  </marker>
</defs>''')

# ---------- 组入口 ----------
A(f'<rect x="{GX}" y="{Y_GATE}" width="{GW}" height="{H_GATE}" rx="8" fill="#f0fff4" stroke="#38a169" stroke-width="1.6"/>')
A(f'<circle cx="{GX+36}" cy="{Y_GATE+30}" r="16" fill="#2c7a7b"/>')
A(f'<text x="{GX+36}" y="{Y_GATE+36}" text-anchor="middle" font-weight="700" font-size="16" fill="#ffffff" font-family="sans-serif">6</text>')
A(f'<text x="{GX+62}" y="{Y_GATE+28}" class="g" fill="#2c7a7b">LAPI</text>')
A(f'<text x="{GX+152}" y="{Y_GATE+28}" class="gt">取 LAPI 地址并填入路由器 bouncer</text>')
A(f'<text x="{GX+GW-18}" y="{Y_GATE+28}" text-anchor="end" class="sm">前置组：BOOT</text>')
A(f'<text x="{GX+62}" y="{Y_GATE+52}" class="lg">'
  '门禁：GSET_BOOT = 1 才执行 · 两个小步骤全通才置位 GSET_LAPI=1 · 任一 build 失败 → hard 终止</text>')

# ---------- 步骤 1：lapi_fetch ----------
A(f'<rect x="{GX}" y="{Y_S1}" width="{GW}" height="{H_S1}" rx="8" fill="#ffffff" stroke="{C_FETCH}" stroke-width="1.6"/>')
A(f'<rect x="{GX}" y="{Y_S1}" width="6" height="{H_S1}" rx="3" fill="{C_FETCH}"/>')
A(f'<circle cx="{GX+36}" cy="{Y_S1+28}" r="13" fill="{C_FETCH}"/>')
A(f'<text x="{GX+36}" y="{Y_S1+33}" text-anchor="middle" font-weight="700" font-size="13" fill="#ffffff" font-family="sans-serif">1</text>')
A(f'<text x="{GX+60}" y="{Y_S1+33}" class="g" fill="{C_FETCH}">lapi_fetch</text>')
A(f'<text x="{GX+180}" y="{Y_S1+33}" class="gt">从容器里把 LAPI 地址与密钥取出来</text>')

# verify 条件
A(f'<text x="{GX+60}" y="{Y_S1+60}" class="lb" fill="{C_FETCH}">verify 三条件（全满足才算已就绪）</text>')
A(f'<text x="{GX+60}" y="{Y_S1+82}" class="lg">① 容器在跑（ct_running）</text>')
A(f'<text x="{GX+60}" y="{Y_S1+103}" class="lg">② LAPI 能响应：容器内 cscli bouncers list 有回显</text>')
A(f'<text x="{GX+60}" y="{Y_S1+124}" class="lg">③ local_api_credentials.yaml 里 url: 与 login: 两个字段都在</text>')

# build 流程
A(f'<text x="{GX+700}" y="{Y_S1+60}" class="lb" fill="{C_FETCH}">build 做什么（只在 verify 不过时）</text>')
A(f'<text x="{GX+700}" y="{Y_S1+82}" class="lg">等待 LAPI 起来：最多 60 秒，每 5 秒探一次</text>')
A(f'<text x="{GX+700}" y="{Y_S1+103}" class="lg">读出 url / login 两个值</text>')
A(f'<text x="{GX+700}" y="{Y_S1+124}" class="lg">缓存到 .bootstrap/lapi.env（权限 600）</text>')

# 小提示
A(f'<rect x="{GX+60}" y="{Y_S1+140}" width="{GW-120}" height="56" rx="5" fill="#e6fffa" stroke="#81e6d9"/>')
A(f'<text x="{GX+74}" y="{Y_S1+160}" class="lg" fill="#234e52">'
  '「拿到」的判据是能从容器读出来，不是「文件存在」——文件可能是旧的。</text>')
A(f'<text x="{GX+74}" y="{Y_S1+181}" class="lg" fill="#234e52">'
  '缓存 lapi.env 有两个作用：证明取到过、给下一步 bouncer_fill 用，不必再进容器读。</text>')

# 箭头 1→2
_cx = GX + GW // 2
A(f'<path d="M {_cx} {Y_S1+H_S1} L {_cx} {Y_S2-8}" stroke="#a0aec0" stroke-width="1.6" marker-end="url(#ar)"/>')

# ---------- 步骤 2：bouncer_fill ----------
A(f'<rect x="{GX}" y="{Y_S2}" width="{GW}" height="{H_S2}" rx="8" fill="#ffffff" stroke="{C_FILL}" stroke-width="1.6"/>')
A(f'<rect x="{GX}" y="{Y_S2}" width="6" height="{H_S2}" rx="3" fill="{C_FILL}"/>')
A(f'<circle cx="{GX+36}" cy="{Y_S2+28}" r="13" fill="{C_FILL}"/>')
A(f'<text x="{GX+36}" y="{Y_S2+33}" text-anchor="middle" font-weight="700" font-size="13" fill="#ffffff" font-family="sans-serif">2</text>')
A(f'<text x="{GX+60}" y="{Y_S2+33}" class="g" fill="{C_FILL}">bouncer_fill</text>')
A(f'<text x="{GX+196}" y="{Y_S2+33}" class="gt">填进路由器 bouncer，并让宿主机服务重新读配置</text>')

# 2.1 / 2.2 / 2.3
A(f'<text x="{GX+60}" y="{Y_S2+66}" class="lb" fill="{C_FILL}">2.1 先补 uci（_bouncer_uci_apply）</text>')
A(f'<text x="{GX+60}" y="{Y_S2+88}" class="lg">找 /etc/config/crowdsec 的 bouncer 段，没有就新建</text>')
A(f'<text x="{GX+60}" y="{Y_S2+108}" class="code">api_url = http://&lt;容器IP&gt;:8080/   enabled = 1</text>')
A(f'<text x="{GX+60}" y="{Y_S2+127}" class="code">deny_action = drop   interface = br-lan</text>')
A(f'<text x="{GX+60}" y="{Y_S2+148}" class="lg">→ uci commit crowdsec</text>')

A(f'<text x="{GX+700}" y="{Y_S2+66}" class="lb" fill="{C_FILL}">2.2 向容器 LAPI 注册，换回 api_key</text>')
A(f'<text x="{GX+700}" y="{Y_S2+88}" class="lg">cscli bouncers add openwrt-fw -o raw</text>')
A(f'<text x="{GX+700}" y="{Y_S2+108}" class="sm">同名已存在拿不到新 key → 先 delete 再 add</text>')
A(f'<text x="{GX+700}" y="{Y_S2+129}" class="lg">拿到 key → 写进 uci → commit crowdsec</text>')
A(f'<text x="{GX+700}" y="{Y_S2+151}" class="sm">拿不到 key → build 失败 → hard 终止</text>')

# 2.3 重启框（重点）
A(f'<rect x="{GX+40}" y="{Y_REST}" width="{GW-80}" height="{H_REST}" rx="7" '
  f'fill="#fff5f5" stroke="{C_REST}" stroke-width="2" stroke-dasharray="6 3"/>')
A(f'<text x="{GX+58}" y="{Y_REST+28}" class="lb" fill="{C_REST}">2.3 重启宿主机 bouncer 服务（v.94 补上，之前缺这一步）</text>')
A(f'<text x="{GX+58}" y="{Y_REST+58}" class="lg">'
  '先判 cs_active_on_host：服务没在跑就不抢跑，交给后续服务拉起流程</text>')
A(f'<text x="{GX+58}" y="{Y_REST+84}" class="code">'
  'service crowdsec-firewall-bouncer restart</text>')
A(f'<text x="{GX+58}" y="{Y_REST+112}" class="lg">'
  '重启后等 nft 表就位（最多 10 秒）；没等到只记日志、不阻断，交给下一步判定</text>')

A(f'<path d="M {GX+GW//2} {Y_S2+150} L {GX+GW//2} {Y_REST-8}" stroke="{C_REST}" stroke-width="1.8" marker-end="url(#arR)"/>')

# ---------- 为什么不重启容器内 crowdsec ----------
A(f'<rect x="{GX}" y="{Y_WHY}" width="{GW}" height="{H_WHY}" rx="8" fill="#faf5ff" stroke="{C_NOTE}" stroke-width="1.6"/>')
A(f'<text x="{GX+18}" y="{Y_WHY+26}" class="lb" fill="#553c9a">为什么只重启宿主机那一个？容器内 crowdsec 刻意不重启</text>')
A(f'<text x="{GX+18}" y="{Y_WHY+52}" class="lg">'
  '① 容器内 crowdsec 读的是容器里的 /etc/crowdsec/config.yaml，从来不读宿主机的 /etc/config/crowdsec。</text>')
A(f'<text x="{GX+18}" y="{Y_WHY+74}" class="lg">'
  '　　所以在宿主机 uci 里写 api_key，对它没有影响 —— 重启它不会让它"读到新配置"。</text>')
A(f'<text x="{GX+18}" y="{Y_WHY+98}" class="lg">'
  '② 重启容器内 crowdsec 会让 LAPI 短暂不可用，last_pull 时间戳断档。</text>')
A(f'<text x="{GX+18}" y="{Y_WHY+120}" class="ts" fill="#c53030">'
  '　　紧接着的 BOUNCERVERIFY 正是靠 last_pull 新鲜度（600 秒）判成功 —— 重启反而把自己判失败。</text>')
A(f'<text x="{GX+18}" y="{Y_WHY+146}" class="lg">'
  '③ 容器内 crowdsec 该重启的时机是改 config.yaml 之后：那件事由 capi_release 自己负责（解 CAPI 后重启）。</text>')

# ---------- 判据速查 ----------
A(f'<rect x="{GX}" y="{Y_TAB}" width="{GW}" height="{H_TAB}" rx="8" fill="#f7fafc" stroke="#cbd5e0"/>')
A(f'<text x="{GX+18}" y="{Y_TAB+26}" class="lb" fill="#2b6cb0">两步各自的「算通过」判据</text>')
A(f'<text x="{GX+18}" y="{Y_TAB+52}" class="lg">'
  'lapi_fetch  →  容器在跑 + LAPI 有回显 + url/login 两字段可读出</text>')
A(f'<text x="{GX+18}" y="{Y_TAB+74}" class="lg">'
  'bouncer_fill →  api_url 等于 http://容器IP:8080/ + enabled=1 + api_key 非空</text>')
A(f'<text x="{GX+18}" y="{Y_TAB+100}" class="ts" fill="#c53030">'
  '注意：bouncer_fill 的 verify 只查「填对没」，不查「生效没」。</text>')
A(f'<text x="{GX+18}" y="{Y_TAB+120}" class="lg">'
  '「生效没」是下一组 BOUNCERVERIFY 的事：bouncer 在列表里 + last_pull 不超过 600 秒。</text>')

A('</svg>')

svg = "\n".join(P)
open("lapi-group-flow.svg", "w").write(svg)
cairosvg.svg2png(bytestring=svg.encode(), write_to="lapi-group-flow.png",
                 output_width=W * 2, output_height=H * 2, background_color="white")
print(f"已生成 lapi-group-flow.svg / lapi-group-flow.png  ({W}x{H})")
