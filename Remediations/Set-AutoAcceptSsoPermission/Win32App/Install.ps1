<#
.SYNOPSIS
    Win32 App Install - Set AutoAcceptSsoPermission policy
.DESCRIPTION
    Sets HKLM\SOFTWARE\Policies\Microsoft\Windows\AAD\AutoAcceptSsoPermission = 1 (DWORD)
    to auto-accept the Entra SSO permission prompt on managed devices.

    Install command (Intune):
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
    Install behavior: System
.NOTES
    Reference: https://techcommunity.microsoft.com/blog/windows-itpro-blog/now-available-admin-control-for-sso-prompts-in-windows/4534613
#>

$ErrorActionPreference = "Stop"

$RegPath   = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AAD"
$ValueName = "AutoAcceptSsoPermission"
$Value     = 1

$LogDir = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs"
$Log    = Join-Path $LogDir "Set-AutoAcceptSsoPermission-Install.log"

function Write-Log ($Message) {
    $line = "{0} - {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $Log -Value $line -ErrorAction SilentlyContinue
    Write-Output $line
}

try {
    if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }

    if (-not (Test-Path $RegPath)) {
        New-Item -Path $RegPath -Force | Out-Null
        Write-Log "Created registry key $RegPath"
    }

    New-ItemProperty -Path $RegPath -Name $ValueName -Value $Value -PropertyType DWord -Force | Out-Null
    Write-Log "Set $ValueName = $Value"

    $current = (Get-ItemProperty -Path $RegPath -Name $ValueName).$ValueName
    if ($current -eq $Value) {
        Write-Log "Install successful - value verified"
        exit 0
    }

    Write-Log "Install failed - value is $current after write"
    exit 1
} catch {
    Write-Log "Install failed - $($_.Exception.Message)"
    exit 1
}
