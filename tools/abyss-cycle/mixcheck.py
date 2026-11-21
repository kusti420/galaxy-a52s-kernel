#!/usr/bin/env python3
"""mixcheck.py <tinymix -D 0 output> <mixer_paths.xml> [more names...]
Which control names used by the ROM's mixer paths (and by abyssd's A2DP offload code) exist on this kernel.
Prints counts, the missing names, and the bt-sco / bt-a2dp paths that have a missing control."""
import re, sys, xml.etree.ElementTree as ET
ctls = set()
# tinymix prints BYTE controls without a line end, so the next control can follow on the same line
for l in open(sys.argv[1], errors='replace'):
    for m in re.finditer(r'(?:^|\s)(\d+)\t([A-Z0-9]+)\t(\d+)\t(.*?)(?= {2,}|\s*$|\t)', l.rstrip('\n')):
        ctls.add(m.group(4).strip())
root = ET.parse(sys.argv[2]).getroot()
used = {c.get('name') for c in root.iter('ctl')}
miss = sorted(n for n in used if n not in ctls)
print(f"{len(ctls)} controls on the card; mixer_paths.xml uses {len(used)} names, missing: {len(miss)}")
for n in miss: print("  MISSING (mixer_paths):", n)
extra = ['AFE Dynamic Bitrate', 'SBM Delay', 'A2DP_SLIM7_UL_HL Switch', 'AFE Input Bit Format', 'AFE Input Channels',
         'BT SampleRate', 'BT SampleRate RX', 'BT SampleRate TX', 'BT set feedback channel', 'SLIM_7_RX Encoder Config',
         'SLIM_7_TX Decoder Config', 'SLIM7_RX ADM Channels', 'HFP_SLIM7_UL_HL Switch', 'AFE Input Bit Format',
         'AFE Scrambler Mode', 'TWS Channel Mode', 'SLIM_7_RX APTX_AD Enc Cfg', 'LC3 Channel Mode', 'SLIMBUS_7_RX DRIFT',
         'AFE Output Channels SLIM7'] + sys.argv[3:]
print("A2DP offload / BT run-time controls:", ", ".join(f"{n}={'ok' if n in ctls else 'MISSING'}" for n in dict.fromkeys(extra)))
bad = 0; tot = 0
for p in root.iter('path'):
    n = p.get('name') or ''
    if 'bt-sco' in n or 'bt-a2dp' in n:
        cs = [c.get('name') for c in p.findall('ctl')]
        if not cs: continue
        tot += 1
        m = [c for c in cs if c not in ctls]
        if m: bad += 1; print("  path", n, "missing", m)
print(f"bt-sco / bt-a2dp paths with own controls: {tot}, with a missing control: {bad}")
