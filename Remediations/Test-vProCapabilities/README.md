# Test-vProCapabilities

Detection-only remediation that reports the Intel vPro / AMT state of every device and separates
**hardware** gaps (cannot be fixed remotely) from **software** gaps (driver, service, provisioning),
so you can see which devices can be brought into Intel vPro Fleet Services and what is missing.

There is no remediation script. The fixes are deployed as Win32 apps:
[IntelManagementEngineDriver](../../Apps/IntelManagementEngineDriver/README.md) (MEI driver, LMS,
WMI provider) and [IntelvProFleetServicesAgent](../../Apps/IntelvProFleetServicesAgent/README.md)
(provisioning).

## How it works

**detection.ps1** runs these checks:

| Check | Source | Gap type |
| --- | --- | --- |
| Intel CPU, `vPro` in brand string | `Win32_Processor` | Hardware |
| ME SKU, ME firmware version, ME enabled | SMBIOS `$AMT` structure (`MS_SmBios`) | Hardware |
| ME PCI device present (any driver state) | `Get-PnpDevice`, by name or Intel class `07 80` without a working driver | Hardware |
| MEI driver working, driver version | PnP device status | Software |
| `LMS` service exists and is running | `Get-Service` | Software |
| AMT WMI provider, AMT version | `ME_System` in `root\Intel_ME` or `root\CIMV2\Intel_ME` | Software |
| AMT provisioning state | `OOB_Service.GetProvisioningState()`, fallback Intel SCS registry keys | Software |

SMBIOS is the authoritative hardware gate: Full AMT (vPro Enterprise) or Standard Manageability on
ME 16+ (vPro Essentials) count as capable. Only if SMBIOS cannot be read does the script fall back to
Intel CPU + ME device + vPro brand string or AMT WMI.

| Status | Exit | Meaning |
| --- | --- | --- |
| `FullyReady` | `0` | Capable hardware, MEI driver OK, LMS running, AMT WMI available, AMT provisioned (or in provisioning) |
| `SoftwareActionNeeded` | `1` | Hardware is vPro capable, see `SoftwareIssues` |
| `HardwareNotCapable` | `1` | No vPro hardware, see `HardwareIssues` |

**Output:** one compressed JSON line with all fields (`vProStatus`, `SMBIOSMESkuStr`,
`MEIDriverVersion`, `AMTProvisionState`, `HardwareIssues`, `SoftwareIssues`, ...), followed by a
`STATUS: <status> - <issues>` line.

## Deploy as Proactive Remediation

Intune > Devices > Scripts and remediations > Create:

| Setting | Value |
| --- | --- |
| Detection script | `detection.ps1` |
| Remediation script | none |
| Run this script using the logged-on credentials | No |
| Enforce script signature check | No |
| Run script in 64-bit PowerShell | Yes |

Devices with exit `1` show as "With issues". Add the "Pre-remediation detection output" column to
the device status view and export it to split them into `SoftwareActionNeeded` and
`HardwareNotCapable`.

## Testing on a client

Run in an elevated 64-bit PowerShell:

```powershell
.\detection.ps1
.\detection.ps1 | Select-Object -First 1 | ConvertFrom-Json   # JSON as an object
```

## Notes

- The SMBIOS check and the ME device match are duplicated in the
  [IntelvProFleetServicesAgent Requirement.ps1](../../Apps/IntelvProFleetServicesAgent/Requirement.ps1),
  the ME device match also in the
  [IntelManagementEngineDriver Requirement.ps1](../../Apps/IntelManagementEngineDriver/Requirement.ps1).
  Keep them in sync when changing either.
- `FullyReady` needs the Intel ME WMI provider, which the IntelManagementEngineDriver app installs.
  Without it a provisioned device still reports `SoftwareActionNeeded`.
- `In-Provisioning` counts as provisioned, same as `Post-Provisioning`.
