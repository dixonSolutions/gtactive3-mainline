#!/usr/bin/env python3
"""Parse a Broadcom LHE patch file (<Key=Value> header + <Blob=hex>) into
its record stream: [cmd u8][len u16 LE][body]. Prints a summary."""
import re, struct, sys, collections

NAMES = {0xf0: 'masked-write', 0xf1: 'write', 0xf2: 'crc8', 0xf3: 'csum32',
         0xf4: 'service', 0xf5: 'masked-verify'}

def load(path):
    t = open(path).read()
    hdr = dict(re.findall(r'<(\w+)=([^>]*)>', t.split('<Blob=')[0]))
    blob = bytes.fromhex(re.sub(r'\s', '', t.split('<Blob=')[1].rstrip().rstrip('>')))
    return hdr, blob

def records(blob):
    o = 0
    while o < len(blob):
        cmd = blob[o]; ln = struct.unpack_from('<H', blob, o + 1)[0]
        yield o, cmd, blob[o + 3:o + 3 + ln]
        o += 3 + ln

if __name__ == '__main__':
    hdr, blob = load(sys.argv[1])
    print(hdr, 'blob', len(blob))
    cnt = collections.Counter(); wr = 0; lo = hi = None
    for o, cmd, body in records(blob):
        cnt[NAMES.get(cmd, hex(cmd))] += 1
        if cmd == 0xf1:
            a = struct.unpack_from('<I', body)[0]; wr += len(body) - 4
            lo = a if lo is None else min(lo, a); hi = max(hi or 0, a + len(body) - 4)
        elif cmd != 0xf1 or '-v' in sys.argv:
            print(f'{o:#8x} {NAMES.get(cmd, hex(cmd)):14} ' +
                  ' '.join(f'{x:#010x}' for x in struct.unpack_from('<%dI' % (len(body) // 4), body))
                  + (f' +{body[-1]:#04x}' if len(body) % 4 else ''))
    print(cnt, f'write bytes {wr} range {lo:#x}-{hi:#x}')
