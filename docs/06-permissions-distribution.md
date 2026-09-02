# 06 — Permissions, Entitlements & Distribution

> **STATUS: REFERENCE — GUI video-path design depth.** Shipped, co-equal with terminal panes (old "Phase 4 / secondary" framing retired). Architecture: [00-overview.md](00-overview.md) · [DECISIONS.md](DECISIONS.md).

> **Which process holds the grants, as of `docs/60` F.9.** The host app this section was written
> about is deleted. The terminal host is the CLI daemon `slopdesk-hostd` and it needs no TCC grant
> at all — it forks no capture and posts no event. Both grants below belong to the GUI video daemon
> `rust/slopdesk-videohostd`, which links `slopdesk-apple-sck` for capture and `slopdesk-apple-ax` +
> `slopdesk-apple-cgevent` for the raise-and-inject path. The `Info.plist` keys in §2 are the CLIENT
> app's and the deleted host app's; no release ships `slopdesk-videohostd` yet, so today it is a
> checkout binary (`just videohostd`) and the grant is against whatever signature that build has.

## 1. Required permissions (macOS host)

| Permission (TCC) | Used for | Required? |
|---|---|---|
| **Screen Recording** | ScreenCaptureKit capture + reading other apps' window titles/contents | ✅ Required |
| **Accessibility** | Posting events to other apps + raising/controlling windows via AX | ✅ Required |
| **Input Monitoring** | ONLY if using `CGEventTap` to *observe* local input | ❌ Not needed to *post* events |

Client (Mac/iOS) needs only **Local Network**, for same-LAN Bonjour discovery — see [03](03-transport-protocol.md#1-discovery--bonjour-zero-config). Bonjour does not traverse a WireGuard mesh, so peers on a trusted private network connect by IP/hostname instead.

## 2. Info.plist

```xml
<!-- Host: Screen Recording -->
<key>NSScreenCaptureUsageDescription</key>
<string>SlopDesk shares your application windows with paired devices.</string>

<!-- Client + Host: Local Network — without it Bonjour fails silently on iOS -->
<key>NSLocalNetworkUsageDescription</key>
<string>SlopDesk discovers and connects to devices on the same local network.</string>
<key>NSBonjourServices</key>
<array><string>_panecast._udp</string></array>
```

> Missing `NSScreenCaptureUsageDescription` → the process is **killed** on first touch of SCKit.

## 3. Detecting & requesting permissions

```swift
// Accessibility — check without prompting:
let trusted = AXIsProcessTrusted()
// Check + prompt (opens System Settings → Privacy → Accessibility):
let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
AXIsProcessTrustedWithOptions(opts)

// Screen Recording:
if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
```

- Permissions **cannot be granted programmatically** — the user enables them in System Settings.
- Grants are tied to the **code signature** — unsigned/ad-hoc rebuilds may lose the grant.
- **Poll `AXIsProcessTrusted()`** (or watch for app reactivation) to detect when the user finishes → update onboarding UI.

## 4. Sandbox — dealbreaker

- A **sandboxed app CANNOT obtain Accessibility**: the prompt never appears, it can't be added in Settings, `AXIsProcessTrusted()` stays false, no entitlement re-enables it.
- Core purpose is controlling other apps → **App Sandbox is fully disabled** on the host.
- **Consequence: no Mac App Store** (MAS requires the sandbox).

## 5. Hardened Runtime & Distribution

- **Hardened Runtime** (required for notarization / Developer-ID) is fine — independent of the sandbox, does not block event posting or AX. Posting CGEvents / using AX needs no special entitlement.
- **Distribution:** Developer-ID signed + **notarized**, shipped outside the App Store (DMG / website / Sparkle auto-update).

## 6. Onboarding flow (proposed)

1. Launch → "2 permissions needed" screen.
2. "Grant Screen Recording" → `CGRequestScreenCaptureAccess()`.
3. "Grant Accessibility" → `AXIsProcessTrustedWithOptions(prompt)` → deep-link to Settings.
4. Poll both → once granted, move to the window-picker screen.
5. iOS client: first LAN connection auto-prompts for Local Network.

## 7. Build checklist

> **HISTORICAL — this is the ORIGINAL pre-build plan** (see the banner at the top of this file). It is
> not a task list and an open box does not mean the step is undone: signing, the hardened runtime and
> notarization are all AUTOMATED now, in `rust/slopdesk-devtools/src/release/pack.rs`
> ([49-release-pipeline.md](49-release-pipeline.md)) — which is also why hand-ticking these would be the
> rot one door down, since the recipe is the truth and it can change without this file.

- [ ] `Info.plist`: the 3 keys above.
- [ ] Disable App Sandbox (host).
- [ ] Enable Hardened Runtime.
- [ ] Developer-ID sign + notarize the host app.
- [ ] Onboarding that polls permissions + step-by-step guidance.
