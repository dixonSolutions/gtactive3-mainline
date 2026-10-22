#!/usr/bin/env python3
"""A fake SM-T570 for the installer tests: adb, heimdall and lsusb in one
script (dispatch on argv[0]), sharing a state file with fakeconsole.py.

$MOCK_STATE (JSON):
  mode        android | download | bringup | duranium | off | android-broken
  adb_auth    device | unauthorized | offline
  props, settings, kg_dump, serial, card, vendor_readable, flash_fail
  root        the fake tablet's file tree (dev/sdaNN files, sys/..., android/...)
  events      [{"after": TICK, "set": {...}}]: the user's physical actions,
              applied when the tick counter (one per mock call) reaches TICK
  log         every flash / reboot, for the assertions
  violation   set when the installer asked for something it must never do
"""
import fcntl
import json
import os
import shutil
import sys

STATE = os.environ["MOCK_STATE"]
PROTECTED = {"BOOTLOADER", "EFS", "SEC_EFS", "PARAM", "UP_PARAM", "PERSISTENT", "VBMETA",
             "VBMETA_SAMSUNG", "CPEFS", "BOOTLOADER2", "UL_KEYS", "KEYSTORAGE", "STEADY", "UH",
             "UHCFG", "BLCMD", "RADIO", "MISC", "DTBO"}


class State:
    def __enter__(self):
        self.f = open(STATE + ".lock", "w")
        fcntl.flock(self.f, fcntl.LOCK_EX)
        with open(STATE) as f:
            self.s = json.load(f)
        s = self.s
        s["tick"] = s.get("tick", 0) + 1
        keep = []
        for e in s.get("events", []):
            if e["after"] <= s["tick"]:
                for k, v in e["set"].items():
                    if k == "props":
                        s["props"].update(v)
                    else:
                        s[k] = v
            else:
                keep.append(e)
        s["events"] = keep
        return s

    def __exit__(self, *a):
        with open(STATE + ".tmp", "w") as f:
            json.dump(self.s, f, indent=1)
        os.replace(STATE + ".tmp", STATE)
        fcntl.flock(self.f, fcntl.LOCK_UN)


def root(s, p):
    return os.path.join(s["root"], p.lstrip("/"))


def boot_kind(path):
    with open(path, "rb") as f:
        d = f.read(4 << 20)
    for marker, kind in ((b"FAKE-UNILOADER-LINUX", "linux"), (b"FAKE-UNILOADER-CHAIN", "chain"),
                         (b"FAKE-STOCK-BOOT", "stock")):
        if marker in d:
            return kind
    return "unknown"


def userdata_kind(s):
    with open(root(s, "dev/sda31"), "rb") as f:
        d = f.read(8192)
    if d.startswith(b"ANDROID-DATA"):
        return "android"
    if d[1024:1028] == b"\x10\x20\xf5\xf2":
        return "android-new"
    if d[4096:4104] == b"EFI PART":
        return "duranium"
    return "empty"


def after_boot(s, kind):
    if kind == "linux":
        return "bringup"
    if kind == "chain":
        return "duranium" if userdata_kind(s) == "duranium" and s.get("image_flavour") == "dev" else \
            ("off" if userdata_kind(s) == "duranium" else "bringup")
    if kind == "stock":
        return "android" if userdata_kind(s) in ("android", "android-new") else "android-broken"
    return "off"


# ---------------- adb ----------------

def adb(s, a):
    while a and a[0] in ("-s",):
        a = a[2:]
    if a[:1] == ["devices"]:
        print("List of devices attached")
        if s["mode"] == "android":
            for extra in s.get("extra_devices", []):
                print(f"{extra}\tdevice")
            print(f"{s['serial']}\t{s.get('adb_auth', 'device')}")
        print()
        return 0
    if s["mode"] != "android" or s.get("adb_auth", "device") != "device":
        sys.stderr.write("error: no devices/emulators found\n")
        return 1
    if a[:1] == ["get-serialno"]:
        print(s["serial"])
        return 0
    if a[:1] == ["reboot"]:
        s["log"].append("adb reboot " + " ".join(a[1:]))
        if a[1:2] == ["download"]:
            s["mode"] = "download"
        return 0
    if a[:1] == ["pull"]:
        args = [x for x in a[1:] if x != "-a"]
        src, dst = args[0], args[1]
        if src.startswith("/vendor") and not s.get("vendor_readable"):
            sys.stderr.write(f"adb: error: failed to stat remote object '{src}': Permission denied\n")
            return 1
        lp = root(s, "android" + src)
        if not os.path.exists(lp):
            sys.stderr.write(f"adb: error: failed to stat remote object '{src}': No such file or directory\n")
            return 1
        if os.path.isdir(lp):
            shutil.copytree(lp, os.path.join(dst, os.path.basename(src)), dirs_exist_ok=True)
        else:
            shutil.copy(lp, dst)
        print(f"{src}: 1 file pulled.")
        return 0
    if a[:1] == ["shell"]:
        cmd = " ".join(a[1:])
        w = a[1:]
        if w[:1] == ["getprop"]:
            print(s["props"].get(w[1], ""))
        elif w[:3] == ["settings", "get", "global"]:
            print(s.get("settings", {}).get(w[3], "null"))
        elif w[:2] == ["dumpsys", "knoxguard_service"]:
            print(s.get("kg_dump", ""))
        elif w[:3] == ["df", "-k", "/data"]:
            print("Filesystem 1K-blocks Used Available Use% Mounted on")
            print("/dev/block/dm-6 53000000 2097152 50000000 4% /data")
        elif w[:2] == ["du", "-sk"]:
            p = root(s, "android" + w[2])
            if not os.path.isdir(p):
                return 1
            n = sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(p) for f in fs)
            print(f"{max(1, n // 1024)}\t{w[2]}")
        elif cmd.startswith("[ -d "):
            return 0 if os.path.isdir(root(s, "android" + cmd[5:].rstrip(" ]"))) else 1
        elif w[:2] == ["ls", "/storage"]:
            print("emulated")
            print("self")
            if s.get("card"):
                print(s["card"])
        elif w[:4] == ["pm", "list", "packages", "-3"]:
            print("package:com.example.notes")
        elif w[:2] == ["pm", "path"]:
            print(f"package:/data/app/{w[2]}/base.apk")
        elif w[:2] == ["mkdir", "-p"]:
            os.makedirs(root(s, "android" + w[2]), exist_ok=True)
        elif w[:2] == ["cp", "-r"]:
            shutil.copytree(root(s, "android" + w[2]),
                            os.path.join(root(s, "android" + w[3]), os.path.basename(w[2])),
                            dirs_exist_ok=True)
        else:
            sys.stderr.write(f"mock adb: unknown shell command {cmd!r}\n")
            return 1
        return 0
    sys.stderr.write(f"mock adb: unknown command {a!r}\n")
    return 1


# ---------------- heimdall ----------------

def heimdall(s, a):
    if a[:1] == ["detect"]:
        return 0 if s["mode"] == "download" else 1
    if s["mode"] != "download":
        sys.stderr.write("ERROR: Failed to detect compatible download-mode device.\n")
        return 1
    if a[:1] == ["print-pit"]:
        with open(os.path.join(os.path.dirname(os.path.realpath(__file__)), "pit.txt")) as f:
            sys.stdout.write(f.read())
        return 0
    if a[:1] == ["flash"]:
        reboot = "--no-reboot" not in a
        parts = []
        i = 1
        while i < len(a):
            if a[i].startswith("--") and a[i] != "--no-reboot":
                parts.append((a[i][2:], a[i + 1]))
                i += 2
            else:
                i += 1
        for p, f in parts:
            if p.upper() in PROTECTED or p.upper() not in ("BOOT", "RECOVERY"):
                s["violation"] = f"heimdall flash --{p}"
                sys.stderr.write("mock: PROTECTED PARTITION\n")
                return 1
        if s.get("flash_fail"):
            print("Uploading BOOT\n0%\nERROR: Failed to send file part packet!")
            s["log"].append("flash failed")
            return 1
        kind = None
        for p, f in parts:
            dev = {"BOOT": "dev/sda12", "RECOVERY": "dev/sda13"}[p.upper()]
            shutil.copy(f, root(s, dev))
            k = boot_kind(f)
            s["log"].append(f"flash {p.upper()} {k}")
            if p.upper() == "BOOT":
                kind = k
                s["boot"] = k
        print("BOOT upload successful")
        if reboot:
            s["mode"] = after_boot(s, kind or s.get("boot", "stock"))
            s["log"].append(f"boot {s['mode']}")
        return 0
    sys.stderr.write(f"mock heimdall: unknown {a!r}\n")
    return 1


def lsusb(s, a):
    if s["mode"] == "download":
        print("Bus 003 Device 042: ID 04e8:685d Samsung Electronics Co., Ltd GT-I9100 Phone [Galaxy S II] (Download mode)")
    elif s["mode"] == "android":
        print("Bus 003 Device 043: ID 04e8:6860 Samsung Electronics Co., Ltd Galaxy A5 (MTP)")
    elif s["mode"] in ("bringup", "duranium"):
        print("Bus 003 Device 044: ID 1d6b:0104 Linux Foundation Multifunction Composite Gadget")
    return 0


def main():
    tool = os.path.basename(sys.argv[0])
    with State() as s:
        s.setdefault("log", [])
        fn = {"adb": adb, "heimdall": heimdall, "lsusb": lsusb}[tool]
        rc = fn(s, sys.argv[1:])
    sys.exit(rc)


if __name__ == "__main__":
    main()
