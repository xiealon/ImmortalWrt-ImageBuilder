#!/usr/bin/env python3
"""生成 CrowdSec LXC 引导流程图 SVG（v.65）
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

W = 740
X_BIG, W_BIG = 30, 200
X_SML, W_SML = 260, 400
CX_BIG = X_BIG + W_BIG/2
CX_SML = X_SML + W_SML/2
X_R = X_SML + W_SML
CH = 672      # 红虚线 bypass 车道
CH_T = 700    # 彩色分支轨迹车道

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

def wrapw(s, width):
    """宽度感知折行（词优先）：按空格切词贪心装箱，不在词中断开；
    仅当单个词自身超宽才退化为按字拆；末行孤字（宽<1.2）时从上行借一词"""
    words = [w for w in s.split(' ') if w]
    lines, cur = [], ''
    for wd in words:
        if not cur:
            cur = wd
        elif sum(_cw(c) for c in cur) + 0.55 + sum(_cw(c) for c in wd) <= width:
            cur += ' ' + wd
        else:
            lines.append(cur)
            cur = wd
    if cur:
        lines.append(cur)
    out = []
    for ln in lines:
        out.extend([ln] if sum(_cw(c) for c in ln) <= width else wrap(ln, width))
    if len(out) >= 2 and sum(_cw(c) for c in out[-1]) < 1.2:
        pw = out[-2].split(' ')
        if len(pw) > 1:
            out[-2] = ' '.join(pw[:-1])
            out[-1] = pw[-1] + out[-1]
    return out or ['']

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
    .tiny{{font-size:9px;fill:#718096;paint-order:stroke;stroke:#ffffff;stroke-width:3px;stroke-linejoin:round;}}
    .tinyR{{font-size:9px;fill:#c53030;paint-order:stroke;stroke:#ffffff;stroke-width:3px;stroke-linejoin:round;}}
    .tinyO{{font-size:9px;fill:#c05621;paint-order:stroke;stroke:#ffffff;stroke-width:3px;stroke-linejoin:round;}}
    .tinyG{{font-size:9px;fill:#2f855a;paint-order:stroke;stroke:#ffffff;stroke-width:3px;stroke-linejoin:round;}}
    .bignum{{font-size:30px;font-weight:700;text-anchor:middle;}}
    .loop{{stroke:#dd6b20;stroke-width:1.6;stroke-dasharray:6 4;fill:none;}}
    .loopt{{font-size:9px;fill:#c05621;}}
  </style>
  <rect x="0" y="0" width="740" height="4096" fill="#ffffff"/>
  <text x="370" y="26" class="title" text-anchor="middle">CrowdSec LXC · 详细流程架构图</text>
  <text x="370" y="44" class="ver" text-anchor="middle">v.2026-10-18.78-bp ｜ ①.a 式小步骤框；◆=判定框，分支轨迹绕右车道连到目标步（竖排标签）｜ 重建=强停→删容器→exec 重跑（CS_REBUILT 防循环）</text>
  <text x="370" y="58" class="ver" text-anchor="middle">实线=正常流 ｜ 紫框+标签=判定分支 ｜ 红虚线+红块=失败/exit 1 ｜ 灰虚线+灰块=exit 0 ｜ 橙虚线=告警/放弃/回路 ｜ 绿=有效</text>
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
    parts.append(f'  <path d="{d}" fill="none" stroke="#c53030" stroke-width="1.4" stroke-dasharray="5 3" marker-end="url(#arrRed)"/>')

def fail_bypass(key_from, key_to, xc, label=None, lpos="mid"):
    _, cyA, _, _ = sml_pos[key_from]
    _, cyB, _, _ = sml_pos[key_to]
    fail_path(f"M{X_R},{cyA} L{xc},{cyA} L{xc},{cyB} L{X_R},{cyB}")
    if label:
        for j, ln in enumerate(wrapw(label, 7.0)):
            ly = (cyA+cyB)/2 - 6 + 11*j if lpos == "mid" else cyA + 14 + 11*j
            text(xc+6, ly, ln, "tinyR")

def edge_end(key, label, kind="red"):
    """本框右缘 → 短虚线 + 色块 + 标签（终止/告警类，不跨步骤）"""
    color = {"red": "#c53030", "gray": "#718096", "orange": "#dd6b20", "green": "#38a169"}[kind]
    marker = {"red": "arrRed", "gray": "arr", "orange": "arrOrange", "green": "arrGreen"}[kind]
    xr, cy, _, _ = sml_pos[key]
    parts.append(f'  <line x1="{xr}" y1="{cy}" x2="{xr+26}" y2="{cy}" stroke="{color}" stroke-width="1.4" stroke-dasharray="4 3" marker-end="url(#{marker})"/>')
    parts.append(f'  <rect x="{xr+28}" y="{cy-4.5}" width="9" height="9" rx="2" fill="{color}"/>')
    cls = {"red": "tinyR", "gray": "tiny", "orange": "tinyO", "green": "tinyG"}[kind]
    for j, ln in enumerate(wrapw(label, 5.0)):
        text(xr+30, cy+9+10*j, ln, cls)

def tint(hexc, f=0.09):
    """边框色兑白出浅底：小步骤框有明确'框感'，文字对比度不受影响"""
    r, g, b = (int(hexc[i:i+2], 16) for i in (1, 3, 5))
    return '#%02x%02x%02x' % tuple(round(c*f + 255*(1-f)) for c in (r, g, b))

def small_box(x, y, w, label, body, wrapw, color="#4a5568"):
    lines = wrap(f"{label} {body}", wrapw)
    h = 14*len(lines) + 10
    parts.append(f'  <rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" fill="{tint(color)}" stroke="{color}" stroke-width="1.5"/>')
    rest0 = lines[0][len(label):].lstrip()
    lab = f'<tspan style="font-weight:700;fill:{color}">{esc(label)}</tspan>'
    if rest0:
        parts.append(f'  <text x="{x+12}" y="{y+16}" class="ndl">{lab} {esc(rest0)}</text>')
    else:
        parts.append(f'  <text x="{x+12}" y="{y+16}" class="ndl">{lab}</text>')
    for j in range(1, len(lines)):
        text(x+12, y+16+14*j, lines[j], "ndl")
    return h

parts.append('  <rect x="14" y="66" width="692" height="58" rx="7" fill="#f7fafc" stroke="#cbd5e0" stroke-width="1"/>')
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
    if i < len(det1) - 1:
        line(20 + i*210 + 200, dy1 + h/2, 20 + (i+1)*210, dy1 + h/2, w=1.4)
    db = max(db, dy1 + h)
line(413, 198, 413, dy1)

sec2_top = db + 52
text(20, db + 24, "二、bootstrap 脚本流程（每次开机，rc.local 触发）", "sub")
parts.append(f'  <path d="M400,{db} L400,{db+34} L130,{db+34} L130,{sec2_top}" fill="none" stroke="#4a5568" stroke-width="1.5" marker-end="url(#arr)"/>')

steps = [
    ("①", "镜像迁移", "旧→新路径", "node", [
        "tarball 缺失：/opt/ 有旧镜像 → mv 迁移到 /etc/crowdsec/；两者都无 → exit 0 跳过（本机不带 CrowdSec）",
        "（.52 起移除 chattr +i 防误删——OpenWrt 无此命令，锁从未生效还刷警告）",
    ]),
    ("②", "模式判定", "config.yaml 在?", "node", [
        "◆ 判定：config.yaml 存在？（rootfs 内 /etc/crowdsec/config.yaml）",
        "_recovering=true：首次/恢复全流程（③ 写 config → ④ 解压 rootfs → ⑤ 配置 → …）",
    ]),
    ("③", "容器 config", "缺失才写", "node", [
        "/srv/lxc/ubuntu/config 不存在才写；apply_cfg 剪掉不被 lxc 支持的行，解析失败 → exit 1 终止",
        "rootfs.path=dir:/srv/lxc/ubuntu/rootfs；静态 IP 10.1.0.10/24",
    ]),
    ("④", "解压 rootfs", "仅首次/恢复", "node", [
        "rebuild_from_image：停容器 → 删 rootfs → tar 解压（.extracting 锁）；解压失败 → exit 1 终止",
        "CS_REBUILT=1 防开机循环：一次开机最多重建一次",
    ]),
    ("⑤", "运行期配置", "网桥+容器+解析", "node", [
        "setup_bridge：lxcbr0 10.1.0.1/24 + 防火墙 lxc 区 ACCEPT + SNAT（src_ip 10.1.0.0/24 → snat_ip 10.0.0.201）",
        "v.72：验证侧各对象独立（verify_lxc_zone/verify_fwd_rules/verify_snat_rule/verify_ip_forward/verify_bridge 按需调用）；修复侧同步拆分——setup_lxc_firewall 入口四分项预检，哪项不符只重建哪项（build_lxc_zone_fwd/build_snat/echo ip_forward），一次 commit+reload；容器网段/出口 IP 收敛为 _lxc_net()/_lan_ip() 唯一出处；proto 规范化 delete+add_list；全对跳过（不 commit 不 reload）",
        "容器静态 IP 10.1.0.10/24 网关 10.1.0.1；DNS 源文件 trim（.53：1 字节空白不再写出空 nameserver）",
        "setup_container_boot：networkd + crowdsec 软链 + hostname/machine-id",
        "resolv.conf + 日志源 + listen_uri 0.0.0.0:8080 + trusted_ips 含 10.1.0.1；prepare_container 失败 → exit 1",
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
        "配置 OpenWrt logd 远程转发：log_ip=10.1.0.10, log_port=514, log_proto=udp；失败不阻断主流程",
        "宿主机系统日志经 UDP 514 发到容器 CrowdSec 采集",
    ]),
    ("⑨", "bouncer 注册", "查 last_pull", "nodeOrange", [
        "固化 UCI bouncer 字段：api_url=http://10.1.0.10:8080/、enabled=1、ipv4=1；失败 → 跳过注册块，直落 ⑩",
        "v.53：每轮注册前 _wait_lapi_ready，等 LAPI 就绪再 cscli bouncers add；add 失败 → ⑨.d 下一轮",
        "◆ 判定 bouncer_pulling：name 匹配 + last_pull 非空 + last_pull 未超 600s（v.55 陈旧阈值，堵 LAPI 僵死盲区）",
        "_bouncer_heal 2 轮：等 LAPI≤90s → 删旧注册拿 key → 容器内重启 crowdsec → 再等 LAPI≤90s → 重启路由器 bouncer+12s → 计 60s 验证窗口",
        "◆ 判定：60s 窗口内 bouncer_pulling 转正？",
        "2 轮未通 → _crowdsec_repair：容器级施救 → 配置校验 → UCI 对齐 → 重注册 → 重启两端 → 重验（见三节）",
    ]),
    ("⑩", "CAPI 放出", "按模式，见第四节", "nodePurple", [
        "◆ 判定 bouncer_pulling：LAPI 侧 last_pull 有效？（安装后再确认一次）",
        "屏蔽 off + _crowdsec_diagnose（分支见第三节）",
        "v.63：开机判定只看 Enrolled——此前 authenticated 不会有，不查",
    ]),
    ("⑪", "console enroll", "注册码 + CAPI 绑定", "nodePurple", [
        "注册码判空：ENROLL_KEY_FILE 缺失/为空 → 放弃 enroll（注册码固定有效不消耗，下次开机重试）",
        "v.66：先 verify_snat 五项校验——src=lan / target=SNAT / snat_ip=出口IP / src_ip=容器网段 / ip_forward=1，任一不符 → setup_lxc_firewall 重建 + 补 ip_forward（不阻断；容器上外网靠它：拉黑名单、连 app.crowdsec.net）",
        "v.63：enroll 前等 api.crowdsec.net 可解析（≤30s 墙钟、就绪即止），治开机 DNS 未就绪秒退；enroll 输出与 capi status 进日志",
        "v.64：online_api_credentials.yaml 缺失时先 cscli capi register 建凭据再 enroll（enroll 的加载前提；v.62 先 mv 走凭据等于必然秒退）",
        "v.65：复检改查 cscli capi status 的 enrolled 行——console status 只打选项表、永远不含 enrolled（源码实锤），v.64 查错命令导致误回滚",
        "v.65：enroll 命令成功即放行；60s 等不到 Enrolled 不回滚不阻止，提示「需要前往网站确认接受」后退出",
    ]),
    ("⑫", "nft 检查", "链路打通", "nodeGreen", [
        "nft list table ip crowdsec → 有表则链路打通；无表 → 记日志检查 bouncer 日志，引导结束 exit 0",
    ]),
]

sml_pos = {}
# 分支轨迹：key -> ((向下箭头标签, 色), (轨迹标签, 线型, 目标key, 车道, 起点dy, 终点dy))
# 线型：green=有效/通过、gray=不阻断继续、orange=放弃/告警、red=失败
TAGS = {
    "②.a": (("否", "red"), ("是 → ⑤ 跳过解压", "green", "⑤.a", CH, 0, 0)),
    "⑥.a": (None, ("不阻断 → ⑦", "gray", "⑦.a", CH, 0, 0)),
    "⑨.c": (("失效", "red"), ("有效 → ⑩", "green", "⑩.a", CH_T, 0, -20)),
    "⑨.e": (("未通", "red"), ("通 → ⑩", "green", "⑩.a", CH_T, 0, -8)),
    "⑩.a": (("无", "orange"), ("有 → ⑪", "green", "⑪.a", CH_T, 8, 0)),
    "⑪.a": (None, ("注册码空 → ⑫", "orange", "⑫.a", CH_T, 12, -14)),
}
TAGCLS = {"red": "tinyR", "orange": "tinyO", "green": "tinyG", "gray": "tiny"}
TRACKS = []
y = sec2_top
prev_lb = None
pos4 = None
for num, t, sub, cls, det in steps:
    det = [(d[1:].lstrip(), True) if d.startswith("◆") else (d, False) for d in det]
    hs = [14*len(wrap(f"{num}.{chr(97+i)} {bd}", 37)) + 10 for i, (bd, _j) in enumerate(det)]
    block_h = max(40, sum(hs) + 22*(len(hs)-1))
    if prev_lb is not None:
        parts.append(f'  <path d="M460,{prev_lb} L460,{prev_lb+13} L130,{prev_lb+13} L130,{y}" fill="none" stroke="#4a5568" stroke-width="1.5" marker-end="url(#arr)"/>')
    rect(X_BIG, y, W_BIG, block_h, cls)
    text(CX_BIG, y+18, f"{num} {t}", "nt")
    text(CX_BIG, y+34, sub, "nd")
    if block_h > 70:
        parts.append(f'  <text x="{CX_BIG}" y="{y+block_h-12}" class="bignum" fill="{STEP_COLORS[cls]}" fill-opacity="0.16">{num}</text>')
    sy = y
    prev_key = None
    for i, (bd, judge) in enumerate(det):
        h = hs[i]
        key = f"{num}.{chr(97+i)}"
        col = "#6b46c1" if judge else STEP_COLORS[cls]
        if i == 0:
            line(X_BIG+W_BIG, sy+h/2, X_SML, sy+h/2, color=STEP_COLORS[cls], w=1.6)
        else:
            line(CX_SML, sy-22, CX_SML, sy, w=1.5)
            tg = TAGS.get(prev_key)
            if tg and tg[0]:
                text(CX_SML-8, sy-11, tg[0][0], TAGCLS[tg[0][1]], anchor="end")
        small_box(X_SML, sy, W_SML, key, bd, 37, col)
        sml_pos[key] = (X_R, sy+h/2, sy+h, sy)
        tg = TAGS.get(key)
        if tg and tg[1]:
            TRACKS.append((key,) + tg[1])
        sy += h + 22
        prev_key = key
    prev_lb = sy - 22
    if num == "④":
        pos4 = y + block_h/2
    y += block_h + 26
sec2_bottom = prev_lb

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
rect(500, fy, 160, 40, "nodeGreen");  text(580, fy+16, "修复成功 → 放出", "nt");  text(580, fy+31, "online_client + ⒋enroll", "nd")

line(dcx-80, dcy, 130, dcy, color="#c53030", w=1.8, marker=None)
line(130, dcy, 130, fy, color="#c53030", w=1.8, marker="arrRed")
rect(30, fy, 200, 40, "nodeRed");  text(130, fy+16, "修复无效 → 重建", "nt");  text(130, fy+31, "_crowdsec_rebuild", "nd")
line(130, fy+40, 130, fy+68, w=1.8)
rect(30, fy+68, 200, 40, "nodeBlue");  text(130, fy+84, "删容器 → exec 重跑", "nt");  text(130, fy+99, "CS_REBUILT 限一次", "nd")

loop_y = fy + 118
parts.append(f'  <path d="M130,{fy+108} L130,{loop_y} L18,{loop_y} L18,{pos4} L30,{pos4}" fill="none" class="loop" marker-end="url(#arrOrange)"/>')
text(246, fy+92, "exec 重跑 → 回到 ④ 解压 rootfs（首次/恢复全流程）", "loopt")

edge_end("①.a", "两者都无 → exit 0", "gray")
edge_end("③.a", "解析失败 → exit 1", "red")
edge_end("④.a", "解压失败 → exit 1", "red")
edge_end("⑤.e", "准备失败 → exit 1", "red")
edge_end("⑫.a", "无 nft 表 → exit 0", "gray")
fail_bypass("⑦.b", "⑦.d", CH, "两次起不来 → _ct_revive")
fail_bypass("⑨.b", "⑨.d", CH, "add 失败 → 下一轮", lpos="top")

# 分支轨迹：框右缘 → 右车道 → 连到目标框右缘，竖排标签注明到哪一步
TRK_COLOR = {"green": "#38a169", "orange": "#dd6b20", "gray": "#4a5568", "red": "#c53030"}
TRK_MK = {"green": "arrGreen", "orange": "arrOrange", "gray": "arr", "red": "arrRed"}
for fk, label, kind, tk, lane, ody, idy in TRACKS:
    _, cyA, _, _ = sml_pos[fk]
    _, cyB, _, _ = sml_pos[tk]
    yA, yB = cyA + ody, cyB + idy
    dash = ' stroke-dasharray="5 3"' if kind == "orange" else ''
    parts.append(f'  <path d="M{X_R},{yA} L{lane},{yA} L{lane},{yB} L{X_R},{yB}" fill="none" stroke="{TRK_COLOR[kind]}" stroke-width="1.5"{dash} marker-end="url(#{TRK_MK[kind]})"/>')
    chars = [c for c in label if c != ' ']
    y0 = (yA + yB)/2 - 5.5*(len(chars)-1)
    for j, cch in enumerate(chars):
        text(lane + (3 if lane == CH else 5), y0 + 9 + 11*j, cch, TAGCLS[kind])
_, cy10b, _, _ = sml_pos["⑩.b"]
fail_path(f"M{X_R},{cy10b} L{CH},{cy10b} L{CH},{sec2_bottom+40} L130,{sec2_bottom+40} L130,{ry}")
text(300, sec2_bottom+36, "LP 失效 → 屏蔽 + diagnose（见三节）", "tinyR")

det3 = [
    "触发：⑨ 注册后 CAPI 段复判 bouncer_pulling，LP 失效先 ensure_online_client_off 屏蔽 online_client",
    "repair-① 容器未运行 → _ct_revive 0：补挂 systemd cgroup + 重写容器 config 重启（不重建，失败交回上层）",
    "repair-② 容器在运行但无 IP 10.1.0.10 → 重写 .network/resolv.conf + 强停重启（resolv.conf 走 _container_dns 兜底：空源文件回落 BRIDGE_IP 10.1.0.1——v.52 实战踩坑：空 nameserver 全链路连不上）",
    "repair-③ 配置校验 → UCI 对齐 → _wait_lapi_ready → 重注册 → 重启 crowdsec+bouncer 两端 → 6×5s 重验；注册失败或重验不过 → return 1，交回上层重建（三.f）",
    "重验通过 → 放出 online_client（⑩）+ enroll（⑪）→ 收尾 nft 检查（⑫）",
    "重验不过 → _crowdsec_rebuild：强停+删 rootfs（删不净强杀+清挂载再删）→ exec 重跑全流程；CS_REBUILT=1 限一次",
]
by = fy + 128
for i, d in enumerate(det3):
    if i > 0:
        line(360, by-16, 360, by, color="#dd6b20", w=1.6)
    h = small_box(30, by, 660, f"三.{chr(97+i)}", d, 63, "#dd6b20")
    by += h + 16
y4 = by + 14

text(20, y4, "四、CAPI(online_client) 屏蔽 / 放出 决策（按启动模式）", "sub")
by4 = y4 + 12
parts.append(f'  <rect x="20" y="{by4}" width="660" height="22" rx="6" fill="#f7fafc" stroke="#cbd5e0" stroke-width="1"/>')
text(32, by4+15, "屏蔽 = 注释 online_client（ensure_online_client_off）｜放出 = 取消注释（ensure_online_client_on，同一套 sed）", "ndl")

my = by4 + 40
rect(240, my, 200, 40, "nodePurple");  text(340, my+16, "判定模式", "nt");  text(340, my+31, "config.yaml 此刻存在?", "nd")
line(340, my+40, 172, my+94, color="#6b46c1", marker="arrPurple")
line(340, my+40, 507, my+94, color="#6b46c1", marker="arrPurple")

sy = my + 94
rect(20, sy, 305, 32, "nodeBlue");  text(172, sy+21, "首次 / 恢复（rootfs 由镜像解压）", "nt")
rect(355, sy, 305, 32, "node");  text(507, sy+21, "后续重启（rootfs 已存在）", "nt")

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
text(104, l4y+22, "有 → 放出", "nt");  text(104, l4y+40, "解除屏蔽(同代码)", "nd");  text(104, l4y+58, "+ enroll⑪", "nd");  text(104, l4y+76, "→ 收尾 nft 检查", "nd")
rect(177, l4y, 125, 110, "nodeOrange")
text(239, l4y+22, "无 → 保持屏蔽", "nt");  text(239, l4y+40, "_crowdsec_diagnose", "nd");  text(239, l4y+58, "损坏→重建重跑", "nd");  text(239, l4y+76, "网络→屏蔽退出", "nd")

r1y = sy + 46
rect(377, r1y, 260, 42, "nodeBlue");  text(507, r1y+18, "① 验证 LAPI Last Pull", "nt");  text(507, r1y+33, "每次重启都验（含新鲜度）", "nd")
line(439, r1y+42, 439, r1y+98, color="#38a169", w=1.8, marker="arrGreen")
line(574, r1y+42, 574, r1y+98, color="#c53030", w=1.8, marker="arrRed")
r2y = r1y + 98
rect(377, r2y, 125, 110, "nodeGreen")
text(439, r2y+22, "有 → 不屏蔽", "nt");  text(439, r2y+40, "放出on(幂等)", "nd");  text(439, r2y+58, "+enroll⑪ 若需", "nd");  text(439, r2y+76, "→ 收尾 nft 检查", "nd")
rect(512, r2y, 125, 110, "nodeOrange")
text(574, r2y+22, "无 → 屏蔽 off", "nt");  text(574, r2y+40, "_crowdsec_diagnose", "nd");  text(574, r2y+58, "损坏→重建重跑", "nd");  text(574, r2y+76, "网络→放出+enroll⑪", "nd")

ky = max(l4y + 110, r2y + 110) + 20
kl1 = ["放出（⑩）与 enroll（⑪）拆为两步：enroll 一律在放出之后；重启只在 LP 失效（空/错位/陈旧）后才屏蔽；",
       "重建后由重跑脚本自行验证 LP 再放出 + enroll"]
kl2 = wrap("新鲜度阈值 BOUNCER_PULL_MAX_AGE 默认 600s（crowdsec 正常每分钟拉一次），容器内 GNU date 解析 RFC3339；解析失败保守维持原非空逻辑", 64)
kl3 = wrap("enroll 开机判定只看 Enrolled：查 cscli capi status 的 enrolled 行（console status 只打选项表、永远不含 enrolled）；enroll 前等 api.crowdsec.net 可解析（≤30s 墙钟、就绪即止）；注册码固定有效不消耗", 64)
kl4 = wrap("enroll 前提：online_api_credentials.yaml 必须已存在（cscli capi register 的产物），缺失先 register 再 enroll；enroll 命令成功即放行，60s 等不到 Enrolled 不回滚，提示前往网站 Accept", 64)
kl5 = wrap("SNAT 与 CAPI 分流：bouncer↔LAPI 走本地桥接不经 SNAT；SNAT 只管容器上外网——拉黑名单、enroll 连 app.crowdsec.net；last_pull 失效不依赖 SNAT，故校验放在 enroll 步（⑪，v.66）", 64)
nkl = len(kl1) + len(kl2) + len(kl3) + len(kl4) + len(kl5)
kh = 14*nkl + 10
parts.append(f'  <rect x="20" y="{ky}" width="660" height="{kh}" rx="7" fill="#f7fafc" stroke="#cbd5e0" stroke-width="1"/>')
text(32, ky+16, "要点", "sub2")
for j, s in enumerate(kl1):
    text(92, ky+16+14*j, s, "ndl")
for j, s in enumerate(kl2):
    text(32, ky+16+14*(len(kl1)+j), s, "ndl")
for j, s in enumerate(kl3):
    text(32, ky+16+14*(len(kl1)+len(kl2)+j), s, "ndl")
for j, s in enumerate(kl4):
    text(32, ky+16+14*(len(kl1)+len(kl2)+len(kl3)+j), s, "ndl")
for j, s in enumerate(kl5):
    text(32, ky+16+14*(len(kl1)+len(kl2)+len(kl3)+len(kl4)+j), s, "ndl")

# ---- 注意事项区块（v.78-bp：原 README「注意 1/2/3」并入图内）----
nl1 = wrapw("注意 1：开机需要先进行一次重启，刷新设备的网络接口", 66)
nl2 = wrapw("注意 2：crowdsec 的初次运行需要时间自动进行初始化安装，无需网络也可以自动集成（大概 30s）", 66)
nl3 = wrapw("注意 3：防火墙里面的 NAT 规则 LXC-SNAT 不要动它，它会在编译时自动修改对应 IP 地址到出接口的 IP（src 区域固定为 lan，即出口区域；网络部分按对象独立验证，enroll 前按需校验 SNAT 规则与 ip_forward，不符自动重建）", 66)
nn = len(nl1) + len(nl2) + len(nl3)
nh = 14*nn + 40
ny = ky + kh + 12
parts.append(f'  <rect x="20" y="{ny}" width="660" height="{nh}" rx="7" fill="#fffaf0" stroke="#f6ad55" stroke-width="1"/>')
text(32, ny+16, "注意事项", "sub2")
for j, s in enumerate(nl1):
    text(32, ny+36+14*j, s, "ndl")
for j, s in enumerate(nl2):
    text(32, ny+36+14*(len(nl1)+j), s, "ndl")
for j, s in enumerate(nl3):
    text(32, ny+36+14*(len(nl1)+len(nl2)+j), s, "ndl")

total_h = ny + nh + 16
parts.append("</svg>")

svg = "\n".join(parts).replace(
    f'viewBox="0 0 {W} 2960"',
    f'width="{W}" height="{total_h}" viewBox="0 0 {W} {total_h}"')
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "crowdsec-flow.svg")
with open(OUT, "w", encoding="utf-8") as f:
    f.write(svg)
print(f"written: viewBox 0 0 {W} {total_h}")
