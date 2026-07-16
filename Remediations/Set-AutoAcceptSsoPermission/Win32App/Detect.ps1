<#
.SYNOPSIS
    Win32 App Detection - AutoAcceptSsoPermission policy
.DESCRIPTION
    Intune Win32 app custom detection script.
    Detection rule contract:
      Installed     -> exit 0 AND write to STDOUT
      Not installed -> exit 0 with NO output (or exit 1)
#>

$ErrorActionPreference = "SilentlyContinue"

$RegPath   = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AAD"
$ValueName = "AutoAcceptSsoPermission"
$Expected  = 1

$current = (Get-ItemProperty -Path $RegPath -Name $ValueName -ErrorAction SilentlyContinue).$ValueName

if ($current -eq $Expected) {
    Write-Output "Installed: $ValueName = $current"
    exit 0
}

# Not detected - no output, non-zero exit
exit 1
