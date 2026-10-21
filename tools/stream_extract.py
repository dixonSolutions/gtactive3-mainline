"""Stream a (possibly truncated) Samsung firmware zip and pull wanted files out of the
tar.md5 archives inside, without writing the whole multi-GB AP to disk."""
import io, struct, sys, tarfile, zlib, os
src, outdir = sys.argv[1], sys.argv[2]
want = set(sys.argv[3:])
os.makedirs(outdir, exist_ok=True)

class Inflate(io.RawIOBase):
    def __init__(self, f):
        self.f, self.d, self.buf, self.eof = f, zlib.decompressobj(-15), b'', False
    def readable(self): return True
    def readinto(self, b):
        while not self.buf and not self.eof:
            c = self.f.read(1 << 20)
            if not c: raise EOFError('truncated input')
            self.buf = self.d.decompress(c)
            if self.d.eof: self.eof = True
        n = min(len(b), len(self.buf)); b[:n] = self.buf[:n]; self.buf = self.buf[n:]
        return n

f = open(src, 'rb')
pos = 0
while True:
    f.seek(pos); h = f.read(30)
    if len(h) < 30 or h[:4] != b'PK\x03\x04': break
    _, _, flags, meth, _, _, _, csz, _, nl, el = struct.unpack('<IHHHHHIIIHH', h)
    name = f.read(nl).decode(); f.read(el)
    print('entry', name, flush=True)
    inf = Inflate(f)
    try:
        with tarfile.open(fileobj=io.BufferedReader(inf, 1 << 20), mode='r|') as t:
            for m in t:
                hit = m.name in want
                print(f'  {m.name} {m.size >> 20} MB{"  <- extract" if hit else ""}', flush=True)
                if hit:
                    with open(os.path.join(outdir, m.name), 'wb') as o:
                        o.write(t.extractfile(m).read())
        while not inf.eof:
            if not inf.read(1 << 20): break
    except EOFError:
        print('  (download ends here)'); break
    # rewind to just after compressed data, skip data descriptor
    consumed = f.tell() - len(inf.d.unused_data)
    f.seek(consumed); dd = f.read(4)
    pos = consumed + (16 if dd == b'PK\x07\x08' else 12)
    if flags & 8 and dd == b'PK\x07\x08':
        f.seek(consumed); blk = f.read(64); nxt = blk.find(b'PK\x03\x04')
        pos = consumed + nxt if nxt >= 0 else pos
