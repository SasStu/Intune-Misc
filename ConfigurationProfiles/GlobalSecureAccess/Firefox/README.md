# Firefox - disable QUIC + DNS over HTTPS

Entra Internet Access can't inspect **QUIC (HTTP/3 over UDP 443)** or
**DNS over HTTPS (DoH)**. Edge and Chrome are handled by native Settings Catalog
rows ([`../EdgeChrome/`](../EdgeChrome/)); Firefox needs its own policy because it
ships its own DoH resolver and HTTP/3 stack.

## Baseline or hardened?

Microsoft documents exactly two things for Firefox
([health check](https://learn.microsoft.com/entra/global-secure-access/troubleshoot-global-secure-access-client-diagnostics-health-check)):
set `network.http.http3.enable` to `false`, and turn **DNS over HTTPS** off.
Everything beyond that is extra hardening. Both variants are provided so you can
pick deliberately rather than inherit settings you didn't choose.

| | Baseline | Hardened |
| --- | --- | --- |
| Imported ADMX | [`firefox-preferences-baseline.json`](./firefox-preferences-baseline.json) | [`firefox-preferences-hardened.json`](./firefox-preferences-hardened.json) |
| `policies.json` drop-in | [`policies-baseline.json`](./policies-baseline.json) | [`policies-hardened.json`](./policies-hardened.json) |

**Start with baseline.** Move to hardened only if you want the extra locks and
have tested that nothing in your estate depends on DoH.

### Baseline - what Microsoft asks for, plus ECH

| Setting | Value | Effect |
| --- | --- | --- |
| `DNSOverHTTPS` policy | `Enabled: false`, `Locked: true` | No DoH, and the user can't switch it back on. |
| `network.http.http3.enable` | `false` (locked) | Turns off QUIC / HTTP3; Firefox uses HTTPS over TCP 443. |
| `network.dns.native_https_query` | `false` (locked) | Stops HTTPS RR lookups, which is how ECH bootstraps - ECH hides SNI from the filter. |

The first two are Microsoft's. `network.dns.native_https_query` is included in
the baseline because nothing else here covers ECH, and ECH defeats SNI-based
filtering. Drop it if you don't run Internet Access web content filtering.

### Hardened - adds three belt-and-braces locks

| Preference | Value | Why | Honest assessment |
| --- | --- | --- | --- |
| `network.trr.mode` | `5` (locked) | "Off by choice" - never attempts DoH, ignores canary/rollout. | The `DNSOverHTTPS` policy already turns DoH off and locks it. |
| `network.trr.uri` | `""` (locked) | Clears any configured DoH resolver URL. | Redundant once DoH is off and locked. |
| `network.http.http3.enable_kyber` | `false` (locked) | Disables the HTTP/3 key-exchange variant. | Moot with HTTP/3 already off. |

None of the three is load-bearing on its own. They're here because a locked
preference costs nothing and survives Firefox changing its defaults.

`Status: "locked"` greys the setting out in `about:preferences` and blocks
`about:config` overrides.

> `network.trr.mode = 5` is stricter than Microsoft's documented `0` (plain
> default-off). Use `0` instead if you want DoH to remain *available* for manual
> opt-in.

## Option A - Imported Firefox ADMX

1. **Import the ADMX** - Intune admin center > **Devices > Configuration >
   Import ADMX** > add `firefox.admx` + `firefox.adml` (and `mozilla.admx` /
   `mozilla.adml`) from the
   [Firefox policy-templates release](https://github.com/mozilla/policy-templates/releases).
   Wait for status **Available**.
2. **Create profile** - **Devices > Configuration > Create > New Policy** >
   Platform **Windows 10 and later**, Profile type **Templates > Imported
   Administrative templates**.
3. Under **Mozilla > Firefox**, enable **Preferences (JSON)** and paste the
   contents of `firefox-preferences-baseline.json` or
   `firefox-preferences-hardened.json` (the object only - not wrapped in
   `policies`).
   Also enable **DNS Over HTTPS** and set it to **Disabled**.
4. Assign to your device group. **Review + create.**

The imported-ADMX policy writes these under
`HKLM\SOFTWARE\Policies\Mozilla\Firefox`, which Firefox reads on next launch.

## Option B - `policies.json` drop-in (no ADMX)

Use `policies-baseline.json` or `policies-hardened.json` if you'd rather not
import ADMX. Rename your chosen file to `policies.json` and deploy it to
**`C:\Program Files\Mozilla Firefox\distribution\policies.json`** with a small
Win32 app or a Remediation (copy file + validate JSON). This is the same file
Microsoft's own Firefox remediation script maintains.

## Verify

Open Firefox and check:

- `about:policies` - shows **Preferences** and **DNSOverHTTPS** as active.
- `about:config` - `network.http.http3.enable` = `false` and locked (no toggle).
- `about:networking#dns` - "HTTPS RR" / TRR should show as not in use.
