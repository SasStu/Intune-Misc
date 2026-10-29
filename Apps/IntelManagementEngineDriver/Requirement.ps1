<#
.SYNOPSIS
    Intune Win32 app requirement rule - Intel Management Engine Driver
.DESCRIPTION
    Makes the MEI + LMS driver package applicable to every device with an Intel Management Engine,
    in any driver state. Devices with a missing or broken MEI driver are exactly the ones to fix.

    The ME is matched as a present PCI device by name, or by hardware ID (Intel PCI function with
    class code 07 80) when it has no working driver. Without a driver Windows names it
    "PCI Simple Communications Controller", so the name match alone misses it. With a driver the
    ME carries its own name, and class 07 80 may be shared with other Intel functions.

    Writes exactly one line to STDOUT: "Supported" or "NotSupported".
    Diagnostics go to C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntelMEDriver-Requirement.log
.NOTES
    Intune requirement rule:
      Output data type          : String
      Operator                  : Equals
      Value                     : Supported
      Run script as 32-bit      : No
      Run with logged on creds  : No
      Enforce signature check   : No
#>

$ErrorActionPreference = "SilentlyContinue"

$logPath = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\IntelMEDriver-Requirement.log"

$meDevices = Get-PnpDevice -PresentOnly |
             Where-Object { $_.InstanceId -like 'PCI\*' -and
                            ($_.FriendlyName -match "Management Engine|CSME|MEI|HECI" -or
                             ($_.HardwareID -match '^PCI\\VEN_8086&.*&CC_0780' -and $_.Status -ne 'OK')) }

$verdict = if ($meDevices) { "Supported" } else { "NotSupported" }

try {
    $devices = ($meDevices | ForEach-Object { "'$($_.FriendlyName)' ($($_.Status))" }) -join ', '
    $logLine = "{0} | {1} | ME devices: {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $verdict, $(if ($devices) { $devices } else { "none" })
    # Requirement scripts run on every evaluation, so keep the log small
    if ((Get-Item -LiteralPath $logPath).Length -gt 1MB) {
        Remove-Item -LiteralPath $logPath -Force
    }
    Add-Content -LiteralPath $logPath -Value $logLine -Encoding UTF8
} catch {}

Write-Output $verdict
exit 0
