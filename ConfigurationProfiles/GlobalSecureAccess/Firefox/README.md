# Firefox - disable QUIC + DNS over HTTPS

Entra Internet Access can't inspect **QUIC (HTTP/3 over UDP 443)** or
**DNS over HTTPS (DoH)**. Edge and Chrome are handled by native Settings Catalog
rows ([`../EdgeChrome/`](../EdgeChrome/)); Firefox needs its own policy because it
ships its own DoH resolver and HTTP/3 stack.

## What the prefs do

| Preference | Value | Effect |
| --- | --- | --- |
| `network.http.http3.enable` | `false` (locked) | Turns off QUIC / HTTP3; Firefox uses HTTPS over TCP 443. |
| `network.http.http3.enable_kyber` | `false` (locked) | Disables the HTTP/3 key-exchange variant (belt & braces). |
| `network.trr.mode` | `5` (locked) | "Off by choice" - Firefox never attempts DoH, ignores canary/rollout. |
| `network.trr.uri` | `""` (locked) | Clears any configured DoH resolver URL. |
| `network.dns.native_https_query` | `false` (locked) | Stops HTTPS RR (ECH bootstrap) DNS lookups. |

`Status: "locked"` greys the setting out in `about:preferences` and blocks
`about:config` overrides.

> `network.trr.mode = 5` is stricter than Microsoft's documented `0` (plain
> default-off). Use `0` instead if you want DoH to remain *available* for manual
> opt-in. Change it in both files below.

## Option A - Imported Firefox ADMX (what you asked for)

1. **Import the ADMX** - Intune admin center > **Devices > Configuration >
   Import ADMX** > add `firefox.admx` + `firefox.adml` (and `mozilla.admx` /
   `mozilla.adml`) from the
   [Firefox policy-templates release](https://github.com/mozilla/policy-templates/releases).
   Wait for status **Available**.
2. **Create profile** - **Devices > Configuration > Create > New Policy** >
   Platform **Windows 10 and later**, Profile type **Templates > Imported
   Administrative templates**.
3. Under **Mozilla > Firefox**, enable **Preferences (JSON)** and paste the
   contents of [`firefox-preferences.json`](./firefox-preferences.json) (the
   object only - not wrapped in `policies`).
   Also enable **DNS Over HTTPS** and set it to **Disabled**.
4. Assign to your device group. **Review + create.**

The imported-ADMX policy writes these under
`HKLM\SOFTWARE\Policies\Mozilla\Firefox`, which Firefox reads on next launch.

## Option B - `policies.json` drop-in (no ADMX)

Use [`policies.json`](./policies.json) if you'd rather not import ADMX. Deploy it
to **`C:\Program Files\Mozilla Firefox\distribution\policies.json`** with a small
Win32 app or a Remediation (copy file + validate JSON). This is the same file
Microsoft's own Firefox remediation script maintains.

## Verify

Open Firefox and check:

- `about:policies` - shows **Preferences** and **DNSOverHTTPS** as active.
- `about:config` - `network.http.http3.enable` = `false` and locked (no toggle).
- `about:networking#dns` - "HTTPS RR" / TRR should show as not in use.
