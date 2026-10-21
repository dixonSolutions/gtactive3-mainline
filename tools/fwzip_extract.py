#!/usr/bin/env python3
"""Stream a Samsung firmware zip (decrypted .enc4) and pull members out of the
*.tar.md5 archives inside it, without writing the multi-GB tars to disk.

Works on zips without a central directory (truncated download) and with
data-descriptor/zip64 local headers, which `unzip` refuses.

usage: python3 -I fwzip_extract.py FW.zip OUTDIR [GLOB ...]
  no GLOB: list only.  GLOBs match tar member names, e.g. 'super.img.lz4' '*.img.lz4'
  Stops after the tar entry in which every GLOB has matched at least once.
"""
import fnmatch
import io
import os
import shutil
import struct
import sys
import tarfile
import zlib

src, outdir, globs = sys.argv[1], sys.argv[2], sys.argv[3:]
os.makedirs(outdir, exist_ok=True)
seen = set()


class Inflate(io.RawIOBase):
    def __init__(self, f, method):
        self.f, self.buf, self.eof = f, b"", False
        self.d = zlib.decompressobj(-15) if method == 8 else None

    def readable(self):
        return True

    def readinto(self, b):
        while not self.buf and not self.eof:
            c = self.f.read(1 << 20)
            if not c:
                raise EOFError("truncated input")
            self.buf = self.d.decompress(c)
            if self.d.eof:
                self.eof = True
        n = min(len(b), len(self.buf))
        b[:n] = self.buf[:n]
        self.buf = self.buf[n:]
        return n


f = open(src, "rb")
pos = 0
while True:
    f.seek(pos)
    h = f.read(30)
    if len(h) < 30 or h[:4] != b"PK\x03\x04":
        break
    _, _, flags, meth, _, _, _, csz, _, nl, el = struct.unpack("<IHHHHHIIIHH", h)
    name = f.read(nl).decode()
    f.read(el)
    print("entry", name, flush=True)
    if meth != 8:
        sys.exit(f"unsupported compression method {meth}")
    inf = Inflate(f, meth)
    try:
        with tarfile.open(fileobj=io.BufferedReader(inf, 1 << 20), mode="r|") as t:
            for m in t:
                hit = m.isfile() and any(fnmatch.fnmatch(m.name, g) for g in globs)
                print(f"  {m.name} {m.size} bytes{'  <- extract' if hit else ''}", flush=True)
                if hit:
                    seen.update(g for g in globs if fnmatch.fnmatch(m.name, g))
                    dst = os.path.join(outdir, os.path.basename(m.name))
                    with open(dst + ".part", "wb") as o:
                        shutil.copyfileobj(t.extractfile(m), o, 1 << 22)
                    os.replace(dst + ".part", dst)
        if globs and seen >= set(globs):
            print("all requested members extracted", flush=True)
            break
        while not inf.eof:
            if not inf.read(1 << 20):
                break
    except EOFError:
        print("  (input ends here: truncated)", flush=True)
        break
    consumed = f.tell() - len(inf.d.unused_data)
    f.seek(consumed)
    blk = f.read(64)
    nxt = blk.find(b"PK\x03\x04")
    if nxt < 0:
        break
    pos = consumed + nxt
