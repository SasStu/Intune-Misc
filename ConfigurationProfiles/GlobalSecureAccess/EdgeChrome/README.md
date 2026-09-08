# Edge / Chrome - disable QUIC + DNS over HTTPS

Entra Internet Access can't inspect **QUIC (HTTP/3 over UDP 443)** or
**DNS over HTTPS (DoH)**. This Settings Catalog profile turns both off in
Microsoft Edge and Google Chrome so all browser traffic falls back to HTTPS
over TCP 443 and the platform DNS resolver, where the Global Secure Access
client can capture and forward it.

Firefox needs its own policy (own DoH resolver + HTTP/3 stack) - see
[`../Firefox/`](../Firefox/).

## What it sets

| Browser | Setting (ADMX-backed) | Value | Effect |
| --- | --- | --- | --- |
| Chrome | `QuicAllowed` | Disabled (`_0`) | No QUIC / HTTP3; HTTPS over TCP 443. |
| Chrome | `DnsOverHttpsMode` | Off (`_0`) | Uses the OS DNS resolver, no DoH. |
| Edge | `QuicAllowed` | Disabled (`_0`) | No QUIC / HTTP3; HTTPS over TCP 443. |
| Edge | `DnsOverHttpsMode` | Off (`_0`) | Uses the OS DNS resolver, no DoH. |

`settingCount` in the export is `4` - one row per line above.

## File

`CProf-Win-D-SetCat-EdgeChromeGSASettings-[SST].json` - a raw
`deviceManagement/configurationPolicies` export from Graph beta. The filename
mirrors the in-portal **profile name** (same string as the `name` field):

| Token | Meaning |
| --- | --- |
| `CProf` | Configuration Profile |
| `Win` | Platform: Windows |
| `D` | Scope: Device |
| `SetCat` | Type: Settings Catalog |
| `EdgeChromeGSASettings` | Purpose |
| `[SST]` | Author initials |

## Import

Strip the read-only fields (`id`, `createdDateTime`, `lastModifiedDateTime`)
and `POST` the rest:

```
POST https://graph.microsoft.com/beta/deviceManagement/configurationPolicies
Content-Type: application/json
Body: <contents of the .json, without id / *DateTime>
```

or use **Intune admin center > Devices > Configuration > Import policy** and
select the file, then assign to your device group.

## Verify

- Edge: `edge://policy` - `QuicAllowed` = `false`, `DnsOverHttpsMode` = `off`.
- Chrome: `chrome://policy` - same two keys.
- `edge://net-internals/#dns` / `chrome://net-internals/#dns` - "Secure DNS" not in use.

<!-- TODO: link the walkthrough article here once published. -->
