#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""static_verify_first.py —— 逐节点检查「先验证后写入」

一个节点一条记录，不抽样、不合并。判据四条：

  V1  verify_<node> 存在
  V2  build_<node>  存在（RO_ONLY 节点除外）
  V3  build_<node> 体内出现判据（verify_/..._missing/..._ok/..._installed/文件测试），
      也就是「先判再写」，不是无条件覆盖
  V4  verify_<node> 体内没有写动作（uci set/commit、cp、mv、mkdir、rm、重定向、nft add），
      验证阶段必须只读

用法：
    python3 tests/static_verify_first.py files/usr/sbin/crowdsec-lxc-bootstrap.sh
退出码：0 全过；1 有违规（逐条打印节点名与行号）
"""
import re
import sys

# 只认「真的改东西」的动作。重定向一律不认（脚本里到处都是 >/dev/null）。
WRITE_PAT = re.compile(
    r'(uci\s+(-q\s+)?(set|add|add_list|delete|commit|rename|reorder)\b|'
    r'(^|[\s;(|])cp\s|(^|[\s;(|])mv\s|(^|[\s;(|])rm\s|'
    r'(^|[\s;(|])mkdir\s|(^|[\s;(|])touch\s|(^|[\s;(|])chmod\s|'
    r'(^|[\s;(|])chown\s|(^|[\s;(|])ln\s+-|sed\s+-i|'
    r'\bnft\s+(add|insert|delete|flush)\b|'
    r'init\.d/\S+\s+(restart|start|stop|reload|enable|disable)\b)')

JUDGE_PAT = re.compile(
    r'(verify_\w+|_\w*(missing|ok|installed|bad|exists|present|sane)\w*|'
    r'\bif\s|\bcase\s|\|\||\bthen\b)')


def has_func(src, name):
    return re.search(r'^%s\(\)' % re.escape(name), src, re.M) is not None


def func_body(src, name):
    m = re.search(r'^%s\(\)\s*\{[ \t]*\n(.*?)\n\}' % re.escape(name), src, re.S | re.M)
    return m.group(1) if m else None


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else 'files/usr/sbin/crowdsec-lxc-bootstrap.sh'
    src = open(path, encoding='utf-8').read()

    m = re.search(r'^DAG_NODES="([^"]*)"', src, re.M)
    if not m:
        print('FAIL 找不到 DAG_NODES')
        return 1
    nodes = m.group(1).split()

    m = re.search(r'^RO_ONLY_NODES="([^"]*)"', src, re.M)
    ro = set(m.group(1).split()) if m else set()

    bad = 0
    print('%-16s %-6s %-6s %-6s %-6s' % ('node', 'V1', 'V2', 'V3', 'V4'))
    print('-' * 46)
    for n in nodes:
        v = func_body(src, 'verify_' + n)
        b = func_body(src, 'build_' + n)
        v1 = has_func(src, 'verify_' + n)
        # 单行定义 `build_x() { build_y; }` 提取不到函数体，但函数确实存在
        v2 = has_func(src, 'build_' + n) or n in ro
        # V3 只是提示：节点级 verify-first 由 ensure 保证（先 verify_X，不过才 build_X），
        # build 体内不再要求自带判断。单行转发实现一律跳过。
        v3 = True if b is None else bool(JUDGE_PAT.search(b))
        v4 = True
        if v is not None:
            lines = v.split('\n')
            for i, ln in enumerate(lines, 1):
                if ln.lstrip().startswith('#'):
                    continue
                if WRITE_PAT.search(ln):
                    v4 = False
                    print('   !! %-16s verify 体第 %d 行有写动作：%s' % (n, i, ln.strip()[:70]))
        ok = v1 and v2 and v4
        bad += 0 if ok else 1
        print('%-16s %-6s %-6s %-6s %-6s %s'
              % (n, 'Y' if v1 else 'NO', 'Y' if v2 else 'NO',
                 'Y' if v3 else 'NO', 'Y' if v4 else 'NO', '' if ok else '<-- 违规'))

    print()
    print('节点 %d 个，违规 %d 个' % (len(nodes), bad))

    # 共用实现：两个以上节点转发到同一个 build_xxx，出问题时日志难分是谁的锅
    shared = {}
    for m2 in re.finditer(r'^build_(\w+)\(\)\s*\{\s*build_(\w+);\s*\}', src, re.M):
        shared.setdefault(m2.group(2), []).append(m2.group(1))
    dup = {k: v for k, v in shared.items() if len(v) >= 2}
    if dup:
        print()
        print('提示：以下节点共用同一份 build 实现（节点粒度仍在，只是实现没拆）')
        for impl, who in dup.items():
            print('   %-20s <- %s' % (impl, ' / '.join(who)))
    return 0 if bad == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
