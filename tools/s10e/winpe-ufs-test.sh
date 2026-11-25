#!/usr/bin/env bash
# S10e dual boot: turn the WinPE on the phone's ESP into a read-only B2LUFS test.
#
#   winpe-ufs-test.sh ESP_STAGE DRIVER_DIR OUT_DIR [read|write]
#
# `write` replaces the read-only test with the guarded write test on the windows partition (see below).
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
stage=${1:?ESP stage}; drivers=${2:?driver dir}; out=${3:?out dir}; mode=${4:-read}   # read | write | service
extra=${5:-}   # service: folder of driver packages (each an .inf + .sys + .cat) to add to the installed Windows
for f in sources/boot.wim efi/microsoft/boot/bcd; do test -f "$stage/$f" || { echo "missing $stage/$f" >&2; exit 1; }; done
for f in b2lufs.inf b2lufs.sys b2lufs.cat b2lufs-test.cer; do test -f "$drivers/$f" || { echo "missing $drivers/$f" >&2; exit 1; }; done
mkdir -p "$out/sources" "$out/efi/microsoft/boot"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

mkdir -p "$work/b2l"
cp "$drivers"/b2lufs.inf "$drivers"/b2lufs.sys "$drivers"/b2lufs.cat "$drivers"/b2lufs-test.cer "$work/b2l/"
printf '%s\r\n' 'list disk' 'list volume' > "$work/b2l/list.txt"
# Run 1 (drvload): "Successfully loaded", yet no disk. The Setup image has no certutil; test signing alone admits
# the driver. Like upstream startnet.cmd: pnputil /add-driver /install + /scan-devices, automount off (mountvol /N),
# then the device node's status/problem, the service, StorPort's Operational events (B2LUFS logs there) and diskpart.
printf '%s\r\n' \
  '@echo off' \
  'mode con: cols=96 lines=140 >nul 2>&1' \
  'wpeinit' \
  'mountvol /N >nul 2>&1' \
  'echo ===== S10e B2LUFS read-only test, run 4 =====' \
  'pnputil /add-driver X:\b2l\b2lufs.inf /install | find /v "Microsoft PnP"' \
  'pnputil /scan-devices >nul' \
  'ping -n 8 127.0.0.1 >nul' \
  'echo ----- UFS0 device node' \
  'pnputil /enum-devices /instanceid "ACPI\SMSN9820\0" /drivers' \
  'echo ----- b2lufs service' \
  'reg query HKLM\SYSTEM\CurrentControlSet\Services\b2lufs /v Start' \
  'echo ----- B2LUFS start snapshot (diagnostic build)' \
  'reg query "HKLM\SYSTEM\CurrentControlSet\Enum\ACPI\SMSN9820\0\Device Parameters\B2LUFSDIAG" 2>nul || reg query "HKLM\SYSTEM\CurrentControlSet\Enum\ACPI\SMSN9820\0" /s /f B2LUFSDIAG /k' \
  'echo ----- diskpart' \
  'diskpart /s X:\b2l\list.txt | find /v "Microsoft" | find /v "Copyright"' \
  'echo ===== done: take a photo =====' > "$work/b2l/b2l-test.cmd"

if [[ $mode == write ]]; then
  # Write test (run 5): the first writes through B2LUFS, to the empty `windows` partition only. diskpart numbers
  # partitions in GPT entry order, so the guard checks that partition 32 starts at the byte offset of the GPT entry
  # we created (LBA 12636928 x 4096) before anything is formatted; any other layout writes nothing. The payload is
  # files of this very image (X:\Windows\System32\drivers, X:\sources): TWRP compares them with wimlib's copies.
  # mountvol /P flushes and dismounts W: so a forced restart loses nothing.
  printf '%s\r\n' 'select disk 0' 'select partition 32' 'detail partition' > "$work/b2l/detail32.txt"
  # Run 6: "The device is not ready" at 0 %: mountvol /N leaves every volume Offline, and diskpart cannot format an
  # offline volume. Bring only this partition's volume online first (as upstream startnet.cmd does for CACHE).
  # Run 7: online ok, then format stopped at 0 % with "Incorrect function": B2LUFS completed some request with
  # SRB_STATUS_INVALID_REQUEST (format's extra commands, not plain WRITE(10/16), which the driver passes through).
  # Run 8 tests the path an installed Windows uses: sda32 is formatted NTFS beforehand from TWRP (mkfs.ntfs) and
  # WinPE only mounts it and copies files with ordinary writes. The label is checked before anything is copied.
  printf '%s\r\n' 'select disk 0' 'select partition 32' 'online volume noerr' 'assign letter=W' \
    > "$work/b2l/format32.txt"
  printf '%s\r\n' \
    '@echo off' \
    'mode con: cols=96 lines=140 >nul 2>&1' \
    'wpeinit' \
    'mountvol /N >nul 2>&1' \
    'echo ===== S10e B2LUFS write test, run 8: copy to the windows partition only =====' \
    'pnputil /add-driver X:\b2l\b2lufs.inf /install >nul' \
    'pnputil /scan-devices >nul' \
    'ping -n 8 127.0.0.1 >nul' \
    'diskpart /s X:\b2l\detail32.txt > X:\b2l\detail32.out' \
    'find "51760857088" X:\b2l\detail32.out >nul' \
    'if errorlevel 1 goto guard' \
    'echo guard ok: partition 32 starts at byte 51760857088 (windows, sda32)' \
    'diskpart /s X:\b2l\format32.txt | find /v "Microsoft" | find /v "Copyright"' \
    'if not exist W:\ goto noformat' \
    'vol W: | find "WINTEST" >nul' \
    'if errorlevel 1 goto nolabel' \
    'echo W: is the WINTEST NTFS volume' \
    'robocopy X:\Windows\System32\drivers W:\b2ltest\drivers /E /NFL /NDL /NJH /R:0 /W:0' \
    'robocopy X:\sources W:\b2ltest\sources /E /NFL /NDL /NJH /R:0 /W:0' \
    'dir /s W:\b2ltest | find "File(s)"' \
    'mountvol W: /P' \
    'echo W: flushed and dismounted' \
    'goto end' \
    ':guard' \
    'echo GUARD FAILED: partition 32 is not the windows partition - NOTHING WAS WRITTEN' \
    'type X:\b2l\detail32.out' \
    'goto end' \
    ':nolabel' \
    'echo W: IS NOT LABELLED WINTEST - nothing copied' \
    'vol W:' \
    'mountvol W: /P' \
    'goto end' \
    ':noformat' \
    'echo ONLINE OR ASSIGN FAILED' \
    ':end' \
    'echo ===== done: take a photo, then restart to TWRP =====' > "$work/b2l/b2l-test.cmd"
fi

if [[ $mode == service ]]; then
  # Offline servicing of the installed Windows on the phone (no input device there yet): DISM from this WinPE adds
  # the driver packages under X:\drv to the `windows` partition, after the same partition guard as the write test.
  # Windows' own NTFS driver mounts it, so a volume left dirty by a forced restart is fine.
  test -n "$extra" && test -d "$extra" || { echo "service mode needs the driver folder as 5th argument" >&2; exit 1; }
  mkdir -p "$work/drv"
  cp -r "$extra"/. "$work/drv/"
  printf '%s\r\n' 'select disk 0' 'select partition 32' 'detail partition' > "$work/b2l/detail32.txt"
  printf '%s\r\n' 'select disk 0' 'select partition 32' 'online volume noerr' 'assign letter=W' \
    > "$work/b2l/format32.txt"
  printf '%s\r\n' \
    '@echo off' \
    'mode con: cols=96 lines=140 >nul 2>&1' \
    'wpeinit' \
    'mountvol /N >nul 2>&1' \
    'echo ===== S10e: add drivers to the installed Windows =====' \
    'pnputil /add-driver X:\b2l\b2lufs.inf /install >nul' \
    'pnputil /scan-devices >nul' \
    'ping -n 8 127.0.0.1 >nul' \
    'diskpart /s X:\b2l\detail32.txt > X:\b2l\detail32.out' \
    'find "51760857088" X:\b2l\detail32.out >nul' \
    'if errorlevel 1 goto guard' \
    'diskpart /s X:\b2l\format32.txt >nul' \
    'if not exist W:\Windows\System32\ntoskrnl.exe goto nowin' \
    'echo W: is the installed Windows' \
    'dism /Image:W:\ /Add-Driver /Driver:X:\drv /Recurse /ForceUnsigned' \
    'echo ----- third-party drivers now in the image' \
    'dism /Image:W:\ /Get-Drivers | find /i "Original File Name"' \
    'mountvol W: /P' \
    'echo W: flushed and dismounted' \
    'goto end' \
    ':guard' \
    'echo GUARD FAILED: partition 32 is not the windows partition - nothing changed' \
    'type X:\b2l\detail32.out' \
    'goto end' \
    ':nowin' \
    'echo NO WINDOWS ON PARTITION 32 - nothing changed' \
    'mountvol W: /P' \
    ':end' \
    'echo ===== done: take a photo, then restart =====' > "$work/b2l/b2l-test.cmd"
fi
printf '%s\r\n' '[LaunchApps]' '%SYSTEMROOT%\System32\cmd.exe, /k X:\b2l\b2l-test.cmd' > "$work/winpeshl.ini"

cp "$stage/sources/boot.wim" "$out/sources/boot.wim"
chmod u+w "$out/sources/boot.wim"   # files copied from an ISO are read-only
wimlib-imagex update "$out/sources/boot.wim" 2 --command="add $work/b2l /b2l" >/dev/null
if [[ -d $work/drv ]]; then
  wimlib-imagex update "$out/sources/boot.wim" 2 --command="add $work/drv /drv" >/dev/null
  wimlib-imagex dir "$out/sources/boot.wim" 2 --path=/drv
fi
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
