#!/usr/bin/env python3
"""Write the S10e Windows volume to the phone's `windows` partition (sda32) from TWRP.

Run in WSL after build-windows-image.ps1 attached the VHDX (wsl --mount --vhd ... --bare):

    python3 push-windows.py [--dry-run]

It finds the VHDX's Windows partition (exactly the size of sda32), reads NTFS $Bitmap (MFT record 6, ntfscat),
and writes only the 1 MiB blocks that hold used clusters, plus the first and last MiB (boot sector and its backup,
which $Bitmap does not cover). Each chunk (up to 64 MiB) is staged in TWRP's RAM (/tmp), written with dd at its
offset in sda32, read back and compared by SHA-256. Unallocated clusters are never read by NTFS, so leaving the
old contents there is safe (the S9 installer's TransferService does the same). Nothing outside sda32 is written:
the target is checked by its sysfs start/size and its GPT name before the first write.
"""
import argparse
import hashlib
import os
import struct
import subprocess
import sys
import tempfile

ADB = "/mnt/c/platform-tools/adb.exe"
SERIAL = "RF8M33ZBLKV"
PART_BYTES = 148783104 * 512          # sda32
PART_START_512 = 101095424            # sda32 start in 512-byte units (sysfs)
MIB = 1 << 20
CHUNK = 64 * MIB


def adb(*args, data=None, check=True):
    r = subprocess.run([ADB, "-s", SERIAL, *args], input=data, capture_output=True)
    if check and r.returncode != 0:
        raise SystemExit(f"adb {' '.join(args)} failed: {r.stderr.decode(errors='replace')}")
    return r.stdout.decode(errors="replace").replace("\r", "")


def find_source():
    out = subprocess.run(["lsblk", "-b", "-n", "-l", "-p", "-o", "NAME,SIZE,TYPE"], capture_output=True, text=True).stdout
    hits = [l.split()[0] for l in out.splitlines() if l.split()[1:] == [str(PART_BYTES), "part"]]
    if len(hits) != 1:
        raise SystemExit(f"expected one {PART_BYTES}-byte partition (the attached VHDX), found {hits}")
    return hits[0]


def check_target():
    state = adb("get-state").strip()
    if state != "recovery":
        raise SystemExit(f"phone not in TWRP ({state})")
    start, size = adb("shell", "cat /sys/block/sda/sda32/start /sys/block/sda/sda32/size").split()
    name = adb("shell", "readlink -f /dev/block/platform/13d60000.ufs/by-name/windows").strip()
    if int(start) != PART_START_512 or int(size) * 512 != PART_BYTES or name != "/dev/block/sda32":
        raise SystemExit(f"sda32 is not the windows partition: start={start} size={size} by-name={name}")
    if adb("shell", "grep -c sda32 /proc/mounts", check=False).strip() not in ("0", ""):
        raise SystemExit("sda32 is mounted in TWRP")


def used_blocks(src):
    with open(src, "rb") as f:
        boot = f.read(512)
    if boot[3:11] != b"NTFS    ":
        raise SystemExit("source partition is not NTFS")
    bps, spc = struct.unpack_from("<HB", boot, 11)
    cluster = bps * spc
    if bps != 4096:
        raise SystemExit(f"source NTFS has {bps}-byte sectors; the phone needs 4096")
    bitmap = subprocess.run(["ntfscat", "-i", "6", src], capture_output=True, check=True).stdout
    per_mib = MIB // cluster
    total_mib = PART_BYTES // MIB
    blocks = {0, total_mib - 1}
    for mib in range(total_mib):
        a, b = mib * per_mib // 8, (mib + 1) * per_mib // 8
        if any(bitmap[a:b]):
            blocks.add(mib)
    return sorted(blocks), cluster


GAP = 16   # MiB of free space a chunk may span: writing unallocated blocks is harmless and saves adb round trips


def runs(blocks):
    out, start, prev = [], None, None
    for b in blocks:
        if start is None:
            start = prev = b
        elif b - prev <= GAP + 1 and (b - start + 1) * MIB <= CHUNK:
            prev = b
        else:
            out.append((start, prev - start + 1)); start = prev = b
    if start is not None:
        out.append((start, prev - start + 1))
    return out


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--dry-run", action="store_true")
    a = p.parse_args()
    src = find_source()
    blocks, cluster = used_blocks(src)
    chunks = runs(blocks)
    print(f"source {src}: {len(blocks)} MiB to write in {len(chunks)} chunks (cluster {cluster})", flush=True)
    if a.dry_run:
        return
    check_target()
    done = 0
    with open(src, "rb") as f, tempfile.TemporaryDirectory(dir="/mnt/c/Users/Public") as tmp:
        stage = os.path.join(tmp, "chunk.bin")
        stage_win = subprocess.run(["wslpath", "-w", stage], capture_output=True, text=True).stdout.strip()
        for i, (start, count) in enumerate(chunks, 1):
            f.seek(start * MIB)
            data = f.read(count * MIB)
            want = hashlib.sha256(data).hexdigest()
            with open(stage, "wb") as s:
                s.write(data)
            adb("push", stage_win, "/tmp/chunk.bin")
            # Write, flush, drop the page cache, then read the range back from the device.
            got = adb("shell", f"dd if=/tmp/chunk.bin of=/dev/block/sda32 bs=1048576 seek={start} count={count} "
                               f"conv=fsync 2>/dev/null && sync && echo 3 > /proc/sys/vm/drop_caches && "
                               f"dd if=/dev/block/sda32 bs=1048576 skip={start} count={count} 2>/dev/null "
                               f"| sha256sum").split()[0]
            if got != want:
                raise SystemExit(f"chunk {i} at MiB {start}: read-back mismatch ({got} != {want})")
            done += count
            print(f"[{i}/{len(chunks)}] MiB {start}+{count} ok  ({done}/{len(blocks)} MiB)", flush=True)
    adb("shell", "rm -f /tmp/chunk.bin; sync")
    print("windows partition written and verified", flush=True)


if __name__ == "__main__":
    main()
