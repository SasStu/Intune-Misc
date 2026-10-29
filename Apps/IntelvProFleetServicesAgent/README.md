# IntelvProFleetServicesAgent

PSAppDeployToolkit 4.1 package that installs the Intel vPro Fleet Services Agent and pairs the
device with Fleet Services. The MSI picks up the `PairingToken` file from its own directory, so the
token ships next to the MSI in `Files\`.

Only `Invoke-AppDeployToolkit.ps1` and the Intune [Requirement.ps1](Requirement.ps1) are versioned here. The PSADT framework files, the MSI and the
`PairingToken` are added at build time (see [.gitignore](.gitignore)). Do not commit the token.

## Behaviour

| Deployment type | What happens |
| --- | --- |
| Install | Checks that `Files\vProFleetAgent.Installer.msi` and `Files\PairingToken` exist and are not empty (else exit `69001`), then installs the MSI with `INSTALLATION_TYPE=STANDARD` |
| Uninstall | Runs `IntelvProFleetServicesAgent.exe un-pair` (best effort, 5 min timeout, failures are logged as warnings), then uninstalls the MSI |
| Repair | Same file checks as Install, then repairs the MSI |

`INSTALLATION_TYPE=STANDARD` covers devices without an 802.1X profile and 802.1X with Windows
Integrated authentication. No proxy is configured. To change this, edit `$msiProperties` in the
script (e.g. `'INSTALLATION_TYPE=STANDARD', 'CONFIGURE_PROXY=YES', 'PROXY_URL=http://proxy:8080'`).

Logs: `C:\Windows\Logs\Software\Intel_vProFleetServicesAgent_1.2.7_EN_01_PSAppDeployToolkit_<Type>.log`
plus the msiexec log next to it.

## Build

```powershell
Install-Module PSAppDeployToolkit -RequiredVersion 4.1.8 -Scope CurrentUser
New-ADTTemplate -Destination C:\Build -Name IntelvProFleetServicesAgent -Version 4

$pkg = 'C:\Build\IntelvProFleetServicesAgent'
Copy-Item .\Invoke-AppDeployToolkit.ps1 $pkg -Force
Copy-Item <download folder>\vProFleetAgent.Installer.msi, <download folder>\PairingToken "$pkg\Files\"

# ProductCode for the Intune detection rule
Import-Module PSAppDeployToolkit
Get-ADTMsiTableProperty -LiteralPath "$pkg\Files\vProFleetAgent.Installer.msi" -Table Property |
    Select-Object ProductName, ProductVersion, ProductCode

IntuneWinAppUtil.exe -c $pkg -s Invoke-AppDeployToolkit.exe -o C:\Build\Out
```

Keep `AppVersion` in the script in sync with the MSI `ProductVersion` (it is part of the log name).

## MSI reference (1.2.7)

| Property | Value |
| --- | --- |
| ProductName | Intel vPro(R) Fleet Services Agent 1.2.7 (version is part of the name, so do not detect by name) |
| ProductCode | `{091A3171-34D0-444F-8826-C72E7CECDDC1}` |
| UpgradeCode | `{5D76BF8E-50C1-4716-A85A-B2B9CDBD9EEC}` |
| ALLUSERS | `1` (per-machine) |
| CLEANAGENTDATA | `TRUE` (default, agent data is removed on uninstall) |
| SCEP_AUTH_TYPE / SCEP_CHALLENGE_TYPE | `WINDOWS` / `DYNAMIC` (defaults matching `INSTALLATION_TYPE=STANDARD`) |

## Intune Win32 app

| Setting | Value |
| --- | --- |
| Install command | `Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent` |
| Uninstall command | `Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent` |
| Install behavior | System |
| Device restart behavior | Determine behavior based on return codes |
| Return codes | Defaults, plus `69001` = Failed (package built without MSI/PairingToken) |
| Requirement rule | Script [Requirement.ps1](Requirement.ps1), see [Requirement script](#requirement-script) |
| Detection rule | MSI, product code `{091A3171-34D0-444F-8826-C72E7CECDDC1}` (1.2.7), version check optional |

### Requirement script

[Requirement.ps1](Requirement.ps1) limits the app to devices that can be provisioned, using the
hardware logic from [Test-vProCapabilities](../../Remediations/Test-vProCapabilities/):

- SMBIOS `$AMT` structure reports Full AMT, or Standard Manageability on ME 16+ (vPro Enterprise /
  Essentials). If SMBIOS cannot be read, falls back to Intel CPU + ME device + vPro brand string or AMT WMI.
- The Intel MEI driver is functional. The agent talks to AMT through it.

AMT provisioning state and the LMS service are not checked, since provisioning is the agent's job.

**Output:** exactly one line on STDOUT, exit code always `0`.

| STDOUT | Meaning |
| --- | --- |
| `Supported` | vPro capable hardware and a working MEI driver, the app is applicable |
| `NotSupported` | Anything else, the device shows as "Not applicable" |

**Intune settings** (Requirements > Add > Script):

| Setting | Value |
| --- | --- |
| Script file | `Requirement.ps1` |
| Run script as 32-bit process on 64-bit clients | No |
| Run this script using the logged on credentials | No |
| Enforce script signature check | No |
| Select output data type | String |
| Operator | Equals |
| Value | `Supported` (case-sensitive) |

Intune re-evaluates requirements on every check-in, so a device becomes applicable once its MEI
driver is fixed. The reason for a `NotSupported` result is not written to STDOUT (it would break the
string comparison) but logged to
`C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\vProFleetAgent-Requirement.log`
(included in "Collect diagnostics", capped at 1 MB).

### Detection

The detection rule proves the agent is installed, not that pairing succeeded. Check pairing in the
Fleet Services portal or with `IntelvProFleetServicesAgent.exe endpoint-info` on the device.

## Notes

- Assign the [IntelManagementEngineDriver](../IntelManagementEngineDriver/README.md) app as
  **Required** to the same group. A dependency alone does not help devices with a broken MEI driver:
  Intune evaluates this app's requirement first, the app is "Not applicable" and its dependencies are
  never installed. Once the driver app has fixed the MEI driver, the requirement passes on the next
  evaluation and the agent installs.
- The `PairingToken` is inside the `.intunewin`. Treat the package as a secret and rebuild it when
  the token is rotated in the Fleet Services portal.
- A new MSI version usually has a new ProductCode: update the detection rule and use supersedence.
- [Test-vProCapabilities](../../Remediations/Test-vProCapabilities/) reports the full vPro state
  (including provisioning) fleet-wide. Its hardware logic is duplicated in `Requirement.ps1`, so keep
  both in sync when changing the SMBIOS check.
