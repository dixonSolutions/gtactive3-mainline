"""Decrypt the downloaded prefix of a FUS .enc4 file and list zip local entries."""
import hashlib, struct, sys, os
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
enc, logic_check_key, out = sys.argv[1], sys.argv[2], sys.argv[3]
key = hashlib.md5(logic_check_key.encode()).digest()
n = os.path.getsize(enc) // 16 * 16
dec = Cipher(algorithms.AES(key), modes.ECB()).decryptor()
with open(enc, 'rb') as fi, open(out, 'wb') as fo:
    left = n
    while left:
        b = fi.read(min(left, 1 << 22)); left -= len(b); fo.write(dec.update(b))
with open(out, 'rb') as f:
    pos = 0
    while True:
        f.seek(pos); h = f.read(30)
        if len(h) < 30 or h[:4] != b'PK\x03\x04': break
        _, _, flags, meth, _, _, crc, csz, usz, nl, el = struct.unpack('<IHHHHHIIIHH', h)
        name = f.read(nl).decode(); extra = f.read(el)
        if csz == 0xFFFFFFFF:  # zip64 extra
            i = 0
            while i < len(extra):
                tag, sz = struct.unpack('<HH', extra[i:i+4])
                if tag == 1: usz, csz = struct.unpack('<QQ', extra[i+4:i+20])
                i += 4 + sz
        data = pos + 30 + nl + el
        print(f"{name} method={meth} size={csz} data@{data} complete={data + csz <= n}")
        pos = data + csz
