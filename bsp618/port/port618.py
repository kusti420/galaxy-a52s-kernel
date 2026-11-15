#!/usr/bin/env python3
"""Regenerate the 6.18 port tree bsp618/src/ from the 6.12 module sources.

The 6.12 sources (bsp612/soc-repo, bsp612/techpacks, drivers612/, samsung612/modules/) are
never edited: they are copied into bsp618/src/ (a mirror of the repo root, like the survey's
survey-src/, so the copied build.sh files run unchanged), then

  1. patches/*.patch are applied in order (hand-written fixes, -p1 against bsp618/src/),
  2. build scripts are pointed at the copy and at the ACK 6.18 clang (r596125),
  3. the mechanical 6.12 -> 6.18 source rules below run over every .c/.h file,
  4. every kbuild Makefile/Kbuild gets the missing-prototypes -Werror relaxation,
     and the DROPPED modules are taken out of their makefiles (out-port/dropped.json lists
     them for the report),
  5. soc-repo-staging is assembled (ACK 6.18 drivers/ net/ + the ported soc-repo:
     build-survey.sh stage with SRC=bsp618/src).

Every rule is 6.18-only (no LINUX_VERSION_CODE guards): the tree is regenerated, so the 6.12
sources stay the single place to edit. Per-file change counts: bsp618/out-port/port618.log.

Usage: port618.py [--fresh] [--no-stage]
  --fresh     delete bsp618/src first (default: rsync over it, keeping build outputs for
              incremental builds; transformed files get a new mtime and are rebuilt)
  --no-stage  skip step 5
Build afterwards: bsp618/port/build618.sh (see there).
"""
import collections, os, re, shutil, subprocess, sys

PORT = os.path.dirname(os.path.abspath(__file__))
B = os.path.dirname(PORT)
R = os.path.dirname(B)
SRC = os.path.join(B, 'src')
OUT = os.path.join(B, 'out-port')

# (repo-relative source, extra rsync excludes)
SOURCES = [
    ('bsp612/soc-repo', []),
    ('bsp612/techpacks', ['Module.symvers']),
    # wlan/donors only feed conn/wlan "build.sh prepare", whose result (work/) is in git
    ('drivers612', ['/conn/wlan/donors/']),
    ('samsung612/modules', []),
    # the hypervisor watchdog module of the kexec harness (modules/hhwdt, built there against
    # out-ack/): rebuilt here against the 6.18 vendor kernel for the test ramdisk
    ('modules/hhwdt', []),
]
LINKS = {  # src-relative link -> target (absolute)
    'ack': os.path.join(R, 'ack'),
    'donors': os.path.join(R, 'donors'),
    'bsp612/kernel': os.path.join(R, 'ack'),
    # the lahaina module config + GKI vmlinux/Module.symvers of the survey are reused as-is
    'bsp612/out': os.path.join(B, 'out-survey'),
}
# build outputs and local work areas are not sources
EXCLUDES = ['*.o', '*.ko', '*.mod', '*.mod.c', '*.cmd', '*.a', '*.d', '*.o.d', '*.order',
            '*.symvers', '*.log', '*.dtb', '*.dtbo', '*.img', '*.cpio.gz', '.tmp_versions/',
            '.git/', '/*/out/', '/*/*/out/', '/*/build/', '.cache.mk',
            '/androidboot/out/']
CLANG_612, CLANG_618 = 'clang-r547379', 'clang-r596125'

stats = collections.Counter()      # rule -> files changed
sites = collections.Counter()      # rule -> edits
perfile = collections.defaultdict(collections.Counter)
warnings = []


def log_edit(rule, path, n):
    if n:
        stats[rule] += 1
        sites[rule] += n
        perfile[os.path.relpath(path, SRC)][rule] += n


def run(cmd, **kw):
    r = subprocess.run(cmd, **kw)
    if r.returncode:
        sys.exit(f'port618: command failed ({r.returncode}): {" ".join(cmd)}')
    return r


# ---------------------------------------------------------------- 1. copy
def sync(fresh):
    if fresh and os.path.isdir(SRC):
        shutil.rmtree(SRC)
    for rel, extra in SOURCES:
        dst = os.path.join(SRC, rel)
        os.makedirs(dst, exist_ok=True)
        ex = [f'--exclude={e}' for e in EXCLUDES + extra]
        run(['rsync', '-a', '--delete', *ex, os.path.join(R, rel) + '/', dst + '/'])
    for rel, tgt in LINKS.items():
        p = os.path.join(SRC, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        if os.path.islink(p) or os.path.exists(p):
            if os.path.islink(p) and os.readlink(p) == tgt:
                continue
            os.remove(p)
        os.symlink(tgt, p)


# ---------------------------------------------------------------- 2. patches
def apply_patches():
    pd = os.path.join(PORT, 'patches')
    for f in sorted(os.listdir(pd)) if os.path.isdir(pd) else []:
        # ack-*.patch are for the ACK kernel tree (ack/, applied there by hand), not bsp618/src
        if not f.endswith('.patch') or f.startswith('ack-'):
            continue
        r = subprocess.run(['patch', '-p1', '-d', SRC, '--forward', '--batch', '-s',
                            '-r', '-', '--no-backup-if-mismatch', '-i', os.path.join(pd, f)],
                           capture_output=True, text=True)
        if r.returncode:
            sys.exit(f'port618: patch {f} does not apply:\n{r.stdout}{r.stderr}')
        stats['patch'] += 1


# ---------------------------------------------------------------- 3. build scripts
def fix_scripts():
    """Same edits the survey made by hand: the copied scripts build the copy with r596125."""
    for top in ('drivers612', 'samsung612'):
        for d, dirs, fs in os.walk(os.path.join(SRC, top)):
            for f in fs:
                p = os.path.join(d, f)
                if os.path.islink(p):
                    continue
                if not (f.endswith(('.sh', '.mk')) or f.startswith(('Kbuild', 'Makefile'))):
                    continue
                s = o = open(p, errors='surrogateescape').read()
                s = s.replace(CLANG_612, CLANG_618)
                # absolute repo root (P=/home/.../a52sxq-mainline) -> the copy
                s = re.sub(re.escape(R) + r'(?=$|[\s;"\'/)])', SRC, s, flags=re.M)
                # camera reaches soc-repo as $(srctree)/../soc-repo (srctree = bsp612/kernel on
                # 6.12); srctree is ack/ here
                s = s.replace('$(srctree)/../soc-repo', os.path.join(SRC, 'bsp612/soc-repo'))
                if s != o:
                    open(p, 'w', errors='surrogateescape').write(s)
                    log_edit('scripts', p, 1)
    # regeneration steps would overwrite the ported tree from donors: the copy already holds
    # their output (both trees are in git)
    p = os.path.join(SRC, 'drivers612/secure/securemsm/build.sh')
    s = open(p).read()
    s2 = s.replace('rsync -a --delete --exclude=.git/ "$DON/" "$SRC/"\n',
                   ': # bsp618/port: src/ is the pre-generated 6.12 tree (donor rsync skipped)\n')
    s2 = s2.replace('for p in "$HERE"/patches/*.patch; do\n', 'for p in; do  # bsp618/port: already applied\n')
    if s2 == s:
        sys.exit('port618: securemsm/build.sh anchors not found')
    open(p, 'w').write(s2)
    p = os.path.join(SRC, 'drivers612/conn/wlan/build.sh')
    s = open(p).read()
    a = 'prepare() {  # rebuild work/ from donors/ + patches/ (WORK=<dir> to build elsewhere)\n'
    if a not in s:
        sys.exit('port618: conn/wlan/build.sh anchor not found')
    open(p, 'w').write(s.replace(a, a + '  echo "bsp618/port: work/ is the pre-generated 6.12 tree, prepare skipped"; return 0\n'))


# ---------------------------------------------------------------- 4. source rules
def call_end(s, pos):
    """pos is just after a '('; returns (index after the matching ')', top-level args)"""
    depth, j, start, args = 1, pos, pos, []
    while depth:
        c = s[j]
        if c in '([{':
            depth += 1
        elif c in ')]}':
            depth -= 1
        elif c == ',' and depth == 1:
            args.append(s[start:j]); start = j + 1
        j += 1
    args.append(s[start:j - 1])
    return j, [a.strip() for a in args]


def body_span(s, pos):
    a = s.index('{', pos)
    depth = 0
    for k in range(a, len(s)):
        if s[k] == '{':
            depth += 1
        elif s[k] == '}':
            depth -= 1
            if not depth:
                return a, k + 1
    raise ValueError('unbalanced')


def r_remove_new(s, p):
    """platform_driver.remove_new is gone (v6.13): .remove has the void prototype since v6.11."""
    s, n = re.subn(r'\.remove_new(\s*=)', r'.remove\1', s)
    # a .remove callback that still returns int: make it void (only `return 0;` style bodies)
    for name in set(re.findall(r'\.remove\s*=\s*(\w+)', s)):
        m = re.search(r'(?:static\s+)?\bint(\s+)' + name +
                      r'(\s*\(\s*struct\s+platform_device\s*\*\s*\w*\s*\))\s*\{', s)
        if not m or re.search(r'\bvoid\s+' + name + r'\s*\(\s*struct\s+platform_device', s):
            continue  # none, or a version-guarded void variant already exists
        a, b = body_span(s, m.start())
        body = s[a:b]
        rets = re.findall(r'\breturn\b([^;]*);', body)
        if any(r.strip() not in ('0', '') for r in rets):
            warnings.append(f'{os.path.relpath(p, SRC)}: {name}() returns non-zero; left int')
            continue
        body = re.sub(r'\n(?:[ \t]*\n)?[ \t]*return\s+0\s*;\s*\n(\s*)\}$', r'\n\1}', body)
        body = re.sub(r'\breturn\s+0\s*;', 'return;', body)
        head = s[m.start():a].replace('int' + m.group(1) + name, 'void' + m.group(1) + name, 1)
        s = s[:m.start()] + head + body + s[b:]
        # a forward declaration with the old type
        s = re.sub(r'(?:static\s+)?\bint(\s+' + name + r'\s*\(\s*struct\s+platform_device\s*\*\s*\w*\s*\)\s*;)',
                   lambda mm: mm.group(0).replace('int', 'void', 1), s)
        n += 1
    return s, n


TIMER_RENAMES = [  # timer_list API (v6.15/v6.16 renames; the old names are gone in 6.18)
    (r'\btry_to_del_timer_sync\b', 'timer_delete_sync_try'),
    (r'\bdel_singleshot_timer_sync\b', 'timer_delete_sync'),
    (r'\bdel_timer_sync\b', 'timer_delete_sync'),
    (r'\bdel_timer\b', 'timer_delete'),
    (r'\bfrom_timer\b', 'timer_container_of'),
]


def r_timer(s, p):
    n = 0
    for a, b in TIMER_RENAMES:
        s, k = re.subn(a, b, s)
        n += k
    # compat aliases ("#define from_timer timer_container_of") became self-defines: drop them
    s, k = re.subn(r'^[ \t]*#[ \t]*define[ \t]+(timer_\w+)[ \t]+\1[ \t]*\n', '', s, flags=re.M)
    return s, n + k


def expr_rx(e):
    """regex for a C lvalue expression, whitespace-insensitive"""
    return r'\s*'.join(re.escape(t) for t in re.findall(r'\w+|->|\S', e))


def r_hrtimer(s, p):
    """hrtimer_init(t, clk, mode) + t->function = fn  ->  hrtimer_setup(t, fn, clk, mode) (v6.16)."""
    n, i = 0, 0
    rx = re.compile(r'\bhrtimer_init(_on_stack)?\s*\(')
    while True:
        m = rx.search(s, i)
        if not m:
            break
        i = m.end()
        line0 = s.rfind('\n', 0, m.start()) + 1
        if s[line0:m.start()].lstrip().startswith(('#', '*', '//')):  # macro/comment: leave
            continue
        j, args = call_end(s, m.end())
        if len(args) != 3:
            continue
        t, clk, mode = args
        # the matching "->function =" assignment, in the rest of the enclosing block
        if t.startswith('&'):
            acc = expr_rx(t[1:].strip()) + r'\s*\.\s*function'
        else:
            acc = r'(?:' + expr_rx(t) + r'|\(\s*' + expr_rx(t) + r'\s*\))\s*->\s*function'
        depth, lim = 0, len(s)
        for k in range(j, len(s)):
            c = s[k]
            if c == '{':
                depth += 1
            elif c == '}':
                depth -= 1
                if depth < 0:
                    lim = k
                    break
        fm = re.compile(r'\n[ \t]*' + acc + r'\s*=\s*([^;]+);[ \t]*(?=\n)').search(s, j, lim)
        if fm and not re.sub(r'/\*.*?\*/|//[^\n]*', '', s[:fm.start()], flags=re.S).rstrip().endswith((';', '{', '}')):
            fm = None  # the body of an if/else: keep it, the callback is chosen at run time
        if fm:
            fn = fm.group(1).strip()
            s = s[:fm.start()] + s[fm.end():]
        else:
            # set right before each hrtimer_start() elsewhere (kept): take that callback when the
            # file assigns exactly one to a timer of this name, else the core's dummy
            last = re.findall(r'\w+', t)[-1]
            fns = set(re.findall(r'\b' + last + r'\s*(?:->|\.)\s*function\s*=\s*(\w+)\s*;', s))
            fn = fns.pop() if len(fns) == 1 else 'hrtimer_dummy_timeout'
            warnings.append(f'{os.path.relpath(p, SRC)}: hrtimer_init({t}) without a .function '
                            f'assignment in the same block: {fn} (later assignments kept)')
        setup = 'hrtimer_setup_on_stack' if m.group(1) else 'hrtimer_setup'
        rep = f'{setup}({t}, {fn}, {clk}, {mode})'
        s = s[:m.start()] + rep + s[j:]
        i = m.start() + len(rep)
        n += 1
    return s, n


def r_alarm(s, p):
    """alarm timer callbacks return void (v6.18: enum alarmtimer_restart is gone)."""
    if 'alarmtimer_restart' not in s:
        return s, 0
    n = 0
    for m in list(re.finditer(r'\benum\s+alarmtimer_restart(\s+\**\s*\w+\s*\(\s*struct\s+alarm\s*\*)', s))[::-1]:
        head_end = s.find(')', m.end())
        nxt = s[head_end + 1:head_end + 40].lstrip()
        if nxt.startswith('{'):
            a, b = body_span(s, head_end)
            body = s[a:b]
            if 'ALARMTIMER_RESTART' in body:
                warnings.append(f'{os.path.relpath(p, SRC)}: alarm callback returns ALARMTIMER_RESTART: not converted')
                continue
            body = re.sub(r'\n(?:[ \t]*\n)?[ \t]*return\s+ALARMTIMER_NORESTART\s*;\s*\n(\s*)\}$', r'\n\1}', body)
            body = re.sub(r'\breturn\s+ALARMTIMER_NORESTART\s*;', 'return;', body)
            s = s[:m.start()] + 'void' + s[m.start() + len(m.group(0)) - len(m.group(1)):a] + body + s[b:]
        else:
            s = s[:m.start()] + 'void' + s[m.start() + len(m.group(0)) - len(m.group(1)):]
        n += 1
    return s, n


def r_namespace(s, p):
    """Symbol namespaces are string literals since v6.13 (cdd30ebb1b9f)."""
    s, n1 = re.subn(r'^(?![ \t]*#[ \t]*define)([^\n]*?\bMODULE_IMPORT_NS\s*\(\s*)([A-Za-z_]\w*)(\s*\))',
                    r'\1"\2"\3', s, flags=re.M)
    s, n2 = re.subn(r'^(?![ \t]*#[ \t]*define)([^\n]*?\bEXPORT_SYMBOL_NS(?:_GPL)?\s*\(\s*\w+\s*,\s*)([A-Za-z_]\w*)(\s*\))',
                    r'\1"\2"\3', s, flags=re.M)
    return s, n1 + n2


def r_ida(s, p):
    """ida_simple_get/remove are gone: ida_alloc_range (inclusive max) / ida_free."""
    n = 0
    out, i = [], 0
    for m in re.finditer(r'\bida_simple_get\s*\(', s):
        if m.start() < i:
            continue
        j, args = call_end(s, m.end())
        if len(args) != 4:
            continue
        ida, lo, hi, gfp = args
        if hi == '0':
            rep = f'ida_alloc_min({ida}, {lo}, {gfp})' if lo != '0' else f'ida_alloc({ida}, {gfp})'
        else:
            rep = f'ida_alloc_range({ida}, {lo}, ({hi}) - 1, {gfp})'
        out.append(s[i:m.start()] + rep)
        i = j
        n += 1
    out.append(s[i:])
    s = ''.join(out)
    s, k = re.subn(r'\bida_simple_remove\b', 'ida_free', s)
    return s, n + k


def r_kthread_worker(s, p):
    """6.12 kthread_create_worker[_on_cpu]() returned a RUNNING worker; since 6.14 it only
    creates it and kthread_run_worker[_on_cpu]() also wakes it. Unconverted vendor workers
    never ran on 6.18 (kgsl_cooling_worker / kgsl_devfreq_notify stuck in D, hung_task panic,
    run ab618-a3 2026-11-14)."""
    s, n = re.subn(r'\bkthread_create_worker_on_cpu\s*\(', 'kthread_run_worker_on_cpu(', s)
    s, k = re.subn(r'\bkthread_create_worker\s*\(', 'kthread_run_worker(', s)
    return s, n + k


def r_nth_page(s, p):
    """nth_page() is gone (v6.18): struct page arrays are virtually contiguous, p + n."""
    n, i = 0, 0
    rx = re.compile(r'\bnth_page\s*\(')
    while True:
        m = rx.search(s, i)
        if not m:
            break
        line0 = s.rfind('\n', 0, m.start()) + 1
        j, args = call_end(s, m.end())
        if s[line0:m.start()].lstrip().startswith('#') or len(args) != 2:
            i = j
            continue
        rep = f'(({args[0]}) + ({args[1]}))'
        s = s[:m.start()] + rep + s[j:]
        i = m.start() + len(rep)
        n += 1
    return s, n


def r_bin_attr(s, p):
    """sysfs bin_attribute read/write callbacks and attribute_group.bin_attrs are const (v6.16)."""
    if 'bin_attribute' not in s:
        return s, 0
    s, n = re.subn(r'(\(\s*struct\s+file\s*\*\s*\w*\s*,\s*struct\s+kobject\s*\*\s*\w*\s*,\s*)'
                   r'struct(\s+bin_attribute\s*\*)', r'\1const struct\2', s)
    for name in set(re.findall(r'\.bin_attrs\s*=\s*(\w+)\s*,', s)):
        s, k = re.subn(r'(?<!const )\bstruct\s+bin_attribute\s*\*\s*' + name + r'\s*\[\s*\]',
                       f'const struct bin_attribute *const {name}[]', s)
        n += k
    return s, n


DAIFMT = [('CBM_CFM', 'CBP_CFP'), ('CBS_CFM', 'CBC_CFP'), ('CBM_CFS', 'CBP_CFC'), ('CBS_CFS', 'CBC_CFC')]


def r_daifmt(s, p):
    """the legacy master/slave DAI format names are gone; same values as provider/consumer"""
    n = 0
    for a, b in DAIFMT:
        s, k = re.subn(r'\bSND_SOC_DAIFMT_' + a + r'\b', 'SND_SOC_DAIFMT_' + b, s)
        n += k
    return s, n


def r_pinconf(s, p):
    """PIN_CONFIG_OUTPUT was renamed PIN_CONFIG_LEVEL (same meaning: drive the pin to arg)"""
    return re.subn(r'\bPIN_CONFIG_OUTPUT\b', 'PIN_CONFIG_LEVEL', s)


def r_gpio_set(s, p):
    """gpio_chip.set/.set_multiple return int (v6.17): void callbacks get `return 0`"""
    n = 0
    for name in set(re.findall(r'(?:\.|->)set(?:_multiple)?\s*=\s*(\w+)\s*[;,]', s)):
        m = re.search(r'(?:static\s+)?\bvoid(\s+)' + name + r'(\s*\(\s*struct\s+gpio_chip\s*\*[^)]*\))\s*\{', s)
        if not m or re.search(r'\bint\s+' + name + r'\s*\(\s*struct\s+gpio_chip', s):
            continue
        a, b = body_span(s, m.start())
        body = re.sub(r'\breturn\s*;', 'return 0;', s[a:b])
        body = body[:-1].rstrip() + '\n\n\treturn 0;\n}'
        head = s[m.start():a].replace('void' + m.group(1) + name, 'int' + m.group(1) + name, 1)
        s = s[:m.start()] + head + body + s[b:]
        s = re.sub(r'(?:static\s+)?\bvoid(\s+' + name + r'\s*\(\s*struct\s+gpio_chip\s*\*[^)]*\)\s*;)',
                   lambda mm: mm.group(0).replace('void', 'int', 1), s)
        n += 1
    return s, n


def r_console(s, p):
    """console_stop/console_start were renamed console_suspend/console_resume (v6.15)"""
    s, a = re.subn(r'\bconsole_stop\s*\(', 'console_suspend(', s)
    s, b = re.subn(r'\bconsole_start\s*\(', 'console_resume(', s)
    return s, a + b


def r_sdhci_free(s, p):
    """sdhci_pltfm_free() is gone: in 6.18 sdhci_pltfm_init() allocates with devm"""
    return re.subn(r'\n[ \t]*sdhci_pltfm_free\s*\(\s*\w+\s*\)\s*;[ \t]*(?=\n)', '', s)


def r_blk_crypto_key(s, p):
    """blk_crypto_key.raw[] is .bytes[] and BLK_CRYPTO_KEY_TYPE_STANDARD is _RAW in 6.18 (the
    upstream hardware-wrapped key support; the Android 6.12 names were its draft)"""
    if 'blk_crypto_key' not in s and 'BLK_CRYPTO_KEY_TYPE' not in s:
        return s, 0
    s, a = re.subn(r'\bkey->raw\b', 'key->bytes', s)
    s, b = re.subn(r'\bBLK_CRYPTO_KEY_TYPE_STANDARD\b', 'BLK_CRYPTO_KEY_TYPE_RAW', s)
    return s, a + b


def r_cfs_nr(s, p):
    """cfs_rq.h_nr_running is h_nr_queued in 6.18 (v6.14; on android16-6.12 the two names were
    a KMI union, same count: queued entities incl. delayed-dequeue ones). idle_h_nr_running
    is h_nr_idle."""
    s, a = re.subn(r'(\.|->)(\s*)h_nr_running\b', r'\1\2h_nr_queued', s)
    s, b = re.subn(r'(\.|->)(\s*)idle_h_nr_running\b', r'\1\2h_nr_idle', s)
    return s, a + b


def r_dma_fence(s, p):
    """dma_fence_ops lost .fence_value_str/.timeline_value_str and .use_64bit_seqno in 6.18:
    64-bit fences are made with dma_fence_init64() (DMA_FENCE_FLAG_SEQNO64_BIT), and
    __dma_fence_is_later() takes the fence instead of its ops. The value_str callbacks were
    debug output only (sync_file info, the drivers' own fault dumps): their initialisers and
    the `if (f->ops->x_value_str) f->ops->x_value_str(...)` call sites go, the callbacks stay
    (__maybe_unused)."""
    if 'dma_fence' not in s:
        return s, 0
    n = 0
    # 1. initialisers; keep the callbacks, unused now
    fns = set()
    def drop_init(m):
        fns.add(m.group(2))
        return ''
    s, k = re.subn(r'\n[ \t]*\.(fence_value_str|timeline_value_str)\s*=\s*(\w+)\s*,?[ \t]*(?=\n)', drop_init, s)
    n += k
    for fn in fns:
        s = re.sub(r'\b(static\s+(?:inline\s+)?void\s+)(?!__maybe_unused)(' + fn + r'\s*\()', r'\1__maybe_unused \2', s)
    # 2. call sites: if (E->ops->x_value_str) <stmt>;  /  { ... }
    out, i = [], 0
    rx = re.compile(r'\bif\s*\(\s*([\w.>\-]+?)\s*->\s*ops\s*->\s*(fence|timeline)_value_str\s*\)\s*')
    for m in rx.finditer(s):
        if m.start() < i:
            continue
        j = m.end()
        if s[j] == '{':
            a, b = body_span(s, j)
            end = b
        else:
            end = s.index(';', j) + 1
        if m.group(2) == 'fence':
            # the fence's own value: print the seqno, as dma_fence_describe() does in 6.18
            body = s[j:end]
            cm = re.search(re.escape(m.group(1)) + r'\s*->\s*ops\s*->\s*fence_value_str\s*\(', body)
            k, args = call_end(body, cm.end())
            body = (body[:cm.start()] + f'snprintf({args[1]}, {args[2]}, "%llu", {args[0]}->seqno)'
                    + body[k:])
            out.append(s[i:m.start()] + '/* bsp618/port: dma_fence_ops.fence_value_str is gone in 6.18 */ '
                       + body)
        else:
            out.append(s[i:m.start()] + '/* bsp618/port: dma_fence_ops.timeline_value_str is gone in 6.18 */')
            warnings.append(f'{os.path.relpath(p, SRC)}: dropped a timeline_value_str call (debug output)')
        i = end
        n += 1
    out.append(s[i:])
    s = ''.join(out)
    # 3. .use_64bit_seqno = true -> dma_fence_init64() for fences made with that ops table
    for m in list(re.finditer(r'\n[ \t]*\.use_64bit_seqno\s*=\s*true\s*,?[ \t]*(?=\n)', s))[::-1]:
        head = s.rfind('dma_fence_ops', 0, m.start())
        ops = re.match(r'dma_fence_ops\s+(\w+)', s[head:])
        s = s[:m.start()] + s[m.end():]
        n += 1
        if not ops:
            warnings.append(f'{os.path.relpath(p, SRC)}: use_64bit_seqno without a named ops table')
            continue
        s, k = re.subn(r'\bdma_fence_init(\s*\([^;]*?&\s*' + ops.group(1) + r'\b)', r'dma_fence_init64\1', s)
        if not k:
            warnings.append(f'{os.path.relpath(p, SRC)}: {ops.group(1)} is 64-bit but no dma_fence_init() uses it here')
        n += k
    # 4. __dma_fence_is_later(f1, f2, E->ops) -> __dma_fence_is_later(E, f1, f2)
    out, i = [], 0
    for m in re.finditer(r'\b__dma_fence_is_later\s*\(', s):
        j, args = call_end(s, m.end())
        if len(args) != 3 or not re.fullmatch(r'.+->\s*ops', args[2]):
            continue
        e = re.sub(r'\s*->\s*ops$', '', args[2])
        out.append(s[i:m.start()] + f'__dma_fence_is_later({e}, {args[0]}, {args[1]})')
        i = j
        n += 1
    out.append(s[i:])
    return ''.join(out), n


def enclosing_brace(s, pos):
    """index of the unmatched '{' before pos"""
    depth = 0
    for k in range(pos - 1, -1, -1):
        c = s[k]
        if c == '}':
            depth += 1
        elif c == '{':
            if not depth:
                return k
            depth -= 1
    return -1


def r_dpcm_dir(s, p):
    """snd_soc_dai_link.dpcm_playback/.dpcm_capture are gone (v6.14): DPCM links take their
    directions from the CPU DAI, restricted by .playback_only/.capture_only. 6.12 semantics
    kept: on a DPCM link (.dynamic or .no_pcm) dpcm_playback alone = playback_only, dpcm_capture
    alone = capture_only, both or neither = unrestricted; non-DPCM links ignored the flags."""
    if 'dpcm_playback' not in s and 'dpcm_capture' not in s:
        return s, 0
    starts = sorted({enclosing_brace(s, m.start()) for m in
                     re.finditer(r'\.dpcm_(?:playback|capture)\s*=', s)} - {-1}, reverse=True)
    n = 0
    for a in starts:
        a, b = body_span(s, a)
        blk = s[a:b]
        flag = lambda f: re.search(r'\.' + f + r'\s*=\s*(?:1|true)\s*,', blk) is not None
        pb, cp = flag('dpcm_playback'), flag('dpcm_capture')
        dpcm = flag('dynamic') or flag('no_pcm')
        add = None
        if dpcm and pb and not cp and not flag('playback_only'):
            add = 'playback_only'
        elif dpcm and cp and not pb and not flag('capture_only'):
            add = 'capture_only'
        if (pb != cp) and not dpcm:
            warnings.append(f'{os.path.relpath(p, SRC)}: dpcm_{"playback" if pb else "capture"} '
                            f'alone on a link without a literal .dynamic/.no_pcm: dropped (6.12 ignored it there too)')
        first = [True]
        def sub(m):
            if add and first[0]:
                first[0] = False
                return m.group(1) + '.' + add + ' = 1,\t/* bsp618/port: was dpcm_' + add.split('_')[0] + ' alone */'
            return ''
        blk2 = re.sub(r'(\n[ \t]*)\.dpcm_(?:playback|capture)\s*=\s*\w+\s*,[^\n]*', sub, blk)
        if blk2 != blk:
            s = s[:a] + blk2 + s[b:]
            n += 1
    return s, n


def gki_namespaces():
    """symbol -> namespace of every namespaced export of the 6.18 GKI build"""
    m = {}
    for l in open(os.path.join(B, 'out-survey/gki/Module.symvers')):
        a = l.rstrip('\n').split('\t')
        if len(a) > 4 and a[4] and not a[4].startswith('module:'):
            m[a[1]] = a[4]
    return m


GKI_NS = gki_namespaces()
GKI_NS_RX = re.compile(r'\b(' + '|'.join(sorted(map(re.escape, GKI_NS), key=len, reverse=True)) + r')\b(?=\s*\()')


def r_ns_import(s, p):
    """6.18 GKI exports more symbols in namespaces than 6.12 did (DMA_BUF_HEAP, MINIDUMP,
    ANDROID_GKI_VFS_..., PWM...). modpost fails the whole M= build and the loader refuses the
    module when one is used without MODULE_IMPORT_NS: import what each .c file calls."""
    if not p.endswith('.c'):
        return s, 0
    code = re.sub(r'/\*.*?\*/|//[^\n]*', '', s, flags=re.S)
    code = re.sub(r'^[ \t]*#[ \t]*define\b(?:[^\n]*\\\n)*[^\n]*', '', code, flags=re.M)
    need = sorted({GKI_NS[m.group(1)] for m in GKI_NS_RX.finditer(code)})
    need = [ns for ns in need if not re.search(r'MODULE_IMPORT_NS\(\s*"' + re.escape(ns) + r'"\s*\)', s)]
    if not need:
        return s, 0
    add = '\n/* bsp618/port: namespaced in the 6.18 GKI exports */\n#include <linux/module.h>\n'
    add += ''.join(f'MODULE_IMPORT_NS("{ns}");\n' for ns in need)
    return s.rstrip('\n') + '\n' + add, len(need)


RULES = [('remove-new', r_remove_new), ('nth-page', r_nth_page), ('bin-attr-const', r_bin_attr),
         ('console-suspend', r_console), ('sdhci-pltfm-free', r_sdhci_free),
         ('asoc-daifmt', r_daifmt), ('pinconf-level', r_pinconf), ('gpio-set-int', r_gpio_set), ('timer-api', r_timer), ('hrtimer-setup', r_hrtimer),
         ('alarm-void', r_alarm), ('ns-string', r_namespace), ('ida-simple', r_ida), ('kthread-run-worker', r_kthread_worker),
         ('blk-crypto-key', r_blk_crypto_key), ('dma-fence-ops', r_dma_fence),
         ('cfs-h-nr-queued', r_cfs_nr),
         ('asoc-dpcm-dir', r_dpcm_dir),
         ('ns-import', r_ns_import)]
TOPS = ['bsp612/soc-repo', 'bsp612/techpacks', 'drivers612', 'samsung612/modules', 'modules/hhwdt']
# trees under these are never compiled by the module builds (userspace tests, references)
SKIP_DIRS = ('/touch/orig', '/secure/qseetest', '/uapi-compare', '/soc-repo/tools',
             '/soc-repo/scripts', '/soc-repo/Documentation')


def transform():
    for top in TOPS:
        for d, dirs, fs in os.walk(os.path.join(SRC, top)):
            if any(x in d + '/' for x in (sd + '/' for sd in SKIP_DIRS)):
                dirs[:] = []
                continue
            for f in fs:
                if not f.endswith(('.c', '.h')):
                    continue
                p = os.path.join(d, f)
                if os.path.islink(p):
                    continue
                s = o = open(p, errors='surrogateescape').read()
                for name, fn in RULES:
                    s, k = fn(s, p)
                    log_edit(name, p, k)
                if s != o:
                    open(p, 'w', errors='surrogateescape').write(s)


WERR = ('\n# bsp618/port: 6.18 turns on -Wmissing-prototypes/-declarations by default (v6.8,\n'
        '# Makefile.extrawarn) and CONFIG_WERROR makes them fatal; android16-6.12 had them\n'
        '# under W=1. Kept as warnings until the vendor code gets static/header fixes.\n'
        'ccflags-y += -Wno-error=missing-prototypes -Wno-error=missing-declarations\n')


def werror():
    """append the relaxation to every kbuild makefile (one that assigns obj-*)"""
    for top in TOPS:
        for d, dirs, fs in os.walk(os.path.join(SRC, top)):
            if any(x in d + '/' for x in (sd + '/' for sd in SKIP_DIRS)):
                dirs[:] = []
                continue
            for f in fs:
                if not (f in ('Kbuild', 'Makefile') or f.startswith('Kbuild.')):
                    continue
                p = os.path.join(d, f)
                if os.path.islink(p):
                    continue
                s = open(p, errors='surrogateescape').read()
                if 'bsp618/port: 6.18 turns on' in s or not re.search(r'^\s*obj-[\w$()]+\s*[:+]?=', s, re.M):
                    continue
                open(p, 'a').write(WERR)
                log_edit('werror-relax', p, 1)


# Forks taken out of the 6.18 build on purpose (report status "dropped"): (makefile under
# bsp618/src, regex of its obj- line, module as survey-report.py names it, reason)
DROPPED = [
    ('bsp612/soc-repo/drivers/hwmon/Makefile', r'obj-\$\(CONFIG_HWMON\)\s*\+=\s*hwmon\.o',
     'bsp612/soc-repo-staging/drivers/hwmon/hwmon',
     'GKI 6.18 has HWMON=y built in (6.12 GKI had it off); a module copy would clash with the '
     'built-in core, which sec_thermistor and qti_amoled_ecm link against'),
    ('bsp612/soc-repo/drivers/iommu/arm/arm-smmu-v3/Makefile',
     r'obj-\$\(CONFIG_QCOM_SMMU_V2_V3_DISPATCHER\)\s*\+=\s*qcom_smmu_v2_v3_dispatcher\.o',
     'bsp612/soc-repo-staging/drivers/iommu/arm/arm-smmu-v3/qcom_smmu_v2_v3_dispatcher',
     'pKVM SMMUv2/v3 dispatcher (kvm/iommu.h); this phone runs Gunyah, not pKVM; never loaded '
     'on 6.12'),
    ('drivers612/display/techpack/display-drivers/bridge-drivers/Kbuild',
     r'obj-\$\(CONFIG_DRM_LT9611UXC\)\s*\+=\s*lt9611uxc\.o',
     'drivers612/display/techpack/display-drivers/bridge-drivers/lt9611uxc',
     'Lontium LT9611UXC DSI-to-HDMI bridge (Qualcomm reference boards); the A52s has none, '
     'its DT has no lt9611 node, never loaded on 6.12'),
    # remaining-modules pass (2026-11-14): copies of GKI modules, other-SoC/other-board drivers
    ('bsp612/soc-repo/drivers/block/zram/Makefile', r'obj-\$\(CONFIG_ZRAM\)\s*\+=\s*zram\.o',
     'bsp612/soc-repo-staging/drivers/block/zram/zram',
     'older Qualcomm copy of zram (no multi-backend zcomp); GKI 6.18 ships zram.ko, which the '
     '6.12 real boot (GKI zram) and the 6.18 Android pack already load'),
    ('bsp612/soc-repo/mm/Makefile', r'obj-\$\(CONFIG_ZSMALLOC\)\s*\+=\s*zsmalloc\.o',
     'bsp612/soc-repo-staging/mm/zsmalloc',
     'zram\'s allocator, same as zram: GKI 6.18 ships zsmalloc.ko (6.18 dropped zpool, which '
     'the soc-repo copy still includes); the GKI module is the one loaded'),
    ('bsp612/soc-repo/drivers/block/Makefile', r'obj-\$\(CONFIG_VIRTIO_BLK\)\s*\+=\s*virtio_block\.o',
     'bsp612/soc-repo-staging/drivers/block/virtio_block',
     'virtio block for Qualcomm guest VMs; Android runs on the host here (5.4: VIRTIO_BLK off), '
     'GKI 6.18 has its own virtio_blk.ko'),
    ('bsp612/soc-repo/drivers/net/phy/aquantia/Makefile', r'obj-\$\(CONFIG_AQUANTIA_PHY\)\s*\+=\s*aquantia\.o',
     'bsp612/soc-repo-staging/drivers/net/phy/aquantia/aquantia',
     'Aquantia Ethernet PHY (automotive/IoT boards); the A52s has no Ethernet (5.4: AQUANTIA_PHY '
     'off); half the module is soc-repo, half ACK 6.18 (aquantia_leds.c), which do not match'),
    ('bsp612/soc-repo/sound/soc/codecs/Makefile', r'obj-\$\(CONFIG_SND_SOC_HDMI_CODEC\)\s*\+=\s*snd-soc-hdmi-codec\.o',
     'bsp612/soc-repo-staging/sound/soc/codecs/snd-soc-hdmi-codec',
     'ASoC HDMI codec for DSI/DP-to-HDMI bridges (lt9611uxc, dropped); no HDMI on the A52s; the '
     'Qualcomm DP/HDMI audio path is audio-kernel\'s hdmi_dlkm (builds)'),
    ('bsp612/soc-repo/drivers/irqchip/Makefile', r'obj-\$\(CONFIG_QCOM_SHOW_RESUME_IRQ\)\s*\+=\s*msm_show_resume_irq\.o',
     'bsp612/soc-repo-staging/drivers/irqchip/msm_show_resume_irq',
     'debug aid (prints the GIC SPIs pending at resume); matches only "qcom,show-resume-irqs", a '
     'node the A52s tree does not have, and copies the GIC driver\'s private gic_chip_data; '
     'never loaded on 6.12 (drivers612/suspend/README.md); /sys/power/pm_wakeup_irq covers it'),
    ('bsp612/soc-repo/drivers/pci/controller/Makefile', r'obj-\$\(CONFIG_PCI_MSM\)\s*\+=\s*pci-msm-drv\.o',
     'bsp612/soc-repo-staging/drivers/pci/controller/pci-msm-drv',
     'Qualcomm PCIe root complex: both RCs (pcie0/pcie1) are disabled in the A52s tree (modem is '
     'on-die, WCN6750 on AHB), nothing enumerates (5.4 built it in, no device); a port would '
     'have to re-derive its private copy of the AER core\'s per-device stats (6.18 aer_info). '
     'Only mhi.ko imports it (msm_pcie_allow/prevent_l1); mhi is not loaded either (no MHI device)'),
]


def drop():
    import json
    for mk, rx, mod, why in DROPPED:
        p = os.path.join(SRC, mk)
        s = open(p).read()
        s2, k = re.subn(r'^(' + rx + r'[^\n]*)$', r'# bsp618/port: dropped, see port618.py DROPPED\n# \1', s,
                        count=1, flags=re.M)
        if not k:
            sys.exit(f'port618: DROPPED anchor not found in {mk}')
        open(p, 'w').write(s2)
        log_edit('dropped', p, 1)
    json.dump({mod: why for mk, rx, mod, why in DROPPED}, open(os.path.join(OUT, 'dropped.json'), 'w'),
              indent=1)


# soc-repo directories that are plain copies of ACK code: replaced by the ACK 6.18 sources
# (soc-repo dir under bsp618/src, ACK dir, why). The copy is emptied except for ACK 6.18's
# own Makefile, so `build-survey.sh stage` leaves ACK 6.18's .c/.h files in soc-repo-staging
# (it rsyncs ack/drivers *.c *.h first, then soc-repo over it) and the module keeps its
# soc-repo name and place in the build.
UPSTREAM = [
    ('bsp612/soc-repo/drivers/gpu/drm/display', 'drivers/gpu/drm/display',
     'drm_display_helper: the soc-repo copy is an unmodified older snapshot of upstream (its '
     'diff to ACK 6.12 only reverts later upstream fixes; Qualcomm changed nothing but the '
     'Makefile layout). The GKI does not build DRM_DISPLAY_HELPER, so the module is ACK 6.18\'s '
     'own drivers/gpu/drm/display, built with the lahaina config'),
]


def upstream():
    for rel, ack_rel, why in UPSTREAM:
        d = os.path.join(SRC, rel)
        for f in os.listdir(d):
            p = os.path.join(d, f)
            shutil.rmtree(p) if os.path.isdir(p) and not os.path.islink(p) else os.remove(p)
        mk = open(os.path.join(R, 'ack', ack_rel, 'Makefile')).read()
        open(os.path.join(d, 'Makefile'), 'w').write(
            mk + '\n# bsp618/port: ACK 6.18 Makefile and sources (soc-repo copy replaced, see '
            'port618.py UPSTREAM)\n')
        log_edit('upstream', os.path.join(d, 'Makefile'), 1)


def stage():
    env = dict(os.environ, SURVEY_SRC=SRC, SURVEY_LOGS=os.path.join(OUT, 'logs'),
               SURVEY_RESULTS=OUT)
    os.makedirs(os.path.join(OUT, 'logs'), exist_ok=True)
    run([os.path.join(B, 'build-survey.sh'), 'stage'], env=env)


def main():
    args = sys.argv[1:]
    os.makedirs(OUT, exist_ok=True)
    sync('--fresh' in args)
    upstream()
    apply_patches()
    fix_scripts()
    transform()
    werror()
    drop()
    if '--no-stage' not in args:
        stage()
    with open(os.path.join(OUT, 'port618.log'), 'w') as lg:
        lg.write('# rule: files changed, edit sites\n')
        for k in sorted(stats):
            lg.write(f'{k}: {stats[k]} files, {sites[k]} sites\n')
        lg.write('\n# warnings\n' + ''.join(w + '\n' for w in warnings))
        lg.write('\n# per file\n')
        for f in sorted(perfile):
            lg.write(f + ': ' + ', '.join(f'{k} {v}' for k, v in sorted(perfile[f].items())) + '\n')
    for k in sorted(stats):
        print(f'port618: {k:14s} {stats[k]:5d} files {sites[k]:6d} sites')
    for w in warnings:
        print('port618: warning:', w)


if __name__ == '__main__':
    main()
