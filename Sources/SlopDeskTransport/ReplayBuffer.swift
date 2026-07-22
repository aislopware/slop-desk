import Foundation
import SlopDeskProtocol

/// Host-side replay buffer for lossless reconnect — an SlopDesk-native port of
/// Eternal Terminal's `BackedWriter` over plain TCP.
///
/// **Pure logic**: no networking dependency, unit-testable in isolation. Retains
/// host→client `output` payloads keyed by a monotonic `Int64` seq until the client
/// acks them, and produces the un-acked tail for replay on reconnect.
///
/// ## Why
/// iOS kills the TCP connection seconds after backgrounding. To resume **byte-exact**
/// without tmux, the host retains sent `output` payloads keyed by their monotonic
/// `Int64` seq; on reconnect the client's `hello.lastReceivedSeq` tells the host which
/// tail to replay (`seq > lastReceivedSeq`). Equivalent to ET's byte-level `BackedWriter`
/// seq, lifted to a **per-message** seq (see `docs/20-wire-protocol.md`).
///
/// **Only `.output` is sequenced and replayed.** Control messages
/// (`resize`/`ack`/`title`/`bell`/…) are lifecycle/metadata, not retained: re-deriving
/// size or re-sending a title on reconnect is cheap and stateless; PTY output is the
/// irreplaceable byte stream.
///
/// ## Caps, gates, and the load-bearing invariant
/// - **`maxBackupBytes` = 256 MiB** (4× ET `MAX_BACKUP_BYTES` — coding-tool hosts are ≥32 GB): retained-byte ceiling we
///   *aim* to stay under.
/// - **`offlineGateBytes` = 64 MiB**: while offline, once retained bytes reach this gate
///   ``shouldPauseDrain`` flips `true` (ET `SKIPPED`); below it the host keeps buffering
///   (ET `BUFFERED_ONLY`).
/// - **INVARIANT — never silently drop un-acked data.** Dropping un-acked output to meet
///   the 256 MiB cap would break byte-exact resume (an unrecoverable client gap), so the
///   buffer **never evicts un-acked entries**. Offline memory is bounded *instead* by
///   ``shouldPauseDrain``: when asserted, the host relay stops reading the PTY, so
///   the kernel PTY buffer backpressures the shell and **no droppable output is produced**.
/// - **INVARIANT — dead-channel send = retain, never throw.** A retained entry is removed
///   only by a client ``ack(upTo:)``, never by a failed wire send. The host relay retains
///   the bytes (``append(bytes:)``) BEFORE sending, so if a live send loses its channel
///   (data channel cancelled mid-flight — POSIX 89) the entry stays retained and is re-sent
///   by the next ``replay(after:)``. This lets the host treat a dead-channel send as
///   "client offline → replay later" with zero byte loss, not a fatal fault.
/// - **Slow-consumer case (online but acking slowly):** if retained bytes exceed
///   `maxBackupBytes` while online, ``shouldPauseDrain`` asserts *anyway* — still no drop;
///   we pause draining until acks catch up. No path discards un-acked output.
///
/// - Seq is **`Int64`** (ET proto2 used int32, which truncates on very long sessions).
/// - **No `CryptoHandler`.** WireGuard already encrypts; the buffer stores raw bytes.
///   Do not reintroduce ET's libsodium secretbox / nonce-reset layer here
///   ([18](../../docs/18-risk-resolutions.md) §H).
///
/// `ReplayBuffer` is a `Sendable` value type: the owning host relay holds it as stored state
/// and mutates it under a lock / actor isolation; the derived ``shouldPauseDrain`` drives the
/// PTY read-loop pause. The pure value type is what makes its invariants exhaustively testable
/// without a socket.
public struct ReplayBuffer: Sendable {
    /// Retained-byte ceiling: 256 MiB (4× ET `MAX_BACKUP_BYTES`).
    public static let maxBackupBytes = 256 * 1024 * 1024

    /// Offline buffering gate: 64 MiB. At/above this while offline, pause the PTY drain.
    public static let offlineGateBytes = 64 * 1024 * 1024

    /// Default scrollback ring size: 64 MiB (override with `SLOPDESK_SCROLLBACK_BYTES`).
    ///
    /// Retains ACKED entries (history) separately from the un-acked live tail, so a cold-reattach
    /// replay can deliver the full visible scrollback to a fresh terminal — like `tmux attach-session`.
    /// Bounded, evicted line-aligned so a replay never starts mid-escape-sequence. Disable entirely
    /// with `SLOPDESK_SCROLLBACK_PERSIST=0`.
    public static let defaultScrollbackBytes = 64 * 1024 * 1024

    /// Action signalled to the PTY relay as output is enqueued.
    ///
    /// Mirrors ET's `BackedWriter` `BufferState`: `bufferedOnly` = keep draining/buffering;
    /// `skipped` = stop draining (offline gate crossed) so the kernel backpressures the shell
    /// instead of buffering unboundedly.
    public enum DrainState: Sendable, Equatable {
        /// Keep buffering and draining the PTY normally (below the gate, or online).
        case bufferedOnly
        /// Gate exceeded — pause draining the PTY until the client catches up / returns.
        case skipped
    }

    // MARK: Stored state

    /// One retained host→client output payload and its assigned seq.
    private struct Entry {
        let seq: Int64
        let bytes: Data
    }

    /// Un-acked retained entries, in ascending seq order (FIFO; oldest at the front).
    private var entries: [Entry] = []

    /// Scrollback ring: acked entries kept for cold-reattach replay, oldest-at-front.
    ///
    /// Bounded by ``scrollbackBytesCap``. Eviction is LINE-ALIGNED: when the oldest surviving
    /// entry would split a line, the cursor advances to the next `\n` so a cold replay never
    /// starts mid-escape-sequence. Separate from `entries` (un-acked) so the never-drop invariant
    /// on un-acked data is untouched.
    private var scrollbackRing: [Entry] = []

    /// Running byte total in ``scrollbackRing``.
    private var scrollbackBytes: Int = 0

    /// Highest seq assigned so far (last produced `output.seq`). Starts at 0; the
    /// first output is seq 1.
    public private(set) var highestSeq: Int64 = 0

    /// Highest contiguous seq the client has acked; entries up to here are released.
    public private(set) var ackedSeq: Int64 = 0

    /// Sum of `bytes.count` over all currently-retained (un-acked) entries.
    ///
    /// Maintained incrementally on every ``append(bytes:)`` / ``ack(upTo:)`` — O(1) to read,
    /// always equal to the true retained total.
    public private(set) var retainedBytes: Int = 0

    /// Whether the connection layer currently considers the client reachable.
    ///
    /// Set by the transport when a channel becomes ready (`true`) or fails/cancels
    /// (`false`). Drives the offline gate via ``shouldPauseDrain``.
    public var isClientOnline: Bool = true

    /// Effective caps for THIS buffer. Default to the ET constants (``maxBackupBytes`` /
    /// ``offlineGateBytes``); injectable so the read-loop-pause wiring can be integration-tested
    /// at a tiny cap (no 256 MiB allocation) and a deployment could tune them.
    public let maxBackupBytesCap: Int
    public let offlineGateBytesCap: Int

    /// Scrollback ring byte cap (0 = disabled). Injected from `SLOPDESK_SCROLLBACK_BYTES`
    /// (default ``defaultScrollbackBytes`` = 64 MiB). Independent of ``maxBackupBytesCap`` — the
    /// ring holds ACKED history only, so it never contributes to ``retainedBytes`` or the
    /// offline-gate / 256 MiB live-tail guarantees.
    public let scrollbackBytesCap: Int

    /// Optional COLD-reattach scrollback cleaner (host injects an OSC-133 distiller). When present,
    /// ``replay(after:)`` runs it over the history portion of a cold replay to collapse the
    /// transient B→C line-editor churn (completion menus, autosuggestions, per-keystroke redraws) to
    /// the committed command line — see ``ScrollbackDistiller``. `nil` ⇒ ring replays raw (all transport
    /// tests default to this). The un-acked live tail is included ONLY for a FRESH client
    /// (`lastReceivedSeq == 0` — nothing rendered yet, so no byte-exact continuity to protect);
    /// a warm reconnect always gets the raw tail. ``messages(after:)`` (the raw primitive for
    /// control-channel snapshots) is never touched.
    public let scrollbackDistiller: (@Sendable (Data) -> Data)?

    @preconcurrency
    public init(
        maxBackupBytes: Int = Self.maxBackupBytes,
        offlineGateBytes: Int = Self.offlineGateBytes,
        scrollbackBytes: Int = Self.defaultScrollbackBytes,
        scrollbackDistiller: (@Sendable (Data) -> Data)? = nil,
    ) {
        maxBackupBytesCap = max(0, maxBackupBytes)
        offlineGateBytesCap = max(0, offlineGateBytes)
        scrollbackBytesCap = max(0, scrollbackBytes)
        self.scrollbackDistiller = scrollbackDistiller
    }

    // MARK: Derived signals

    /// Whether the PTY relay should **pause draining** right now.
    ///
    /// `true` when either:
    /// 1. the client is **offline** and retained bytes reached ``offlineGateBytes`` (64 MiB)
    ///    — the ET `SKIPPED` state; or
    /// 2. retained bytes reached ``maxBackupBytes`` (256 MiB) regardless of online state — the
    ///    slow-consumer guard; still never drop un-acked data, hold the pause until acks drain.
    ///
    /// While `true` the host stops `read()`ing the PTY master, so the kernel PTY buffer
    /// fills and backpressures the child — no droppable output is generated. This is what bounds
    /// memory while honoring the never-drop invariant.
    public var shouldPauseDrain: Bool {
        if retainedBytes >= maxBackupBytesCap { return true }
        if !isClientOnline, retainedBytes >= offlineGateBytesCap { return true }
        return false
    }

    /// The ``DrainState`` corresponding to ``shouldPauseDrain`` (the ET vocabulary).
    public var drainState: DrainState {
        shouldPauseDrain ? .skipped : .bufferedOnly
    }

    // MARK: Spec API (primary)

    /// Appends a host→client output payload, assigning it the next monotonic seq
    /// (`highestSeq + 1`, starting at 1), and retains it until acked.
    ///
    /// - Parameter bytes: the raw PTY output payload (no framing, no seq prefix).
    /// - Returns: the seq assigned to this payload.
    @discardableResult
    public mutating func append(bytes: Data) -> Int64 {
        highestSeq += 1
        entries.append(Entry(seq: highestSeq, bytes: bytes))
        retainedBytes += bytes.count
        return highestSeq
    }

    /// Records a client ack, dropping retained entries with `seq <= seq` and updating
    /// ``retainedBytes``.
    ///
    /// Idempotent and monotonic: a stale/duplicate ack (`seq <= ackedSeq`) is a no-op;
    /// ``ackedSeq`` only advances. Acking past ``highestSeq`` clears everything but CLAMPS
    /// `ackedSeq` to ``highestSeq``: the ack seq arrives unvalidated off the
    /// wire (WireMessage case 12 → MuxChannelSession → here), and an unclamped far-future value
    /// (e.g. `Int64.max` from a buggy/corrupt peer) would make every later legitimate ack fall
    /// into the `seq <= ackedSeq` no-op, so nothing is ever released again — append() accumulates
    /// to ``maxBackupBytesCap`` and ``shouldPauseDrain`` wedges the PTY drain permanently.
    ///
    /// When ``scrollbackBytesCap`` > 0, the acked prefix is MOVED into ``scrollbackRing`` (for
    /// cold-reattach replay) rather than discarded; ``evictScrollbackToFit()`` trims the ring to
    /// the cap line-aligned. ``entries`` and ``retainedBytes`` update as in the pre-scrollback
    /// behaviour — the never-drop invariant on un-acked data is preserved.
    public mutating func ack(upTo seq: Int64) {
        // Clamp untrusted wire input: an ack can never legitimately exceed what we produced.
        let clamped = min(seq, highestSeq)
        guard clamped > ackedSeq else { return }
        ackedSeq = clamped
        // entries are ascending by seq; identify the released prefix.
        var dropCount = 0
        var releasedBytes = 0
        for entry in entries {
            if entry.seq <= clamped {
                dropCount += 1
                releasedBytes += entry.bytes.count
            } else {
                break
            }
        }
        guard dropCount > 0 else { return }
        if scrollbackBytesCap > 0 {
            // Move the acked prefix into the ring (retain for cold replay).
            for entry in entries.prefix(dropCount) {
                scrollbackRing.append(entry)
                scrollbackBytes += entry.bytes.count
            }
            evictScrollbackToFit()
        }
        entries.removeFirst(dropCount)
        retainedBytes -= releasedBytes
    }

    /// Evicts the OLDEST scrollback entries until `scrollbackBytes <= scrollbackBytesCap`.
    ///
    /// LINE-ALIGNED: after an eviction lands at/under the cap, the new oldest entry may start
    /// mid-line (the evicted chunk was the tail of a \n-terminated sequence). Trim its front to
    /// the next `\n` + 1 so a cold replay starts on a clean line boundary, never mid-escape-sequence.
    /// If the new oldest has no `\n`, leave it intact (next cycle removes it if still over cap; a
    /// line longer than the cap can't be split usefully, and the following entry already starts clean).
    private mutating func evictScrollbackToFit() {
        guard scrollbackBytes > scrollbackBytesCap, !scrollbackRing.isEmpty else { return }
        // Count the eviction prefix WITHOUT mutating, then remove it in ONE bulk removeFirst:
        // per-entry removeFirst() in a loop would be O(k*n) memmoves under the shared replayLock.
        // The mux FIFO in ack(upTo:) uses the same bulk idiom.
        var dropCount = 0
        var droppedBytes = 0
        while scrollbackBytes - droppedBytes > scrollbackBytesCap, dropCount < scrollbackRing.count {
            droppedBytes += scrollbackRing[dropCount].bytes.count
            dropCount += 1
        }
        scrollbackRing.removeFirst(dropCount)
        scrollbackBytes -= droppedBytes
        // Landed at/under cap: line-align the new oldest so the ring never starts mid-escape-sequence.
        if scrollbackBytes <= scrollbackBytesCap, !scrollbackRing.isEmpty {
            let head = scrollbackRing[0]
            if let nlIdx = head.bytes.firstIndex(of: UInt8(ascii: "\n")) {
                let afterNL = head.bytes.index(after: nlIdx)
                let trimmed = Data(head.bytes[afterNL...])
                let removed = head.bytes.count - trimmed.count
                scrollbackRing[0] = Entry(seq: head.seq, bytes: trimmed)
                scrollbackBytes -= removed
            }
            // No \n: leave intact — replay starts at this entry's beginning, a PTY-read chunk boundary.
        }
    }

    /// Returns retained output payloads with `seq > lastReceivedSeq`, ascending, for replay
    /// after reconnect.
    ///
    /// ### Replay semantics
    ///
    /// **Cold reattach** (`lastReceivedSeq == 0`, or below the oldest scrollback entry): returns
    /// all ``scrollbackRing`` entries with seq > lastReceivedSeq, then all un-acked ``entries``.
    /// The fresh client re-renders the full scrollback, like `tmux attach-session`.
    ///
    /// **Warm reconnect** (`lastReceivedSeq` at/near the live frontier): ring entries all have
    /// `seq ≤ ackedSeq ≤ lastReceivedSeq`, so the filter drops them all; only the un-acked tail
    /// returns — identical to the pre-scrollback implementation.
    ///
    /// **Ring-wrapped edge** (ring wrapped past the reconnect point): `entry.seq > lastReceivedSeq`
    /// selects whatever ring entries survive; the client's `highestSeqFed` dedup (deliverOutput
    /// guard) drops any seq ≤ highestSeqFed, so no duplicate is possible.
    ///
    /// - `messages(after: 0)` returns the whole scrollback ring PLUS the un-acked tail.
    /// - `messages(after: highestSeq)` returns empty (client is current).
    /// - Un-acked entries in ``entries`` are never absent (never-drop invariant).
    public func messages(after lastReceivedSeq: Int64) -> [(seq: Int64, bytes: Data)] {
        var result: [(seq: Int64, bytes: Data)] = []
        // 1. From the scrollback ring (acked history, oldest-first).
        for entry in scrollbackRing where entry.seq > lastReceivedSeq {
            result.append((seq: entry.seq, bytes: entry.bytes))
        }
        // 2. From the un-acked live tail.
        for entry in entries where entry.seq > lastReceivedSeq {
            result.append((seq: entry.seq, bytes: entry.bytes))
        }
        return result
    }

    // MARK: Compatibility API (used by SlopDeskHost stub + transport)

    /// Assigns the next seq, retains the payload, and reports the resulting ``DrainState`` — the
    /// convenience form the host relay uses to act on backpressure in the same call.
    ///
    /// - Returns: the assigned seq and the resulting ``DrainState``.
    @discardableResult
    public mutating func enqueueOutput(_ bytes: Data) -> (seq: Int64, drain: DrainState) {
        let seq = append(bytes: bytes)
        return (seq, drainState)
    }

    /// Records a client ack, releasing retained entries with `seq <= seq`.
    /// Synonym for ``ack(upTo:)``.
    public mutating func acknowledge(upTo seq: Int64) {
        ack(upTo: seq)
    }

    /// Returns retained `output` messages with `seq > lastReceivedSeq`, in order, wrapped as
    /// ``WireMessage/output(seq:bytes:)`` ready to re-send — the reconnect/reattach replay.
    ///
    /// When a ``scrollbackDistiller`` is injected AND the replay reaches the scrollback ring (a COLD
    /// reattach — `lastReceivedSeq` below the acked frontier), the scrollback portion is DISTILLED
    /// (transient B→C editing churn collapsed to the committed command) and RE-CHUNKED across the same
    /// seq range (distilled bytes ≤ raw, so chunk count never exceeds entry count → seqs stay ascending
    /// and strictly below the un-acked tail).
    ///
    /// **FRESH client (`lastReceivedSeq == 0`)**: the un-acked live tail is history to a client
    /// that has rendered nothing — there is no byte-exact continuity to protect, and a session
    /// that ran detached for hours retains up to the offline gate (64 MiB) of raw live-TUI churn
    /// (Claude Code repaint frames) that would replay for seconds and then render wrong at the
    /// new geometry. Ring + tail are therefore transformed as ONE chronological stream and
    /// re-chunked across the combined seq range; the LAST emitted chunk always carries the
    /// highest tail seq, so the client's ack releases every retained entry (the transform can
    /// shrink the byte count below the seq count — an unsent top seq would otherwise strand
    /// un-acked bytes against the 256 MiB pause gate forever).
    ///
    /// **Warm reconnect (`lastReceivedSeq > 0`)**: the un-acked tail is ALWAYS re-sent RAW —
    /// the client's grid is live mid-stream and transformed bytes would corrupt it. Without a
    /// distiller this is byte-identical to `messages(after:)` mapped to `.output`.
    public func replay(after lastReceivedSeq: Int64) -> [WireMessage] {
        let scrollback = scrollbackRing.filter { $0.seq > lastReceivedSeq }
        if let scrollbackDistiller, lastReceivedSeq == 0, !entries.isEmpty {
            // COLD replay to a fresh client — transform ring + tail as one stream.
            var raw = Data()
            for entry in scrollback { raw.append(entry.bytes) }
            for entry in entries { raw.append(entry.bytes) }
            let cleaned = scrollbackDistiller(raw)
            let seqs = scrollback.map(\.seq) + entries.map(\.seq)
            return Self.rechunk(cleaned, across: seqs, mustCoverLastSeq: true)
        }
        var result: [WireMessage] = []
        if let scrollbackDistiller, !scrollback.isEmpty {
            var raw = Data()
            for entry in scrollback { raw.append(entry.bytes) }
            let cleaned = scrollbackDistiller(raw)
            result.append(contentsOf: Self.rechunk(cleaned, across: scrollback.map(\.seq)))
        } else {
            for entry in scrollback { result.append(.output(seq: entry.seq, bytes: entry.bytes)) }
        }
        // Un-acked live tail — raw (byte-exact resume of in-flight output on a warm grid).
        for entry in entries where entry.seq > lastReceivedSeq {
            result.append(.output(seq: entry.seq, bytes: entry.bytes))
        }
        return result
    }

    /// Splits `data` (distilled scrollback) into at most `seqs.count` `.output` messages, assigning the
    /// scrollback seqs ascending. `data.count <= sum(original entry sizes)`, so at chunk size
    /// `ceil(count / maxChunks)` the chunk count is `<= maxChunks`; the LAST allowed chunk
    /// absorbs the remainder so every byte is emitted and no seq is reused. Empty `data` ⇒ no messages
    /// (the client's forward-jump tolerance in `deliverOutput` handles the seq gap).
    ///
    /// `mustCoverLastSeq` (the cold fresh-client replay, where `seqs` includes UN-ACKED tail seqs):
    /// the final emitted message is relabeled to `seqs.last` — ascending order holds (every earlier
    /// chunk uses a strictly lower seq from the same list) and the client's `deliverOutput` accepts
    /// the forward jump — so the ack that follows releases the entire retained tail. With empty
    /// `data` an empty `.output` still carries `seqs.last` for the same reason.
    ///
    /// The chunk size is CLAMPED to ``MuxFlowControl/maxOutputFramePayloadBytes``: every emitted
    /// frame must satisfy the credit progress invariant (wire bytes ≤ window/2), exactly like the
    /// live drain's `takeMergedFrame` cap. Without the clamp, the `max(32 KiB, …)` floor alone can
    /// emit 32768-byte payloads — 32781 wire bytes, 13 over window/2: the "dead zone" that can park
    /// the sender against a receiver whose pending credit never crosses the grant threshold (a
    /// silent pane right after cold reattach). The clamp is safe on the seq budget: every ring entry was appended at
    /// ≤ the same cap, so `ceil(count / maxChunks)` ≤ cap and the chunk count stays
    /// ≤ `maxChunks` even at the clamped size; the last-chunk absorb then never exceeds the
    /// cap either.
    private static func rechunk(
        _ data: Data, across seqs: [Int64], mustCoverLastSeq: Bool = false,
    ) -> [WireMessage] {
        guard !seqs.isEmpty else { return [] }
        guard !data.isEmpty else {
            // No bytes, but a cold-tail replay must still deliver the top seq — un-acked
            // entries release only on the ack this message provokes.
            return mustCoverLastSeq ? [.output(seq: seqs[seqs.count - 1], bytes: Data())] : []
        }
        let maxChunks = seqs.count
        let chunkSize = min(
            MuxFlowControl.maxOutputFramePayloadBytes,
            max(32 * 1024, (data.count + maxChunks - 1) / maxChunks),
        )
        var result: [WireMessage] = []
        var start = data.startIndex
        var k = 0
        while start < data.endIndex, k < maxChunks {
            let isLast = k == maxChunks - 1
            let end = isLast
                ? data.endIndex
                : (data.index(start, offsetBy: chunkSize, limitedBy: data.endIndex) ?? data.endIndex)
            result.append(.output(seq: seqs[k], bytes: Data(data[start..<end])))
            start = end
            k += 1
        }
        if mustCoverLastSeq, case let .output(seq, bytes) = result[result.count - 1],
           seq != seqs[seqs.count - 1]
        {
            result[result.count - 1] = .output(seq: seqs[seqs.count - 1], bytes: bytes)
        }
        return result
    }

    // MARK: Test seams (scrollback ring inspection)

    /// Number of entries currently in the scrollback ring. For tests only.
    public var scrollbackRingCountForTesting: Int { scrollbackRing.count }

    /// Total bytes currently in the scrollback ring. For tests only.
    public var scrollbackRingBytesForTesting: Int { scrollbackBytes }

    /// The seq values in the scrollback ring, oldest-first. For tests only.
    public var scrollbackRingSeqsForTesting: [Int64] { scrollbackRing.map(\.seq) }

    /// The leading bytes of the oldest scrollback ring entry (to verify line-alignment). For tests only.
    public var scrollbackRingOldestBytesForTesting: Data? { scrollbackRing.first?.bytes }
}
