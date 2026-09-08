# Set-GlobalSecureAccessClientSettings

Applies the Global Secure Access client-side controls that Intune has **no
native UI** for. Ships as three plain `.ps1` files - deploy as an Intune
**Remediation** (no `.intunewin`), or repackage later as a Win32 app; the file
names (`detection` / `install` / `uninstall`) double as the Remediation
detection/remediation pair and the Win32-app detect/install/uninstall commands.

Browser-side settings that let GSA capture Edge / Chrome / Firefox traffic
(disable QUIC + DoH) are separate - see
[`../../ConfigurationProfiles/GlobalSecureAccess/`](../../ConfigurationProfiles/GlobalSecureAccess/).

| Setting | Location | Value | Purpose |
| --- | --- | --- | --- |
| `RestrictNonPrivilegedUsers` | `HKLM\SOFTWARE\Microsoft\Global Secure Access Client` | `1` | Non-admins can't disable/enable the client (UAC + admin required). |
| `HideDisableButton` | same | `1` | Removes the tray **Disable** action. |
| `HideSignOutButton` | same | `1` | Removes the tray **Sign out** action. |
| `HideDisablePrivateAccessButton` | same | `1` | Removes **Disable Private Access** (no-op without Private Access license). |

All registry values are `REG_DWORD`.

## Files

| File | Role |
| --- | --- |
| `detection.ps1` | Detection. `exit 0` = compliant, `exit 1` = apply. Prints one status line. |
| `install.ps1` | Apply / remediate. Idempotent. Detail -> log file, one summary line to stdout. |
| `uninstall.ps1` | Revert (Win32 uninstall command, or one-off rollback). |

The `CONFIG` banner block at the top of `detection.ps1` and `install.ps1` **must be
kept in sync** - edit values in both.

Device logs: `%ProgramData%\Microsoft\IntuneManagementExtension\Logs\GSAClientSettings-install.log`
and `GSAClientSettings-uninstall.log` - written next to the IME logs so they are
picked up by Intune **Collect diagnostics** / support bundles. Falls back to
`%ProgramData%\GSAClientSettings\` when the IME folder is absent.

### A note on stdout

Intune stores only ~2048 characters of **stdout** per script run (shown in the
portal's *Pre-remediation / Post-remediation output*). stderr isn't surfaced and
can mark the run failed. So `install.ps1` logs verbosely to the file and emits a
single stdout summary; `detection.ps1` emits one `Compliant` / `Non-compliant: ...`
line - keep it that way if you extend them.

## Deploy as a Remediation

**Intune admin center > Devices > Remediations > Create script package**

| Field | Value |
| --- | --- |
| Detection script file | `detection.ps1` |
| Remediation script file | `install.ps1` |
| Run this script using the logged-on credentials | **No** (SYSTEM) |
| Enforce script signature check | No |
| Run script in 64-bit PowerShell | **Yes** |

**Assignments** - target a device group. Schedule **Daily**.
(`uninstall.ps1` is not used here - run it as a one-off Platform script if you
need to roll back.)

## Deploy as a Win32 app (alternative)

`IntuneWinAppUtil.exe -c . -s install.ps1 -o <out>`, then:

| Field | Value |
| --- | --- |
| Install command | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File install.ps1` |
| Uninstall command | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1` |
| Detection rule | custom script `detection.ps1` (32-bit: **No**) |
| Install behavior | System |

## Verify on a client

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Global Secure Access Client' |
    Select RestrictNonPrivilegedUsers, HideDisableButton, HideSignOutButton, HideDisablePrivateAccessButton
```

Restart the GSA client (or reboot) for the tray-menu changes to show.

## Not covered here

- GSA client **installer** (`GlobalSecureAccessClient.exe /quiet`) + `IPv4Preferred` tweak - separate Win32 app.
- Edge / Chrome QUIC + DoH - see [`../../ConfigurationProfiles/GlobalSecureAccess/EdgeChrome/`](../../ConfigurationProfiles/GlobalSecureAccess/EdgeChrome/) (native Settings Catalog rows).
- Firefox QUIC + DoH - see [`../../ConfigurationProfiles/GlobalSecureAccess/Firefox/`](../../ConfigurationProfiles/GlobalSecureAccess/Firefox/).
