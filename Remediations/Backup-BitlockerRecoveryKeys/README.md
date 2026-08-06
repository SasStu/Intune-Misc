# Backup-BitlockerRecoveryKeys

Backs up BitLocker recovery passwords to Microsoft Entra ID (Azure AD) for
**every BitLocker-protected local drive** on the device - the operating
system drive and any fixed data drives - not just `%SystemDrive%`.

Based on [mmeierm/Scripts - Bitlocker_KeyRecovery_remediation.ps1](https://github.com/mmeierm/Scripts/blob/main/Remediations/Bitlocker_KeyRecovery_remediation.ps1),
which only backs up the system drive's key. This version loops over
`Get-BitLockerVolume` and skips only `Removable` media (USB sticks etc.),
so any additional fixed/internal disks with BitLocker enabled get their
recovery keys escrowed as well.

## How it works

**detection.ps1**
For every non-removable BitLocker volume with protection on and a
`RecoveryPassword` key protector, checks the `Microsoft-Windows-BitLocker-API`
event log for a matching event ID `845` (successful Entra ID backup) per
protector GUID.
- Exit `0` - every applicable drive already has a confirmed backup (or there's nothing to do)
- Exit `1` - at least one drive is missing a backup -> triggers remediation

**remediation.ps1**
For every non-removable BitLocker volume with protection on, runs
`BackupToAAD-BitLockerKeyProtector` for each `RecoveryPassword` key protector.
- Exit `0` - all backups succeeded (or nothing to do)
- Exit `1` - at least one backup failed

Both scripts write a single pipe-separated (`|`) summary line covering
every drive (e.g. `[C:] OK - backed up protector <guid> | [D:] SKIPPED - no RecoveryPassword key protector present`),
so the per-drive result is readable directly in the Intune remediation
output/log instead of only the last thing written.

## Deploy as Proactive Remediation

Intune > Devices > Scripts and remediations > Create:

| Setting | Value |
|---|---|
| Detection script | `detection.ps1` |
| Remediation script | `remediation.ps1` |
| Run this script using the logged-on credentials | No |
| Enforce script signature check | No |
| Run script in 64-bit PowerShell | Yes |

Assign to a device group and run on a schedule (e.g. hourly/daily) so newly
added or re-encrypted drives get their keys escrowed automatically.

## Notes

- Requires the device to be Entra-joined (or hybrid-joined) - `BackupToAAD-BitLockerKeyProtector`
  fails on workgroup/AD-only devices with no Entra device object.
- Drives with BitLocker off, or without a `RecoveryPassword` protector
  (e.g. TPM-only or auto-unlock data drives with no password protector),
  are reported as `SKIPPED`, not treated as a failure.
- Removable drives (USB) are intentionally excluded - their keys are not
  meant to be escrowed to the device's Entra object.
