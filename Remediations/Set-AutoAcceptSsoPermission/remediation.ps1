<#
.SYNOPSIS
    Intune Proactive Remediation - Set AutoAcceptSsoPermission policy
.DESCRIPTION
    Creates/sets the registry policy that auto-accepts the Entra SSO
    permission prompt ("Continue to sign in") on managed devices.

    Policy:
      Path : HKLM\SOFTWARE\Policies\Microsoft\Windows\AAD
      Name : AutoAcceptSsoPermission
      Type : DWORD
      Data : 1

    Notes:
      - Only effective on organization-managed devices with an Entra
        work or school account.
      - Does NOT bypass MFA, Conditional Access, or app consent.
      - Requires KB5101650 (July 2026) on Windows 11 24H2/25H2.
.NOTES
    Deploy as a Remediation Script in Intune Proactive Remediations.
    Run as: System (not user context)
    Reference: https://techcommunity.microsoft.com/blog/windows-itpro-blog/now-available-admin-control-for-sso-prompts-in-windows/4534613
#>

$ErrorActionPreference = "Stop"

$RegPath   = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AAD"
$ValueName = "AutoAcceptSsoPermission"
$Value     = 1

try {
    if (-not (Test-Path $RegPath)) {
        New-Item -Path $RegPath -Force | Out-Null
    }

    New-ItemProperty -Path $RegPath -Name $ValueName -Value $Value -PropertyType DWord -Force | Out-Null

    # Verify
    $current = (Get-ItemProperty -Path $RegPath -Name $ValueName).$ValueName
    if ($current -eq $Value) {
        Write-Output "Remediated: $ValueName set to $Value under $RegPath"
        exit 0
    }

    Write-Output "Failed: $ValueName is $current after write (expected $Value)"
    exit 1
} catch {
    Write-Output "Failed: $($_.Exception.Message)"
    exit 1
}
