#!/usr/bin/env python3
"""Synthetic firmware files for the firmware tool tests (no Samsung data).

    fixtures.py fdt OUT MODEL COMPATIBLE...   a minimal DTB
    fixtures.py dtbo OUT                      a DT table (dtbo partition) with two DTBs
    fixtures.py bootimg OUT                   a v2 boot image: kernel with an embedded config + a DTB
"""
import gzip
import struct
import sys


def fdt(model, *compatible):
    strings = b"model\0compatible\0"

    def prop(nameoff, value):
        v = value + b"\0" * (-len(value) % 4)
        return struct.pack(">3I", 3, len(value), nameoff) + v

    st = struct.pack(">I", 1) + b"\0\0\0\0"  # BEGIN_NODE ""
    st += prop(0, model.encode() + b"\0")
    st += prop(6, b"".join(c.encode() + b"\0" for c in compatible))
    st += struct.pack(">2I", 2, 9)  # END_NODE, END
    off_rsv = 40
    off_struct = off_rsv + 16
    off_strings = off_struct + len(st)
    total = off_strings + len(strings)
    hdr = struct.pack(">10I", 0xD00DFEED, total, off_struct, off_strings, off_rsv, 17, 16, 0, len(strings), len(st))
    return hdr + b"\0" * 16 + st + strings


def dtbo():
    blobs = [fdt("Test board rev0", "test,board-rev0", "test,soc"), fdt("Test board rev1", "test,board-rev1", "test,soc")]
    hsize, esize = 32, 32
    off = hsize + esize * len(blobs)
    entries, data = b"", b""
    for b in blobs:
        entries += struct.pack(">8I", len(b), off + len(data), 0, 0, 0, 0, 0, 0)
        data += b
    total = off + len(data)
    return struct.pack(">8I", 0xD7B7AB1E, total, hsize, esize, len(blobs), hsize, 4096, 0) + entries + data


def bootimg():
    cfg = b"CONFIG_TEST_ONE=y\nCONFIG_TEST_TWO=m\n# CONFIG_TEST_THREE is not set\n"
    kernel = b"\0" * 64 + b"Linux version 4.14.113-test (test@test)\0" + b"IKCFG_ST" + gzip.compress(cfg) + b"IKCFG_ED" + b"\0" * 64
    dtb = fdt("Test board", "test,board", "test,soc")
    ps = 2048

    def pad(b):
        return b + b"\0" * (-len(b) % ps)

    hdr = b"ANDROID!" + struct.pack("<10I", len(kernel), 0x10008000, 0, 0x11000000, 0, 0, 0x10000100, ps, 2, 0)
    hdr += b"\0" * 16 + b"console=ram".ljust(512, b"\0") + b"\0" * 32 + b"\0" * 1024
    hdr += struct.pack("<IQI", 0, 0, 1660)  # recovery dtbo size/offset, header size
    hdr += struct.pack("<IQ", len(dtb), 0x10000000)
    return pad(hdr) + pad(kernel) + pad(dtb)


def main():
    a = sys.argv[1:]
    if not a:
        sys.exit(__doc__)
    if a[0] == "fdt":
        data = fdt(a[2], *a[3:])
    elif a[0] == "dtbo":
        data = dtbo()
    elif a[0] == "bootimg":
        data = bootimg()
    else:
        sys.exit(__doc__)
    with open(a[1], "wb") as f:
        f.write(data)


if __name__ == "__main__":
    main()
