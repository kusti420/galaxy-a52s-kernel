#!/usr/bin/env python3
"""Copy a file from the PC into the test kernel's RAM through its telnet shell (base64 heredoc).
Works with nothing but busybox on the phone and needs no connection from the phone to the PC.
Usage: tput.py <local file> <remote path>   (env TSH_IP, default 172.16.42.1)"""
import base64, os, select, socket, sys, time
src, dst = sys.argv[1], sys.argv[2]
s = socket.create_connection((os.environ.get('TSH_IP', '172.16.42.1'), 23), timeout=5)
s.setblocking(False)
def drain(t=0.0):
    buf = b''
    end = time.time() + t
    while True:
        r, _, _ = select.select([s], [], [], max(0, end - time.time()))
        if not r: break
        try:
            d = s.recv(65536)
        except BlockingIOError:
            continue
        if not d: break
        buf += d
    return buf
def send(b):
    v = memoryview(b)
    while v:
        _, w, _ = select.select([], [s], [], 10)
        if not w: raise SystemExit('send stalled')
        try: n = s.send(v)
        except BlockingIOError: n = 0
        v = v[n:]
        drain()
drain(0.5)
send(b"stty -echo; /bin/busybox base64 -d > " + dst.encode() + b" <<'B64EOF'\n")
t0 = time.time(); total = 0
with open(src, 'rb') as f:
    while True:
        chunk = f.read(57 * 4096)
        if not chunk: break
        send(base64.encodebytes(chunk)); total += len(chunk)
send(b"B64EOF\necho TPUT_DONE $(/bin/busybox sha256sum " + dst.encode() + b" | cut -c1-64)\n")
buf = b''; end = time.time() + 120
while time.time() < end and b'TPUT_DONE ' not in buf.replace(b'echo TPUT_DONE', b''):
    buf += drain(1.0)
import hashlib
want = hashlib.sha256(open(src, 'rb').read()).hexdigest()
ok = want.encode() in buf
print(f"{src} -> {dst}: {total} bytes in {time.time()-t0:.0f}s, sha256 {'OK' if ok else 'MISMATCH'}")
sys.exit(0 if ok else 1)
