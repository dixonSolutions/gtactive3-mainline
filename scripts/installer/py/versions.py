#!/usr/bin/env python3
"""systemd's version comparison (strverscmp_improved, UAPI.10), so the
installer orders image versions exactly like systemd-sysupdate and
systemd-boot do, also on hosts without systemd-analyze.

usage:
  versions.py cmp A B     prints <, = or >
  versions.py max         newest of the versions on stdin (one per line)
"""
import sys

VALID = set("~-^.")


def valid(c):
    return c.isascii() and (c.isalnum() or c in VALID)


def _cmp(x, y):
    return (x > y) - (x < y)


def vercmp(a, b):
    if not a or not b:
        return _cmp(a, b)
    i = j = 0
    while True:
        while i < len(a) and not valid(a[i]):
            i += 1
        while j < len(b) and not valid(b[j]):
            j += 1
        ca = a[i] if i < len(a) else ""
        cb = b[j] if j < len(b) else ""
        if ca == "~" or cb == "~":  # pre-release: older
            r = _cmp(ca != "~", cb != "~")
            if r:
                return r
            i, j = i + 1, j + 1
            ca = a[i] if i < len(a) else ""
            cb = b[j] if j < len(b) else ""
        if not ca or not cb:
            return _cmp(a[i:], b[j:])
        for sep in "-^.":
            if ca == sep or cb == sep:
                r = _cmp(ca != sep, cb != sep)
                if r:
                    return r
                i, j = i + 1, j + 1
                ca = a[i] if i < len(a) else ""
                cb = b[j] if j < len(b) else ""
        if ca.isdigit() or cb.isdigit():
            r = _cmp(ca.isdigit(), cb.isdigit())
            if r:
                return r
            while i < len(a) and a[i] == "0":
                i += 1
            while j < len(b) and b[j] == "0":
                j += 1
            ii, jj = i, j
            while ii < len(a) and a[ii].isdigit():
                ii += 1
            while jj < len(b) and b[jj].isdigit():
                jj += 1
            r = _cmp(i != ii, j != jj) or _cmp(ii - i, jj - j) or _cmp(a[i:ii], b[j:jj])
            if r:
                return r
        else:
            r = _cmp(ca.isalpha(), cb.isalpha())
            if r:
                return r
            ii, jj = i, j
            while ii < len(a) and a[ii].isalpha():
                ii += 1
            while jj < len(b) and b[jj].isalpha():
                jj += 1
            n = min(ii - i, jj - j)
            r = _cmp(a[i:i + n], b[j:j + n]) or _cmp(ii - i, jj - j)
            if r:
                return r
        i, j = ii, jj


def main():
    a = sys.argv[1:]
    if a[:1] == ["cmp"] and len(a) == 3:
        print("<=>"[vercmp(a[1], a[2]) + 1])
    elif a == ["max"]:
        best = None
        for ln in sys.stdin:
            v = ln.strip()
            if v and (best is None or vercmp(v, best) > 0):
                best = v
        if best is None:
            sys.exit(1)
        print(best)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
