#!/usr/bin/env python3
"""Make a diagnostic B2LUFS build: record why the transport start fails instead of failing silently.

    python diag_patch.py UPSTREAM/windows/b2lufs

On the S10e (first WinPE test, 2026-11-24) B2LUFS bound to ACPI\\SMSN9820\\0 but failed to start: Code 10,
0xC00000C2 (HwInitialize returned FALSE). Upstream's B2LUfsStartTransport returns FALSE from several checks
(HCS ready bits, slot counts, 64-bit DMA, HCE, UTRL doorbell, run/stop) and logs none of them.

This edits a clone of the pinned upstream source (never committed here) so that:
  - B2LUfsStartTransport snapshots CAP, HCS, HCE, UTRLDBR, UTRLRSR, IS, IE, AHIT and the DMA addresses first
    (reads only), then runs the original checks and records the result;
  - on failure HwInitialize disables the controller interrupt (IE = 0) and still succeeds, so a PASSIVE callback
    can publish the snapshot under the device's hardware key, subkey B2LUFSDIAG; no LUN is enumerated;
  - on success the snapshot is published too and the original PASSIVE initialization runs unchanged.
Every edit is an exact, counted replacement: a changed upstream stops the build.
"""
import sys
from pathlib import Path

DIAG_FIELDS = ("Result", "Cap", "Hcs", "Hce", "Doorbell", "RunStop", "Is", "Ie", "Ahit",
               "UtrdHigh", "UtrdLow", "UcdHigh", "BuffersMissing")


def replace(text, old, new, name):
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{name}: expected one match of {old[:60]!r}, found {count}")
    return text.replace(old, new)


def main():
    src = Path(sys.argv[1])
    header = src / "b2lufs_transport.h"
    transport = src / "b2lufs_transport.c"
    storport = src / "b2lufs_storport.c"

    h = header.read_text()
    fields = "".join(f"    ULONG Diag{f};\n" for f in DIAG_FIELDS)
    h = replace(h, "    BOOLEAN TransportReady;\n} B2LUFS_ADAPTER;",
                "    BOOLEAN TransportReady;\n    BOOLEAN DiagStartFailed;\n" + fields + "} B2LUFS_ADAPTER;",
                header.name)
    header.write_text(h)

    t = transport.read_text()
    t = replace(t, "BOOLEAN\nB2LUfsStartTransport(_In_ PVOID DeviceExtension, _Inout_ B2LUFS_ADAPTER *Adapter)\n{",
                "static BOOLEAN\nB2LUfsStartTransportInner(_In_ PVOID DeviceExtension, _Inout_ B2LUFS_ADAPTER *Adapter)\n{",
                transport.name)
    wrapper = """BOOLEAN
B2LUfsStartTransport(_In_ PVOID DeviceExtension, _Inout_ B2LUFS_ADAPTER *Adapter)
{
    BOOLEAN Started;

    /* S10e diagnostic build: register snapshot before the upstream checks (reads only). */
    Adapter->DiagBuffersMissing = (Adapter->UtrdVirtual == NULL || Adapter->UcdVirtual == NULL) ? 1UL : 0UL;
    Adapter->DiagUtrdHigh = (ULONG)Adapter->UtrdPhysical.HighPart;
    Adapter->DiagUtrdLow = Adapter->UtrdPhysical.LowPart;
    Adapter->DiagUcdHigh = (ULONG)Adapter->UcdPhysical.HighPart;
    if (Adapter->Resources.Base[B2LUfsResourceHci] != NULL) {
        Adapter->DiagCap = B2LUfsReadHci(DeviceExtension, Adapter, B2LUFS_REG_CAP);
        Adapter->DiagHcs = B2LUfsReadHci(DeviceExtension, Adapter, B2LUFS_REG_HCS);
        Adapter->DiagHce = B2LUfsReadHci(DeviceExtension, Adapter, B2LUFS_REG_HCE);
        Adapter->DiagDoorbell = B2LUfsReadHci(DeviceExtension, Adapter, B2LUFS_REG_UTRLDBR);
        Adapter->DiagRunStop = B2LUfsReadHci(DeviceExtension, Adapter, B2LUFS_REG_UTRLRSR);
        Adapter->DiagIs = B2LUfsReadHci(DeviceExtension, Adapter, B2LUFS_REG_IS);
        Adapter->DiagIe = B2LUfsReadHci(DeviceExtension, Adapter, B2LUFS_REG_IE);
        Adapter->DiagAhit = B2LUfsReadHci(DeviceExtension, Adapter, B2LUFS_REG_AHIT);
    }
    Started = B2LUfsStartTransportInner(DeviceExtension, Adapter);
    Adapter->DiagResult = Started ? 1UL : 0UL;
    return Started;
}

BOOLEAN
B2LUfsStopTransport("""
    t = replace(t, "BOOLEAN\nB2LUfsStopTransport(", wrapper, transport.name)
    transport.write_text(t)

    s = storport.read_text()
    names = "".join(f'static UCHAR B2LUFS_DIAG_{f.upper()}[] = "{f}";\n' for f in DIAG_FIELDS)
    writes = "".join(
        f"    (void)StorPortRegistryWriteAdapterKey(DeviceExtension, B2LUFS_DIAG_SUBKEY, B2LUFS_DIAG_{f.upper()},\n"
        f"        REG_DWORD, &Adapter->Diag{f}, sizeof(Adapter->Diag{f}));\n" for f in DIAG_FIELDS)
    passive = f"""static UCHAR B2LUFS_DIAG_SUBKEY[] = "B2LUFSDIAG";
{names}
/* S10e diagnostic build: publish the start snapshot, then the upstream PASSIVE path only if the start worked. */
static BOOLEAN
B2LUfsDiagPassive(_In_ PVOID DeviceExtension)
{{
    B2LUFS_ADAPTER *Adapter = (B2LUFS_ADAPTER *)DeviceExtension;

{writes}    if (Adapter->DiagStartFailed) {{
        return TRUE;
    }}
    return B2LUfsPassiveInitialize(DeviceExtension);
}}

_Use_decl_annotations_
static BOOLEAN
B2LUfsInitialize(_In_ PVOID DeviceExtension)"""
    s = replace(s, "_Use_decl_annotations_\nstatic BOOLEAN\nB2LUfsInitialize(_In_ PVOID DeviceExtension)",
                passive, storport.name)
    s = replace(s, """    if (!B2LUfsStartTransport(DeviceExtension, Adapter)) {
        return FALSE;
    }""", """    if (!B2LUfsStartTransport(DeviceExtension, Adapter)) {
        if (Adapter->DumpMode || Adapter->Resources.Base[B2LUfsResourceHci] == NULL) {
            return FALSE;
        }
        /* Diagnostic build: keep the adapter so the snapshot reaches the registry; no LUN is enumerated. */
        Adapter->DiagStartFailed = TRUE;
        StorPortWriteRegisterUlong(DeviceExtension,
            (PULONG)((PUCHAR)Adapter->Resources.Base[B2LUfsResourceHci] + 0x24UL), 0);   /* IE = 0 */
        return StorPortEnablePassiveInitialization(DeviceExtension, B2LUfsDiagPassive);
    }""", storport.name)
    s = replace(s, """    return StorPortEnablePassiveInitialization(
        DeviceExtension, B2LUfsPassiveInitialize);""", """    return StorPortEnablePassiveInitialization(
        DeviceExtension, B2LUfsDiagPassive);""", storport.name)
    storport.write_text(s)
    print("diagnostic B2LUFS patch applied:", ", ".join(DIAG_FIELDS))


if __name__ == "__main__":
    main()
