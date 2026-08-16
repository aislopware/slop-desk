import CSlopDeskFFI
import Foundation

/// The Swift face of `rust/slopdesk-video`'s `window_feed`, reached through the door of the same
/// name.
///
/// PURE client-side assembler for `windowFeedSnapshot` chunks (docs/45): collects chunks per
/// generation and yields a complete snapshot exactly once. Untrusted-input discipline throughout —
/// bounded partial-generation map, bounded record accumulation, and the pinned decode rule that all
/// chunks of one generation must AGREE on `chunkCount` (disagreement ⇒ the generation is corrupt ⇒
/// discarded; the next `windowFeedSubscribe` renewal heals it from the host's cached chunks).
///
/// A HANDLE, and therefore a CLASS, for the reason the blob assembler is one: the accumulator is a
/// list of records with three strings each, held across chunks and across up to four generations.
/// The records cross in the shape the control DECODE already answers in — flat rows naming spans in
/// one arena — so a fold costs this side the same marshalling an encode already does, and there is
/// no second record type anywhere.
public final class WindowFeedAssembler: @unchecked Sendable {
    /// One fully assembled snapshot: `records` is every chunk's records concatenated in chunk order.
    public struct CompleteSnapshot: Equatable, Sendable {
        public var generation: UInt32
        public var records: [HostWindowRecord]

        public init(generation: UInt32, records: [HostWindowRecord]) {
            self.generation = generation
            self.records = records
        }
    }

    /// The bounds, from the door, so neither language writes them down twice.
    private static let bounds = slopdesk_window_feed_bounds()
    /// Partial generations kept at once — chunks interleave across at most adjacent generations in
    /// practice (one answer per renewal); the bound keeps a hostile sender from growing the map.
    public static var maxPartialGenerations: Int { bounds.max_partial_generations }
    /// Absolute record cap per assembled generation — the host caps snapshots at 64 records, so
    /// anything past this is hostile padding; the generation is discarded (cap untrusted accumulators).
    public static var maxRecordsPerGeneration: Int { bounds.max_records_per_generation }

    /// The partial generations, and any snapshot a fold completed and no take has claimed yet.
    private let handle: OpaquePointer?

    public init() {
        handle = slopdesk_window_feed_new()
    }

    deinit {
        slopdesk_window_feed_free(handle)
    }

    /// Folds one decoded chunk. Returns the completed snapshot when this chunk finishes its
    /// generation, else `nil`. Duplicate chunks (the host dup-sends ×2) overwrite idempotently.
    public func fold(
        generation: UInt32,
        chunkIndex: UInt8,
        chunkCount: UInt8,
        records: [HostWindowRecord],
    ) -> CompleteSnapshot? {
        let (rows, arena) = HostWindowRecord.rows(records)
        let folded = rows.withUnsafeBufferPointer { source in
            arena.withUnsafeBytes { pool in
                slopdesk_window_feed_fold(
                    handle, generation, chunkIndex, chunkCount,
                    source.baseAddress, source.count, pool.baseAddress, pool.count,
                )
            }
        }
        guard folded.complete else { return nil }
        return take(generation: folded.generation, shape: folded)
    }

    /// Drops ALL partial state — called at the end of each subscribe round so a half-received
    /// generation never leaks into the next round (the renewal re-fetches it whole).
    public func reset() {
        slopdesk_window_feed_reset(handle)
    }

    /// Copies the completed snapshot out at the shape the fold reported.
    private func take(generation: UInt32, shape: SlopDeskWindowFeedFold) -> CompleteSnapshot? {
        var rows = [SlopDeskControlRecord](repeating: SlopDeskControlRecord(), count: shape.record_count)
        var arena = Data(count: shape.arena_len)
        let taken = rows.withUnsafeMutableBufferPointer { out in
            arena.withUnsafeMutableBytes { pool in
                slopdesk_window_feed_take(
                    handle, out.baseAddress, out.count, pool.baseAddress, pool.count,
                )
            }
        }
        guard taken.copied else { return nil }
        return CompleteSnapshot(
            generation: generation,
            records: rows.map { row in HostWindowRecord.of(row, arena: arena) },
        )
    }
}
