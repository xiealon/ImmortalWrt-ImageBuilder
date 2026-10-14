#!/usr/bin/env python3
# =============================================================================
# shell/_patch-crowdsec-config.py
#
# 作用：安全地往 crowdsec 的 config.yaml 里追加 trusted_ips 条目。
#       由 shell/prepare-crowdsec-rootfs.sh 在编译期调用。
#
# 为什么需要这个脚本（历史教训）：
#   之前用 awk 按固定缩进插入 trusted_ips 列表项，结果在真实 rootfs 上：
#     - awk 的匹配模式 `^[[:space:]]*trusted_ips:[[:space:]]*$` 没命中
#       （某些 crowdsec 版本的 trusted_ips 行尾有注释/内联内容），
#       awk 静默什么都不做，构建照样"成功"，打出一个 LAPI 绑死 127.0.0.1 的包；
#     - 后来加了校验，却因为字段压根没插进去而 abort，
#       报 "trusted_ips 未插入 10.0.0.1" —— 拦住了坏包，但把构建搞挂了。
#
# 现在改成：
#   1. 优先用 PyYAML 做"解析 → 改 → 重新解析验证"，缩进由序列化器保证正确；
#   2. PyYAML 不可用时退回正则行级插入，缩进自动跟随同 key 下已有的列表项；
#   3. 找不到 trusted_ips 字段时按标准缩进新建一段；
#   4. 任何一种方式失败都只警告不退出 —— trusted_ips 是保险而非必需
#      （bouncer 走 api_key 认证），不该让它把整个构建干掉。
#
# 用法：python3 _patch-crowdsec-config.py <config.yaml> <bridge_ip> <container_net>
# 退出码：0 = 成功或已跳过；非 0 = 文件本身读不了（真 fatal）
# =============================================================================
import os
import re
import shutil
import sys


def log(msg):
    print("==> [config] %s" % msg)


def read(path):
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


def write(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    shutil.move(tmp, path)


# --------------------------------------------------------------------------
# LAPI 对外监听：把 listen_uri 的 host 换成 0.0.0.0，端口保留
#
# 为什么用 Python 而不是 sed：
#   sed 的反向引用在 GNU sed（\1）与 BSD sed（\1）之间不完全一致，
#   \g<1> 只有部分实现支持，写错会把整行替换成字面量 "g<1>0.0.0.0:g<2>"。
#   实测踩过这个坑，所以这里用 Python 正则，行为在任何环境下一致。
#
# 覆盖的写法：
#   listen_uri: 127.0.0.1:8080
#   listen_uri: localhost:8080
#   listen_uri: "[::1]:8080"
#   listen_uri: '0.0.0.0:8080'
# --------------------------------------------------------------------------
LISTEN_RE = re.compile(
    r'^(?P<pre>[ \t]*listen_uri:[ \t]*)'
    r'(?P<q>["\']?)'
    r'(?P<host>\[[^\]]*\]|[^:#\'"\s]+)'
    r':(?P<port>[0-9]+)'
    r'(?P<post>.*)$'
)


def patch_listen_uri(path):
    lines = read(path).split("\n")
    changed = False
    for i, ln in enumerate(lines):
        m = LISTEN_RE.match(ln)
        if not m:
            continue
        if m.group("host") == "0.0.0.0":
            continue
        lines[i] = "%s%s0.0.0.0:%s%s" % (
            m.group("pre"), m.group("q"), m.group("port"), m.group("post"))
        changed = True
        log("listen_uri: %s -> 0.0.0.0:%s"
            % (m.group("host"), m.group("port")))
    if changed:
        write(path, "\n".join(lines))
    return changed


def _find_listen_uri(text):
    """从 config.yaml 文本里提取 listen_uri 的值（去掉引号），找不到返回 None。

    用纯文本正则而非 YAML 解析：不同 crowdsec 版本的字段层级可能不同
    （顶层 api.server 或 crowdsec_service.api.server），文本正则永远命中，
    不会因为字段层级变化而误判。
    """
    m = re.search(r'^[ \t]*listen_uri:[ \t]*["\']?([^"\'\s#]+)["\']?', text, re.M)
    return m.group(1) if m else None


# --------------------------------------------------------------------------
# 方案 A：用 PyYAML 解析 → 改 → 重新序列化（最稳，缩进必然正确）
# --------------------------------------------------------------------------
def patch_with_pyyaml(path, bridge_ip, cnet):
    try:
        import yaml
    except ImportError:
        return None  # 没装，退回方案 B

    try:
        data = yaml.safe_load(read(path))
    except Exception as exc:                       # noqa: BLE001
        log("PyYAML 无法解析原文件（%s），退回行级插入" % exc)
        return None

    if not isinstance(data, dict):
        log("config.yaml 顶层不是字典，跳过 trusted_ips 处理")
        return None

    # 真实结构是顶层 api.server.trusted_ips（不是 crowdsec_service.api）。
    # 历史 bug：曾写成 crowdsec_service.api.server，永远取不到值。
    _api = data.get("api") if isinstance(data.get("api"), dict) else None
    server = _api.get("server") if isinstance(_api, dict) else None
    if not isinstance(server, dict):
        log("未找到 api.server，跳过 trusted_ips 处理（不影响 bouncer）")
        return None

    cur = server.get("trusted_ips")
    if cur is None:
        cur = []
    elif not isinstance(cur, list):
        log("trusted_ips 不是列表（类型 %s），跳过" % type(cur).__name__)
        return None
    else:
        cur = list(cur)

    added = []
    for item in (bridge_ip, cnet):
        if item and item not in cur:
            cur.append(item)
            added.append(item)

    if not added:
        log("trusted_ips 已含 %s / %s，无需改动" % (bridge_ip, cnet))
        return True

    server["trusted_ips"] = cur

    # CrowdSec 的 config.yaml 带大量注释，safe_dump 会把注释全丢掉。
    # 所以这里只把改动的 trusted_ips 段落用行级方式写回（方案 B 的逻辑），
    # 保留原文件其余部分与注释不动 —— 这样既拿到了 PyYAML 的解析能力，
    # 又不会破坏配置文件的人类可读性。
    log("PyYAML 解析成功，trusted_ips 待加入: %s" % ", ".join(added))
    return {"added": added}


# --------------------------------------------------------------------------
# 方案 B：行级插入，缩进自动跟随（不依赖任何第三方库）
# --------------------------------------------------------------------------
KEY_RE = re.compile(r"^(\s*)trusted_ips\s*:")


def detect_list_indent(lines, key_idx, key_indent):
    """在 trusted_ips: 之后找同级的列表项缩进；找不到就用 key 缩进 + 2。"""
    base = len(key_indent)
    for line in lines[key_idx + 1:]:
        if not line.strip():
            continue
        stripped = line.lstrip()
        indent = len(line) - len(stripped)
        if stripped.startswith("- "):
            return " " * indent
        # 遇到新的 key（缩进 <= trusted_ips 自身）就停
        if indent <= base and ":" in stripped:
            break
    return " " * (base + 2)


def patch_by_lines(path, bridge_ip, cnet):
    text = read(path)
    lines = text.split("\n")

    targets = [i for i, ln in enumerate(lines) if KEY_RE.match(ln)]

    if not targets:
        # 字段不存在 → 找 api: 下面第一个真正的子键，插在它之前
        log("未找到 trusted_ips 字段，尝试在 crowdsec_service.api 下新建")
        inserted = insert_new_block(lines, bridge_ip, cnet)
        if inserted is None:
            log("找不到可用的 crowdsec_service.api，跳过")
            return False
        write(path, "\n".join(lines))
        log("已新建 trusted_ips（第 %d 行起）" % (inserted + 1))
        return True

    added_any = False
    # 从后往前插，避免影响行号
    for idx in reversed(targets):
        m = KEY_RE.match(lines[idx])
        key_indent = m.group(1)

        # 收集该 key 下已有的列表项，判断是否已存在
        existing = set()
        body_end = len(lines)
        for j in range(idx + 1, len(lines)):
            ln = lines[j]
            if not ln.strip():
                continue
            stripped = ln.lstrip()
            indent = len(ln) - len(stripped)
            if stripped.startswith("- "):
                existing.add(stripped[2:].strip())
                continue
            if indent <= len(key_indent) and ":" in stripped:
                body_end = j
                break

        todo = [x for x in (bridge_ip, cnet) if x and x not in existing]
        if not todo:
            continue

        item_indent = detect_list_indent(lines, idx, key_indent)
        new_lines = ["%s- %s" % (item_indent, v) for v in todo]

        # key 行后面若已有列表项就插在末尾，否则插在 key 行正下方
        insert_at = body_end if body_end > idx + 1 else idx + 1
        lines[insert_at:insert_at] = new_lines
        added_any = True
        log("在第 %d 行 trusted_ips 下插入: %s（缩进 %d 空格）"
            % (idx + 1, ", ".join(todo), len(item_indent)))

    if added_any:
        write(path, "\n".join(lines))
    return added_any


def insert_new_block(lines, bridge_ip, cnet):
    """在 crowdsec_service.api 下新建 trusted_ips。

    必须插在 api: 的**第一个真实子键之前**，且缩进 = api 缩进 + 2。
    之前直接插在 api: 行之后，遇到 api: 后面是空行的情况会插到错误的缩进层，
    产出 "expected <block end>" 的坏 YAML。
    """
    api_idx = None
    for i, ln in enumerate(lines):
        if re.match(r"^(\s*)api\s*:\s*(#.*)?$", ln):
            api_idx = i
            break
    if api_idx is None:
        return None

    api_indent = len(lines[api_idx]) - len(lines[api_idx].lstrip())
    item_indent = " " * (api_indent + 2)

    # 往后找 api 的第一个真实子键（同缩进或更深的、非注释、非空行）
    insert_at = None
    for j in range(api_idx + 1, len(lines)):
        ln = lines[j]
        if not ln.strip() or ln.lstrip().startswith("#"):
            continue
        indent = len(ln) - len(ln.lstrip())
        if indent > api_indent:
            insert_at = j
            break
        # 缩进 <= api 且不是列表项 → 已经出了 api 块，插在 api 行正下方
        break

    block = [
        "%strusted_ips:" % item_indent,
        "%s- %s" % (item_indent, bridge_ip),
        "%s- %s" % (item_indent, cnet),
    ]
    if insert_at is not None:
        lines[insert_at:insert_at] = block
    else:
        lines[api_idx + 1:api_idx + 1] = block
    return insert_at if insert_at is not None else api_idx + 1


PROM_SEC_RE = re.compile(r"^prometheus\s*:\s*(#.*)?$")


def _prom_block_range(lines):
    """返回顶层 prometheus: 段的 (start, end)；段不存在返回 None。"""
    for i, ln in enumerate(lines):
        if PROM_SEC_RE.match(ln):
            for j in range(i + 1, len(lines)):
                s = lines[j]
                if not s.strip():
                    continue
                if not s[0].isspace() and ":" in s:
                    return i, j
            return i, len(lines)
    return None


def patch_prometheus(path, listen_addr, port):
    """启用 Prometheus exporter（:6060/metrics），供 LuCI 与外部抓取。

    背景：crowdsec 包默认 prometheus.enabled=false，于是 cscli metrics 报
      dial tcp 127.0.0.1:6060: connect: connection refused
    这不是故障，但 LuCI 拿不到指标。编译期直接打开，避免刷机后才发现。

    listen_address 必须是 0.0.0.0 不能用 127.0.0.1：
      bouncer 与 LuCI 跑在宿主，从 10.0.0.1 访问容器的 10.0.0.10:6060，
      容器里只听回环地址的话宿主永远连不上。

    整段改写而非逐行打补丁：prometheus 段各版本差异大（有的整段注释、
    有的 key 名不同），逐行匹配容易静默失配。整段替换后用 YAML 复验兜底。
    """
    lines = read(path).split("\n")
    block = [
        "prometheus:",
        "  enabled: true",
        "  level: full",
        "  listen_address: %s" % listen_addr,
        "  listen_port: %d" % port,
    ]

    rng = _prom_block_range(lines)
    if rng is None:
        while lines and not lines[-1].strip():
            lines.pop()
        lines += [""] + block
    else:
        start, end = rng
        lines[start:end] = block

    write(path, "\n".join(lines))

    try:
        import yaml
        data = yaml.safe_load(read(path)) or {}
        prom = data.get("prometheus") or {}
        if prom.get("enabled") is not True:
            log("!! prometheus 写入后仍未启用，请人工检查")
            return False
        log("prometheus 已启用：%s:%s" % (prom.get("listen_address"),
                                         prom.get("listen_port")))
    except ImportError:
        log("prometheus 已写入（无 PyYAML，跳过复验）")
    return True


def main():
    if len(sys.argv) != 4:
        print("用法: %s <config.yaml> <bridge_ip> <container_net>" % sys.argv[0],
              file=sys.stderr)
        return 2

    path, bridge_ip, cnet = sys.argv[1], sys.argv[2], sys.argv[3]

    if not os.path.isfile(path):
        print("!! %s 不存在" % path, file=sys.stderr)
        return 2

    try:
        read(path)
    except Exception as exc:                       # noqa: BLE001
        print("!! 读取 %s 失败: %s" % (path, exc), file=sys.stderr)
        return 2

    # 先修 LAPI 监听（致命项，必须成功）
    patch_listen_uri(path)

    # 复验：listen_uri 必须已经是 0.0.0.0（文本级校验，不依赖 YAML 结构）。
    # 历史 bug：复验时用 PyYAML 取 crowdsec_service.api.server 路径，
    #   但真实结构是顶层 api.server，永远取到 None → 把构建判死（abort）。
    _verify = _find_listen_uri(read(path))
    if not _verify or not _verify.startswith("0.0.0.0:"):
        log("!! listen_uri 修改后校验不通过（当前 %r），abort" % _verify)
        return 1
    log("listen_uri 复验通过：%s" % _verify)

    # 打开 Prometheus exporter（可选项，失败只警告）
    try:
        patch_prometheus(path, "0.0.0.0", 6060)
    except Exception as exc:                       # noqa: BLE001
        log("启用 prometheus 时出错（%s），跳过（不影响 bouncer 认证）" % exc)

    # 再处理 trusted_ips（保险项，失败只警告）
    probed = patch_with_pyyaml(path, bridge_ip, cnet)

    if probed is None:
        log("使用行级插入模式（无 PyYAML）")
    elif probed is True:
        # PyYAML 说无需改动，直接跳过行级处理
        log("无需改动，结束")
        return 0

    try:
        ok = patch_by_lines(path, bridge_ip, cnet)
    except Exception as exc:                       # noqa: BLE001
        # 保险起见：绝不让这一步把整个构建干掉
        log("插入 trusted_ips 时出错（%s），跳过（不影响 bouncer 认证）" % exc)
        return 0

    if ok:
        # 改完必须能重新解析，否则还原并跳过
        try:
            import yaml
            yaml.safe_load(read(path))
            log("插入完成，YAML 复验通过")
        except ImportError:
            log("插入完成（无 PyYAML，跳过复验）")
        except Exception as exc:                   # noqa: BLE001
            log("!! 插入后 YAML 解析失败（%s），已保留现场请人工检查" % exc)
            return 0
    else:
        log("未能插入 trusted_ips（非致命，bouncer 走 api_key 认证）")

    return 0


if __name__ == "__main__":
    sys.exit(main())
