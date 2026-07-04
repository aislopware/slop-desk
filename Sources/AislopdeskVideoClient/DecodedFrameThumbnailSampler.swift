#if canImport(QuartzCore) && canImport(Metal) && canImport(VideoToolbox)
import CoreImage
import CoreVideo
import Foundation
import QuartzCore

/// Samples the live decoded stream into a small `CGImage` ~every `interval` seconds (MERIDIAN C4 —
/// the sidebar WINDOWS row's live thumbnail). Sits on the `submitDecodedFrame` hook (every decoded
/// buffer passes through), but the actual NV12 → RGB conversion runs OFF the decode path on a
/// utility queue, so the hot path only pays a clock read + a lock.
///
/// Instantiated ONLY by the live `VideoWindowPipeline.activate` (app-target runtime — the `CIContext`
/// is created lazily on the first sampled frame, so no Metal device ever exists in a headless
/// build/test context — the hang-safety rule).
final class DecodedFrameThumbnailSampler: @unchecked Sendable {
    /// Seconds between samples. A thumbnail is decorative — 2 s is plenty live, and keeps the
    /// conversion cost invisible next to the 30–60 fps decode.
    private let interval: CFTimeInterval
    /// The sampled image's longer edge (pixels) — sidebar-row sized, not a screenshot.
    private let maxEdge: CGFloat
    /// Delivered on the MAIN actor with each sample.
    private let onSample: @MainActor (CGImage) -> Void

    private let lock = NSLock()
    private var lastSampleAt: CFTimeInterval = 0
    private var converting = false
    /// Lazy so a pipeline that never decodes a frame never creates the CoreImage context (and its
    /// Metal device). Created on the conversion queue; only ever used there.
    private var context: CIContext?
    private let queue = DispatchQueue(label: "aislopdesk.video.thumbnail-sampler", qos: .utility)

    init(
        interval: CFTimeInterval = 2.0,
        maxEdge: CGFloat = 240,
        onSample: @escaping @MainActor (CGImage) -> Void,
    ) {
        self.interval = interval
        self.maxEdge = maxEdge
        self.onSample = onSample
    }

    /// Offer one decoded buffer. Returns immediately (throttled / conversion-in-flight buffers are
    /// skipped — the NEXT frame samples instead; the stream keeps producing them).
    func ingest(_ buffer: CVImageBuffer) {
        let now = CACurrentMediaTime()
        let admit: Bool = lock.withLock {
            guard !converting, now - lastSampleAt >= interval else { return false }
            converting = true
            lastSampleAt = now
            return true
        }
        guard admit else { return }
        // CVImageBuffer is a thread-safe, refcounted CoreVideo handle whose pixels are immutable
        // after decode — the same unchecked-Sendable ferry the render path uses.
        let box = UnsafeTransfer(buffer)
        queue.async { [weak self] in
            guard let self else { return }
            defer { lock.withLock { converting = false } }
            guard let image = convert(box.value) else { return }
            Task { @MainActor [onSample] in onSample(image) }
        }
    }

    /// NV12 CVPixelBuffer → downscaled RGB CGImage (runs on the sampler queue only).
    private func convert(_ buffer: CVImageBuffer) -> CGImage? {
        let source = CIImage(cvImageBuffer: buffer)
        let extent = source.extent
        guard extent.width >= 1, extent.height >= 1 else { return nil }
        let scale = CGFloat.minimum(maxEdge / CGFloat.maximum(extent.width, extent.height), 1)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if context == nil { context = CIContext(options: [.cacheIntermediates: false]) }
        return context?.createCGImage(scaled, from: scaled.extent)
    }
}
#endif
