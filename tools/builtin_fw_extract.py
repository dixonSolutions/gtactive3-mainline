#!/usr/bin/env python3
"""Extract CONFIG_EXTRA_FIRMWARE blobs from an uncompressed arm64 kernel Image.

.builtin_fw is an array of struct builtin_fw { const char *name; const u8 *data;
unsigned long size; } (include/linux/firmware.h). In a relocatable arm64 Image the
two pointers are zero in place and only live in the RELA table as
R_AARCH64_RELATIVE (r_info 0x403) addends, so we:
  1. find the RELA table (runs of {r_offset, 0x403, r_addend} triples),
  2. find the relocated slot whose addend points at a known firmware name,
  3. walk the 24-byte array both ways while name/data relocs and size look valid.
Kernel VA of Image offset 0 = KIMAGE_VADDR + text_offset (39-/48-bit layouts tried).

Also dumps the Broadcom BCM477x GPS/sensor-hub patch that Samsung's bbd driver
embeds as a text array and serves as /dev/bbd_patch (drivers/sensorhub/brcm/bbdpl/bbd.c),
to OUTDIR/bbd/<Name>.patch.

usage: python3 -I builtin_fw_extract.py Image OUTDIR KNOWN_NAME
"""
import os
import struct
import sys


def safe_join(top, name):
    """Join a name taken from the Image below top; refuse absolute paths and '..'."""
    rel = os.path.normpath(name)
    if os.path.isabs(rel) or rel == ".." or rel.startswith(".." + os.sep):
        sys.exit(f"refusing unsafe firmware name {name!r}")
    return os.path.join(top, rel)


img, outdir, known = sys.argv[1], sys.argv[2], sys.argv[3].encode()
d = open(img, "rb").read()
if d[56:60] != b"ARM\x64":
    sys.exit("not an arm64 Image")
text_offset = struct.unpack_from("<Q", d, 8)[0]

# 1. RELA: collect every R_AARCH64_RELATIVE triple (8-aligned scan for r_info == 0x403)
rel = {}
info = struct.pack("<Q", 0x403)
i = d.find(info)
while i >= 0:
    if i % 8 == 0 and i >= 8:
        off, add = struct.unpack_from("<Q", d, i - 8)[0], struct.unpack_from("<Q", d, i + 8)[0]
        rel[off] = add
    i = d.find(info, i + 1)
if not rel:
    sys.exit("no R_AARCH64_RELATIVE relocations found")

name_off = d.find(b"\0" + known + b"\0") + 1
if name_off <= 0:
    sys.exit("known name not in Image")
for kimage in (0xFFFFFF8008000000, 0xFFFF000008000000, 0xFFFF800008000000):
    base = kimage + text_offset
    slots = [o for o, a in rel.items() if a == base + name_off]
    if slots:
        break
else:
    sys.exit("no relocation points at the known name")


def entry(va):
    np, dp = rel.get(va), rel.get(va + 8)
    if np is None or dp is None:
        return None
    no, do = np - base, dp - base
    so = va + 16 - base
    if not (0 <= no < len(d) and 0 <= so + 8 <= len(d)):
        return None
    sz = struct.unpack_from("<Q", d, so)[0]
    e = d.find(b"\0", no)
    name = d[no:e]
    if not (0 < len(name) < 256 and all(32 < c < 127 for c in name)):
        return None
    if not (0 <= do and do + sz <= len(d) and 0 < sz < 64 << 20):
        return None
    return name.decode(), do, sz


start = end = slots[0]
while entry(start - 24):
    start -= 24
while entry(end):
    end += 24
os.makedirs(outdir, exist_ok=True)
print(f"builtin_fw at Image+{start - base:#x}: {(end - start) // 24} entries")
for va in range(start, end, 24):
    name, do, sz = entry(va)
    dst = safe_join(outdir, name)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, "wb") as f:
        f.write(d[do:do + sz])
    print(f"  {name}  {sz} bytes  (Image+{do:#x})")

# Samsung bbd: static unsigned char bbd_patch[] = "<FormatVersion=...>...<Blob=HEX...>\n";
o = d.find(b"<FormatVersion=")
while o >= 0:
    e = d.find(b"\0", o)
    blob = d[o:e]
    nm = blob.split(b"<Name=", 1)[1].split(b">", 1)[0].decode() if b"<Name=" in blob else "bbd"
    dst = safe_join(os.path.join(outdir, "bbd"), nm + ".patch")
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, "wb") as f:
        f.write(blob)
    print(f"  bbd/{nm}.patch  {len(blob)} bytes  (Image+{o:#x})")
    o = d.find(b"<FormatVersion=", e)
