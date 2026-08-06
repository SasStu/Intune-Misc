<#
.SYNOPSIS
    Intune Proactive Remediation - Detect missing BitLocker recovery key backups in Entra ID
.DESCRIPTION
    Checks every BitLocker-protected, non-removable drive (operating system
    drive AND fixed/local data drives) for a successful recovery-password
    backup to Microsoft Entra ID, identified by BitLocker-API event ID 845
    (one event per KeyProtectorId GUID).

    For each qualifying volume:
      - Skipped if BitLocker protection is not turned on
      - Skipped if it has no RecoveryPassword key protector
      - Otherwise, each RecoveryPassword protector must have a matching
        event ID 845 in the Microsoft-Windows-BitLocker-API event log

    Output is a single pipe-separated line covering every drive, so the
    per-drive status is readable in the Intune remediation output/log.

    Exit 0 = every applicable drive has a confirmed backup (or nothing to do)
    Exit 1 = at least one drive is missing a backup -> remediation.ps1 runs
.NOTES
    Deploy as a Detection Script in Intune Proactive Remediations, paired
    with remediation.ps1 in this folder.
    Run as: System (not user context)
    Run script in 64-bit PowerShell: Yes

    Based on https://github.com/mmeierm/Scripts/blob/main/Remediations/Bitlocker_KeyRecovery_detection.ps1,
    extended from system-drive-only to all fixed local drives.
#>

$ErrorActionPreference = "Stop"

$results  = [System.Collections.Generic.List[string]]::new()
$needsFix = $false

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
            $results.Add("[$mountPoint] SKIPPED - BitLocker protection is not on")
            continue
        }

        $recoveryProtectors = $volume.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' }

        if (-not $recoveryProtectors) {
            $results.Add("[$mountPoint] SKIPPED - no RecoveryPassword key protector present")
            continue
        }

        foreach ($protector in $recoveryProtectors) {
            $guid = $protector.KeyProtectorId

            $backupEvent = Get-WinEvent -ProviderName Microsoft-Windows-BitLocker-API `
                -FilterXPath "*[System[(EventID=845)] and EventData[Data[@Name='ProtectorGUID'] and (Data='$guid')]]" `
                -MaxEvents 1 -ErrorAction SilentlyContinue

            if ($backupEvent) {
                $results.Add("[$mountPoint] OK - backup event found for $guid")
            } else {
                $needsFix = $true
                $results.Add("[$mountPoint] MISSING - no backup event for $guid")
            }
        }
    }

    Write-Output ($results -join " | ")

    if ($needsFix) {
        exit 1
    }
    exit 0
} catch {
    Write-Output "NonCompliant: $($_.Exception.Message)"
    exit 1
}
