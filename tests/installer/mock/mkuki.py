#!/usr/bin/env python3
"""A minimal PE file with a .osrel section, standing in for a UKI.

usage: mkuki.py OUT IMAGE_VERSION [USRHASH]
"""
import struct
import sys

out, ver = sys.argv[1], sys.argv[2]
usrhash = sys.argv[3] if len(sys.argv) > 3 else "ab" * 32
osrel = (f'ID=nura\nIMAGE_ID=samsung-gtactive3wifi_phosh_edge\nIMAGE_VERSION="{ver}"\n'
         f"VARIANT_ID=phosh\n").encode()
cmdline = f"usrhash={usrhash} quiet\n".encode()
dos = bytearray(64)
dos[:2] = b"MZ"
struct.pack_into("<I", dos, 0x3C, 64)
pe = b"PE\0\0" + struct.pack("<HHIIIHH", 0xAA64, 2, 0, 0, 0, 0, 0)
hdr_end = 64 + len(pe) + 2 * 40
data_off = (hdr_end + 511) // 512 * 512


def section(name, payload, off):
    return name.ljust(8, b"\0") + struct.pack("<IIIIIIHHI", len(payload), 0, len(payload), off, 0, 0, 0, 0, 0)


off2 = data_off + (len(osrel) + 511) // 512 * 512
sects = section(b".osrel", osrel, data_off) + section(b".cmdline", cmdline, off2)
img = bytearray(bytes(dos) + pe + sects)
img += b"\0" * (data_off - len(img)) + osrel
img += b"\0" * (off2 - len(img)) + cmdline
open(out, "wb").write(img)
