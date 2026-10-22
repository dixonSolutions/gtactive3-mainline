#!/usr/bin/env python3
"""Client for the SM-T570 USB debug console (TCP 23 over the USB NCM link).

The same protocol is served by the gtactive3-mainline bring-up Linux (the
installer's live environment, initramfs/init.c) and, in Duranium dev
images, by gta3-console: a "> " prompt, one command per line.
  cat PATH          streams PATH (a block device: the whole device)
  put PATH LEN      then LEN raw bytes; answers "ok <received>"
  write PATH VALUE  answers "ok" / "error"
  evread PATH N S   input events "sec.usec type code value", "timeout"

usage:
  console.py probe                       prints "bringup" or "duranium VERSION VARIANT"
  console.py cmd LINE [TIMEOUT]          prints the answer
  console.py put LOCAL|- REMOTE LEN [LABEL]
  console.py get REMOTE LEN SHAFILE [LABEL]   raw bytes to stdout, sha256 to SHAFILE
  console.py hash REMOTE LEN [LABEL]     sha256 of the first LEN bytes
  console.py key DEV SECS                waits for a key press: prints its code,
                                         "timeout", or exits 3 if the console went away

Address: $GTA3_CONSOLE_ADDR, else fe80::57:aff:fe00:1%<the cdc_ncm interface>;
port $GTA3_CONSOLE_PORT (default 23).
"""
import hashlib
import os
import socket
import sys
import time

LL = "fe80::57:aff:fe00:1"
PORT = int(os.environ.get("GTA3_CONSOLE_PORT", "23"))


def ncm_iface():
    base = "/sys/class/net"
    for n in sorted(os.listdir(base)):
        try:
            drv = os.path.basename(os.readlink(os.path.join(base, n, "device", "driver")))
        except OSError:
            continue
        if drv == "cdc_ncm":
            return n
    return None


def address():
    a = os.environ.get("GTA3_CONSOLE_ADDR")
    if a:
        return a
    i = ncm_iface()
    if not i:
        sys.exit("no tablet USB network (cdc_ncm) interface")
    return f"{LL}%{i}"


def connect(timeout=10):
    s = socket.create_connection((address(), PORT), timeout=timeout)
    s.settimeout(30)
    buf = b""
    while not buf.endswith(b"> "):
        d = s.recv(65536)
        if not d:
            sys.exit("console closed before the prompt")
        buf += d
    return s


def until_prompt(s):
    buf = b""
    while not buf.endswith(b"> "):
        d = s.recv(65536)
        if not d:
            break
        buf += d
    return buf[:-2] if buf.endswith(b"> ") else buf


def cmd(line, timeout=30):
    s = connect()
    s.settimeout(timeout)
    s.sendall(line.encode() + b"\n")
    out = until_prompt(s)
    s.close()
    return out.decode(errors="replace")


class Progress:
    """One line per 5 % when not on a terminal, a live line on one."""

    def __init__(self, label, total):
        self.label, self.total, self.t0 = label, total, time.time()
        self.tty = sys.stderr.isatty()
        self.last = -1

    def __call__(self, done, final=False):
        pct = 100 * done // self.total if self.total else 100
        if not final and (pct == self.last or (not self.tty and pct % 5)):
            return
        self.last = pct
        dt = max(time.time() - self.t0, 1e-3)
        rate = done / dt
        eta = int((self.total - done) / rate) if rate > 0 else 0
        msg = (f"  {self.label}: {done / 2**30:.2f} / {self.total / 2**30:.2f} GiB "
               f"{pct:3d}% {rate / 1e6:.1f} MB/s ETA {eta // 60}:{eta % 60:02d}")
        if self.tty:
            sys.stderr.write("\r" + msg + ("\n" if final else ""))
        else:
            sys.stderr.write(msg + "\n")
        sys.stderr.flush()


def put(local, remote, n, label=None):
    s = connect(timeout=30)
    s.sendall(f"put {remote} {n}\n".encode())
    prog = Progress(label or os.path.basename(remote), n) if n > 1 << 20 else None
    f = sys.stdin.buffer if local == "-" else open(local, "rb")
    sent = 0
    while sent < n:
        c = f.read(min(1 << 20, n - sent))
        if not c:
            sys.exit(f"short read of {local} at {sent} of {n} bytes")
        s.sendall(c)
        sent += len(c)
        if prog:
            prog(sent)
    if prog:
        prog(sent, True)
    s.settimeout(300)  # the last page-cache flush happens before the reply
    r = b""
    while b"\n" not in r:
        d = s.recv(4096)
        if not d:
            break
        r += d
    line = r.split(b"\n")[0].decode(errors="replace").strip()
    s.close()
    print(line)
    return line == f"ok {n}"


def stream(remote, n, sink, label=None):
    """cat REMOTE, feed exactly n bytes to sink(bytes), then hang up (a
    block device would otherwise stream to its end)."""
    s = connect()
    s.settimeout(120)
    s.sendall(f"cat {remote}\n".encode())
    h = hashlib.sha256()
    prog = Progress(label or os.path.basename(remote), n) if n > 1 << 20 else None
    got = 0
    while got < n:
        d = s.recv(min(1 << 20, n - got))
        if not d:
            sys.exit(f"console closed after {got} of {n} bytes of {remote}")
        if got == 0 and d.startswith(b"error\n"):
            sys.exit(f"cannot read {remote}")
        h.update(d)
        sink(d)
        got += len(d)
        if prog:
            prog(got)
    if prog:
        prog(got, True)
    s.close()
    return h.hexdigest()


def key(dev, secs):
    """Wait up to secs for a key press on dev; print its code."""
    end = time.time() + secs
    while time.time() < end:
        left = max(1, min(30, int(end - time.time())))
        try:
            out = cmd(f"evread {dev} 16 {left}", timeout=left + 15)
        except OSError:
            sys.exit(3)
        for ln in out.splitlines():
            f = ln.split()
            # "sec.usec type code value": EV_KEY (1), pressed (1)
            if len(f) == 4 and f[1] == "1" and f[3] == "1":
                print(int(f[2], 16))
                return
            if ln.strip() == "error":
                sys.exit(f"cannot read {dev}")
    print("timeout")


def main():
    a = sys.argv[1:]
    if not a:
        sys.exit(__doc__)
    op = a[0]
    try:
        if op == "probe":
            s = connect(timeout=3)
            s.sendall(b"cat /etc/os-release\n")
            r = until_prompt(s).decode(errors="replace")
            s.close()
            kv = dict(ln.split("=", 1) for ln in r.splitlines() if "=" in ln)
            # Duranium images say ID=nura (upstream's name); the bring-up
            # Linux has no os-release at all
            if kv.get("IMAGE_ID", "").strip('"').startswith("samsung-gtactive3wifi"):
                print("duranium", kv.get("IMAGE_VERSION", "?").strip('"'),
                      kv.get("VARIANT_ID", "?").strip('"'))
            else:
                print("bringup")
        elif op == "cmd":
            sys.stdout.write(cmd(a[1], int(a[2]) if len(a) > 2 else 30))
        elif op == "put":
            sys.exit(0 if put(a[1], a[2], int(a[3]), a[4] if len(a) > 4 else None) else 1)
        elif op == "get":
            out = sys.stdout.buffer
            digest = stream(a[1], int(a[2]), out.write, a[4] if len(a) > 4 else None)
            out.flush()
            with open(a[3], "w") as f:
                f.write(digest + "\n")
        elif op == "hash":
            print(stream(a[1], int(a[2]), lambda d: None, a[3] if len(a) > 3 else None))
        elif op == "key":
            key(a[1], int(a[2]))
        else:
            sys.exit(__doc__)
    except (OSError, socket.timeout) as e:
        sys.exit(f"console: {e}")


if __name__ == "__main__":
    main()
