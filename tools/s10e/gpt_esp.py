#!/usr/bin/env python3
"""Make the S10e `cache` partition (entry 28, the dual boot's ESP) an EFI System Partition named `esp`.

Windows finds its system partition only by the EFI System type; Setup's Sysprep BCD step failed with "Failed to get
system partition" while CACHE was Basic Data. B2LUFS retypes a partition *named* cache to Basic Data in its Windows
view, so the entry is also renamed. Only entry 28's type and name change; both GPT copies get new CRCs.

    python -I gpt_esp.py PRIMARY BACKUP OUT_DIR
"""
import importlib.util
import sys
import uuid
from pathlib import Path

spec = importlib.util.spec_from_file_location("g", Path(__file__).with_name("gpt_split.py"))
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)

ESP = uuid.UUID("C12A7328-F81F-11D2-BA4B-00A0C93EC93B")
INDEX = 27                       # entry 28
FIRST, LAST = 1983488, 2137087   # sda28 in 4096-byte LBAs


def main():
    pri_path, bak_path, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    pri, bak = pri_path.read_bytes(), bak_path.read_bytes()
    ph = g.header(pri[g.SECTOR:2 * g.SECTOR])
    bh = g.header(bak[4 * g.SECTOR:])
    raw = pri[2 * g.SECTOR:2 * g.SECTOR + ph["count"] * 128]
    if g.crc(raw) != ph["ent_crc"] or raw != bak[:bh["count"] * 128]:
        raise SystemExit("GPT entries invalid or primary/backup differ")
    ents = g.entries(raw, ph["count"])
    e = ents[INDEX]
    if e["name"].lower() != "cache" or (e["first"], e["last"]) != (FIRST, LAST):
        raise SystemExit(f"entry 28 is not the expected cache partition: {e}")
    ents[INDEX] = dict(e, type=ESP, name="esp", attr=0)
    new_raw = g.pack_entries(ents, ph["count"])
    changed = [i for i in range(0, len(raw)) if raw[i] != new_raw[i]]
    if not changed or min(changed) < INDEX * 128 or max(changed) >= (INDEX + 1) * 128:
        raise SystemExit("internal error: bytes outside entry 28 changed")
    ent_crc = g.crc(new_raw)
    new_pri = pri[:g.SECTOR] + g.pack_header(dict(ph, ent_crc=ent_crc)) + new_raw
    new_bak = new_raw + g.pack_header(dict(bh, ent_crc=ent_crc))
    g.header(new_pri[g.SECTOR:2 * g.SECTOR]); g.header(new_bak[4 * g.SECTOR:])
    out.mkdir(parents=True, exist_ok=True)
    (out / "gpt-primary-esp.bin").write_bytes(new_pri)
    (out / "gpt-backup-esp.bin").write_bytes(new_bak)
    print(f"entry 28: cache/{e['type']} -> esp/{ESP}; {len(changed)} entry bytes changed; wrote {out}")


if __name__ == "__main__":
    main()
