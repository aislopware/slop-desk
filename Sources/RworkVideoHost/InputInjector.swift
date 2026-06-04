#if os(macOS)
import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import RworkVideoProtocol

/// Injects remote input into a tracked window using the **activate-then-control**
/// model (doc 18 §A — Dissolved-by-decision; doc 05).
///
/// ⚠️ **GUI-ONLY + TCC:** this code drives real input. It needs three TCC grants and
/// is ship-outside-the-Mac-App-Store / non-sandboxed (doc 05 §0):
/// 1. **Accessibility** — for `AXUIElementPerformAction(kAXRaiseAction)` + setting
///    `kAXFocusedWindow`/`kAXMainWindow`.
/// 2. **'Post Event' (a.k.a. "Accessibility / Input Monitoring" post)** — required by
///    `CGEvent.post` to synthesise HID events (doc 18 §B point 1).
/// 3. **Screen Recording** — the capture side (`WindowCapturer`) needs it; bundled
///    here for completeness.
/// COMPILED + reviewed; NEVER driven from tests.
///
/// Per-interaction flow (doc 18 §A, doc 05 §6):
/// 1. Raise + focus the target window (`NSRunningApplication.activate` + AX
///    `kAXRaiseAction` / set `kAXFocusedWindow`) → it becomes frontmost.
/// 2. Map the event's normalised window coordinate → host-window CG point via
///    ``CoordinateMapping`` (no Y flip; the click point is CG top-left, doc 05 §2).
/// 3. `CGEvent.post(.cghidEventTap)` / `CGWarpMouseCursorPosition`, stamping
///    `eventSourceUserData` = the event's `tag` so the host can FILTER its own
///    self-injected events out of the cursor/geometry watchers (avoids loops).
public final class InputInjector: @unchecked Sendable {
    private let pid: pid_t
    private let windowID: CGWindowID
    /// The `kCGWindowBounds` (CG top-left points) of the target window, kept in sync
    /// by the geometry watcher so mapping stays correct as the window moves.
    private var windowBoundsCG: VideoRect
    private let boundsLock = NSLock()
    /// The CGEventSource whose `userData` we stamp = self-inject filter tag.
    private let eventSource: CGEventSource?

    /// SAFETY button-balance. On a `mouseDown` for an already-held button it injects a synthetic
    /// release first, so a fresh click never starts inside a selection stranded by a lost
    /// `mouseUp`. Pure decision lives in ``InputButtonBalance``; the lock guards it (harmless
    /// insurance — in the ordered path injection is already serial).
    private let balanceLock = NSLock()
    private var balance = InputButtonBalance()

    /// Test-only same-machine seam (`RWORK_VIDEO_INJECT_TO_PID=1`): deliver events straight to
    /// the target PID via `postToPid` and SKIP the cursor warp, so a loopback host on the SAME
    /// Mac does not hijack the global cursor away from the client window being driven (which
    /// would fight an automated drag). PRODUCTION leaves this off — the remote user's real
    /// cursor must track via the HID warp. Ordering/selection semantics are unchanged; only the
    /// post tap + cursor move differ.
    private static let injectToPid = ProcessInfo.processInfo.environment["RWORK_VIDEO_INJECT_TO_PID"] != nil
    private static let inputTrace = ProcessInfo.processInfo.environment["RWORK_INPUT_TRACE"] != nil

    public init(pid: pid_t, windowID: CGWindowID, windowBoundsCG: VideoRect) {
        self.pid = pid
        self.windowID = windowID
        self.windowBoundsCG = windowBoundsCG
        self.eventSource = CGEventSource(stateID: .hidSystemState)
        if let eventSource {
            // Default local-events suppression interval is 0.25s: after a posted (or warped)
            // event, subsequent synthetic events landing inside that window can be eaten —
            // exactly why a click right after a warp-move sometimes "didn't take". Zero it so
            // injected events are never suppressed. (CGEventSource header; the free
            // `CGEventSourceSetLocalEventsSuppressionInterval` is obsoleted, this property
            // is the modern equivalent.)
            eventSource.localEventsSuppressionInterval = 0
        }
    }

    public func updateWindowBounds(_ bounds: VideoRect) {
        boundsLock.lock(); windowBoundsCG = bounds; boundsLock.unlock()
    }

    private var bounds: VideoRect {
        boundsLock.lock(); defer { boundsLock.unlock() }; return windowBoundsCG
    }

    // MARK: Activate-then-control

    /// Raises + focuses the target window so it is frontmost before posting events
    /// (doc 18 §A). Combines AX raise (reorders even when full app activation is
    /// throttled on macOS 14+) with `activate()` (doc 05 §4 caveat).
    @MainActor
    public func raiseTargetWindow() {
        let appEl = AXUIElementCreateApplication(pid)
        // Cap blocking AX IPC. `raiseTargetWindow` runs on the main actor and the input
        // consumer AWAITS it before injecting the mouseDown (activate-then-control), so a
        // hung/modal/beachballing target app would otherwise head-of-line-stall the WHOLE
        // ordered input stream for the framework default (~6s) and let pointer datagrams pile
        // up unbounded. A short timeout makes each AX call fail fast instead (the raise is
        // best-effort: a missed raise just means the click lands on the already-frontmost
        // window) without changing injection ordering.
        AXUIElementSetMessagingTimeout(appEl, 0.25)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return }
        // Heuristic match the AX window to the tracked CGWindowID by frame (no public
        // map exists — doc 05 §4); defensive against same-title windows.
        let targetBounds = bounds
        for axWindow in axWindows where axWindowMatchesBounds(axWindow, targetBounds) {
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(appEl, kAXMainWindowAttribute as CFString, axWindow)
            AXUIElementSetAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, axWindow)
            break
        }
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    // MARK: Event posting (tagged for self-inject filtering)

    /// Posts a remote input event. The window must already be raised (call
    /// ``raiseTargetWindow()`` for the first event of an interaction).
    public func inject(_ event: InputEvent) {
        // SAFETY auto-release: clear a button left stuck by a lost/never-sent `mouseUp` BEFORE
        // posting a fresh `mouseDown` on it, so a click never begins inside a phantom selection.
        let plan = balanceLock.withLock { balance.plan(for: event) }
        if let stuck = plan.preRelease, case .mouseDown(_, let n, _, let mods, let tag) = event {
            if Self.inputTrace {
                FileHandle.standardError.write(Data("rwork-videohostd[inject]: SAFETY pre-release of stuck \(stuck) before mouseDown\n".utf8))
            }
            postMouseButton(button: stuck, normalized: n, down: false, clickCount: 1, modifiers: mods, tag: tag)
        }
        if plan.suppress {
            // A duplicate up from the client's loss-resilient 3× send (button already
            // released) — drop it so the host never posts a spurious extra *MouseUp.
            if Self.inputTrace {
                FileHandle.standardError.write(Data("rwork-videohostd[inject]: suppressed duplicate mouseUp (button not held)\n".utf8))
            }
            return
        }
        switch event {
        case .mouseMove(let n, let tag):
            postMouseMove(normalized: n, tag: tag)
        case .mouseDown(let button, let n, let clickCount, let mods, let tag):
            postMouseButton(button: button, normalized: n, down: true, clickCount: clickCount, modifiers: mods, tag: tag)
        case .mouseUp(let button, let n, let clickCount, let mods, let tag):
            postMouseButton(button: button, normalized: n, down: false, clickCount: clickCount, modifiers: mods, tag: tag)
        case .mouseDrag(let button, let n, let clickCount, let mods, let tag):
            postMouseDrag(button: button, normalized: n, clickCount: clickCount, modifiers: mods, tag: tag)
        case .scroll(let dx, let dy, _, let tag):
            postScroll(dx: dx, dy: dy, tag: tag)
        case .key(let keyCode, let down, let mods, let tag):
            postKey(keyCode: keyCode, down: down, modifiers: mods, tag: tag)
        case .text(let string, let tag):
            postText(string, tag: tag)
        }
    }

    private func target(_ normalized: VideoPoint) -> CGPoint {
        CoordinateMapping.windowPoint(normalized: normalized, windowBounds: bounds).cgPoint
    }

    /// Warp the cursor to an absolute point, then immediately re-associate the mouse and
    /// cursor so the warp's transient disassociation (which can swallow the next synthetic
    /// event) is cancelled. Together with the suppression interval = 0 set in `init`, this
    /// makes warp-then-post safe so absolute positioning never eats the following event.
    private func warp(to pt: CGPoint) {
        if Self.injectToPid { return }  // test seam: don't hijack the global cursor (same-machine loopback)
        CGWarpMouseCursorPosition(pt)
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))   // re-associate (true)
    }

    private func postMouseMove(normalized: VideoPoint, tag: UInt32) {
        let pt = target(normalized)
        // Absolute HOVER move: warp the cursor, then post `.mouseMoved` so apps reading
        // deltas see it (doc 05 §1). A button-held drag is NEVER inferred here — the client
        // sends an explicit `.mouseDrag` for that (see ``postMouseDrag``), so a move is
        // always a pure hover. This is the fix for the former GAP D1: when the host inferred
        // "is a button held?" from its own state, a lost `mouseUp` datagram left that state
        // stuck, turning every later hover into a phantom `.leftMouseDragged` (runaway
        // selection until the next click). Stateless = no phantom drag.
        warp(to: pt)
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left) {
            stampAndPost(event, tag: tag)
        }
    }

    /// Posts a drag-move: the `*MouseDragged` matching the held `button`, at `pt`. STATELESS
    /// — the CLIENT told us a button is held (its view reported `mouseDragged`, a distinct
    /// callback from `mouseMoved`), so we never track held state on the host. A `*MouseDragged`
    /// is the event type macOS selection/drag engines consume between mouseDown and mouseUp; a
    /// bare `.mouseMoved` mid-gesture is ignored and can collapse a selection — which broke
    /// drag-select ("bôi không được"). Statelessness also makes this wire-reorder-safe: over
    /// plain UDP a drag can arrive before its `mouseDown`; the target app just ignores a
    /// dragged with no active session, then anchors when the down lands and extends to the
    /// final drag — so the selection range stays correct even if early drag samples are lost
    /// or reordered.
    private func postMouseDrag(button: MouseButton, normalized: VideoPoint, clickCount: UInt8, modifiers: InputModifiers, tag: UInt32) {
        let pt = target(normalized)
        warp(to: pt)
        let (type, cgButton): (CGEventType, CGMouseButton)
        switch button {
        case .left:  (type, cgButton) = (.leftMouseDragged, .left)
        case .right: (type, cgButton) = (.rightMouseDragged, .right)
        case .other: (type, cgButton) = (.otherMouseDragged, .center)
        }
        guard let event = CGEvent(mouseEventSource: eventSource, mouseType: type, mouseCursorPosition: pt, mouseButton: cgButton) else { return }
        // A real drag carries the originating click's clickState (1 = drag-select, 2 =
        // word-by-word). A freshly-created dragged event defaults to clickState 0, which some
        // selection engines treat as "not part of a drag" → nothing selects. Match the down:
        // SAME value on the down, the drags, and the up (`postMouseButton` sets it too).
        event.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, Int(clickCount))))
        event.flags = cgFlags(modifiers)
        stampAndPost(event, tag: tag)
    }

    private func postMouseButton(button: MouseButton, normalized: VideoPoint, down: Bool, clickCount: UInt8, modifiers: InputModifiers, tag: UInt32) {
        let pt = target(normalized)
        // Warp before posting so a tap with no preceding move still lands at `pt` and the
        // visible cursor agrees with where the click registers. Safe now that the
        // suppression interval is 0 and `warp` re-associates the cursor.
        warp(to: pt)
        let (cgButton, downType, upType): (CGMouseButton, CGEventType, CGEventType)
        switch button {
        case .left: (cgButton, downType, upType) = (.left, .leftMouseDown, .leftMouseUp)
        case .right: (cgButton, downType, upType) = (.right, .rightMouseDown, .rightMouseUp)
        case .other: (cgButton, downType, upType) = (.center, .otherMouseDown, .otherMouseUp)
        }
        guard let event = CGEvent(mouseEventSource: eventSource, mouseType: down ? downType : upType, mouseCursorPosition: pt, mouseButton: cgButton) else { return }
        // A single click needs clickState = 1 to register reliably (focus / insertion point);
        // 2 = double, 3 = triple. It MUST be set on BOTH the down and the up edge with the
        // SAME value — a freshly-created CGEvent does not reliably carry clickState = 1, so
        // clicks "didn't take" or landed wrong. (`mouseEventClickState`; Apple forum 685901.)
        event.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, Int(clickCount))))
        event.flags = cgFlags(modifiers)
        stampAndPost(event, tag: tag)
    }

    private func postScroll(dx: Double, dy: Double, tag: UInt32) {
        // dx/dy arrive off the (untrusted) wire. `Int32(Double)` is the TRAPPING
        // initializer — it fatal-errors on NaN/±inf or any value outside Int32's range
        // (e.g. a hostile `1e300`), so a single crafted scroll datagram could crash the
        // whole host process. `RworkVideoProtocol` already rejects non-finite deltas at
        // decode; this clamp is the defence-in-depth backstop for a finite-but-huge value,
        // and it can never trap.
        guard let event = CGEvent(scrollWheelEvent2Source: eventSource, units: .pixel, wheelCount: 2,
                                  wheel1: Self.clampToInt32(dy), wheel2: Self.clampToInt32(dx), wheel3: 0) else { return }
        stampAndPost(event, tag: tag)
    }

    /// Clamps a wire-supplied scroll delta into `Int32` without ever trapping. `NaN` becomes
    /// 0; ±infinity and any out-of-range magnitude saturate to `Int32.min`/`Int32.max`. (The
    /// NaN check MUST come first — every comparison with NaN is false, so it would otherwise
    /// fall through to the trapping `Int32(_:)`.)
    static func clampToInt32(_ value: Double) -> Int32 {
        if value.isNaN { return 0 }
        if value >= Double(Int32.max) { return Int32.max }
        if value <= Double(Int32.min) { return Int32.min }
        return Int32(value.rounded())
    }

    private func postKey(keyCode: UInt16, down: Bool, modifiers: InputModifiers, tag: UInt32) {
        guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(keyCode), keyDown: down) else { return }
        event.flags = cgFlags(modifiers)
        postKeyboardEvent(event)
    }

    /// Unicode text injection — layout-independent, the robust text path (doc 05 §3).
    ///
    /// The unicode string is attached to the **key-DOWN event ONLY**. Attaching it to
    /// BOTH the down and the up double-inserts the text (the up-event would emit the
    /// string a second time), so the key-up is posted bare — it just completes the
    /// keystroke so the target app sees a balanced down/up pair (CGEvent contract).
    private func postText(_ string: String, tag: UInt32) {
        let units = Array(string.utf16)
        guard let down = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true) else { return }
        units.withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        // Force a MODIFIER-FREE insertion. A plain-text keystroke must never inherit a
        // latched/residual modifier from the shared `.hidSystemState` source — e.g. a ⌘
        // left stuck after ⌘+Delete would turn this insertion into a ⌘-modified keystroke
        // (Return → newline-with-⌘, etc.). `postKey` already sets `flags` explicitly; only
        // `postText` left them at the source default, so clear them here on both edges.
        down.flags = []
        postKeyboardEvent(down)
        // Bare key-up: NO keyboardSetUnicodeString (attaching it here would insert the
        // text a second time). Also modifier-free, matching the down.
        if let up = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false) {
            up.flags = []
            postKeyboardEvent(up)
        }
    }

    /// Posts a KEYBOARD event at the HID tap, deliberately WITHOUT stamping
    /// `eventSourceUserData`. This is the one place that diverges from ``stampAndPost``.
    ///
    /// A host Vietnamese IME (the user runs **xkey** — xmannv/xkey) installs TWO event
    /// taps: a HID tap (`.cghidEventTap`, head-insert) and a session tap
    /// (`.cgSessionEventTap`, tail-append) that exists specifically to catch
    /// remote-desktop-injected keystrokes. To avoid composing the same keystroke twice it
    /// DEDUPES across the two taps using `eventSourceUserData`: the HID tap marks an event
    /// it has handled so the session tap can skip it. A keystroke we post to the HID tap
    /// carrying our own NONZERO self-inject `tag` defeats that dedup — xkey's session tap
    /// re-processes it → DOUBLE Telex composition → garbage (empirically verified with
    /// `scripts/inject-telex-probe.swift`: injecting "ddaa" WITH a nonzero userData yields
    /// "daa"; with userData cleared it yields the correct "đâ"). Posting `userData = 0`
    /// restores the dedup and the IME composes exactly once.
    ///
    /// Keys are safe to leave untagged: the self-inject filter exists only for the
    /// `CursorSampler` / `WindowGeometryWatcher` feedback loop, which is driven by POINTER
    /// and GEOMETRY events — a keystroke never moves the cursor or resizes the window, so it
    /// can never feed back. Mouse/scroll events still go through ``stampAndPost`` (xkey only
    /// taps keyboard events, so their tag is harmless to it and needed by our own watchers).
    private func postKeyboardEvent(_ event: CGEvent) {
        event.post(tap: .cghidEventTap)
    }

    /// Stamps the self-inject filter tag on `eventSourceUserData` then posts at the
    /// HID tap (doc 18 §A). The cursor/geometry watchers compare incoming NSEvent
    /// `eventSourceUserData` to drop events we injected ourselves. POINTER/SCROLL ONLY —
    /// keyboard events use ``postKeyboardEvent`` (untagged) so the host IME's tap-dedup
    /// is not defeated.
    private func stampAndPost(_ event: CGEvent, tag: UInt32) {
        event.setIntegerValueField(.eventSourceUserData, value: Int64(tag))
        if Self.injectToPid, pid != 0 {
            event.postToPid(pid)   // test seam: deliver to the target app without moving the cursor
        } else {
            event.post(tap: .cghidEventTap)
        }
    }

    private func cgFlags(_ modifiers: InputModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.capsLock) { flags.insert(.maskAlphaShift) }
        if modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }

    @MainActor
    private func axWindowMatchesBounds(_ element: AXUIElement, _ targetBounds: VideoRect) -> Bool {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success else {
            return false
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        // Tolerate sub-point rounding between AX and CGWindowBounds.
        return abs(Double(point.x) - targetBounds.origin.x) < 2
            && abs(Double(point.y) - targetBounds.origin.y) < 2
            && abs(Double(size.width) - targetBounds.size.width) < 2
            && abs(Double(size.height) - targetBounds.size.height) < 2
    }
}
#endif
