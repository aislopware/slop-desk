#if os(macOS)
import AppKit
import ApplicationServices
import Foundation
import SlopDeskVideoProtocol

/// PURE display-pick math for host-window-resize (2026-06-30, unit-tested): given a window frame and
/// the active displays' bounds (all CG global POINTS, top-left origin), pick the display the window
/// sits on. Two callers: the resize MAX reported to the client (`displayMax` = display point size,
/// caps the "Resize…" popover) and the reposition-to-display-ORIGIN before an AX resize (else macOS
/// clamps the window at its old off-origin position instead of letting it grow to full screen).
public enum WindowDisplayResolver {
    /// The display whose bounds CONTAIN the window's centre; else the LARGEST display (window off every
    /// screen / straddling a gap → biggest); else `nil` (no displays). Ordered area comparison (not a
    /// bare `<` that mis-handles ties); centre not a corner, so a window mostly on one screen resolves
    /// to it despite a sliver overhanging a neighbour.
    public static func display(forWindowFrame frame: CGRect, displays: [CGRect]) -> CGRect? {
        guard !displays.isEmpty else { return nil }
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        if let hit = displays.first(where: { $0.contains(centre) }) { return hit }
        return displays.max(by: { ($0.width * $0.height) < ($1.width * $1.height) })
    }

    /// CG bounds of every active display (global POINTS, top-left origin). GUI-only (reads live display
    /// config) but cheap + non-hanging — unlike SCStream/VT it needs no window-server session. Returns
    /// `[]` on query failure so callers fall back to no-clamp / no-reposition.
    static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }
}

/// PURE geometry for DIALOG-EXPAND (host-side, unit-tested): capture region = the target window frame
/// ∪ any associated panel windows (a file-open / print / share dialog the OS attaches to the window),
/// so a dialog larger than the streamed window shows in full and clickable instead of cropped to the
/// window frame by the display-anchored crop.
///
/// Native Swift, single source of truth (reabsorbed from the Rust core's `capture_region`). STATELESS
/// / pure; `windowsInFront` is front-to-back, the slice strictly IN FRONT of the target. All `CGRect`
/// ops (standardized `width`/`height`, `intersection`, `union`, `CGRectNull`) delegate to native
/// `CGRect` — not reinvented here.
///
/// Association is by **owning process**: the open/save panel is attributed to the host app's own pid
/// (HW-verified 2026-06-12: a Chrome file dialog enumerates as `pid==Chrome, layer==0, name=="Open"`).
/// A panel qualifies when it is a DIFFERENT window, SAME pid, on an *associatable* layer
/// (``isAssociatableLayer``: `0` sheets/dialogs, `101` pop-up / context menus — HW-verified 2026-06-17
/// a VS Code gear menu is `pid==Code, layer==101`), overlapping the target by ≥ `minOverlapFraction`
/// of the smaller rect's area.
public enum CaptureRegionMath {
    /// Minimum overlap fraction (of the smaller rect's area) for a same-pid front window to count
    /// as an attached panel. Matches the Rust core's `DEFAULT_MIN_OVERLAP_FRACTION`.
    public static let defaultMinOverlapFraction: Double = 0.30

    /// Per-edge hysteresis threshold (points) for ``shouldRetarget``. Matches the Rust core's
    /// `DEFAULT_MIN_DELTA`.
    public static let defaultMinDelta: Double = 8

    /// Whether a CG window level counts as "attached" to the streamed window for capture-region
    /// expansion.
    ///
    /// `0` (`kCGNormalWindowLevel`) — file/save/print sheets & dialogs, attributed to the app's own
    /// pid. `101` (`kCGPopUpMenuWindowLevel`) — pop-up / context / dropdown menus that render as a
    /// SEPARATE same-pid window and can overhang the streamed window (HW-measured 2026-06-17: VS Code's
    /// gear "Manage" menu enumerates at layer `101`).
    ///
    /// DELIBERATELY excludes menu bar (`24`), Dock (`20`), tooltips / status windows (`25`): system
    /// chrome or transient — unioning them would drag the crop onto the top strip or churn the encoder
    /// open/closed on every hover.
    public static func isAssociatableLayer(_ layer: Int) -> Bool {
        layer == 0 || layer == 101
    }

    /// One on-screen window, as read from `CGWindowListCopyWindowInfo` (CG top-left points).
    public struct WindowSnapshot: Equatable, Sendable {
        public let windowID: UInt32
        public let ownerPID: Int32
        public let layer: Int
        public let frame: CGRect
        public init(windowID: UInt32, ownerPID: Int32, layer: Int, frame: CGRect) {
            self.windowID = windowID
            self.ownerPID = ownerPID
            self.layer = layer
            self.frame = frame
        }
    }

    /// Union of `targetFrame` with every qualifying associated panel in `windowsInFront` (front-to-back,
    /// the slice strictly IN FRONT of the target), clamped to `displayBounds`. Returns `targetFrame`
    /// (clamped) when nothing qualifies — no dialog, or the dialog fits inside the window.
    ///
    /// A window qualifies when it is a DIFFERENT window, owned by `targetPID`, on an associatable layer
    /// (``isAssociatableLayer`` — `0` sheets/dialogs, `101` pop-up menus), overlapping by ≥
    /// `minOverlapFraction` of the SMALLER rect's area (skips an incidental 1px edge touch). The whole
    /// panel frame joins the union even where it overhangs the window.
    public static func unionRegion(
        targetFrame: CGRect,
        targetWindowID: UInt32,
        targetPID: Int32,
        windowsInFront: [WindowSnapshot],
        displayBounds: CGRect,
        minOverlapFraction: Double = defaultMinOverlapFraction,
    ) -> CGRect {
        var union = targetFrame
        // CGRect.width / .height are standardized (always ≥ 0).
        // SEPARATE mul — no FMA (kept explicit even with no add chained here).
        let targetArea = targetFrame.width * targetFrame.height
        // `!(targetArea > 0.0)` (NOT `targetArea <= 0`): NaN-faithful skip-guard — zero/NaN area falls
        // back to the clamped frame. Reproduces the Rust core's exact predicate.
        if !(targetArea > 0.0) {
            return targetFrame.intersection(displayBounds)
        }
        for w in windowsInFront {
            guard w.windowID != targetWindowID, w.ownerPID == targetPID, isAssociatableLayer(w.layer)
            else { continue }
            // CGRectIsNull is disjoint (a real gap) — an edge-touch / zero-area overlap is NOT null.
            let inter = w.frame.intersection(targetFrame)
            guard !inter.isNull else { continue }
            // keep each product a SEPARATE mul — no FMA.
            let interArea = inter.width * inter.height
            let wArea = w.frame.width * w.frame.height
            // NaN-faithful ternary min `wArea < targetArea ? wArea : targetArea` (differs from
            // Swift.min on NaN — inputs finite here, kept exact).
            let smallerArea = wArea < targetArea ? wArea : targetArea
            // `>=` is inclusive (overlap exactly == fraction qualifies); negated guards stay `!(…)`
            // to mirror the Rust core's NaN-faithful skip semantics.
            if !(smallerArea > 0.0) || !(interArea / smallerArea >= minOverlapFraction) { continue }
            union = union.union(w.frame)
        }
        let clamped = union.intersection(displayBounds)
        return clamped.isNull ? targetFrame.intersection(displayBounds) : clamped
    }

    /// The OPAQUE content rectangles within the capture region: the target window frame then each
    /// qualifying panel/popup, every rect clamped to `displayBounds`.
    ///
    /// Same qualification rule as ``unionRegion``, but returns the INDIVIDUAL rects (not the bounding
    /// box) so the client can mask the empty area BETWEEN them (the black flank beside a narrow popup)
    /// to transparent — the union bbox can't express that hole. Front-to-back, target first. A rect
    /// whose clamp to the display is null is dropped; an empty result means nothing is on the display.
    public static func contentRects(
        targetFrame: CGRect,
        targetWindowID: UInt32,
        targetPID: Int32,
        windowsInFront: [WindowSnapshot],
        displayBounds: CGRect,
        minOverlapFraction: Double = defaultMinOverlapFraction,
    ) -> [CGRect] {
        var rects: [CGRect] = []
        let clampedTarget = targetFrame.intersection(displayBounds)
        if !clampedTarget.isNull { rects.append(clampedTarget) }
        // keep the two factors as a SEPARATE mul — no FMA.
        let targetArea = targetFrame.width * targetFrame.height
        // Mirror unionRegion's NaN skip-guard: with zero/NaN target area no popup qualifies (overlap
        // fraction undefined), so return just the target. EXACT `!(targetArea > 0.0)`.
        if !(targetArea > 0.0) { return rects }
        for w in windowsInFront {
            guard w.windowID != targetWindowID, w.ownerPID == targetPID, isAssociatableLayer(w.layer)
            else { continue }
            let inter = w.frame.intersection(targetFrame)
            guard !inter.isNull else { continue }
            // keep each product a SEPARATE mul — no FMA.
            let interArea = inter.width * inter.height
            let wArea = w.frame.width * w.frame.height
            // NaN-faithful ternary min (NOT Swift.min): `wArea < targetArea ? wArea : targetArea`.
            let smallerArea = wArea < targetArea ? wArea : targetArea
            if !(smallerArea > 0.0) || !(interArea / smallerArea >= minOverlapFraction) { continue }
            let clamped = w.frame.intersection(displayBounds)
            if !clamped.isNull { rects.append(clamped) }
        }
        return rects
    }

    /// Hysteresis gate for a region change: each change is an encoder rebuild + IDR, so retarget only
    /// when the desired region differs from the current on ANY edge by more than `minDelta` points.
    /// Strict `>`, so exactly `minDelta` does NOT retarget. Capture regions here are always
    /// positive-size, so `.minX`/`.minY` equal the standardized edges and `.width`/`.height` give the
    /// size deltas.
    public static func shouldRetarget(current: CGRect, desired: CGRect, minDelta: Double = defaultMinDelta) -> Bool {
        abs(desired.minX - current.minX) > minDelta
            || abs(desired.minY - current.minY) > minDelta
            || abs(desired.width - current.width) > minDelta
            || abs(desired.height - current.height) > minDelta
    }

    /// Whether a window-move geometry event should re-origin the input/cursor mapping to the PLAIN
    /// window frame. NO while a DIALOG-EXPAND capture region is active (`activeRegionGlobal != nil`):
    /// the mapping origin is then owned by the union region (window∪dialog, set in `applyCaptureRegion`)
    /// and the stream is still union-sized. Re-origining would desync input/cursor — a normalized client
    /// point in the dialog area (left/above the window) maps to a wrong absolute point (clicks land
    /// wrong) and the cursor reports not-visible over the dialog.
    public static func shouldReoriginToWindowOnGeometry(activeRegionGlobal: CGRect?) -> Bool {
        activeRegionGlobal == nil
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
    private var lastTitle: String?

    /// DIALOG-EXPAND (host-only): when set, every Nth drag poll enumerates windows IN FRONT of the
    /// tracked window, computes the capture region = window ∪ any attached same-pid panel (a file-open
    /// dialog the OS attributes to the app's pid), and fires this handler with the GLOBAL-point union
    /// whenever it changes beyond hysteresis. Off (nil) ⇒ zero extra work. The union math lives in
    /// ``CaptureRegionMath`` (pure native Swift, unit-tested); this only feeds it the
    /// `CGWindowListCopyWindowInfo` snapshot. queue-confined.
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

    /// Reads the window's current bounds via `CGWindowListCopyWindowInfo`
    /// (`kCGWindowBounds` is CG top-left points — the space the client maps from).
    /// Returns `nil` if the window is gone.
    public func currentBoundsCG() -> VideoRect? {
        guard let infoList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = infoList.first,
              let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else {
            return nil
        }
        return VideoRect(bounds)
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

    /// Enumerate windows IN FRONT of the tracked window, compute the capture-region union via
    /// ``CaptureRegionMath`` (native Swift), and fire the union handler when it changes beyond
    /// hysteresis. queue-confined (called from ``pollOnce``). Display = the one under centre.
    private func pollAssociatedUnion(targetFrameVR: VideoRect) {
        guard let handler = associatedUnionHandler else { return }
        let targetFrame = CGRect(
            x: targetFrameVR.origin.x,
            y: targetFrameVR.origin.y,
            width: targetFrameVR.size.width,
            height: targetFrameVR.size.height,
        )
        // Display under the window centre (the VD in the real deployment).
        let center = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
        var did = CGDirectDisplayID(0)
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(center, 1, &did, &count) == .success, count > 0 else { return }
        let displayBounds = CGDisplayBounds(did)
        guard let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return }
        // CGWindowList is FRONT-to-back: take the slice strictly in front of the tracked window.
        var inFront: [CaptureRegionMath.WindowSnapshot] = []
        for w in all {
            let wid = (w[kCGWindowNumber as String] as? UInt32) ?? 0
            if wid == windowID { break } // reached the tracked window — the rest are behind it
            guard let bd = w[kCGWindowBounds as String] as? [String: Any],
                  let r = CGRect(dictionaryRepresentation: bd as CFDictionary) else { continue }
            let ownerPID = Int32((w[kCGWindowOwnerPID as String] as? Int) ?? -1)
            let layer = (w[kCGWindowLayer as String] as? Int) ?? Int.min
            inFront.append(.init(windowID: wid, ownerPID: ownerPID, layer: layer, frame: r))
        }
        let union = CaptureRegionMath.unionRegion(
            targetFrame: targetFrame,
            targetWindowID: UInt32(windowID),
            targetPID: Int32(pid),
            windowsInFront: inFront,
            displayBounds: displayBounds,
        )
        let baseline = lastUnionEmitted.isNull ? targetFrame : lastUnionEmitted
        guard CaptureRegionMath.shouldRetarget(current: baseline, desired: union) else { return }
        lastUnionEmitted = union
        // The INDIVIDUAL opaque rects (window + popups) so the client can mask the black flank
        // between them — the union bbox alone can't express the hole beside a narrow popup.
        let contentRects = CaptureRegionMath.contentRects(
            targetFrame: targetFrame,
            targetWindowID: UInt32(windowID),
            targetPID: Int32(pid),
            windowsInFront: inFront,
            displayBounds: displayBounds,
        )
        handler(union, contentRects)
    }

    /// Emits a title change if the window's title differs from the last seen value.
    /// Driven by the AX `kAXTitleChangedNotification` in production.
    @preconcurrency
    @MainActor
    public func checkTitle() {
        let appEl = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return }
        // Match the EXACT window by CGWindowID via ``axWindowID(of:)`` — robust when windows share a
        // frame (panes stacked at one origin on the shared VD); the old frame-equality heuristic bound
        // the WRONG window there.
        for axWindow in axWindows where axWindowID(of: axWindow) == windowID {
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
               let title = titleRef as? String, title != lastTitle
            {
                lastTitle = title
                geometryHandler(.title(title))
            }
            return
        }
    }

    /// PATH A in-session resize: resize the REAL tracked window to `desiredPoints` via the
    /// Accessibility API and return the size it ACTUALLY adopted (points). The window may clamp to its
    /// own min/max, so the ACHIEVED size (read back from `kAXSizeAttribute`), not the requested one, is
    /// the source of truth for the SCStream/encoder reconfigure + `resizeAck`.
    ///
    /// Returns `nil` (resize ABORTED — caller keeps the old encoder, sends no ack) when the app/window
    /// can't be looked up, the window rejects a size write (`kAXErrorAttributeUnsupported` on a
    /// fixed-size/sheet window), or the AX call can't complete (`kAXErrorCannotComplete` on a
    /// hung/modal app). NEVER crashes.
    ///
    /// ⚠️ **GUI-ONLY + TCC:** needs the Accessibility grant (as watcher/injector do).
    /// `AXUIElementSetMessagingTimeout` caps a hung target (mirrors ``InputInjector/raiseTargetWindow()``)
    /// so a beachballing app fails fast instead of stalling the resize.
    @preconcurrency
    @MainActor
    public func resizeWindow(toPoints desiredPoints: VideoSize) -> VideoSize? {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.25)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return nil }
        // Match the EXACT window by CGWindowID via ``axWindowID(of:)`` — robust when windows share a
        // frame; the prior frame-equality lookup could resize the WRONG window when panes stack at one
        // origin on the shared VD.
        for axWindow in axWindows where axWindowID(of: axWindow) == windowID {
            // RESIZE-TO-ORIGIN (2026-06-30): re-anchor at the display's TOP-LEFT BEFORE the size write.
            // macOS clamps an AX size-set to keep the window on-screen from its CURRENT position, so a
            // window parked mid-screen can't grow to the full display; moving it to the display origin
            // first lets the requested size take. Best-effort — a window that refuses the position write
            // (kAXErrorAttributeUnsupported) still gets the size write below.
            if let live = axWindowFrame(axWindow),
               let display = WindowDisplayResolver.display(
                   forWindowFrame: CGRect(
                       x: live.origin.x, y: live.origin.y, width: live.size.width, height: live.size.height,
                   ),
                   displays: WindowDisplayResolver.activeDisplayBounds(),
               )
            {
                var origin = display.origin
                if let posValue = AXValueCreate(.cgPoint, &origin) {
                    _ = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posValue)
                }
            }
            var size = CGSize(width: max(1, desiredPoints.width), height: max(1, desiredPoints.height))
            guard let value = AXValueCreate(.cgSize, &size) else { return nil }
            // WRITE the new size. Tolerate (never crash on) unsupported/cannot-complete — a fixed-size
            // window returns kAXErrorAttributeUnsupported, a hung app times out to
            // kAXErrorCannotComplete. Either ⇒ abort (return nil).
            let setStatus = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, value)
            guard setStatus == .success else { return nil }
            // READ BACK the achieved size — the window may have clamped to its own min/max; the
            // achieved (not requested) size is the source of truth for the reconfigure.
            return axWindowFrame(axWindow)?.size ?? desiredPoints
        }
        return nil
    }

    @MainActor
    private func axWindowFrame(_ element: AXUIElement) -> VideoRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success
        else {
            return nil
        }
        // `as?` to a CF type (AXValue) always succeeds (compile error); the AX copies above succeeded,
        // so these are non-nil AXValues. Force cast traps only on an OS-contract break.
        // swiftlint:disable:next force_cast
        let posValue = posRef as! AXValue
        // swiftlint:disable:next force_cast
        let sizeValue = sizeRef as! AXValue
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue, .cgPoint, &point)
        AXValueGetValue(sizeValue, .cgSize, &size)
        return VideoRect(x: Double(point.x), y: Double(point.y), width: Double(size.width), height: Double(size.height))
    }
}
#endif
