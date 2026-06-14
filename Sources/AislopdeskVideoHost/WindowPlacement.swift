#if os(macOS)
import ApplicationServices
import CoreGraphics
import Foundation
import OSLog

/// PURE placement arithmetic (feature #1): decide where/how to move a window fully onto a display.
/// Headlessly unit-testable; the AX side effects live in ``WindowPlacement``.
public enum WindowPlacementMath {
    /// Clamp `windowSize` to `displayBounds` (resize DOWN only if larger — never enlarge) and place
    /// at the display's top-left origin. macOS crops a window that overhangs a display, so an
    /// oversized window must be shrunk before the move.
    public static func placement(windowSize: CGSize, displayBounds: CGRect)
        -> (origin: CGPoint, size: CGSize, needsResize: Bool)
    {
        let w = min(windowSize.width, displayBounds.width)
        let h = min(windowSize.height, displayBounds.height)
        // ½-pt tolerance so floating-point equality doesn't trigger a no-op resize.
        let needsResize = (w + 0.5 < windowSize.width) || (h + 0.5 < windowSize.height)
        return (displayBounds.origin, CGSize(width: w, height: h), needsResize)
    }

    /// True when `size` fits inside `bounds` (within a ½-pt tolerance). Used after the AX move to
    /// confirm the window actually shrank to fit the VD — an app that refuses/clamps the resize
    /// leaves an oversized window, which must NOT be reported as a successful 2× move (the capture
    /// crop would exceed the framebuffer and the client's input mapping would desync).
    public static func fits(_ size: CGSize, within bounds: CGRect) -> Bool {
        size.width <= bounds.width + 0.5 && size.height <= bounds.height + 0.5
    }
}

/// Moves a target window onto a display via Accessibility (feature #1 — put the remoted window on
/// the HiDPI virtual display so it renders at real 2× backing). Best-effort + crash-free.
///
/// Restoration: ``moveWindowOntoDisplay`` reports the window's PRE-move global frame in its result so
/// the caller (the daemon's ``WindowParkingManager``) can put the window back exactly where it was
/// when the pane closes / the daemon shuts down / the VD is torn down — otherwise the user's real
/// window is left shrunk + stranded on the (physically invisible) VD.
public enum WindowPlacement {
    private static let log = Logger(subsystem: "aislopdesk.video.host", category: "WindowPlacement")

    /// Per-message AX timeout: cap a hung target so a beachballing app fails fast instead of
    /// stalling the (main-thread) placement path. Matches ``WindowGeometryWatcher/resizeWindow``.
    static let axMessagingTimeout: Float = 0.25

    /// Outcome of a successful park: the window's ACHIEVED point size on the VD (read back from AX —
    /// the window may have clamped the requested shrink) and its PRE-move global frame (for restore).
    public struct MoveResult: Equatable, Sendable {
        public let achievedSize: CGSize
        public let originalFrame: CGRect
        public init(achievedSize: CGSize, originalFrame: CGRect) {
            self.achievedSize = achievedSize
            self.originalFrame = originalFrame
        }
    }

    /// Move the window `windowID` (owned by `pid`) fully onto `displayID`. Resizes it DOWN first if
    /// larger than the display (else macOS crops it), then sets its origin to the display's top-left
    /// (size BEFORE position — some apps clamp size to the current display before a cross-display
    /// move). Returns a ``MoveResult`` (achieved point size + pre-move global frame) on success, or
    /// `nil` on ANY failure — window not found, original frame unreadable, AX write failed, hung app
    /// (timeout), OR the app refused the shrink so the window still overhangs the VD. On the
    /// overhang-refusal path the window is rolled BACK to its original frame before returning nil, so
    /// the caller's 1× fallback captures it cleanly in place rather than over-cropping a half-moved
    /// window. NEVER crashes. Main-actor (AX is main-thread).
    @preconcurrency
    @MainActor
    public static func moveWindowOntoDisplay(
        windowID: CGWindowID,
        pid: pid_t,
        displayID: CGDirectDisplayID,
    ) -> MoveResult? {
        guard pid > 0, displayID != 0 else { return nil }
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, axMessagingTimeout)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement]
        else {
            log.error("move window \(windowID): no AX windows for pid \(pid) (Accessibility not granted?)")
            return nil
        }
        // Match the EXACT window by CGWindowID (robust even when several windows share a frame),
        // not by frame-equality.
        guard let axWindow = axWindows.first(where: { axWindowID(of: $0) == windowID }) else {
            log.error("move window \(windowID): no AX window matched the CGWindowID for pid \(pid)")
            return nil
        }
        // Read the FULL pre-move global frame (position + size). Both must be readable: we need the
        // size to plan the shrink and the origin to restore the window later. If either is
        // unreadable, do NOT touch the window — return nil so the caller falls back to 1× in place
        // (assuming a size here would risk an over-cropped capture and an un-restorable window).
        guard let originalFrame = axWindowFrame(axWindow) else {
            log.error("move window \(windowID): pre-move frame unreadable — staying 1× in place")
            return nil
        }

        let bounds = CGDisplayBounds(displayID) // global points; VD origin is the target
        let plan = WindowPlacementMath.placement(windowSize: originalFrame.size, displayBounds: bounds)
        if plan.needsResize { // shrink to fit BEFORE crossing displays
            setSize(axWindow, plan.size)
        }
        guard setOrigin(axWindow, plan.origin) else {
            log.error("move window \(windowID): AX position write failed — rolling back")
            restore(axWindow, to: originalFrame) // undo any partial resize
            return nil
        }
        // Read back the ACHIEVED size — the window may have clamped the resize to its own min/max.
        let achieved = axWindowFrame(axWindow)?.size ?? plan.size
        // If the app refused/clamped the shrink the window still overhangs the VD → a 2× move here
        // would over-crop the capture and desync input mapping. Roll back and fall back to 1×.
        guard WindowPlacementMath.fits(achieved, within: bounds) else {
            log
                .error(
                    "move window \(windowID): achieved \(Int(achieved.width))×\(Int(achieved.height))pt overhangs VD — rolling back to 1×",
                )
            restore(axWindow, to: originalFrame)
            return nil
        }
        log
            .notice(
                "moved window \(windowID) onto display \(displayID) at (\(Int(plan.origin.x)),\(Int(plan.origin.y))) size \(Int(achieved.width))×\(Int(achieved.height))pt",
            )
        return MoveResult(achievedSize: achieved, originalFrame: originalFrame)
    }

    /// Put the window `windowID` (owned by `pid`) BACK to a previously-saved global frame. Inverse of
    /// ``moveWindowOntoDisplay``: sets the ORIGIN first (cross back to the roomy original display),
    /// then the SIZE (grow to the original size where there is room). Best-effort + crash-free; logs
    /// and returns `false` on any AX failure. Call before the VD is destroyed so the original display
    /// still exists. Main-actor.
    @preconcurrency
    @MainActor
    @discardableResult
    public static func restoreWindow(windowID: CGWindowID, pid: pid_t, toFrame frame: CGRect) -> Bool {
        guard pid > 0 else { return false }
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, axMessagingTimeout)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement],
              let axWindow = axWindows.first(where: { axWindowID(of: $0) == windowID })
        else {
            log.error("restore window \(windowID): AX window not found (pid \(pid))")
            return false
        }
        restore(axWindow, to: frame)
        log
            .notice(
                "restored window \(windowID) to (\(Int(frame.origin.x)),\(Int(frame.origin.y))) size \(Int(frame.width))×\(Int(frame.height))pt",
            )
        return true
    }

    /// ORIGIN-then-SIZE restore of an already-resolved AX window to `frame` (best-effort, no return —
    /// rollback/restore is opportunistic).
    @MainActor
    private static func restore(_ element: AXUIElement, to frame: CGRect) {
        _ = setOrigin(element, frame.origin)
        setSize(element, frame.size)
    }

    @MainActor
    @discardableResult
    private static func setSize(_ element: AXUIElement, _ size: CGSize) -> Bool {
        var s = size
        guard let v = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, v) == .success
    }

    @MainActor
    @discardableResult
    private static func setOrigin(_ element: AXUIElement, _ origin: CGPoint) -> Bool {
        var o = origin
        guard let v = AXValueCreate(.cgPoint, &o) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, v) == .success
    }

    /// The AX window's global frame (position + size in top-left points), or `nil` if either read
    /// fails.
    @MainActor
    private static func axWindowFrame(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef, let sizeVal = sizeRef else { return nil }
        // `as?` to a CoreFoundation type (AXValue) always succeeds (compile error); the copies above
        // succeeded so these are non-nil AXValues. Force cast traps on an OS-contract break.
        // swiftlint:disable force_cast
        let posValue = posVal as! AXValue
        let sizeValue = sizeVal as! AXValue
        // swiftlint:enable force_cast
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue, .cgPoint, &point)
        AXValueGetValue(sizeValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }
}
#endif
