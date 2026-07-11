#if canImport(QuartzCore) && canImport(Metal) && canImport(VideoToolbox)
import Foundation
import SlopDeskVideoProtocol

/// One-shot window-preview fetch (docs/45 Phase 4): the kind-1 sibling of ``AppIconFetch``.
/// Retransmits `windowPreviewRequest` until the JPEG blob assembles (each retransmit re-sends
/// every chunk from the host's ≤1 s capture cache), validates the JPEG magic, releases the lane.
/// Returns `(jpeg, pxWidth, pxHeight)` or `nil` (timeout / throttled host / no window) — the peek
/// simply never appears (fully-formed-only; no spinner, no skeleton).
@preconcurrency
@MainActor
public enum WindowPreviewFetch {
    public static func fetch(
        host: String,
        mediaPort: UInt16,
        cursorPort: UInt16,
        windowID: UInt32,
        maxWidthPx: UInt16 = 640,
        retryInterval: Duration = .milliseconds(500),
        timeout: Duration = .seconds(3),
    ) async -> (jpeg: Data, pxWidth: Int, pxHeight: Int)? {
        guard let registry = VideoWindowPipeline.sharedRegistry else { return nil }
        let acq = registry.acquire(host: host, mediaPort: mediaPort, cursorPort: cursorPort)
        defer { registry.release(host: host, mediaPort: mediaPort, cursorPort: cursorPort, channelID: acq.channelID) }

        let box = BlobReplyBox(expectedKind: BlobAssembler.previewKind, expectedID: UInt64(windowID))
        acq.flow.registerLane(
            channelID: acq.channelID,
            onMedia: { channel, payload in
                guard channel == .control,
                      let msg = try? VideoControlMessage.decode(payload),
                      case let .blobChunk(kind, id, metaA, metaB, index, count, bytes) = msg
                else { return }
                box.fold(
                    blobKind: kind, blobID: id, metaA: metaA, metaB: metaB,
                    chunkIndex: index, chunkCount: count, bytes: bytes,
                )
            },
            onCursor: { _ in },
        )

        let request = VideoControlMessage.windowPreviewRequest(
            windowID: windowID, maxWidthPx: maxWidthPx,
        ).encode()
        let flow = acq.flow
        let channelID = acq.channelID
        let sender = Task { @MainActor in
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while ContinuousClock.now < deadline, !box.hasBlob, !Task.isCancelled {
                flow.send(request, on: .control, channelID: channelID)
                try? await Task.sleep(for: retryInterval)
            }
            box.finish()
        }
        let result = await box.firstBlobWithMeta()
        sender.cancel()
        guard let result,
              BlobImageValidator.validates(result.bytes, forKind: BlobAssembler.previewKind)
        else { return nil }
        return (result.bytes, Int(result.metaA), Int(result.metaB))
    }
}
#endif
