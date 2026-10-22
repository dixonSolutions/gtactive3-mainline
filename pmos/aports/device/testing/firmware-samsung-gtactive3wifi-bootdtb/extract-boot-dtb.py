#!/usr/bin/env python3
# Copy the DTB section out of an Android boot image (header v2).
# usage: extract-boot-dtb.py boot.img out.img
import struct
import sys

with open(sys.argv[1], "rb") as f:
    img = f.read()
if img[:8] != b"ANDROID!":
    sys.exit(f"{sys.argv[1]}: not an Android boot image")
kernel, ramdisk, second = struct.unpack_from("<I4xI4xI", img, 8)
page, version = struct.unpack_from("<II", img, 36)
if version != 2:
    sys.exit(f"{sys.argv[1]}: boot image header v{version}, expected v2")
recovery_dtbo, = struct.unpack_from("<I", img, 1632)
dtb, = struct.unpack_from("<I", img, 1648)


def pages(n):
    return (n + page - 1) // page


off = page * (1 + pages(kernel) + pages(ramdisk) + pages(second) + pages(recovery_dtbo))
data = img[off:off + dtb]
if len(data) != dtb or not dtb:
    sys.exit(f"{sys.argv[1]}: truncated or missing DTB section")
with open(sys.argv[2], "wb") as f:
    f.write(data)
print(f"{sys.argv[2]}: {dtb} bytes from offset {off}")
