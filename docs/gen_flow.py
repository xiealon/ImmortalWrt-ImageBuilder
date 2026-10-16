#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 CrowdSec LXC 引导流程图 SVG（v.63）
用法: python3 gen_flow.py  →  同目录 crowdsec-flow.svg（末尾打印总高 H）

渲染高清 PNG（2x，需 Noto Sans CJK 字体）——本机 Chromium 有两个坑，须按下面方法来：
  ① 有效视口比 --window-size 高低 88px，直渲 SVG 会裁掉底部 →
     先写个 render.html：body 白底，内嵌 <img src="file://.../crowdsec-flow.svg"
     style="display:block;width:680px;height:Hpx">，让文档高度精确等于 H；
     窗口按 680×(H+100) 开（--force-device-scale-factor=2），
     截图后用 PIL crop((0,0,1360,2*H)) 裁回精确尺寸
  ② SVG 根无背景，窗口高出文档的透明区会拍成黑带 → 生成器已内置全幅白矩形，
     渲染再加 --default-background-color=FFFFFFFF 双保险
  ③ 压缩：PIL convert('RGB').quantize(colors=256, MEDIANCUT, FLOYDSTEINBERG)
     + optimize，约 1.3MB → 460KB，文字仍锐利
"""

W = 680
X_BIG, W_BIG = 30, 200          # 大步骤框（左列）
X_SML, W_SML = 260, 400         # 小步骤框（右列）
CX_BIG = X_BIG + W_BIG/2        # 130
CX_SML = X_SML + W_SML/2        # 460
X_R = X_SML + W_SML             # 660 小框右缘

import os

def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

WIDE_SYM = set("—…“”‘’→←↑↓↔")

def _cw(ch):
    o = ord(ch)
    if o >= 0x2E80 or ch in WIDE_SYM or 0x2460 <= o <= 0x24FF:
        return 1.0
    return 0.55

def wrap(s, width):
    """按显示宽度折行（CJK/全角=1，ASCII≈0.55）"""
    out, cur, curw = [], "", 0.0
    for ch in s:
        w = _cw(ch)
        if cur and curw + w > width:
            out.append(cur.rstrip())
            cur, curw = "", 0.0
            if ch == " ":
                continue
        cur += ch
        curw += w
    if cur.strip():
        out.append(cur.rstrip())
    return out or [""]

STEP_COLORS = {
    "node": "#4a5568", "nodeBlue": "#2b6cb0", "nodeGreen": "#38a169",
    "nodeOrange": "#dd6b20", "nodeRed": "#c53030", "nodePurple": "#6b46c1",
}

parts = []
parts.append(f'''<svg viewBox="0 0 {W} 2960" xmlns="http://www.w3.org/2000/svg" font-family="-apple-system,'PingFang SC','Microsoft YaHei','Noto Sans CJK SC',sans-serif">
  <defs>
    <marker id="arr" markerWidth="9" markerHeight="9" refX="7" refY="3" orient="auto" markerUnits="strokeWidth"><path d="M0,0 L7,3 L0,6 z" fill="#4a5568"/></marker>
    <marker id="arrRed" markerWidth="9" markerHeight="9" refX="7" refY="3" orient="auto" markerUnits="strokeWidth"><path d="M0,0 L7,3 L0,6 z" fill="#c53030"/></marker>
    <marker id="arrGreen" markerWidth="9" markerHeight="9" refX="7" refY="3" orient="auto" markerUnits="strokeWidth"><path d="M0,0 L7,3 L0,6 z" fill="#38a169"/></marker>
    <marker id="arrOrange" markerWidth="9" markerHeight="9" refX="7" refY="3" orient="auto" markerUnits="strokeWidth"><path d="M0,0 L7,3 L0,6 z" fill="#dd6b20"/></marker>
    <marker id="arrPurple" markerWidth="9" markerHeight="9" refX="7" refY="3" orient="auto" markerUnits="strokeWidth"><path d="M0,0 L7,3 L0,6 z" fill="#6b46c1"/></marker>
  </defs>
  <style>
    .title{{font-size:17px;font-weight:700;fill:#1a202c;}}
    .ver{{font-size:11px;fill:#718096;}}
    .sub{{font-size:13px;font-weight:700;fill:#2b6cb0;}}
    .sub2{{font-size:12px;font-weight:600;fill:#dd6b20;}}
    .node{{fill:#fff;stroke:#4a5568;stroke-width:1.3;}}
    .nodeBlue{{fill:#ebf8ff;stroke:#2b6cb0;stroke-width:1.8;}}
    .nodeGreen{{fill:#f0fff4;stroke:#38a169;stroke-width:1.8;}}
    .nodeOrange{{fill:#fffaf0;stroke:#dd6b20;stroke-width:1.8;}}
    .nodeRed{{fill:#fff5f5;stroke:#c53030;stroke-width:1.8;}}
    .nodePurple{{fill:#faf5ff;stroke:#6b46c1;stroke-width:1.8;}}
    .sml{{fill:#ffffff;stroke:#a0aec0;stroke-width:1.1;}}
    .nt{{font-size:12px;font-weight:700;text-anchor:middle;}}
    .nd{{font-size:10px;text-anchor:middle;fill:#4a5568;}}
    .ndl{{font-size:10px;text-anchor:start;fill:#4a5568;}}
    .mono{{font-family:'SFMono-Regular',Consolas,'Noto Sans CJK SC',monospace;font-size:9px;text-anchor:middle;fill:#2d3748;}}
    .bignum{{font-size:30px;font-weight:700;text-anchor:middle;}}
    .loop{{stroke:#dd6b20;stroke-width:1.6;stroke-dasharray:6 4;fill:none;}}
    .loopt{{font-size:9px;fill:#c05621;}}
  </style>
  <rect x="0" y="0" width="680" height="4096" fill="#ffffff"/>
  <text x="340" y="26" class="title" text-anchor="middle">CrowdSec LXC · 详细流程架构图</text>
  <text x="340" y="44" class="ver" text-anchor="middle">v.2026-10-16.63 ｜ 左=大步骤框，右=小步骤框（①.a 式编号）｜ 重建 = 强停→删容器→exec 重跑（CS_REBUILT 防循环）</text>
  <text x="340" y="58" class="ver" text-anchor="middle">灰实线 = 正常流向 ｜ 红虚线 = 失效 / 重试分支 ｜ 橙虚线 = exec 重跑回路 ｜ exit 0/1 = 脚本终止</text>
''')

def rect(x, y, w, h, cls):
    parts.append(f'  <rect x="{x}" y="{y}" width="{w}" height="{h}" rx="7" class="{cls}"/>')

def text(x, y, s, cls, anchor=None):
    a = f' text-anchor="{anchor}"' if anchor else ""
    parts.append(f'  <text x="{x}" y="{y}" class="{cls}"{a}>{esc(s)}</text>')

def line(x1, y1, x2, y2, color="#4a5568", w=1.5, marker="arr"):
    m = f' marker-end="url(#{marker})"' if marker else ""
    parts.append(f'  <line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{color}" stroke-width="{w}"{m}/>')

def fail_path(d):
    """失效分支：红色虚线 + 红箭头"""
    parts.append(f'  <path d="{d}" fill="none" stroke="#c53030" stroke-width="1.4" stroke-dasharray="5 3" marker-end="url(#arrRed)"/>')

def fail_bypass(key_from, key_to, xc):
    """右缘通道绕行：A 框右缘 → 通道 xc → B 框右缘"""
    _, cyA, _, _ = sml_pos[key_from]
    _, cyB, _, _ = sml_pos[key_to]
    fail_path(f"M{X_R},{cyA} L{xc},{cyA} L{xc},{cyB} L{X_R},{cyB}")

def small_box(x, y, w, label, body, wrapw, color="#4a5568"):
    """小步骤框：白底灰边，label 着色加粗，自动折行；返回框高"""
    lines = wrap(f"{label} {body}", wrapw)
    h = 14*len(lines) + 10
    parts.append(f'  <rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" class="sml"/>')
    rest0 = lines[0][len(label):].lstrip()
    lab = f'<tspan style="font-weight:700;fill:{color}">{esc(label)}</tspan>'
    if rest0:
        parts.append(f'  <text x="{x+12}" y="{y+16}" class="ndl">{lab} {esc(rest0)}</text>')
    else:
        parts.append(f'  <text x="{x+12}" y="{y+16}" class="ndl">{lab}</text>')
    for j in range(1, len(lines)):
        text(x+12, y+16+14*j, lines[j], "ndl")
    return h

# ==================== 顶部：开机起算时间线 ====================
parts.append('  <rect x="14" y="66" width="652" height="58" rx="7" fill="#f7fafc" stroke="#cbd5e0" stroke-width="1"/>')
text(24, 80, "开机起算 · 引导时间线（最坏等待；健康重启通常 <1 分钟走完前三步）", "sub")
_tl = [
    ("rc.local", "触发 bootstrap", "node"),
    ("等容器 RUNNING", "≤60s（12×5s）", "nodeBlue"),
    ("等 LAPI 就绪", "≤90s（1s 轮询）", "nodeBlue"),
    ("bouncer 检查", "0s 直接判定", "node"),
    ("heal 每轮 ×2", "≤90+90+12+60s", "nodeOrange"),
    ("repair→重建", "30s→exec 重跑", "nodeRed"),
]
_tw, _th, _gap, _tx = 96, 32, 12.8, 20
for _i, (_t1, _t2, _cls) in enumerate(_tl):
    rect(_tx, 88, _tw, _th, _cls)
    text(_tx + _tw/2, 101, _t1, "nt")
    text(_tx + _tw/2, 113, _t2, "nd")
    if _i < len(_tl) - 1:
        line(_tx + _tw, 104, _tx + _tw + _gap, 104, w=1.4)
    _tx += _tw + _gap

# ==================== 一、开机自启链路 ====================
text(20, 140, "一、开机自启链路（v.56 起弃用 lxc-auto，只剩一条路径）", "sub")
rect(20, 152, 120, 46, "nodeOrange");  text(80, 171, "开机", "nt");  text(80, 187, "procd 启动", "nd")
line(140, 175, 164, 175, w=1.8)
rect(164, 152, 150, 46, "node");  text(239, 170, "/etc/rc.local", "nt");  text(239, 186, "判锁+检查镜像", "nd")
line(314, 175, 338, 175, w=1.8)
rect(338, 152, 150, 46, "node");  text(413, 170, "bootstrap 脚本", "nt");  text(413, 186, "/usr/sbin/...sh", "mono")
line(488, 175, 512, 175, w=1.8)
rect(512, 152, 150, 46, "nodeBlue");  text(587, 170, "lxc-start -d", "nt");  text(587, 186, "-n ubuntu -d", "mono")

det1 = [
    "procd boot 阶段执行 /etc/rc.local → mkdir 锁防重入 → 检查镜像 tarball 或 rootfs；都无 → bootstrap exit 0 跳过（本机不带 CS）",
    "/bin/sh /usr/sbin/crowdsec-lxc-bootstrap.sh >> 日志；bootstrap 先 disable lxc-auto（幂等，失败不阻断）",
    "挂 systemd cgroup（幂等）→ lxc-start -P /srv/lxc -n ubuntu -d → 容器 RUNNING；两次起不来 → _ct_revive 施救（二.⑦）",
]
dy1 = 214
db = dy1
for i, d in enumerate(det1):
    h = small_box(20 + i*210, dy1, 200, f"一.{chr(97+i)}", d, 17, "#2b6cb0")
    db = max(db, dy1 + h)
line(413, 198, 413, dy1)

# ==================== 二、bootstrap 脚本流程 ====================
sec2_top = db + 52
text(20, db + 24, "二、bootstrap 脚本流程（每次开机，rc.local 触发）", "sub")
parts.append(f'  <path d="M400,{db} L400,{db+34} L130,{db+34} L130,{sec2_top}" fill="none" stroke="#4a5568" stroke-width="1.5" marker-end="url(#arr)"/>')

# (编号, 标题, 副标题, 节点样式, [小步骤正文])
steps = [
    ("①", "镜像迁移", "旧→新路径", "node", [
        "tarball 缺失：/opt/ 有旧镜像 → mv 迁移到 /etc/crowdsec/；两者都无 → exit 0 跳过（本机不带 CrowdSec）",
        "（.52 起移除 chattr +i 防误删——OpenWrt 无此命令，锁从未生效还刷警告）",
    ]),
    ("②", "模式判定", "config.yaml 在?", "node", [
        "rootfs 内 config.yaml 不存在 → _recovering=true（首次/恢复全流程）",
        "存在 → 后续重启模式：跳过解压，直接配置 + 启动 + 验 LP",
    ]),
    ("③", "容器 config", "缺失才写", "node", [
        "/srv/lxc/ubuntu/config 不存在才写；apply_cfg 剪掉不被 lxc 支持的行，解析失败 → exit 1 终止",
        "rootfs.path=dir:/srv/lxc/ubuntu/rootfs；静态 IP 10.0.0.10/24",
    ]),
    ("④", "解压 rootfs", "仅首次/恢复", "node", [
        "rebuild_from_image：停容器 → 删 rootfs → tar 解压（.extracting 锁）；解压失败 → exit 1 终止",
        "CS_REBUILT=1 防开机循环：一次开机最多重建一次",
    ]),
    ("⑤", "运行期配置", "网桥+容器+解析", "node", [
        "setup_bridge：lxcbr0 10.0.0.1/24 + 防火墙 lxc 区 ACCEPT",
        "容器静态 IP 10.0.0.10/24 网关 10.0.0.1；DNS 源文件 trim（.53：1 字节空白不再写出空 nameserver）",
        "setup_container_boot：networkd + crowdsec 软链 + hostname/machine-id",
        "resolv.conf + 日志源 + listen_uri 0.0.0.0:8080 + trusted_ips 含 10.0.0.1；prepare_container 失败 → exit 1",
    ]),
    ("⑥", "安装前屏蔽 CAPI", "仅首次/恢复 off", "nodeOrange", [
        "仅首次/恢复：ensure_online_client_off 注释 online_client，LAPI 干净独立启动；失败仅告警不阻断",
        "后续重启不在此屏蔽——只在 last pull 验证失败后才屏蔽（见第四节）",
    ]),
    ("⑦", "启动容器", "cgroup + lxc-start -d", "nodeBlue", [
        "v.54：grep /proc/mounts 无 /sys/fs/cgroup/systemd → mount name=systemd（手动运行不经 lxc-auto boot()，否则容器内 systemd 20 秒内 STOPPED）",
        "lxc-start -P /srv/lxc -n ubuntu -d 直接守护进程化（不经 lxc-auto 前台，不卡死）",
        "v.56：lxc-auto disable 幂等禁用（开机自启统一由 rc.local→本脚本链负责，弃用 lxc-auto）",
        "两次 lxc-start -d 失败 → _ct_revive：补挂 cgroup → 强停+重写 config 重启 → 仍无效则重建重装（v.57，exec 回路见三节）",
        "_wait_lapi_ready 等 cscli bouncers list 就绪（≤90s，.53）；90s 超时仅告警继续，注册成败交 ⑨ 判定",
    ]),
    ("⑧", "日志转发", "宿主机→容器", "node", [
        "配置 OpenWrt logd 远程转发：log_ip=10.0.0.10, log_port=514, log_proto=udp；失败不阻断主流程",
        "宿主机系统日志经 UDP 514 发到容器 CrowdSec 采集",
    ]),
    ("⑨", "bouncer 注册", "查 last_pull", "nodeOrange", [
        "固化 UCI bouncer 字段：api_url=http://10.0.0.10:8080/、enabled=1、ipv4=1；失败 → 跳过注册块，直落 ⑩",
        "v.53：每轮注册前 _wait_lapi_ready，等 LAPI 就绪再 cscli bouncers add；add 失败 → ⑨.e 下一轮",
        "bouncer_pulling() 判据：name 匹配 + last_pull 非空",
        "v.55：陈旧阈值 BOUNCER_PULL_MAX_AGE=600s（阈值非等待）——last_pull 超龄未更新也判失效，堵 LAPI 僵死盲区",
        "失效 → _bouncer_heal 2 轮：等 LAPI≤90s → 删旧注册拿 key → 容器内重启 crowdsec → 再等 LAPI≤90s → 重启路由器 bouncer+12s → 此后才计 60s 验证窗口",
        "2 轮未通 → _crowdsec_repair：容器级施救 → 配置校验 → UCI 对齐 → 重注册 → 重启两端 → 重验（见三节）",
    ]),
    ("⑩", "CAPI 放出+enroll", "按模式，见第四节", "nodePurple", [
        "判据：bouncer_pulling（LAPI 侧 last_pull 有效?）——安装后再确认一次",
        "有 → 放出 on + _try_enroll；无 → 屏蔽 off + 诊断（分支见第三节）",
        "v.63：开机判定只看 Enrolled——enroll 后需网页端 Accept，此前 authenticated 不会有，不查",
        "v.63：enroll 前等 api.crowdsec.net 可解析（≤30s 墙钟、就绪即止），治开机 DNS 未就绪秒退；enroll 输出与 capi status 进日志",
    ]),
    ("⑪", "nft 检查", "链路打通", "nodeGreen", [
        "nft list table ip crowdsec → 有表则链路打通；无表 → 记日志检查 bouncer 日志，引导结束 exit 0",
    ]),
]

sml_pos = {}   # "⑦.b" -> (右缘x, 中心y, 底y, 顶y)
y = sec2_top
prev_lb = None
pos4 = None
for num, t, sub, cls, det in steps:
    hs = [14*len(wrap(f"{num}.{chr(97+i)} {d}", 37)) + 10 for i, d in enumerate(det)]
    block_h = max(40, sum(hs) + 12*(len(hs)-1))
    if prev_lb is not None:
        parts.append(f'  <path d="M460,{prev_lb} L460,{prev_lb+13} L130,{prev_lb+13} L130,{y}" fill="none" stroke="#4a5568" stroke-width="1.5" marker-end="url(#arr)"/>')
    rect(X_BIG, y, W_BIG, block_h, cls)
    text(CX_BIG, y+18, f"{num} {t}", "nt")
    text(CX_BIG, y+34, sub, "nd")
    if block_h > 70:
        parts.append(f'  <text x="{CX_BIG}" y="{y+block_h-12}" class="bignum" fill="{STEP_COLORS[cls]}" fill-opacity="0.16">{num}</text>')
    sy = y
    for i, d in enumerate(det):
        h = hs[i]
        if i == 0:
            line(X_BIG+W_BIG, sy+h/2, X_SML, sy+h/2)
        else:
            line(CX_SML, sy-12, CX_SML, sy)
        small_box(X_SML, sy, W_SML, f"{num}.{chr(97+i)}", d, 37, STEP_COLORS[cls])
        sml_pos[f"{num}.{chr(97+i)}"] = (X_R, sy+h/2, sy+h, sy)
        sy += h + 12
    prev_lb = sy - 12
    if num == "④":
        pos4 = y + block_h/2
    y += block_h + 26
sec2_bottom = prev_lb

# ==================== 三、修复 → 重建 ====================
y3 = sec2_bottom + 30
text(30, y3, "三、CAPI 段：LP 失效 → repair 修复（不重建）→ 重建", "sub")
ry = y3 + 18
rect(30, ry, 200, 40, "nodeRed");  text(130, ry+16, "last pull 验证失败", "nt");  text(130, ry+31, "bouncer_pulling=false", "nd")
text(250, ry+24, "先 ensure_online_client_off 屏蔽 CAPI", "ndl")
line(130, ry+40, 130, ry+68, color="#c53030", w=1.8, marker="arrRed")

ry2 = ry + 68
rect(30, ry2, 260, 40, "nodeOrange");  text(160, ry2+16, "_crowdsec_repair（不重建路径）", "nt");  text(160, ry2+31, "容器级施救 + 服务级修复", "nd")
rect(300, ry2, 185, 40, "node");  text(392, ry2+16, "① 容器级施救", "nt");  text(392, ry2+31, "未运行/无 IP", "nd")
line(290, ry2+20, 300, ry2+20)
rect(500, ry2, 160, 40, "node");  text(580, ry2+16, "② 服务级修复", "nt");  text(580, ry2+31, "重配+重注册+重启", "nd")
line(485, ry2+20, 500, ry2+20)

cy = ry2 + 66
dcx, dcy = 340, cy + 28
parts.append(f'  <polygon points="{dcx},{cy} {dcx+80},{dcy} {dcx},{dcy+56} {dcx-80},{dcy}" fill="#fffaf0" stroke="#dd6b20" stroke-width="1.8"/>')
text(dcx, dcy+4, "重验", "nt")
text(dcx, dcy+18, "bouncer_pulling?", "nd")
parts.append(f'  <path d="M160,{ry2+40} L160,{ry2+52} L340,{ry2+52} L340,{cy}" fill="none" stroke="#4a5568" stroke-width="1.5" marker-end="url(#arr)"/>')

fy = dcy + 56
line(dcx+80, dcy, 600, dcy, color="#38a169", w=1.8, marker=None)
line(600, dcy, 600, fy, color="#38a169", w=1.8, marker="arrGreen")
rect(500, fy, 160, 40, "nodeGreen");  text(580, fy+16, "修复成功 → 放出", "nt");  text(580, fy+31, "online_client + enroll", "nd")

line(dcx-80, dcy, 130, dcy, color="#c53030", w=1.8, marker=None)
line(130, dcy, 130, fy, color="#c53030", w=1.8, marker="arrRed")
rect(30, fy, 200, 40, "nodeRed");  text(130, fy+16, "修复无效 → 重建", "nt");  text(130, fy+31, "_crowdsec_rebuild", "nd")
line(130, fy+40, 130, fy+68, w=1.8)
rect(30, fy+68, 200, 40, "nodeBlue");  text(130, fy+84, "删容器 → exec 重跑", "nt");  text(130, fy+99, "CS_REBUILT 限一次", "nd")

# exec 回路 → 回到 ④ 解压 rootfs（左侧竖线，避开小步骤框）
loop_y = fy + 118
parts.append(f'  <path d="M130,{fy+108} L130,{loop_y} L18,{loop_y} L18,{pos4} L30,{pos4}" fill="none" class="loop" marker-end="url(#arrOrange)"/>')
text(246, fy+92, "exec 重跑 → 回到 ④ 解压 rootfs（首次/恢复全流程）", "loopt")

# ---- 失效分支箭头（红虚线）----
# ⑦.b 启动两次失败 → ⑦.d _ct_revive（右缘通道绕行，跨过 ⑦.c）
fail_bypass("⑦.b", "⑦.d", 668)
# ⑨.d LP 判据失效 → ⑨.e _bouncer_heal（底部平行短箭）
_, _, b9d, _ = sml_pos["⑨.d"]
_, _, _, t9e = sml_pos["⑨.e"]
fail_path(f"M620,{b9d} L620,{t9e}")
# ⑨.e 2 轮未通 → ⑩.a CAPI 段复判（右缘通道绕行，跨过 ⑨.f）
fail_bypass("⑨.e", "⑩.a", 664)
# ⑩.b LP 失效 → 三节 repair 触发红框（右缘通道 → 节标题下方横线 → 红框顶）
_, cy10b, _, _ = sml_pos["⑩.b"]
fail_path(f"M{X_R},{cy10b} L672,{cy10b} L672,{sec2_bottom+40} L130,{sec2_bottom+40} L130,{ry}")

det3 = [
    "触发：⑨ 注册后 CAPI 段复判 bouncer_pulling，LP 失效先 ensure_online_client_off 屏蔽 online_client",
    "repair-① 容器未运行 → _ct_revive 0：补挂 systemd cgroup + 重写容器 config 重启（不重建，失败交回上层）",
    "repair-② 容器在运行但无 IP 10.0.0.10 → 重写 .network/resolv.conf + 强停重启（resolv.conf 走 _container_dns 兜底：空源文件回落 BRIDGE_IP 10.0.0.1——v.52 实战踩坑：空 nameserver 全链路连不上）",
    "repair-③ 配置校验 → UCI 对齐 → _wait_lapi_ready → 重注册 → 重启 crowdsec+bouncer 两端 → 6×5s 重验；注册失败或重验不过 → return 1，交回上层重建（三.f）",
    "重验通过 → 放出 online_client + _try_enroll → 收尾 nft 检查",
    "重验不过 → _crowdsec_rebuild：强停+删 rootfs（删不净强杀+清挂载再删）→ exec 重跑全流程；CS_REBUILT=1 限一次",
]
by = fy + 128
for i, d in enumerate(det3):
    h = small_box(30, by, 620, f"三.{chr(97+i)}", d, 59, "#dd6b20")
    by += h + 10
y4 = by + 14

# ==================== 四、CAPI 决策 ====================
text(20, y4, "四、CAPI(online_client) 屏蔽 / 放出 决策（按启动模式）", "sub")
by4 = y4 + 12
parts.append(f'  <rect x="20" y="{by4}" width="620" height="22" rx="6" fill="#f7fafc" stroke="#cbd5e0" stroke-width="1"/>')
text(32, by4+15, "屏蔽 = 注释 online_client（ensure_online_client_off）｜放出 = 取消注释（ensure_online_client_on，同一套 sed）", "ndl")

my = by4 + 40
rect(240, my, 200, 40, "nodePurple");  text(340, my+16, "判定模式", "nt");  text(340, my+31, "config.yaml 此刻存在?", "nd")
line(340, my+40, 172, my+94, color="#6b46c1", marker="arrPurple")
line(340, my+40, 507, my+94, color="#6b46c1", marker="arrPurple")

sy = my + 94
rect(20, sy, 305, 32, "nodeBlue");  text(172, sy+21, "首次 / 恢复（rootfs 由镜像解压）", "nt")
rect(355, sy, 305, 32, "node");  text(507, sy+21, "后续重启（rootfs 已存在）", "nt")

# 左列
l1y = sy + 46
rect(42, l1y, 260, 42, "nodeOrange");  text(172, l1y+18, "① 安装前「直接屏蔽」off", "nt");  text(172, l1y+33, "online_client 注释", "nd")
line(172, l1y+42, 172, l1y+60)
l2y = l1y + 60
rect(42, l2y, 260, 42, "node");  text(172, l2y+18, "② 安装步骤", "nt");  text(172, l2y+33, "解压·配置·启动·bouncer 注册", "nd")
line(172, l2y+42, 172, l2y+60)
l3y = l2y + 60
rect(42, l3y, 260, 42, "node");  text(172, l3y+18, "③ 验证 LAPI Last Pull", "nt");  text(172, l3y+33, "bouncer_pulling（含新鲜度）?", "nd")
line(104, l3y+42, 104, l3y+102, color="#38a169", w=1.8, marker="arrGreen")
line(240, l3y+42, 240, l3y+102, color="#c53030", w=1.8, marker="arrRed")
l4y = l3y + 102
rect(42, l4y, 125, 110, "nodeGreen")
text(104, l4y+22, "有 → 放出", "nt");  text(104, l4y+40, "解除屏蔽(同代码)", "nd");  text(104, l4y+58, "+ _try_enroll", "nd");  text(104, l4y+76, "→ 收尾 nft 检查", "nd")
rect(177, l4y, 125, 110, "nodeOrange")
text(239, l4y+22, "无 → 保持屏蔽", "nt");  text(239, l4y+40, "_crowdsec_diagnose", "nd");  text(239, l4y+58, "损坏→重建重跑", "nd");  text(239, l4y+76, "网络→屏蔽退出", "nd")

# 右列
r1y = sy + 46
rect(377, r1y, 260, 42, "nodeBlue");  text(507, r1y+18, "① 验证 LAPI Last Pull", "nt");  text(507, r1y+33, "每次重启都验（含新鲜度）", "nd")
line(439, r1y+42, 439, r1y+98, color="#38a169", w=1.8, marker="arrGreen")
line(574, r1y+42, 574, r1y+98, color="#c53030", w=1.8, marker="arrRed")
r2y = r1y + 98
rect(377, r2y, 125, 110, "nodeGreen")
text(439, r2y+22, "有 → 不屏蔽", "nt");  text(439, r2y+40, "放出on(幂等)", "nd");  text(439, r2y+58, "+enroll 若需", "nd");  text(439, r2y+76, "→ 收尾 nft 检查", "nd")
rect(512, r2y, 125, 110, "nodeOrange")
text(574, r2y+22, "无 → 屏蔽 off", "nt");  text(574, r2y+40, "_crowdsec_diagnose", "nd");  text(574, r2y+58, "损坏→重建重跑", "nd");  text(574, r2y+76, "网络→放出+enroll", "nd")

# 要点（首两行手工断行：自动折行会把 enroll 拆成 enrol/l；x=92 为首行避开"要点"标签）
ky = max(l4y + 110, r2y + 110) + 20
kl1 = ["enroll 一律在放出之后；重启只在 LP 失效（空/错位/陈旧）后才屏蔽；",
       "重建后由重跑脚本自行验证 LP 再放出 + enroll"]
kl2 = wrap("新鲜度阈值 BOUNCER_PULL_MAX_AGE 默认 600s（crowdsec 正常每分钟拉一次），容器内 GNU date 解析 RFC3339；解析失败保守维持原非空逻辑", 60)
kl3 = wrap("enroll 开机判定只看 Enrolled（网页端 Accept 前不会有 authenticated，不查）；enroll 前等 api.crowdsec.net 可解析（≤30s 墙钟、就绪即止），治开机 DNS 未就绪秒退；注册码固定有效不消耗", 60)
nkl = len(kl1) + len(kl2) + len(kl3)
kh = 14*nkl + 10
parts.append(f'  <rect x="20" y="{ky}" width="620" height="{kh}" rx="7" fill="#f7fafc" stroke="#cbd5e0" stroke-width="1"/>')
text(32, ky+16, "要点", "sub2")
for j, s in enumerate(kl1):
    text(92, ky+16+14*j, s, "ndl")
for j, s in enumerate(kl2):
    text(32, ky+16+14*(len(kl1)+j), s, "ndl")
for j, s in enumerate(kl3):
    text(32, ky+16+14*(len(kl1)+len(kl2)+j), s, "ndl")

total_h = ky + kh + 16
parts.append("</svg>")

svg = "\n".join(parts).replace(
    f'viewBox="0 0 {W} 2960"',
    f'width="{W}" height="{total_h}" viewBox="0 0 {W} {total_h}"')
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "crowdsec-flow.svg")
with open(OUT, "w", encoding="utf-8") as f:
    f.write(svg)
print(f"written: viewBox 0 0 {W} {total_h}")
