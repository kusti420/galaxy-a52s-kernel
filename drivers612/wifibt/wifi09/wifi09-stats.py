#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
# WIFI-09: count WLAN suspend timeouts and Wi-Fi drops in a `dumpsys batterystats --history` dump (PC side).
#   wifi09-stats.py <batterystats.txt> [MM-DD HH:MM:SS of a kernel change, optional]
# Prints, per window: wake/abort records (= suspend attempts that ended), WoW NACKs (-11), WLAN suspend
# timeouts (wcn6750 -110 / phy0 -62 or the "Callback failed ... returned -110/-62" form), then every timeout
# with the seconds since the previous record and whether a NACK or an RX wakelock abort came just before,
# then every supplicant drop (completed -> anything else) with the timeout that preceded it, if any.
import sys, re, datetime, collections

f = sys.argv[1]
cut = sys.argv[2] if len(sys.argv) > 2 else None
TS = re.compile(r'^\s+(\d\d-\d\d \d\d:\d\d:\d\d)\.(\d+)')
WR = re.compile(r'wake_reason=\d+:"([^"]*)"')
WLAN = r'(wcn6750|phy0|icnss)'
def T(s): return datetime.datetime.strptime('2000-' + s, '%Y-%m-%d %H:%M:%S')
def is_to(w): return re.search(WLAN, w) and re.search(r'(error|returned) -(110|62)\b', w)
def is_nack(w): return re.search(WLAN, w) and re.search(r'(error|returned) -11\b', w)

cnt = collections.defaultdict(collections.Counter)
hist = collections.deque(maxlen=6); timeouts = []; drops = []
state = None; last_to = None; screen = '?'
for l in open(f, errors='replace'):
    m = TS.match(l)
    if not m: continue
    t = m.group(1); k = 'all' if not cut else ('before' if t < cut else 'after')
    if '+screen' in l: screen = 'on'
    if '-screen' in l: screen = 'off'
    for w in WR.findall(l):
        cnt[k]['records'] += 1
        if w.startswith('Abort'): cnt[k]['aborts'] += 1
        if is_nack(w): cnt[k]['wow_nack_-11'] += 1
        if 'WLAN_CE' in w: cnt[k]['wlan_wakes'] += 1
        if is_to(w):
            cnt[k]['wlan_timeouts'] += 1; last_to = (t, w)
            timeouts.append((t, w, list(hist)))
        hist.append((t, w))
    m2 = re.search(r'wifi_suppl=([\w-]+)', l)
    if m2:
        s = m2.group(1)
        if state == 'completed' and s != 'completed':
            cnt[k]['drops'] += 1
            near = last_to if last_to and 0 <= (T(t) - T(last_to[0])).total_seconds() < 30 else None
            if near: cnt[k]['drops_after_timeout'] += 1
            drops.append((t, s, screen, near))
        state = s
for k in cnt: print(k, dict(cnt[k]))
print('\n== WLAN suspend timeouts')
for t, w, h in timeouts:
    gap = (T(t) - T(h[-1][0])).total_seconds() if h else -1
    nack = any(is_nack(x) and (T(t) - T(a)).total_seconds() <= 12 for a, x in h)
    rx = any('rx_wakelock' in x and (T(t) - T(a)).total_seconds() <= 6 for a, x in h)
    print(f'{t}  since_prev={gap:.0f}s  {"NACK<=12s " if nack else ""}{"RXWL<=6s " if rx else ""} {w[-52:]}')
print('\n== Wi-Fi drops (supplicant left "completed")')
for t, s, sc, near in drops:
    print(f'{t} -> {s:10s} screen={sc:3s} ' + (f'AFTER TIMEOUT {near[0]}' if near else ''))
