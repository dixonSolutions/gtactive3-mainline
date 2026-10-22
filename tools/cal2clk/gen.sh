#!/bin/sh
# Regenerate the Exynos9810 clock driver tables from Samsung's CMUCAL data.
# usage: gen.sh CAL_DIR LINUX_TREE
set -e
D=$(cd "$(dirname "$0")" && pwd)
CAL=$1
L=$2
T=$(mktemp -d)
python3 -I "$D/../cal2clk.py" "$CAL" "$T/clk.c" "$T/hdr.h" "$T/dts.txt"
{
	cat "$D/head.c"
	cat "$T/clk.c"
	echo
	cat "$D/chub.c"
	cat "$D/tail.c"
} > "$L/drivers/clk/samsung/clk-exynos9810.c"
{
	cat <<'H'
/* SPDX-License-Identifier: (GPL-2.0-only OR BSD-2-Clause) */
/*
 * Device Tree binding constants for the Exynos9810 clock controllers.
 *
 * Clock names follow Samsung's CMUCAL tables for S5E9810.
 */

#ifndef _DT_BINDINGS_CLOCK_EXYNOS9810_H
#define _DT_BINDINGS_CLOCK_EXYNOS9810_H

H
	cat "$D/chub.h"
	cat "$T/hdr.h"
	echo
	echo "#endif /* _DT_BINDINGS_CLOCK_EXYNOS9810_H */"
} > "$L/include/dt-bindings/clock/samsung,exynos9810.h"
cp "$T/dts.txt" "$T/dts.txt.yaml" "${3:-/dev/null}" 2>/dev/null || true
cat "$T/dts.txt"
cat "$T/dts.txt.yaml"
rm -rf "$T"
