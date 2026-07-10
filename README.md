# Intune-Misc

A grab-bag of standalone PowerShell scripts for Intune/Entra administration and remediation. Each script is self-contained (own `.SYNOPSIS`/`.DESCRIPTION`/`.EXAMPLE` help) and not part of a shared module - run with `Get-Help .\Scripts\<name>.ps1 -Full` for details.

## Scripts

### [New-EntraAppRegAuthCertificate.ps1](Scripts/New-EntraAppRegAuthCertificate.ps1)

Creates a self-signed certificate for Entra App Registration certificate authentication. Supports a software-backed key (optionally exported as a password-protected `.pfx`) or a TPM-backed, non-exportable key. Always writes a `.cer` file for upload to the App Registration's "Certificates & secrets" blade.

Requires: PowerShell 5.1+, run as Administrator.

### [Set-AdeDevicesToEnrollmentPolicy.ps1](Scripts/Set-AdeDevicesToEnrollmentPolicy.ps1)

Bulk-reassigns Apple ADE (ABM/ASM) devices from an enrollment program token to a target enrollment policy/profile via Microsoft Graph, working around the lack of a "select all" option in the Intune GUI. Can target all devices, a specific platform, or a list of serial numbers, and supports `-WhatIf`.

Requires: PowerShell 7.2+, `Microsoft.Graph.Authentication` module, `DeviceManagementServiceConfig.ReadWrite.All` scope.

## Usage notes

- These are ad-hoc/remediation scripts, not a maintained toolset - review the parameters and use `-WhatIf` (where supported) before running against production tenants.
- No shared dependencies between scripts; each can be copied and run individually.
