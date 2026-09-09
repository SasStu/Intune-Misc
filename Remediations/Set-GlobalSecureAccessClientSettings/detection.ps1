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

# "IPv4Preferred" - Microsoft's own client packaging script sets this alongside
# the installer. It is not under the GSA key: it is the Windows IPv6 prefix
# policy value, and it only takes effect after a reboot.
# https://learn.microsoft.com/entra/global-secure-access/how-to-install-windows-client#package-the-client
# Set $IPv4RegValue to $null to skip this check entirely.
$IPv4RegPath  = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters'
$IPv4RegName  = 'DisabledComponents'
$IPv4RegValue = 0x20   # prefer IPv4 over IPv6
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

# --- IPv4 preferred ---------------------------------------------------
if ($null -ne $IPv4RegValue) {
    $ipv4Actual = $null
    try { $ipv4Actual = (Get-ItemProperty -Path $IPv4RegPath -Name $IPv4RegName -ErrorAction Stop).$IPv4RegName } catch { }
    if ($null -eq $ipv4Actual) {
        $problems.Add("$IPv4RegName not set (expected $IPv4RegValue)")
    }
    elseif ([int]$ipv4Actual -ne [int]$IPv4RegValue) {
        $problems.Add("$IPv4RegName is $ipv4Actual (expected $IPv4RegValue)")
    }
}

# --- Result ---------------------------------------------------------------
if ($problems.Count -eq 0) {
    Write-Output 'Compliant'
    exit 0
}
Write-Output ("Non-compliant: " + ($problems -join '; '))
exit 1
