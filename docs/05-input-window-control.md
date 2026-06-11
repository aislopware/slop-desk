# 05 — Input Injection & Window Control (the HARDEST part)

> **STATUS: REFERENCE — GUI video-path (Phase 4).** Current architecture: [00-overview.md](00-overview.md) · [DECISIONS.md](DECISIONS.md).

> ⚠️ **ONLY applies to the GUI video-path.** In the hybrid architecture ([12](12-coding-profile.md)), **the terminal goes over the PTY text-path**: input = bytes → PTY stdin → **no CGEvent, no TCC Accessibility, no activate-then-control, no AXUIElement↔CGWindowID matching**. All of the injection risks below **disappear for the terminal** (the bulk of the coding workflow); they only apply when mirroring a GUI window (VS Code/Xcode) in Phase 4.
>
> **Correction (needs testing):** keyboard injection via `CGEventPostToPid` **is** accepted by Electron/VS Code text areas; only **mouse** is rejected by the renderer IPC (requires the SkyLight `SLEventPostToPid` private SPI).

> This is the biggest technical risk of the **GUI video-path**. Read the "limitations" section carefully before designing.

## 0. Blunt conclusion

**Activate-then-control is the CORRECT and nearly the ONLY trustworthy model on modern macOS.** Reasons:

1. **You cannot reliably inject mouse events into a background window.** macOS hit-tests synthesized mouse events against the window z-order under the pointer — exactly like physical input. `CGEventPostToPid` puts the event into the process's queue, but **AppKit still hit-tests internally** and a non-frontmost window usually won't handle the click.
2. **Therefore you must raise/focus the target window first**, then post the event → which is exactly the chosen model.
3. **macOS 14 changed activation to cooperative/advisory** — the system can refuse, especially when triggered by network/timer events (which is precisely the remote-control case).
4. **Incompatible with App Sandbox** → ship outside the Mac App Store, Developer-ID + notarize.
5. **Prefer AX actions (`AXPress`, set `AXValue`) over synthesized clicks** when the UI exposes Accessibility — they bypass hit-testing & focus, far more robust.

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

→ **Use `CGEventPostToPid(targetPid, e)` AFTER raising** (less disturbance of the system pointer). It **complements** activation, it does not replace it.

---

## 2. Coordinate mapping (very easy to get wrong)

**Key fact:** CGEvent mouse positions and `kCGWindowBounds` **use the SAME global "screen space": origin at the top-left of the main display, +Y downward, in points.** → the window rect can be used directly for clicks, **no Y-flip needed**.

⚠️ **AppKit (`NSWindow.frame`/`NSScreen`) is inverted** (origin bottom-left, +Y up). If you mix AppKit frames with CGEvent points → you must flip. **Solution: stay in CG/Quartz space end-to-end; never touch AppKit frames.**

```swift
// remotePoint: coordinates relative to the window's top-left (points)
let target = CGPoint(x: windowBounds.origin.x + remotePoint.x,
                     y: windowBounds.origin.y + remotePoint.y)
```

- **Multi-monitor:** one continuous plane; displays to the left/above have negative coordinates → automatically correct since we add the window origin.
- **Retina:** `kCGWindowBounds` & CGEvent are both in **points**; the scale factor does NOT enter the math. ONLY divide by scale if the client sends **pixel** coordinates from a ScreenCaptureKit frame (frames are in pixels). **Don't double-apply scale.**
- The client should send **normalized (0–1)** coordinates → multiply by `windowBounds.width/height` → fully sidesteps the pixel/point ambiguity.

---

## 3. Keyboard

- **Virtual keycodes** (`virtualKey:keyDown:`): for navigation keys/shortcuts (arrows, Return, Tab, Esc, ⌘-keys). A keycode is a **physical position** → the character depends on the **host's** layout. Set modifiers: `event.flags = [.maskCommand, .maskShift]`.
- **Unicode injection** (`event.keyboardSetUnicodeString(...)`): **the robust way to send text** — layout-independent, delivers exactly the characters the user typed. Fully avoids the keycode-vs-layout and dead-key problems.

**Strategy:** send **text as Unicode**, use **keycodes only for shortcuts/navigation keys**. (Some games read hardware keycodes and ignore Unicode → fall back to keycodes.)

---

## 4. Raising a SPECIFIC window

Activating an *app* only brings its key/main window forward — not necessarily the right window. You must use AX:

```swift
let appEl = AXUIElementCreateApplication(pid)   // pid from SCWindow.owningApplication.processID
var v: CFTypeRef?
AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &v)
let axWindows = v as! [AXUIElement]
let target = axWindows.first { /* match by title / compare frame against SCWindow.frame */ }!

AXUIElementPerformAction(target, kAXRaiseAction as CFString)
AXUIElementSetAttributeValue(appEl, kAXMainWindowAttribute as CFString, target)
NSRunningApplication(processIdentifier: pid)?.activate()   // see the macOS 14 caveat below
```

> ⚠️ **There is no public API to map `AXUIElement` ↔ `CGWindowID`.** Window matching is a **heuristic** (title + comparing `kAXPositionAttribute`/`kAXSizeAttribute` against the CG `frame`). This is the genuinely fragile point of the "one specific window" design — code defensively (multiple windows with the same title, windows moving between query and raise).

### macOS 14+ cooperative activation caveat (important for remote control)

`activate(ignoringOtherApps:)` is deprecated; the new `activate()` is **advisory** — the system may refuse. Community reports: **works when triggered by a user action, FAILS when triggered by a timer/network** — exactly the remote-control case (activation driven by an incoming network event).

Mitigations:
- `activateIgnoringOtherApps:` (deprecated) still works on macOS 14 and is stronger — accept the warning.
- `AXRaise` reorders the window even when full app activation is throttled → **combining `AXRaise` + `activate()` is the most reliable**.
- **Must test on the exact shipping versions (14/15/26)** — activation policy keeps tightening.

---

## 5. Accessibility as the primary control path (when possible)

When a control exposes AX → control it **directly**, without synthesizing mouse/keyboard:

```swift
AXUIElementPerformAction(buttonEl, kAXPressAction as CFString)             // press a button
AXUIElementSetAttributeValue(fieldEl, kAXValueAttribute as CFString, "x")  // set text (layout-independent)
AXUIElementSetAttributeValue(fieldEl, kAXFocusedAttribute as CFString, kCFBooleanTrue)
```

**More robust** because it doesn't depend on pointer position, z-order, hit-testing, or the window being key.

**Limitation:** only as good as the target app's AX implementation. Custom-drawn UI, canvases, many games, Electron/web, OpenGL/Metal views → expose very little → fall back to CGEvent. AX needs the **same Accessibility permission** (no smaller permission footprint, only higher reliability).

**Recommended hybrid:** try AX actions for known control types; fall back to activate-then-CGEvent for everything else (drags, freehand drawing, games, views that expose nothing).

---

## 6. Proposed architecture: "activate-then-control, 1 window at a time"

1. **Enumerate** with ScreenCaptureKit; capture & stream the selected `SCWindow`. Keep `windowID`, `owningApplication.processID`, `frame`.
2. **On every interaction:** re-read the frame (CG space), **raise the specific window** (`AXRaise` + set main, then `activate()` — consider `activateIgnoringOtherApps:` if testing shows the new API drops network-triggered activations).
3. **Map** remote coordinates → global CG (add the window origin; normalize if the stream is in pixels; no Y-flip).
4. **Act:** prefer **AX actions** when the control exposes them; otherwise → **`CGEventPostToPid(pid, e)`**. Send text as **Unicode**, keycodes only for shortcuts.

---

## 7. Tasks for the Phase 0 spike (RISK VALIDATION)

- [ ] Get `pid` + `windowID` + `frame` from `SCWindow`.
- [ ] `AXRaise` the correct specific window of a multi-window app (test the matching heuristic).
- [ ] `CGEventPostToPid` click at mapped coordinates → verify the click lands at the right spot in the window.
- [ ] Test activation from a (simulated) network callback on the target macOS — measure the activation success rate.
- [ ] Try `AXPress` on a standard button → compare reliability against synthesized clicks.

→ If these items pass → the model is viable. If activation fails often → consider fallbacks (see [08-risks](08-risks-open-questions.md)).
