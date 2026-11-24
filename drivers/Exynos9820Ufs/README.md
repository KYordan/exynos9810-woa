# Exynos 9820 UFS (Galaxy S10e dual boot)

The disk driver an installed Windows needs on the Galaxy S10e (SM-G970F, Exynos 9820): **B2LUFS**, a StorPort
miniport from [orhunnx/beyond2lte-uefi](https://github.com/orhunnx/beyond2lte-uefi) (`windows/b2lufs`). It takes over
the UFS link the UEFI left running (no controller reset, no PHY calibration) and exposes user LUN 0, where the
`windows` partition lives.

That repository carries no license file, so its source is not copied here. The `S10e UFS driver (B2LUFS)` workflow
clones it at a pinned commit, builds `b2lufs.sys` with its own `build-b2lufs.ps1`, and `make-package.ps1` turns the
WinPE-only INF into a boot-start package:

| Change | Why |
|---|---|
| `StartType` 3 → 0, `LoadOrderGroup = SCSI miniport` | the system disk's controller loads at boot |
| `b2lufs.cat` (Inf2Cat), sys + cat test-signed | DISM can add it offline; the image trusts `b2lufs-test.cer` and has test signing on |

It binds to `ACPI\BYND9820`, the compatible ID of `UFS0` in the S10e firmware's DSDT (the S5E9820 tables of the
same overlay, enabled in the ios-s10e `windows-dualboot` firmware).

The artifact (`s10e-b2lufs-N`) is a 7z archive encrypted with the `B2L_ARTIFACT_PASSWORD` repository secret.
