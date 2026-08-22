#if os(macOS)
import CoreGraphics
import CSlopDeskFFI
import Foundation
import OSLog

/// The Swift face of `rust/slopdesk-video`'s `window_placement` (feature #1): decide where and at
/// what size to move a window fully onto a display. The AX side effects live in ``WindowPlacement``.
///
/// What stays HERE is what CoreGraphics defines, and only that:
///   * `CGRect.width`/`.height` STANDARDIZE — they return `|size|` (always ≥ 0) — so the display
///     extents are read through them and cross already standardized.
///   * `CGSize.width`/`.height` are RAW stored fields (NOT standardized), so the window operand
///     (and the `size` arg to ``fits``) crosses verbatim, never abs'd. The clamp is therefore
///     asymmetric, and the far side is told which side it is holding rather than deciding.
///   * `CGRect.origin` is the RAW stored origin (NOT standardized), so the origin crosses verbatim —
///     including negative coordinates from a display placed left of / above the main display.
///
/// What moved is the arithmetic: the ordered comparison that keeps a NaN where a NaN-ignoring
/// minimum would swallow it, and the ½-pt tolerance predicate. `golden/golden_vectors.json` pins
/// both as bit patterns, replayed by `WindowPlacementGoldenVectorTests` here and by
/// `every_pinned_placement_puts_the_window_where_swift_put_it` on the far side.
public enum WindowPlacementMath {
    /// Clamp `windowSize` to `displayBounds` (resize DOWN only if larger — never enlarge) and place
    /// at the display's top-left origin. macOS crops a window that overhangs a display, so an
    /// oversized window must be shrunk before the move.
    public static func placement(windowSize: CGSize, displayBounds: CGRect)
        -> (origin: CGPoint, size: CGSize, needsResize: Bool)
    {
        let plan = slopdesk_window_placement(
            windowSize.width, windowSize.height, // RAW CGSize fields
            displayBounds.origin.x, displayBounds.origin.y, // RAW CGRect origin
            displayBounds.width, displayBounds.height, // CG-standardized (abs)
        )
        return (
            CGPoint(x: plan.origin_x, y: plan.origin_y),
            CGSize(width: plan.width, height: plan.height),
            plan.needs_resize,
        )
    }

    /// True when `size` fits inside `bounds` (within a ½-pt tolerance). Used after the AX move to
    /// confirm the window actually shrank to fit the VD — an app that refuses/clamps the resize
    /// leaves an oversized window, which must NOT be reported as a successful 2× move (the capture
    /// crop would exceed the framebuffer and the client's input mapping would desync).
    /// `bounds.width`/`.height` are CG-standardized (abs); `size` is raw.
    public static func fits(_ size: CGSize, within bounds: CGRect) -> Bool {
        slopdesk_window_fits(size.width, size.height, bounds.width, bounds.height)
    }
}

/// Moves a target window onto a display via Accessibility (feature #1 — put the remoted window on
/// the HiDPI virtual display so it renders at real 2× backing).
///
/// Every line of the sequence — resolve the window, read its frame, plan, shrink, move, read back,
/// roll back on refusal — is `slopdesk-ffi`'s `ax` module now, because the ORDER is load-bearing and
/// one of the steps was already a golden-pinned Rust rule. What is left here is the call and the
/// logging, and the logging is the only reason these are not one-liners.
///
/// Restoration: ``moveWindowOntoDisplay`` reports the window's PRE-move global frame in its result so
/// the caller (the daemon's ``WindowParkingManager``) can put the window back exactly where it was
/// when the pane closes / the daemon shuts down / the VD is torn down — otherwise the user's real
/// window is left shrunk + stranded on the (physically invisible) VD.
public enum WindowPlacement {
    private static let log = Logger(subsystem: "slopdesk.video.host", category: "WindowPlacement")

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

    /// Move the window `windowID` (owned by `pid`) fully onto `displayID`. `nil` on ANY failure —
    /// window not found, original frame unreadable, AX write failed, hung app, OR the app refused
    /// the shrink so the window still overhangs the VD; on the last two the door already rolled the
    /// window back before answering, so the caller's 1× fallback captures it cleanly in place.
    ///
    /// ⚠️ **GUI-ONLY + TCC:** needs the Accessibility grant (as watcher/injector do).
    @discardableResult
    public static func moveWindowOntoDisplay(
        windowID: CGWindowID,
        pid: pid_t,
        displayID: CGDirectDisplayID,
    ) -> MoveResult? {
        var parked = SlopDeskAxPark()
        guard slopdesk_ax_park_window(windowID, pid, displayID, &parked) else {
            log.error("move window \(windowID): AX park refused for pid \(pid) — staying 1× in place")
            return nil
        }
        let achieved = CGSize(width: parked.achieved_width, height: parked.achieved_height)
        log
            .notice(
                "moved window \(windowID) onto display \(displayID) size \(Int(achieved.width))×\(Int(achieved.height))pt",
            )
        return MoveResult(achievedSize: achieved, originalFrame: HostDisplays.rect(parked.original))
    }

    /// Put the window `windowID` (owned by `pid`) BACK to a previously-saved global frame. Inverse of
    /// ``moveWindowOntoDisplay``. Call before the VD is destroyed so the original display still
    /// exists.
    @discardableResult
    public static func restoreWindow(windowID: CGWindowID, pid: pid_t, toFrame frame: CGRect) -> Bool {
        guard slopdesk_ax_restore_window(windowID, pid, HostDisplays.record(frame)) else {
            log.error("restore window \(windowID): AX window not found (pid \(pid))")
            return false
        }
        log
            .notice(
                "restored window \(windowID) to (\(Int(frame.origin.x)),\(Int(frame.origin.y))) size \(Int(frame.width))×\(Int(frame.height))pt",
            )
        return true
    }

    /// Un-minimize the window `windowID` (owned by `pid`) so the WindowServer paints it again — a
    /// minimized window is never rendered, so SCK capture of one streams nothing (the mint-time
    /// rescue, ``OffScreenWindowMintRescue``, calls this before resolving the window for capture).
    /// Read-then-write: a window that is not minimized is left untouched (`.notMinimized`).
    public static func deminiaturizeWindow(windowID: CGWindowID, pid: pid_t) -> DeminiaturizeOutcome {
        switch slopdesk_ax_deminiaturize(windowID, pid) {
        case Int32(SLOPDESK_AX_DEMINIATURIZE_RESTORING):
            log.notice("deminiaturized window \(windowID) (pid \(pid)) for capture")
            return .restoring
        case Int32(SLOPDESK_AX_DEMINIATURIZE_NOT_MINIMIZED):
            return .notMinimized
        default:
            log.error("deminiaturize window \(windowID): AX window not found or refused (pid \(pid))")
            return .failed
        }
    }
}
#endif
