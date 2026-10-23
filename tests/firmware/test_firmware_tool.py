#!/usr/bin/env python3
"""Tests for scripts/firmware-tool, on synthetic files (tests/firmware/fixtures.py).

    python3 -I tests/firmware/test_firmware_tool.py
"""
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "scripts" / "firmware-tool"
sys.path.insert(0, str(Path(__file__).resolve().parent))
import fixtures  # noqa: E402


def tool(*args, stdin=None):
    return subprocess.run([sys.executable, "-I", str(TOOL), *args], input=stdin, capture_output=True, text=True)


class Redact(unittest.TestCase):
    def test_props_and_text(self):
        text = ("[ro.serialno]: [R52TESTSERIAL1]\n[ro.product.model]: [SM-T999]\n"
                "[ro.boot.wifimacaddr]: [aa:bb:cc:dd:ee:ff]\n[ril.serialnumber]: [R52TESTSERIAL1]\n"
                "[ro.build.fingerprint]: [samsung/x/y:13/T999XXU1AXA1:user/release-keys]\n"
                "console=ram androidboot.serialno=R52TESTSERIAL1 androidboot.em.did=0011223344 x=1\n"
                "bt addr 11:22:33:44:55:66 imei 356789012345678 seen R52TESTSERIAL1\n")
        r = tool("redact", "--scrub", "R52TESTSERIAL1", stdin=text)
        self.assertEqual(r.returncode, 0, r.stderr)
        out = r.stdout
        for secret in ("R52TESTSERIAL1", "aa:bb:cc", "11:22:33", "356789012345678", "0011223344"):
            self.assertNotIn(secret, out)
        self.assertIn("[ro.product.model]: [SM-T999]", out)
        self.assertIn("T999XXU1AXA1:user/release-keys", out)
        self.assertIn("x=1", out)


class DeviceTrees(unittest.TestCase):
    def test_dt_table_and_boot_image(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / "dtbo.img").write_bytes(fixtures.dtbo())
            (d / "boot.img").write_bytes(fixtures.bootimg())
            r = tool("dtb", str(d / "dtbo.img"), str(d / "boot.img"), "-o", str(d / "dt"))
            self.assertEqual(r.returncode, 0, r.stderr)
            lines = r.stdout.splitlines()
            self.assertEqual(len(lines), 3, r.stdout)
            self.assertIn("test,board-rev0", lines[0])
            self.assertIn("test,board-rev1", lines[1])
            self.assertIn("Test board\t", lines[2] + "\t")
            self.assertTrue((d / "dt" / "dtbo-01.dtb").is_file())

    def test_ikconfig(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / "kernel").write_bytes(fixtures.bootimg())
            r = tool("ikconfig", str(d / "kernel"), str(d / "config"))
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn("CONFIG_TEST_TWO=m", (d / "config").read_text())
            (d / "plain").write_bytes(b"no config here")
            self.assertNotEqual(tool("ikconfig", str(d / "plain"), str(d / "c2")).returncode, 0)


class Targets(unittest.TestCase):
    def test_classify(self):
        elf64 = b"\x7fELF\x02\x01\x01" + b"\0" * 11 + b"\xb7\x00" + b"\0" * 40
        with tempfile.TemporaryDirectory() as d:
            v = Path(d) / "vendor"
            for rel, data in (("lib64/hw/audio.primary.exynos9999.so", elf64),
                              ("lib64/hw/camera.exynos9999.so", elf64),
                              ("lib/libfoo.so", elf64),                     # not a HAL, no subsystem: skipped
                              ("bin/hw/gpsd", elf64),
                              ("bin/hw/start.sh", b"#!/bin/sh\n"),         # not ELF: skipped
                              ("firmware/dsp_fw.bin", b"\x00\x01\x02\x03" * 64),
                              ("firmware/tuning.txt", b"text only\n")):     # text: skipped
                p = v / rel
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_bytes(data)
            r = tool("targets", str(v))
            self.assertEqual(r.returncode, 0, r.stderr)
            names = [l.lstrip("# ").split("|")[0] for l in r.stdout.splitlines()]
            self.assertIn("audio64-audio.primary.exynos9999", names)
            self.assertIn("camera64-camera.exynos9999", names)
            self.assertIn("gnss-gpsd", names)
            self.assertIn("npu-dsp-dsp_fw.bin", names)
            self.assertEqual(len(names), 4, r.stdout)
            raw = [l for l in r.stdout.splitlines() if "dsp_fw.bin" in l][0]
            self.assertTrue(raw.startswith("# ") and "raw-binary" in raw)
            r = tool("targets", str(v), "--match", "camera")
            self.assertEqual(len(r.stdout.splitlines()), 1, r.stdout)


class Summary(unittest.TestCase):
    def test_snapshot_summary(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / "system").mkdir()
            (d / "props.txt").write_text("[ro.product.model]: [SM-T999]\n[ro.build.PDA]: [T999XXU1AXA1]\n")
            (d / "system" / "version.txt").write_text("Linux version 4.14.113-test\n")
            (d / "system" / "by-name.txt").write_text("lrwxrwxrwx 1 root root 15 boot -> /dev/block/sda5\n")
            fw = d / "tree" / "vendor" / "firmware"
            fw.mkdir(parents=True)
            (fw / "a.bin").write_bytes(b"\0" * 10)
            r = tool("summary", str(d))
            self.assertEqual(r.returncode, 0, r.stderr)
            s = (d / "SUMMARY.md").read_text()
            self.assertIn("| Model | SM-T999 |", s)
            self.assertIn("`boot`", s)
            self.assertIn("vendor/firmware/a.bin", s)


if __name__ == "__main__":
    os.chdir(ROOT)
    unittest.main()
