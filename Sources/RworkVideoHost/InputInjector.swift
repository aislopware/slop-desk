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

    public init(pid: pid_t, windowID: CGWindowID, windowBoundsCG: VideoRect) {
        self.pid = pid
        self.windowID = windowID
        self.windowBoundsCG = windowBoundsCG
        self.eventSource = CGEventSource(stateID: .hidSystemState)
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
        switch event {
        case .mouseMove(let n, let tag):
            postMouseMove(normalized: n, tag: tag)
        case .mouseDown(let button, let n, let clickCount, let mods, let tag):
            postMouseButton(button: button, normalized: n, down: true, clickCount: clickCount, modifiers: mods, tag: tag)
        case .mouseUp(let button, let n, let clickCount, let mods, let tag):
            postMouseButton(button: button, normalized: n, down: false, clickCount: clickCount, modifiers: mods, tag: tag)
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

    private func postMouseMove(normalized: VideoPoint, tag: UInt32) {
        let pt = target(normalized)
        // Absolute move: warp the cursor, then post a moved event so apps reading
        // deltas see it (doc 05 §1).
        CGWarpMouseCursorPosition(pt)
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left) {
            stampAndPost(event, tag: tag)
        }
    }

    private func postMouseButton(button: MouseButton, normalized: VideoPoint, down: Bool, clickCount: UInt8, modifiers: InputModifiers, tag: UInt32) {
        let pt = target(normalized)
        let (cgButton, downType, upType): (CGMouseButton, CGEventType, CGEventType)
        switch button {
        case .left: (cgButton, downType, upType) = (.left, .leftMouseDown, .leftMouseUp)
        case .right: (cgButton, downType, upType) = (.right, .rightMouseDown, .rightMouseUp)
        case .other: (cgButton, downType, upType) = (.center, .otherMouseDown, .otherMouseUp)
        }
        guard let event = CGEvent(mouseEventSource: eventSource, mouseType: down ? downType : upType, mouseCursorPosition: pt, mouseButton: cgButton) else { return }
        if clickCount >= 2 { event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount)) }
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
        stampAndPost(event, tag: tag)
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
        stampAndPost(down, tag: tag)
        // Bare key-up: NO keyboardSetUnicodeString (attaching it here would insert the
        // text a second time).
        if let up = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false) {
            stampAndPost(up, tag: tag)
        }
    }

    /// Stamps the self-inject filter tag on `eventSourceUserData` then posts at the
    /// HID tap (doc 18 §A). The cursor/geometry watchers compare incoming NSEvent
    /// `eventSourceUserData` to drop events we injected ourselves.
    private func stampAndPost(_ event: CGEvent, tag: UInt32) {
        event.setIntegerValueField(.eventSourceUserData, value: Int64(tag))
        event.post(tap: .cghidEventTap)
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
