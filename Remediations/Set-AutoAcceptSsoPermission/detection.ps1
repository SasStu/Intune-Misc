<#
.SYNOPSIS
    Intune Proactive Remediation - Detect AutoAcceptSsoPermission policy
.DESCRIPTION
    Checks whether the registry policy that auto-accepts the Entra SSO
    permission prompt ("Continue to sign in") is configured.

    Policy:
      Path : HKLM\SOFTWARE\Policies\Microsoft\Windows\AAD
      Name : AutoAcceptSsoPermission
      Type : DWORD
      Data : 1 (auto-accept SSO permission prompts)

    The key is deployed on all devices regardless of OS build (pre-deployment).
    The policy takes effect once KB5101650 (July 2026) or later is installed:
      Windows 11 24H2 - Build 26100.8875+
      Windows 11 25H2 - Build 26200.8875+

    Exit 0 = compliant (value present and set to 1)
    Exit 1 = non-compliant (value missing or wrong) -> remediation runs
.NOTES
    Deploy as a Detection Script in Intune Proactive Remediations.
    Run as: System (not user context)
    Reference: https://techcommunity.microsoft.com/blog/windows-itpro-blog/now-available-admin-control-for-sso-prompts-in-windows/4534613
#>

$ErrorActionPreference = "SilentlyContinue"

$RegPath   = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AAD"
$ValueName = "AutoAcceptSsoPermission"
$Expected  = 1

# ── Registry check ──
try {
    $current = Get-ItemProperty -Path $RegPath -Name $ValueName -ErrorAction Stop |
               Select-Object -ExpandProperty $ValueName

    if ($current -eq $Expected) {
        Write-Output "Compliant: $ValueName = $current"
        exit 0
    }

    Write-Output "NonCompliant: $ValueName = $current (expected $Expected)"
    exit 1
} catch {
    Write-Output "NonCompliant: $ValueName not configured under $RegPath"
    exit 1
}
