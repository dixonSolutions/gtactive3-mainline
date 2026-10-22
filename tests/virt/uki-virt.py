#!/usr/bin/env python3
"""Make a Duranium UKI bootable in QEMU's virt machine.

    uki-virt.py IN.efi OUT.efi [--linux IMAGE]

The SM-T570 UKIs carry the tablet's DTB as an unconditional .dtb section,
which systemd-stub installs over the firmware's devicetree: Linux would then
look for Exynos hardware on QEMU's board. This renames .dtb (".dtb-off"), so
the stub leaves edk2's devicetree (QEMU's virt board) in place. With
--linux it also replaces the kernel (for images whose kernel predates the
virt.config fragment, see build-kernel.sh).

Everything else stays byte-identical: the stub, .cmdline, .initrd, .osrel,
the multi-profile layout. The sections after a resized one are moved up;
the stub's own sections come first in every ukify-built UKI and never move.
No PE checksum or signature is kept (QEMU boots without Secure Boot).
"""
import argparse
import struct
import sys

# sections ukify appends to the stub; only these may move
UKI_SECTIONS = {
    b".osrel", b".cmdline", b".dtb", b".dtbauto", b".hwids", b".efifw",
    b".uname", b".splash", b".linux", b".initrd", b".ucode", b".pcrsig",
    b".pcrpkey", b".profile", b".sbat",
}
DTB_OFF = b".dtb-off"


def align(v, a):
    return (v + a - 1) // a * a


def parse(pe):
    """PE32+ header fields and sections (name, header offset, VA, data)."""
    peoff = struct.unpack_from("<I", pe, 0x3C)[0]
    if pe[peoff:peoff + 4] != b"PE\0\0":
        raise ValueError("not a PE image")
    coff = peoff + 4
    nsec, = struct.unpack_from("<H", pe, coff + 2)
    optsz, = struct.unpack_from("<H", pe, coff + 16)
    opt = coff + 20
    if struct.unpack_from("<H", pe, opt)[0] != 0x20B:
        raise ValueError("not PE32+")
    salign, falign = struct.unpack_from("<II", pe, opt + 32)
    secs = []
    for i in range(nsec):
        off = opt + optsz + 40 * i
        vsize, va, rsize, rptr = struct.unpack_from("<IIII", pe, off + 8)
        secs.append({"off": off, "name": bytes(pe[off:off + 8]).rstrip(b"\0"),
                     "vsize": vsize, "va": va, "rptr": rptr,
                     "data": bytes(pe[rptr:rptr + rsize])})
    return {"opt": opt, "salign": salign, "falign": falign, "sections": secs}


def sections(pe):
    return parse(pe)["sections"]


def virtualize(pe, linux=None):
    """Return the patched image and a list of what was changed."""
    pe = bytearray(pe)
    h = parse(pe)
    opt, secs = h["opt"], h["sections"]
    notes = []
    dtbs = [s for s in secs if s["name"] == b".dtb"]
    for s in dtbs:
        pe[s["off"]:s["off"] + 8] = DTB_OFF
        s["name"] = DTB_OFF
    if dtbs:
        notes.append(f"renamed {len(dtbs)} .dtb section(s) to {DTB_OFF.decode()}")
    elif any(s["name"] == b".dtbauto" for s in secs):
        notes.append(".dtbauto only: applied only on a matching board, left alone")

    first = len(secs)
    if linux is not None:
        lin = [i for i, s in enumerate(secs) if s["name"] == b".linux"]
        if len(lin) != 1:
            raise ValueError(f"expected one .linux section, found {len(lin)}")
        secs[lin[0]]["data"] = linux
        secs[lin[0]]["vsize"] = len(linux)
        first = lin[0]
        notes.append(f".linux replaced ({len(linux)} bytes)")
    for s in secs[first:]:
        if s["name"] not in UKI_SECTIONS and s["name"] != DTB_OFF:
            raise ValueError(f"section {s['name']!r} after .linux, refusing to move it")

    # the certificate table (data directory 4) would point past moved data
    struct.pack_into("<II", pe, opt + 112 + 4 * 8, 0, 0)
    struct.pack_into("<I", pe, opt + 64, 0)  # CheckSum
    if first == len(secs):
        return bytes(pe), notes

    # lay out from the first changed section on; earlier ones keep their place
    out = bytearray(pe[:secs[first]["rptr"]])
    prev = secs[first - 1]
    end_va = prev["va"] + prev["vsize"]
    for s in secs[first:]:
        s["va"] = align(end_va, h["salign"])
        rptr = align(len(out), h["falign"])
        out += b"\0" * (rptr - len(out))
        rsize = align(len(s["data"]), h["falign"])
        out += s["data"] + b"\0" * (rsize - len(s["data"]))
        struct.pack_into("<IIII", out, s["off"] + 8, s["vsize"], s["va"], rsize, rptr)
        end_va = s["va"] + s["vsize"]
    struct.pack_into("<I", out, opt + 56, align(end_va, h["salign"]))  # SizeOfImage
    return bytes(out), notes


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--linux", help="kernel Image to put into .linux")
    a = ap.parse_args()
    linux = open(a.linux, "rb").read() if a.linux else None
    try:
        out, notes = virtualize(open(a.src, "rb").read(), linux)
    except ValueError as e:
        sys.exit(f"{a.src}: {e}")
    open(a.dst, "wb").write(out)
    for n in notes:
        print(n)


if __name__ == "__main__":
    main()
