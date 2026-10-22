#!/usr/bin/env python3
"""The project's image channels, from the GitHub Pages index (releases.json,
schema 1) or, if that is not there, from the GitHub releases API.

usage:
  releases.py from-api API.json DLBASE > index.json   build an index from the API
  releases.py channels index.json        TSV: id ui flavour verified prerelease latest title
  releases.py files index.json CHANNEL [VERSION]
                                         TSV: kind name size sha256 url (newest version by default)
  releases.py newest index.json          the newest version of any channel

Only the signed SHA256SUMS of a release is trusted for hashes; the sha256
fields here are for display and an early mismatch check.
"""
import json
import re
import sys

CHANNELS = {
    "samsung-gtactive3wifi_phosh_edge": ("phosh", "release", "Phosh"),
    "samsung-gtactive3wifi_gnome_edge": ("gnome", "release", "GNOME"),
    "samsung-gtactive3wifi_phosh_edge-dev": ("phosh", "dev", "Phosh (dev)"),
    "samsung-gtactive3wifi_gnome_edge-dev": ("gnome", "dev", "GNOME (dev)"),
}


def kind_of(name):
    if name in ("SHA256SUMS", "SHA256SUMS.gpg"):
        return "signature" if name.endswith(".gpg") else "manifest"
    if name.endswith(".efi"):
        return "uki"
    if ".usr-arm64-verity." in name:
        return "usr-verity"
    if ".usr-arm64." in name:
        return "usr"
    if "-sysext-" in name:
        return "sysext"
    if "-confext-" in name:
        return "confext"
    if re.search(r"_\d{8}\.raw(\.zst)?$", name):
        return "install-raw"
    return "other"


def vkey(v):
    return (len(v), v) if v.isdigit() else (0, v)


def from_api(api, dlbase):
    chans = []
    for r in api:
        tag = r.get("tag_name", "")
        if tag not in CHANNELS:
            continue
        ui, flavour, title = CHANNELS[tag]
        prefix = tag[:-4] if tag.endswith("-dev") else tag
        vers = {}
        for a in r.get("assets", []):
            n = a["name"]
            m = re.match(re.escape(prefix) + r"_(\d{8})\.", n)
            f = {"name": n, "size": a.get("size", 0), "sha256": "", "kind": kind_of(n),
                 "url": f"{dlbase}/{tag}/{n}"}
            if m:
                vers.setdefault(m.group(1), []).append(f)
            elif f["kind"] in ("manifest", "signature"):
                vers.setdefault("_common", []).append(f)
        common = vers.pop("_common", [])
        versions = [{"version": v, "date": "", "files": fs + common}
                    for v, fs in sorted(vers.items(), key=lambda x: vkey(x[0]), reverse=True)]
        chans.append({"id": tag, "ui": ui, "flavour": flavour, "title": title,
                      "description": "", "prerelease": bool(r.get("prerelease")),
                      "verified": flavour == "release" and not r.get("prerelease"),
                      "latest": versions[0]["version"] if versions else "",
                      "versions": versions})
    return {"schema": 1, "generated": "", "repo": "", "channels": chans}


def load(p):
    with open(p) as f:
        d = json.load(f)
    if d.get("schema") != 1:
        sys.exit(f"{p}: unknown index schema {d.get('schema')!r}")
    return d


def clean(s):
    return str(s).replace("\t", " ").replace("\n", " ")


def main():
    a = sys.argv[1:]
    if not a:
        sys.exit(__doc__)
    if a[0] == "from-api":
        with open(a[1]) as f:
            api = json.load(f)
        json.dump(from_api(api, a[2].rstrip("/")), sys.stdout, indent=1)
        return
    d = load(a[1])
    chans = d.get("channels", [])
    if a[0] == "channels":
        # Phosh (recommended) first, release before dev
        order = {"phosh": 0, "gnome": 1}
        chans = sorted(chans, key=lambda c: (order.get(c.get("ui"), 2),
                                             c.get("flavour") != "release"))
        for c in chans:
            if not c.get("latest"):
                continue
            print("\t".join(clean(x) for x in (
                c["id"], c.get("ui", "?"), c.get("flavour", "?"),
                "yes" if c.get("verified") else "no", "yes" if c.get("prerelease") else "no",
                c["latest"], c.get("title", c["id"]))))
    elif a[0] == "files":
        c = next((c for c in chans if c["id"] == a[2]), None)
        if not c:
            sys.exit(f"no channel {a[2]}")
        want = a[3] if len(a) > 3 else c.get("latest")
        v = next((v for v in c.get("versions", []) if v["version"] == want), None)
        if not v:
            sys.exit(f"{a[2]} has no version {want}")
        for f in v["files"]:
            print("\t".join(clean(x) for x in (f.get("kind", kind_of(f["name"])), f["name"],
                                               f.get("size", 0), f.get("sha256", ""), f["url"])))
    elif a[0] == "newest":
        vs = [v["version"] for c in chans for v in c.get("versions", []) if v.get("version")]
        if not vs:
            sys.exit(1)
        print(max(vs, key=vkey))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
