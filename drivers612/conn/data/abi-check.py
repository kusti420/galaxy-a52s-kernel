#!/usr/bin/env python3
"""ABI gate for the IPA uapi headers (/dev/ipa, /dev/wwan_ioctl).

The ROM's vendor ipacm/libipanat were built with the 5.4 headers (abi54/linux,
copied from kernel_a52sxq_bone include/uapi/linux). The ioctl numbers carry
pointer types, so nothing at run time notices a struct-layout difference.
This script compares, for everything BOTH header sets define:
  - the full record layout of every struct (clang -fdump-record-layouts:
    member offsets, names, sizeof, align),
  - the value of every enum constant and object-like numeric macro
    (ioctl command numbers included).
Differences must be listed in abi54/EXCEPTIONS with a reason, else exit 1.
Exception kinds (see that file): struct NAME, prefix NAME (5.4 layout must be
a prefix of the new one), member NAME (new member inside 5.4 padding: sizes
and all other offsets must still match), value NAME [NEWVALUE].

Usage: abi-check.py [-v] [REF_INCLUDE_DIR [NEW_INCLUDE_DIR]]
"""
import os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
HDRS = ['linux/msm_ipa.h', 'linux/rmnet_ipa_fd_ioctl.h', 'linux/ipa_qmi_service_v01.h']
PRE = '#define __packed __attribute__((packed))\n#include <stdio.h>\n#include <stddef.h>\n' + \
      ''.join('#include <%s>\n' % h for h in HDRS)
CC = os.environ.get('HOSTCLANG', 'clang')
CFLAGS = ['-w']


def text(d):
    out = ''
    for h in HDRS:
        s = open(os.path.join(d, h), errors='replace').read()
        s = re.sub(r'/\*.*?\*/', ' ', s, flags=re.S)
        out += re.sub(r'\\\n', ' ', s) + '\n'
    return out


def names(d):
    s = text(d)
    structs = set(re.findall(r'^\s*struct\s+(\w+)\s*\{', s, re.M))
    enums = set()
    for body in re.findall(r'\benum\s+\w*\s*\{(.*?)\}', s, re.S):
        body = re.sub(r'^\s*#.*$', '', body, flags=re.M)
        for item in body.split(','):
            m = re.match(r'\s*(\w+)', item)
            if m:
                enums.add(m.group(1))
    # object-like macros with a value; string macros are not ABI numbers
    macros = set(m.group(1) for m in
                 re.finditer(r'^[ \t]*#[ \t]*define[ \t]+(\w+)[ \t]+(\S.*)$', s, re.M)
                 if '"' not in m.group(2))
    return structs, enums, macros


def run(args, **kw):
    return subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, **kw)


def layouts(d, structs, tmp, skip=()):
    src = os.path.join(tmp, 'l.c')
    with open(src, 'w') as f:
        f.write(PRE + ''.join('unsigned long s_%s = sizeof(struct %s);\n' % (n, n) for n in sorted(structs)))
    r = run([CC, '-fsyntax-only', '-Xclang', '-fdump-record-layouts'] + CFLAGS + ['-I', d, src])
    if r.returncode:
        sys.exit('abi-check: layout dump failed for %s:\n%s' % (d, r.stderr[-3000:]))
    res = {}
    for blk in r.stdout.split('*** Dumping AST Record Layout')[1:]:
        lines = [l for l in blk.strip('\n').split('\n') if '|' in l]
        m = re.match(r'\s*0 \| struct (\w+)$', lines[0])
        if not m:
            continue
        rows = []
        for l in lines[1:]:
            off, rest = l.split('|', 1)
            rest = re.sub(r'\(unnamed [^)]*\)', '(unnamed)', rest)
            rest = re.sub(r'\(anonymous [^)]*\)', '(unnamed)', rest)
            if rest.strip().startswith('['):
                rows.append(rest.strip())
            else:
                depth = (len(rest) - len(rest.lstrip())) // 2
                # offset, nesting depth, member name (type spelling may differ)
                if rest.split()[-1] in skip:
                    continue
                rows.append('%s d%d %s' % (off.strip(), depth, rest.split()[-1]))
        res[m.group(1)] = rows
    return res


def values(d, consts, tmp):
    consts = sorted(consts)
    while True:
        src = os.path.join(tmp, 'v.c')
        with open(src, 'w') as f:
            f.write(PRE + 'int main(void){\n' +
                    ''.join('printf("%s %%lld\\n",(long long)(%s));\n' % (n, n) for n in consts) +
                    'return 0;}\n')
        exe = os.path.join(tmp, 'v')
        r = run([CC] + CFLAGS + ['-I', d, src, '-o', exe])
        if r.returncode == 0:
            break
        nhead = PRE.count('\n') + 1
        bad = set()
        for m in re.finditer(r'v\.c:(\d+):\d+: error', r.stderr):
            i = int(m.group(1)) - nhead - 1
            if 0 <= i < len(consts):
                bad.add(consts[i])
        if not bad:
            sys.exit('abi-check: value program failed for %s:\n%s' % (d, r.stderr[-3000:]))
        consts = [c for c in consts if c not in bad]
    out = run([exe]).stdout
    return dict(l.split() for l in out.splitlines())


def exceptions():
    exc = {}
    p = os.path.join(HERE, 'abi54', 'EXCEPTIONS')
    if os.path.exists(p):
        for l in open(p):
            l = l.split('#')[0].split()
            if len(l) >= 2:
                exc[(l[0], l[1])] = l[2] if len(l) > 2 else None
    return exc


def main():
    a = [x for x in sys.argv[1:] if x != '-v']
    verbose = '-v' in sys.argv
    ref = a[0] if a else os.path.join(HERE, 'abi54')
    new = a[1] if len(a) > 1 else os.path.join(HERE, 'src/dataipa/drivers/platform/msm/include/uapi')
    rs, re_, rm = names(ref)
    ns, ne, nm = names(new)
    exc = exceptions()
    used = set()
    fails = []
    with tempfile.TemporaryDirectory() as tmp:
        lr = layouts(ref, rs & ns, tmp)
        # 'member X': a new-header-only member that sits in 5.4 padding
        skip = set(n for k, n in exc if k == 'member')
        used |= set(('member', n) for n in skip)
        ln = layouts(new, rs & ns, tmp, skip)
        for n in sorted(rs & ns):
            if n not in lr or n not in ln:
                fails.append('struct %s: no layout dumped' % n)
                continue
            if lr[n] == ln[n]:
                continue
            if ('prefix', n) in exc:
                used.add(('prefix', n))
                body = lr[n][:-1]
                if ln[n][:len(body)] == body:
                    continue
                fails.append('struct %s: 5.4 layout is not a prefix of the new one' % n)
            elif ('struct', n) in exc:
                used.add(('struct', n))
                continue
            else:
                fails.append('struct %s: layout differs  5.4 %s  new %s' % (n, lr[n][-1], ln[n][-1]))
            if verbose:
                for x, y in zip(lr[n], ln[n]):
                    if x != y:
                        fails.append('    first difference: 5.4 "%s"  new "%s"' % (x, y))
                        break
        common = (re_ | rm) & (ne | nm)
        vr = values(ref, common, tmp)
        vn = values(new, common, tmp)
        for n in sorted(set(vr) & set(vn)):
            if vr[n] == vn[n]:
                continue
            if ('value', n) in exc:
                used.add(('value', n))
                if exc[('value', n)] in (None, vn[n]):
                    continue
                fails.append('value %s: excepted as %s but is %s' % (n, exc[('value', n)], vn[n]))
                continue
            fails.append('value %s: 5.4 %s  new %s' % (n, vr[n], vn[n]))
        stale = sorted(set(exc) - used)
    for k in stale:
        fails.append('stale exception: %s %s' % k)
    print('abi-check: %d common structs, %d common constants, %d exceptions, %d failures'
          % (len(rs & ns), len(set(vr) & set(vn)), len(exc), len(fails)))
    for f in fails:
        print('  ' + f)
    sys.exit(1 if fails else 0)


main()
