<#
.SYNOPSIS
    Intune Win32 app requirement rule - Intel vPro Fleet Services Agent
.DESCRIPTION
    Makes the Fleet Services Agent applicable only to devices that can actually be provisioned.
    Hardware logic is taken from Remediations\Test-vProCapabilities\detection.ps1:
      - SMBIOS $AMT structure confirms a vPro SKU (Full AMT, or Standard Manageability on ME >= 16)
        Fallback when SMBIOS cannot be queried: Intel CPU + ME device + (vPro brand string or AMT WMI)
      - Intel MEI driver is functional (the agent talks to AMT through it)
    AMT provisioning state and LMS are ignored on purpose: provisioning is the agent's job.

    Writes exactly one line to STDOUT: "Supported" or "NotSupported".
    Diagnostics go to C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\vProFleetAgent-Requirement.log
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

$logPath = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\vProFleetAgent-Requirement.log"
$issues  = [System.Collections.Generic.List[string]]::new()

# ═══════════════════════════════════════════════════════════════════
# 1. CPU
# ═══════════════════════════════════════════════════════════════════
$proc            = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
$isIntelCPU      = ($proc.Manufacturer -match "Intel" -or $proc.Name -match "Intel")
$cpuSupportsvPro = ($proc.Name -match "vPro")
if (-not $isIntelCPU) {
    $issues.Add("CPU is not Intel ($($proc.Manufacturer))")
}

# ═══════════════════════════════════════════════════════════════════
# 2. SMBIOS-based ME/AMT hardware check (authoritative)
# ═══════════════════════════════════════════════════════════════════
$smbiosCheckRan    = $false
$smbiosvProCapable = $false
$smbiosMESkuStr    = "Unknown"
$smbiosMEVersion   = "N/A"
try {
    $smbiosBytes = (Get-WmiObject -Namespace root\WMI -Class MS_SmBios -ErrorAction Stop).SMBiosData
    $smbiosHex   = [System.BitConverter]::ToString($smbiosBytes)

    $smbiosCheckRan = $true
    if ($smbiosHex.Contains('24-41-4D-54')) {
        [int]$signatureLoc = $smbiosHex.IndexOf('24-41-4D-54')
        [int]$tableLength  = [convert]::ToInt16($smbiosHex.Substring($signatureLoc - 9).Substring(0, 2), 16)

        # Offset calculation differs for 12th-gen+ CPUs (table length > 20)
        if ($tableLength -eq 20) {
            [int]$offset = 173
        } else {
            [int]$offset = 173 + ($tableLength - 20) * 3
        }

        # SKU bits: 8 = Full AMT, 16 = Standard Manageability, 32 = SBA
        $skuHex = $smbiosHex.Substring($signatureLoc - 12, $offset).Substring($offset - 35, 5)
        $skuInt = [convert]::ToUInt16($skuHex.Substring(3, 2) + $skuHex.Substring(0, 2), 16)

        $smbiosMESkuStr = if ($skuInt -band 8)  { "Intel(R) Full AMT Manageability" }
                          elseif ($skuInt -band 16) { "Intel(R) Standard Manageability" }
                          elseif ($skuInt -band 32) { "Intel(R) Small Business Advantage" }
                          else                       { "Consumer" }

        # ME firmware version (hex order: min, maj, rev, hf -> displayed as maj.min.hf.rev)
        $verHex = $smbiosHex.Substring($signatureLoc - 12, $offset).Substring($offset - 23, 23)
        $minVer = [convert]::ToInt16($verHex.Substring(3,  2) + $verHex.Substring(0,  2), 16)
        $majVer = [convert]::ToInt16($verHex.Substring(9,  2) + $verHex.Substring(6,  2), 16)
        $revVer = [convert]::ToInt16($verHex.Substring(15, 2) + $verHex.Substring(12, 2), 16)
        $hfVer  = [convert]::ToInt16($verHex.Substring(21, 2) + $verHex.Substring(18, 2), 16)
        $smbiosMEVersion = "$majVer.$minVer.$hfVer.$revVer"

        # vPro Essentials = Standard Manageability + ME >= 16; vPro Enterprise = Full AMT
        if (($skuInt -band 8) -or (($skuInt -band 16) -and ($majVer -ge 16))) {
            $smbiosvProCapable = $true
        } else {
            $issues.Add("SMBIOS: ME SKU is '$smbiosMESkuStr' (ME v$majVer) - not vPro capable")
        }
    } else {
        $issues.Add("SMBIOS: No Intel AMT signature found")
    }
} catch {
    $smbiosCheckRan = $false
    $issues.Add("SMBIOS check could not run: $($_.Exception.Message)")
}

# ═══════════════════════════════════════════════════════════════════
# 3. ME hardware + MEI driver
# ═══════════════════════════════════════════════════════════════════
# Without a driver the ME shows up as "PCI Simple Communications Controller", so also match the
# hardware ID: Intel PCI function with class code 07 80 (other communication controller). Only for
# devices without a working driver, since 07 80 may be shared with other Intel functions.
$meDevices         = Get-PnpDevice | Where-Object { $_.FriendlyName -match "Management Engine|CSME|MEI|HECI" -or
                                                    ($_.HardwareID -match '^PCI\\VEN_8086&.*&CC_0780' -and $_.Status -ne 'OK') }
$meHardwarePresent = [bool]$meDevices
$meiDriverOK       = [bool]($meDevices | Where-Object { $_.Status -eq "OK" })
if (-not $meHardwarePresent) {
    $issues.Add("No Intel Management Engine device found")
} elseif (-not $meiDriverOK) {
    $issues.Add("ME device found but MEI driver is not functional (status: $(($meDevices | Select-Object -First 1).Status))")
}

# AMT WMI is only needed for the fallback path
$amtWMIAvailable = $false
if (-not $smbiosCheckRan) {
    foreach ($ns in @("root\Intel_ME", "root\CIMV2\Intel_ME")) {
        if (Get-CimInstance -Namespace $ns -ClassName "ME_System") {
            $amtWMIAvailable = $true
            break
        }
    }
}

# ═══════════════════════════════════════════════════════════════════
# 4. Verdict
# ═══════════════════════════════════════════════════════════════════
$hardwareCapable = if ($smbiosCheckRan) {
    $smbiosvProCapable
} else {
    $isIntelCPU -and $meHardwarePresent -and ($cpuSupportsvPro -or $amtWMIAvailable)
}

$verdict = if ($hardwareCapable -and $meiDriverOK) { "Supported" } else { "NotSupported" }

# ═══════════════════════════════════════════════════════════════════
# 5. Log and output (STDOUT must contain only the verdict)
# ═══════════════════════════════════════════════════════════════════
try {
    $logLine = "{0} | {1} | CPU='{2}' SMBIOSRan={3} SKU='{4}' ME={5} MEIDriverOK={6} | {7}" -f
        (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $verdict, $proc.Name, $smbiosCheckRan,
        $smbiosMESkuStr, $smbiosMEVersion, $meiDriverOK, ($issues -join '; ')
    # Requirement scripts run on every evaluation, so keep the log small
    if ((Get-Item -LiteralPath $logPath).Length -gt 1MB) {
        Remove-Item -LiteralPath $logPath -Force
    }
    Add-Content -LiteralPath $logPath -Value $logLine -Encoding UTF8
} catch {}

Write-Output $verdict
exit 0
