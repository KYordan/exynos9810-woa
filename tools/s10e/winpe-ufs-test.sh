#!/usr/bin/env bash
# S10e dual boot: turn the WinPE on the phone's ESP into a read-only B2LUFS test.
#
#   winpe-ufs-test.sh ESP_STAGE DRIVER_DIR OUT_DIR
#
# ESP_STAGE  the ESP tree copied from the Windows ISO (efi\, boot\boot.sdi, sources\boot.wim)
# DRIVER_DIR the unpacked s10e-b2lufs artifact (b2lufs.inf/.sys/.cat, b2lufs-test.cer)
# OUT_DIR    receives sources/boot.wim and efi/microsoft/boot/bcd to copy over the ESP's
#
# Boot image 2 (Windows Setup) gets the driver under X:\b2l and a winpeshl.ini that starts a console running
# b2l-test.cmd instead of Setup: it trusts the test certificate, loads B2LUFS with drvload and lists disks,
# partitions and volumes with diskpart. Nothing in it writes to a disk. The BCD's WinPE loader entry gets
# testsigning (element 16000049), without which the test-signed driver would not load. Runs in WSL as a normal
# user: wimlib-imagex (wimtools) and python3-hivex, no DISM, no administrator.
set -euo pipefail
stage=${1:?ESP stage}; drivers=${2:?driver dir}; out=${3:?out dir}
for f in sources/boot.wim efi/microsoft/boot/bcd; do test -f "$stage/$f" || { echo "missing $stage/$f" >&2; exit 1; }; done
for f in b2lufs.inf b2lufs.sys b2lufs.cat b2lufs-test.cer; do test -f "$drivers/$f" || { echo "missing $drivers/$f" >&2; exit 1; }; done
mkdir -p "$out/sources" "$out/efi/microsoft/boot"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

mkdir -p "$work/b2l"
cp "$drivers"/b2lufs.inf "$drivers"/b2lufs.sys "$drivers"/b2lufs.cat "$drivers"/b2lufs-test.cer "$work/b2l/"
printf '%s\r\n' \
  'list disk' 'select disk 0' 'detail disk' 'list partition' 'list volume' > "$work/b2l/list.txt"
printf '%s\r\n' \
  '@echo off' \
  'wpeinit' \
  'echo ===== S10e B2LUFS read-only test =====' \
  'certutil -f -addstore Root X:\b2l\b2lufs-test.cer >nul' \
  'certutil -f -addstore TrustedPublisher X:\b2l\b2lufs-test.cer >nul' \
  'drvload X:\b2l\b2lufs.inf' \
  'echo drvload exit code %errorlevel%' \
  'ping -n 6 127.0.0.1 >nul' \
  'diskpart /s X:\b2l\list.txt' \
  'echo ===== done: take a photo =====' > "$work/b2l/b2l-test.cmd"
printf '%s\r\n' '[LaunchApps]' '%SYSTEMROOT%\System32\cmd.exe, /k X:\b2l\b2l-test.cmd' > "$work/winpeshl.ini"

cp "$stage/sources/boot.wim" "$out/sources/boot.wim"
chmod u+w "$out/sources/boot.wim"   # files copied from an ISO are read-only
wimlib-imagex update "$out/sources/boot.wim" 2 --command="add $work/b2l /b2l" >/dev/null
wimlib-imagex update "$out/sources/boot.wim" 2 --command="add $work/winpeshl.ini /Windows/System32/winpeshl.ini" >/dev/null
wimlib-imagex dir "$out/sources/boot.wim" 2 --path=/b2l
wimlib-imagex dir "$out/sources/boot.wim" 2 --path=/Windows/System32/winpeshl.ini

cp "$stage/efi/microsoft/boot/bcd" "$out/efi/microsoft/boot/bcd"
chmod u+w "$out/efi/microsoft/boot/bcd"
python3 - "$out/efi/microsoft/boot/bcd" <<'EOF'
import hivex, sys
path = sys.argv[1]
h = hivex.Hivex(path, write=True)
objects = h.node_get_child(h.root(), "Objects")
bootmgr = h.node_get_child(objects, "{9dea862c-5cdd-4e70-acc1-f32b344d4795}")
default = h.node_get_child(h.node_get_child(bootmgr, "Elements"), "23000003")
guid = h.value_value(h.node_get_value(default, "Element"))[1].decode("utf-16-le").rstrip("\0")
elements = h.node_get_child(h.node_get_child(objects, guid), "Elements")
node = h.node_get_child(elements, "16000049") or h.node_add_child(elements, "16000049")
h.node_set_value(node, {"key": "Element", "t": 3, "value": b"\x01"})   # AllowPrereleaseSignatures = testsigning on
h.commit(path)
print(f"BCD: testsigning on for the default entry {guid}")
EOF
sha256sum "$out/sources/boot.wim" "$out/efi/microsoft/boot/bcd"
