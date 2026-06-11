# 06 — Permissions, Entitlements & Distribution

> **STATUS: REFERENCE — GUI video-path (Phase 4).** Current architecture: [00-overview.md](00-overview.md) · [DECISIONS.md](DECISIONS.md).

## 1. Required permissions (macOS host)

| Permission (TCC) | Used for | Required? |
|-------------|-----------|-----------|
| **Screen Recording** | ScreenCaptureKit capture + reading other apps' window titles/contents | ✅ Required |
| **Accessibility** | Posting events to other apps + raising/controlling windows via AX | ✅ Required |
| **Input Monitoring** | ONLY if using `CGEventTap` to *observe* local input | ❌ Not needed to *post* events |

The client (Mac/iOS) only needs **Local Network** (Bonjour) — see [03](03-transport-protocol.md#1-discovery--bonjour-zero-config).

## 2. Info.plist

```xml
<!-- Host: Screen Recording -->
<key>NSScreenCaptureUsageDescription</key>
<string>PaneCast shares your application windows with paired devices.</string>

<!-- Client + Host: Local Network (mandatory on iOS 14+, without it Bonjour fails silently) -->
<key>NSLocalNetworkUsageDescription</key>
<string>PaneCast discovers and connects to devices on the same local network.</string>
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

- **Permissions cannot be granted programmatically** — the user must enable them in System Settings.
- Grants are tied to the **code signature** — unsigned/ad-hoc rebuilds may lose the grant.
- **Poll `AXIsProcessTrusted()`** (or watch for app reactivation) to know when the user has finished enabling → update the onboarding UI.

## 4. Sandbox — dealbreaker (stated explicitly)

- **A sandboxed app CANNOT obtain the Accessibility permission.** With sandbox on → the prompt never appears, it can't be added in Settings, `AXIsProcessTrusted()` is always false. **No entitlement re-enables it.**
- Since the app's core purpose is controlling other apps → **Sandbox is fully disabled.**
- **Consequence: no Mac App Store** (the App Store requires sandbox).

## 5. Hardened Runtime & Distribution

- **Hardened Runtime** (required for notarization/Developer-ID) is **OK** — it does not block event posting/AX. Hardened runtime and sandbox are independent of each other.
- Usually **no** special hardened-runtime entitlement is needed just to post CGEvents/use AX.
- **Distribution model:** Developer-ID signed + **notarized**, shipped outside the App Store (DMG / website / Sparkle auto-update).

## 6. Onboarding flow (proposed)

1. Open the app → "2 permissions needed" screen.
2. "Grant Screen Recording" button → `CGRequestScreenCaptureAccess()`.
3. "Grant Accessibility" button → `AXIsProcessTrustedWithOptions(prompt)` → deep-link to Settings.
4. Poll both → once both are granted, move to the window picker screen.
5. iOS client: on the first LAN connection → iOS prompts for Local Network automatically.

## 7. Build checklist

- [ ] `Info.plist`: the 3 keys above.
- [ ] Disable App Sandbox (host).
- [ ] Enable Hardened Runtime.
- [ ] Developer-ID sign + notarize the host app.
- [ ] Onboarding that polls permissions + step-by-step guidance.
