#!/usr/bin/env python3
# 核验 packages/ 里的真实包名，对照 custom-packages.sh 的点名。
# 用法：
#   python3 shell/audit-package-names.py                 # 扫 packages/ + shell/*custom-packages.sh
#   python3 shell/audit-package-names.py --dir packages --list shell/custom-packages.sh
# 用法要点：
#   - 包名只认 ipk 的 control:Package / apk 的 .PKGINFO:pkgname，不看文件名
#   - 报告里 [DIFF] 表示文件名不符合 <pkg>_<ver>_<arch>.ipk，但安装不受影响（Packages 索引带 Filename）
#   - [MISS] 表示清单点了名但 packages/ 里没有，可能来自官方 feed，也可能是真缺
import argparse
import gzip
import io
import os
import re
import sys
import tarfile


def _control_fields(raw):
    try:
        tf = tarfile.open(fileobj=io.BytesIO(gzip.decompress(raw)))
    except Exception:
        return {}
    for m in tf.getmembers():
        if m.name.lstrip('./') == 'control':
            f = tf.extractfile(m)
            if not f:
                return {}
            d = {}
            for ln in f.read().decode('utf-8', 'replace').splitlines():
                if ':' in ln:
                    k, v = ln.split(':', 1)
                    d[k.strip()] = v.strip()
            return d
    return {}


def ipk_control(path):
    data = open(path, 'rb').read()
    if data.startswith(b'!<arch>\n'):
        pos, fields = 8, {}
        while pos + 60 <= len(data):
            hdr = data[pos:pos + 60]
            name = hdr[0:16].decode('ascii', 'replace').strip().rstrip('/')
            try:
                size = int(hdr[48:58].decode('ascii').strip())
            except ValueError:
                break
            body = data[pos + 60:pos + 60 + size]
            if name.startswith('control.tar'):
                fields = _control_fields(body)
                break
            pos += 60 + size + (size & 1)
        return fields
    try:
        outer = tarfile.open(fileobj=io.BytesIO(gzip.decompress(data)))
    except Exception:
        return {}
    for m in outer.getmembers():
        if m.name.lstrip('./').startswith('control.tar'):
            f = outer.extractfile(m)
            if f:
                return _control_fields(f.read())
    return {}


def apk_pkginfo(path):
    try:
        tf = tarfile.open(fileobj=io.BytesIO(gzip.decompress(open(path, 'rb').read())))
    except Exception:
        return {}
    for m in tf.getmembers():
        if m.name.lstrip('./') == '.PKGINFO':
            f = tf.extractfile(m)
            if not f:
                return {}
            d = {}
            for ln in f.read().decode('utf-8', 'replace').splitlines():
                if '=' in ln:
                    k, v = ln.split('=', 1)
                    d[k.strip()] = v.strip()
            return d
    return {}


def list_names(list_files):
    """从 custom-packages.sh 里取出所有点名（跳过注释行、跳过 -排除项）"""
    names = set()
    for lf in list_files:
        if not os.path.exists(lf):
            continue
        for ln in open(lf, encoding='utf-8', errors='replace'):
            s = ln.strip()
            if s.startswith('#') or not s.startswith('CUSTOM_PACKAGES='):
                continue
            m = re.search(r'"(.*)"', s)
            if not m:
                continue
            for tok in m.group(1).split()[1:]:
                if tok.startswith('-'):
                    continue
                names.add(tok)
    return names


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dir', default='packages', help='包目录，默认 packages')
    ap.add_argument('--list', nargs='*', default=None, help='清单文件，默认 shell/*custom-packages.sh')
    args = ap.parse_args()

    pkg_dir = args.dir
    if not os.path.isdir(pkg_dir):
        print('[ERR] 目录不存在: %s' % pkg_dir)
        return 2

    lists = args.list
    if lists is None:
        lists = [p for p in ['shell/custom-packages.sh', 'shell/apk-custom-packages.sh'] if os.path.exists(p)]
        if not lists:
            lists = []

    ipks = sorted(f for f in os.listdir(pkg_dir) if f.endswith('.ipk'))
    apks = sorted(f for f in os.listdir(pkg_dir) if f.endswith('.apk'))
    print('== 扫描 %s ==' % pkg_dir)
    print('ipk %d 个 / apk %d 个' % (len(ipks), len(apks)))

    real = {}       # pkgname -> [(file, ver, arch)]
    diff = []       # 文件名不规范
    nopkg = []      # 读不出包名

    for fn in ipks:
        c = ipk_control(os.path.join(pkg_dir, fn))
        pkg, ver, arch = c.get('Package'), c.get('Version'), c.get('Architecture')
        if not pkg:
            nopkg.append(fn)
            continue
        real.setdefault(pkg, []).append((fn, ver or '?', arch or '?'))
        want = '%s_%s_%s.ipk' % (pkg, ver, arch)
        if fn != want:
            diff.append((fn, pkg, ver, arch, want))

    for fn in apks:
        c = apk_pkginfo(os.path.join(pkg_dir, fn))
        pkg, ver, arch = c.get('pkgname'), c.get('pkgver'), c.get('pkgarch')
        if not pkg:
            nopkg.append(fn)
            continue
        real.setdefault(pkg, []).append((fn, ver or '?', arch or '?'))
        want = '%s-%s.apk' % (pkg, ver)
        if fn != want:
            diff.append((fn, pkg, ver, arch, want))

    print('真实包名 %d 个' % len(real))

    print()
    print('== [DIFF] 文件名与包名不一致 %d 个（安装不受影响，点名要用左边括号里的 Package）==' % len(diff))
    for fn, pkg, ver, arch, want in diff:
        print('  %-56s -> Package=%-30s %s | %s' % (fn, pkg, ver, arch))
        print('       标准名: %s' % want)

    dup = {k: v for k, v in real.items() if len(v) > 1}
    if dup:
        print()
        print('== [DUP] 同包多版本 %d 个（opkg 取最高版本）==' % len(dup))
        for k in sorted(dup):
            print('  %-40s %s' % (k, ' , '.join('%s' % x[1] for x in dup[k])))

    if nopkg:
        print()
        print('== [WARN] 读不出包名 %d 个 ==' % len(nopkg))
        for fn in nopkg:
            print('  ', fn)

    if lists:
        want_names = list_names(lists)
        miss = sorted(n for n in want_names if n not in real)
        print()
        print('== 清单点名 %d 个 / packages 里没有 %d 个 ==' % (len(want_names), len(miss)))
        print('   注：官方 feed 提供的包（kmod-* / lib* / luci-i18n-* 等）本来就不在 packages/ 里，属正常')
        head = [n for n in miss if not n.startswith(('kmod-', 'lib', 'luci-i18n-'))]
        rest = [n for n in miss if n.startswith(('kmod-', 'lib', 'luci-i18n-'))]
        if head:
            print('   [MISS] 非 kmod/lib/i18n 的缺失（最值得看）:')
            for n in head[:60]:
                print('     ', n)
            if len(head) > 60:
                print('      ... 还有 %d 个' % (len(head) - 60))
        if rest:
            print('   [MISS] kmod / lib / i18n 类共 %d 个（通常由官方 feed 提供）:' % len(rest))
            for n in rest[:20]:
                print('     ', n)
            if len(rest) > 20:
                print('      ... 还有 %d 个' % (len(rest) - 20))

    return 0


if __name__ == '__main__':
    sys.exit(main())
