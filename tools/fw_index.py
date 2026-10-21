#!/usr/bin/env python3
"""Build firmware/extracted/INDEX.md and the linux-firmware staging tree.

Input: the tree populated by tools/extract-stock-fw.sh (OUT = firmware/extracted):
  OUT/vendor/firmware/...      /vendor/firmware from super.img
  OUT/vendor/etc/...           firmware-like data under /vendor/etc
  OUT/vendor/tee/...           Trustonic/TEEgris trusted apps
  OUT/kernel-builtin/...       CONFIG_EXTRA_FIRMWARE + bbd patch from the stock boot.img kernel
  OUT/hints/...                init rc / vintf / fstab / build.prop (reference only)
Output:
  OUT/INDEX.md
  OUT/linux-firmware/lib/firmware/...   files under the names mainline drivers request
                                        (plus samsung/gtactive3wifi/<stock name> for the rest)

Every hardware attribution below cites the stock DT (firmware/stock/*.dts), the
Samsung 4.9 reference tree (src/samsung-9810-ref) or mainline (src/linux) by file:line.

usage: python3 -I fw_index.py OUT
"""
import hashlib
import os
import re
import shutil
import sys

OUT = os.path.abspath(sys.argv[1])
STAGE = os.path.join(OUT, "linux-firmware", "lib", "firmware")
SG = "samsung/gtactive3wifi/"  # namespace for blobs without a mainline consumer yet

BRCM_MAINLINE = ("mainline brcmfmac has no BCM4375 entry (src/linux drivers/net/wireless/broadcom/"
                 "brcm80211/brcmfmac/pcie.c:52-74, 110-111); needs BRCMF_FW_CLM_DEF(4375B1, "
                 "\"brcmfmac4375b1-pcie\"), chip id 0x4375 (samsung-9810-ref drivers/net/wireless/"
                 "bcmdhd_100_15/include/bcmdevs.h:520), PCI ids 0x4475/0x4476/0x4477 (bcmdevs.h:299-301) "
                 "and a TCM rambase of 0x170000 in brcmf_chip_tcm_rambase() (src/linux brcmfmac/chip.c:"
                 "710-755; dhd uses CR4_4369_RAM_BASE for 4375: dhd_pcie.c:1607-1609, include/sbchipc.h:3285)")
BT_NOTE = ("btbcm.c:494-532 has no BCM4375B1 subver entry, so mainline asks for "
           "brcm/BCM.samsung,gtactive3wifi.hcd then brcm/BCM.hcd (src/linux drivers/bluetooth/"
           "btbcm.c:661-667); with an entry it would try brcm/BCM4375B1.samsung,gtactive3wifi.hcd "
           "first (btbcm.c:650-655)")

# (regex on path relative to OUT, hardware, stock consumer + source, mainline note, [staged names])
RULES = [
    # ---- Wi-Fi: Broadcom BCM4375 B1, PCIe on pcie1 0x116b0000 (HARDWARE.md) ----
    (r"vendor/firmware/bcmdhd_sta\.bin_b1$", "Wi-Fi BCM4375B1 (PCIe, pcie1)",
     "dhd STA firmware 4375b1-roml 18.41.117 (FW-TAG string in file); dhd appends the _b1 fw_ext "
     "from bcm4375_naming_table (samsung-9810-ref bcmdhd_100_15/dhd_pcie.c:2342-2362, 2620-2622)",
     BRCM_MAINLINE + ". Staged under the board-specific name only: brcmfmac tries "
     "<fw>.<board_type>.<ext> before <fw>.<ext> for every item (src/linux brcmfmac/firmware.c:"
     "655-675, 777-786), so no generic name can clash with linux-firmware",
     ["brcm/brcmfmac4375b1-pcie.samsung,gtactive3wifi.bin"]),
    (r"vendor/firmware/bcmdhd_clm\.blob$", "Wi-Fi BCM4375B1 regulatory (CLM)",
     "dhd clm_path", "brcmfmac loads <fw>.clm_blob (pcie.c BRCMF_FW_CLM_DEF)",
     ["brcm/brcmfmac4375b1-pcie.samsung,gtactive3wifi.clm_blob"]),
    (r"vendor/firmware/nvram\.txt_CS01_semco_b1$", "Wi-Fi BCM4375B1 NVRAM, SEMCO SWB-E43 module",
     "selected when the chip OTP module tag is e43_cs51/e43_cs53 (dhd_pcie.c:2350-2351); header "
     "line 1 says 'SWB-E43 R03 SEMCO nvram_200831_Active3-EU_US' -> most likely this tablet's module",
     "brcmfmac board nvram = <fw>.<DT root compatible>.txt; root compatible is samsung,gtactive3wifi "
     "(src/linux arch/arm64/boot/dts/exynos/exynos9810-gtactive3wifi.dts:21). VERIFY module tag at runtime. "
     "Contains the Broadcom placeholder macaddr=00:90:4c:30:50:01 (line 11): set the real MAC "
     "from /efs/wifi/.mac.info outside /usr (systemd .link MACAddress= or DT local-mac-address).",
     ["brcm/brcmfmac4375b1-pcie.samsung,gtactive3wifi.txt"]),
    (r"vendor/firmware/nvram\.txt_1rh_es43_b1$", "Wi-Fi BCM4375B1 NVRAM, Murata 1RH ES4.3 module",
     "selected when OTP tag is 1rh_es43 (dhd_pcie.c:2361; dhd_custom_cis.c:829); header says "
     "'Hubble Y2 EU Murata' (generic S20-family nvram)",
     "alternative; swap in as brcmfmac4375b1-pcie.samsung,gtactive3wifi.txt if the module is Murata",
     [SG + "wifi/nvram.txt_1rh_es43_b1"]),
    (r"vendor/firmware/bcmdhd_mfg\.bin_b1$", "Wi-Fi BCM4375B1 manufacturing/test firmware",
     "dhd factory mode", "not needed", []),
    (r"vendor/firmware/bcmdhd_mon\.bin_b1$", "Wi-Fi BCM4375B1 monitor-mode firmware",
     "dhd monitor mode", "not needed for normal operation", [SG + "wifi/bcmdhd_mon.bin_b1"]),
    # ---- Bluetooth: BCM4375B1 on UART1 ----
    (r"vendor/firmware/bcm4375B1_semco_sem\.hcd$", "Bluetooth BCM4375B1 patchram (SEMCO 'sem' module)",
     "libbt-vendor picks by /data/vendor/conn/.cid.info (strings in vendor/lib64/libbt-vendor.so: "
     "'semco_sem_e43_cs51', '_semco_sem.hcd'); UART /dev/ttySAC1 (vendor/etc/init/init.exynos9810.rc:798)",
     BT_NOTE + ". Staged as default because the Wi-Fi SEMCO module tag is semco_sem_e43_cs5x; VERIFY.",
     ["brcm/BCM.samsung,gtactive3wifi.hcd", "brcm/BCM4375B1.samsung,gtactive3wifi.hcd"]),
    (r"vendor/firmware/bcm4375B1_semco\.hcd$", "Bluetooth BCM4375B1 patchram (SEMCO, older cid)",
     "libbt-vendor '_semco.hcd'", "alternative", [SG + "bt/bcm4375B1_semco.hcd"]),
    (r"vendor/firmware/bcm4375B1_murata\.hcd$", "Bluetooth BCM4375B1 patchram (Murata module)",
     "libbt-vendor '_murata.hcd'", "alternative (use with the Murata nvram)", [SG + "bt/bcm4375B1_murata.hcd"]),
    # ---- Touch / pen / grip (kernel built-in in stock) ----
    (r"kernel-builtin/tsp_himax/hx83102e_gtactive3\.bin$", "Touch Himax HX83102E TDDI (spi21.0)",
     "CONFIG_EXTRA_FIRMWARE in stock kernel; himax,fw-path (firmware/stock/dtbo-4.dts:2394). Chip has "
     "flash ('Sense on re-map off, run flash' in stock kernel strings): file is only for in-field update",
     "mainline driver does not need it to run; keep for a future update path",
     [SG + "tsp_himax/hx83102e_gtactive3.bin"]),
    (r"kernel-builtin/epen/w9019_gtactive3\.bin$", "S Pen digitiser Wacom W9019 (i2c 6-0056)",
     "CONFIG_EXTRA_FIRMWARE; wacom,fw_path, wacom,ic_type 0x233b (dtbo-4.dts:2432-2433)",
     "mainline wacom_i2c does not flash firmware; reference only", [SG + "epen/w9019_gtactive3.bin"]),
    (r"kernel-builtin/exynos9810_acpm_tmu\.fw$", "ACPM (APM Cortex-M) TMU plugin",
     "CONFIG_EXTRA_FIRMWARE; acpm_tmu node (firmware/stock/stock-0.dts:7906)",
     "mainline exynos TMU driver talks to TMU registers directly; ACPM firmware itself is loaded by "
     "S-Boot. Reference only", [SG + "exynos9810_acpm_tmu.fw"]),
    (r"kernel-builtin/bbd/.*\.patch$", "GNSS + sensor hub Broadcom BCM4775 B0 (AsicVersion 0x004775B0), spi20",
     "embedded bbd_patch[] served as /dev/bbd_patch (samsung-9810-ref drivers/sensorhub/brcm/bbdpl/"
     "bbd.c:131-156); lhd loads it (vendor/etc/sensor/lhd.conf 'LhePatch=/dev/bbd_patch'); DT "
     "compatible ssp,BCM4773 (dtbo-4.dts:4768)",
     "no mainline driver (would need a bbd/SSP port + userspace lhd); reference only",
     [SG + "bbd/bcm_sensorhub_a1.patch"]),
    (r"vendor/firmware/a96t365_gtactive3wifi\.bin$", "Grip/SAR sensor ABOV A96T365 (i2c 7-0020)",
     "a96t3x6,fw_path (dtbo-4.dts:2924)", "no mainline driver; reference only",
     [SG + "a96t365_gtactive3wifi.bin"]),
    # ---- NFC ----
    (r"vendor/firmware/nfc/sec_s3nrn4v_firmware\.bin$", "NFC Samsung S3NRN4V (i2c 5-0027)",
     "loaded by userspace NFC HAL (vendor/etc/libnfc-sec-vendor.conf:31-32)",
     "mainline s3fwrn5 covers S3FWRN5/S3FWRN82 only; reference only", [SG + "nfc/sec_s3nrn4v_firmware.bin"]),
    (r"vendor/etc/nfc/sec_s3nrn4v_(hw|sw)reg\.bin$", "NFC Samsung S3NRN4V RF/SW register tables",
     "libnfc-sec-vendor.conf:38-44", "reference only", []),
    # ---- Audio ----
    (r"vendor/firmware/calliope_(sram|dram|iva)\.bin$", "Audio ABOX DSP (Cortex-A7, abox@17c50000)",
     "request_firmware calliope_*.bin (samsung-9810-ref sound/soc/samsung/abox/abox.c:5110-5135); "
     "node firmware/stock/stock-0.dts:7236", "no mainline ABOX driver; needed only for an ABOX port",
     [SG + "abox/{name}"]),
    (r"vendor/firmware/(AP|APBargeIn|APBiBF|APDV|APSV)_AUDIO_SLSI\.bin$", "Audio ABOX solution binaries (SLSI effects)",
     "abox ext_bin samsung,name (stock-0.dts:7488-7524)", "no mainline consumer", [SG + "abox/{name}"]),
    (r"vendor/firmware/(rtdsp|rtdsp_param|SoundBoosterParam)\.bin$", "Audio ABOX ext bins for Richtek RT5510 adaptation",
     "abox ext_bin (dtbo-4.dts:1465-1483), abox-adaptation-richtek (dtbo-4.dts:1491)",
     "no mainline consumer", [SG + "abox/{name}"]),
    (r"vendor/firmware/spkamp\.bin$", "Audio speaker amp tuning (RT5510, i2c 4-0034, dtbo-4.dts:1549)",
     "consumer not in DT/kernel strings; likely audio HAL", "mainline rt5510 driver: none upstream; reference",
     [SG + "audio/spkamp.bin"]),
    (r"vendor/firmware/param_ti\.bin$", "Audio TI TAS2562 amp parameters (hw_rev 5 boards, HARDWARE.md)",
     "audio HAL (mixer_gains_ti.xml / mixer_paths_ti.xml)", "not used on hw_rev 4", []),
    (r"vendor/firmware/vts\.bin$", "Voice Trigger System (VTS) Cortex-M (vts@13870000, stock-0.dts:8601)",
     "request_firmware \"vts.bin\" (samsung-9810-ref sound/soc/samsung/vts/vts.c:2626)",
     "no mainline driver", [SG + "vts.bin"]),
    (r"vendor/firmware/dbmd8_va_fw\.bin$", "DSP Group DBMD8 voice DSP (spi17.0)",
     "va-firmware-name (dtbo-4.dts:1317)", "no mainline driver", [SG + "dbmd8_va_fw.bin"]),
    (r"vendor/firmware/(dax_param\.bin)$", "Audio Dolby DAX parameters", "userspace audio HAL", "userspace only", []),
    # ---- Multimedia / camera / accelerators ----
    (r"vendor/firmware/mfc_fw\.bin$", "Video codec MFC (mfc0@178d0000, compatible samsung,mfc-v6 in stock-0.dts:6209-6210)",
     "MFC_FW_NAME (samsung-9810-ref drivers/media/platform/exynos/mfc/s5p_mfc_common.h:53)",
     "mainline s5p-mfc has no Exynos9810 variant (fw names s5p-mfc*.fw, src/linux drivers/media/"
     "platform/samsung/s5p-mfc/s5p_mfc.c:1557-1703); staged under stock name for a future port",
     [SG + "mfc_fw.bin"]),
    (r"vendor/firmware/fimc_is_(lib|rta)\.bin$", "Camera ISP (FIMC-IS) DDK / RTA",
     "FIMC_IS_ISP_LIB (samsung-9810-ref drivers/media/platform/exynos/fimc-is2/include/fimc-is-binary.h:53); "
     "fimc_is_lib node stock-0.dts:118", "no mainline driver", [SG + "camera/{name}"]),
    (r"vendor/firmware/setfile_3l6\.bin$", "Rear camera Samsung S5K3L6 tuning (i2c 0-002d)",
     "fimc-is sensor module setfile", "no mainline driver", [SG + "camera/setfile_3l6.bin"]),
    (r"vendor/firmware/setfile_gc5035\.bin$", "Front camera GalaxyCore GC5035 tuning (i2c 1-0037)",
     "fimc-is sensor module setfile", "no mainline driver", [SG + "camera/setfile_gc5035.bin"]),
    (r"vendor/firmware/iva20_rt-lhotse\.bin$", "IVA 2.0 vision accelerator runtime (iva@17200000, stock-0.dts:8649)",
     "IVA driver/HAL (vendor.samsung_slsi.hardware.iva); 'lhotse' = Exynos 9810", "no mainline driver", []),
    (r"vendor/firmware/(WithLightFixNoBN\.SDNNmodel|tracker_cfg\.json|pp_cfg\.json|default_configuration\.hfd\.cfg\.json)$",
     "Camera AI models/configs (userspace)", "camera HAL", "userspace only", []),
    # ---- GNSS config ----
    (r"vendor/etc/gnss/.*", "GNSS BCM4775 config/certificates", "gpsd/lhd", "userspace only", []),
    (r"vendor/etc/sensors?/.*", "Sensor HAL config (sensorhub via BCM4775 'bbd')", "sensors HAL", "reference", []),
    (r"vendor/etc/wifi/.*", "Wi-Fi supplicant/indoor channel config", "wpa_supplicant", "reference", []),
    # ---- TEE ----
    (r"vendor/tee/.*", "Trusted apps (TEEgris/Kinibi) for fingerprint, keymaster, DRM etc.",
     "teegris daemon (vendor/etc/init/teegris.rc)", "not usable on mainline", []),
]


def classify(rel):
    for pat, hw, stock, ml, stage in RULES:
        if re.search(pat, rel):
            return hw, stock, ml, stage
    return None


def sha256(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        while b := f.read(1 << 20):
            h.update(b)
    return h.hexdigest()


def walk(top):
    for dp, dn, fn in os.walk(top):
        dn.sort()
        for n in sorted(fn):
            yield os.path.join(dp, n)


if os.path.isdir(os.path.join(OUT, "linux-firmware")):
    shutil.rmtree(os.path.join(OUT, "linux-firmware"))

rows, unknown, staged = [], [], []
for top in ("vendor", "kernel-builtin"):
    for p in walk(os.path.join(OUT, top)):
        rel = os.path.relpath(p, OUT)
        if os.path.islink(p):
            continue
        c = classify(rel)
        size, digest = os.path.getsize(p), sha256(p)
        if not c:
            unknown.append((rel, size, digest))
            continue
        hw, stock, ml, stage = c
        names = [s.replace("{name}", os.path.basename(rel)) for s in stage]
        for n in names:
            dst = os.path.join(STAGE, n)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(p, dst)
            staged.append((n, rel))
        rows.append((rel, size, digest, hw, stock, ml, names))

hints = sorted(os.path.relpath(p, OUT) for p in walk(os.path.join(OUT, "hints")))
src = open(os.path.join(OUT, "SOURCE.txt")).read().strip() if os.path.exists(os.path.join(OUT, "SOURCE.txt")) else "?"

md = []
w = md.append
w("# SM-T570 (gtactive3wifi) stock firmware: extracted blobs\n")
w("Generated by `tools/fw_index.py` (run from `tools/extract-stock-fw.sh`). Proprietary: never commit "
  "anything in this directory.\n")
w("## Source\n")
w("```\n" + src + "\n```\n")
w("## Summary\n")
w("- Wi-Fi/BT: **Broadcom BCM4375 B1** (not BCM4361 as HARDWARE.md guessed): FW-TAG `4375b1-roml/"
  "config_pcie_release Version=18.41.117`, BT `bcm4375B1_*.hcd`. Two module variants ship (SEMCO SWB-E43, "
  "Murata 1RH); stock dhd chooses by OTP module tag (samsung-9810-ref bcmdhd_100_15/dhd_pcie.c:2342-2362, "
  "2610-2622). "
  "Mainline brcmfmac and btbcm need a BCM4375 entry first.")
w("- Touch HX83102E and Wacom W9019 firmware were **built into the stock kernel** (CONFIG_EXTRA_FIRMWARE), "
  "not in /vendor; extracted from boot.img via the RELA table (`tools/builtin_fw_extract.py`).")
w("- GNSS + sensor hub is a **BCM4775 B0** behind Samsung's `bbd` driver; its patch is embedded in the kernel too.")
w("- No vendor kernel modules: `/vendor/lib/modules`, `/vendor_dlkm` and `/odm_dlkm` are empty (stock kernel is "
  "monolithic; `vendor/etc/init/wifi_brcm.rc:2` modprobes dhd.ko from a path that does not exist).")
w("- No GPU firmware (Mali-G72 Bifrost needs none; panfrost). No modem (Wi-Fi-only tablet). No display "
  "firmware (panel init sequences live in the stock DT/kernel).")
w("- MAC addresses live on EFS (sda1): Wi-Fi `/efs/wifi/.mac.info` (vendor/etc/init/wifi.rc:41), BT "
  "`/efs/bluetooth/bt_addr` (init.exynos9810.rc:801).")
w("")
w("## Mainline firmware names (staged in `linux-firmware/lib/firmware/`)\n")
w("| /lib/firmware name | from |")
w("|---|---|")
for n, rel in staged:
    if not n.startswith(SG):
        w(f"| `{n}` | `{rel}` |")
w("\nEverything else with a hardware owner is staged under `" + SG + "<stock name>` so a package can "
  "install it without clashing with linux-firmware.\n")
w("## Files\n")
w("| File | Size | SHA-256 | Hardware | Stock consumer (source) | Mainline / Linux name |")
w("|---|---:|---|---|---|---|")
for rel, size, digest, hw, stock, ml, names in rows:
    nm = "<br>".join(f"`{n}`" for n in names) or "(not staged)"
    w(f"| `{rel}` | {size} | `{digest}` | {hw} | {stock} | {ml}<br>{nm} |")
if unknown:
    w("\n## Unclassified files\n")
    w("| File | Size | SHA-256 |")
    w("|---|---:|---|")
    for rel, size, digest in unknown:
        w(f"| `{rel}` | {size} | `{digest}` |")
w("\n## Hardware hints (reference copies, not firmware)\n")
w(f"{len(hints)} files under `hints/`: vendor init rc, vintf manifests, ueventd.rc, fstab, build.prop, audio "
  "mixer paths/policies (useful for ALSA UCM), ODM build.prop.\n")
for h in hints:
    w(f"- `{h}`")
w("")
with open(os.path.join(OUT, "INDEX.md"), "w") as f:
    f.write("\n".join(md) + "\n")
print(f"INDEX.md: {len(rows)} classified, {len(unknown)} unclassified, {len(staged)} staged, {len(hints)} hints")
