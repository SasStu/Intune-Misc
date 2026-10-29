# IntelManagementEngineDriver

PSAppDeployToolkit 4.1 package that installs these components from Intel's
[Management Engine Drivers for Windows 10 and Windows 11](https://www.intel.com/content/www/us/en/download/682431/intel-management-engine-drivers-for-windows-10-and-windows-11.html)
download, using `pnputil` and the DCH INFs:

The folders in `Files\` have the same names as in Intel's `Drivers\` folder, so they are copied as is.

| Folder | Component | Why |
| --- | --- | --- |
| `Files\MEI` | Intel Management Engine Interface (MEI) driver | Fleet Services Agent and everything else talk to the ME through it |
| `Files\LMS` | Intel Local Manageability Service (LMS) | Local AMT access |
| `Files\WMIProvider` | Intel ME WMI provider (`root\Intel_ME`) | [Test-vProCapabilities](../../Remediations/Test-vProCapabilities/) needs it for `FullyReady` and to read the AMT provisioning state |
| `Files\SOL`, `Files\SOL_LMS_Extension` | Intel AMT Serial Over LAN driver and its LMS extension | Driver for the AMT serial port (vPro only), otherwise an unknown "PCI Serial Port" in Device Manager |

DAL is not installed.

Only the scripts and this README are versioned here. The PSADT framework files and the driver
folders are added at build time (see [.gitignore](.gitignore)).

## Behaviour

| Deployment type | What happens |
| --- | --- |
| Install | Checks that each driver folder contains INF files (else exit `69001`) and that an MEI INF has `DriverVer` equal to `AppVersion` (else exit `69002`). Then runs `pnputil /add-driver <inf> /install` for every INF, folder by folder in that order. INFs below legacy OS folders (`win7`, `win8`, `win81`, e.g. `MEI\win8`) are skipped |
| Uninstall | Finds the `oemNN.inf` packages published from the package INFs (same file name and version, via `Get-WindowsDriver -Online`) and runs `pnputil /delete-driver oemNN.inf /uninstall` in reverse order. The devices fall back to the next best driver in the store (OEM or Windows Update) |
| Repair | Same as Install |

pnputil exit codes: `0` success, `3010` reboot required, `259` treated as success (driver added to
the store, but no device needed an update: the same or a newer driver is already installed, or there
is no matching device, e.g. SOL on a non-vPro platform).

LMS and the WMI provider are software components of the MEI device, so they only show up once the
MEI driver is active. If the LMS service or the `Intel_ME` WMI namespace is missing after install,
the log has a warning (they may appear after a reboot).

Logs: `C:\Windows\Logs\Software\Intel_ManagementEngineDriver_<AppVersion>_EN_01_PSAppDeployToolkit_<Type>.log`,
including the pnputil output.

## Build

1. Download the zip from Intel and extract it. `Intel(R)_CSME_SW_Installation_Guide.pdf` in the zip
   lists the components and their folders.
2. Create the PSADT template and copy the scripts:

   ```powershell
   Install-Module PSAppDeployToolkit -RequiredVersion 4.1.8 -Scope CurrentUser
   New-ADTTemplate -Destination C:\Build -Name IntelManagementEngineDriver -Version 4

   $pkg = 'C:\Build\IntelManagementEngineDriver'
   Copy-Item .\Invoke-AppDeployToolkit.ps1 $pkg -Force
   ```

3. Copy the DCH driver folders from the extracted zip (layout of `intel_security_engine_software_ME_2618.9.30.0`):

   ```powershell
   $src = '<download folder>\intel_security_engine_software_ME_2618.9.30.0\Drivers'
   'MEI', 'LMS', 'WMIProvider', 'SOL', 'SOL_LMS_Extension' |
       ForEach-Object { Copy-Item "$src\$_" "$pkg\Files\$_" -Recurse }
   ```

   Every `*.inf` below each folder is installed, except below legacy OS folders like `MEI\win8`
   (copying them along is fine, the script skips them). Not used from `Drivers\`: `ICLS`, `IMSS`,
   `IMSS_HSA_Extension`, `IMSS_Store`, `ISSEI`, `JHI` (DAL), `WiMan`, `wiman_wlan_extension`.
4. Read the MEI driver version and set it in **both** `AppVersion` (`Invoke-AppDeployToolkit.ps1`)
   and `$requiredVersion` ([Detection.ps1](Detection.ps1)):

   ```powershell
   Get-ChildItem "$pkg\Files" -Filter *.inf -Recurse |
       Select-String -Pattern '^\s*DriverVer' | Select-Object Path, Line
   ```

5. Package it:

   ```powershell
   IntuneWinAppUtil.exe -c $pkg -s Invoke-AppDeployToolkit.exe -o C:\Build\Out
   ```

Current values (bundle `ME_2618.9.30.0`): MEI `heci.inf` `2603.9.4.0`, LMS `LMS.inf` `2613.9.7.0`
(WMI and SOL versions not recorded yet).
`AppVersion` and `$requiredVersion` are both `2603.9.4.0`. If `AppVersion` does not match the MEI INF,
the install fails with `69002`, and an empty or invalid `$requiredVersion` never detects.

## Intune Win32 app

| Setting | Value |
| --- | --- |
| Install command | `Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent` |
| Uninstall command | `Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent` |
| Install behavior | System |
| Device restart behavior | Determine behavior based on return codes |
| Return codes | Defaults, plus `69001` and `69002` = Failed (package built without INFs or with a mismatched version) |
| Requirement rule | Script [Requirement.ps1](Requirement.ps1), see [Requirement script](#requirement-script) |
| Detection rule | Script [Detection.ps1](Detection.ps1), see [Detection script](#detection-script) |

### Requirement script

[Requirement.ps1](Requirement.ps1) makes the app applicable to every device with an Intel ME PCI
device present, in any driver state. The device is matched by name, or, if it has no working driver,
by hardware ID (Intel PCI function with class code `07 80`), because without a driver Windows names
it "PCI Simple Communications Controller". The hardware ID is not used for devices with a working
driver, since `07 80` may be shared with other Intel functions (e.g. Serial IO).

**Output:** exactly one line on STDOUT, exit code always `0`.

| STDOUT | Meaning |
| --- | --- |
| `Supported` | An Intel ME device is present, the app is applicable |
| `NotSupported` | No ME device (AMD, VM, ...), the device shows as "Not applicable" |

The matched devices and their status are logged to
`C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntelMEDriver-Requirement.log` (capped at 1 MB).

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

### Detection script

[Detection.ps1](Detection.ps1) reports the app as installed when all of these are true:

- The ME PCI device has a working driver with version `$requiredVersion` or newer
- The `LMS` service exists
- The `Intel_ME` WMI namespace exists (`root\Intel_ME` or `root\CIMV2\Intel_ME`)
- No AMT Serial Over LAN port (Intel PCI class `07 00`) without a working driver is present

A newer OEM driver also counts as installed, so the package does not fight Windows Update or OEM
tools. Component versions of LMS, WMI and SOL are not checked, only their presence.

| Setting | Value |
| --- | --- |
| Rules format | Use a custom detection script |
| Script file | `Detection.ps1` |
| Run script as 32-bit process on 64-bit clients | No |
| Enforce script signature check | No |

## Testing on a client

Run in an elevated 64-bit PowerShell:

```powershell
.\Requirement.ps1          # expect "Supported" on Intel ME hardware
.\Detection.ps1            # "Detected" or nothing; set $requiredVersion first
Get-PnpDevice | Where-Object { $_.HardwareID -match '^PCI\\VEN_8086&.*&CC_07(80|00)' } |
    Select-Object Status, FriendlyName, InstanceId   # ME (07 80) and SOL (07 00) devices
```

Then install from the built package folder with
`.\Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent` and check the PSADT log,
the MEI driver version in Device Manager, `Get-Service LMS`,
`Get-CimInstance -Namespace root\Intel_ME -ClassName ME_System` and the SOL COM port under "Ports".

## Notes

- Assign this app as **Required** to the same group as the
  [IntelvProFleetServicesAgent](../IntelvProFleetServicesAgent/README.md) app. Do not rely on a
  dependency only: the agent's requirement needs a working MEI driver, so on devices without one the
  agent is "Not applicable" and Intune never installs its dependencies.
- A new Intel release means: replace the driver folders, update `AppVersion` and
  `$requiredVersion`, rebuild, and use supersedence.
- [Test-vProCapabilities](../../Remediations/Test-vProCapabilities/) reports MEI, LMS and AMT WMI
  problems fleet-wide and uses the same ME device match.
- On consumer ME platforms (no AMT), Intel may not create the LMS and WMI software components. If
  such devices keep failing detection and reinstalling, restrict the requirement to vPro capable
  devices (SMBIOS check from the Fleet Services Agent `Requirement.ps1`).
