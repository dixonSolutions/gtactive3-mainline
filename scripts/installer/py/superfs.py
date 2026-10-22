#!/usr/bin/env python3
"""Pull one logical partition (e.g. "vendor") out of an Android dynamic
"super" partition, reading it as a single forward stream: Samsung's
super.img (Android sparse format, after lz4 -d) or the raw partition read
from the tablet. Replaces simg2img + lpunpack without a 7 GB temporary file.

usage:
  superfs.py extract NAME OUT < super     writes NAME's bytes to OUT
  superfs.py end NAME < super-head        prints the byte offset where NAME
                                          ends in super (read the first MiB)

Formats: system/core/libsparse/sparse_format.h (sparse) and
system/core/fs_mgr/liblp/include/liblp/metadata_format.h (LP metadata,
slot 0 of the primary copy).
"""
import struct
import sys

SPARSE_MAGIC = 0xED26FF3A
LP_GEOMETRY_MAGIC = 0x616C4467
LP_HEADER_MAGIC = 0x414C5030
LP_RESERVED = 4096
LP_GEOMETRY_SIZE = 4096
SECTOR = 512


class Stream:
    """Yields (offset, bytes) runs of the logical (unsparsed) image."""

    def __init__(self, f):
        self.f = f
        head = self.read_exact(28, allow_short=True)
        self.sparse = len(head) == 28 and struct.unpack_from("<I", head)[0] == SPARSE_MAGIC
        self.head = head

    def read_exact(self, n, allow_short=False):
        b = b""
        while len(b) < n:
            d = self.f.read(n - len(b))
            if not d:
                if allow_short:
                    return b
                raise EOFError("stream ended early")
            b += d
        return b

    def runs(self):
        if not self.sparse:
            off = 0
            if self.head:
                yield 0, self.head
                off = len(self.head)
            while True:
                d = self.f.read(1 << 20)
                if not d:
                    return
                yield off, d
                off += len(d)
        _, major, _, fhdr, chdr, blk, _, chunks, _ = struct.unpack("<IHHHHIIII", self.head)
        if major != 1:
            raise ValueError("unsupported sparse version")
        self.read_exact(fhdr - 28)
        off = 0
        for _ in range(chunks):
            ctype, _, csz, total = struct.unpack("<HHII", self.read_exact(chdr))
            data = total - chdr
            n = csz * blk
            if ctype == 0xCAC1:  # raw
                left = n
                while left:
                    d = self.read_exact(min(left, 1 << 20))
                    yield off + n - left, d
                    left -= len(d)
            elif ctype == 0xCAC2:  # fill
                pat = self.read_exact(4)
                if pat != b"\0\0\0\0":
                    left = n
                    while left:
                        c = min(left, 1 << 20)
                        yield off + n - left, pat * (c // 4)
                        left -= c
            elif ctype in (0xCAC3, 0xCAC4):  # don't care, crc32
                self.read_exact(data)
            else:
                raise ValueError(f"bad sparse chunk type {ctype:#x}")
            off += n


def parse_metadata(buf):
    g = buf[LP_RESERVED:LP_RESERVED + LP_GEOMETRY_SIZE]
    if struct.unpack_from("<I", g)[0] != LP_GEOMETRY_MAGIC:
        raise ValueError("no LP geometry: not a super partition")
    max_size, slots, _ = struct.unpack_from("<III", g, 40)
    m = LP_RESERVED + 2 * LP_GEOMETRY_SIZE  # primary metadata, slot 0
    if struct.unpack_from("<I", buf, m)[0] != LP_HEADER_MAGIC:
        raise ValueError("no LP metadata header")
    hsize = struct.unpack_from("<I", buf, m + 8)[0]
    tables = m + hsize
    # descriptors: partitions, extents, groups, block devices (offset, num, size)
    po, pn, ps = struct.unpack_from("<III", buf, m + 80)
    eo, en, es = struct.unpack_from("<III", buf, m + 92)
    exts = [struct.unpack_from("<QIQI", buf, tables + eo + i * es) for i in range(en)]
    parts = {}
    for i in range(pn):
        e = tables + po + i * ps
        name = buf[e:e + 36].split(b"\0")[0].decode()
        _, first, num, _ = struct.unpack_from("<IIII", buf, e + 36)
        runs, lo = [], 0
        for sectors, ttype, tdata, _ in exts[first:first + num]:
            if ttype == 0:  # linear
                runs.append((lo, tdata * SECTOR, sectors * SECTOR))
            lo += sectors * SECTOR
        parts[name] = (runs, lo)
    return parts


def find(parts, name):
    for n in (name, name + "_a"):
        if n in parts:
            return parts[n]
    raise SystemExit(f"no logical partition {name!r} (have: {', '.join(sorted(parts))})")


def main():
    a = sys.argv[1:]
    if len(a) < 2:
        sys.exit(__doc__)
    st = Stream(sys.stdin.buffer)
    it = st.runs()
    # the metadata sits in the first MiB; holes (don't-care chunks) read as zeros
    head_len = 1 << 20
    head = bytearray(head_len)
    pending = []
    for off, d in it:
        pending.append((off, d))
        if off < head_len:
            n = min(len(d), head_len - off)
            head[off:off + n] = d[:n]
        if off + len(d) >= head_len:
            break
    runs, size = find(parse_metadata(bytes(head)), a[1])
    if a[0] == "end":
        print(max(p + n for _, p, n in runs) if runs else 0)
        return
    if a[0] != "extract":
        sys.exit(__doc__)
    end = max(p + n for _, p, n in runs) if runs else 0

    def chain():
        yield from pending
        yield from it

    with open(a[2], "wb") as o:
        o.truncate(size)
        for off, d in chain():
            if off >= end:
                break
            for lo, po, n in runs:
                s, e = max(off, po), min(off + len(d), po + n)
                if s < e:
                    o.seek(lo + s - po)
                    o.write(d[s - off:e - off])
    print(f"{a[1]}: {size} bytes")


if __name__ == "__main__":
    main()
