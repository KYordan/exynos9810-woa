#!/usr/bin/env python3
"""Plan the S10e dual-boot GPT: shrink `userdata` (iOS HFS root) and add a `windows` partition after it.

Reads the two GPT dumps taken from the phone (primary = LBA 0..5, backup = last 5 LBAs, 4096-byte sectors),
checks every CRC, and writes the new primary/backup images next to them. It never touches a device: the
images are flashed from TWRP in a separate, explicit step.

    python -I gpt_split.py PRIMARY BACKUP --userdata-gib 40 --out-dir DIR
    python -I gpt_split.py PRIMARY BACKUP --list
"""
import argparse
import binascii
import struct
import sys
import uuid
from pathlib import Path

SECTOR = 4096
BASIC_DATA = uuid.UUID("EBD0A0A2-B9E5-4433-87C0-68B6B72699C7")
HDR = struct.Struct("<8sIIIIQQQQ16sQIII")   # 92-byte GPT header
ENT = struct.Struct("<16s16sQQQ72s")         # 128-byte partition entry


def crc(data):
    return binascii.crc32(data) & 0xFFFFFFFF


def header(raw):
    f = HDR.unpack_from(raw)
    keys = ("sig", "rev", "size", "crc", "res", "my", "alt", "first", "last", "guid", "ent_lba", "count", "esize",
            "ent_crc")
    h = dict(zip(keys, f))
    # Samsung writes HeaderSize = 512 (the spec allows 92..sector size); the CRC covers HeaderSize bytes.
    if h["sig"] != b"EFI PART" or not 92 <= h["size"] <= SECTOR or h["esize"] != 128:
        raise SystemExit("not a GPT header with 128-byte entries")
    check = bytearray(raw[:h["size"]]); check[16:20] = b"\0\0\0\0"
    if crc(check) != h["crc"]:
        raise SystemExit(f"header CRC mismatch at LBA {h['my']}")
    h["raw"] = bytes(raw[:SECTOR])
    return h


def pack_header(h):
    """Only the partition-array CRC changes; every other byte of the old sector (reserved area included) is kept."""
    raw = bytearray(h["raw"])
    struct.pack_into("<I", raw, 88, h["ent_crc"])
    struct.pack_into("<I", raw, 16, 0)
    struct.pack_into("<I", raw, 16, crc(raw[:h["size"]]))
    return bytes(raw)


def entries(raw, count):
    out = []
    for i in range(count):
        t, u, first, last, attr, name = ENT.unpack_from(raw, i * 128)
        out.append({"type": uuid.UUID(bytes_le=t), "uuid": uuid.UUID(bytes_le=u), "first": first, "last": last,
                    "attr": attr, "name": name.decode("utf-16-le").rstrip("\0")})
    return out


def pack_entries(ents, count):
    raw = bytearray(count * 128)
    for i, e in enumerate(ents):
        if e["type"].int == 0:
            continue
        name = e["name"].encode("utf-16-le")[:72].ljust(72, b"\0")
        ENT.pack_into(raw, i * 128, e["type"].bytes_le, e["uuid"].bytes_le, e["first"], e["last"], e["attr"], name)
    return bytes(raw)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("primary", type=Path)
    p.add_argument("backup", type=Path)
    p.add_argument("--list", action="store_true")
    p.add_argument("--userdata-gib", type=int, default=40)
    p.add_argument("--hfs-bytes", type=int, default=32 << 30, help="iOS root HFS volume size (must still fit)")
    p.add_argument("--out-dir", type=Path)
    a = p.parse_args()

    pri, bak = a.primary.read_bytes(), a.backup.read_bytes()
    if len(pri) != 6 * SECTOR or len(bak) != 5 * SECTOR:
        raise SystemExit("expected primary = 6 sectors, backup = 5 sectors of 4096 bytes")
    ph = header(pri[SECTOR:2 * SECTOR])
    bh = header(bak[4 * SECTOR:])
    pent_raw = pri[2 * SECTOR:2 * SECTOR + ph["count"] * 128]
    bent_raw = bak[:bh["count"] * 128]
    if crc(pent_raw) != ph["ent_crc"] or crc(bent_raw) != bh["ent_crc"]:
        raise SystemExit("partition array CRC mismatch")
    if pent_raw != bent_raw or ph["alt"] != bh["my"] or bh["alt"] != ph["my"] or ph["ent_lba"] != 2 \
            or bh["ent_lba"] != bh["my"] - 4 or ph["count"] * 128 != 4 * SECTOR:
        raise SystemExit("primary and backup GPT disagree or have an unexpected layout")
    ents = entries(pent_raw, ph["count"])
    used = [(i, e) for i, e in enumerate(ents) if e["type"].int]
    print(f"GPT ok: {len(used)}/{ph['count']} entries, usable LBA {ph['first']}..{ph['last']}, backup header LBA "
          f"{bh['my']}, disk GUID {uuid.UUID(bytes_le=ph['guid'])}")
    if a.list:
        for i, e in used:
            size = (e["last"] - e["first"] + 1) * SECTOR
            print(f"  {i + 1:3} {e['name']:<12} {e['first']:>10}..{e['last']:<10} {size / 2**20:12.1f} MiB  {e['type']}")
        return

    names = [e["name"].lower() for _, e in used]
    if names.count("userdata") != 1 or "windows" in names:
        raise SystemExit("need exactly one userdata and no windows partition yet")
    index, user = next((i, e) for i, e in used if e["name"].lower() == "userdata")
    if any(e["first"] > user["last"] for _, e in used):
        raise SystemExit("userdata is not the last partition")
    lbas = (a.userdata_gib << 30) // SECTOR
    if lbas * SECTOR < a.hfs_bytes or lbas >= user["last"] - user["first"] + 1:
        raise SystemExit("new userdata size must hold the HFS volume and be smaller than today")
    if ((user["first"] + lbas) * SECTOR) % (1 << 20):
        raise SystemExit("windows partition would not start on a 1 MiB boundary")
    free = next(i for i, e in enumerate(ents) if e["type"].int == 0)
    win = {"type": BASIC_DATA, "uuid": uuid.uuid4(), "first": user["first"] + lbas, "last": user["last"],
           "attr": 0, "name": "windows"}
    old_last = user["last"]
    user = dict(user, last=user["first"] + lbas - 1)
    ents[index] = user
    ents[free] = win
    new_raw = pack_entries(ents, ph["count"])
    if new_raw[:index * 128] != pent_raw[:index * 128]:
        raise SystemExit("internal error: entries before userdata changed")
    ent_crc = crc(new_raw)
    nph = pack_header(dict(ph, ent_crc=ent_crc))
    nbh = pack_header(dict(bh, ent_crc=ent_crc))
    new_pri = pri[:SECTOR] + nph + new_raw
    new_bak = new_raw + nbh
    # Re-parse what we built, as the phone will.
    header(new_pri[SECTOR:2 * SECTOR]); header(new_bak[4 * SECTOR:])
    print(f"userdata (entry {index + 1}): LBA {user['first']}..{old_last} -> ..{user['last']} "
          f"({lbas * SECTOR / 2**30:.1f} GiB, HFS {a.hfs_bytes / 2**30:.1f} GiB fits)")
    print(f"windows  (entry {free + 1}, new sda{free + 1}): LBA {win['first']}..{win['last']} "
          f"({(win['last'] - win['first'] + 1) * SECTOR / 2**30:.2f} GiB, basic data, {win['uuid']})")
    if a.out_dir:
        a.out_dir.mkdir(parents=True, exist_ok=True)
        (a.out_dir / "gpt-primary-new.bin").write_bytes(new_pri)
        (a.out_dir / "gpt-backup-new.bin").write_bytes(new_bak)
        print(f"wrote {a.out_dir / 'gpt-primary-new.bin'} and {a.out_dir / 'gpt-backup-new.bin'}")


if __name__ == "__main__":
    main()
