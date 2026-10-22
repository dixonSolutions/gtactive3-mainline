#!/usr/bin/env python3
"""Fake USB debug console (initramfs/init.c protocol) for the installer
tests. Answers only while the mock tablet ($MOCK_STATE) is in "bringup" or
"duranium"; paths map into the state's "root" directory.

usage: fakeconsole.py PORTFILE   (listens on 127.0.0.1, writes the port)
"""
import fcntl
import json
import os
import socket
import socketserver
import struct
import sys

STATE = os.environ["MOCK_STATE"]
DISCARD_OK = {"/dev/sda24", "/dev/sda25", "/dev/sda28", "/dev/sda31"}
BANNER = b"Galaxy Tab Active3 debug console (fake). Commands: dmesg, peek, cat, put, write, run, ls, evread, reboot\n> "


def load():
    with open(STATE + ".lock", "w") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        with open(STATE) as f:
            return json.load(f)


def update(fn):
    with open(STATE + ".lock", "w") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        with open(STATE) as f:
            s = json.load(f)
        fn(s)
        with open(STATE + ".tmp", "w") as f:
            json.dump(s, f, indent=1)
        os.replace(STATE + ".tmp", STATE)


def rpath(s, p):
    return os.path.join(s["root"], p.lstrip("/"))


class H(socketserver.BaseRequestHandler):
    def handle(self):
        s = load()
        if s["mode"] not in ("bringup", "duranium"):
            return
        c = self.request
        c.sendall(BANNER)
        buf = b""
        while True:
            while b"\n" not in buf:
                d = c.recv(65536)
                if not d:
                    return
                buf += d
            line, buf = buf.split(b"\n", 1)
            line = line.decode(errors="replace").strip()
            s = load()
            if s["mode"] not in ("bringup", "duranium"):
                return
            mode = s["mode"]
            out = b""
            w = line.split(" ")
            if w[0] == "cat" and len(w) > 1:
                p = w[1]
                if mode == "bringup" and p == "/etc/os-release":
                    out = b"error\n"
                elif mode == "duranium" and p in ("/etc/os-release", "/usr/lib/os-release"):
                    out = s["os_release"].encode()
                else:
                    try:
                        with open(rpath(s, p), "rb") as f:
                            while True:
                                d = f.read(1 << 20)
                                if not d:
                                    break
                                try:
                                    c.sendall(d)
                                except OSError:
                                    return  # client hung up mid-stream (block device read)
                    except OSError:
                        out = b"error\n"
            elif w[0] == "put" and len(w) == 3:
                n, got = int(w[2]), 0
                path = rpath(s, w[1])
                os.makedirs(os.path.dirname(path), exist_ok=True)
                block = w[1].startswith("/dev/sda")
                f = open(path, "r+b" if block and os.path.exists(path) else "ab" if w[1] == "/dev/tty0" else "wb")
                while got < n:
                    if buf:
                        d, buf = buf[:n - got], buf[n - got:]
                    else:
                        d = c.recv(min(1 << 20, n - got))
                        if not d:
                            break
                    f.write(d)
                    got += len(d)
                f.close()
                if block and w[1] not in ("/dev/sda31", "/dev/sda24"):
                    update(lambda st: st.__setitem__("violation", f"put {w[1]}"))
                update(lambda st: st["log"].append(f"put {w[1]} {got}"))
                out = f"ok {got}\n".encode()
            elif w[0] == "write" and len(w) >= 3:
                out = b"ok\n"
            elif w[0] == "discard" and len(w) == 2:
                if w[1] not in DISCARD_OK:
                    out = b"discard: not an approved partition\n"
                else:
                    p = rpath(s, w[1])
                    size = os.path.getsize(p)
                    with open(p, "r+b") as f:
                        f.truncate(0)
                        f.truncate(size)
                    update(lambda st: st["log"].append(f"discard {w[1]}"))
                    out = f"discarded {size} bytes\n".encode()
            elif w[0] == "ls" and len(w) == 2:
                try:
                    out = "".join(n + "\n" for n in sorted(os.listdir(rpath(s, w[1])))).encode()
                except OSError:
                    out = b"error\n"
            elif w[0] == "poke":
                out = b"ok\n"
            elif w[0] == "evread":
                k = s.get("tablet_key", 116)
                if k == "timeout":
                    out = b"name: gpio_keys\ntimeout\n"
                else:
                    out = f"name: gpio_keys\n1.000000 1 {int(k):x} 1\n1.100000 1 {int(k):x} 0\n".encode()
                    if int(k) == 115 and mode == "bringup":  # init: Volume Up = Download mode
                        update(lambda st: st.__setitem__("mode", "download"))
                        c.sendall(out)
                        return
            elif w[0] == "reboot":
                m = w[1] if len(w) > 1 else "normal"
                c.sendall(b"rebooting\n")

                def rb(st):
                    st["log"].append(f"console reboot {m}")
                    st["mode"] = "download" if m == "download" else st["mode"]
                update(rb)
                return
            elif w[0] == "run":
                out = self.run(s, w[1:]).encode()
            elif line:
                out = b"unknown command\n"
            c.sendall(out + b"> ")

    def run(self, s, argv):
        if argv and argv[0].endswith("mkfs.f2fs"):
            dev = argv[-1]
            update(lambda st: st["log"].append("mkfs " + " ".join(argv[1:])))
            with open(rpath(s, dev), "r+b") as f:
                sb = bytearray(4096)
                struct.pack_into("<I", sb, 1024, 0xF2F52010)
                feat = 0x499 if "-Oencrypt,extra_attr,project_quota,quota,verity" in argv else 0x1
                struct.pack_into("<I", sb, 1024 + 2180, feat)
                f.write(sb)
            return "Info: format successful\nrun: exit 0 signal 0\n"
        if argv[:1] == ["/bin/sh"] and len(argv) == 2:
            try:
                script = open(rpath(s, argv[1])).read()
            except OSError:
                return "run: exit 127 signal 0\n"
            for ln in script.splitlines():
                if ln.startswith("# gta3:"):
                    name = ln[7:].strip()
                    update(lambda st: st["log"].append("sh " + name))
                    return s.get("sh", {}).get(name, "") + "run: exit 0 signal 0\n"
            return "run: exit 0 signal 0\n"
        return "run: exit 127 signal 0\n"


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    srv = Server(("127.0.0.1", 0), H)
    with open(sys.argv[1] + ".tmp", "w") as f:
        f.write(str(srv.server_address[1]))
    os.replace(sys.argv[1] + ".tmp", sys.argv[1])
    srv.serve_forever()


if __name__ == "__main__":
    main()
