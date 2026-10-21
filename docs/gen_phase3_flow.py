#!/usr/bin/env python3
"""生成 BACKUP 仓「v.81 开机后步骤：A/B/C 三步 + step_C 决策树 + tier 3 重装自愈全貌图」SVG + 高清 PNG
内容：crowdsec-lxc-bootstrap.sh（v.81 · 旁路由锁定线）DAG 调度完成后的阶段 3——
「开机后服务链」按 installed stamp 分流：
  安装态（无 stamp）：A（容器内配置治理）→ B（crowdsec 配置与 bouncer 链路治理）→ C（last_pull 验证）
  重启态（有 stamp）：A/B 不主动治理，直接 C；仅 C 失败才复验/修 A/B
  A/B 每步：verify 就绪跳过 → fix 一次 → 复验 → 不过即 hard（v.81 起一次修复）
  C 无修复动作：纯等待 → 决策树（复验 A/B → 一次修复 → 判损坏重装 / hard）
  开机步已并入 DAG boot 组（build_ct_boot 启动链前置检查），深修链 9 函数已删
右侧：step_C() 决策树（两态共用：纯等待 90s → 纯等待窗口 60s → 复验 A/B →
  判容器损坏→五道门→full_reinstall / 一次修复→复验 C / hard）；
  enroll 例外块；与构建七步的分工；已取消的深修链清单；右下 tier 3 重装自愈块
底部：两个合法放行 + 开机并入 DAG boot 组 + 一次修复与 stamp 分流 + 等待与修复分离 + tier 3 规则

用法: python3 gen_phase3_flow.py
  输出: 同目录 phase3-flow.svg / phase3-flow.png（2x 高清，已裁精确尺寸）
"""
import os
import subprocess

W, H = 1020, 1236
OUT_DIR = os.path.dirname(os.path.abspath(__file__))
SVG = os.path.join(OUT_DIR, "phase3-flow.svg")
PNG = os.path.join(OUT_DIR, "phase3-flow.png")

# 配色（与 dag-flow / cs-build-flow 同源）：服务链主色青蓝，C 决策紫，enroll 例外橙
MAIN_FG, MAIN_BG, MAIN_BD = "#2b6cb0", "#ebf8ff", "#90cdf4"   # 蓝（服务链）
TAG_ENSURE = ("#2b6cb0", "#bee3f8")   # 蓝（ensure 语义）
TAG_DECIDE = ("#6b46c1", "#e9d8fd")   # 紫（C 验证/决策）
TAG_EXTRA = ("#dd6b20", "#feebc8")    # 橙（enroll 例外）
HARD_FG, HARD_BG, HARD_BD = "#c53030", "#fff5f5", "#fc8181"  # 红（hard）
DECIDE_FG, DECIDE_BG, DECIDE_BD = "#6b46c1", "#faf5ff", "#d6bcfa"  # 紫（决策树）

# 链卡：编号、名称、验（verify 判定）、修（fix 动作）、mono 备注、tag 类型
STEPS = [
    ("A", "容器内配置治理（网络文件/自启/resolv/日志）",
     "五判据与：容器网络文件 · 自启软链与机器身份 · resolv.conf · acquis+解析器 · 日志转发",
     "fix_A 按需补写缺项（幂等写入）+ 容器在运行则重启容器内 crowdsec 使配置生效",
     "verify_A · fix_A（setup_container_network/boot/resolv/acquis/log_forward）", "ensure"),
    ("B", "crowdsec 配置与 bouncer 链路治理",
     "listen_uri · trusted_ips · 容器 config 三文件 + 宿主机服务活 + nft 表 + 注册态",
     "fix_B：按需补写三文件 + 屏蔽 online_client → uci_apply → 等 LAPI 90s → 注册一次 → 起服务 → 等 nft 表",
     "verify_B · fix_B（_bouncer_register_once · _ensure_bouncer_service）", "ensure"),
    ("C", "last_pull 验证（无修复动作）",
     "_wait_lapi_ready 90 纯等待 + bouncer_pulling（last_pull 600s 新鲜度）",
     "纯等待窗口 60s（12×5s）；仍败 → 决策树：复验 A/B → 一次修复 → 判损坏重装 / hard",
     "step_C · _sc_wait_pull · bouncer_pulling", "decide"),
    ("⑤", "CAPI online_client 放出",
     "config.yaml 中 online_client 未注释（CAPI 经 LAPI 后启用）",
     "ensure_online_client_on（取消注释 + credentials 回 online）",
     "verify_online_client_on · ensure_online_client_on", "ensure"),
    ("⑥", "console enroll",
     "cscli capi status 已 Enrolled",
     "re_enroll 一次 shot：命令成功但 10 秒内未显示 Enrolled（等网站人工 Accept）算过",
     "phase3_step_enroll · re_enroll", "extra"),
]
TAG_STYLE = {"ensure": TAG_ENSURE, "decide": TAG_DECIDE, "extra": TAG_EXTRA}

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
  <text x="{W//2}" y="30" text-anchor="middle" class="t">v.81 开机后步骤：A/B/C 三步 + step_C 决策树 + tier 3 重装自愈（阶段 3 · BACKUP 旁路由锁定线）</text>
  <text x="{W//2}" y="52" text-anchor="middle" class="ts">stamp 分流：安装态 A→B→C 构造；重启态直接 C；每步 verify 跳过 → fix 一次 → 复验 → 不过即 hard（v.81 一次修复）</text>''')

LX, LW = 36, 640          # 左列（分流卡 + A/B/C 链）
RX, RW = 700, 284         # 右列（决策树等）
CY0, CH, CGAP = 96, 92, 20   # 卡起始 y / 卡高 / 卡间（箭头）距

# ---------- 左列顶部：stamp 分流卡 ----------
p.append(f'''
  <rect x="{LX}" y="{CY0}" width="{LW}" height="64" rx="8" fill="{MAIN_BG}" stroke="{MAIN_BD}" stroke-width="1.2"/>
  <text x="{LX+16}" y="{CY0+22}" class="b" style="font-size:12.5px" fill="{MAIN_FG}">阶段 3 入口：_stamp_present 判别（installed 标记）</text>
  <text x="{LX+16}" y="{CY0+42}" class="s" style="font-size:10px"><tspan class="b">安装态</tspan>（无 stamp，首启纯构造）→ A → B → C 依序执行，缺项修复一次 + 复验</text>
  <text x="{LX+16}" y="{CY0+58}" class="s" style="font-size:10px"><tspan class="b">重启态</tspan>（有 stamp，曾完整跑通）→ A/B 不主动治理，直接验证 C；仅 C 失败才复验/修 A/B</text>''')
AY0 = CY0 + 64
p.append(f'<line x1="{LX+LW/2}" y1="{AY0+3}" x2="{LX+LW/2}" y2="{AY0+CGAP-3}" class="ln" marker-end="url(#ar)"/>')

def step_card(x, y, w, num, name, ver, fix, note, kind):
    tfg, tbg = TAG_STYLE[kind]
    tag = {"ensure": "ensure", "decide": "验证/决策", "extra": "例外"}[kind]
    p.append(f'''
  <rect x="{x}" y="{y}" width="{w}" height="{CH}" rx="8" fill="#ffffff" stroke="{'#fbd38d' if kind=='extra' else '#cbd5e0'}" stroke-width="1"/>
  <circle cx="{x+24}" cy="{y+21}" r="12" fill="{MAIN_BG}" stroke="{MAIN_BD}" stroke-width="1.2"/>
  <text x="{x+24}" y="{y+25}" text-anchor="middle" class="b" fill="{MAIN_FG}" style="font-size:12px">{num}</text>
  <text x="{x+44}" y="{y+25}" class="b" style="font-size:12.5px">{name}</text>
  <rect x="{x+w-72}" y="{y+8}" width="60" height="15" rx="7" fill="{tbg}"/>
  <text x="{x+w-42}" y="{y+19}" text-anchor="middle" class="tag" fill="{tfg}">{tag}</text>
  <text x="{x+16}" y="{y+47}" class="s" style="font-size:10px"><tspan class="b" fill="{MAIN_FG}">验</tspan>　{ver}</text>
  <text x="{x+16}" y="{y+64}" class="s" style="font-size:10px"><tspan class="b" fill="{MAIN_FG}">修</tspan>　{fix}</text>
  <text x="{x+16}" y="{y+83}" class="s mono" style="font-size:9px;fill:#a0aec0">{note}</text>''')

CY1 = AY0 + CGAP   # A 卡起始
for i, (num, name, ver, fix, note, kind) in enumerate(STEPS):
    y = CY1 + i * (CH + CGAP)
    step_card(LX, y, LW, num, name, ver, fix, note, kind)
    if i < len(STEPS) - 1:
        ay1 = y + CH + 3
        ay2 = y + CH + CGAP - 3
        p.append(f'<line x1="{LX+LW/2}" y1="{ay1}" x2="{LX+LW/2}" y2="{ay2}" class="ln" marker-end="url(#ar)"/>')

CHAIN_BOT = CY1 + len(STEPS) * CH + (len(STEPS) - 1) * CGAP   # 链底 y
RCOL_BOT = CY0 + 828                  # 右列底

# ---------- 右列：step_C() 决策树 ----------
p.append(f'''
  <rect x="{RX}" y="{CY0}" width="{RW}" height="300" rx="8" fill="{DECIDE_BG}" stroke="{DECIDE_BD}" stroke-width="1"/>
  <rect x="{RX}" y="{CY0}" width="{RW}" height="26" rx="8" fill="{DECIDE_FG}"/>
  <rect x="{RX}" y="{CY0+16}" width="{RW}" height="10" fill="{DECIDE_FG}"/>
  <text x="{RX+RW/2}" y="{CY0+18}" text-anchor="middle" class="tag" fill="#ffffff" style="font-size:11px">step_C() 决策树（安装态/重启态共用）</text>''')
mx = RX + 14
tree = [
    (CY0+42,  "b", "① _wait_lapi_ready 90（纯等待）"),
    (CY0+57,  "s", "　bouncer_pulling 真 → 就绪 return 0"),
    (CY0+76,  "b", "② verify_lapi_ready 真 → _sc_wait_pull"),
    (CY0+91,  "s", "　60s 纯等待窗口（12×5s，只观察）"),
    (CY0+106, "s", "　last_pull 刷新 → 就绪 return 0"),
    (CY0+125, "b", "③ 仍未就绪 → 复验 A/B 定位根因"),
    (CY0+141, "s", "　├ A/B 全正常 → 配置正确 = 容器损坏"),
    (CY0+156, "s", "　│　→ 五道门 → full_reinstall 重装"),
    (CY0+171, "s", "　│　门拒/exec 未接管 → hard exit 1"),
    (CY0+190, "s", "　└ A/B 有缺项 → fix_A/fix_B 一次"),
    (CY0+205, "s", "　　复验 A/B 正常 → 再等一轮 ①+②"),
    (CY0+220, "s", "　　　├ 恢复 → return 0"),
    (CY0+235, "s", "　　　├ 仍拉不到 → 容器损坏 → 重装"),
    (CY0+250, "s", "　　　└ 修不好 → hard exit 1"),
]
for ty, cls, txt in tree:
    p.append(f'<text x="{mx}" y="{ty}" class="{cls}" style="font-size:9.5px">{txt}</text>')
p.append(f'''
  <rect x="{RX+10}" y="{CY0+262}" width="{RW-20}" height="28" rx="5" fill="#ffffff" stroke="{DECIDE_BD}" stroke-width="1"/>
  <text x="{RX+RW/2}" y="{CY0+280}" text-anchor="middle" class="s" style="font-size:9.5px">等待与修复严格分离：①②只 sleep+探测，③ 才动 A/B</text>''')

# ---------- 右列：enroll 例外块（橙）----------
p.append(f'''
  <rect x="{RX+12}" y="{CY0+314}" width="{RW-24}" height="150" rx="6" fill="#fffaf0" stroke="#fbd38d" stroke-width="1"/>
  <text x="{RX+24}" y="{CY0+336}" class="b" style="font-size:10.5px" fill="#dd6b20">enroll 例外（⑥）</text>
  <text x="{RX+24}" y="{CY0+356}" class="s" style="font-size:9.5px">phase3_step_enroll：</text>
  <text x="{RX+24}" y="{CY0+371}" class="s" style="font-size:9.5px">fix 返 0 即过，不做事后</text>
  <text x="{RX+24}" y="{CY0+386}" class="s" style="font-size:9.5px">复核——命令成功但 10 秒</text>
  <text x="{RX+24}" y="{CY0+401}" class="s" style="font-size:9.5px">内未 Enrolled 是等网站</text>
  <text x="{RX+24}" y="{CY0+416}" class="s" style="font-size:9.5px">人工 Accept 的合法中间态，</text>
  <text x="{RX+24}" y="{CY0+431}" class="s" style="font-size:9.5px">复核会误杀</text>
  <text x="{RX+24}" y="{CY0+450}" class="s" style="font-size:9.5px">无注册码（key 文件为空）</text>
  <text x="{RX+24}" y="{CY0+465}" class="s" style="font-size:9.5px">→ 记日志跳过，本地防护</text>
  <text x="{RX+24}" y="{CY0+480}" class="s" style="font-size:9.5px">不受影响</text>''')

# ---------- 右列：与构建七步分工 + 已取消深修链 ----------
p.append(f'''
  <text x="{mx}" y="{CY0+504}" class="b" style="font-size:10.5px" fill="{MAIN_FG}">与构建七步的分工</text>
  <text x="{mx}" y="{CY0+520}" class="s" style="font-size:9.5px">构建七步：容器内产物就绪</text>
  <text x="{mx}" y="{CY0+535}" class="s" style="font-size:9.5px">（rootfs 落盘，boot 组内）</text>
  <text x="{mx}" y="{CY0+550}" class="s" style="font-size:9.5px">本链：服务真的通（A→B→C）</text>
  <text x="{mx}" y="{CY0+575}" class="b" style="font-size:10.5px" fill="{HARD_FG}">已取消：深修链 9 函数（v.81）</text>
  <text x="{mx}" y="{CY0+591}" class="s" style="font-size:9.5px">_bouncer_heal · _crowdsec_repair ·</text>
  <text x="{mx}" y="{CY0+606}" class="s" style="font-size:9.5px">_restart_bouncer_service ·</text>
  <text x="{mx}" y="{CY0+621}" class="s" style="font-size:9.5px">_fix_lapi_ready · _fix_bouncer_link ·</text>
  <text x="{mx}" y="{CY0+636}" class="s" style="font-size:9.5px">verify_bouncer_link · verify_container_boot</text>
  <text x="{mx}" y="{CY0+651}" class="s" style="font-size:9.5px">+ _fix_container_boot · setup_crowdsec_config</text>
  <text x="{mx}" y="{CY0+670}" class="s" style="font-size:9.5px">→ 剩余动作全是幂等写入，首启不跑修复</text>''')

# ---------- 右列：tier 3 重装自愈块（红）----------
p.append(f'''
  <rect x="{RX+12}" y="{CY0+686}" width="{RW-24}" height="142" rx="6" fill="#fff5f5" stroke="{HARD_BD}" stroke-width="1"/>
  <text x="{RX+24}" y="{CY0+708}" class="b" style="font-size:10.5px" fill="{HARD_FG}">tier 3 重装自愈（C 失败判损坏）</text>
  <text x="{RX+24}" y="{CY0+726}" class="s" style="font-size:9.5px">五道门全过才抹 rootfs：</text>
  <text x="{RX+24}" y="{CY0+741}" class="s" style="font-size:9.5px">① last_pull 仍失效（已恢复→无益）</text>
  <text x="{RX+24}" y="{CY0+756}" class="s" style="font-size:9.5px">② installed 标记在位（曾跑通）</text>
  <text x="{RX+24}" y="{CY0+771}" class="s" style="font-size:9.5px">③ 失败计数 &lt; 2（达到转人工）</text>
  <text x="{RX+24}" y="{CY0+786}" class="s" style="font-size:9.5px">④ 非重装后流程（禁递归）</text>
  <text x="{RX+24}" y="{CY0+801}" class="s" style="font-size:9.5px">⑤ 镜像 gzip -t 过</text>
  <text x="{RX+24}" y="{CY0+819}" class="s" style="font-size:9.5px">全过 → 备份凭证 → 强停 → 抹 rootfs</text>''')

# ---------- 底部说明 ----------
BY = RCOL_BOT + 24
p.append(f'''
  <rect x="{LX}" y="{BY}" width="{W-LX*2}" height="252" rx="10" fill="#f7fafc" stroke="#cbd5e0" stroke-width="1"/>
  <text x="{LX+16}" y="{BY+22}" class="b" style="font-size:12.5px">两个刻意保留的合法放行</text>
  <text x="{LX+16}" y="{BY+42}" class="s" style="font-size:10px">① enroll 的「命令成功但 10 秒内未显示 Enrolled」（等网站人工 Accept）算通过——phase3_step_enroll 信 fix 自带终态判定；</text>
  <text x="{LX+16}" y="{BY+59}" class="s" style="font-size:10px">② 未配置注册码（$ENROLL_KEY_FILE 缺失或为空）→ 明确记日志跳过 enroll，本地防护不受影响（不因可选功能让开机失败）。</text>
  <text x="{LX+16}" y="{BY+82}" class="b" style="font-size:12.5px">开机已并入 DAG boot 组（v.81）</text>
  <text x="{LX+16}" y="{BY+102}" class="s" style="font-size:10px">build_ct_boot 开头做启动链内容级前置检查（verify_ct_config + verify_rootfs）：缺链不开机、不重写、不重建，复核不过即 hard——</text>
  <text x="{LX+16}" y="{BY+119}" class="s" style="font-size:10px">容器级损坏不在此处盲目施救，留给 C 失败链判重装；_ct_revive 退为纯 revive（启动链共用）。</text>
  <text x="{LX+16}" y="{BY+142}" class="b" style="font-size:12.5px">一次修复 + stamp 分流 + 等待与修复分离（v.81 三原则）</text>
  <text x="{LX+16}" y="{BY+162}" class="s" style="font-size:10px">① 三处循环（ensure / ensure_sub / phase3_step）全部单次化：安装顺序保证前置就绪，修一次不过即 hard，「多修复一次没必要」；</text>
  <text x="{LX+16}" y="{BY+179}" class="s" style="font-size:10px">② 首启/重启以 installed stamp 判别：重启态健康路径只跑 C（last_pull 为健康信号），A/B 退化静默由 C 失败兜底；</text>
  <text x="{LX+16}" y="{BY+196}" class="s" style="font-size:10px">③ C 的等待（90s + 60s 窗口）不夹带任何写入/重启——刚注册完 bouncer 有拉取周期，无窗口会把「刚修好」误判「容器损坏」。</text>
  <text x="{LX+16}" y="{BY+219}" class="b" style="font-size:12.5px" fill="#c53030">tier 3 重装自愈（C 失败且 A/B 复验正常 → 判容器损坏）</text>
  <text x="{LX+16}" y="{BY+238}" class="s" style="font-size:10px">安装态（无 stamp）门② 必拒——初次安装不运行，防开机反复重置；五门全过：备份凭证 → 强停容器 → 抹 rootfs → REINSTALL=1 二遍，成功写 stamp 即清零</text>
  <text x="{LX+16}" y="{BY+252-6}" class="s mono" style="font-size:9px;fill:#a0aec0">main() 阶段 3：[REINSTALL=1 → _cred_restore] → [_recovering → shield] → _stamp_present ? step_C : (verify_A→fix_A) → (verify_B→fix_B) → step_C → online_client 放出</text>''')

p.append('</svg>')
svg = "\n".join(p)
with open(SVG, "w", encoding="utf-8") as f:
    f.write(svg)
print(f"written: {SVG} ({W}x{H})")

# ---- 渲染 PNG（2x 高清，crop 精确尺寸，quantize 压缩）----
html = os.path.join(OUT_DIR, "render-p3.html")
with open(html, "w", encoding="utf-8") as f:
    f.write(f'''<!DOCTYPE html><html><head><meta charset="utf-8"><style>
html,body{{margin:0;padding:0;background:#ffffff}}
img{{display:block;width:{W}px;height:{H}px}}
</style></head><body><img src="file://{SVG}"></body></html>''')

shot = os.path.join(OUT_DIR, "_p3_shot.png")
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
