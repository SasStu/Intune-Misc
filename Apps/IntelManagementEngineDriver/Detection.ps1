<#
.SYNOPSIS
    Intune Win32 app detection script - Intel Management Engine Driver
.DESCRIPTION
    Detected when all of these are true:
      - The Intel ME PCI device has a working driver (status OK)
      - Its driver version is $requiredVersion or newer (a newer OEM driver counts as installed)
      - The Intel LMS service exists
      - The Intel_ME WMI namespace exists (root\Intel_ME or root\CIMV2\Intel_ME)
      - If an AMT Serial Over LAN port is present (vPro only), it has a working driver
    Writes "Detected" to STDOUT when detected, nothing otherwise. Exit code is always 0.
.NOTES
    Keep $requiredVersion in sync with AppVersion in Invoke-AppDeployToolkit.ps1 (the MEI INF DriverVer).
    An empty or invalid value never detects, so a forgotten update shows up as a failed install.
#>

$requiredVersion = '2603.9.4.0'

$ErrorActionPreference = "SilentlyContinue"

$required = $null
if (-not [version]::TryParse($requiredVersion, [ref]$required)) {
    exit 0
}

$pciDevices = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'PCI\*' }

# Working ME devices. With a driver the ME always carries its own name; the hardware ID match in
# Requirement.ps1 is only for driverless devices, since class 07 80 may be shared with other Intel functions.
$meDevices = $pciDevices |
             Where-Object { $_.Status -eq 'OK' -and $_.FriendlyName -match "Management Engine|CSME|MEI|HECI" }

$meiCurrent = $false
foreach ($device in $meDevices) {
    $installed = $null
    $driverVersion = (Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName "DEVPKEY_Device_DriverVersion").Data
    if ([version]::TryParse($driverVersion, [ref]$installed) -and $installed -ge $required) {
        $meiCurrent = $true
        break
    }
}

$lmsPresent = [bool](Get-Service -Name "LMS")

$wmiPresent = [bool]((Get-CimInstance -Namespace "root" -ClassName "__NAMESPACE" -Filter "Name = 'Intel_ME'") -or
                     (Get-CimInstance -Namespace "root\CIMV2" -ClassName "__NAMESPACE" -Filter "Name = 'Intel_ME'"))

# AMT SOL is an Intel PCI serial port (class code 07 00, vPro only). Without a driver it shows as "PCI Serial Port".
$solBroken = [bool]($pciDevices |
                    Where-Object { $_.Status -ne 'OK' -and
                                   ($_.FriendlyName -match "Serial Over LAN|\bSOL\b" -or
                                    $_.HardwareID -match '^PCI\\VEN_8086&.*&CC_0700') })

if ($meiCurrent -and $lmsPresent -and $wmiPresent -and -not $solBroken) {
    Write-Output "Detected"
}
exit 0
