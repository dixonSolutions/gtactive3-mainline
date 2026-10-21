#!/usr/bin/env python3
"""Streaming decrypt of a Samsung FUS .enc4 firmware file (AES-128-ECB).

The key is md5(logic-check string); the string lives in a text file (never in git).
Same algorithm as tools/fusdl.py, but stand-alone and resumable-safe: output goes to
OUT.part and is renamed only after a complete, block-aligned decrypt.

usage: python3 -I enc4_decrypt.py IN.enc4 KEYFILE OUT
"""
import hashlib
import os
import sys

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

enc, keyfile, out = sys.argv[1:4]
with open(keyfile) as f:
    key = hashlib.md5(f.read().strip().encode()).digest()
size = os.path.getsize(enc)
if size % 16:
    sys.exit(f"{enc}: size {size} is not a multiple of 16 (truncated download?)")
dec = Cipher(algorithms.AES(key), modes.ECB()).decryptor()
tmp = out + ".part"
done = last = 0
with open(enc, "rb") as fi, open(tmp, "wb") as fo:
    while b := fi.read(1 << 24):
        fo.write(dec.update(b))
        done += len(b)
        if done - last >= 512 << 20:
            print(f"  {done >> 20} / {size >> 20} MiB", flush=True)
            last = done
    fo.write(dec.finalize())
with open(tmp, "rb") as f:
    if f.read(4) != b"PK\x03\x04":
        os.unlink(tmp)
        sys.exit("decrypted data is not a zip: wrong key?")
os.replace(tmp, out)
print("decrypted ->", out)
