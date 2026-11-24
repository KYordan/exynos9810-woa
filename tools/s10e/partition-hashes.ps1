<#
 .SYNOPSIS
   SHA-256 of every S10e partition except `windows` (sda32), plus both GPT copies, read from TWRP.

 .DESCRIPTION
   Taken before and after a Windows write test: any difference outside sda32 means a write landed where it must
   not. Read-only on the phone. The output is "hash  name" lines, so two runs compare with Compare-Object.

     .\partition-hashes.ps1 -Out before.txt
     .\partition-hashes.ps1 -Out after.txt
     Compare-Object (Get-Content before.txt) (Get-Content after.txt)
#>
param(
    [Parameter(Mandatory)] [string]$Out,
    [string]$Adb = 'C:\platform-tools\adb.exe',
    [string]$Serial = 'RF8M33ZBLKV'
)
$ErrorActionPreference = 'Stop'
$state = (& $Adb -s $Serial get-state 2>$null)
if ($state -ne 'recovery') { throw "phone not in TWRP (adb state: $state)" }
# GPT: LBA 0..5 (protective MBR, header, entries) and the last 5 LBAs (backup entries + header), 4096-byte LBAs.
$remote = 'for n in $(seq 1 31); do set -- $(sha256sum /dev/block/sda$n); echo "$1  sda$n"; done; ' +
          'set -- $(dd if=/dev/block/sda bs=4096 count=6 2>/dev/null | sha256sum); echo "$1  gpt-primary"; ' +
          'set -- $(dd if=/dev/block/sda bs=4096 skip=31236091 count=5 2>/dev/null | sha256sum); echo "$1  gpt-backup"'
$lines = & $Adb -s $Serial shell $remote
if ($LASTEXITCODE -ne 0 -or @($lines).Count -ne 33) { throw "expected 33 hash lines, got $(@($lines).Count)" }
$lines | Set-Content -Encoding ascii $Out
"{0} lines -> {1}" -f @($lines).Count, $Out
