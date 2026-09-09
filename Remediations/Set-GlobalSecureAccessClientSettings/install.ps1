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
      - "IPv4Preferred" (Tcpip6 DisabledComponents = 0x20) - needs a reboot

    Full detail goes to a log file in the Intune Management Extension log
    folder (picked up by IME log collection / device diagnostics); stdout is a
    single summary line (Intune keeps only ~2048 chars of stdout).

    Exit codes:
      0     success, nothing outstanding
      3010  success, soft reboot required (the IPv4 preference was just written)
      1603  fatal error

    3010 is what a Win32 app wants: the default Intune return-code table maps it
    to "Soft reboot", so the app still counts as installed and the restart is
    handled by the app's device restart behavior. Set that to "Determine
    behavior based on return codes" or the 3010 has nothing to act on.

    As an Intune Remediation, any non-zero exit is filed as a FAILED
    remediation. Set $SoftRebootExitCode to 0 below for that delivery model.
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

# "IPv4Preferred" - Windows IPv6 prefix policy, not a GSA key. Reboot to apply.
# Set $IPv4RegValue to $null to skip.
$IPv4RegPath  = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters'
$IPv4RegName  = 'DisabledComponents'
$IPv4RegValue = 0x20   # prefer IPv4 over IPv6
# ======================================================================
# END CONFIG
# ======================================================================

# install.ps1 only - not mirrored in detection.ps1.
# Exit code used when the IPv4 preference was just written and the reboot that
# activates it is still outstanding.
#   3010 -> Win32 app: "soft reboot", still a successful install.
#   0    -> Intune Remediation: anything non-zero counts as a failed remediation.
$SoftRebootExitCode = 3010

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

$changes        = New-Object System.Collections.Generic.List[string]
$rebootRequired = $false

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

    # --- IPv4 preferred ---------------------------------------------------
    # Microsoft's client packaging script sets this next to the installer. When
    # the client is delivered another way (PatchMyPC, EAM, a plain wrapped exe)
    # nothing sets it, so it belongs here.
    if ($null -ne $IPv4RegValue) {
        if (-not (Test-Path $IPv4RegPath)) {
            New-Item -Path $IPv4RegPath -Force | Out-Null
            Write-Log "Created $IPv4RegPath"
        }
        $ipv4Current = $null
        try { $ipv4Current = (Get-ItemProperty -Path $IPv4RegPath -Name $IPv4RegName -ErrorAction Stop).$IPv4RegName } catch { }
        if ($null -ne $ipv4Current -and [int]$ipv4Current -eq [int]$IPv4RegValue) {
            Write-Log "$IPv4RegName already $IPv4RegValue"
        }
        else {
            # NOTE: DisabledComponents is a bitmask covering more than the IPv4
            # preference. Writing 0x20 replaces whatever was there. The previous
            # value is logged below so it can be put back by hand if needed.
            New-ItemProperty -Path $IPv4RegPath -Name $IPv4RegName -PropertyType DWord -Value $IPv4RegValue -Force | Out-Null
            Write-Log "Set $IPv4RegName = $IPv4RegValue (was '$ipv4Current') - reboot required to take effect"
            $changes.Add("$IPv4RegName=$IPv4RegValue")
            $rebootRequired = $true
        }
    }

    if ($changes.Count -eq 0) {
        Write-Log "=== install.ps1 completed OK (no changes) ==="
        Write-Output 'GSA client settings already compliant - no changes.'
        exit 0
    }
    if ($rebootRequired) {
        Write-Log "=== install.ps1 completed OK - exiting $SoftRebootExitCode (reboot outstanding) ==="
        Write-Output ("GSA client settings applied: " + ($changes -join ', ') + ". IPv4 preference applies after the next reboot. See $logFile")
        exit $SoftRebootExitCode
    }
    Write-Log "=== install.ps1 completed OK ==="
    Write-Output ("GSA client settings applied: " + ($changes -join ', ') + ". See $logFile")
    exit 0
}
catch {
    Write-Log "FATAL: $($_.Exception.Message)" 'ERROR'
    Write-Output "GSA client settings FAILED: $($_.Exception.Message). See $logFile"
    exit 1603
}
