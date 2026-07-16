# Set-AutoAcceptSsoPermission

Configures the new Windows policy that auto-accepts the Entra SSO permission prompt
("Continue to sign in") on managed devices, so users no longer see the consent dialog
when Windows shares their signed-in work account with Microsoft apps.

Reference: [Now available: Admin control for SSO prompts in Windows](https://techcommunity.microsoft.com/blog/windows-itpro-blog/now-available-admin-control-for-sso-prompts-in-windows/4534613)

## Registry policy

| | |
|---|---|
| Path | `HKLM\SOFTWARE\Policies\Microsoft\Windows\AAD` |
| Value | `AutoAcceptSsoPermission` |
| Type | `DWORD` |
| Data | `1` (auto-accept the SSO permission prompt) |

## Prerequisites

- Windows 11 24H2 (build 26100.8875+) or 25H2 (build 26200.8875+), i.e. the
  July 2026 update **KB5101650** or later
- Device must be organization-managed (Intune/GPO); has no effect on personal PCs
- Account must be a Microsoft Entra work or school account
- Does NOT bypass MFA, Conditional Access, or app-specific consent

## Option 1: Proactive Remediation

Intune > Devices > Scripts and remediations > Create:

| Setting | Value |
|---|---|
| Detection script | `detection.ps1` |
| Remediation script | `remediation.ps1` |
| Run this script using the logged-on credentials | No |
| Enforce script signature check | No |
| Run script in 64-bit PowerShell | Yes |

The detection script has no OS build check - the key is pre-deployed on all
targeted devices and the policy simply takes effect once KB5101650 (or later)
is installed.

## Option 2: Win32 App

1. Package the `Win32App` folder with the [Microsoft Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool):

   ```powershell
   IntuneWinAppUtil.exe -c .\Win32App -s Install.ps1 -o .\Output
   ```

2. Create a Win32 app in Intune with:

   | Setting | Value |
   |---|---|
   | Install command | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1` |
   | Uninstall command | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall.ps1` |
   | Install behavior | System |
   | Device restart behavior | No specific action |

3. Detection rule - either:
   - **Registry rule (simplest):** Key path `HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\AAD`,
     value `AutoAcceptSsoPermission`, detection method "Integer comparison", operator "Equals", value `1`.
     Enable "Associated with a 32-bit app on 64-bit clients: No".
   - **Custom script:** upload `Win32App\Detect.ps1` (run as 64-bit, enforce signature check: No).

Logs are written to `%ProgramData%\Microsoft\IntuneManagementExtension\Logs\Set-AutoAcceptSsoPermission-*.log`.

## Rollback

Run `Win32App\Uninstall.ps1` (or uninstall the Win32 app) to remove the value and
restore the default prompt behavior.
