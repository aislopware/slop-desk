import CSlopDeskFFI
import Foundation
import SlopDeskVideoProtocol

// The Swift face of `rust/slopdesk-video`'s `window_feed_host` cache + chunk packer (docs/45 §5–6).
// No clock (callers pass `now`), no sockets — the "decider beside the actor" discipline of
// `VideoMuxRouter`/`UnboundLaneByeDecider`.

/// Byte-budgeted greedy packer: splits one snapshot's records into `windowFeedSnapshot` chunks whose
/// RECORD bytes fit the per-chunk budget `window_feed_host.rs` holds — so every encoded chunk fits
/// one mux datagram. Packing is byte-budgeted, NOT record-counted (titles vary 14–320 B/record).
public enum WindowFeedChunkPacker {
    /// Encodes `records` (already builder-capped, so each string is wire-capped) into ready-to-send
    /// chunk payloads for `generation`. ZERO records still yield ONE empty chunk — an empty desktop
    /// is a real snapshot the client must be able to assemble.
    ///
    /// Two calls, like every other pure builder on this door: the first reports the shape, the
    /// second fills the buffers it named.
    public static func encodedChunks(generation: UInt32, records: [HostWindowRecord]) -> [Data] {
        let (rows, arena) = HostWindowRecord.rows(records)
        return rows.withUnsafeBufferPointer { input in
            arena.withUnsafeBytes { pool -> [Data] in
                let shape = slopdesk_feed_chunks(
                    generation, input.baseAddress, input.count, pool.baseAddress, pool.count,
                    nil, 0, nil, 0,
                )
                return payloads(shape) { spans, bytes in
                    slopdesk_feed_chunks(
                        generation, input.baseAddress, input.count, pool.baseAddress, pool.count,
                        spans.baseAddress, spans.count, bytes.baseAddress, bytes.count,
                    )
                }
            }
        }
    }

    /// Copies a payload list out at the shape the door reported: one buffer of spans, one of the
    /// concatenated bytes, cut back apart on this side. Shared by the packer and the cache's reply,
    /// because both answer in exactly this shape.
    static func payloads(
        _ shape: SlopDeskFeedShape,
        _ fill: (UnsafeMutableBufferPointer<SlopDeskByteSpan>, UnsafeMutableRawBufferPointer) -> SlopDeskFeedShape,
    ) -> [Data] {
        let room = shape.count
        guard room > 0 else { return [] }
        var spans = [SlopDeskByteSpan](repeating: SlopDeskByteSpan(), count: room)
        var bytes = Data(count: shape.arena_len)
        let filled = spans.withUnsafeMutableBufferPointer { out in
            bytes.withUnsafeMutableBytes { pool in fill(out, pool) }
        }
        guard filled.count == shape.count else { return [] }
        return spans.map { span in
            let start = Int(span.offset)
            let end = start + Int(span.length)
            guard start >= 0, end <= bytes.count, start <= end else { return Data() }
            return Data(bytes[start..<end])
        }
    }
}

/// The host's ONE feed snapshot cache: a TTL-gated build (renewal retransmits, re-requests, and
/// multiple clients are all answered from the same encoded bytes — the enumeration-amplification
/// guard, superseding per-channel coalescing for this path) + a generation counter that bumps ONLY
/// when the records actually changed (so an unchanged desktop answers with the 5-byte
/// `windowFeedCurrent`).
///
/// A HANDLE, and so a class: it holds the record list AND the datagrams that list packs into, and
/// the near side reads one reply out of it per subscribe. That is doc 55 §4b's test. `@unchecked
/// Sendable` is sound because the feed glue drives it from one queue.
public final class WindowFeedCache: @unchecked Sendable {
    /// The far-side cache, which owns the records, the chunks and the staleness stamp.
    private let handle: OpaquePointer?
    /// How long a built snapshot answers subscribes without re-enumerating (docs/45 §6: 1 s).
    public let ttl: TimeInterval

    public init(ttl: TimeInterval = 1.0) {
        self.ttl = ttl
        handle = slopdesk_feed_cache_new(ttl)
    }

    deinit { slopdesk_feed_cache_free(handle) }

    /// The last published generation. `0` = nothing built yet — never published (it is the wire's
    /// "client has nothing" sentinel), so the counter starts at 1 and skips 0 on wrap.
    public var generation: UInt32 { slopdesk_feed_cache_generation(handle) }

    /// The cached records, read back through the door in the same two-step shape everything else
    /// on this boundary uses.
    public var records: [HostWindowRecord] {
        let shape = slopdesk_feed_cache_records(handle, nil, 0, nil, 0)
        let room = shape.count
        guard room > 0 else { return [] }
        var rows = [SlopDeskControlRecord](repeating: SlopDeskControlRecord(), count: room)
        var arena = Data(count: shape.arena_len)
        let filled = rows.withUnsafeMutableBufferPointer { out in
            arena.withUnsafeMutableBytes { pool in
                slopdesk_feed_cache_records(handle, out.baseAddress, out.count, pool.baseAddress, pool.count)
            }
        }
        guard filled.count == shape.count else { return [] }
        return rows.map { row in HostWindowRecord.of(row, arena: arena) }
    }

    /// Whether the caller must enumerate + ``fold(_:now:)`` before answering (never built, or stale).
    public func needsRebuild(now: TimeInterval) -> Bool {
        slopdesk_feed_cache_needs_rebuild(handle, now)
    }

    /// Folds a freshly built record set: bumps the generation + re-encodes chunks ONLY when the
    /// records differ from the cached set (or nothing was ever built); an identical set just
    /// refreshes the TTL stamp.
    public func fold(_ fresh: [HostWindowRecord], now: TimeInterval) {
        let (rows, arena) = HostWindowRecord.rows(fresh)
        rows.withUnsafeBufferPointer { input in
            arena.withUnsafeBytes { pool in
                slopdesk_feed_cache_fold(handle, input.baseAddress, input.count, pool.baseAddress, pool.count, now)
            }
        }
    }

    /// The datagrams answering one `windowFeedSubscribe(knownGeneration:)`: the 5-byte
    /// `windowFeedCurrent` ack when the client is already current, else the full chunk sequence
    /// (`isSnapshot` tells the sender to dup-send ×2). Empty only in the impossible never-built case.
    public func replyDatagrams(forKnownGeneration known: UInt32) -> (isSnapshot: Bool, payloads: [Data]) {
        var isSnapshot = false
        let shape = slopdesk_feed_cache_reply(handle, known, &isSnapshot, nil, 0, nil, 0)
        let payloads = WindowFeedChunkPacker.payloads(shape) { spans, bytes in
            var again = false
            return slopdesk_feed_cache_reply(
                handle, known, &again, spans.baseAddress, spans.count, bytes.baseAddress, bytes.count,
            )
        }
        return (isSnapshot, payloads)
    }
}
