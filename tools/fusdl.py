#!/usr/bin/env python3
"""Minimal Samsung FUS firmware downloader.

Port of the "Smart" FUS client from Bifrost (github.com/zacharee/Bifrost,
FusClient.kt / CryptUtils.kt / Request.kt). Talks only to Samsung's servers.

Portions Copyright (c) 2021 Zachary Wander, MIT License (Bifrost).

Needs tools/auth_param.dat next to this script: copy it from Bifrost's
common/src/commonMain/composeResources/files/auth_param.dat (not redistributed here).

usage: fusdl.py MODEL REGION SERIAL OUTDIR
"""
import hashlib
import os
import struct
import sys
import zlib
from xml.etree import ElementTree as ET

import requests
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

HERE = os.path.dirname(os.path.abspath(__file__))
FUS = "https://neofussvr.sslcs.cdngc.net/"
DL = "http://cloud-neofussvr.samsungmobile.com/NF_SmartDownloadBinaryForMass.do?file="
UA = "SMART 2.0"
SHIFT = [0, 5, 10, 15, 4, 9, 14, 3, 8, 13, 2, 7, 12, 1, 6, 11]


# ---- white-box AES block from auth_param.dat (CryptUtils.authenticateBlock) ----
class AuthParams:
    def __init__(self, path):
        with open(path, "rb") as f:
            self.data = f.read()
        v = struct.unpack("<14i", self.data[:56])
        # magic, alignment, b1, b2, b5, b6, b3, b4 (offset, size)
        self.b1_size, self.b2_size, self.b3_size = v[3], v[5], v[11]

    def s(self, pos, n=1):
        pos += 56
        return self.data[pos:pos + n]

    def block(self, inb: bytes) -> bytes:
        t = [0] * 320
        for i in range(16):
            t[i] = inb[i]
        v15 = [0] * 64
        base_final = self.b1_size
        for j in range(9):
            src = j * 32
            nxt = (j + 1) * 32
            blk_base = j * 16
            mid = src + 16
            for idx in range(16):
                t[src + 16 + idx] = t[src + SHIFT[idx]]
            for i in range(4):
                i4, i16 = i << 2, i << 4
                row = blk_base + i4
                base262 = base_final + self.b2_size + self.b3_size + 6144 * (i + (j << 2))
                for k in range(4):
                    val = t[mid + i4 + k]
                    blk = row + k
                    src16 = self.s((blk << 12) + (val << 4), 16)
                    sel = self.s(base_final + self.b2_size + (blk << 5), 32)
                    out = i16 + (k << 2)
                    for oi in range(4):
                        acc = 0
                        sb = oi << 3
                        for bi in range(8):
                            b = sel[sb + bi]
                            si = (b >> 3) & 0x1F
                            bp = 7 - (b & 7)
                            byte = src16[si] if si < 16 else 0
                            acc |= ((byte >> bp) & 1) << (7 - bi)
                        v15[out + oi] = acc & 0xFF
                for k2 in range(4):
                    a1, a2, a3, a4 = (v15[i16 + k2 + o] for o in (0, 4, 8, 12))
                    tbl = self.s(base262 + 1536 * k2, 1536)
                    hi1 = ((a1 & 0xF0) | (a2 >> 4)) & 0xFF
                    lo1 = (((a1 & 0x0F) << 4) | (a2 & 0x0F)) & 0xFF
                    v6 = ((16 * tbl[hi1]) ^ tbl[256 + lo1]) & 0xFF
                    hi2 = ((a3 & 0xF0) | (a4 >> 4)) & 0xFF
                    lo2 = (((a3 & 0x0F) << 4) | (a4 & 0x0F)) & 0xFF
                    v7 = ((16 * tbl[512 + hi2]) ^ tbl[768 + lo2]) & 0xFF
                    hi3 = ((v6 & 0xF0) | (v7 >> 4)) & 0xFF
                    lo3 = (((v6 & 0x0F) << 4) | (v7 & 0x0F)) & 0xFF
                    t[nxt + i4 + k2] = ((16 * tbl[1024 + hi3]) ^ tbl[1280 + lo3]) & 0xFF
        return bytes(self.s(base_final + (idx << 8) + t[SHIFT[idx] + 288])[0] for idx in range(16))


def logic_check(inp: str, nonce: str) -> str:
    if len(inp) < 16:
        return ""
    return "".join(inp[ord(c) & 0xF] for c in nonce)


# ---- XML helpers matching Bifrost's builder ----
def el(parent, tag, text=None):
    e = ET.SubElement(parent, tag)
    if text is not None:
        e.text = text
    return e


def data(parent, tag, text):
    el(el(parent, tag), "Data", text)


def find_data(root, path):
    e = root.find(path)
    if e is None:
        return None
    d = e.find("Data")
    return d.text if d is not None else e.text


class Client:
    def __init__(self):
        self.nonce = ""
        self.auth = ""
        self.session = ""
        self.ap = AuthParams(os.path.join(HERE, "auth_param.dat"))

    def authv(self):
        return f'FUS nonce="{self.nonce}", signature="{self.auth}", nc="", type="", realm=""'

    def req(self, name, body=""):
        cookie = f"JSESSIONID={self.session};SESSION={self.session}"
        r = requests.post(FUS + name, data=body.encode(), timeout=60, headers={
            "Authorization": self.authv(), "User-Agent": UA,
            "Cookie": cookie, "Set-Cookie": cookie,
        })
        n = r.headers.get("NONCE")
        if n:
            self.nonce = n
            self.auth = self.ap.block(n[:16].encode()).hex()
        sc = r.headers.get("Set-Cookie", "")
        for part in sc.split(","):
            part = part.strip()
            for key in ("JSESSIONID=", "SESSION="):
                if part.startswith(key):
                    self.session = part[len(key):].split(";")[0]
        return r

    def generate_nonce(self):
        self.req("NF_SmartDownloadGenerateNonce.do")
        if not self.nonce:
            sys.exit("no nonce from server")

    def binary_inform(self, fw, model, region):
        m = ET.Element("FUSMsg")
        h = el(m, "FUSHdr")
        el(h, "ProtoVer", "1"); el(h, "SessionID", "0"); el(h, "MsgID", "1")
        b = el(m, "FUSBody")
        p = el(b, "Put")
        el(p, "CmdID", "1")
        data(p, "REQUEST_TYPE", "2")
        data(p, "BINARY_SW_VERSION", fw)
        data(p, "DEVICE_SN_NUMBER", "")
        data(p, "BINARY_LOCAL_CODE", region)
        data(p, "BINARY_MODEL_NAME", model)
        data(p, "ACCESS_MODE", "1")
        data(p, "BINARY_NATURE", "1")
        data(p, "LOGIC_CHECK", logic_check(fw, self.nonce))
        cl = el(p, "CLIENT_LANGUAGE")
        el(cl, "Type", "String"); el(cl, "Type", "ISO 3166-1-alpha-3"); el(cl, "Data", "1033")
        g = el(b, "Get")
        el(g, "CmdID", "2")
        el(g, "BINARY_SW_VERSION")
        r = self.req("NF_SmartDownloadBinaryInform.do", ET.tostring(m, encoding="unicode"))
        return ET.fromstring(r.text)

    def binary_init(self, name, fwver, region, model_type):
        m = ET.Element("FUSMsg")
        h = el(m, "FUSHdr")
        el(h, "ProtoVer", "1"); el(h, "SessionID", "0"); el(h, "MsgID", "1")
        p = el(el(m, "FUSBody"), "Put")
        data(p, "BINARY_NAME", name)
        if fwver:
            data(p, "BINARY_SW_VERSION", fwver)
        data(p, "DEVICE_LOCAL_CODE", region)
        if model_type:
            data(p, "DEVICE_MODEL_TYPE", model_type)
        data(p, "LOGIC_CHECK", logic_check(name[len(name) - 25:len(name) - 9], self.nonce))
        r = self.req("NF_SmartDownloadBinaryInitForMass.do", ET.tostring(m, encoding="unicode"))
        return r.text


def latest_version(model, region):
    r = requests.get(f"https://fota-cloud-dn.ospserver.net/firmware/{region}/{model}/version.xml",
                     headers={"User-Agent": "Kiss2.0_FUS"}, timeout=30)
    vc = ET.fromstring(r.text).find("firmware/version/latest").text.split("/")
    if len(vc) == 3:
        vc.append(vc[0])
    if vc[2] == "":
        vc[2] = vc[0]
    return "/".join(vc)


def main():
    model, region, serial, outdir = sys.argv[1:5]
    os.makedirs(outdir, exist_ok=True)
    fw = latest_version(model, region)
    print("latest:", fw)

    c = Client()
    c.generate_nonce()
    x = c.binary_inform(fw.upper(), model, region)
    status = x.findtext("FUSBody/Results/Status")
    print("inform status:", status)
    if status not in ("200", "S00"):
        sys.exit(ET.tostring(x, encoding="unicode")[:2000])

    put = "FUSBody/Put/"
    size = int(find_data(x, put + "BINARY_BYTE_SIZE"))
    name = find_data(x, put + "BINARY_NAME")
    path = find_data(x, put + "MODEL_PATH")
    crc = find_data(x, put + "BINARY_CRC")
    fwver = find_data(x, put + "BINARY_SW_VERSION")
    model_type = find_data(x, put + "DEVICE_MODEL_TYPE")
    res_ver = find_data(x, "FUSBody/Results/LATEST_FW_VERSION") or find_data(x, "FUSBody/Results/BINARY_SW_VERSION")
    logic_val = find_data(x, put + "LOGIC_VALUE_FACTORY") or find_data(x, put + "LOGIC_VALUE_HOME")
    key = hashlib.md5(logic_check(res_ver, logic_val).encode()).digest() if res_ver and logic_val else None
    print(f"file: {name}  {size / 2**30:.2f} GiB  crc={crc}")

    print("init:", ET.fromstring(c.binary_init(name, fwver, region, model_type)).findtext("FUSBody/Results/Status"))

    enc = os.path.join(outdir, name)
    have = os.path.getsize(enc) if os.path.exists(enc) else 0
    if have < size:
        hdr = {"Authorization": c.authv(), "User-Agent": UA, "Cache-Control": "no-cache"}
        if have:
            hdr["Range"] = f"bytes={have}-"
        with requests.get(DL + path + name, headers=hdr, stream=True, timeout=120) as r:
            r.raise_for_status()
            with open(enc, "ab") as f:
                done = have
                last = 0
                for chunk in r.iter_content(1 << 20):
                    f.write(chunk)
                    done += len(chunk)
                    if done - last >= 100 << 20:
                        print(f"  {done / 2**30:.2f} / {size / 2**30:.2f} GiB", flush=True)
                        last = done
    print("downloaded")

    if crc:
        c32 = 0
        with open(enc, "rb") as f:
            while b := f.read(1 << 22):
                c32 = zlib.crc32(b, c32)
        print("crc ok" if c32 == int(crc) else f"CRC MISMATCH {c32} != {crc}")

    if name.endswith(".enc4") and key:
        out = enc[:-5]
        dec = Cipher(algorithms.AES(key), modes.ECB()).decryptor()
        with open(enc, "rb") as fi, open(out, "wb") as fo:
            while b := fi.read(1 << 22):
                fo.write(dec.update(b))
            fo.write(dec.finalize())
        print("decrypted ->", out)


if __name__ == "__main__":
    main()
