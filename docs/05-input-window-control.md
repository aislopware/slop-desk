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
