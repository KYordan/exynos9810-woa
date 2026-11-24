<#
 .SYNOPSIS
   Packages the B2LUFS Exynos 9820 UFS StorPort miniport for an installed Windows on the Galaxy S10e.

 .DESCRIPTION
   B2LUFS comes from orhunnx/beyond2lte-uefi (windows/b2lufs). That repository has no license file, so its source
   is NOT copied here: CI clones it at a pinned commit, builds b2lufs.sys with its own build-b2lufs.ps1, and this
   script turns its WinPE INF template into a boot-start package:

     - StartType 3 -> 0 and LoadOrderGroup "SCSI miniport": the system disk's controller must load at boot;
     - b2lufs.sys + b2lufs.inf -> b2lufs.cat (Inf2Cat), both signed with a test certificate made for this build;
     - b2lufs-test.cer: the image built for the phone trusts it (Root + TrustedPublisher) and has test signing on.

   The device it binds to is the DSDT's UFS0 (_HID SMSN9820, _CID BYND9820) in the S10e firmware's ACPI tables.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Template,   # windows\b2lufs\b2lufs.inf.in of the pinned upstream commit
    [Parameter(Mandatory)] [string]$Sys,        # b2lufs.sys built by upstream build-b2lufs.ps1
    [Parameter(Mandatory)] [string]$OutDir
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Set-Exactly([string]$Text, [string]$Old, [string]$New) {
    $count = ([regex]::Matches($Text, [regex]::Escape($Old))).Count
    if ($count -ne 1) { throw "INF template: expected exactly one '$Old', found $count (upstream changed?)" }
    return $Text.Replace($Old, $New)
}

function Find-KitTool([string]$Name, [string]$Arch) {
    $root = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    $tool = Get-ChildItem $root -Recurse -Filter $Name -File -ErrorAction SilentlyContinue |
        Where-Object { $_.DirectoryName -match "\\$Arch$" } | Sort-Object FullName -Descending | Select-Object -First 1
    if ($null -eq $tool) { throw "$Name ($Arch) not found under $root" }
    return $tool.FullName
}

New-Item -ItemType Directory -Force $OutDir | Out-Null
$inf = [IO.File]::ReadAllText($Template)
$inf = Set-Exactly $inf 'StartType=3' 'StartType=0'
$inf = Set-Exactly $inf 'ErrorControl=1' "ErrorControl=1`r`nLoadOrderGroup=SCSI miniport"
$inf = "; S10e dual boot: boot-start package made by exynos9810-woa drivers\Exynos9820Ufs\make-package.ps1`r`n" + $inf
[IO.File]::WriteAllText((Join-Path $OutDir 'b2lufs.inf'), $inf, [Text.Encoding]::ASCII)
Copy-Item $Sys (Join-Path $OutDir 'b2lufs.sys') -Force

$inf2cat = Find-KitTool 'Inf2Cat.exe' 'x86'
$signtool = Find-KitTool 'signtool.exe' 'x64'
$made = $false
foreach ($os in '10_NI_ARM64', '10_GE_ARM64', '10_CO_ARM64') {
    & $inf2cat "/driver:$OutDir" "/os:$os" | Out-Host
    if ($LASTEXITCODE -eq 0 -and (Test-Path (Join-Path $OutDir 'b2lufs.cat'))) { Write-Host "Inf2Cat /os:$os"; $made = $true; break }
}
if (-not $made) { throw 'Inf2Cat did not produce b2lufs.cat' }

$cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=S10e WOA Test Signing' `
    -CertStoreLocation Cert:\CurrentUser\My -KeyExportPolicy Exportable -NotAfter (Get-Date).AddYears(10)
try {
    Export-Certificate -Cert $cert -FilePath (Join-Path $OutDir 'b2lufs-test.cer') | Out-Null
    foreach ($file in 'b2lufs.sys', 'b2lufs.cat') {
        & $signtool sign /fd sha256 /sha1 $cert.Thumbprint /s My (Join-Path $OutDir $file) | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "signtool failed on $file" }
    }
}
finally {
    Remove-Item "Cert:\CurrentUser\My\$($cert.Thumbprint)" -Force   # the private key never leaves the runner
}
Get-ChildItem $OutDir | ForEach-Object { '{0}  {1}' -f (Get-FileHash $_.FullName).Hash.ToLower(), $_.Name }
