#Requires -RunAsAdministrator
<#
 .SYNOPSIS
   Builds the Galaxy S10e Windows 11 image (dual boot with iOS) in a 4Kn VHDX and hands the disk to WSL.

 .DESCRIPTION
   Follows the S9 installer's VhdxImageBuilder/BootConfiguration, for the S10e layout:
     - a dynamic VHDX with 4096-byte sectors (the phone's UFS is 4Kn: NTFS made on a 512-byte disk would not mount
       there): ESP 260 MB, MSR 16 MB, and a Windows partition of exactly the size of the phone's `windows`
       partition (sda32, 148783104 x 512 bytes), NTFS with 4 KB clusters;
     - install.wim applied with /Compact (CompactOS: less to write to the phone);
     - B2LUFS (the UFS boot driver, s10e-b2lufs artifact) injected with DISM;
     - an OOBE answer file (local account, no screens: the phone has no input device in Windows yet) and 250 %
       display scaling for the 1080 x 2280 panel;
     - bcdboot, then the BCD pointed at the phone: boot manager on `cache` (the ESP), loader and OS on `windows`,
       each a GPT partition of the phone's disk GUID; test signing on (B2LUFS is test-signed), 4 processors, no
       VSM/hypervisor, boot-status failures ignored;
     - the ESP files copied to <Work>\esp, the VHDX detached and attached to WSL (wsl --mount --bare) so the
       transfer script there can stream the used NTFS clusters to the phone.
   Nothing here touches the phone.

 .EXAMPLE
   .\build-windows-image.ps1 -Iso C:\Projects\woa-s10e\iso\22631.2428...ISO -Driver C:\Projects\exynos9810-woa\s10e-b2lufs -Work G:\woa-s10e\image
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Iso,
    [Parameter(Mandatory)] [string]$Driver,
    [Parameter(Mandatory)] [string]$Work,
    [string]$UserName = 'S10e',
    [int]$Processors = 4
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- the phone (read from its GPT, 2026-11-24) ---
$DiskGuid     = '{52444e41-494f-2044-4d4d-43204449534b}'
$CacheGuid    = '{52444e41-494f-2044-6361-636865000000}'   # sda28 cache = Windows EFI system partition
$WindowsGuid  = '{cbb880e2-813e-46b6-af31-ffa05f30871c}'   # sda32 windows
$WindowsBytes = 148783104L * 512                            # 76,176,949,248
$BootMgrId    = '{9dea862c-5cdd-4e70-acc1-f32b344d4795}'

function Step([string]$Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Exe $($Arguments -join ' ') failed with exit code $LASTEXITCODE" }
}
function Get-FreeLetter([char[]]$Avoid) {
    $used = (Get-PSDrive -PSProvider FileSystem).Name
    foreach ($c in [char[]]('PQRSTUVW')) { if ($used -notcontains [string]$c -and $Avoid -notcontains $c) { return $c } }
    throw 'no free drive letter'
}

foreach ($f in $Iso, (Join-Path $Driver 'b2lufs.inf'), (Join-Path $Driver 'b2lufs.sys'), (Join-Path $Driver 'b2lufs.cat')) {
    if (-not (Test-Path -LiteralPath $f)) { throw "missing: $f" }
}
New-Item -ItemType Directory -Force $Work | Out-Null
$vhdx = Join-Path $Work 'windows.vhdx'
if (Test-Path $vhdx) { throw "$vhdx already exists: delete it (or Dismount-VHD it) first" }
$espOut = Join-Path $Work 'esp'
$log = Join-Path $Work 'build.log'
Start-Transcript -Path $log -Force | Out-Null

$isoMount = $null
$vhdAttached = $false
try {
    Step 'Mounting the Windows ISO (read-only)'
    $isoMount = Mount-DiskImage -ImagePath $Iso -Access ReadOnly -PassThru
    $isoLetter = ($isoMount | Get-Volume).DriveLetter
    $wim = "${isoLetter}:\sources\install.wim"
    $image = Get-WindowsImage -ImagePath $wim | Where-Object ImageName -eq 'Windows 11 Pro' | Select-Object -First 1
    if (-not $image) { throw 'Windows 11 Pro not found in install.wim' }
    Write-Host "install.wim index $($image.ImageIndex): $($image.ImageName)"

    Step 'Creating the 4Kn VHDX (dynamic) on the work drive'
    $size = $WindowsBytes + 512MB
    $vhd = New-VHD -Path $vhdx -Dynamic -SizeBytes $size -BlockSizeBytes 32MB -LogicalSectorSizeBytes 4096 -PhysicalSectorSizeBytes 4096
    $disk = Mount-VHD -Path $vhd.Path -NoDriveLetter -Passthru | Get-Disk
    $vhdAttached = $true
    if ($disk.LogicalSectorSize -ne 4096) { throw 'the virtual disk is not 4Kn' }
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT | Out-Null
    $espLetter = Get-FreeLetter @()
    $winLetter = Get-FreeLetter @($espLetter)
    $esp = New-Partition -DiskNumber $disk.Number -Size 260MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
    Format-Volume -Partition $esp -FileSystem FAT32 -NewFileSystemLabel 'System' -Confirm:$false | Out-Null
    $esp | Set-Partition -NewDriveLetter $espLetter
    New-Partition -DiskNumber $disk.Number -Size 16MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' | Out-Null
    $win = New-Partition -DiskNumber $disk.Number -Size $WindowsBytes -Alignment 1MB -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
    if ($win.Size -ne $WindowsBytes) { throw "Windows partition is $($win.Size) bytes, the phone's is $WindowsBytes" }
    Format-Volume -Partition $win -FileSystem NTFS -AllocationUnitSize 4096 -NewFileSystemLabel 'Windows' -Confirm:$false | Out-Null
    $win | Set-Partition -NewDriveLetter $winLetter
    $W = "${winLetter}:\"; $S = "${espLetter}:\"
    Write-Host "ESP $S  Windows $W  (VHDX disk $($disk.Number), partition offset $($win.Offset))"

    Step 'Applying Windows 11 Pro (CompactOS) - the slow part, 15-30 minutes'
    Invoke-Native dism.exe @('/Apply-Image', "/ImageFile:$wim", "/Index:$($image.ImageIndex)", "/ApplyDir:$W", '/Compact')

    Step 'Injecting the B2LUFS UFS boot driver'
    Invoke-Native dism.exe @("/Image:$W", '/Add-Driver', "/Driver:$(Join-Path $Driver 'b2lufs.inf')", '/ForceUnsigned')
    Invoke-Native dism.exe @("/Image:$W", '/Get-Drivers')

    Step 'OOBE answer file (no input device on the phone yet)'
    $panther = Join-Path $W 'Windows\Panther'
    New-Item -ItemType Directory -Force $panther | Out-Null
    $arch = 'processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"'
    @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" $arch>
      <ComputerName>S10E</ComputerName>
      <TimeZone>FLE Standard Time</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" $arch>
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" $arch>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>$UserName</Name>
            <Group>Administrators</Group>
            <Password><Value></Value><PlainText>true</PlainText></Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>$UserName</Username>
        <Password><Value></Value><PlainText>true</PlainText></Password>
        <LogonCount>9999999</LogonCount>
      </AutoLogon>
      <TimeZone>FLE Standard Time</TimeZone>
    </component>
  </settings>
</unattend>
"@ | Set-Content -Encoding UTF8 (Join-Path $panther 'unattend.xml')

    Step 'Display scaling 250 % (default user and sign-in screen)'
    foreach ($hive in @(@('S10E_DEFUSER', (Join-Path $W 'Users\Default\NTUSER.DAT')), @('S10E_DEFAULT', (Join-Path $W 'Windows\System32\config\DEFAULT')))) {
        Invoke-Native reg.exe @('load', "HKLM\$($hive[0])", $hive[1])
        try {
            Invoke-Native reg.exe @('add', "HKLM\$($hive[0])\Control Panel\Desktop", '/v', 'LogPixels', '/t', 'REG_DWORD', '/d', '240', '/f')
            Invoke-Native reg.exe @('add', "HKLM\$($hive[0])\Control Panel\Desktop", '/v', 'Win8DpiScaling', '/t', 'REG_DWORD', '/d', '1', '/f')
        } finally {
            [GC]::Collect(); Start-Sleep -Milliseconds 500
            Invoke-Native reg.exe @('unload', "HKLM\$($hive[0])")
        }
    }

    Step 'UEFI boot files (bcdboot) and the phone BCD'
    Invoke-Native bcdboot.exe @("$($W)Windows", '/s', $S.TrimEnd('\'), '/f', 'UEFI')
    $bcd = Join-Path $S 'EFI\Microsoft\Boot\BCD'
    foreach ($a in @(
            @('path', '\Windows\System32\winload.efi'), @('systemroot', '\Windows'), @('testsigning', 'on'),
            @('nointegritychecks', 'off'), @('numproc', "$Processors"), @('vsmlaunchtype', 'off'),
            @('hypervisorlaunchtype', 'off'), @('detecthal', 'on'), @('bootstatuspolicy', 'IgnoreAllFailures'),
            @('recoveryenabled', 'no'))) {
        Invoke-Native bcdedit.exe (@('/store', $bcd, '/set', '{default}') + $a)
    }
    $open = Invoke-CimMethod -Namespace root\WMI -ClassName BcdStore -MethodName OpenStore -Arguments @{ File = $bcd }
    if (-not $open.ReturnValue) { throw 'cannot open the BCD store' }
    function Call($o, [string]$m, [hashtable]$a) {
        $r = Invoke-CimMethod -InputObject $o -MethodName $m -Arguments $a
        if (-not $r.ReturnValue) { throw "BCD rejected $m" }
        $r
    }
    $store = $open.Store
    $mgr = (Call $store 'OpenObject' @{ Id = $BootMgrId }).Object
    $loaderId = (Call $mgr 'GetElement' @{ Type = [uint32]0x23000003 }).Element.Id
    $loader = (Call $store 'OpenObject' @{ Id = $loaderId }).Object
    $null = Call $mgr 'SetQualifiedPartitionDeviceElement' @{ Type = [uint32]0x11000001; PartitionStyle = [uint32]1; DiskSignature = $DiskGuid; PartitionIdentifier = $CacheGuid }
    foreach ($t in [uint32]0x11000001, [uint32]0x21000001) {
        $null = Call $loader 'SetQualifiedPartitionDeviceElement' @{ Type = $t; PartitionStyle = [uint32]1; DiskSignature = $DiskGuid; PartitionIdentifier = $WindowsGuid }
    }
    $null = Call $loader 'SetBooleanElement' @{ Type = [uint32]0x16000060; Boolean = $false }   # isolated context off
    $null = Call $mgr 'SetIntegerElement' @{ Type = [uint32]0x25000004; Integer = [uint64]0 }     # no boot menu wait
    Invoke-Native bcdedit.exe @('/store', $bcd, '/enum', 'all')

    Step "Copying the ESP files to $espOut"
    if (Test-Path $espOut) { Remove-Item $espOut -Recurse -Force }
    Copy-Item (Join-Path $S 'EFI') (Join-Path $espOut 'EFI') -Recurse
    Get-FileHash (Join-Path $W 'Windows\System32\ntoskrnl.exe'), (Join-Path $W 'Windows\System32\winload.efi') |
        ForEach-Object { '{0}  {1}' -f $_.Hash.ToLower(), (Split-Path $_.Path -Leaf) }
    $vol = Get-Volume -DriveLetter $winLetter
    Write-Host ("Windows volume used: {0:N1} GB" -f (($vol.Size - $vol.SizeRemaining) / 1GB))
}
finally {
    if ($vhdAttached) { Dismount-VHD -Path $vhdx -ErrorAction SilentlyContinue }
    if ($isoMount) { Dismount-DiskImage -ImagePath $Iso -ErrorAction SilentlyContinue | Out-Null }
}

Step 'Handing the VHDX to WSL (read by tools/s10e/push-windows.sh)'
wsl.exe --mount --vhd $vhdx --bare
if ($LASTEXITCODE -ne 0) { throw 'wsl --mount failed' }
Write-Host "`nDONE. Image: $vhdx  ESP files: $espOut  Log: $log" -ForegroundColor Green
Stop-Transcript | Out-Null
