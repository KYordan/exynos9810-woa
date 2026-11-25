<#
 .SYNOPSIS
   Catalogs and test-signs built driver packages with one throw-away test certificate.

 .DESCRIPTION
   For each package folder (an .inf next to its .sys): Inf2Cat makes the catalog, then the .sys and .cat are
   signed with a code-signing certificate created for this run, whose public part is written to every folder as
   s10e-test.cer. The private key is deleted at the end. The phone's Windows runs these with test signing on.

     .\sign-test-packages.ps1 -Packages out\hsi2c, out\touch
#>
[CmdletBinding()]
param([Parameter(Mandatory)] [string[]]$Packages)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Find-KitTool([string]$Name, [string]$Arch) {
    $root = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    $tool = Get-ChildItem $root -Recurse -Filter $Name -File -ErrorAction SilentlyContinue |
        Where-Object { $_.DirectoryName -match "\\$Arch$" } | Sort-Object FullName -Descending | Select-Object -First 1
    if ($null -eq $tool) { throw "$Name ($Arch) not found under $root" }
    $tool.FullName
}

$inf2cat = Find-KitTool 'Inf2Cat.exe' 'x86'
$signtool = Find-KitTool 'signtool.exe' 'x64'
$cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=S10e WOA Test Signing (drivers)' `
    -CertStoreLocation Cert:\CurrentUser\My -KeyExportPolicy Exportable -NotAfter (Get-Date).AddYears(10)
try {
    foreach ($dir in $Packages) {
        $dir = (Resolve-Path $dir).Path
        if (-not (Get-ChildItem $dir -Filter *.inf) -or -not (Get-ChildItem $dir -Filter *.sys)) { throw "$dir needs an .inf and a .sys" }
        $made = $false
        foreach ($os in '10_NI_ARM64', '10_GE_ARM64', '10_CO_ARM64') {
            & $inf2cat "/driver:$dir" "/os:$os" | Out-Host
            if ($LASTEXITCODE -eq 0 -and (Get-ChildItem $dir -Filter *.cat)) { Write-Host "Inf2Cat /os:$os"; $made = $true; break }
        }
        if (-not $made) { throw "Inf2Cat did not produce a catalog in $dir" }
        foreach ($file in (Get-ChildItem $dir -Include *.sys, *.cat -Recurse)) {
            & $signtool sign /fd sha256 /sha1 $cert.Thumbprint /s My $file.FullName | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "signtool failed on $($file.FullName)" }
        }
        Export-Certificate -Cert $cert -FilePath (Join-Path $dir 's10e-test.cer') | Out-Null
        Get-ChildItem $dir -File | ForEach-Object { '{0}  {1}' -f (Get-FileHash $_.FullName).Hash.ToLower(), $_.Name }
    }
}
finally {
    Remove-Item "Cert:\CurrentUser\My\$($cert.Thumbprint)" -Force
}
