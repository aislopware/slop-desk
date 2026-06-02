#if canImport(QuartzCore) && canImport(CoreVideo)
import Foundation
import CoreVideo
import QuartzCore

/// Drives display from VSync (`CADisplayLink`), NOT decode-completion (doc 17 §3.7).
///
/// ⚠️ **GUI-ONLY** for the `CADisplayLink` path (needs a run loop + a screen).
/// COMPILED + reviewed; not driven from tests.
///
/// Pacing policy (doc 17 §3.7, Moonlight pacer):
/// - The decoder pushes decoded frames into ``submit(_:)`` (most-recent wins).
/// - Each VSync tick pulls the latest decoded frame and renders it; an EMPTY queue
///   shows the LAST decoded frame again (no judder).
/// - A late frame is SKIPPED, never queued, so latency does not accumulate — we keep
///   only the single most-recent frame, dropping any older one still pending.
///
/// The "keep only the newest frame" logic is pure and is unit-testable in isolation;
/// the `CADisplayLink` wiring is GUI-only.
public final class FramePacer: @unchecked Sendable {
    /// Called each VSync with the frame to draw (the newest decoded, or the last
    /// shown when nothing newer arrived). `nil` only before the first frame.
    public typealias RenderCallback = @Sendable (CVImageBuffer) -> Void

    private let renderCallback: RenderCallback
    private let lock = NSLock()
    /// The newest decoded frame not yet shown; replaced (dropped) when a newer one
    /// arrives before the next vsync — this is the skip-late behaviour.
    private var pendingFrame: CVImageBuffer?
    /// The last frame shown — re-presented on an empty queue (show-last-frame).
    private var lastShownFrame: CVImageBuffer?

    #if canImport(QuartzCore) && !os(macOS)
    private var displayLink: CADisplayLink?
    #endif

    public init(renderCallback: @escaping RenderCallback) {
        self.renderCallback = renderCallback
    }

    /// Submits a freshly decoded frame. If an earlier frame is still pending for this
    /// vsync it is dropped (skip-late: only the newest frame is presented).
    public func submit(_ frame: CVImageBuffer) {
        lock.lock()
        pendingFrame = frame // drops any older pending frame
        lock.unlock()
    }

    /// One VSync step: decide which frame to present (pure; the GUI link calls this).
    /// Returns the frame to draw, or `nil` if nothing has ever been decoded yet.
    public func frameForVSync() -> CVImageBuffer? {
        lock.lock(); defer { lock.unlock() }
        if let pending = pendingFrame {
            lastShownFrame = pending
            pendingFrame = nil
            return pending
        }
        return lastShownFrame // show-last-frame on empty queue
    }

    /// VSync handler: pull the frame and render it.
    public func tick() {
        if let frame = frameForVSync() {
            renderCallback(frame)
        }
    }
}
#endif
