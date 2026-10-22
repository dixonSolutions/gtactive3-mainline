#!/usr/bin/env python3
"""Samsung firmware tars (AP_*.tar.md5): check and read members.

A .tar.md5 is a plain tar with "<md5>  <name>\\n" appended (what Odin
checks).

usage:
  aptar.py check TAR           verify the appended md5 (if there is one)
  aptar.py list TAR            member names and sizes
  aptar.py cat TAR MEMBER      stream one member to stdout
"""
import hashlib
import os
import re
import sys
import tarfile


def md5_tail(path):
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        f.seek(max(0, size - 512))
        tail = f.read()
    m = re.search(rb"([0-9a-f]{32})  ([^\n/]+)\n?$", tail)
    if not m:
        return None, size
    return m.group(1).decode(), size - (len(tail) - m.start())


def main():
    a = sys.argv[1:]
    if len(a) < 2:
        sys.exit(__doc__)
    op, path = a[0], a[1]
    if op == "check":
        want, n = md5_tail(path)
        if not want:
            print("no md5 trailer")
            return
        h = hashlib.md5()
        with open(path, "rb") as f:
            left = n
            while left:
                d = f.read(min(left, 1 << 22))
                if not d:
                    sys.exit("short file")
                h.update(d)
                left -= len(d)
        if h.hexdigest() != want:
            sys.exit(f"MD5 MISMATCH: {path} is damaged or incomplete (download it again)")
        print("md5 ok")
        return
    with tarfile.open(path, "r|") as t:
        for m in t:
            if op == "list":
                print(m.name, m.size)
            elif op == "cat" and m.name == a[2]:
                f = t.extractfile(m)
                out = sys.stdout.buffer
                while True:
                    d = f.read(1 << 20)
                    if not d:
                        break
                    out.write(d)
                out.flush()
                return
    if op == "cat":
        sys.exit(f"{a[2]} is not in {path}")


if __name__ == "__main__":
    main()
