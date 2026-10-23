#!/usr/bin/env python3
"""QEMU aarch64 test harness for the SM-T570 Duranium images (see run.sh).

One VM at a time, headless: edk2 -> the image's systemd-boot -> its UKI
(with the tablet DTB switched off, see uki-virt.py) -> the image's own
initrd, first boot (systemd-repart, LUKS root), UI and update path.

Control channels:
  hvc.sock   root shell on hvc0 (systemd.debug_shell=hvc0, added to the
             kernel command line through SMBIOS io.systemd.stub.kernel-
             cmdline-extra, so the image itself is not changed)
  qmp.sock   QMP: screenshots, keyboard/pointer input, reset, power off
  serial.log PL011 console: edk2, systemd-boot, kernel and systemd log
"""
import argparse
import base64
import functools
import http.server
import importlib.util
import json
import os
import re
import select
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
HOSTTOOLS = ROOT / "build/virt/host"
SECTOR = 4096
GUEST_HOST = "10.0.2.2"          # QEMU user networking: the host's 127.0.0.1

_spec = importlib.util.spec_from_file_location("uki_virt", HERE / "uki-virt.py")
uki_virt = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(uki_virt)


class Fail(Exception):
    pass


class Skip(Exception):
    """The image cannot be tested here (e.g. its kernel has no virt drivers)."""


LOGFILE = None


def log(msg):
    line = f"[{time.strftime('%H:%M:%S')}] {msg}"
    print(line, flush=True)
    if LOGFILE:
        with open(LOGFILE, "a") as f:
            f.write(line + "\n")


# ---------------------------------------------------------------- host tools

def qemu_env():
    env = dict(os.environ)
    if (HOSTTOOLS / "usr/bin/qemu-system-aarch64").exists():
        lib = str(HOSTTOOLS / "usr/lib64")
        env["LD_LIBRARY_PATH"] = lib + (":" + env["LD_LIBRARY_PATH"] if env.get("LD_LIBRARY_PATH") else "")
        env["QEMU_MODULE_DIR"] = str(HOSTTOOLS / "usr/lib64/qemu")
    env["MTOOLS_SKIP_CHECK"] = "1"
    return env


def qemu_bin():
    if os.environ.get("QEMU"):
        return os.environ["QEMU"]
    local = HOSTTOOLS / "usr/bin/qemu-system-aarch64"
    if local.exists():
        return str(local)
    found = shutil.which("qemu-system-aarch64")
    if not found:
        raise Fail("qemu-system-aarch64 not found: run tests/virt/setup-host.sh")
    return found


def firmware():
    """(code, vars template) of an aarch64 edk2 build."""
    pairs = [
        (os.environ.get("EDK2_CODE"), os.environ.get("EDK2_VARS")),
        (HOSTTOOLS / "usr/share/edk2/aarch64/QEMU_EFI-silent-pflash.raw",
         HOSTTOOLS / "usr/share/edk2/aarch64/vars-template-pflash.raw"),
        ("/usr/share/edk2/aarch64/QEMU_EFI-silent-pflash.raw",
         "/usr/share/edk2/aarch64/vars-template-pflash.raw"),
        ("/usr/share/AAVMF/AAVMF_CODE.fd", "/usr/share/AAVMF/AAVMF_VARS.fd"),
    ]
    for code, var in pairs:
        if code and var and Path(code).exists() and Path(var).exists():
            return Path(code), Path(var)
    raise Fail("no aarch64 edk2 firmware: run tests/virt/setup-host.sh")


def accel():
    """KVM on an aarch64 host that has it (CI arm64 runners may), else TCG
    emulating the tablet's little core (Cortex-A55: same ISA as userspace
    sees on the device). acpi=off: edk2 then hands the devicetree to the OS
    (the kernel has no ACPI support)."""
    if os.uname().machine == "aarch64" and os.access("/dev/kvm", os.R_OK | os.W_OK):
        return ["-machine", "virt,gic-version=host,acpi=off", "-accel", "kvm", "-cpu", "host"]
    return ["-machine", "virt,gic-version=3,acpi=off", "-accel", "tcg,thread=multi", "-cpu", "cortex-a55"]


def run(cmd, **kw):
    kw.setdefault("check", True)
    kw.setdefault("env", qemu_env())
    return subprocess.run([str(c) for c in cmd], **kw)


def mem_available_mb():
    for line in open("/proc/meminfo"):
        if line.startswith("MemAvailable:"):
            return int(line.split()[1]) // 1024
    return 0


# ---------------------------------------------------------------- disk image

def partitions(disk):
    out = run(["sfdisk", "--sector-size", str(SECTOR), "-J", disk],
              capture_output=True, text=True).stdout
    return json.loads(out)["partitiontable"]["partitions"]


def esp_offset(disk):
    for p in partitions(disk):
        if p["type"].upper() == "C12A7328-F81F-11D2-BA4B-00A0C93EC93B":
            return p["start"] * SECTOR
    raise Fail(f"{disk}: no ESP")


def esp_list(disk, path="::/EFI/Linux"):
    img = f"{disk}@@{esp_offset(disk)}"
    out = run(["mdir", "-b", "-i", img, path], capture_output=True, text=True, check=False).stdout
    return [line.strip() for line in out.splitlines() if line.strip().lower().endswith(".efi")]


def uki_has_virt_kernel(uki):
    """True if the UKI's kernel has the virt.config drivers built in."""
    secs = uki_virt.sections(Path(uki).read_bytes())
    linux = [s for s in secs if s["name"] == b".linux"]
    return bool(linux) and b"virtio_blk" in linux[0]["data"] and b"pci-host-ecam-generic" in linux[0]["data"]


def virtualize_uki(src, dst, kernel):
    """Copy a UKI and make it boot on QEMU virt (uki-virt.py)."""
    args = [sys.executable, "-I", HERE / "uki-virt.py", src, dst]
    if kernel in ("auto", "none"):
        if uki_has_virt_kernel(src):
            kernel = None
        elif kernel == "none" or not (ROOT / "src/linux").is_dir():
            raise Skip(f"{Path(src).name}: the kernel has no QEMU virt drivers (virt.config); "
                       "use --kernel auto on a checkout with src/linux, or an Image")
        else:
            kernel = build_kernel()
    if kernel:
        args += ["--linux", kernel]
    run(args, stdout=subprocess.DEVNULL)


@functools.lru_cache(maxsize=None)
def build_kernel():
    log("the image's kernel has no virt drivers: building a virt Image (build-kernel.sh)")
    out = run(["sh", HERE / "build-kernel.sh"], capture_output=True, text=True)
    return out.stdout.strip().splitlines()[-1]


def esp_patch_ukis(disk, kernel, work):
    img = f"{disk}@@{esp_offset(disk)}"
    for path in esp_list(disk):
        name = path.rsplit("/", 1)[-1]
        a, b = work / ("in-" + name), work / ("out-" + name)
        run(["mcopy", "-n", "-i", img, path, a])
        virtualize_uki(a, b, kernel)
        run(["mcopy", "-o", "-i", img, b, path])
        a.unlink()
        b.unlink()
        log(f"ESP: {name} virtualized")


def prepare_disk(src, rundir, size_gb, kernel):
    disk = rundir / "disk.raw"
    src = Path(src)
    if src.name.endswith(".zst"):
        log(f"decompressing {src.name}")
        run(["zstd", "-d", "-q", "-f", "-T0", src, "-o", disk])
    else:
        run(["cp", "--reflink=auto", "--sparse=always", src, disk])
    if disk.stat().st_size > size_gb << 30:
        raise Fail(f"--disk-gb {size_gb} is smaller than the image")
    # room for what the first boot's systemd-repart adds (the second usr
    # slot, its verity partition and the LUKS root)
    os.truncate(disk, size_gb << 30)
    esp_patch_ukis(disk, kernel, rundir)
    return disk


def part_by_label(disk, label):
    for p in partitions(disk):
        if p.get("name") == label:
            return p
    raise Fail(f"{disk}: no partition labelled {label}")


# ---------------------------------------------------------------- QMP / shell

class QMP:
    def __init__(self, path, timeout=30):
        deadline = time.time() + timeout
        while True:
            try:
                self.s = socket.socket(socket.AF_UNIX)
                self.s.connect(str(path))
                break
            except OSError:
                if time.time() > deadline:
                    raise Fail(f"QMP socket {path} not reachable")
                time.sleep(0.5)
        self.f = self.s.makefile("rwb")
        # a monitor serves one client at a time: don't wait forever for its greeting
        self.s.settimeout(timeout)
        try:
            self._read()
        except TimeoutError:
            raise Fail(f"QMP socket {path} busy (another client is connected)")
        self.s.settimeout(None)
        self.cmd("qmp_capabilities")

    def _read(self):
        while True:
            line = self.f.readline()
            if not line:
                raise Fail("QMP connection closed")
            msg = json.loads(line)
            if "event" not in msg:
                return msg

    def cmd(self, name, **args):
        self.f.write(json.dumps({"execute": name, "arguments": args}).encode() + b"\n")
        self.f.flush()
        msg = self._read()
        if "error" in msg:
            raise Fail(f"QMP {name}: {msg['error'].get('desc')}")
        return msg.get("return")

    def close(self):
        self.s.close()


QCODES = {" ": "spc", "\n": "ret", "\t": "tab", "-": "minus", ".": "dot",
          "/": "slash", "=": "equal", ",": "comma", ";": "semicolon"}


def type_text(qmp, text, delay=0.08):
    for ch in text:
        if ch.isalpha() and ch.isupper():
            keys = ["shift", ch.lower()]
        elif ch.isalnum():
            keys = [ch]
        else:
            keys = [QCODES[ch]]
        qmp.cmd("send-key", keys=[{"type": "qcode", "data": k} for k in keys], **{"hold-time": 40})
        time.sleep(delay)


def press(qmp, *keys):
    """press("ret"), press("ctrl", "alt", "f2"), ... (QEMU qcodes)"""
    qmp.cmd("send-key", keys=[{"type": "qcode", "data": k} for k in keys], **{"hold-time": 60})
    time.sleep(0.2)


def tap(qmp, x, y):
    """Tap at x, y (0..1 of the screen) with the virtio tablet."""
    ev = [{"type": "abs", "data": {"axis": "x", "value": int(x * 32767)}},
          {"type": "abs", "data": {"axis": "y", "value": int(y * 32767)}}]
    qmp.cmd("input-send-event", events=ev)
    for down in (True, False):
        qmp.cmd("input-send-event", events=[{"type": "btn", "data": {"down": down, "button": "left"}}])
        time.sleep(0.1)


def swipe(qmp, x0, y0, x1, y1, steps=12):
    def at(x, y):
        qmp.cmd("input-send-event", events=[
            {"type": "abs", "data": {"axis": "x", "value": int(x * 32767)}},
            {"type": "abs", "data": {"axis": "y", "value": int(y * 32767)}}])
    at(x0, y0)
    qmp.cmd("input-send-event", events=[{"type": "btn", "data": {"down": True, "button": "left"}}])
    for i in range(1, steps + 1):
        at(x0 + (x1 - x0) * i / steps, y0 + (y1 - y0) * i / steps)
        time.sleep(0.03)
    qmp.cmd("input-send-event", events=[{"type": "btn", "data": {"down": False, "button": "left"}}])


def ppm_to_png(ppm, png):
    data = Path(ppm).read_bytes()
    m = re.match(rb"P6\s+(\d+)\s+(\d+)\s+(\d+)\s", data)
    w, h = int(m.group(1)), int(m.group(2))
    px = data[m.end():]
    raw = b"".join(b"\0" + px[y * w * 3:(y + 1) * w * 3] for y in range(h))

    def chunk(t, d):
        c = t + d
        return len(d).to_bytes(4, "big") + c + zlib.crc32(c).to_bytes(4, "big")
    ihdr = w.to_bytes(4, "big") + h.to_bytes(4, "big") + bytes([8, 2, 0, 0, 0])
    Path(png).write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) +
                          chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def screenshot(qmp, png):
    png = Path(png)
    try:
        qmp.cmd("screendump", filename=str(png), format="png")
    except Fail:
        ppm = png.with_suffix(".ppm")
        qmp.cmd("screendump", filename=str(ppm))
        ppm_to_png(ppm, png)
        ppm.unlink()
    return png


class Shell:
    """Root shell on the guest's hvc0, one command at a time.

    Markers are split in the command line ("@@B"":") so that the tty's echo
    of a command never matches the marker the command prints."""

    def __init__(self, path):
        self.path = str(path)
        self.s = None
        self.buf = b""
        self.n = 0

    def connect(self):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.connect(self.path)
        self.s.setblocking(False)

    def close(self):
        if self.s:
            self.s.close()
            self.s = None

    def _send(self, data):
        if self.s is None:
            self.connect()
        self.s.sendall(data)

    def _pump(self, timeout):
        r, _, _ = select.select([self.s], [], [], timeout)
        if r:
            d = self.s.recv(65536)
            if not d:
                raise Fail("hvc0 socket closed")
            self.buf += d

    def _expect(self, rx, timeout):
        deadline = time.time() + timeout
        while True:
            m = rx.search(self.buf)
            if m:
                rest = self.buf[m.end():]
                head = self.buf[:m.end()]
                self.buf = rest
                return m, head
            left = deadline - time.time()
            if left <= 0:
                return None, b""
            self._pump(min(left, 1.0))

    def ready(self, timeout=5):
        """True once a shell answers (and is set up: no echo, no prompt)."""
        if self.s is None:
            self.connect()
        self.n += 1
        self.buf = b""
        self._send(b"\r\x03\rstty -echo 2>/dev/null; PS1=; export PS1; "
                   b"echo \"@@R\"\"%d@@\"\r" % self.n)
        m, _ = self._expect(re.compile(rb"@@R%d@@" % self.n), timeout)
        return m is not None

    def wait(self, timeout, poll=10, serial=None, initrd_ok=False):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if serial:
                serial.check()
            try:
                if self.ready(timeout=poll):
                    if initrd_ok:
                        return True
                    rc, _ = self.run("test -e /etc/initrd-release", timeout=30)
                    if rc != 0:
                        return True
                    time.sleep(poll)        # still in the initrd
                    continue
            except (OSError, Fail):
                self.close()
                time.sleep(poll)
        return False

    def run(self, cmd, timeout=120):
        """Run a shell script, return (exit code, output)."""
        self.n += 1
        n = self.n
        # plain output: no colours, pagers or progress bars from systemd tools
        cmd = "export SYSTEMD_COLORS=0 SYSTEMD_PAGER= SYSTEMD_PAGERSECURE=0 TERM=dumb NO_COLOR=1\n" + cmd
        b64 = base64.b64encode(cmd.encode()).decode()
        self.buf = b""
        self._send(b"rm -f /run/vt.b64\r")
        for i in range(0, len(b64), 2000):
            self._send(f"printf %s {b64[i:i + 2000]} >> /run/vt.b64\r".encode())
        self._send(f"base64 -d /run/vt.b64 > /run/vt.sh; printf '@@B''{n}@@\\n'; "
                   f"sh /run/vt.sh </dev/null 2>&1; echo \"@@E$?:\"\"{n}@@\"\r".encode())
        m, head = self._expect(re.compile(rb"@@E(\d+):%d@@" % n), timeout)
        if not m:
            self._send(b"\x03\r")
            raise Fail(f"guest command timed out after {timeout}s: {cmd[:120]}")
        out = head[:m.start()]
        i = out.find(b"@@B%d@@" % n)
        if i >= 0:
            out = out[i + len(b"@@B%d@@" % n):]
        return int(m.group(1)), out.replace(b"\r", b"").decode(errors="replace").strip("\n")

    def out(self, cmd, timeout=120):
        return self.run(cmd, timeout)[1]

    def put(self, data, dest, mode="0644"):
        """Write bytes to a guest file through the shell."""
        b64 = base64.b64encode(data).decode()
        script = [f"rm -f {dest}.b64"]
        script += [f"printf %s {b64[i:i + 1500]} >> {dest}.b64" for i in range(0, len(b64), 1500)]
        script += [f"base64 -d {dest}.b64 > {dest} && rm {dest}.b64 && chmod {mode} {dest}"]
        for i in range(0, len(script), 40):
            rc, out = self.run("\n".join(script[i:i + 40]), timeout=60)
            if rc:
                raise Fail(f"writing {dest}: {out}")


class Serial:
    """Watches serial.log for fatal boot events."""
    FATAL = [
        (re.compile(rb"Kernel panic - not syncing[^\r\n]*"), "kernel panic"),
        (re.compile(rb"You are in emergency mode[^\r\n]*"), "emergency mode"),
        (re.compile(rb"Failed to start [^\r\n]*[Ss]witch [Rr]oot[^\r\n]*"), "switch-root failed"),
        (re.compile(rb"Synchronous Exception at[^\r\n]*"), "firmware exception"),
        (re.compile(rb"Failed to execute [^\r\n]*"), "systemd-boot could not start the UKI"),
    ]

    def __init__(self, path):
        self.path = Path(path)
        self.pos = 0
        self.events = []

    def mark(self):
        self.pos = self.path.stat().st_size if self.path.exists() else 0

    def check(self):
        """Raise Fail on a fatal event logged since mark()."""
        if not self.path.exists():
            return
        with open(self.path, "rb") as f:
            f.seek(self.pos)
            data = f.read()
        for rx, what in self.FATAL:
            m = rx.search(data)
            if m:
                self.events.append(m.group(0).decode(errors="replace"))
                raise Fail(f"{what}: {m.group(0).decode(errors='replace').strip()}")

    def tail(self, n=40):
        if not self.path.exists():
            return ""
        lines = self.path.read_bytes().decode(errors="replace").splitlines()
        return "\n".join(lines[-n:])


# ---------------------------------------------------------------- the VM

MAX_MEM_MB = 3072          # guest RAM cap (16 GB laptop shared by several agents)
MEM_START_MB = 4096        # start a VM only with 4 GiB available
MEM_ABORT_MB = 1536        # power it off below 1.5 GiB
MEM_WAIT_S = int(os.environ.get("VIRT_MEM_WAIT", "1800"))  # seconds to wait for memory

CMDLINE_EXTRA = ("earlycon console=ttyAMA0 systemd.debug_shell=hvc0 rd.systemd.debug_shell=hvc0 "
                 # the getty generator would put a login prompt on hvc0 as well
                 "systemd.mask=serial-getty@hvc0.service "
                 "systemd.journald.forward_to_console=0")


class VM:
    def __init__(self, rundir, mem_mb=2560, smp=4, ssh_port=0):
        self.dir = Path(rundir)
        self.mem = mem_mb
        self.smp = smp
        self.ssh_port = ssh_port
        self.proc = None
        self.qmp = None
        self.shell = Shell(self.dir / "hvc.sock")
        self.serial = Serial(self.dir / "serial.log")

    def cmdline(self):
        code, var = firmware()
        vars_fd = self.dir / "vars.fd"
        if not vars_fd.exists():
            shutil.copyfile(var, vars_fd)
        fwd = ""
        if self.ssh_port:
            p = self.ssh_port
            # the dev images' debug layer: ssh 22, register console 23, shell 2323
            fwd = (f",hostfwd=tcp:127.0.0.1:{p}-:22,hostfwd=tcp:127.0.0.1:{p + 1}-:23"
                   f",hostfwd=tcp:127.0.0.1:{p + 2}-:2323")
        return [
            qemu_bin(), "-name", "duranium-virt", "-nodefaults",
            *accel(),
            "-smp", str(self.smp), "-m", str(self.mem),
            "-drive", f"if=pflash,format=raw,readonly=on,file={code}",
            "-drive", f"if=pflash,format=raw,file={vars_fd}",
            "-drive", f"if=none,id=hd0,format=raw,file={self.dir / 'disk.raw'},cache=writeback,discard=unmap",
            "-device", "virtio-blk-pci,drive=hd0,logical_block_size=4096,physical_block_size=4096,bootindex=0",
            "-device", "virtio-gpu-pci,xres=720,yres=1280",
            "-device", "virtio-keyboard-pci", "-device", "virtio-tablet-pci",
            "-device", "virtio-rng-pci",
            "-netdev", f"user,id=n0{fwd}", "-device", "virtio-net-pci,netdev=n0,romfile=",
            "-device", "virtio-serial-pci",
            "-chardev", f"socket,id=hvc,path={self.dir / 'hvc.sock'},server=on,wait=off",
            "-device", "virtconsole,chardev=hvc",
            "-chardev", f"file,id=ser,path={self.dir / 'serial.log'},append=on",
            "-serial", "chardev:ser",
            "-qmp", f"unix:{self.dir / 'qmp.sock'},server=on,wait=off",
            # a second monitor for "harness.py shot/tap/..." while a check runs
            "-qmp", f"unix:{self.dir / 'qmp-cli.sock'},server=on,wait=off",
            "-display", "none", "-rtc", "base=utc",
            "-smbios", "type=11,value=io.systemd.stub.kernel-cmdline-extra=" + CMDLINE_EXTRA,
        ]

    def start(self):
        """Start QEMU under the laptop rules (docs/COORDINATION.md): one VM
        at a time (build/vm.lock), only with MEM_START_MB available, nice 10,
        and a watchdog that powers the VM off below MEM_ABORT_MB."""
        if self.mem > MAX_MEM_MB:
            raise Fail(f"--mem {self.mem}: at most {MAX_MEM_MB} MiB on this laptop")
        deadline = time.time() + MEM_WAIT_S
        while mem_available_mb() < MEM_START_MB:
            if time.time() > deadline:
                raise Fail(f"MemAvailable stayed below {MEM_START_MB} MiB for {MEM_WAIT_S}s: not starting a VM")
            log(f"waiting for memory: {mem_available_mb()} MiB available, {MEM_START_MB} needed")
            time.sleep(30)
        for s in ("qmp.sock", "qmp-cli.sock", "hvc.sock", "aborted"):
            (self.dir / s).unlink(missing_ok=True)
        (ROOT / "build").mkdir(exist_ok=True)
        cmd = ["flock", str(ROOT / "build/vm.lock"), "nice", "-n", "10"] + self.cmdline()
        (self.dir / "qemu.cmd").write_text(" ".join(map(str, cmd)) + "\n")
        log("starting QEMU (waiting for build/vm.lock: one VM at a time)")
        self.proc = subprocess.Popen([str(c) for c in cmd], env=qemu_env(),
                                     stdout=open(self.dir / "qemu.log", "ab"),
                                     stderr=subprocess.STDOUT, start_new_session=True)
        (self.dir / "qemu.pid").write_text(str(self.proc.pid))
        # the watchdog outlives this process ("start"/"resume" leave the VM running)
        subprocess.Popen([sys.executable, "-I", str(HERE / "harness.py"), "watchdog", str(self.dir)],
                         stdout=open(self.dir / "watchdog.log", "ab"), stderr=subprocess.STDOUT,
                         start_new_session=True)
        self.serial.mark()
        deadline = time.time() + 6 * 3600
        while not (self.dir / "qmp.sock").exists():
            if self.proc.poll() is not None:
                raise Fail(f"QEMU exited: {(self.dir / 'qemu.log').read_text()[-2000:]}")
            if time.time() > deadline:
                raise Fail("QEMU did not start")
            time.sleep(1)
        self.qmp = QMP(self.dir / "qmp.sock")
        log(f"QEMU running (pid {self.proc.pid})")

    def attach(self):
        """Connect from another process: the second monitor, so this works
        while "check" holds the first one (older runs have only qmp.sock)."""
        cli = self.dir / "qmp-cli.sock"
        self.qmp = QMP(cli if cli.exists() else self.dir / "qmp.sock")

    def running(self):
        return self.proc is None or self.proc.poll() is None

    def reset(self):
        self.shell.close()
        self.serial.mark()
        self.qmp.cmd("system_reset")

    def stop(self, timeout=180):
        """Clean power off through the guest, else QMP quit."""
        if self.proc is not None and self.proc.poll() is not None:
            return
        try:
            if self.shell.ready(timeout=5):
                self.shell._send(b"systemctl poweroff\r")
            else:
                self.qmp.cmd("system_powerdown")
        except (Fail, OSError):
            pass
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.proc is not None and self.proc.poll() is not None:
                break
            time.sleep(2)
        else:
            log("guest did not power off: QMP quit")
            try:
                self.qmp.cmd("quit")
            except (Fail, OSError):
                pass
            if self.proc is not None:
                self.proc.wait(30)
        self.shell.close()
        log("QEMU stopped")


# ---------------------------------------------------------------- results

class Results:
    def __init__(self, rundir, meta):
        self.dir = Path(rundir)
        self.data = dict(meta, checks=[], started=time.strftime("%Y-%m-%dT%H:%M:%S%z"))
        self.t0 = time.time()

    def add(self, name, status, detail="", **extra):
        c = dict(name=name, status=status, detail=detail,
                 t=round(time.time() - self.t0), **extra)
        self.data["checks"].append(c)
        log(f"{status.upper():5} {name}: {' '.join(detail.split())[:300]}".rstrip(": "))
        self.save()

    def save(self):
        fails = [c for c in self.data["checks"] if c["status"] == "fail"]
        self.data["result"] = "FAIL" if fails else "SKIP" if self.data.get("skipped") else "PASS"
        self.data["duration_s"] = round(time.time() - self.t0)
        (self.dir / "results.json").write_text(json.dumps(self.data, indent=1) + "\n")


def patterns(name):
    return [re.compile(line.strip()) for line in (HERE / name).read_text().splitlines()
            if line.strip() and not line.startswith("#")]


def classify(lines):
    """Split journal / unit lines into (qemu_only, known_benign, unexpected)."""
    qemu, known = patterns("qemu-only.txt"), patterns("known-benign.txt")
    q, k, u = [], [], []
    for line in lines:
        if any(p.search(line) for p in qemu):
            q.append(line)
        elif any(p.search(line) for p in known):
            k.append(line)
        else:
            u.append(line)
    return q, k, u


# ---------------------------------------------------------------- update mirror

class Mirror:
    """A local update server: one channel directory over HTTP for the guest
    (sysupdate source Path= -> http://10.0.2.2:PORT/), UKIs virtualized, the
    manifest signed with a throwaway key the guest is told to trust."""

    def __init__(self, rundir):
        self.dir = Path(rundir) / "mirror"
        self.gpg = Path(rundir) / "gnupg"
        self.server = None

    def add_version(self, src_dir, prefix, version, kernel):
        """Add one version from a mkosi.output directory (or a download)."""
        self.dir.mkdir(parents=True, exist_ok=True)
        src = Path(src_dir)
        pat = re.compile(re.escape(f"{prefix}_{version}") + r"\.(efi|usr-arm64(-verity)?\.[0-9a-f]+\.raw(\.zst)?|"
                         r"[a-z-]+-(sysext|confext)-arm64\.raw(\.zst)?)$")
        n = 0
        for f in sorted(src.iterdir()):
            if not pat.match(f.name) or f.is_symlink():
                continue
            if f.name.endswith(".efi"):
                virtualize_uki(f, self.dir / f.name, kernel)
            elif f.name.endswith(".zst"):
                run(["cp", "--reflink=auto", f, self.dir / f.name])
            else:
                log(f"mirror: compressing {f.name}")
                run(["zstd", "-q", "-f", "-T4", "-3", f, "-o", self.dir / (f.name + ".zst")])
            n += 1
        if not n:
            raise Fail(f"no update files for {prefix}_{version} in {src}")

    def sign(self):
        self.gpg.mkdir(mode=0o700, exist_ok=True)
        env = dict(os.environ, GNUPGHOME=str(self.gpg))
        g = ["gpg", "--batch", "--quiet"]
        if run(g + ["--list-secret-keys"], env=env, capture_output=True).stdout == b"":
            run(g + ["--passphrase", "", "--quick-gen-key", "duranium-virt-test", "ed25519", "sign", "1d"], env=env)
        sums = []
        for f in sorted(self.dir.iterdir()):
            if f.name.startswith("SHA256SUMS"):
                continue
            h = run(["sha256sum", f.name], cwd=self.dir, capture_output=True, text=True).stdout
            sums.append(h)
        (self.dir / "SHA256SUMS").write_text("".join(sums))
        run(g + ["--yes", "--detach-sign", "--armor", "-o", self.dir / "SHA256SUMS.gpg",
                 self.dir / "SHA256SUMS"], env=env)
        return run(g + ["--export"], env=env, capture_output=True).stdout

    def serve(self):
        self.server = Server(self.dir)
        return self.server.url

    def close(self):
        if self.server:
            self.server.close()


class Server:
    """A directory over HTTP for the guest (http://10.0.2.2:PORT/)."""

    def __init__(self, directory):
        handler = functools.partial(QuietHandler, directory=str(directory))
        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.url = f"http://{GUEST_HOST}:{self.httpd.server_address[1]}/"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    # --interrupt: the first download of a file matching CUT breaks off
    # after CUT_AFTER bytes (a dropped mobile link)
    CUT = None
    CUT_AFTER = 64 << 20
    cut_done = set()

    def copyfile(self, source, outputfile):
        name = self.path.rsplit("/", 1)[-1]
        if not (self.CUT and self.CUT in name and name not in self.cut_done):
            return super().copyfile(source, outputfile)
        self.cut_done.add(name)
        left = self.CUT_AFTER
        while left > 0:
            buf = source.read(min(left, 1 << 20))
            if not buf:
                break
            outputfile.write(buf)
            left -= len(buf)
        outputfile.flush()
        self.log_message("connection cut after %d bytes of %s", self.CUT_AFTER, name)
        self.close_connection = True
        self.connection.shutdown(socket.SHUT_RDWR)

    def log_message(self, fmt, *args):
        with open(Path(self.directory).parent / "mirror.log", "a") as f:
            f.write("%s %s\n" % (time.strftime("%H:%M:%S"), fmt % args))


# ---------------------------------------------------------------- the checks

TEST_USER, TEST_PASSWORD = "tester", "duranium1"
def _config(key):
    """A value from the port's config.toml (scripts/config: derived values filled in)."""
    cfg = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "scripts", "config")
    return subprocess.run([cfg, "get", key], check=True, capture_output=True, text=True).stdout.strip()


UPDATE_BASE = _config("update.base")
PROJECT_KEY = _config("update.fingerprint")   # pmos/sysupdate-public-key.asc


class Checks:
    def __init__(self, a, vm, res):
        self.a, self.vm, self.res = a, vm, res
        self.sh = vm.shell
        self.shots = vm.dir / "shots"
        self.shots.mkdir(exist_ok=True)

    def shot(self, name):
        try:
            p = screenshot(self.vm.qmp, self.shots / f"{name}.png")
            self.res.data.setdefault("screenshots", []).append(str(p.relative_to(self.vm.dir)))
            return p
        except Fail as e:
            log(f"screenshot {name}: {e}")

    def wait_cond(self, script, timeout, poll=5):
        """Poll a guest shell condition until it exits 0."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            rc, out = self.sh.run(script, timeout=60)
            if rc == 0:
                return out
            self.vm.serial.check()
            time.sleep(poll)
        return None

    def boot(self, label, timeout):
        t0 = time.time()
        try:
            ok = self.sh.wait(timeout, serial=self.vm.serial)
        except Fail as e:
            self.shot(f"{label}-failed")
            self.res.add(f"{label}: boot", "fail", str(e), serial_tail=self.vm.serial.tail())
            return False
        if not ok:
            self.shot(f"{label}-failed")
            self.res.add(f"{label}: boot", "fail", f"no shell on hvc0 after {timeout}s",
                         serial_tail=self.vm.serial.tail())
            return False
        info = self.sh.out(". /usr/lib/os-release; echo $IMAGE_VERSION $VARIANT_ID; uname -r")
        self.res.add(f"{label}: boot", "pass", f"shell after {round(time.time() - t0)}s ({info})")
        return info.split()

    def first_boot(self):
        if self.sh.run("test -e /etc/default_user")[0] == 0:
            self.res.add("first boot setup", "skip", "already done")
            return True
        out = self.wait_cond("pidof f0rmz", 600)
        if out is None:
            self.res.add("first boot setup", "fail", "f0rmz (duranium-firstboot) never started",
                         unit=self.sh.out("systemctl status duranium-firstboot --no-pager -l | tail -20"))
            return False
        time.sleep(15)
        q = self.vm.qmp
        # f0rmz (LVGL, 720x1280 here): "Get Started", then one page per
        # field (username, password, optional FDE passphrase: left empty)
        # with Next/Submit at the bottom right, then a summary with "Finish"
        steps = [("welcome", None, (0.5, 0.629)),
                 ("username", TEST_USER, (0.928, 0.971)),
                 ("password", TEST_PASSWORD, (0.928, 0.971)),
                 ("fde-passphrase", None, (0.9, 0.971)),
                 ("summary", None, (0.5, 0.494))]
        for i, (page, text, button) in enumerate(steps):
            if text:
                type_text(q, text)
                time.sleep(1)
            self.shot(f"firstboot-{i}-{page}")
            tap(q, *button)
            time.sleep(5)
        if self.wait_cond("test -s /etc/default_user", 180) is None:
            self.shot("firstboot-stuck")
            self.res.add("first boot setup", "fail", "/etc/default_user not written (f0rmz input?)",
                         journal=self.sh.out("journalctl -b -u duranium-firstboot --no-pager | tail -30"))
            return False
        user = self.sh.out("cat /etc/default_user; id " + TEST_USER)
        self.res.add("first boot setup", "pass", user.replace("\n", "; "))
        return True

    def system_state(self, label):
        state = self.sh.out("timeout 900 systemctl is-system-running --wait", timeout=960)
        status = "pass" if state == "running" else "warn" if state == "degraded" else "fail"
        self.res.add(f"{label}: system state", status, state)
        for t in ("multi-user.target", "graphical.target"):
            st = self.sh.out(f"systemctl is-active {t}")
            self.res.add(f"{label}: {t}", "pass" if st == "active" else "fail", st)

    def ui(self, ui):
        if ui == "phosh":
            procs = {"greetd": "greetd", "phoc": "phoc", "greeter (phrog)": "phrog"}
        else:
            procs = {"gdm": "gdm", "gnome-shell (greeter)": "gnome-shell"}
        missing = []
        for name, comm in procs.items():
            if self.wait_cond(f"pgrep -x {comm} >/dev/null", 300) is None:
                missing.append(name)
        time.sleep(40)        # the greeter's first frames take a while under TCG
        self.shot("greeter")
        drm = self.sh.out("cat /sys/class/drm/card*-*/status 2>/dev/null | tr '\\n' ' '; "
                          "cat /sys/class/drm/card*/device/uevent 2>/dev/null | grep DRIVER | sort -u")
        if missing:
            self.res.add(f"{ui}: greeter", "fail", "not running: " + ", ".join(missing), drm=drm,
                         journal=self.sh.out("journalctl -b -u greetd -u gdm --no-pager | tail -40"))
            return False
        self.res.add(f"{ui}: greeter", "pass", f"running on {drm}")
        return self.login(ui)

    def login(self, ui):
        q = self.vm.qmp
        if ui == "phosh":
            # phrog opens on its password keypad; a keyboard types into it
            type_text(q, TEST_PASSWORD)
            press(q, "ret")
            if self.wait_cond(f"pgrep -u {TEST_USER} -x phosh", 240) is None:
                # an older phrog shows a lock screen first: swipe up, retry
                swipe(q, 0.5, 0.9, 0.5, 0.2)
                time.sleep(4)
                self.shot("login-retry")
                type_text(q, TEST_PASSWORD)
                press(q, "ret")
            comm = "phosh"
        else:
            tap(q, 0.5, 0.46)     # gdm's user list: the only user, centred
            time.sleep(6)
            self.shot("login-0")
            type_text(q, TEST_PASSWORD)
            press(q, "ret")
            comm = "gnome-shell"
        out = self.wait_cond(f"pgrep -u {TEST_USER} -x {comm}", 300)
        time.sleep(60)        # llvmpipe on TCG: let the shell finish its first frames
        self.shot("session")
        if out is None:
            self.res.add(f"{ui}: session", "fail", f"no {comm} running as {TEST_USER} after login",
                         journal=self.sh.out(f"journalctl -b _UID=$(id -u {TEST_USER}) --no-pager | tail -40"))
            return False
        procs = self.sh.out("ps -o pid,user,args | grep -E 'phoc|phosh|gnome-shell|mutter' | grep -v grep")
        self.res.add(f"{ui}: session", "pass", f"{comm} as {TEST_USER}", processes=procs)
        return True

    def errors(self, label):
        failed = self.sh.out("systemctl --failed --plain --no-legend --no-pager | awk '{print $1}'").split()
        units = {}
        for u in failed:
            units[u] = self.sh.out(f"journalctl -b -u {u} --no-pager -o cat | tail -6")
        q, k, unexp = classify([f"{u}: {' / '.join(units[u].splitlines()[-2:])}" for u in failed])
        self.res.add(f"{label}: failed units", "warn" if unexp else "pass",
                     f"{len(failed)} failed: {len(q)} QEMU-only, {len(k)} known, {len(unexp)} unexpected"
                     + (" (" + ", ".join(x.split(":")[0] for x in unexp) + ")" if unexp else ""),
                     qemu_only=q, known=k, unexpected=unexp, logs=units)
        lines = self.sh.out("journalctl -b -p err --no-pager -o short-monotonic | cut -c1-400",
                            timeout=180).splitlines()
        lines = [line for line in lines if not line.startswith("-- ")]
        q, k, unexp = classify(lines)
        self.res.add(f"{label}: journal errors", "warn" if unexp else "pass",
                     f"{len(lines)} lines: {len(q)} QEMU-only, {len(k)} known, {len(unexp)} unexpected",
                     qemu_only=q, known=k, unexpected=unexp)

    def debug_layer(self):
        rc, _ = self.sh.run("test -e /usr/lib/systemd/system/duranium-usb-debug.service")
        if rc:
            self.res.add("debug layer", "skip", "release image (no duranium-usb-debug)")
            return
        st = self.sh.out("for u in duranium-usb-debug.service duranium-debug-sockets.service "
                         "duranium-debug-shell.socket gta3-debug-console.socket; do "
                         "printf '%s %s %s\\n' $u $(systemctl is-active $u) "
                         "$(systemctl show -P NRestarts $u); done")
        bad = [l for l in st.splitlines() if " failed" in l or re.search(r" [1-9]\d*$", l)]
        self.res.add("debug layer: units (no USB gadget in QEMU)", "warn" if bad else "pass",
                     "; ".join(st.splitlines()))

    def update_source(self):
        """The image's sysupdate points at this project's channel and trusts
        only the project key (contrib/samsung-gtactive3wifi/mkosi.finalize)."""
        out = self.sh.out(
            "grep -h '^Path=http' /usr/lib/sysupdate.d/*.transfer | sort -u\n"
            "test -e /usr/lib/systemd/system/duranium-usb-debug.service && echo DEV\n"
            "gpg --no-default-keyring --keyring /usr/lib/systemd/import-pubring.pgp "
            "--with-colons --fingerprint 2>/dev/null | grep '^fpr' | cut -d: -f10")
        paths = [l for l in out.splitlines() if l.startswith("Path=")]
        fprs = [l for l in out.splitlines() if re.fullmatch(r"[0-9A-F]{40}", l)]
        want = UPDATE_BASE + "%M_%W_%w" + ("-dev" if "DEV" in out.splitlines() else "") + "/"
        ok = paths == ["Path=" + want] and fprs in ([], [PROJECT_KEY])
        self.res.add("update: sysupdate source and key", "pass" if ok else "fail",
                     f"{', '.join(paths)}; keys: {', '.join(fprs) or '? (no gpg)'}; expected {want}")
        if not ok:
            return
        rc, out = self.sh.run("timeout 600 /usr/lib/systemd/systemd-sysupdate list > /run/vt-list 2>&1; "
                              "rc=$?; tail -15 /run/vt-list; exit $rc", timeout=660)
        self.res.add("update: live channel (GitHub, signature)", "pass" if rc == 0 else "warn",
                     out.replace("\n", "; ")[-400:])

    def podman(self, image):
        """podman from /usr, else from the image's dev-tools sysext/confext
        (served from the image's directory, installed the way
        scripts/duranium-update does: /var/lib/duranium-extensions)."""
        rc, _ = self.sh.run("command -v podman")
        if rc:
            prefix, version = image_id(image)
            exts = {}
            for kind in ("sysext", "confext"):
                for suffix in (".raw", ".raw.zst"):
                    f = Path(image).parent / f"{prefix}_{version}.dev-tools-{kind}-arm64{suffix}"
                    if f.exists() and kind not in exts:
                        exts[kind] = f
            if "sysext" not in exts:
                self.res.add("podman", "skip", "no podman in /usr and no dev-tools sysext next to the image")
                return
            served = self.vm.dir / "ext"
            served.mkdir(exist_ok=True)
            for f in exts.values():
                dst = served / f.name.removesuffix(".zst")
                if f.name.endswith(".zst"):
                    run(["zstd", "-d", "-q", "-f", f, "-o", dst])
                else:
                    run(["cp", "--reflink=auto", f, dst])
            server = Server(served)
            script = ["mkdir -p /var/lib/duranium-extensions"]
            for f in sorted(served.iterdir()):
                script.append(f"wget -q -O /var/lib/duranium-extensions/{f.name} {server.url}{f.name}")
            script += ["/usr/libexec/gtactive3wifi/extensions-link",
                       "systemd-sysext refresh && systemd-confext refresh", "command -v podman"]
            rc, out = self.sh.run("\n".join(script) + " || exit 1", timeout=900)
            server.close()
            shutil.rmtree(served, ignore_errors=True)
            self.res.add("podman: dev-tools sysext", "pass" if rc == 0 else "fail", out[-300:])
            if rc:
                return
        cmd = "podman run --rm docker.io/library/alpine cat /etc/alpine-release"
        rc, out = self.sh.run(f"cd /tmp && {cmd} 2>&1", timeout=1200)
        if rc == 0:
            self.res.add("podman: alpine container", "pass", out[-200:])
            return
        # container networking needs nf_tables/veth/bridge modules: tell a
        # networking problem from a podman one
        rc2, out2 = self.sh.run(f"cd /tmp && {cmd.replace('run --rm', 'run --rm --network=host')} 2>&1",
                                timeout=600)
        self.res.add("podman: alpine container", "warn" if rc2 == 0 else "fail",
                     ("only with --network=host: " if rc2 == 0 else "") + out[-300:] + " / " + out2[-200:])

    # ------------------------------------------------------------ A/B update

    def esp_ukis(self):
        return self.sh.out("ls /boot/EFI/Linux/ 2>/dev/null || ls /efi/EFI/Linux/").split()

    def update(self, url, pubring, want):
        """updatectl update from the local mirror, reboot, check, bless."""
        before = self.sh.out(". /usr/lib/os-release; echo $IMAGE_VERSION")
        self.sh.put(pubring, "/etc/systemd/import-pubring.pgp")
        rc, out = self.sh.run(
            "systemctl stop systemd-sysupdate.timer systemd-sysupdate-update.timer "
            "systemd-sysupdate-reboot.timer systemd-sysupdate.service 2>/dev/null\n"
            "mkdir -p /etc/sysupdate.d\n"
            "for t in /usr/lib/sysupdate.d/*.transfer; do\n"
            f"  sed -E 's|^Path=https?://.*/$|Path={url}|' \"$t\" > /etc/sysupdate.d/${{t##*/}}\n"
            "done\n"
            "grep -h '^Path=http' /etc/sysupdate.d/*.transfer | sort -u\n"
            "updatectl check 2>&1 || systemd-sysupdate list 2>&1")
        self.res.add("update: channel", "pass" if rc == 0 and want in out else "fail",
                     f"{before} -> offered: {out[-300:]}")
        if rc or want not in out:
            return False
        t0 = time.time()
        if self.a.interrupt:
            rc, out = self.update_interrupted(want)
        else:
            rc, out = self.sh.run("updatectl update 2>&1", timeout=3600)
            self.res.add("update: updatectl update", "pass" if rc == 0 else "fail",
                         f"{round(time.time() - t0)}s: {out[-500:]}")
        if rc:
            self.res.data["sysupdate_log"] = self.sh.out(
                "journalctl -b -u systemd-sysupdated -u 'systemd-sysupdate*' --no-pager | tail -60")
            return False
        layout = self.sh.out("lsblk -rno NAME,PARTLABEL,SIZE; ls -l /boot/EFI/Linux/; bootctl list --no-pager 2>&1 | grep -E 'title|version|id:|tries'")
        new_uki = [f for f in self.esp_ukis() if f"_{want}+" in f]
        self.res.add("update: new UKI with boot counter", "pass" if new_uki else "fail",
                     ", ".join(new_uki) or "none", layout=layout)
        self.vm.serial.mark()
        self.sh._send(b"systemctl reboot\r")
        self.sh.close()
        time.sleep(20)
        info = self.boot("after update", self.a.boot_timeout)
        if not info:
            return False
        ok = info[0] == want
        self.res.add("update: new version booted", "pass" if ok else "fail", f"{info[0]} (wanted {want})")
        blessed = self.wait_cond("systemctl is-active boot-complete.target >/dev/null || exit 1\n"
                                 "ls /boot/EFI/Linux/ | grep -q '_%s+' && exit 1\n"
                                 "ls /boot/EFI/Linux/" % want, 900)
        self.res.add("update: boot counting marked it good", "pass" if blessed else "fail",
                     blessed or self.sh.out("systemctl status systemd-bless-boot --no-pager | tail; ls /boot/EFI/Linux"))
        return ok and blessed is not None

    def update_interrupted(self, want):
        """The automatic update service with a download that breaks off:
        systemd-sysupdate.service (update --cleanup=yes) must fail, be
        restarted (device package r31: Restart=on-failure; here with a short
        RestartSec) and finish the update on a later attempt."""
        QuietHandler.CUT = ".usr-arm64."
        # the image's own retry policy (device package r31+) with a shorter
        # RestartSec; images without one get r31's Restart=on-failure
        own = self.sh.out("systemctl show -P Restart systemd-sysupdate.service")
        extra = "" if own == "on-failure" else "Restart=on-failure\\n"
        self.res.data["sysupdate_retry_policy"] = own if not extra else f"{own} (r31 emulated)"
        rc, out = self.sh.run(
            "mkdir -p /run/systemd/system/systemd-sysupdate.service.d\n"
            "printf '[Unit]\\nStartLimitIntervalSec=1h\\nStartLimitBurst=4\\n"
            f"[Service]\\n{extra}RestartSec=30s\\n' "
            "> /run/systemd/system/systemd-sysupdate.service.d/zz-virt-test.conf\n"
            "systemctl daemon-reload\n"
            "systemctl start --no-block systemd-sysupdate.service")
        t0 = time.time()
        done = self.wait_cond(
            "[ \"$(systemctl show -P NRestarts systemd-sysupdate.service)\" -ge 1 ] || exit 1\n"
            "systemctl is-active -q systemd-sysupdate.service && exit 1\n"
            "[ \"$(systemctl show -P Result systemd-sysupdate.service)\" = success ] || exit 1\n"
            f"ls /boot/EFI/Linux/ | grep '_{want}+'", 1800, poll=15)
        log_ = self.sh.out("journalctl -b --no-pager -o short-monotonic -t systemd-sysupdate -t systemd "
                           "| grep -E 'sysupdate|sd-pull' | grep -vE 'Acquiring|Validating|Discover' | tail -40")
        cut = (self.vm.dir / "mirror.log").read_text().count("connection cut")
        ok = done is not None and cut >= 1
        self.res.add("update: broken-off download recovers (systemd-sysupdate.service)",
                     "pass" if ok else "fail",
                     f"{cut} download(s) cut, {round(time.time() - t0)}s, restarts "
                     f"{self.sh.out('systemctl show -P NRestarts systemd-sysupdate.service')}",
                     journal=log_)
        QuietHandler.CUT = None
        return (0 if ok else 1), log_

    def rollback(self, prefix, good, bad):
        """Break the blessed new version (unblessed UKI + corrupt usr) and
        check that boot counting returns to the previous one."""
        self.vm.stop()
        disk = self.vm.dir / "disk.raw"
        img = f"{disk}@@{esp_offset(disk)}"
        run(["mren", "-i", img, f"::/EFI/Linux/{prefix}_{bad}.efi", f"::/EFI/Linux/{prefix}_{bad}+2-0.efi"])
        usr = part_by_label(disk, f"duranium_{bad}_usr")
        with open(disk, "r+b") as f:
            f.seek(usr["start"] * SECTOR)
            f.write(b"\xa5" * (64 << 20))
        log(f"rollback: {prefix}_{bad}.efi -> +2-0, first 64 MiB of duranium_{bad}_usr overwritten")
        self.vm.start()
        attempts = []
        for attempt in range(4):
            t0 = time.time()
            try:
                ok = self.sh.wait(min(self.a.boot_timeout, 1200), serial=self.vm.serial)
                why = "booted" if ok else "timeout"
            except Fail as e:
                ok, why = False, str(e)
            self.shot(f"rollback-{attempt}")
            if ok:
                ver = self.sh.out(". /usr/lib/os-release; echo $IMAGE_VERSION")
                attempts.append(f"attempt {attempt}: {why} {ver} after {round(time.time() - t0)}s")
                if ver == bad:
                    self.res.add("rollback", "fail", "the corrupted version booted", attempts=attempts)
                    return False
                ukis = self.esp_ukis()
                marked = any(f"_{bad}+0-" in u for u in ukis)
                self.res.add("rollback: previous version booted", "pass" if ver == good else "fail",
                             f"{ver}; ESP: {' '.join(ukis)}", attempts=attempts)
                self.res.add("rollback: broken version marked bad", "pass" if marked else "fail",
                             " ".join(ukis))
                return ver == good
            attempts.append(f"attempt {attempt}: {why} after {round(time.time() - t0)}s, reset")
            log(f"rollback attempt {attempt}: {why}; system_reset")
            self.vm.reset()
        self.res.add("rollback", "fail", "no version booted", attempts=attempts,
                     serial_tail=self.vm.serial.tail())
        return False


# ---------------------------------------------------------------- commands

def image_id(path):
    """<prefix>, <version> from <prefix>_<YYMMDDNN>.raw[.zst]"""
    m = re.match(r"(.+)_(\d{8})\.raw(\.zst)?$", Path(path).name)
    if not m:
        raise Fail(f"{path}: expected <image-id>_<version>.raw[.zst]")
    return m.group(1), m.group(2)


def new_rundir(a):
    prefix, version = image_id(a.image)
    name = a.name or f"{prefix.split('_', 1)[-1]}_{version}-{time.strftime('%m%d%H%M%S')}"
    d = ROOT / "build/virt/runs" / name
    d.mkdir(parents=True, exist_ok=False)
    return d


def cmd_check(a):
    prefix, version = image_id(a.image)
    rundir = new_rundir(a)
    ui = a.ui if a.ui != "auto" else ("gnome" if "_gnome_" in prefix else "phosh")
    global LOGFILE
    LOGFILE = rundir / "log.txt"
    res = Results(rundir, {"image": str(a.image), "id": prefix, "version": version, "ui": ui})
    log(f"run directory: {rundir}")
    vm = VM(rundir, mem_mb=a.mem, ssh_port=a.ssh_port)
    mirror = None
    try:
        prepare_disk(a.image, rundir, a.disk_gb, a.kernel)
        if a.update:
            src, want = a.update.rsplit(":", 1)
            mirror = Mirror(rundir)
            mirror.add_version(src, prefix, want, a.update_kernel or a.kernel)
            pubring = mirror.sign()
            url = mirror.serve()
        vm.start()
        c = Checks(a, vm, res)
        if not c.boot("first boot", a.boot_timeout):
            return res
        c.first_boot()
        c.system_state("first boot")
        if not a.no_ui:
            c.ui(ui)
        c.errors("first boot")
        c.debug_layer()
        c.update_source()
        c.podman(a.image)
        if a.update and c.update(url, pubring, want):
            c.system_state("after update")
            c.errors("after update")
            if a.rollback:
                c.rollback(prefix, version, want)
    except Skip as e:
        res.add("image", "skip", str(e))
        res.data["skipped"] = True
    except Fail as e:
        res.add("harness", "fail", str(e), serial_tail=vm.serial.tail())
    finally:
        if vm.qmp and vm.running():
            if a.keep:
                log(f"--keep: VM left running, stop it with: harness.py stop {rundir}")
            else:
                vm.stop()
        if mirror:
            mirror.close()
        if (rundir / "aborted").exists():
            res.add("laptop memory", "fail", (rundir / "aborted").read_text().strip())
        res.save()
        if not a.keep_disk and not a.keep:
            for f in ("disk.raw", "vars.fd"):
                (rundir / f).unlink(missing_ok=True)
            if mirror:
                shutil.rmtree(mirror.dir, ignore_errors=True)
    summary(res)
    return res


def summary(res):
    d = res.data
    print(f"\n== {d['id']}_{d['version']} ({d['ui']}): {d['result']} in {d['duration_s']}s")
    for c in d["checks"]:
        detail = " ".join(c["detail"].split())
        print(f"  {c['status'].upper():5} {c['name']}: {detail[:160]}")
    print(f"results: {res.dir / 'results.json'}")


def cmd_watchdog(a):
    """Runs next to every VM: powers it off if the laptop runs low on memory."""
    rundir = Path(a.run)
    pid = int((rundir / "qemu.pid").read_text())
    while Path(f"/proc/{pid}").exists():
        avail = mem_available_mb()
        if avail < MEM_ABORT_MB and (rundir / "qmp.sock").exists():
            msg = f"MemAvailable {avail} MiB < {MEM_ABORT_MB} MiB: VM powered off by the watchdog"
            (rundir / "aborted").write_text(msg + "\n")
            print(time.strftime("%H:%M:%S"), msg, flush=True)
            try:
                q = QMP(rundir / "qmp.sock")
                q.cmd("system_powerdown")
                for _ in range(30):
                    if not Path(f"/proc/{pid}").exists():
                        return
                    time.sleep(2)
                q.cmd("quit")
            except (Fail, OSError):
                os.kill(pid, 15)
            return
        time.sleep(5)


def cmd_report(a):
    """Markdown summary of a run (for CI step summaries)."""
    d = json.loads((Path(a.run) / "results.json").read_text())
    print(f"### {d['id']}_{d['version']} ({d['ui']}): {d['result']} in {d.get('duration_s', '?')} s\n")
    print("| check | result | detail |\n|---|---|---|")
    for c in d["checks"]:
        detail = c["detail"].replace("|", "\\|").replace("\n", " ")[:200]
        print(f"| {c['name']} | {c['status']} | {detail} |")
    for c in d["checks"]:
        if c.get("unexpected"):
            print(f"\n<details><summary>{c['name']}: unexpected</summary>\n\n```")
            print("\n".join(c["unexpected"][:80]))
            print("```\n</details>")


def cmd_start(a):
    """Boot an image and leave the VM running (for interactive work)."""
    rundir = new_rundir(a)
    prepare_disk(a.image, rundir, a.disk_gb, a.kernel)
    vm = VM(rundir, mem_mb=a.mem, ssh_port=a.ssh_port)
    vm.start()
    print(rundir)


def cmd_resume(a):
    """Boot a stopped run directory's disk again (after "stop" or --keep-disk)."""
    vm = VM(a.run, mem_mb=a.mem, ssh_port=a.ssh_port)
    vm.start()
    print(a.run)


def attach(rundir):
    vm = VM(rundir)
    vm.attach()
    return vm


def cmd_sh(a):
    vm = attach(a.run)
    if not vm.shell.ready(timeout=a.timeout):
        raise Fail("no shell on hvc0 (yet)")
    rc, out = vm.shell.run(a.cmd, timeout=a.timeout)
    print(out)
    return rc


def cmd_step(a):
    """Run single checks against a running VM (results in RUN/step-results.json)."""
    vm = attach(a.run)
    res = Results(a.run, {"id": "step", "version": "", "ui": a.ui})
    res.dir = Path(a.run)
    c = Checks(a, vm, res)
    if not vm.shell.ready(timeout=30):
        raise Fail("no shell on hvc0 (yet)")
    for step in a.steps:
        {"firstboot": c.first_boot, "state": lambda: c.system_state("now"),
         "ui": lambda: c.ui(a.ui), "errors": lambda: c.errors("now"),
         "debug": c.debug_layer, "source": c.update_source}[step]()
    (Path(a.run) / "step-results.json").write_text(json.dumps(res.data, indent=1) + "\n")


def cmd_shot(a):
    print(screenshot(attach(a.run).qmp, a.png))


def cmd_type(a):
    type_text(attach(a.run).qmp, a.text)


def cmd_key(a):
    press(attach(a.run).qmp, *a.keys)


def cmd_tap(a):
    tap(attach(a.run).qmp, a.x, a.y)


def cmd_swipe(a):
    swipe(attach(a.run).qmp, a.x0, a.y0, a.x1, a.y1)


def cmd_stop(a):
    vm = attach(a.run)
    pid = int((Path(a.run) / "qemu.pid").read_text())
    try:
        if vm.shell.ready(timeout=5):
            vm.shell._send(b"systemctl poweroff\r")
        else:
            vm.qmp.cmd("system_powerdown")
    except (Fail, OSError):
        pass
    for _ in range(90):
        if not Path(f"/proc/{pid}").exists():
            break
        time.sleep(2)
    else:
        vm.qmp.cmd("quit")
    print("stopped")


def main():
    ap = argparse.ArgumentParser(description="QEMU test harness for the Duranium images")
    sub = ap.add_subparsers(dest="cmd", required=True)

    def image_args(p):
        p.add_argument("image", help="<image-id>_<version>.raw or .raw.zst")
        p.add_argument("--kernel", default="auto",
                       help="auto (build a virt Image if the UKI's kernel lacks virt drivers), none, or an Image")
        p.add_argument("--mem", type=int, default=2560, help=f"guest MiB (default 2560, at most {MAX_MEM_MB})")
        p.add_argument("--disk-gb", type=int, default=24)
        p.add_argument("--ssh-port", type=int, default=0,
                       help="forward host 127.0.0.1:N/N+1/N+2 to guest 22/23/2323")
        p.add_argument("--name", help="run directory name under build/virt/runs")

    p = sub.add_parser("check", help="boot an image and run every check")
    image_args(p)
    p.add_argument("--ui", choices=["auto", "phosh", "gnome"], default="auto")
    p.add_argument("--update", metavar="DIR:VERSION",
                   help="A/B update to VERSION from DIR (mkosi.output/<id> or a downloaded release)")
    p.add_argument("--update-kernel", help="--kernel for the update's UKI (default: the same)")
    p.add_argument("--interrupt", action="store_true",
                   help="update through systemd-sysupdate.service with the first usr download cut off")
    p.add_argument("--rollback", action="store_true", help="after the update, test the fallback")
    p.add_argument("--no-ui", action="store_true", help="skip the greeter/login checks")
    p.add_argument("--boot-timeout", type=int, default=1800)
    p.add_argument("--keep", action="store_true", help="leave the VM running at the end")
    p.add_argument("--keep-disk", action="store_true", help="keep disk.raw in the run directory")
    p.set_defaults(fn=cmd_check)

    p = sub.add_parser("start", help="boot an image, leave it running")
    image_args(p)
    p.set_defaults(fn=cmd_start)

    p = sub.add_parser("resume", help="boot a run directory's disk again, leave it running")
    p.add_argument("run")
    p.add_argument("--mem", type=int, default=2560)
    p.add_argument("--ssh-port", type=int, default=0)
    p.set_defaults(fn=cmd_resume)

    p = sub.add_parser("sh", help="run a command in a running VM")
    p.add_argument("run")
    p.add_argument("cmd")
    p.add_argument("--timeout", type=int, default=120)
    p.set_defaults(fn=cmd_sh)
    p = sub.add_parser("step", help="run single checks on a running VM")
    p.add_argument("run")
    p.add_argument("steps", nargs="+", choices=["firstboot", "state", "ui", "errors", "debug", "source"])
    p.add_argument("--ui", choices=["phosh", "gnome"], default="phosh")
    p.set_defaults(fn=cmd_step)
    p = sub.add_parser("shot", help="screenshot (PNG) of a running VM")
    p.add_argument("run")
    p.add_argument("png")
    p.set_defaults(fn=cmd_shot)
    p = sub.add_parser("type", help="type text")
    p.add_argument("run")
    p.add_argument("text")
    p.set_defaults(fn=cmd_type)
    p = sub.add_parser("key", help="press keys together (QEMU qcodes: ret, tab, esc, ctrl, ...)")
    p.add_argument("run")
    p.add_argument("keys", nargs="+")
    p.set_defaults(fn=cmd_key)
    p = sub.add_parser("tap", help="tap at X Y (0..1)")
    p.add_argument("run")
    p.add_argument("x", type=float)
    p.add_argument("y", type=float)
    p.set_defaults(fn=cmd_tap)
    p = sub.add_parser("swipe", help="swipe X0 Y0 X1 Y1 (0..1)")
    p.add_argument("run")
    for n in ("x0", "y0", "x1", "y1"):
        p.add_argument(n, type=float)
    p.set_defaults(fn=cmd_swipe)
    p = sub.add_parser("watchdog", help=argparse.SUPPRESS)
    p.add_argument("run")
    p.set_defaults(fn=cmd_watchdog)
    p = sub.add_parser("report", help="markdown summary of a run directory")
    p.add_argument("run")
    p.set_defaults(fn=cmd_report)
    p = sub.add_parser("stop", help="power a running VM off")
    p.add_argument("run")
    p.set_defaults(fn=cmd_stop)

    a = ap.parse_args()

    def interrupted(sig, frame):
        raise KeyboardInterrupt(f"signal {sig}")
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupted)
    try:
        r = a.fn(a)
    except Skip as e:
        print(f"skip: {e}", file=sys.stderr)
        sys.exit(77)
    except Fail as e:
        sys.exit(f"error: {e}")
    if isinstance(r, Results):
        sys.exit({"PASS": 0, "SKIP": 77}.get(r.data["result"], 1))
    sys.exit(r if isinstance(r, int) else 0)


if __name__ == "__main__":
    main()
