#!/usr/bin/env python3
"""Read an Android boot image (header v0-v2), as on the SM-T570 (v2).

usage:
  bootimg.py info IMG              KEY=VALUE lines (shell-safe)
  bootimg.py extract IMG PART OUT  PART: kernel, ramdisk, dtb
  bootimg.py find IMG MARKER       exit 0 if MARKER (text) is in the kernel
"""
import struct
import sys


def parse(path):
    with open(path, "rb") as f:
        d = f.read(4096)
    if d[:8] != b"ANDROID!":
        sys.exit(f"{path}: not an Android boot image")
    (ks, ka, rs, ra, ss, sa, ta, ps, hv, osv) = struct.unpack_from("<10I", d, 8)
    if hv > 2 or ps not in (2048, 4096):
        sys.exit(f"{path}: unsupported boot image (header v{hv}, page {ps})")
    h = dict(kernel_size=ks, kernel_addr=ka, ramdisk_size=rs, ramdisk_addr=ra,
             second_size=ss, second_addr=sa, tags_addr=ta, page_size=ps,
             header_version=hv, board=d[48:64].split(b"\0")[0].decode(errors="replace"),
             cmdline=d[64:576].split(b"\0")[0].decode(errors="replace"),
             dtbo_size=0, dtb_size=0, dtb_addr=0)
    ver, lvl = osv >> 11, osv & 0x7ff
    h["os_version"] = f"{ver >> 14}.{(ver >> 7) & 0x7f}.{ver & 0x7f}"
    h["os_patch_level"] = f"{2000 + (lvl >> 4)}-{lvl & 0xf:02d}"
    if hv >= 1:
        h["dtbo_size"] = struct.unpack_from("<I", d, 1632)[0]
    if hv >= 2:
        h["dtb_size"], h["dtb_addr"] = struct.unpack_from("<IQ", d, 1648)
    return h


def offsets(h):
    def up(n):
        return -(-n // h["page_size"]) * h["page_size"]
    o, out = h["page_size"], {}
    for part, size in (("kernel", h["kernel_size"]), ("ramdisk", h["ramdisk_size"]),
                       ("second", h["second_size"]), ("dtbo", h["dtbo_size"]),
                       ("dtb", h["dtb_size"])):
        out[part] = (o, size)
        o += up(size)
    return out


def main():
    a = sys.argv[1:]
    if len(a) < 2:
        sys.exit(__doc__)
    h = parse(a[1])
    if a[0] == "info":
        base = h["kernel_addr"] - 0x8000
        h.update(base=base, kernel_offset=0x8000, ramdisk_offset=h["ramdisk_addr"] - base,
                 tags_offset=h["tags_addr"] - base, dtb_offset=h["dtb_addr"] - base if h["dtb_addr"] else 0)
        for k, v in h.items():
            v = f"0x{v:08x}" if isinstance(v, int) and (k.endswith("addr") or k.endswith("offset") or k == "base") else v
            s = str(v)
            if not all(c.isalnum() or c in ".-_:/x" for c in s):
                s = "'" + s.replace("'", "") + "'"
            print(f"BI_{k.upper()}={s}")
    elif a[0] == "extract":
        off, size = offsets(h)[a[2]]
        if not size:
            sys.exit(f"{a[1]} has no {a[2]}")
        with open(a[1], "rb") as f, open(a[3], "wb") as o:
            f.seek(off)
            o.write(f.read(size))
    elif a[0] == "find":
        off, size = offsets(h)["kernel"]
        with open(a[1], "rb") as f:
            f.seek(off)
            sys.exit(0 if a[2].encode() in f.read(size) else 1)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
