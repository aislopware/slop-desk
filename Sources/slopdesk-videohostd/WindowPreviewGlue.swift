// Window-preview PEEK (docs/45 Phase 4): answers `windowPreviewRequest` with `blobChunk` kind-1
// JPEGs. The ONLY window-content imagery anywhere (the icon-over-thumbnail ruling) — one-shot, on
// demand, at a LEGIBLE size. `SCScreenshotManager` shares WindowServer/GPU with the live HEVC
// encoders, so previews are hard-throttled: single-flight per window, captures reused ≤ 1 s,
// ≤ 2 fresh captures/s globally, chunks paced ~1 datagram/ms. A throttled/failed request is
// answered with SILENCE — the client's fetch round times out quietly (fully-formed-only contract).

import Foundation

#if os(macOS)
import AppKit
import ScreenCaptureKit
import SlopDeskVideoHost
import SlopDeskVideoProtocol

/// Captures + serves window previews, serialized on this actor.
actor WindowPreviewService {
    private let mux: NWVideoMuxDatagramTransport
    /// windowID → (encoded chunks, capture stamp): a peek re-hover inside 1 s is free.
    private var cache: [UInt32: (chunks: [Data], at: TimeInterval)] = [:]
    /// Windows with a capture mid-flight (single-flight; concurrent requests coalesce to silence —
    /// the requester's retransmit picks the finished capture out of the cache).
    private var inFlight: Set<UInt32> = []
    /// Stamps of the last fresh captures (the global ≤ 2/s cap).
    private var captureStamps: [TimeInterval] = []

    private static let reuseWindow: TimeInterval = 1.0
    private static let maxCapturesPerSecond = 2
    private static let jpegQualityLadder: [CGFloat] = [0.6, 0.4, 0.25]

    init(mux: NWVideoMuxDatagramTransport) {
        self.mux = mux
    }

    private static func nowSeconds() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    func answer(
        channelID: UInt32,
        windowID: UInt32,
        maxWidthPx: UInt16,
        answerGuard: ListAnswerGuard,
    ) async {
        defer { answerGuard.end(channelID) }
        let now = Self.nowSeconds()
        if let cached = cache[windowID], now - cached.at < Self.reuseWindow {
            await sendPaced(cached.chunks, to: channelID)
            mux.retire(channelID)
            return
        }
        // Single-flight + the global capture cap: over-budget requests get silence, not a queue —
        // the client times out quietly and a retransmit lands on the cache if a capture finished.
        captureStamps.removeAll { now - $0 >= 1.0 }
        guard !inFlight.contains(windowID), captureStamps.count < Self.maxCapturesPerSecond else {
            mux.retire(channelID)
            return
        }
        inFlight.insert(windowID)
        captureStamps.append(now)
        defer { inFlight.remove(windowID) }
        let px = max(160, min(1280, Int(maxWidthPx)))
        guard let (jpeg, width, height) = await Self.captureJPEG(windowID: windowID, maxWidthPx: px),
              let chunks = BlobChunker.encodedChunks(
                  blobKind: BlobAssembler.previewKind,
                  blobID: UInt64(windowID),
                  metaA: UInt16(clamping: width),
                  metaB: UInt16(clamping: height),
                  bytes: jpeg,
              )
        else {
            mux.retire(channelID)
            return
        }
        cache[windowID] = (chunks, Self.nowSeconds())
        // Bound the cache — stale previews age out naturally; 16 windows of peek history is plenty.
        if cache.count > 16 {
            let cutoff = Self.nowSeconds() - Self.reuseWindow
            cache = cache.filter { $0.value.at >= cutoff }
        }
        log("answered windowPreviewRequest win=\(windowID): \(jpeg.count) bytes in \(chunks.count) chunk(s)")
        await sendPaced(chunks, to: channelID)
        mux.retire(channelID)
    }

    /// Sends chunks paced ~1 datagram/ms — a preview burst must never contend with a video frame's
    /// fragments for the socket.
    private func sendPaced(_ chunks: [Data], to channelID: UInt32) async {
        for chunk in chunks {
            mux.send(chunk, on: .control, channelID: channelID)
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    /// One-shot capture → aspect-preserving downscale to `maxWidthPx` → JPEG under the wire cap
    /// (quality ladder; a frame that can't fit at q0.25 is dropped — silence beats a broken image).
    private static func captureJPEG(
        windowID: UInt32, maxWidthPx: Int,
    ) async -> (jpeg: Data, width: Int, height: Int)? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false,
        ), let window = content.windows.first(where: { $0.windowID == windowID })
        else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = min(1, CGFloat(maxWidthPx) / max(window.frame.width, 1))
        let config = SCStreamConfiguration()
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config,
        ) else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        for quality in jpegQualityLadder {
            guard let jpeg = rep.representation(
                using: .jpeg, properties: [.compressionFactor: quality],
            ) else { continue }
            if jpeg.count <= VideoControlMessage.previewBlobMaxBytes {
                return (jpeg, image.width, image.height)
            }
        }
        return nil
    }
}
#endif
