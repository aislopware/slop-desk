#if os(macOS)
import Foundation
import CoreGraphics
import ApplicationServices
import OSLog

/// Private AX SPI: maps an `AXUIElement` window to its `CGWindowID`. TCC-gated (Accessibility), no
/// SIP disable needed — the same trust the injector/geometry watcher already require. Lets us match
/// the EXACT target window by id at mint time (more robust than frame-matching when the window may
/// be about to move displays).
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

/// PURE placement arithmetic (feature #1): decide where/how to move a window fully onto a display.
/// Headlessly unit-testable; the AX side effects live in ``WindowPlacement``.
public enum WindowPlacementMath {
    /// Clamp `windowSize` to `displayBounds` (resize DOWN only if larger — never enlarge) and place
    /// at the display's top-left origin. macOS crops a window that overhangs a display, so an
    /// oversized window must be shrunk before the move.
    public static func placement(windowSize: CGSize, displayBounds: CGRect)
        -> (origin: CGPoint, size: CGSize, needsResize: Bool) {
        let w = min(windowSize.width, displayBounds.width)
        let h = min(windowSize.height, displayBounds.height)
        // ½-pt tolerance so floating-point equality doesn't trigger a no-op resize.
        let needsResize = (w + 0.5 < windowSize.width) || (h + 0.5 < windowSize.height)
        return (displayBounds.origin, CGSize(width: w, height: h), needsResize)
    }
}

/// Moves a target window onto a display via Accessibility (feature #1 — put the remoted window on
/// the HiDPI virtual display so it renders at real 2× backing). Best-effort + crash-free.
public enum WindowPlacement {
    private static let log = Logger(subsystem: "aislopdesk.video.host", category: "WindowPlacement")

    /// Move the window `windowID` (owned by `pid`) fully onto `displayID`. Resizes it DOWN first if
    /// larger than the display (else macOS crops it), then sets its origin to the display's top-left
    /// (size BEFORE position — some apps clamp size to the current display before a cross-display
    /// move). Returns the window's ACHIEVED point size (read back from AX after the move) on success,
    /// or `nil` on ANY AX failure (window not found, fixed-size/unsupported, hung app → timeout) —
    /// the caller then captures the window where it is (still works, only without the VD's 2×
    /// backing). The achieved size is the authoritative capture/helloAck source of truth: a window
    /// resized down to fit the VD must NOT be captured/acked at its stale pre-move size, or the
    /// SCStream over-crops AND the client's input mapping desyncs (the post-resize point size feeds
    /// both `captureWidth/Height` and the SCStream size). NEVER crashes. Main-actor (AX is main-thread).
    @MainActor
    public static func moveWindowOntoDisplay(windowID: CGWindowID, pid: pid_t, displayID: CGDirectDisplayID) -> CGSize? {
        guard pid > 0, displayID != 0 else { return nil }
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.5)   // cap a hung target (mirrors resizeWindow)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else {
            log.error("move window \(windowID): no AX windows for pid \(pid) (Accessibility not granted?)")
            return nil
        }
        guard let axWindow = axWindows.first(where: { axWindowID($0) == windowID }) else {
            log.error("move window \(windowID): no AX window matched the CGWindowID for pid \(pid)")
            return nil
        }
        let bounds = CGDisplayBounds(displayID)               // global points; VD origin is the target
        let currentSize = axWindowSize(axWindow) ?? bounds.size
        let plan = WindowPlacementMath.placement(windowSize: currentSize, displayBounds: bounds)
        if plan.needsResize {                                 // shrink to fit BEFORE crossing displays
            var size = plan.size
            if let v = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, v)
            }
        }
        var origin = plan.origin
        guard let posValue = AXValueCreate(.cgPoint, &origin) else { return nil }
        let status = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posValue)
        if status != .success {
            log.error("move window \(windowID): AX position write failed (\(status.rawValue))")
            return nil
        }
        // Read back the ACHIEVED size — the window may have clamped the resize to its own min/max,
        // and we need the TRUE post-move point size for the capture/helloAck (not the requested one).
        let achieved = axWindowSize(axWindow) ?? plan.size
        log.notice("moved window \(windowID) onto display \(displayID) at (\(Int(origin.x)),\(Int(origin.y))) size \(Int(achieved.width))×\(Int(achieved.height))pt")
        return achieved
    }

    @MainActor
    private static func axWindowID(_ element: AXUIElement) -> CGWindowID? {
        var wid: CGWindowID = 0
        return _AXUIElementGetWindow(element, &wid) == .success ? wid : nil
    }

    @MainActor
    private static func axWindowSize(_ element: AXUIElement) -> CGSize? {
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let sizeVal = sizeRef else { return nil }
        var size = CGSize.zero
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        return size
    }
}
#endif
