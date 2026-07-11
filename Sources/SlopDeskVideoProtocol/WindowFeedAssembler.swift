import Foundation

/// PURE client-side assembler for `windowFeedSnapshot` chunks (docs/45): collects chunks per
/// generation and yields a complete snapshot exactly once. Untrusted-input discipline throughout —
/// bounded partial-generation map, bounded record accumulation, and the pinned decode rule that all
/// chunks of one generation must AGREE on `chunkCount` (disagreement ⇒ the generation is corrupt ⇒
/// discarded; the next `windowFeedSubscribe` renewal heals it from the host's cached chunks).
public struct WindowFeedAssembler: Sendable {
    /// One fully assembled snapshot: `records` is every chunk's records concatenated in chunk order.
    public struct CompleteSnapshot: Equatable, Sendable {
        public var generation: UInt32
        public var records: [HostWindowRecord]

        public init(generation: UInt32, records: [HostWindowRecord]) {
            self.generation = generation
            self.records = records
        }
    }

    private struct Partial {
        var chunkCount: UInt8
        var received: [UInt8: [HostWindowRecord]] = [:]
    }

    /// Partial generations kept at once — chunks interleave across at most adjacent generations in
    /// practice (one answer per renewal); the bound keeps a hostile sender from growing the map.
    public static let maxPartialGenerations = 4
    /// Absolute record cap per assembled generation — the host caps snapshots at 64 records, so
    /// anything past this is hostile padding; the generation is discarded (cap untrusted accumulators).
    public static let maxRecordsPerGeneration = 512

    private var partials: [UInt32: Partial] = [:]
    /// Insertion order for eviction (oldest partial dropped when the map is full).
    private var insertionOrder: [UInt32] = []

    public init() {}

    /// Folds one decoded chunk. Returns the completed snapshot when this chunk finishes its
    /// generation, else `nil`. Duplicate chunks (the host dup-sends ×2) overwrite idempotently.
    public mutating func fold(
        generation: UInt32,
        chunkIndex: UInt8,
        chunkCount: UInt8,
        records: [HostWindowRecord],
    ) -> CompleteSnapshot? {
        var partial: Partial
        if let existing = partials[generation] {
            guard existing.chunkCount == chunkCount else {
                // Chunks of one generation disagreeing on chunkCount = corruption/hostile — the
                // pinned decode rule says the WHOLE generation is discarded, not patched.
                discard(generation)
                return nil
            }
            partial = existing
        } else {
            if partials.count >= Self.maxPartialGenerations, let oldest = insertionOrder.first {
                discard(oldest)
            }
            partial = Partial(chunkCount: chunkCount)
            insertionOrder.append(generation)
        }
        partial.received[chunkIndex] = records
        guard partial.received.count == Int(chunkCount) else {
            partials[generation] = partial
            return nil
        }
        discard(generation)
        var assembled: [HostWindowRecord] = []
        for index in 0..<chunkCount {
            // Every index is present (count == chunkCount and the codec pinned index < count).
            assembled += partial.received[index] ?? []
            guard assembled.count <= Self.maxRecordsPerGeneration else { return nil }
        }
        return CompleteSnapshot(generation: generation, records: assembled)
    }

    /// Drops a generation's partial state (corrupt, evicted, or just completed).
    private mutating func discard(_ generation: UInt32) {
        partials[generation] = nil
        insertionOrder.removeAll { $0 == generation }
    }

    /// Drops ALL partial state — called at the end of each subscribe round so a half-received
    /// generation never leaks into the next round (the renewal re-fetches it whole).
    public mutating func reset() {
        partials.removeAll()
        insertionOrder.removeAll()
    }
}
