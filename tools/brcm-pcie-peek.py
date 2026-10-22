#!/usr/bin/env python3
"""Read-only look at a Broadcom FullMAC PCIe dongle (BCM4375 on the SM-T570).

Maps the TCM BAR (resource2) read-only and does only 32-bit loads, so it
can run next to brcmfmac on a live system:

  brcm-pcie-peek.py               shared area: flags (rev, TRAP, ...),
                                  host_cap, mailbox words
  brcm-pcie-peek.py --console     also print the firmware console buffer
  brcm-pcie-peek.py --follow SEC  stream new firmware console output

Run it with python3 -I as root. The layout is the pciedev_shared_t of
Broadcom's DHD (bcmpcie.h); the RAM base is the BCM4375's.
"""
import ctypes
import os
import sys
import time

DEV = "/sys/bus/pci/devices/0000:01:00.0/resource2"
RAMBASE = 0x170000

SHARED = [
    (0, "flags"), (4, "trap_addr"), (8, "assert_exp_addr"),
    (12, "assert_file_addr"), (16, "assert_line"), (20, "console_addr"),
    (28, "fwid"), (40, "h2d_mb_data_ptr"), (44, "d2h_mb_data_ptr"),
    (48, "rings_info_ptr"), (80, "flags2"), (84, "host_cap"),
    (96, "device_fatal_logbuf_start"),
]
FLAGS = [
    (0x400, "TRAP"), (0x200, "ASSERT"), (0x10000, "DMA_INDEX"),
    (0x2000000, "USE_MAILBOX"), (0x10000000, "HOSTRDY"),
    (0x20000000, "NO_OOB_DW"), (0x40000000, "INBAND_DS"),
]


def main():
    libc = ctypes.CDLL(None, use_errno=True)
    libc.mmap.restype = ctypes.c_void_p
    libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int,
                          ctypes.c_int, ctypes.c_int, ctypes.c_long]
    fd = os.open(DEV, os.O_RDONLY | os.O_SYNC)
    size = os.fstat(fd).st_size
    base = libc.mmap(None, size, 1, 1, fd, 0)  # PROT_READ, MAP_SHARED
    if base is None or base == ctypes.c_void_p(-1).value:
        sys.exit("mmap failed: errno %d" % ctypes.get_errno())

    def r32(off):
        return ctypes.c_uint32.from_address(base + off).value

    # The last word of RAM points to the shared area; pick the largest
    # RAM size for which it points into RAM.
    sh = None
    for ramsize in range(0x80000, size - RAMBASE + 1, 0x10000):
        v = r32(RAMBASE + ramsize - 4)
        if RAMBASE <= v < RAMBASE + ramsize:
            sh, end = v, RAMBASE + ramsize
    if sh is None:
        sys.exit("no shared area found (firmware not running?)")

    for off, name in SHARED:
        print("%-26s 0x%08x" % (name, r32(sh + off)))
    flags = r32(sh)
    print("rev %d, flags: %s" % (flags & 0xff, " ".join(
        n for b, n in FLAGS if flags & b) or "-"))
    for off, name in ((40, "h2d_mb_data"), (44, "d2h_mb_data")):
        p = r32(sh + off)
        if RAMBASE <= p < end:
            print("%-26s 0x%08x" % (name, r32(p)))

    con = r32(sh + 20)
    if not RAMBASE <= con < end:
        return
    buf, bsz = r32(con + 8), r32(con + 12)
    if not (RAMBASE <= buf < end and 0 < bsz <= 0x10000):
        return

    def text(data):
        return data.replace(b"\0", b"").replace(b"\r", b"").decode("latin-1")

    if "--console" in sys.argv:
        data = b"".join(r32(buf + o).to_bytes(4, "little")
                        for o in range(0, bsz, 4))
        w = r32(con + 16)
        sys.stdout.write(text(data[w:] + data[:w]))
    if "--follow" in sys.argv:
        stop = time.time() + float(sys.argv[sys.argv.index("--follow") + 1])
        rd = r32(con + 16)
        while time.time() < stop:
            w = r32(con + 16)
            out = bytearray()
            while rd != w:
                out.append((r32(buf + (rd & ~3)) >> (8 * (rd & 3))) & 0xff)
                rd = (rd + 1) % bsz
            if out:
                sys.stdout.write(text(bytes(out)))
                sys.stdout.flush()
            time.sleep(0.05)


if __name__ == "__main__":
    main()
