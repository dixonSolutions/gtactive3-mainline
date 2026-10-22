#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""
Predict what clk-exynos9810.c will report, using register values read one by
one from the tablet (only registers the driver itself reads, never holes:
reading an undefined CMU offset raises an SError on Exynos9810).

usage: rates.py CLK_C CLOCK_NAME...      (needs scripts/tab and the console)
       rates.py CLK_C --offline DUMP CLOCK_NAME...  (DUMP: "addr 0xval" lines)
"""
import re
import subprocess
import sys

P = "/home/borysthebear/Projects/gtactive3-mainline"
src = open(sys.argv[1]).read()
args = sys.argv[2:]
cache = {}
if args and args[0] == "--offline":
    for line in open(args[1]):
        m = re.match(r"([0-9a-fx]+)\s+(0x[0-9a-f]+)", line.strip())
        if m:
            cache[int(m.group(1), 16)] = int(m.group(2), 16)
    args = args[2:]
    online = False
else:
    online = True

bases = {}
regs = {}
clk = {}
cur = None
for line in src.split("\n"):
    m = re.match(r"/\* Register Offset definitions for CMU_(\w+) \((0x[0-9a-f]+)\)", line)
    if m:
        cur = m.group(1).lower()
        bases[cur] = int(m.group(2), 16)
        continue
    m = re.match(r"#define (\w+)\s+(0x[0-9a-f]+)$", line)
    if m and cur:
        regs[(cur, m.group(1))] = int(m.group(2), 16)

# join continuation lines of the table entries
body = re.sub(r"(?<!\)),\n\s+", ", ", src)
pn = {m.group(1): re.findall(r'"(\w+)"', m.group(2))
      for m in re.finditer(r"PNAME\((\w+)\) = \{([^}]*)\}", body)}
cur = None
for line in body.split("\n"):
    m = re.match(r"static const struct samsung_\w+ (\w+?)_\w+\[\]", line)
    if m:
        cur = m.group(1)
    m = re.match(r'\s+(PLL|MUX_F|DIV_F|GATE|FFACTOR|FRATE)\((.*)\),$', line)
    if not m:
        continue
    kind, a = m.group(1), [x.strip() for x in m.group(2).split(",")]
    if kind == "PLL":
        clk[a[2].strip('"')] = ("pll", cur, a[0], a[3].strip('"'), a[5])
    elif kind == "MUX_F":
        clk[a[1].strip('"')] = ("mux", cur, pn[a[2]], a[3], int(a[4]), int(a[5]))
    elif kind == "DIV_F":
        clk[a[1].strip('"')] = ("div", cur, a[2].strip('"'), a[3], int(a[4]), int(a[5]))
    elif kind == "GATE":
        clk[a[1].strip('"')] = ("gate", cur, a[2].strip('"'), a[3], int(a[4]))
    elif kind == "FFACTOR":
        clk[a[1].strip('"')] = ("ff", cur, a[2].strip('"'), int(a[3]), int(a[4]))
    elif kind == "FRATE":
        clk[a[1].strip('"')] = ("fixed", cur, int(a[4]))
clk["oscclk"] = ("fixed", None, 26000000)


def rd(cmu, reg):
    addr = bases[cmu] + regs[(cmu, reg)]
    if addr not in cache:
        if not online:
            raise KeyError(f"0x{addr:08x} ({reg}) not in dump")
        out = subprocess.run(["flock", f"{P}/build/tab.lock", f"{P}/scripts/tab",
                              f"peek 0x{addr:08x}"], capture_output=True,
                             text=True, timeout=60).stdout.strip()
        cache[addr] = int(out.split()[-1], 16)
        print(f"{addr:08x} 0x{cache[addr]:08x}  {reg}", file=sys.stderr)
    return cache[addr]


def rate(n, depth=0):
    c = clk[n]
    k = c[0]
    if k == "fixed":
        return c[2], n
    if k == "pll":
        v = rd(c[1], c[4])
        m, p, s = (v >> 16) & 0x3ff, (v >> 8) & 0x3f, v & 7
        fin, _ = rate(c[3])
        r = fin * m // (p << s) if p else 0
        if c[2] == "pll_1031x":
            regs[(c[1], "CON3")] = regs[(c[1], c[4])] + 0xc
            k_ = rd(c[1], "CON3") & 0xffff
            r = (fin * ((m << 16) + k_) // (p << s)) >> 16
        return r, f"{n}[en={v >> 31} lock={(v >> 29) & 1} m={m} p={p} s={s}]"
    if k == "mux":
        v = rd(c[1], c[3])
        sel = (v >> c[4]) & ((1 << c[5]) - 1)
        if sel >= len(c[2]):
            return 0, f"{n}[sel={sel}?]"
        r, _ = rate(c[2][sel], depth + 1)
        return r, f"{n}[sel={sel}:{c[2][sel]}]"
    if k == "div":
        v = rd(c[1], c[3])
        d = ((v >> c[4]) & ((1 << c[5]) - 1)) + 1
        r, _ = rate(c[2], depth + 1)
        return r // d, f"{n}[/{d}]"
    if k == "gate":
        v = rd(c[1], c[3])
        r, _ = rate(c[2], depth + 1)
        return r, f"{n}[cg={(v >> 21) & 1} manual={(v >> 20) & 1} hwacg={(v >> 28) & 1}]"
    if k == "ff":
        r, _ = rate(c[2], depth + 1)
        return r * c[3] // c[4], n
    raise SystemExit(k)


def chain(n):
    out = []
    while True:
        r, desc = rate(n)
        out.append(f"{desc} = {r / 1e6:.4f} MHz")
        c = clk[n]
        if c[0] in ("fixed",):
            break
        if c[0] == "pll":
            n = c[3]
        elif c[0] == "mux":
            v = rd(c[1], c[3])
            sel = (v >> c[4]) & ((1 << c[5]) - 1)
            n = c[2][sel]
        else:
            n = c[2]
    return out


for n in args:
    print(n)
    for line in chain(n):
        print("    " + line)
