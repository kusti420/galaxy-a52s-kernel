# katcheck.py <key hex> <iv_offset sectors> <pat> <ct> <rt>: AES-256-XTS reference (blk-crypto: tweak = le128 DUN per 4096-byte unit)
import sys
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
k = bytes.fromhex(sys.argv[1]); iv0 = int(sys.argv[2]) // 8
pat, ct, rt = (open(f, 'rb').read() for f in sys.argv[3:6])
bad = 0
for u in range(len(pat) // 4096):
    e = Cipher(algorithms.AES(k), modes.XTS((iv0 + u).to_bytes(16, 'little'))).encryptor()
    if e.update(pat[u*4096:(u+1)*4096]) + e.finalize() != ct[u*4096:(u+1)*4096]: bad += 1
print(f'ciphertext units matching the AES-256-XTS reference: {len(pat)//4096 - bad}/{len(pat)//4096}; read-back == pattern: {rt == pat}; ciphertext != plaintext: {ct != pat}')
