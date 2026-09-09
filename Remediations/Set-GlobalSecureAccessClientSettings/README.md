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
| `DisabledComponents` | `HKLM\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters` | `0x20` | "IPv4Preferred" - prefer IPv4 over IPv6. **Needs a reboot.** |

All registry values are `REG_DWORD`.

## About `DisabledComponents`

Microsoft calls this the `IPv4Preferred` key and sets it in the
[PowerShell script that packages the client](https://learn.microsoft.com/entra/global-secure-access/how-to-install-windows-client#package-the-client).
Two things follow from that:

- **It is only set if you deploy the client Microsoft's way.** Package it with
  PatchMyPC, the Enterprise App Catalog or your own wrapped `.exe` and nothing
  writes it - which is why it is in this script package instead.
- **It is not a GSA key.** `DisabledComponents` is the Windows IPv6 prefix
  policy value and it is a bitmask covering more than the IPv4 preference.
  Writing `0x20` replaces whatever was there; `install.ps1` logs the previous
  value first. `uninstall.ps1` removes the value only if it is still `0x20`, so
  a value set for some other reason is left alone.

Set `$IPv4RegValue = $null` in both `detection.ps1` and `install.ps1` to leave
IPv6 configuration alone entirely.

## Files

| File | Role |
| --- | --- |
| `detection.ps1` | Detection. `exit 0` = compliant, `exit 1` = apply. Prints one status line naming every setting that is out of place. |
| `install.ps1` | Apply / remediate. Idempotent. `exit 0`, or `3010` when the IPv4 preference was just written. Detail -> log file, one summary line to stdout. |
| `uninstall.ps1` | Revert (Win32 uninstall command, or one-off rollback). |

### `install.ps1` exit codes

| Code | When |
| --- | --- |
| `0` | Already compliant, or changes applied with nothing outstanding. |
| `3010` | Applied, and the IPv4 preference needs a reboot to take effect. |
| `1603` | Fatal error. |

`3010` is what a **Win32 app** wants: Intune's default return-code table maps it
to **Soft reboot**, so the app still counts as installed and the restart is left
to the app's **Device restart behavior** - set that to **Determine behavior
based on return codes**, or the `3010` has nothing to act on.

As an **Intune Remediation**, any non-zero exit is filed as a *failed*
remediation. Set `$SoftRebootExitCode = 0` near the top of `install.ps1` for
that delivery model.

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

Set `$SoftRebootExitCode = 0` in `install.ps1` first - see the exit-code table
above. Left at `3010`, the first run of every device is reported as a failed
remediation even though it worked.

**Assignments** - target a device group. Schedule **Daily**.
(`uninstall.ps1` is not used here - run it as a one-off Platform script if you
need to roll back.)

## Deploy as a Win32 app (alternative)

`IntuneWinAppUtil.exe -c . -s install.ps1 -o <out>`, then:

| Field | Value |
| --- | --- |
| Install | **PowerShell script** - upload `install.ps1` |
| Uninstall | **PowerShell script** - upload `uninstall.ps1` |
| Detection rule | custom script `detection.ps1` (32-bit: **No**) |
| Install behavior | System |
| Device restart behavior | **Determine behavior based on return codes** |
| Return codes | leave the defaults (`3010` is already mapped to Soft reboot) |

The **PowerShell script** installer option avoids the 32-bit trap that a
`powershell.exe -File ...` command line walks into. Note the portal greys the
option out until the install command line contains something, so type a
character there first, then switch.

## Verify on a client

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Global Secure Access Client' |
    Select RestrictNonPrivilegedUsers, HideDisableButton, HideSignOutButton, HideDisablePrivateAccessButton

Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' |
    Select DisabledComponents
```

Restart the GSA client (or reboot) for the tray-menu changes to show. The IPv4
preference needs a full reboot, and `netsh interface ipv6 show prefixpolicies`
is the way to confirm it actually took.

## Not covered here

- GSA client **installer** (`GlobalSecureAccessClient.exe /quiet`) - separate Win32 app.
- Edge / Chrome QUIC + DoH - see [`../../ConfigurationProfiles/GlobalSecureAccess/EdgeChrome/`](../../ConfigurationProfiles/GlobalSecureAccess/EdgeChrome/) (native Settings Catalog rows).
- Firefox QUIC + DoH - see [`../../ConfigurationProfiles/GlobalSecureAccess/Firefox/`](../../ConfigurationProfiles/GlobalSecureAccess/Firefox/).
