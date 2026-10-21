#!/usr/bin/env python3
"""Decode the bring-up timing side channel from logs/devd.log.

Each cycle: 'flash done' -> tablet boots -> init reboots into Download mode after
30 + 10*code s -> devd logs 'Download mode'. gap = overhead + 30 + 10*code.
code = st_max + 3*st_gadget  (st_max: 0 no i2c dev, 1 NACK, 2 ACK; st_gadget 0/1)
"""
import re, sys
from datetime import datetime

OVERHEAD = 25.0  # flash done -> init running, measured on builds 4-7
NAMES = {0: "no /dev/i2c-0", 1: "MAX77705 NACK", 2: "MAX77705 ACK"}
log = open(sys.argv[1] if len(sys.argv) > 1 else "logs/devd.log").read().splitlines()
ts = lambda l: datetime.strptime(l[1:20], "%Y-%m-%d %H:%M:%S")
done = None
for l in log:
    if "flash done" in l:
        done = ts(l)
    elif "Download mode" in l and done:
        gap = (ts(l) - done).total_seconds()
        code = round((gap - OVERHEAD - 30) / 10)
        desc = ""
        if 0 <= code <= 5:
            desc = f"{NAMES[code % 3]}, gadget {'bound' if code // 3 else 'NOT bound'}"
        print(f"{done:%H:%M:%S}  gap {gap:5.0f}s  code {code:2d}  {desc}")
        done = None
