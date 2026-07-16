<#
.SYNOPSIS
    Win32 App Uninstall - Remove AutoAcceptSsoPermission policy
.DESCRIPTION
    Removes the AutoAcceptSsoPermission value so Windows falls back to the
    default behavior (SSO permission prompt is shown to the user).

    Uninstall command (Intune):
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall.ps1
    Install behavior: System
#>

$ErrorActionPreference = "Stop"

$RegPath   = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AAD"
$ValueName = "AutoAcceptSsoPermission"

$LogDir = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs"
$Log    = Join-Path $LogDir "Set-AutoAcceptSsoPermission-Uninstall.log"

function Write-Log ($Message) {
    $line = "{0} - {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $Log -Value $line -ErrorAction SilentlyContinue
    Write-Output $line
}

try {
    if (Test-Path $RegPath) {
        $props = Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue
        if ($null -ne $props.$ValueName) {
            Remove-ItemProperty -Path $RegPath -Name $ValueName -Force
            Write-Log "Removed $ValueName from $RegPath"
        } else {
            Write-Log "$ValueName not present - nothing to remove"
        }
    } else {
        Write-Log "$RegPath not present - nothing to remove"
    }
    exit 0
} catch {
    Write-Log "Uninstall failed - $($_.Exception.Message)"
    exit 1
}
