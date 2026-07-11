import Foundation
import SlopDeskVideoProtocol

// PURE window-feed generation cache + chunk packer (docs/45 §5–6). No clock (callers pass `now`),
// no sockets — the "decider beside the actor" discipline of `VideoMuxRouter`/`UnboundLaneByeDecider`,
// so the generation/TTL/packing rules are headless-tested.

/// Byte-budgeted greedy packer: splits one snapshot's records into `windowFeedSnapshot` chunks whose
/// RECORD bytes fit ``VideoControlMessage/feedRecordBytesPerChunk`` — so every encoded chunk fits one
/// mux datagram. Packing is byte-budgeted, NOT record-counted (real titles vary 14–320 B/record).
public enum WindowFeedChunkPacker {
    /// The exact encoded size of one record: 4 id + 2 w + 2 h + 1 flags + 1 display + three
    /// UInt16-length-prefixed strings.
    static func recordEncodedSize(_ record: HostWindowRecord) -> Int {
        14 + record.bundleID.utf8.count + record.appName.utf8.count + record.title.utf8.count
    }

    /// Encodes `records` (already builder-capped, so ≤ 64 and each string wire-capped) into ready-to-
    /// send chunk payloads for `generation`. ZERO records still yield ONE empty chunk — an empty
    /// desktop is a real snapshot the client must be able to assemble.
    public static func encodedChunks(generation: UInt32, records: [HostWindowRecord]) -> [Data] {
        var groups: [[HostWindowRecord]] = []
        var current: [HostWindowRecord] = []
        var currentBytes = 0
        for record in records {
            let size = recordEncodedSize(record)
            if !current.isEmpty, currentBytes + size > VideoControlMessage.feedRecordBytesPerChunk {
                groups.append(current)
                current = []
                currentBytes = 0
            }
            current.append(record)
            currentBytes += size
        }
        if !current.isEmpty || groups.isEmpty { groups.append(current) }
        // 64 records can't exceed 64 chunks; the clamp is a defensive bound, never expected to bite.
        let chunkCount = UInt8(clamping: groups.count)
        return groups.enumerated().map { index, chunkRecords in
            VideoControlMessage.windowFeedSnapshot(
                generation: generation,
                chunkIndex: UInt8(clamping: index),
                chunkCount: chunkCount,
                records: chunkRecords,
            ).encode()
        }
    }
}

/// The host's ONE feed snapshot cache: a TTL-gated build (renewal retransmits, re-requests, and
/// multiple clients are all answered from the same encoded bytes — the enumeration-amplification
/// guard, superseding per-channel coalescing for this path) + a generation counter that bumps ONLY
/// when the records actually changed (so an unchanged desktop answers with the 5-byte
/// `windowFeedCurrent`).
public struct WindowFeedCache: Sendable {
    /// The last published generation. `0` = nothing built yet — never published (it is the wire's
    /// "client has nothing" sentinel), so the counter starts at 1 and skips 0 on wrap.
    public private(set) var generation: UInt32 = 0
    public private(set) var records: [HostWindowRecord] = []
    /// The ready-to-send chunk payloads for `generation` (encoded once per bump, not per subscriber).
    public private(set) var encodedChunks: [Data] = []
    private var builtAt: TimeInterval = -.infinity
    /// How long a built snapshot answers subscribes without re-enumerating (docs/45 §6: 1 s).
    public let ttl: TimeInterval

    public init(ttl: TimeInterval = 1.0) {
        self.ttl = ttl
    }

    /// Whether the caller must enumerate + ``fold(_:now:)`` before answering (never built, or stale).
    public func needsRebuild(now: TimeInterval) -> Bool {
        generation == 0 || now - builtAt >= ttl
    }

    /// Folds a freshly built record set: bumps the generation + re-encodes chunks ONLY when the
    /// records differ from the cached set (or nothing was ever built); an identical set just
    /// refreshes the TTL stamp.
    public mutating func fold(_ fresh: [HostWindowRecord], now: TimeInterval) {
        builtAt = now
        guard generation == 0 || fresh != records else { return }
        generation &+= 1
        if generation == 0 { generation = 1 } // skip the "client has nothing" sentinel on wrap
        records = fresh
        encodedChunks = WindowFeedChunkPacker.encodedChunks(generation: generation, records: fresh)
    }

    /// The datagrams answering one `windowFeedSubscribe(knownGeneration:)`: the 5-byte
    /// `windowFeedCurrent` ack when the client is already current, else the full chunk sequence
    /// (`isSnapshot` tells the sender to dup-send ×2). Empty only in the impossible never-built case.
    public func replyDatagrams(forKnownGeneration known: UInt32) -> (isSnapshot: Bool, payloads: [Data]) {
        guard generation != 0 else { return (false, []) }
        if known == generation {
            return (false, [VideoControlMessage.windowFeedCurrent(generation: generation).encode()])
        }
        return (true, encodedChunks)
    }
}
