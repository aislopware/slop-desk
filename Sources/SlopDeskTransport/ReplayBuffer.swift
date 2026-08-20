import CSlopDeskFFI
import Foundation
import SlopDeskProtocol

// MARK: - ReplayBuffer

/// Host-side replay buffer for lossless reconnect — an SlopDesk-native port of Eternal Terminal's
/// `BackedWriter` over plain TCP.
///
/// ## This is a handle, not an implementation
/// The buffer is `rust/slopdesk-wire`'s `replay::ReplayBuffer` and has been since stage 14. What
/// used to be here was the second copy of it — 658 lines of Swift keeping the same invariants in the
/// same repository, which is what `CLAUDE.md`'s one-implementation rule exists to stop. Stage 30
/// deleted that copy. Every rule below is still true; it is just enforced somewhere the compiler
/// forbids `unsafe`. `docs/55-ffi-boundary.md` describes the handle convention.
///
/// ## Why a handle and not a call
/// The rest of the FFI is pure functions: bytes in, bytes out. This one *is* the memory — up to
/// 256 MiB of retained output, appended on every PTY chunk — so the state stays in Rust and this
/// type owns the token. That also makes this a **reference type**, where the Swift original was a
/// `Sendable` value type. Nothing relied on copying it (the owning session holds exactly one and
/// mutates it under `replayLock`), and reference semantics are what the retained history wants
/// anyway: a silent copy of a 256 MiB buffer was never a thing anyone meant to write.
///
/// ## Why
/// iOS kills the TCP connection seconds after backgrounding. To resume **byte-exact** without tmux,
/// the host retains sent `output` payloads keyed by their monotonic `Int64` seq; on reconnect the
/// client's `hello.lastReceivedSeq` tells the host which tail to replay (`seq > lastReceivedSeq`).
/// Equivalent to ET's byte-level `BackedWriter` seq, lifted to a **per-message** seq (see
/// `docs/20-wire-protocol.md`).
///
/// **Only `.output` is sequenced and replayed.** Control messages (`resize`/`ack`/`title`/`bell`/…)
/// are lifecycle/metadata, not retained: re-deriving size or re-sending a title on reconnect is
/// cheap and stateless; PTY output is the irreplaceable byte stream.
///
/// ## Caps, gates, and the load-bearing invariant
/// - **`maxBackupBytes` = 256 MiB** (4× ET `MAX_BACKUP_BYTES` — coding-tool hosts are ≥32 GB):
///   retained-byte ceiling we *aim* to stay under.
/// - **`offlineGateBytes` = 64 MiB**: while offline, once retained bytes reach this gate
///   ``shouldPauseDrain`` flips `true` (ET `SKIPPED`); below it the host keeps buffering.
/// - **INVARIANT — never silently drop un-acked data.** Dropping un-acked output to meet the
///   256 MiB cap would break byte-exact resume, so the buffer **never evicts un-acked entries**.
///   Offline memory is bounded *instead* by ``shouldPauseDrain``: when asserted, the host relay
///   stops reading the PTY, so the kernel PTY buffer backpressures the shell and **no droppable
///   output is produced**.
/// - **INVARIANT — dead-channel send = retain, never throw.** A retained entry is removed only by a
///   client ``ack(upTo:)``, never by a failed wire send.
/// - **Slow-consumer case:** if retained bytes exceed `maxBackupBytes` while online,
///   ``shouldPauseDrain`` asserts anyway — still no drop.
/// - **No `CryptoHandler`.** WireGuard already encrypts; the buffer stores raw bytes.
///
/// ## Thread safety
/// `@unchecked Sendable`, on the same terms the value type had: the owning host relay serialises
/// every call under its `replayLock`. That is not a nicety here — the Rust entry points take `&mut`
/// through the handle, so two overlapping calls would be aliasing UB rather than a lost update.
public final class ReplayBuffer: @unchecked Sendable {
    /// Retained-byte ceiling, as the buffer itself holds it (4× ET `MAX_BACKUP_BYTES`).
    public static let maxBackupBytes = Int(slopdesk_replay_constant(0))

    /// Offline buffering gate. At/above this while offline, pause the PTY drain.
    public static let offlineGateBytes = Int(slopdesk_replay_constant(1))

    /// Default scrollback ring size (override with `SLOPDESK_SCROLLBACK_BYTES`).
    ///
    /// Retains ACKED entries (history) separately from the un-acked live tail, so a cold-reattach
    /// replay can deliver the full visible scrollback to a fresh terminal — like
    /// `tmux attach-session`. Bounded, evicted line-aligned so a replay never starts
    /// mid-escape-sequence. Disable entirely with `SLOPDESK_SCROLLBACK_PERSIST=0`.
    public static let defaultScrollbackBytes = Int(slopdesk_replay_constant(2))

    /// Action signalled to the PTY relay as output is enqueued (ET's `BufferState`).
    public enum DrainState: Sendable, Equatable {
        /// Keep buffering and draining the PTY normally (below the gate, or online).
        case bufferedOnly
        /// Gate exceeded — pause draining the PTY until the client catches up / returns.
        case skipped
    }

    private let handle: OpaquePointer

    /// The COLD-reattach scrollback cleaner the ring applies, exposed because the owning session
    /// reuses the same transform over its detached-window backlog — which is compacted outside the
    /// ring and so cannot ride the handle's internal call.
    ///
    /// Not an injection point any more. It used to be a closure Rust called back through a C
    /// function pointer, which then dialled screend over `AF_UNIX`; the passes are linked now, so
    /// both ends of that trip are one call and there is nothing to hand in.
    public let scrollbackDistiller: @Sendable (Data) -> Data

    public init(
        // Spelled out rather than `Self.` — a class default argument may not name a covariant Self.
        maxBackupBytes: Int = ReplayBuffer.maxBackupBytes,
        offlineGateBytes: Int = ReplayBuffer.offlineGateBytes,
        scrollbackBytes: Int = ReplayBuffer.defaultScrollbackBytes,
        distill: Bool = true,
        reassertInputModes: Bool = false,
    ) {
        scrollbackDistiller = { @Sendable data in
            Self.sanitize(data, distill: distill, reassertInputModes: reassertInputModes)
        }
        // Rust returns null only if the allocation failed, and it aborts on allocation failure
        // before it could — so this is unreachable rather than unhandled.
        guard let handle = slopdesk_replay_new(
            max(0, maxBackupBytes),
            max(0, offlineGateBytes),
            max(0, scrollbackBytes),
            distill,
            reassertInputModes,
        ) else {
            preconditionFailure("slopdesk_replay_new returned null")
        }
        self.handle = handle
    }

    deinit {
        slopdesk_replay_free(handle)
    }

    /// The replay transform, applied to a standalone buffer.
    ///
    /// The retry exists to be correct rather than travelled: the passes REMOVE bytes, except that
    /// re-asserting input modes appends a handful of escape sequences, so the first guess fits.
    public static func sanitize(_ data: Data, distill: Bool, reassertInputModes: Bool) -> Data {
        var input = [UInt8](data)
        return input.withUnsafeMutableBufferPointer { bytes -> Data in
            var out = [UInt8](repeating: 0, count: bytes.count + 4096)
            var needed = out.withUnsafeMutableBufferPointer { buffer in
                slopdesk_sanitize(
                    bytes.baseAddress,
                    bytes.count,
                    distill,
                    reassertInputModes,
                    buffer.baseAddress,
                    buffer.count,
                )
            }
            if needed > out.count {
                out = [UInt8](repeating: 0, count: needed)
                needed = out.withUnsafeMutableBufferPointer { buffer in
                    slopdesk_sanitize(
                        bytes.baseAddress,
                        bytes.count,
                        distill,
                        reassertInputModes,
                        buffer.baseAddress,
                        buffer.count,
                    )
                }
            }
            guard needed > 0, needed <= out.count else { return Data() }
            return Data(out[0..<needed])
        }
    }

    // MARK: Derived signals

    /// Highest seq assigned so far (last produced `output.seq`). Starts at 0; the first output is 1.
    public var highestSeq: Int64 { slopdesk_replay_highest_seq(handle) }

    /// Highest contiguous seq the client has acked; entries up to here are released.
    public var ackedSeq: Int64 { slopdesk_replay_acked_seq(handle) }

    /// Sum of the payload sizes of all currently-retained (un-acked) entries.
    public var retainedBytes: Int { slopdesk_replay_retained_bytes(handle) }

    /// Monotonic mutation counter over the RING (acked history), guarding a detach-time fold splice.
    public var ringGeneration: UInt64 { slopdesk_replay_ring_generation(handle) }

    /// Whether the connection layer currently considers the client reachable. Drives the offline
    /// gate via ``shouldPauseDrain``.
    public var isClientOnline: Bool {
        get { slopdesk_replay_is_client_online(handle) }
        set { slopdesk_replay_set_client_online(handle, newValue) }
    }

    /// Whether the PTY relay should **pause draining** right now — `true` when the client is offline
    /// and retained bytes reached the offline gate, or when they reached the backup cap regardless.
    ///
    /// While `true` the host stops `read()`ing the PTY master, so the kernel buffer fills and
    /// backpressures the child: no droppable output is generated. This is what bounds memory while
    /// honouring the never-drop invariant.
    public var shouldPauseDrain: Bool { slopdesk_replay_should_pause_drain(handle) }

    /// The ``DrainState`` corresponding to ``shouldPauseDrain`` (the ET vocabulary).
    public var drainState: DrainState { shouldPauseDrain ? .skipped : .bufferedOnly }

    /// Effective caps for THIS buffer — injectable so the read-loop-pause wiring can be
    /// integration-tested at a tiny cap (no 256 MiB allocation) and a deployment could tune them.
    public var maxBackupBytesCap: Int { slopdesk_replay_max_backup_cap(handle) }
    public var offlineGateBytesCap: Int { slopdesk_replay_offline_gate_cap(handle) }

    /// Scrollback ring byte cap (0 = disabled). Independent of ``maxBackupBytesCap`` — the ring
    /// holds ACKED history only, so it never contributes to ``retainedBytes``.
    public var scrollbackBytesCap: Int { slopdesk_replay_scrollback_cap(handle) }

    // MARK: Spec API (primary)

    /// Appends a host→client output payload, assigning it the next monotonic seq (starting at 1),
    /// and retains it until acked.
    @discardableResult
    public func append(bytes: Data) -> Int64 {
        bytes.withUnsafeBytes { raw in
            slopdesk_replay_append(handle, raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count)
        }
    }

    /// Retained (un-acked) bytes with `seq > seq` — how far behind the head a subscriber that has
    /// confirmed up to `seq` actually is. O(log n) and copy-free on the Rust side; the existing
    /// "bytes above S" primitives materialise every payload, which a per-ack lag check cannot afford
    /// under the owner's replay lock.
    public func retainedBytes(above seq: Int64) -> Int {
        slopdesk_replay_retained_bytes_above(handle, seq)
    }

    /// Records a client ack, dropping retained entries with `seq <= seq`.
    ///
    /// Idempotent and monotonic; acking past ``highestSeq`` clamps. When the ring is enabled the
    /// acked prefix is MOVED into it rather than discarded, then trimmed to the cap line-aligned.
    public func ack(upTo seq: Int64) { slopdesk_replay_ack(handle, seq) }

    /// Retained output payloads with `seq > lastReceivedSeq`, ascending, RAW — the primitive behind
    /// control-channel snapshots. Never distilled.
    public func messages(after lastReceivedSeq: Int64) -> [(seq: Int64, bytes: Data)] {
        let count = slopdesk_replay_messages(handle, lastReceivedSeq)
        return (0..<count).map { index in
            (seq: slopdesk_replay_result_seq(handle, index), bytes: resultBytes(at: index))
        }
    }

    // MARK: Snapshot-replay source (state-transfer cold reattach)

    /// The raw material for a RENDERED-snapshot replay (`docs/DECISIONS.md` 2026-07-25
    /// state-transfer): the COMPLETE retained history plus the seq budget the rendered stream may
    /// ride.
    public struct SnapshotSource: Sendable {
        /// Ring + un-acked tail concatenated, oldest-first — the composer's model input.
        public let history: Data
        /// Seqs available to carry the rendered stream (strictly above `lastReceivedSeq`).
        public let replaySeqs: [Int64]
        /// Total bytes of the entries behind `replaySeqs`.
        public let replayBytes: Int
    }

    public func snapshotSource(after lastReceivedSeq: Int64) -> SnapshotSource {
        let replayBytes = slopdesk_replay_snapshot_source(handle, lastReceivedSeq)
        return SnapshotSource(history: blobSlot(), replaySeqs: seqSlot(), replayBytes: replayBytes)
    }

    /// Re-chunks a RENDERED snapshot stream across `seqs` (ascending, from
    /// ``snapshotSource(after:)``) — always covering the last seq so the ack it provokes releases
    /// every retained entry, exactly like the cold distilled replay.
    ///
    /// An instance method where the Swift original was `static`: the re-chunker writes into this
    /// buffer's message slot, and the one call site already holds the buffer it came from.
    public func rechunkSnapshot(_ data: Data, across seqs: [Int64]) -> [WireMessage] {
        let count = data.withUnsafeBytes { raw in
            seqs.withUnsafeBufferPointer { labels in
                slopdesk_replay_rechunk_snapshot(
                    handle,
                    raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count,
                    labels.baseAddress, labels.count,
                )
            }
        }
        return outputs(count)
    }

    // MARK: History canonicalization

    /// The frozen material for a detach-time ring fold: the acked ring's raw bytes, the seqs its
    /// canonical replacement may ride, and the generation guarding the splice.
    public struct RingFoldSource: Sendable {
        public let bytes: Data
        public let seqs: [Int64]
        public let generation: UInt64
    }

    /// Captures the ring for a detach-time fold, or `nil` when the ring is empty.
    public func ringFoldSource() -> RingFoldSource? {
        let generation = slopdesk_replay_ring_fold_source(handle)
        guard generation != UInt64.max else { return nil }
        return RingFoldSource(bytes: blobSlot(), seqs: seqSlot(), generation: generation)
    }

    /// Replaces the acked ring with `rendered` re-chunked across the original ring seqs — the
    /// detach-time fold that turns the NEXT cold compose from O(raw history) into O(rendered +
    /// delta), and collapses the ring's memory to the rendered size.
    ///
    /// Returns `false` without touching anything when the buffer has mutated since `source` was
    /// captured (a reattach adopted a snapshot, new acks moved entries in, eviction ran).
    @discardableResult
    public func adoptFoldedRing(_ rendered: Data, from source: RingFoldSource) -> Bool {
        rendered.withUnsafeBytes { raw in
            source.seqs.withUnsafeBufferPointer { labels in
                slopdesk_replay_adopt_folded_ring(
                    handle,
                    raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count,
                    labels.baseAddress, labels.count,
                    source.generation,
                )
            }
        }
    }

    /// Replaces the ENTIRE retained history (ring + un-acked tail) with the rendered snapshot stream
    /// EXACTLY as it was sent — "as if the host had emitted the rendered bytes all along". Chunks
    /// at/below ``ackedSeq`` become the ring; the rest become the un-acked tail, released by the
    /// client's acks exactly like the raw entries they replaced.
    ///
    /// Called right after a successful snapshot compose. Two loads it carries: the consumed
    /// detached-window backlog got NO seqs of its own and would otherwise vanish from every later
    /// cold replay; and the next compose parses the (small) rendered history instead of re-walking
    /// the full raw ring.
    public func adoptSnapshotReplay(_ messages: [WireMessage]) {
        slopdesk_replay_input_clear(handle)
        for message in messages {
            guard case let .output(seq, bytes) = message else { continue }
            bytes.withUnsafeBytes { raw in
                slopdesk_replay_input_push(
                    handle, seq, raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count,
                )
            }
        }
        slopdesk_replay_adopt_snapshot_replay(handle)
    }

    // MARK: Compatibility API (used by SlopDeskHost stub + transport)

    /// Assigns the next seq, retains the payload, and reports the resulting ``DrainState`` — the
    /// convenience form the host relay uses to act on backpressure in the same call.
    @discardableResult
    public func enqueueOutput(_ bytes: Data) -> (seq: Int64, drain: DrainState) {
        (append(bytes: bytes), drainState)
    }

    /// Records a client ack, releasing retained entries with `seq <= seq`. Synonym for
    /// ``ack(upTo:)``.
    public func acknowledge(upTo seq: Int64) { ack(upTo: seq) }

    /// Retained `output` messages with `seq > lastReceivedSeq`, in order, ready to re-send — the
    /// reconnect/reattach replay.
    ///
    /// With a ``scrollbackDistiller`` injected AND the replay reaching the scrollback ring (a COLD
    /// reattach), the scrollback portion is DISTILLED and RE-CHUNKED across the same seq range. For
    /// a FRESH client (`lastReceivedSeq == 0`) the un-acked tail is transformed with it, as one
    /// chronological stream — a client that has rendered nothing has no byte-exact continuity to
    /// protect, and a session that ran detached for hours would otherwise replay seconds of raw
    /// live-TUI churn and then render it wrong at the new geometry. A warm reconnect always gets the
    /// raw tail: its grid is live mid-stream and transformed bytes would corrupt it.
    public func replay(after lastReceivedSeq: Int64) -> [WireMessage] {
        outputs(slopdesk_replay_replay(handle, lastReceivedSeq))
    }

    // MARK: Reading the handle's slots

    /// The message slot as `.output` wire messages.
    private func outputs(_ count: Int) -> [WireMessage] {
        (0..<count).map { index in
            .output(seq: slopdesk_replay_result_seq(handle, index), bytes: resultBytes(at: index))
        }
    }

    /// One message payload. Length first, then one copy — the slot is stable between the two.
    private func resultBytes(at index: Int) -> Data {
        let length = slopdesk_replay_result_len(handle, index)
        guard length > 0 else { return Data() }
        var payload = Data(count: length)
        let copied = payload.withUnsafeMutableBytes { raw in
            slopdesk_replay_result_copy(
                handle, index, raw.baseAddress?.assumingMemoryBound(to: UInt8.self), length,
            )
        }
        return copied == length ? payload : Data()
    }

    private func blobSlot() -> Data {
        let length = slopdesk_replay_blob_len(handle)
        guard length > 0 else { return Data() }
        var payload = Data(count: length)
        let copied = payload.withUnsafeMutableBytes { raw in
            slopdesk_replay_blob_copy(
                handle, raw.baseAddress?.assumingMemoryBound(to: UInt8.self), length,
            )
        }
        return copied == length ? payload : Data()
    }

    private func seqSlot() -> [Int64] {
        let count = slopdesk_replay_seqs_count(handle)
        guard count > 0 else { return [] }
        var values = [Int64](repeating: 0, count: count)
        let copied = values.withUnsafeMutableBufferPointer { buffer in
            slopdesk_replay_seqs_copy(handle, buffer.baseAddress, buffer.count)
        }
        return copied == count ? values : []
    }

    // MARK: Test seams (scrollback ring inspection)

    /// Number of entries currently in the scrollback ring. For tests only.
    public var scrollbackRingCountForTesting: Int { slopdesk_replay_ring_len(handle) }

    /// Total bytes currently in the scrollback ring. For tests only.
    public var scrollbackRingBytesForTesting: Int { slopdesk_replay_ring_bytes(handle) }

    /// The seq values in the scrollback ring, oldest-first. For tests only.
    public var scrollbackRingSeqsForTesting: [Int64] {
        _ = slopdesk_replay_ring_seqs(handle)
        return seqSlot()
    }

    /// The leading bytes of the oldest scrollback ring entry (to verify line-alignment). For tests
    /// only. `nil` exactly when the ring is empty — an entry that IS empty answers empty `Data`.
    public var scrollbackRingOldestBytesForTesting: Data? {
        guard slopdesk_replay_ring_len(handle) > 0 else { return nil }
        let length = slopdesk_replay_ring_oldest(handle, nil, 0)
        guard length > 0 else { return Data() }
        var payload = Data(count: length)
        let copied = payload.withUnsafeMutableBytes { raw in
            slopdesk_replay_ring_oldest(
                handle, raw.baseAddress?.assumingMemoryBound(to: UInt8.self), length,
            )
        }
        return copied == length ? payload : Data()
    }
}
