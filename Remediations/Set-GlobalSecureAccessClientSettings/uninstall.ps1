<#
    uninstall.ps1
    GSA client settings - REVERT script.

    Use as:
      - Win32 app "uninstall command":
          powershell.exe -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1
      - one-off Platform script to roll back a Remediation

    Reverts what install.ps1 applied:
      - RestrictNonPrivilegedUsers / HideDisableButton -> 0
      - HideSignOutButton / HideDisablePrivateAccessButton -> removed
      - QUIC firewall rule -> removed

    Does NOT delete the "Global Secure Access Client" key (client installer owns it).
    Run elevated / 64-bit.

    Exit codes:
      0     success
      1603  fatal error
#>

$RegPath      = 'HKLM:\SOFTWARE\Microsoft\Global Secure Access Client'
$QuicRuleName = 'GSA - Block QUIC (UDP 443 Outbound)'
$resetToZero  = @('RestrictNonPrivilegedUsers', 'HideDisableButton')
$removeValues = @('HideSignOutButton', 'HideDisablePrivateAccessButton')

# Log alongside the IME logs so detail is collected with Intune diagnostics.
$imeLogDir = Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs'
$logDir    = if (Test-Path $imeLogDir) { $imeLogDir } else { Join-Path $env:ProgramData 'GSAClientSettings' }
$logFile   = Join-Path $logDir 'GSAClientSettings-uninstall.log'
function Write-Log {
    param([string]$Message)
    try {
        $dir = Split-Path -Parent $logFile
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -Path $logFile -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    } catch { }
}

try {
    $ErrorActionPreference = 'Stop'
    Write-Log "=== uninstall.ps1 started ==="

    if (Test-Path $RegPath) {
        foreach ($n in $resetToZero) {
            New-ItemProperty -Path $RegPath -Name $n -PropertyType DWord -Value 0 -Force | Out-Null
            Write-Log "Reset $n = 0"
        }
        foreach ($n in $removeValues) {
            Remove-ItemProperty -Path $RegPath -Name $n -ErrorAction SilentlyContinue
            Write-Log "Removed $n"
        }
    }
    else {
        Write-Log "Registry path $RegPath not present - skipped"
    }

    $rules = Get-NetFirewallRule -DisplayName $QuicRuleName -ErrorAction SilentlyContinue
    if ($rules) {
        $rules | Remove-NetFirewallRule
        Write-Log "Removed firewall rule '$QuicRuleName'"
    }

    Write-Log "=== uninstall.ps1 completed OK ==="
    Write-Output "GSA client settings reverted. See $logFile"
    exit 0
}
catch {
    Write-Log "FATAL: $($_.Exception.Message)"
    Write-Output "GSA client settings revert FAILED: $($_.Exception.Message). See $logFile"
    exit 1603
}
