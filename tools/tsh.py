#!/usr/bin/env python3
"""Run one shell command on the test kernel's telnet shell (TSH_IP, default 172.16.42.1, port 23) and print its output.
Usage: tsh.py [-t seconds] 'command'   (exit 0 if the end marker was seen)"""
import os, socket, sys, time
args = sys.argv[1:]; tmo = 20.0
if args and args[0] == '-t': tmo = float(args[1]); args = args[2:]
cmd = ' '.join(args); M = '__TSH_END__'
s = socket.create_connection((os.environ.get('TSH_IP', '172.16.42.1'), 23), timeout=5); s.settimeout(0.5)
def strip_iac(b):
    out = bytearray(); i = 0
    while i < len(b):
        if b[i] == 255 and i + 2 < len(b) + 1: i += 3; continue
        out.append(b[i]); i += 1
    return bytes(out)
time.sleep(0.5)
try: s.recv(4096)
except Exception: pass
B = '__TSH_BEGIN__'
# The telnet shell echoes the command line back. Both markers are sent with a quote inside,
# so only the real output lines equal them; everything before the begin marker is dropped.
s.sendall(("echo " + B[:5] + "'" + B[5:] + "'; " + cmd + "; echo " + M[:5] + "'" + M[5:] + "'\n").encode())
buf = b''; t0 = time.time()
while time.time() - t0 < tmo:
    try:
        d = s.recv(65536)
        if not d: break
        buf += strip_iac(d)
        if M.encode() in buf: break
    except socket.timeout: pass
    except Exception: break
txt = buf.decode(errors='replace').replace('\r', '')
ok = any(l.strip() == M for l in txt.split('\n'))
lines = txt.split('\n')
out = []; started = False
for l in lines:
    if not started:
        started = (l.strip() == B)
        continue
    if l.strip() == M: break
    out.append(l)
sys.stdout.write('\n'.join(out) + ('\n' if out else ''))
sys.exit(0 if ok else 1)
