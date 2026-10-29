<#
.SYNOPSIS
    Intune Proactive Remediation - Detect Intel vPro Management Capability
.DESCRIPTION
    Checks whether a device supports Intel vPro / Active Management Technology (AMT).
    When a device is NOT fully vPro-ready, the output differentiates between:
      - Hardware gaps   (non-Intel CPU, no vPro SKU, no ME hardware) - cannot be fixed remotely
      - Software gaps   (missing MEI driver, LMS service, provisioning) - can be remediated
    Returns one of three statuses:
      FullyReady           (exit 0) - vPro hardware + software all in place
      SoftwareActionNeeded (exit 1) - hardware supports vPro, but drivers/services/config need attention
      HardwareNotCapable   (exit 1) - platform lacks vPro hardware support
.NOTES
    Deploy as a Detection Script in Intune Proactive Remediations.
    Run as: System (not user context)
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = "SilentlyContinue"

# ═══════════════════════════════════════════════════════════════════
# Result object
# ═══════════════════════════════════════════════════════════════════
$result = [ordered]@{
    ComputerName        = $env:COMPUTERNAME
    Manufacturer        = ""
    Model               = ""
    ProcessorName       = ""
    # ── Overall verdict ──
    vProStatus          = "Unknown"          # FullyReady | SoftwareActionNeeded | HardwareNotCapable
    vProCapable         = $false
    # ── Hardware checks ──
    IsIntelCPU          = $false
    CPUSupportsvPro     = $false             # Brand string contains "vPro"
    # ── SMBIOS hardware check (authoritative) ──
    SMBIOSCheckRan      = $false
    SMBIOSvProCapable   = $false             # SMBIOS confirms Full AMT or SM >= ME16 SKU
    SMBIOSMESkuStr      = "Unknown"
    SMBIOSMEVersion     = "N/A"
    SMBIOSMEEnabled     = $false
    MEHardwarePresent   = $false             # ME/CSME device exists in device manager (any driver state)
    # ── Software checks ──
    MEIDriverInstalled  = $false
    MEIDriverVersion    = "N/A"
    MEIDriverStatus     = "N/A"              # OK | Error | Degraded | Unknown
    LMSServiceExists    = $false
    LMSServiceRunning   = $false
    AMTWMIAvailable     = $false
    AMTVersion          = "N/A"
    AMTProvisionState   = "Unknown"
    # ── Diagnostic arrays ──
    HardwareIssues      = [System.Collections.Generic.List[string]]::new()
    SoftwareIssues      = [System.Collections.Generic.List[string]]::new()
}

# ═══════════════════════════════════════════════════════════════════
# 1. System / CPU info
# ═══════════════════════════════════════════════════════════════════
try {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $result.Manufacturer = $cs.Manufacturer
    $result.Model        = $cs.Model
} catch {}

try {
    $proc = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
    $result.ProcessorName = $proc.Name

    # Intel check
    if ($proc.Manufacturer -match "Intel" -or $proc.Name -match "Intel") {
        $result.IsIntelCPU = $true
    } else {
        $result.HardwareIssues.Add("CPU is not Intel ($($proc.Manufacturer)) - vPro requires an Intel processor")
    }

    # vPro brand string check
    if ($proc.Name -match "vPro") {
        $result.CPUSupportsvPro = $true
    } elseif ($result.IsIntelCPU) {
        $result.HardwareIssues.Add("Intel CPU does not advertise vPro in brand string - may not be a vPro SKU")
    }
} catch {}

# ═══════════════════════════════════════════════════════════════════
# 2. SMBIOS-based ME/AMT hardware check (authoritative)
#    Reads the Intel $AMT SMBIOS structure to determine the true ME
#    SKU - the only reliable way to distinguish vPro from Consumer
#    platforms that happen to have ME hardware in device manager.
# ═══════════════════════════════════════════════════════════════════
try {
    $smbiosBytes = (Get-WmiObject -Namespace root\WMI -Class MS_SmBios -ErrorAction Stop).SMBiosData
    $smbiosHex   = [System.BitConverter]::ToString($smbiosBytes)

    if ($smbiosHex.Contains('24-41-4D-54')) {
        $result.SMBIOSCheckRan = $true
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

        $result.SMBIOSMESkuStr = if ($skuInt -band 8)  { "Intel(R) Full AMT Manageability" }
                                 elseif ($skuInt -band 16) { "Intel(R) Standard Manageability" }
                                 elseif ($skuInt -band 32) { "Intel(R) Small Business Advantage" }
                                 else                       { "Consumer" }

        # ME firmware version (hex order: min, maj, rev, hf -> displayed as maj.min.hf.rev)
        $verHex  = $smbiosHex.Substring($signatureLoc - 12, $offset).Substring($offset - 23, 23)
        $minVer  = [convert]::ToInt16($verHex.Substring(3,  2) + $verHex.Substring(0,  2), 16)
        $majVer  = [convert]::ToInt16($verHex.Substring(9,  2) + $verHex.Substring(6,  2), 16)
        $revVer  = [convert]::ToInt16($verHex.Substring(15, 2) + $verHex.Substring(12, 2), 16)
        $hfVer   = [convert]::ToInt16($verHex.Substring(21, 2) + $verHex.Substring(18, 2), 16)
        $result.SMBIOSMEVersion = "$majVer.$minVer.$hfVer.$revVer"

        # ME enabled when both state bytes are 01
        if (($smbiosHex.Substring($signatureLoc + 12).Substring(0, 2) -eq '01') -and
            ($smbiosHex.Substring($signatureLoc + 12).Substring(3, 2) -eq '01')) {
            $result.SMBIOSMEEnabled = $true
        }

        # vPro Essentials = Standard Manageability + ME >= 16; vPro Enterprise = Full AMT
        if ($skuInt -band 8) {
            $result.SMBIOSvProCapable = $true
        } elseif (($skuInt -band 16) -and ($majVer -ge 16)) {
            $result.SMBIOSvProCapable = $true
        } else {
            $result.HardwareIssues.Add("SMBIOS: ME SKU is '$($result.SMBIOSMESkuStr)' (ME v$majVer) - not a vPro capable platform")
        }
    } else {
        $result.SMBIOSCheckRan = $true
        $result.HardwareIssues.Add("SMBIOS: No Intel AMT signature found - platform does not support AMT/vPro")
    }
} catch {
    $result.HardwareIssues.Add("SMBIOS check could not run: $($_.Exception.Message)")
}

# ═══════════════════════════════════════════════════════════════════
# 3. ME Hardware presence (device exists regardless of driver state)
# ═══════════════════════════════════════════════════════════════════
try {
    # Look for ANY Management Engine PnP device, even with a missing or errored driver.
    # Without a driver Windows names it "PCI Simple Communications Controller", so also match
    # the hardware ID: Intel PCI function with class code 07 80 (other communication controller).
    # Only for devices without a working driver, since 07 80 may be shared with other Intel functions.
    $meDevices = Get-PnpDevice -ErrorAction SilentlyContinue |
                 Where-Object { $_.FriendlyName -match "Management Engine|CSME|MEI|HECI" -or
                                ($_.HardwareID -match '^PCI\\VEN_8086&.*&CC_0780' -and $_.Status -ne 'OK') }

    if ($meDevices) {
        $result.MEHardwarePresent = $true

        # Now check if the driver is healthy
        $meiOK = $meDevices | Where-Object { $_.Status -eq "OK" } | Select-Object -First 1

        if ($meiOK) {
            $result.MEIDriverInstalled = $true
            $result.MEIDriverStatus    = "OK"
            $driverInfo = Get-PnpDeviceProperty -InstanceId $meiOK.InstanceId `
                            -KeyName "DEVPKEY_Device_DriverVersion" -ErrorAction SilentlyContinue
            if ($driverInfo.Data) {
                $result.MEIDriverVersion = $driverInfo.Data
            }
        } else {
            # Hardware exists but driver is missing or errored
            $bestDevice = $meDevices | Select-Object -First 1
            $result.MEIDriverStatus = $bestDevice.Status
            $result.SoftwareIssues.Add("ME hardware found but MEI driver is not functional (status: $($bestDevice.Status)) - install or update the Intel MEI driver")
        }
    } else {
        # No ME hardware at all
        if ($result.IsIntelCPU) {
            $result.HardwareIssues.Add("No Intel Management Engine hardware detected - chipset/platform may not support vPro")
        }
    }
} catch {}

# ═══════════════════════════════════════════════════════════════════
# 4. Intel LMS (Local Manageability Service)
# ═══════════════════════════════════════════════════════════════════
try {
    $lms = Get-Service -Name "LMS" -ErrorAction SilentlyContinue
    if ($lms) {
        $result.LMSServiceExists  = $true
        $result.LMSServiceRunning = ($lms.Status -eq "Running")
        if (-not $result.LMSServiceRunning) {
            $result.SoftwareIssues.Add("Intel LMS service exists but is not running (status: $($lms.Status)) - start the service or set to Automatic")
        }
    } else {
        # Only flag as a software issue if the hardware supports it
        if ($result.MEHardwarePresent) {
            $result.SoftwareIssues.Add("Intel LMS service is not installed - install Intel Manageability Software to enable AMT management")
        }
    }
} catch {}

# ═══════════════════════════════════════════════════════════════════
# 5. AMT WMI provider
# ═══════════════════════════════════════════════════════════════════
$amtNamespaces = @("root\Intel_ME", "root\CIMV2\Intel_ME")
$amtNamespace  = $null

foreach ($ns in $amtNamespaces) {
    try {
        $amtGeneral = Get-CimInstance -Namespace $ns -ClassName "ME_System" -ErrorAction Stop
        if ($amtGeneral) {
            $result.AMTWMIAvailable = $true
            $amtNamespace = $ns
            if ($amtGeneral.FWVersion) {
                $result.AMTVersion = $amtGeneral.FWVersion
            }
            break
        }
    } catch {}
}

if (-not $result.AMTWMIAvailable -and $result.MEHardwarePresent) {
    $result.SoftwareIssues.Add("Intel AMT WMI provider not available - install Intel Manageability SDK/Software or verify ME firmware supports AMT")
}

# ═══════════════════════════════════════════════════════════════════
# 6. AMT provisioning state
#    Primary: firmware via OOB_Service.GetProvisioningState() - reflects
#    the real state regardless of the provisioning tool (Fleet Services,
#    EMA, SCS, MEBX). Fallback: registry keys written only by Intel SCS.
#    The provider only supports static calls; calling the method on an
#    instance fails with "Provider failure" (0x80041004).
# ═══════════════════════════════════════════════════════════════════
$provisionStateNames = @{ 0 = "Pre-Provisioning"; 1 = "In-Provisioning"; 2 = "Post-Provisioning" }

if ($amtNamespace) {
    try {
        $ps = Invoke-CimMethod -Namespace $amtNamespace -ClassName "OOB_Service" -MethodName "GetProvisioningState" -ErrorAction Stop
        if ($ps.ReturnValue -eq 0 -and $null -ne $ps.state) {
            $state = [int]$ps.state
            $result.AMTProvisionState = if ($provisionStateNames.ContainsKey($state)) { $provisionStateNames[$state] } else { "Unknown ($state)" }
        }
    } catch {}
}

$amtRegPaths = @(
    "HKLM:\SOFTWARE\Intel\Setup and Configuration Software\SCCM",
    "HKLM:\SOFTWARE\Intel\AMT"
)

foreach ($path in $amtRegPaths) {
    try {
        if (Test-Path $path) {
            $props = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
            if ($null -ne $props.ProvisionState -and $result.AMTProvisionState -eq "Unknown") {
                $result.AMTProvisionState = switch ([int]$props.ProvisionState) {
                    0 { "Pre-Provisioning" }
                    1 { "In-Provisioning" }
                    2 { "Post-Provisioning" }
                    default { "Unknown ($($props.ProvisionState))" }
                }
            }
            if ($props.AMTVersion -and $result.AMTVersion -eq "N/A") {
                $result.AMTVersion = $props.AMTVersion
            }
        }
    } catch {}
}

# Flag unprovisioned AMT only when hardware + software are otherwise present
if ($result.AMTWMIAvailable -and $result.AMTProvisionState -notin @("Post-Provisioning", "In-Provisioning")) {
    $result.SoftwareIssues.Add("AMT is not provisioned (state: $($result.AMTProvisionState)) - provision via Intel vPro Fleet Services, Intel EMA, Intel SCS, or MEBX")
}

# ═══════════════════════════════════════════════════════════════════
# 7. Determine overall verdict
# ═══════════════════════════════════════════════════════════════════

$hasHardware = ($result.IsIntelCPU -and $result.MEHardwarePresent)

# SMBIOS is the authoritative hardware gate - it reads the actual ME SKU from firmware.
# PnP/brand-string fallback is used only when SMBIOS could not be queried (WMI unavailable).
$hardwareCapable = if ($result.SMBIOSCheckRan) {
    $result.SMBIOSvProCapable
} else {
    $hasHardware -and ($result.CPUSupportsvPro -or $result.AMTWMIAvailable)
}

# Fully ready = hardware capable + driver OK + LMS running + AMT available + provisioned
$fullyReady = $hardwareCapable -and
              $result.MEIDriverInstalled -and
              $result.LMSServiceRunning -and
              $result.AMTWMIAvailable -and
              ($result.AMTProvisionState -in @("Post-Provisioning", "In-Provisioning"))

if ($fullyReady) {
    $result.vProStatus  = "FullyReady"
    $result.vProCapable = $true
} elseif ($hardwareCapable) {
    $result.vProStatus  = "SoftwareActionNeeded"
    $result.vProCapable = $true              # Hardware can do it, software just needs attention
} else {
    $result.vProStatus  = "HardwareNotCapable"
    $result.vProCapable = $false
}

# ═══════════════════════════════════════════════════════════════════
# 8. Output and exit
# ═══════════════════════════════════════════════════════════════════

# Convert lists to arrays for clean JSON
$result.HardwareIssues = @($result.HardwareIssues)
$result.SoftwareIssues = @($result.SoftwareIssues)

$output = $result | ConvertTo-Json -Depth 3 -Compress
Write-Output $output

switch ($result.vProStatus) {
    "FullyReady" {
        Write-Output "STATUS: FullyReady - vPro hardware and software are in place"
        exit 0
    }
    "SoftwareActionNeeded" {
        Write-Output "STATUS: SoftwareActionNeeded - Hardware supports vPro but software/config issues found: $($result.SoftwareIssues -join '; ')"
        exit 1
    }
    "HardwareNotCapable" {
        Write-Output "STATUS: HardwareNotCapable - Device lacks vPro hardware: $($result.HardwareIssues -join '; ')"
        exit 1
    }
}
