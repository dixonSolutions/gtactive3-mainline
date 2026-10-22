#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""
Generate mainline Samsung CCF tables for Exynos9810 from Samsung's downstream
CMUCAL tables (drivers/soc/samsung/cal-if/exynos9810/cmucal-{sfr,node}.c).

Everything is emitted read-only: PLLs without rate tables (recalc only),
muxes with CLK_MUX_READ_ONLY and dividers with CLK_DIVIDER_READ_ONLY. Gates
are real gates but marked CLK_IGNORE_UNUSED while the board is in bring-up.

usage: cal2clk.py CAL_DIR OUT_C OUT_DT_HEADER OUT_DTSI_SNIPPET
"""
import re
import sys
from collections import OrderedDict

CAL = sys.argv[1]

# (CAL block, mainline cmu suffix, physical base)
BLOCKS = [
    ("CMU", "top"),
    ("APM", "apm"),
    ("CMGP", "cmgp"),
    ("PERIC0", "peric0"),
    ("PERIC1", "peric1"),
    ("PERIS", "peris"),
    ("FSYS0", "fsys0"),
    ("DPU", "dpu"),
    ("G3D", "g3d"),
]
SEL = {b for b, _ in BLOCKS}

sfr_src = open(f"{CAL}/cmucal-sfr.c").read()
node_src = open(f"{CAL}/cmucal-node.c").read()

blocks = {}
for m in re.finditer(r"SFR_BLOCK\((\w+),\s*(0x[0-9a-fA-F]+),\s*(0x[0-9a-fA-F]+)\)", sfr_src):
    blocks[m.group(1)] = int(m.group(2), 16)

sfrs = {}
for m in re.finditer(r"\bSFR\((\w+),\s*(0x[0-9a-fA-F]+),\s*(\w+)\)", sfr_src):
    sfrs[m.group(1)] = (int(m.group(2), 16), m.group(3))

acc = {}
for m in re.finditer(r"SFR_ACCESS\((\w+),\s*(\d+),\s*(\d+),\s*(\w+)\)", sfr_src):
    acc[m.group(1)] = (int(m.group(2)), int(m.group(3)), m.group(4))

parents = {}
for m in re.finditer(r"enum clk_id (\w+)\[\] = \{([^}]*)\};", node_src):
    parents[m.group(1)] = [p.strip() for p in m.group(2).split(",") if p.strip()]

clks = OrderedDict()   # id -> dict


def add(cid, **kw):
    assert cid not in clks, cid
    kw["id"] = cid
    clks[cid] = kw


for m in re.finditer(r"CLK_PLL\((\w+),\s*(\w+),\s*(\w+),\s*(\w+),\s*(\w+),\s*(\w+),"
                     r"\s*(\w+),\s*(\w+),\s*(\w+),\s*(\w+),", node_src):
    typ, cid, pid, lock, en = m.group(1, 2, 3, 4, 5)
    k = m.group(10)
    con = acc[en][2]
    add(cid, kind="pll", type=typ, parent=pid, lock=acc[lock][2], con=con,
        block=sfrs[con][1], has_k=(k != "EMPTY_CAL_ID"))

for m in re.finditer(r"CLK_MUX\((\w+),\s*(\w+),\s*(\w+),\s*(\w+),\s*(\w+)\)", node_src):
    cid, pl, sel = m.group(1, 2, 3)
    if pl == "NULL":
        continue        # CLKOUT muxes
    shift, width, reg = acc[sel]
    add(cid, kind="mux", parents=parents[pl], reg=reg, shift=shift,
        width=width, block=sfrs[reg][1])

for m in re.finditer(r"CLK_DIV\((\w+),\s*(\w+),\s*(\w+),\s*(\w+),\s*(\w+)\)", node_src):
    cid, pid, ratio = m.group(1, 2, 3)
    shift, width, reg = acc[ratio]
    add(cid, kind="div", parent=pid, reg=reg, shift=shift, width=width,
        block=sfrs[reg][1])

for m in re.finditer(r"CLK_GATE\((\w+),\s*(\w+),\s*(\w+),\s*(\w+),\s*(\w+)\)", node_src):
    cid, pid, cg = m.group(1, 2, 3)
    shift, width, reg = acc[cg]
    add(cid, kind="gate", parent=pid, reg=reg, shift=shift,
        block=sfrs[reg][1])

for m in re.finditer(r"FIXEDRATE\((\w+),\s*(\d+),\s*(\w+)\)", node_src):
    add(m.group(1), kind="fixed", rate=int(m.group(2)), block=None)

for m in re.finditer(r"FIXEDFACTOR\((\w+),\s*(\w+),\s*(\d+),\s*(\w+)\)", node_src):
    cid, pid, ratio, eo = m.group(1, 2, 3, 4)
    add(cid, kind="ff", parent=pid, div=int(ratio) + 1,
        block=sfrs[acc[eo][2]][1])


# ---- naming ---------------------------------------------------------------
PREFIX = {"pll": "fout", "mux": "mout", "div": "dout", "gate": "gout",
          "ff": "dout", "fixed": ""}


def base_name(c):
    cid, kind = c["id"], c["kind"]
    if kind == "fixed":
        if cid.startswith("OSCCLK_") and not cid.startswith("OSCCLK_RCO") \
                and c["rate"] == 26000000:
            return "oscclk"
        return cid.lower()
    if kind == "pll":
        return "fout_" + cid[4:].lower() + "_pll"
    s = cid
    for p in ("MUX_", "DIV_", "GATE_", "GOUT_"):
        if s.startswith(p):
            s = s[len(p):]
            break
    mm = re.match(r"(?:CLK_)?BLK_([A-Za-z0-9]+)_UID_(.*)$", s)
    if mm:
        s = mm.group(1) + "_" + re.sub(r"_IPCLKPORT", "", mm.group(2),
                                       flags=re.I)
    elif s.startswith("CLKCMU_"):
        s = "CMU_" + s[len("CLKCMU_"):]
    elif s.startswith("CLK_"):
        s = s[4:]
    return PREFIX[kind] + "_" + s.lower()


CANON = {"mux": "MUX_", "div": "DIV_", "gate": "GATE_", "pll": "PLL_"}


def canonical(c):
    p = CANON.get(c["kind"])
    return p is None or c["id"].startswith(p) or c["id"].startswith("GOUT_")


names = {}
seen = {}
# ids with their canonical type prefix get first pick of the short name
for c in sorted(clks.values(), key=lambda c: not canonical(c)):
    n = base_name(c)
    if n != "oscclk" and n in seen:
        n += "_out"
    assert n == "oscclk" or n not in seen, n
    seen[n] = c["id"]
    names[c["id"]] = n


def pname(cid):
    return names[cid]


# assign fixed-rate placeholders to the block that uses them
for c in clks.values():
    if c["block"] not in SEL:
        continue
    ps = c.get("parents") or ([c["parent"]] if "parent" in c else [])
    for p in ps:
        pc = clks.get(p)
        if pc and pc["kind"] == "fixed" and names[p] != "oscclk" \
                and pc["block"] is None:
            pc["block"] = c["block"]

# ---- emit ----------------------------------------------------------------
PLLTYPE = {"PLL_1016X": "pll_1017x", "PLL_1017X": "pll_1017x",
           "PLL_1018X": "pll_1017x", "PLL_1019X": "pll_1017x",
           "PLL_1050X": "pll_1017x", "PLL_1031X": "pll_1031x"}

out = []
hdr = []
dts = []
binding = {}


def w(s=""):
    out.append(s)


def wrap_call(head, args, indent="\t"):
    """Format NAME(arg, arg, ...), wrapped at 80 columns, tab = 8."""
    lines = []
    cur = indent + head + "("
    first = True
    cont = (indent + " " * (len(head) + 1)).replace(" " * 8, "\t")
    for i, a in enumerate(args):
        tok = a + ("," if i < len(args) - 1 else "),")
        add_s = ("" if first else " ") + tok
        if len(cur.expandtabs(8)) + len(add_s) > 80 and not first:
            lines.append(cur)
            cur = cont + tok
        else:
            cur += add_s
        first = False
    lines.append(cur)
    return "\n".join(lines)


def field(name, val):
    f = "\t." + name
    pad = "\t" * max(1, (32 - len(f.expandtabs(8)) + 7) // 8)
    return f"{f}{pad}= {val},"


for blk, cmu in BLOCKS:
    members = [c for c in clks.values() if c["block"] == blk]
    # topological-ish: keep CAL order but put kinds together
    regs = OrderedDict()
    for c in members:
        for key in ("con", "lock", "reg"):
            if key in c:
                regs[c[key]] = sfrs[c[key]][0]
    base = blocks[blk]
    upper = cmu.upper()

    w(f"/* ---- CMU_{upper} {'-' * (66 - len(upper))} */")
    w()
    w(f"/* Register Offset definitions for CMU_{upper} (0x{base:08x}) */")
    for r, off in sorted(regs.items(), key=lambda x: x[1]):
        d = "#define " + r
        pad = "\t" * max(1, (56 - len(d) + 7) // 8)
        if len((d + pad).expandtabs(8)) + 6 > 100:
            pad = " "
        w(f"{d}{pad}0x{off:04x}")
    w()

    ids = []
    for kind in ("fixed", "pll", "mux", "div", "ff", "gate"):
        for c in members:
            if c["kind"] == kind:
                ids.append(c)
    hdr.append(f"/* CMU_{upper} */")
    for i, c in enumerate(ids, 1):
        macro = "CLK_" + names[c["id"]].upper()
        c["macro"] = macro
        pad = "\t" * max(1, (48 - len("#define " + macro) + 7) // 8)
        hdr.append(f"#define {macro}{pad}{i}")
    hdr.append("")
    nr = f"CLKS_NR_{upper}"
    w(f"#define {nr}\t({ids[-1]['macro']} + 1)" if ids else "")
    w()

    ext = OrderedDict()

    def need(p):
        pc = clks.get(p)
        if pc is None:
            raise SystemExit(f"unknown parent {p}")
        if pc["block"] != blk:
            if names[p] != "oscclk" or True:
                ext[names[p]] = pc["block"]
        return pname(p)

    fixed = [c for c in ids if c["kind"] == "fixed"]
    if fixed:
        w(f"static const struct samsung_fixed_rate_clock {cmu}_fixed_clks[] __initconst = {{")
        w("\t/* Placeholders for pads and PHY outputs, rates from CMUCAL */")
        for c in fixed:
            w(wrap_call("FRATE", [c["macro"], f'"{names[c["id"]]}"', "NULL", "0",
                                  str(c["rate"])]))
        w("};")
        w()

    plls = [c for c in ids if c["kind"] == "pll"]
    if plls:
        w(f"static const struct samsung_pll_clock {cmu}_pll_clks[] __initconst = {{")
        w("\t/* No rate tables: the PLLs are owned by the bootloader / ACPM */")
        for c in plls:
            w(wrap_call("PLL", [PLLTYPE[c["type"]], c["macro"],
                                f'"{names[c["id"]]}"', f'"{need(c["parent"])}"',
                                c["lock"], c["con"], "NULL"]))
        w("};")
        w()

    muxes = [c for c in ids if c["kind"] == "mux"]
    if muxes:
        for c in muxes:
            plist = ", ".join(f'"{need(p)}"' for p in c["parents"])
            line = f"PNAME({names[c['id']]}_p) = {{ {plist} }};"
            if len(line.expandtabs(8)) > 80:
                w(f"PNAME({names[c['id']]}_p) = {{")
                for p in c["parents"]:
                    w(f'\t"{need(p)}",')
                w("};")
                w()
            else:
                w(line)
        w()
        w(f"static const struct samsung_mux_clock {cmu}_mux_clks[] __initconst = {{")
        for c in muxes:
            w(wrap_call("MUX_F", [c["macro"], f'"{names[c["id"]]}"',
                                  f"{names[c['id']]}_p", c["reg"],
                                  str(c["shift"]), str(c["width"]), "0",
                                  "CLK_MUX_READ_ONLY"]))
        w("};")
        w()

    divs = [c for c in ids if c["kind"] == "div"]
    if divs:
        w(f"static const struct samsung_div_clock {cmu}_div_clks[] __initconst = {{")
        for c in divs:
            w(wrap_call("DIV_F", [c["macro"], f'"{names[c["id"]]}"',
                                  f'"{need(c["parent"])}"', c["reg"],
                                  str(c["shift"]), str(c["width"]), "0",
                                  "CLK_DIVIDER_READ_ONLY"]))
        w("};")
        w()

    ffs = [c for c in ids if c["kind"] == "ff"]
    if ffs:
        w(f"static const struct samsung_fixed_factor_clock {cmu}_fixed_factor_clks[] __initconst = {{")
        for c in ffs:
            w(wrap_call("FFACTOR", [c["macro"], f'"{names[c["id"]]}"',
                                    f'"{need(c["parent"])}"', "1",
                                    str(c["div"]), "0"]))
        w("};")
        w()

    gates = [c for c in ids if c["kind"] == "gate"]
    if gates:
        w(f"static const struct samsung_gate_clock {cmu}_gate_clks[] __initconst = {{")
        for c in gates:
            w(wrap_call("GATE", [c["macro"], f'"{names[c["id"]]}"',
                                 f'"{need(c["parent"])}"', c["reg"],
                                 str(c["shift"]), "CLK_IGNORE_UNUSED", "0"]))
        w("};")
        w()

    w(f"static const struct samsung_cmu_info {cmu}_cmu_info __initconst = {{")
    for kind, arr in (("pll", "pll_clks"), ("mux", "mux_clks"),
                      ("div", "div_clks"), ("gate", "gate_clks"),
                      ("fixed", "fixed_clks"),
                      ("ff", "fixed_factor_clks")):
        if any(c["kind"] == kind for c in ids):
            w(field(arr, f"{cmu}_{arr}"))
            w(field("nr_" + arr, f"ARRAY_SIZE({cmu}_{arr})"))
    w(field("nr_clk_ids", nr))
    w("};")
    w()
    binding[cmu] = (base, list(ext.items()))

# text fixes for alignment of cmu_info (tabs)
src = re.sub(r"\n{3,}", "\n\n", "\n".join(out))
open(sys.argv[2], "w").write(src)
open(sys.argv[3], "w").write("\n".join(hdr))



def short(n, cmu):
    s = re.sub(r"^[dmg]out_cmu_", "", n)
    s = re.sub(r"^%s_" % cmu, "", s)
    s = re.sub(r"_%s$" % cmu, "", s)
    return re.sub(r"_out$", "", s)


# DT nodes (for the SoC dtsi) and the per-compatible clock lists (binding)
yaml = []
for cmu, (base, ext) in binding.items():
    inputs = [("oscclk", "oscclk")] + sorted(
        [(n, short(n, cmu)) for n, b in ext if n != "oscclk"],
        key=lambda x: (x[1] != "bus", x[1] != "ip", x[1]))
    dts.append(f"\t\tcmu_{cmu}: clock-controller@{base:x} {{")
    dts.append(f'\t\t\tcompatible = "samsung,exynos9810-cmu-{cmu}";')
    dts.append(f"\t\t\treg = <0x{base:08x} 0x8000>;")
    dts.append("\t\t\t#clock-cells = <1>;")
    cl = []
    for n, sn in inputs:
        if n == "oscclk":
            cl.append("<&oscclk>")
        else:
            src = [c for c in clks.values() if names[c["id"]] == n][0]
            scmu = [m for b, m in BLOCKS if b == src["block"]][0]
            cl.append(f"<&cmu_{scmu} CLK_{n.upper()}>")
    dts.append("\t\t\tclocks = " + ",\n\t\t\t\t ".join(cl) + ";")
    line = "\t\t\tclock-names = "
    cont = "\t\t\t\t      "
    for i, (n, sn) in enumerate(inputs):
        tok = f'"{sn}"' + (";" if i == len(inputs) - 1 else ",")
        if len((line + " " + tok).expandtabs(8)) > 80:
            dts.append(line)
            line = cont + tok
        else:
            line += ("" if line.endswith("= ") else " ") + tok
    dts.append(line)
    dts.append("\t\t};")
    dts.append("")
    yaml.append((cmu, inputs))
open(sys.argv[4], "w").write("\n".join(dts) + "\n")
with open(sys.argv[4] + ".yaml", "w") as f:
    for cmu, inputs in yaml:
        f.write(f"{cmu}: " + " ".join(f"{sn}={n}" for n, sn in inputs) + "\n")
