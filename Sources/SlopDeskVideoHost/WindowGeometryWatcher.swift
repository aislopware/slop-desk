#if os(macOS)
import CoreGraphics
import CSlopDeskFFI
import SlopDeskVideoProtocol

/// The display list, from `rust/slopdesk-apple-cgdisplay` through the two `slopdesk_cgdisplay_*`
/// doors. Three call sites ran the same two-call enumeration by hand before this — the resize
/// display-pick, the feed's display ordinals, and the parked-window restore's "does this intersect
/// any display at all" — and two of the three sized their buffer from a first counting call while
/// the third hard-coded sixteen.
public enum HostDisplays {
    /// One display: where it sits, and the `CGDirectDisplayID` the capture path names it by.
    public struct Display: Equatable, Sendable {
        public let id: CGDirectDisplayID
        public let bounds: CGRect
    }

    /// Every display. `online` includes mirrored and sleeping ones; the default (active) is the
    /// drawable ones. `[]` on query failure, which every caller reads as "do not clamp and do not
    /// reposition".
    public static func displays(online: Bool = false) -> [Display] {
        let needed = slopdesk_cgdisplay_list(online, nil, 0)
        guard needed > 0 else { return [] }
        var records = [SlopDeskCGDisplay](
            repeating: SlopDeskCGDisplay(bounds: SlopDeskVideoRect(), display_id: 0), count: needed,
        )
        let written = records.withUnsafeMutableBufferPointer {
            slopdesk_cgdisplay_list(online, $0.baseAddress, $0.count)
        }
        guard written == needed else { return [] }
        return records.map { Display(id: $0.display_id, bounds: rect($0.bounds)) }
    }

    /// Every display's bounds, in CG global points.
    public static func bounds(online: Bool) -> [CGRect] {
        displays(online: online).map(\.bounds)
    }

    /// The display under `point`, or `nil` when the point is off every display.
    public static func display(under point: CGPoint) -> Display? {
        var record = SlopDeskCGDisplay(bounds: SlopDeskVideoRect(), display_id: 0)
        guard slopdesk_cgdisplay_under(point.x, point.y, &record) else { return nil }
        return Display(id: record.display_id, bounds: rect(record.bounds))
    }

    /// One display's bounds, by id — for callers that already hold one from `SCShareableContent`
    /// or from the virtual display they created. A zero rect means the id names no display.
    public static func bounds(of displayID: CGDirectDisplayID) -> CGRect {
        rect(slopdesk_cgdisplay_bounds_of(displayID))
    }

    /// The door's rect record as a `CGRect`. Shared so the call sites that take one back do not
    /// each write the same four-field copy.
    public static func rect(_ record: SlopDeskVideoRect) -> CGRect {
        CGRect(x: record.x, y: record.y, width: record.width, height: record.height)
    }

    /// A `CGRect` as the door's rect record — the other direction, for the same reason.
    public static func record(_ rect: CGRect) -> SlopDeskVideoRect {
        SlopDeskVideoRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }

    /// The display a window sits on: the one holding its centre, else the largest, else `nil`.
    ///
    /// The pick is `slopdesk_video::window_list`, through ``slopdesk_window_display_for_frame``.
    /// Two callers, both about the resize ceiling — the `displayMax` the client caps its "Resize…"
    /// popover with, and the reposition-to-display-ORIGIN before an AX resize, without which macOS
    /// clamps the window at its old off-origin position instead of letting it grow to full screen.
    public static func display(forWindowFrame frame: CGRect, in displays: [CGRect]) -> CGRect? {
        var out = SlopDeskVideoRect()
        let found = displays.map(record).withUnsafeBufferPointer {
            slopdesk_window_display_for_frame(record(frame), $0.baseAddress, $0.count, &out)
        }
        return found ? rect(out) : nil
    }
}

/// Watches a tracked window's geometry (move / resize / title) and emits ``WindowGeometryMessage`` for
/// the geometry channel (doc 17 §3.8, doc 18 §B).
///
/// ⚠️ **GUI-ONLY:** the Accessibility API (`AXObserver`) and `CGWindowListCopyWindowInfo` need an
/// AppKit run loop + Accessibility TCC. COMPILED + reviewed; not driven from tests.
///
/// Two complementary sources (doc 18 §B):
/// - **AX `kAXWindowMovedNotification` / `kAXWindowResizedNotification`** fire at the END of a
///   move/resize — authoritative final position.
/// - **Polling `CGWindowListCopyWindowInfo` during a drag** keeps the client in sync per-frame while
///   AX is silent mid-drag.
///
/// The TCC need is documented in ``InputInjector`` (Accessibility).
public final class WindowGeometryWatcher: @unchecked Sendable {
    /// Poll cadence during an active drag (per video frame ≈ 30 Hz; doc 18 §B).
    public static let dragPollHz: Double = 30

    public typealias GeometryHandler = @Sendable (WindowGeometryMessage) -> Void

    private let windowID: CGWindowID
    private let pid: pid_t
    private let geometryHandler: GeometryHandler

    private var pollTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "slopdesk.video.geometry", qos: .userInteractive)
    private var lastBounds: VideoRect?
    /// DIALOG-EXPAND (host-only): when set, every Nth drag poll enumerates windows IN FRONT of the
    /// tracked window, computes the capture region = window ∪ any attached same-pid panel (a file-open
    /// dialog the OS attributes to the app's pid), and fires this handler with the GLOBAL-point union
    /// whenever it changes beyond hysteresis. Off (nil) ⇒ zero extra work. The union math lives in
    /// `slopdesk_video::capture_region` and is golden-pinned; this only feeds it the window records
    /// `slopdesk_cgwindow_in_front_of` answered. queue-confined.
    /// `(unionGlobal, contentRectsGlobal)` — the bounding union AND the individual opaque content rects
    /// (window + popups, global points) the client masks the black flank with.
    public typealias UnionHandler = @Sendable (CGRect, [CGRect]) -> Void
    private var associatedUnionHandler: UnionHandler?
    private var lastUnionEmitted: CGRect = .null
    private var unionPollCounter = 0
    /// Enumerate the union every `unionPollDivider`-th drag poll (~6 Hz at 30 Hz drag cadence) — a
    /// dialog open/close is a discrete event, so 6 Hz is ample and cheap.
    private static let unionPollDivider = 5

    public init(windowID: CGWindowID, pid: pid_t, geometryHandler: @escaping GeometryHandler) {
        self.windowID = windowID
        self.pid = pid
        self.geometryHandler = geometryHandler
    }

    /// Arm the DIALOG-EXPAND union poll. Call BEFORE ``startDragPolling`` (the handler is read on the
    /// poll queue). Passing nil disarms.
    public func setAssociatedUnionHandler(_ handler: UnionHandler?) {
        associatedUnionHandler = handler
    }

    /// Reads the window's current bounds through ``slopdesk_cgwindow_bounds``
    /// (CG top-left points — the space the client maps from). `nil` if the window is gone.
    public func currentBoundsCG() -> VideoRect? {
        var record = SlopDeskVideoRect()
        guard slopdesk_cgwindow_bounds(windowID, 0, &record) else { return nil }
        return VideoRect(HostDisplays.rect(record))
    }

    /// Every on-screen window strictly IN FRONT of `windowID`, front-to-back, through
    /// ``slopdesk_cgwindow_in_front_of``. The door reports the count it NEEDS, so an under-lent
    /// buffer costs one retry rather than a truncated occluder set — and a truncated one would
    /// shrink the capture region, cropping the very dialog the union exists to reveal.
    private static func windowsInFront(of windowID: CGWindowID) -> [SlopDeskWindowRecord] {
        let needed = slopdesk_cgwindow_in_front_of(windowID, nil, 0)
        guard needed > 0 else { return [] }
        var records = [SlopDeskWindowRecord](
            repeating: SlopDeskWindowRecord(bounds: SlopDeskVideoRect(), window_id: 0, owner_pid: 0, layer: 0),
            count: needed,
        )
        let written = records.withUnsafeMutableBufferPointer {
            slopdesk_cgwindow_in_front_of(windowID, $0.baseAddress, $0.count)
        }
        return written == needed ? records : []
    }

    /// Starts polling for geometry changes during drags. The AX-notification path is
    /// registered separately by the host app's run loop; this poller is the
    /// per-frame fallback (doc 18 §B).
    public func startDragPolling() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Self.dragPollHz)
        timer.setEventHandler { [weak self] in self?.pollOnce() }
        pollTimer = timer
        timer.resume()
    }

    public func stop() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    /// Emits a geometry message if the window's bounds changed since the last poll.
    /// Coalesces into a single `.bounds` message when both origin and size move.
    public func pollOnce() {
        guard let bounds = currentBoundsCG() else { return }
        defer { lastBounds = bounds }
        guard let previous = lastBounds else {
            geometryHandler(.bounds(bounds))
            return
        }
        let moved = bounds.origin != previous.origin
        let resized = bounds.size != previous.size
        switch (moved, resized) {
        case (true, true): geometryHandler(.bounds(bounds))
        case (true, false): geometryHandler(.move(bounds.origin))
        case (false, true): geometryHandler(.resize(bounds.size))
        case (false, false): break
        }
        // DIALOG-EXPAND: throttled union enumeration (only when armed).
        if associatedUnionHandler != nil {
            unionPollCounter += 1
            if unionPollCounter.isMultiple(of: Self.unionPollDivider) { pollAssociatedUnion(targetFrameVR: bounds) }
        }
    }

    /// Enumerate windows IN FRONT of the tracked window, ask `slopdesk_video::capture_region` what
    /// the region should be, and fire the union handler when it changes beyond hysteresis.
    /// queue-confined (called from ``pollOnce``). Display = the one under centre.
    ///
    /// The occluder records go BACK IN unchanged — the door that answers them and the doors that
    /// decide over them share one `SlopDeskWindowRecord` layout, so nothing is re-marshalled here.
    private func pollAssociatedUnion(targetFrameVR: VideoRect) {
        guard let handler = associatedUnionHandler else { return }
        let targetFrame = HostDisplays.record(
            CGRect(
                x: targetFrameVR.origin.x,
                y: targetFrameVR.origin.y,
                width: targetFrameVR.size.width,
                height: targetFrameVR.size.height,
            ),
        )
        // Display under the window centre (the VD in the real deployment).
        let center = CGPoint(x: targetFrame.x + targetFrame.width / 2, y: targetFrame.y + targetFrame.height / 2)
        guard let displayCG = HostDisplays.display(under: center)?.bounds else { return }
        let display = HostDisplays.record(displayCG)
        let inFront = Self.windowsInFront(of: windowID)
        let wid = UInt32(windowID)
        let owner = Int32(pid)
        let union = inFront.withUnsafeBufferPointer {
            slopdesk_capture_union_region(targetFrame, wid, owner, $0.baseAddress, $0.count, display)
        }
        let baseline = lastUnionEmitted.isNull ? targetFrame : HostDisplays.record(lastUnionEmitted)
        guard slopdesk_capture_should_retarget(baseline, union) else { return }
        lastUnionEmitted = HostDisplays.rect(union)
        // The INDIVIDUAL opaque rects (window + popups) so the client can mask the black flank
        // between them — the union bbox alone can't express the hole beside a narrow popup.
        handler(lastUnionEmitted, Self.contentRects(targetFrame, wid, owner, inFront, display))
    }

    /// The opaque pieces inside the region, through ``slopdesk_capture_content_rects``. The door
    /// reports the count it NEEDS, so the counting call lends nothing and the second one lends
    /// exactly that — a truncated set would leave part of the stream masked to transparent.
    private static func contentRects(
        _ target: SlopDeskVideoRect,
        _ windowID: UInt32,
        _ pid: Int32,
        _ inFront: [SlopDeskWindowRecord],
        _ display: SlopDeskVideoRect,
    ) -> [CGRect] {
        inFront.withUnsafeBufferPointer { windows in
            let needed = slopdesk_capture_content_rects(
                target, windowID, pid, windows.baseAddress, windows.count, display, nil, 0,
            )
            guard needed > 0 else { return [] }
            var rects = [SlopDeskVideoRect](repeating: SlopDeskVideoRect(), count: needed)
            let written = rects.withUnsafeMutableBufferPointer {
                slopdesk_capture_content_rects(
                    target, windowID, pid, windows.baseAddress, windows.count, display,
                    $0.baseAddress, $0.count,
                )
            }
            return written == needed ? rects.map(HostDisplays.rect) : []
        }
    }

    /// PATH A in-session resize: resize the REAL tracked window to `desiredPoints` and return the
    /// size it ACTUALLY adopted (points). The window may clamp to its own min/max, so the ACHIEVED
    /// size, not the requested one, is the source of truth for the SCStream/encoder reconfigure +
    /// `resizeAck`.
    ///
    /// Returns `nil` (resize ABORTED — caller keeps the old encoder, sends no ack) when the
    /// app/window can't be looked up, the window rejects a size write (a fixed-size/sheet window),
    /// or the AX call can't complete (a hung/modal app). NEVER crashes.
    ///
    /// The display list is lent so the door can re-anchor the window at its display's TOP-LEFT
    /// before the size write: macOS clamps an AX size-set to keep the window on screen from its
    /// CURRENT position, so a window parked mid-screen can't grow to the full display until it has
    /// been moved to the origin first.
    ///
    /// ⚠️ **GUI-ONLY + TCC:** needs the Accessibility grant (as watcher/injector do).
    public func resizeWindow(toPoints desiredPoints: VideoSize) -> VideoSize? {
        var width = 0.0
        var height = 0.0
        let resized = HostDisplays.bounds(online: false).map(HostDisplays.record).withUnsafeBufferPointer {
            slopdesk_ax_resize_window(
                windowID, pid, desiredPoints.width, desiredPoints.height,
                $0.baseAddress, $0.count, &width, &height,
            )
        }
        return resized ? VideoSize(width: width, height: height) : nil
    }
}
#endif
