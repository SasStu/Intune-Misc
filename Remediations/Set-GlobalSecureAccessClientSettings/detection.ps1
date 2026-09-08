<#
    detection.ps1
    GSA client settings - DETECTION script.

    Use as:
      - Intune Remediation "detection script"
      - Win32 app custom "detection script" (exit 0 + stdout = detected)

    Self-contained: no dot-sourcing, no external files. Run in 64-bit PowerShell.

    Exit codes:
      0  compliant       (Remediation: no action / Win32: detected)
      1  non-compliant   (Remediation: run install.ps1 / Win32: not detected)

    Intune keeps ~2048 chars of stdout - this script writes one status line.
#>

# ======================================================================
# CONFIG  --  KEEP THIS BLOCK IN SYNC WITH install.ps1
# (detection.ps1 / install.ps1 / uninstall.ps1 double as Win32-app
#  detect / install / uninstall commands and as a Remediation script pair.)
# ======================================================================
$RegPath = 'HKLM:\SOFTWARE\Microsoft\Global Secure Access Client'

# REG_DWORD values under $RegPath. Edit to taste.
# https://learn.microsoft.com/entra/global-secure-access/how-to-install-windows-client#client-registry-keys
$RegValues = [ordered]@{
    RestrictNonPrivilegedUsers     = 1   # non-admins cannot disable/enable the client
    HideDisableButton              = 1   # hide tray "Disable"
    HideSignOutButton              = 1   # hide tray "Sign out"
    HideDisablePrivateAccessButton = 1   # hide tray "Disable Private Access" (no-op without Private Access license)
}
# ======================================================================
# END CONFIG
# ======================================================================

$problems = New-Object System.Collections.Generic.List[string]

# --- Registry ---------------------------------------------------------
if (-not (Test-Path $RegPath)) {
    $problems.Add("Registry path missing: $RegPath")
}
else {
    foreach ($kv in $RegValues.GetEnumerator()) {
        $actual = $null
        try { $actual = (Get-ItemProperty -Path $RegPath -Name $kv.Key -ErrorAction Stop).$($kv.Key) } catch { }
        if ($null -eq $actual) {
            $problems.Add("$($kv.Key) not set (expected $($kv.Value))")
        }
        elseif ([int]$actual -ne [int]$kv.Value) {
            $problems.Add("$($kv.Key) is $actual (expected $($kv.Value))")
        }
    }
}

# --- Result ---------------------------------------------------------------
if ($problems.Count -eq 0) {
    Write-Output 'Compliant'
    exit 0
}
Write-Output ("Non-compliant: " + ($problems -join '; '))
exit 1
