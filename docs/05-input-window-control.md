# 05 — Input Injection & Window Control (the HARDEST part)

> **STATUS: REFERENCE — GUI video-path design depth.** Shipped, co-equal with terminal panes (old "Phase 4 / secondary" framing retired). Architecture: [00-overview.md](00-overview.md) · [DECISIONS.md](DECISIONS.md).

> ⚠️ **ONLY applies to GUI-window panes.** A pane is either a terminal pane or a GUI-window pane ([12](12-coding-profile.md)). **Terminal panes go over the PTY text-path**: input = bytes → PTY stdin → **no CGEvent, no TCC Accessibility, no activate-then-control, no AXUIElement↔CGWindowID matching**. Every injection risk below **disappears for terminal panes** (they inject nothing); all apply only when mirroring a GUI window (VS Code/Xcode).
>
> **Correction (needs testing):** keyboard injection via `CGEventPostToPid` **is** accepted by Electron/VS Code text areas; only **mouse** is rejected by the renderer IPC (requires the SkyLight `SLEventPostToPid` private SPI).

## 0. Blunt conclusion

**Activate-then-control is the CORRECT and nearly the ONLY trustworthy model on modern macOS.**

1. **Cannot reliably inject mouse into a background window.** macOS hit-tests synthesized mouse events against the window z-order under the pointer, like physical input. `CGEventPostToPid` queues the event, but **AppKit still hit-tests internally** → a non-frontmost window usually won't handle the click.
2. **So raise/focus the target window first**, then post → the chosen model.
3. **Modern macOS makes activation cooperative/advisory** — the system can refuse, especially for network/timer-triggered events (precisely the remote-control case).
4. **Incompatible with App Sandbox** → ship outside the Mac App Store, Developer-ID + notarize.
5. **Prefer AX actions (`AXPress`, set `AXValue`) over synthesized clicks** where the UI exposes Accessibility — they bypass hit-testing & focus, far more robust.

---

## 1. Creating & posting CGEvents

```swift
let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: .left)
let up   = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,   mouseCursorPosition: pt, mouseButton: .left)
let kdn  = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
let scr  = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
```

Gotchas:
- **Drag** = `.leftMouseDown` → many `.leftMouseDragged` → `.leftMouseUp`. Down→up at 2 points is NOT a drag.
- **Double-click:** set `.mouseEventClickState = 2` on the second down/up pair.
- **Mouse moved/dragged:** set `.mouseEventDeltaX/Y` for apps/games that read deltas.

### Routing — the crux

| Function | Routing | Target process? |
|-----|---------|-----------------|
| `CGEventPost(.cghidEventTap)` | Lowest HID layer, moves the real pointer, global hit-test | No |
| `CGEventPost(.cgSessionEventTap)` | Session stream, still global hit-test | No |
| `CGEventPostToPid(pid, e)` | Into a specific process's queue, **but AppKit still hit-tests internally** | Process, **not the window** |

→ **Use `CGEventPostToPid(targetPid, e)` AFTER raising** (less disturbance of the system pointer). It **complements** activation, doesn't replace it.

---

## 2. Coordinate mapping (very easy to get wrong)

**Key fact:** CGEvent mouse positions and `kCGWindowBounds` **use the SAME global "screen space": origin at the top-left of the main display, +Y downward, in points.** → use the window rect directly for clicks, **no Y-flip needed**.

⚠️ **AppKit (`NSWindow.frame`/`NSScreen`) is inverted** (origin bottom-left, +Y up). Mixing AppKit frames with CGEvent points forces a flip. **Solution: stay in CG/Quartz space end-to-end; never touch AppKit frames.**

```swift
// remotePoint: coordinates relative to the window's top-left (points)
let target = CGPoint(x: windowBounds.origin.x + remotePoint.x,
                     y: windowBounds.origin.y + remotePoint.y)
```

- **Multi-monitor:** one continuous plane; displays to the left/above have negative coordinates → correct automatically since we add the window origin.
- **Retina:** `kCGWindowBounds` & CGEvent are both **points**; scale factor does NOT enter the math. ONLY divide by scale if the client sends **pixel** coordinates from a ScreenCaptureKit frame (frames are pixels). **Don't double-apply scale.**
- The client should send **normalized (0–1)** coordinates → multiply by `windowBounds.width/height` → fully sidesteps the pixel/point ambiguity.

> Normalize → window-rect mapping (and pixel/point scale) is native Swift coordinate mapping; the shell supplies the live window rect and posts the resulting CGEvent.

---

## 3. Keyboard

- **Virtual keycodes** (`virtualKey:keyDown:`): navigation keys/shortcuts (arrows, Return, Tab, Esc, ⌘-keys). A keycode is a **physical position** → character depends on the **host's** layout. Set modifiers: `event.flags = [.maskCommand, .maskShift]`.
- **Unicode injection** (`event.keyboardSetUnicodeString(...)`): **the robust way to send text** — layout-independent, delivers exactly the typed characters. Avoids the keycode-vs-layout and dead-key problems.

**Strategy:** send **text as Unicode**, use **keycodes only for shortcuts/navigation keys**. (Some games read hardware keycodes and ignore Unicode → fall back to keycodes.)

---

## 4. Raising a SPECIFIC window

Activating an *app* only brings its key/main window forward — not necessarily the right one. Use AX:

```swift
let appEl = AXUIElementCreateApplication(pid)   // pid from SCWindow.owningApplication.processID
var v: CFTypeRef?
AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &v)
let axWindows = v as! [AXUIElement]
let target = axWindows.first { /* match by title / compare frame against SCWindow.frame */ }!

AXUIElementPerformAction(target, kAXRaiseAction as CFString)
AXUIElementSetAttributeValue(appEl, kAXMainWindowAttribute as CFString, target)
NSRunningApplication(processIdentifier: pid)?.activate()   // see the activation caveat below
```

> ⚠️ **No public API maps `AXUIElement` ↔ `CGWindowID`.** Window matching is a **heuristic** (title + comparing `kAXPositionAttribute`/`kAXSizeAttribute` against the CG `frame`). This is the genuinely fragile point of the "one specific window" design — code defensively (multiple windows same title, windows moving between query and raise).

### Cooperative activation caveat (important for remote control)

`activate(ignoringOtherApps:)` is deprecated; `activate()` is **advisory** — the system may refuse. Community reports: **works when triggered by a user action, FAILS when triggered by a timer/network** — exactly the remote-control case (activation driven by an incoming network event).

Mitigations:
- `activateIgnoringOtherApps:` (deprecated) still works and is stronger — accept the warning.
- `AXRaise` reorders the window even when full app activation is throttled → **combining `AXRaise` + `activate()` is the most reliable**.
- **Test on the shipping floor (macOS 26)** — activation policy keeps tightening.

---

## 5. Accessibility as the primary control path (when possible)

When a control exposes AX → control it **directly**, without synthesizing mouse/keyboard:

```swift
AXUIElementPerformAction(buttonEl, kAXPressAction as CFString)             // press a button
AXUIElementSetAttributeValue(fieldEl, kAXValueAttribute as CFString, "x")  // set text (layout-independent)
AXUIElementSetAttributeValue(fieldEl, kAXFocusedAttribute as CFString, kCFBooleanTrue)
```

**More robust** — no dependence on pointer position, z-order, hit-testing, or the window being key.

**Limitation:** only as good as the target app's AX implementation. Custom-drawn UI, canvases, many games, Electron/web, OpenGL/Metal views expose very little → fall back to CGEvent. AX needs the **same Accessibility permission** (no smaller footprint, only higher reliability).

**Recommended hybrid:** try AX actions for known control types; fall back to activate-then-CGEvent for everything else (drags, freehand drawing, games, views that expose nothing).

---

## 6. Proposed architecture: "activate-then-control, 1 window at a time"

1. **Enumerate** with ScreenCaptureKit; capture & stream the selected `SCWindow`. Keep `windowID`, `owningApplication.processID`, `frame`.
2. **On every interaction:** re-read the frame (CG space), **raise the specific window** (`AXRaise` + set main, then `activate()` — consider `activateIgnoringOtherApps:` if testing shows the new API drops network-triggered activations).
3. **Map** remote coordinates → global CG (add the window origin; normalize if the stream is in pixels; no Y-flip).
4. **Act:** prefer **AX actions** when the control exposes them; else **`CGEventPostToPid(pid, e)`**. Send text as **Unicode**, keycodes only for shortcuts.

---

## 7. Tasks for the Phase 0 spike (RISK VALIDATION)

- [ ] Get `pid` + `windowID` + `frame` from `SCWindow`.
- [ ] `AXRaise` the correct specific window of a multi-window app (test the matching heuristic).
- [ ] `CGEventPostToPid` click at mapped coordinates → verify it lands at the right spot in the window.
- [ ] Test activation from a (simulated) network callback on the target macOS — measure the activation success rate.
- [ ] Try `AXPress` on a standard button → compare reliability against synthesized clicks.

→ If these pass → the model is viable. If activation fails often → consider fallbacks (see [08-risks](08-risks-open-questions.md)).

---

## 8. Trackpad gestures — audit & forwarding contract (2026-07-16)

Ground truth, probe-verified on macOS 26 (`scratchpad` probes; six CGEvent field variants — phases,
`ScrollCount`, `mayBegin`, momentum tail, `BeginGesture`/`EndGesture` brackets — against Safari + Chrome
with real link-click history): **a synthetic phased scroll can NEVER trigger the browser's own
two-finger history swipe.** Chromium's `HistorySwiper` needs real `NSTouch` data (trackpad path) or
routes into `trackSwipeEventWithOptions:` (Magic-Mouse path) — both reject CGEvent-posted scrolls;
Safari behaves identically. Likewise there is **no public constructor for gesture events** (`magnify` /
`rotate` / `smartMagnify` / `swipe` / `quickLook` / `pressure`) — only scroll wheels and mouse/key
events can be synthesised; the private byte-blob route (Hammerspoon's TouchEvents) is broken in
Chromium apps and macOS-version-fragile. So everything beyond plain scroll is either **translated to
key equivalents** or **deliberately dropped**:

| Gesture (2-finger unless noted) | Reaches the client view as | Disposition |
|---|---|---|
| Scroll (any direction, incl. momentum) | `scrollWheel` + phases | **Forwarded 1:1** (wire `.scroll`, phases replayed on host — native rubber-band/inertia) |
| Swipe between pages (horizontal swipe, any speed) | same scroll stream | **Translated on HOST**: `SwipeNavRecognizer` on the injected stream → ⌘[ / ⌘] when the receiving app is in `SwipeNavPolicy` (browsers + Finder). `SLOPDESK_SWIPE_NAV` default-ON; `SLOPDESK_SWIPE_NAV_APPS` extends. Three decision points: at LIFT (≤ 450 ms began→ended, ≥ 80 pt on-glass, ≥ 3× horizontal dominance); by MOMENTUM CONFIRMATION — a sharp flick spends most of its displacement in the momentum tail, so a dominant quick lift ≥ 24 pt arms a 250 ms coast window that fires at ≥ 120 pt combined; or via the SLOW tier — natively a page-swipe works at any speed (drag, even hold, release), so past 450 ms the lift fires on COMMITMENT instead: ≥ 160 pt (2×) travel with ≥ 4× dominance, GRADUATED to ≥ 2× dominance once travel is overwhelming (≥ 240 pt, 3×) — native decides the axis at onset and forgives later wobble that a whole-gesture ratio re-taxes; no upper duration bound (`SLOPDESK_SWIPE_NAV_SLOW=0` restores the flick-only gate). Momentum can only confirm what a flick lift armed — diagonal/modest content pans keep scrolling only. UDP-loss tolerant: a lost `began` is synthesised from the first continuous `changed`, a lost `ended` from the first momentum event. `SLOPDESK_SWIPE_NAV_TRAVEL` scales the threshold family (default 80); `SLOPDESK_SWIPE_NAV_TRACE` logs per-gesture verdicts (travel/duration/dominance) to stderr. |
| — swipe-peel FEEDBACK (client, macOS) | same scroll stream, mirrored locally | **The piece key translation can't give**: the page reacting WHILE the fingers are on the glass. The client runs its own `SwipeNavRecognizer` (in `SwipePeelPlanner`) over the very stream it forwards and, from ≥ 24 pt decisively-horizontal travel, slides the page WITH the fingers (~1:1 with a soft `tanh` knee into a cap at 45 % of the pane — never past where the reveal reads as a detached card) over a flat near-black underlay with an edge shade, and shows a chevron-in-circle chip whose ring fills toward the live tier's commit threshold, turning solid + one trackpad haptic tap the instant "release now navigates". Commit ⇒ the outgoing page FREEZES into a snapshot (one NV12→RGB conversion of the frame on glass) while the live layer returns home invisibly beneath it, holds ~280 ms for the post-navigation page to stream in, then slides off in the swipe direction — Safari's own snapshot-swap trick, masking the inject→capture→stream round trip; no frame on glass yet degrades to the plain 180 ms ease-home. Reject/coast-expiry/reroute ⇒ ease-home (shade fades in the same transaction). Gated + configured by the host's `SwipeNavStatusMessage` push (cursor socket type 3, doc 20 §9.6): no push or `eligible=false` ⇒ no overlay — the affordance never lies in an app where ⌘[ would edit text, and a host-side `SLOPDESK_SWIPE_NAV_TRAVEL`/`_SLOW` retune re-tunes the mirror. |
| Pinch zoom | `magnify(with:)` | **Translated on CLIENT**: `PinchZoomKeyPlanner` → ⌘= / ⌘− steps (0.2 magnification per step, ≤ 3 steps/event). `SLOPDESK_PINCH_KEYS` default-ON. |
| Smart zoom (double-tap) | `smartMagnify(with:)` | **Translated on CLIENT**: ⌘0 (actual size) — pairs with the pinch ladder. Same flag. |
| Tap-to-click / 2-finger tap (secondary) | plain mouse events | Already forwarded (indistinguishable from clicks) |
| 3-finger drag (accessibility) | plain down/drag/up | Already forwarded |
| Rotate | `rotate(with:)` | **Dropped** — no universal key equivalent; niche on a coding desktop |
| Force click / Quick Look / pressure | `pressureChange`/`quickLook` | **Dropped** — pressure can't be faithfully synthesised; host Quick Look = press Space yourself |
| Mission Control / App Exposé / Spaces / Launchpad / Show Desktop / Notification Centre (3-4 finger, edge) | **never reaches any app** — consumed by the client's own WindowServer/Dock | Not capturable at app level, IMPOSSIBLE to forward as gestures. Host-side equivalents already work as keystrokes (⌃↑ / ⌃↓ / ⌃←→ / F11) — reachable via immersive mode's system-key capture |

Traps that produced false probe negatives (keep for the next RE round): a stray same-app window
(here: a Safari "Open" dialog) can sit exactly over the probe point — verify the top window at the
target coordinate, not just the app; and posting a ⌘-flagged key through the shared
`.hidSystemState` source LATCHES ⌘ onto every later synthetic event (the known `postText` trap) —
probes must set `flags = []` explicitly on every event. Both shipped translations therefore emit BRACKETED chords — real ⌘ key down, letter pair flagged, ⌘ release with empty flags — the same byte-shape a forwarded client chord has.
