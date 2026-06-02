#if os(macOS)
import Foundation
import AppKit
import ApplicationServices
import RworkVideoProtocol

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
    private let queue = DispatchQueue(label: "rwork.video.geometry", qos: .userInteractive)
    private var lastBounds: VideoRect?
    private var lastTitle: String?

    public init(windowID: CGWindowID, pid: pid_t, geometryHandler: @escaping GeometryHandler) {
        self.windowID = windowID
        self.pid = pid
        self.geometryHandler = geometryHandler
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
