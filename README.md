# Intune-Misc

A grab-bag of standalone PowerShell scripts and remediation packages for Intune/Entra administration. Each script is self-contained (own `.SYNOPSIS`/`.DESCRIPTION`/`.EXAMPLE` help) and not part of a shared module - run with `Get-Help .\Scripts\<name>.ps1 -Full` for details.

## Repository layout

| Folder | Contents |
| --- | --- |
| [Scripts/](Scripts/) | Standalone admin scripts, run manually against a tenant |
| [Remediations/](Remediations/) | Intune Proactive Remediation packages (detection + remediation scripts, optionally a Win32 app variant), one folder per remediation with its own README |
| [ConfigurationProfiles/](ConfigurationProfiles/) | Exported Intune configuration/Settings Catalog profiles and browser policy JSON, grouped by feature area, each with its own README |
| [Apps/](Apps/) | Win32 app packaging artifacts, e.g. the [IntelvProFleetServicesAgent](Apps/IntelvProFleetServicesAgent/README.md) and [IntelManagementEngineDriver](Apps/IntelManagementEngineDriver/README.md) PSADT packages |

## Scripts

### [New-EntraAppRegAuthCertificate.ps1](Scripts/New-EntraAppRegAuthCertificate.ps1)

Creates a self-signed certificate for Entra App Registration certificate authentication. Supports a software-backed key (optionally exported as a password-protected `.pfx`) or a TPM-backed, non-exportable key. Always writes a `.cer` file for upload to the App Registration's "Certificates & secrets" blade.

Requires: PowerShell 5.1+, run as Administrator.

### [New-AdePolicyFromProfile.ps1](Scripts/New-AdePolicyFromProfile.ps1)

Migrates a classic Apple ADE enrollment profile (depIOSEnrollmentProfile/depMacOSEnrollmentProfile) to a new Settings Catalog enrollment policy, copying every classic field that has a direct policy equivalent (including the nested macOS local admin/primary account tree) and defaulting new-only Setup Assistant screens via `-NewFieldDefault`. Can target a single profile or bulk-migrate every classic profile on a token, optionally set the new policy's enrollment-time device group, and supports `-WhatIf`. Fields with no policy equivalent are left out and listed in the summary for manual follow-up.

Requires: PowerShell 7.2+, `Microsoft.Graph.Authentication` module, `DeviceManagementServiceConfig.ReadWrite.All` scope (plus `Group.Read.All` if `-DeviceGroupName` is used).

### [Set-AdeDevicesToEnrollmentPolicy.ps1](Scripts/Set-AdeDevicesToEnrollmentPolicy.ps1)

Bulk-reassigns Apple ADE (ABM/ASM) devices from an enrollment program token to a target enrollment policy/profile via Microsoft Graph, working around the lack of a "select all" option in the Intune GUI. Can target all devices, a specific platform, or a list of serial numbers, and supports `-WhatIf`.

Requires: PowerShell 7.2+, `Microsoft.Graph.Authentication` module, `DeviceManagementServiceConfig.ReadWrite.All` scope.

## Remediations

### [Backup-BitlockerRecoveryKeys](Remediations/Backup-BitlockerRecoveryKeys/README.md)

Backs up BitLocker recovery passwords to Entra ID for every BitLocker-protected fixed drive (OS and data drives), not just `%SystemDrive%`. Detection checks the BitLocker-API event log for a successful backup (event `845`) per protector; remediation runs `BackupToAAD-BitLockerKeyProtector` for the missing ones. Both write a one-line per-drive summary for the Intune output.

### [Set-AutoAcceptSsoPermission](Remediations/Set-AutoAcceptSsoPermission/README.md)

Deploys the `AutoAcceptSsoPermission` registry policy that auto-accepts the Entra SSO permission prompt ("Continue to sign in") on managed Windows devices, so users no longer see the consent dialog when Windows shares their signed-in work account with Microsoft apps. Ships both a Proactive Remediation pair (`detection.ps1`/`remediation.ps1`) and a Win32 app variant (`Win32App/` with install/uninstall/detect scripts) - see the folder README for prerequisites (Windows 11 24H2/25H2 with KB5101650+) and deployment steps.

### [Set-GlobalSecureAccessClientSettings](Remediations/Set-GlobalSecureAccessClientSettings/README.md)

Applies the Global Secure Access **client-side** controls with no native Intune UI: HKLM hardening of the GSA client (`RestrictNonPrivilegedUsers`, hide tray Disable / Sign out / Disable Private Access). The `detection.ps1` / `install.ps1` / `uninstall.ps1` trio deploys as a Remediation script pair or a Win32 app. Browser-side settings (QUIC + DoH off) live under [ConfigurationProfiles/GlobalSecureAccess/](ConfigurationProfiles/GlobalSecureAccess/).

### [Test-vProCapabilities](Remediations/Test-vProCapabilities/README.md)

Detection-only remediation that reports each device's Intel vPro / AMT state as JSON: `FullyReady`, `SoftwareActionNeeded` (vPro hardware, but MEI driver, LMS, AMT WMI or provisioning missing) or `HardwareNotCapable` (based on the SMBIOS ME SKU). The software gaps are fixed by the two Intel apps under [Apps/](#apps).

## Apps

### [IntelManagementEngineDriver](Apps/IntelManagementEngineDriver/README.md)

PSADT 4.1 package that installs the Intel MEI driver, LMS, the ME WMI provider and the AMT SOL driver via `pnputil`, with a requirement script (any Intel ME device) and a detection script (minimum MEI driver version plus LMS, WMI and SOL present). Only the scripts are versioned, the driver folders are added at build time.

### [IntelvProFleetServicesAgent](Apps/IntelvProFleetServicesAgent/README.md)

PSADT 4.1 package that installs the Intel vPro Fleet Services Agent and pairs the device using the `PairingToken` shipped next to the MSI. Its requirement script limits it to vPro capable devices with a working MEI driver, so assign the driver app as Required to the same group. The MSI and the token are not versioned; treat the built `.intunewin` as a secret.

## Configuration Profiles

### [GlobalSecureAccess/](ConfigurationProfiles/GlobalSecureAccess/)

Browser policy so the GSA client can capture all web traffic: disables QUIC (HTTP/3 over UDP 443) and DNS over HTTPS, which Entra Internet Access can't inspect. `EdgeChrome/` is a Settings Catalog profile export (Edge + Chrome, 4 settings); `Firefox/` needs its own policy - shipped both as an ADMX preferences paste and a `policies.json` drop-in. Each folder README covers import and verification.

## Usage notes

- These are ad-hoc/remediation scripts, not a maintained toolset - review the parameters and use `-WhatIf` (where supported) before running against production tenants.
- No shared dependencies between scripts; each can be copied and run individually.
- Remediation packages under `Remediations/` are meant to be deployed via Intune (Proactive Remediations or Win32 apps), not run interactively - each folder's README documents the deployment settings.
