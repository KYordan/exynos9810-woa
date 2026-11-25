#!/usr/bin/env python3
"""Minimal read-only VHDX reader (dynamic disks, no parent, clean log) - enough to stream a partition out of the
image build-windows-image.ps1 makes, without wsl --mount (administrator) or qemu (which cannot open files on
WSL's drvfs mounts: "Operation not supported").

    python3 vhdx.py IMAGE            # geometry, allocated blocks, GPT partitions
"""
import struct
import sys
import uuid

BAT_GUID = uuid.UUID("2DC27766-F623-4200-9D64-115E9BFD4A08")
META_GUID = uuid.UUID("8B7CA206-4790-4B9A-B8FE-575F050F886E")
FILE_PARAMS = uuid.UUID("CAA16737-FA36-4D43-B3B6-33F0AA44E76B")
DISK_SIZE = uuid.UUID("2FA54224-CD1B-4876-B211-5DBED83BF4B8")
LOGICAL_SECTOR = uuid.UUID("8141BF1D-A96F-4709-BA47-F233A8FAAB5F")
FULLY_PRESENT = 6
MB = 1 << 20


class Vhdx:
    def __init__(self, path):
        self.f = open(path, "rb")
        if self._read(0, 8) != b"vhdxfile":
            raise ValueError("not a VHDX file")
        heads = []
        for off in (64 * 1024, 128 * 1024):
            h = self._read(off, 4096)
            if h[:4] == b"head":
                seq = struct.unpack_from("<Q", h, 8)[0]
                log_guid = uuid.UUID(bytes_le=h[48:64])
                heads.append((seq, log_guid))
        if not heads:
            raise ValueError("no VHDX header")
        seq, log_guid = max(heads)
        if log_guid.int != 0:
            raise ValueError("VHDX log not empty (not cleanly detached): attach and detach it in Windows first")
        regions = {}
        for off in (192 * 1024, 256 * 1024):
            r = self._read(off, 64 * 1024)
            if r[:4] != b"regi":
                continue
            count = struct.unpack_from("<I", r, 8)[0]
            for i in range(count):
                e = r[16 + 32 * i:48 + 32 * i]
                regions[uuid.UUID(bytes_le=e[:16])] = struct.unpack_from("<QI", e, 16)
            break
        bat_off, bat_len = regions[BAT_GUID]
        meta_off, _ = regions[META_GUID]
        meta = self._read(meta_off, 64 * 1024)
        if meta[:8] != b"metadata":
            raise ValueError("bad metadata table")
        items = {}
        for i in range(struct.unpack_from("<H", meta, 10)[0]):
            e = meta[32 + 32 * i:64 + 32 * i]
            item, off, length = uuid.UUID(bytes_le=e[:16]), *struct.unpack_from("<II", e, 16)
            items[item] = self._read(meta_off + off, length)
        self.block_size, flags = struct.unpack_from("<II", items[FILE_PARAMS])
        if flags & 2:
            raise ValueError("differencing VHDX not supported")
        self.size = struct.unpack_from("<Q", items[DISK_SIZE])[0]
        self.sector = struct.unpack_from("<I", items[LOGICAL_SECTOR])[0]
        self.chunk_ratio = (1 << 23) * self.sector // self.block_size
        self.bat = self._read(bat_off, bat_len)

    def _read(self, off, length):
        self.f.seek(off)
        return self.f.read(length)

    def block(self, n):
        """(state, file offset) of payload block n."""
        e = struct.unpack_from("<Q", self.bat, 8 * (n + n // self.chunk_ratio))[0]
        return e & 7, (e >> 20) * MB

    def present(self, n):
        return self.block(n)[0] == FULLY_PRESENT

    def read(self, off, length):
        out = bytearray()
        while length:
            n, inner = divmod(off, self.block_size)
            take = min(length, self.block_size - inner)
            state, file_off = self.block(n)
            out += self._read(file_off + inner, take) if state == FULLY_PRESENT else bytes(take)
            off += take; length -= take
        return bytes(out)

    def partitions(self):
        hdr = self.read(self.sector, self.sector)
        if hdr[:8] != b"EFI PART":
            raise ValueError("no GPT in the virtual disk")
        lba, count, esize = struct.unpack_from("<QII", hdr, 72)
        raw = self.read(lba * self.sector, count * esize)
        for i in range(count):
            e = raw[i * esize:(i + 1) * esize]
            if any(e[:16]):
                first, last = struct.unpack_from("<QQ", e, 32)
                yield i + 1, first * self.sector, (last - first + 1) * self.sector, uuid.UUID(bytes_le=e[:16])


if __name__ == "__main__":
    v = Vhdx(sys.argv[1])
    blocks = (v.size + v.block_size - 1) // v.block_size
    used = sum(v.present(n) for n in range(blocks))
    print(f"size {v.size} sector {v.sector} block {v.block_size} chunk_ratio {v.chunk_ratio}: {used}/{blocks} blocks present")
    for p in v.partitions():
        print("  partition %d offset %d size %d type %s" % p)
