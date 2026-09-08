<#
    install.ps1
    GSA client settings - APPLY / REMEDIATE script.

    Use as:
      - Intune Remediation "remediation script"
      - Win32 app "install command":
          powershell.exe -NoProfile -ExecutionPolicy Bypass -File install.ps1

    Self-contained: no dot-sourcing, no external files. Idempotent.
    Run in 64-bit PowerShell / SYSTEM context.

    Applies:
      - HKLM registry hardening for the Global Secure Access client

    Full detail goes to a log file in the Intune Management Extension log
    folder (picked up by IME log collection / device diagnostics); stdout is a
    single summary line (Intune keeps only ~2048 chars of stdout).

    Exit codes:
      0     success
      1603  fatal error
#>

# ======================================================================
# CONFIG  --  KEEP THIS BLOCK IN SYNC WITH detection.ps1
# ======================================================================
$RegPath = 'HKLM:\SOFTWARE\Microsoft\Global Secure Access Client'

$RegValues = [ordered]@{
    RestrictNonPrivilegedUsers     = 1
    HideDisableButton              = 1
    HideSignOutButton              = 1
    HideDisablePrivateAccessButton = 1
}
# ======================================================================
# END CONFIG
# ======================================================================

# Log into the Intune Management Extension log folder so the detail is collected
# with IME logs (Intune "Collect diagnostics" / support bundles). Falls back to
# ProgramData if the IME folder is not present (e.g. running outside Intune).
$imeLogDir = Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs'
$logDir    = if (Test-Path $imeLogDir) { $imeLogDir } else { Join-Path $env:ProgramData 'GSAClientSettings' }
$logFile   = Join-Path $logDir 'GSAClientSettings-install.log'
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    try {
        $dir = Split-Path -Parent $logFile
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -Path $logFile -Value ("{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message)
    } catch { }
}

$changes = New-Object System.Collections.Generic.List[string]

try {
    $ErrorActionPreference = 'Stop'
    Write-Log "=== install.ps1 started ==="

    # --- Registry ---------------------------------------------------------
    if (-not (Test-Path $RegPath)) {
        New-Item -Path $RegPath -Force | Out-Null
        Write-Log "Created $RegPath"
        $changes.Add('created reg key')
    }
    foreach ($kv in $RegValues.GetEnumerator()) {
        $current = $null
        try { $current = (Get-ItemProperty -Path $RegPath -Name $kv.Key -ErrorAction Stop).$($kv.Key) } catch { }
        if ($null -ne $current -and [int]$current -eq [int]$kv.Value) {
            Write-Log "$($kv.Key) already $($kv.Value)"
            continue
        }
        New-ItemProperty -Path $RegPath -Name $kv.Key -PropertyType DWord -Value $kv.Value -Force | Out-Null
        Write-Log "Set $($kv.Key) = $($kv.Value) (was '$current')"
        $changes.Add("$($kv.Key)=$($kv.Value)")
    }

    Write-Log "=== install.ps1 completed OK ==="
    if ($changes.Count -eq 0) {
        Write-Output 'GSA client settings already compliant - no changes.'
    }
    else {
        Write-Output ("GSA client settings applied: " + ($changes -join ', ') + ". See $logFile")
    }
    exit 0
}
catch {
    Write-Log "FATAL: $($_.Exception.Message)" 'ERROR'
    Write-Output "GSA client settings FAILED: $($_.Exception.Message). See $logFile"
    exit 1603
}
