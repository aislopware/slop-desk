#if os(macOS)
import Foundation
import AppKit
import ApplicationServices
import AislopdeskVideoProtocol

/// Watches a tracked window's geometry (move / resize / title) and emits
/// ``WindowGeometryMessage`` for the geometry channel (doc 17 §3.8, doc 18 §B).
///
/// ⚠️ **GUI-ONLY:** uses the Accessibility API (`AXObserver`) and
/// `CGWindowListCopyWindowInfo` which need an AppKit run loop + Accessibility TCC.
/// COMPILED + reviewed; not driven from tests.
///
/// Two complementary sources (doc 18 §B):
/// - **AX `kAXWindowMovedNotification` / `kAXWindowResizedNotification`** fire at the
///   END of a move/resize — authoritative final position.
/// - **Polling `CGWindowListCopyWindowInfo` during a drag** keeps the client window
///   in sync per-frame while AX is silent mid-drag (AX only fires at the end).
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
    private let queue = DispatchQueue(label: "aislopdesk.video.geometry", qos: .userInteractive)
    private var lastBounds: VideoRect?
    private var lastTitle: String?

    /// DIALOG-EXPAND (host-only): when set, every Nth drag poll enumerates the on-screen windows IN
    /// FRONT of the tracked window, computes the capture region = window ∪ any attached same-pid
    /// panel (a file-open dialog the OS attributes to the app's pid), and fires this handler with the
    /// GLOBAL-point union whenever it changes beyond hysteresis. Off (nil) ⇒ zero extra work. The
    /// union math is in ``CaptureRegionMath`` (pure + unit-tested); this method only feeds it the
    /// `CGWindowListCopyWindowInfo` snapshot. queue-confined.
    public typealias UnionHandler = @Sendable (CGRect) -> Void
    private var associatedUnionHandler: UnionHandler?
    private var lastUnionEmitted: CGRect = .null
    private var unionPollCounter = 0
    /// Enumerate the union every `unionPollDivider`-th drag poll (~6 Hz at the 30 Hz drag cadence) —
    /// a dialog open/close is a discrete event, not a per-frame one, so 6 Hz is ample and cheap.
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
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
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
        self.pollTimer = timer
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
            if unionPollCounter % Self.unionPollDivider == 0 { pollAssociatedUnion(targetFrameVR: bounds) }
        }
    }

    /// Enumerate windows IN FRONT of the tracked window, compute the capture-region union via
    /// ``CaptureRegionMath``, and fire the union handler when it changes beyond hysteresis. queue-
    /// confined (called from ``pollOnce``). The display is the one under the window centre.
    private func pollAssociatedUnion(targetFrameVR: VideoRect) {
        guard let handler = associatedUnionHandler else { return }
        let targetFrame = CGRect(x: targetFrameVR.origin.x, y: targetFrameVR.origin.y,
                                 width: targetFrameVR.size.width, height: targetFrameVR.size.height)
        // Display under the window centre (the VD in the real deployment).
        let center = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
        var did = CGDirectDisplayID(0); var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(center, 1, &did, &count) == .success, count > 0 else { return }
        let displayBounds = CGDisplayBounds(did)
        guard let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return }
        // CGWindowList is FRONT-to-back: take the slice strictly in front of the tracked window.
        var inFront: [CaptureRegionMath.WindowSnapshot] = []
        for w in all {
            let wid = (w[kCGWindowNumber as String] as? UInt32) ?? 0
            if wid == windowID { break }   // reached the tracked window — the rest are behind it
            guard let bd = w[kCGWindowBounds as String] as? [String: Any],
                  let r = CGRect(dictionaryRepresentation: bd as CFDictionary) else { continue }
            let ownerPID = Int32((w[kCGWindowOwnerPID as String] as? Int) ?? -1)
            let layer = (w[kCGWindowLayer as String] as? Int) ?? Int.min
            inFront.append(.init(windowID: wid, ownerPID: ownerPID, layer: layer, frame: r))
        }
        let union = CaptureRegionMath.unionRegion(targetFrame: targetFrame, targetWindowID: UInt32(windowID),
                                                  targetPID: Int32(pid), windowsInFront: inFront, displayBounds: displayBounds)
        let baseline = lastUnionEmitted.isNull ? targetFrame : lastUnionEmitted
        guard CaptureRegionMath.shouldRetarget(current: baseline, desired: union) else { return }
        lastUnionEmitted = union
        handler(union)
    }

    /// Emits a title change if the window's title differs from the last seen value.
    /// Driven by the AX `kAXTitleChangedNotification` in production.
    @MainActor
    public func checkTitle() {
        let appEl = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return }
        // Heuristic match by position/size to the tracked CGWindowID (no public
        // AXUIElement <-> CGWindowID map — doc 05 §4).
        guard let bounds = currentBoundsCG() else { return }
        for axWindow in axWindows {
            if axWindowFrame(axWindow) == bounds {
                var titleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
                   let title = titleRef as? String, title != lastTitle {
                    lastTitle = title
                    geometryHandler(.title(title))
                }
                return
            }
        }
    }

    /// PATH A in-session resize (host-window-resize feature):
    /// resize the REAL tracked window to `desiredPoints` via the Accessibility API and return
    /// the size the window ACTUALLY adopted (points). The window may clamp to its own
    /// min/max — so the ACHIEVED size (read back from `kAXSizeAttribute`), not the requested
    /// size, is the source of truth for the SCStream/encoder reconfigure + the `resizeAck`.
    ///
    /// Returns `nil` (resize ABORTED, caller keeps the old encoder running, sends no ack) when:
    /// the app/window cannot be looked up, or the window does not support a size write
    /// (`kAXErrorAttributeUnsupported` on a fixed-size/sheet window) or the AX call cannot
    /// complete (`kAXErrorCannotComplete` on a hung/modal app). NEVER crashes.
    ///
    /// ⚠️ **GUI-ONLY + TCC:** needs the Accessibility grant (same one the watcher/injector
    /// already require). `AXUIElementSetMessagingTimeout` caps a hung target (mirrors
    /// ``InputInjector/raiseTargetWindow()``) so a beachballing app fails fast instead of
    /// stalling the resize path.
    @MainActor
    public func resizeWindow(toPoints desiredPoints: VideoSize) -> VideoSize? {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.25)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return nil }
        // Heuristic match the AX window to the tracked CGWindowID by frame (no public map —
        // doc 05 §4), the same lookup ``axWindowFrame`` / the injector use.
        guard let bounds = currentBoundsCG() else { return nil }
        for axWindow in axWindows where axWindowFrame(axWindow) == bounds {
            var size = CGSize(width: max(1, desiredPoints.width), height: max(1, desiredPoints.height))
            guard let value = AXValueCreate(.cgSize, &size) else { return nil }
            // WRITE the new size. Tolerate (do NOT crash on) unsupported/cannot-complete —
            // a fixed-size window returns kAXErrorAttributeUnsupported; a hung app times out
            // to kAXErrorCannotComplete. Either ⇒ abort the resize (return nil).
            let setStatus = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, value)
            guard setStatus == .success else { return nil }
            // READ BACK the achieved size — the window may have clamped to its own min/max.
            // The achieved (not requested) size is the source of truth for the reconfigure.
            return axWindowFrame(axWindow)?.size ?? desiredPoints
        }
        return nil
    }

    @MainActor
    private func axWindowFrame(_ element: AXUIElement) -> VideoRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success else {
            return nil
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return VideoRect(x: Double(point.x), y: Double(point.y), width: Double(size.width), height: Double(size.height))
    }
}
#endif
