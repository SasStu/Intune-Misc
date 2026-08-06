<#
.SYNOPSIS
    Intune Proactive Remediation - Backup BitLocker recovery keys to Entra ID
.DESCRIPTION
    Backs up the RecoveryPassword key protector of every BitLocker-protected,
    non-removable drive (operating system drive AND fixed/local data drives)
    to Microsoft Entra ID (Azure AD), not just the system drive.

    For each qualifying volume:
      - Skipped if BitLocker protection is not turned on
      - Skipped if it has no RecoveryPassword key protector
      - Otherwise, every RecoveryPassword protector is backed up via
        BackupToAAD-BitLockerKeyProtector

    Output is a single pipe-separated line covering every drive, so the
    per-drive result is readable in the Intune remediation output/log
    instead of only the last thing written.

    Exit 0 = all applicable drives backed up successfully (or nothing to do)
    Exit 1 = at least one backup failed -> surfaced as remediation failure
.NOTES
    Deploy as a Remediation Script in Intune Proactive Remediations, paired
    with detection.ps1 in this folder.
    Run as: System (not user context)
    Run script in 64-bit PowerShell: Yes

    Based on https://github.com/mmeierm/Scripts/blob/main/Remediations/Bitlocker_KeyRecovery_remediation.ps1,
    extended from system-drive-only to all fixed local drives.
#>

$ErrorActionPreference = "Stop"

$results  = [System.Collections.Generic.List[string]]::new()
$hadError = $false

try {
    # VolumeType is "OperatingSystem", "Fixed" or "Removable" - exclude only removable media (USB sticks etc.)
    $volumes = Get-BitLockerVolume | Where-Object { $_.VolumeType -ne 'Removable' }

    if (-not $volumes) {
        Write-Output "No fixed BitLocker volumes found on this device."
        exit 0
    }

    foreach ($volume in $volumes) {
        $mountPoint = $volume.MountPoint

        if ($volume.ProtectionStatus -ne 'On') {
            $results.Add("[$mountPoint] SKIPPED - BitLocker protection is not on (status: $($volume.ProtectionStatus))")
            continue
        }

        $recoveryProtectors = $volume.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' }

        if (-not $recoveryProtectors) {
            $results.Add("[$mountPoint] SKIPPED - no RecoveryPassword key protector present")
            continue
        }

        foreach ($protector in $recoveryProtectors) {
            try {
                BackupToAAD-BitLockerKeyProtector -MountPoint $mountPoint -KeyProtectorId $protector.KeyProtectorId -ErrorAction Stop
                $results.Add("[$mountPoint] OK - backed up protector $($protector.KeyProtectorId)")
            } catch {
                $hadError = $true
                $results.Add("[$mountPoint] FAILED - protector $($protector.KeyProtectorId): $($_.Exception.Message)")
            }
        }
    }

    Write-Output ($results -join " | ")

    if ($hadError) {
        exit 1
    }
    exit 0
} catch {
    Write-Output "Failed: $($_.Exception.Message)"
    exit 1
}
