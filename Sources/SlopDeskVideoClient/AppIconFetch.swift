#if canImport(QuartzCore) && canImport(Metal) && canImport(VideoToolbox)
import Foundation
import SlopDeskVideoProtocol

/// One-shot app-icon fetch (docs/45 Phase 3): the blob sibling of ``VideoWindowDiscovery``.
/// Acquires a transient lane, retransmits `appIconRequest` until the kind-0 blob assembles (each
/// retransmit re-sends every chunk from the host's cache — the whole-blob re-request discipline),
/// validates the PNG magic, and releases the lane. Returns `nil` on timeout / no registry / no
/// icon — the caller's NEGATIVE cache entry stops re-asking.
@preconcurrency
@MainActor
public enum AppIconFetch {
    public static func fetch(
        host: String,
        mediaPort: UInt16,
        cursorPort: UInt16,
        bundleID: String,
        sizePx: UInt16 = 64,
        retryInterval: Duration = .milliseconds(500),
        timeout: Duration = .seconds(3),
    ) async -> Data? {
        guard let registry = VideoWindowPipeline.sharedRegistry else { return nil }
        let acq = registry.acquire(host: host, mediaPort: mediaPort, cursorPort: cursorPort)
        defer { registry.release(host: host, mediaPort: mediaPort, cursorPort: cursorPort, channelID: acq.channelID) }

        let expectedID = BlobChunker.fnv1a64(bundleID)
        let box = BlobReplyBox(expectedKind: BlobAssembler.iconKind, expectedID: expectedID)
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

        let request = VideoControlMessage.appIconRequest(sizePx: sizePx, bundleID: bundleID).encode()
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
        let blob = await box.firstBlob()
        sender.cancel()
        // Magic-validated on reassembly — a malformed blob never poisons the caller's disk cache.
        guard let blob, BlobImageValidator.validates(blob, forKind: BlobAssembler.iconKind) else {
            return nil
        }
        return blob
    }
}

/// One-shot blob box: chunks fold under the lock (receive queue), the first COMPLETE blob matching
/// the expected (kind, blobID) resolves the waiter. The `ReplyBox` shape with the shared
/// ``BlobAssembler`` folded in.
private final class BlobReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var assembler = BlobAssembler()
    private let expectedKind: UInt8
    private let expectedID: UInt64
    private var blob: Data?
    private var cont: CheckedContinuation<Data?, Never>?
    private var resolved = false

    init(expectedKind: UInt8, expectedID: UInt64) {
        self.expectedKind = expectedKind
        self.expectedID = expectedID
    }

    var hasBlob: Bool { lock.withLock { blob != nil } }

    func fold(
        blobKind: UInt8, blobID: UInt64, metaA: UInt16, metaB: UInt16,
        chunkIndex: UInt8, chunkCount: UInt8, bytes: Data,
    ) {
        guard blobKind == expectedKind, blobID == expectedID else { return }
        lock.lock()
        let complete = assembler.fold(
            blobKind: blobKind, blobID: blobID, metaA: metaA, metaB: metaB,
            chunkIndex: chunkIndex, chunkCount: chunkCount, bytes: bytes,
        )
        if let complete, blob == nil { blob = complete.bytes }
        guard blob != nil, !resolved, let c = cont else {
            lock.unlock()
            return
        }
        resolved = true
        cont = nil
        let b = blob
        lock.unlock()
        c.resume(returning: b)
    }

    func finish() {
        lock.lock()
        guard !resolved, let c = cont else {
            lock.unlock()
            return
        }
        resolved = true
        cont = nil
        let b = blob
        lock.unlock()
        c.resume(returning: b)
    }

    func firstBlob() async -> Data? {
        await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
            lock.lock()
            if resolved || blob != nil {
                resolved = true
                let b = blob
                lock.unlock()
                c.resume(returning: b)
                return
            }
            cont = c
            lock.unlock()
        }
    }
}
#endif
