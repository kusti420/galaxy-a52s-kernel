#!/usr/bin/env python3
# Tiny LAN throughput peer for the Wi-Fi test (runs on the PC): netsrv.py <port>
# Client sends one line: "D <bytes>" -> server sends that many bytes; "U" -> server counts bytes until EOF and
# appends "U <bytes> <seconds>" to stdout. The phone side is toybox nc.
import socket, sys, time, threading
def serve(c):
    try:
        f = c.makefile('rb'); line = f.readline().decode().split()
        if line and line[0] == 'D':
            n = int(line[1]); buf = b'\xa5' * 65536
            while n > 0: c.sendall(buf[:min(n, 65536)]); n -= 65536
        elif line and line[0] == 'U':
            t0 = time.time(); n = 0
            while True:
                b = f.read(65536)
                if not b: break
                n += len(b)
            print('U', n, round(time.time() - t0, 3), flush=True)
    except Exception as e: print('ERR', e, flush=True)
    finally: c.close()
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('0.0.0.0', int(sys.argv[1]))); s.listen(4)
while True:
    c, _ = s.accept(); threading.Thread(target=serve, args=(c,), daemon=True).start()
