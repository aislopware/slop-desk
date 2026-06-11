import Foundation
import AislopdeskProtocol

/// Host-side replay buffer for lossless reconnect — an Aislopdesk-native port of
/// Eternal Terminal's `BackedWriter` over plain TCP.
///
/// This is **pure logic**: it has no networking dependency and is unit-testable in
/// isolation. It retains host→client `output` payloads keyed by a monotonic
/// `Int64` seq until the client acks them, and produces the un-acked tail for
/// replay on reconnect.
///
/// ## Why
/// iOS kills the TCP connection a few seconds after backgrounding. To resume
/// **byte-exact** without tmux, the host retains recently-sent `output` payloads
/// keyed by their monotonic `Int64` seq. On reconnect the client's
/// `hello.lastReceivedSeq` tells the host which tail to replay (everything with
/// `seq > lastReceivedSeq`). This is functionally equivalent to ET's byte-level
/// `BackedWriter` seq, lifted to a **per-message** seq (see `docs/20-wire-protocol.md`).
///
/// **Only `.output` is sequenced and replayed.** Control messages
/// (`resize`/`ack`/`title`/`bell`/…) are lifecycle/metadata and are *not* retained:
/// re-deriving terminal size or re-sending a title on reconnect is cheap and stateless
/// on the host side, whereas PTY output is the irreplaceable byte stream.
///
/// ## Caps, gates, and the load-bearing invariant
/// - **`maxBackupBytes` = 64 MiB** (ET `MAX_BACKUP_BYTES`): the retained-byte ceiling
///   we *aim* to stay under.
/// - **`offlineGateBytes` = 4 MiB**: while the client is offline, once retained bytes
///   reach this gate, ``shouldPauseDrain`` flips `true` (ET `SKIPPED`); below it the
///   host keeps buffering (ET `BUFFERED_ONLY`).
/// - **INVARIANT — never silently drop un-acked data.** Dropping un-acked output to
///   satisfy the 64 MiB cap would break byte-exact resume (the client would see a gap
///   it can never recover). So this buffer **never evicts un-acked entries**. Memory
///   while the client is offline is bounded *instead* by ``shouldPauseDrain``: when it
///   is asserted, the host relay (WF-3) stops reading the PTY, so the kernel PTY buffer
///   backpressures the shell and **no output is produced that we'd have to drop**.
/// - **INVARIANT — dead-channel send = retain, never throw.** A retained entry is only
///   ever removed by a client ``ack(upTo:)``; a *failed wire send* never evicts it.
///   The host relay retains the bytes (via ``append(bytes:)``) BEFORE the send. So if a
///   live send loses its channel (the data channel is cancelled mid-flight — POSIX 89),
///   the entry stays retained and is re-sent by the next ``replay(after:)``. This is what
///   lets the host treat a dead-channel send as "client offline → replay later" instead of
///   a fatal fault, with zero byte loss.
/// - **Slow-consumer case (client online but acking slowly):** if retained bytes exceed
///   `maxBackupBytes` while online, ``shouldPauseDrain`` is asserted *anyway* (see its
///   doc) — we still refuse to drop un-acked data; we pause draining until the client
///   catches up via `ack`. There is no path that discards un-acked output.
///
/// - Seq is **`Int64`** (ET proto2 used int32, which truncates on very long sessions).
/// - **No `CryptoHandler`.** WireGuard already encrypts; the buffer stores raw bytes.
///   Do not reintroduce ET's libsodium secretbox / nonce-reset layer here
///   ([18](../../docs/18-risk-resolutions.md) §H).
///
/// `ReplayBuffer` is a `Sendable` value type. The owning host relay holds it as stored state
/// and mutates it under a lock / actor isolation; the derived ``shouldPauseDrain`` signal drives
/// the PTY read-loop pause. Keeping the buffer a pure value type is what makes its invariants
/// exhaustively testable without standing up a socket.
public struct ReplayBuffer: Sendable {
    /// Retained-byte ceiling: 64 MiB (ET `MAX_BACKUP_BYTES`).
    public static let maxBackupBytes = 64 * 1024 * 1024

    /// Offline buffering gate: 4 MiB. At/above this while offline, pause the PTY drain.
    public static let offlineGateBytes = 4 * 1024 * 1024

    /// Action signalled to the PTY relay as output is enqueued.
    ///
    /// This mirrors ET's `BackedWriter` `BufferState`: `bufferedOnly` = keep draining
    /// the PTY and buffering output; `skipped` = stop draining the PTY (the offline
    /// gate was crossed) so the kernel backpressures the shell instead of us buffering
    /// unboundedly.
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

    /// Highest seq assigned so far (last produced `output.seq`). Starts at 0; the
    /// first output is seq 1.
    public private(set) var highestSeq: Int64 = 0

    /// Highest contiguous seq the client has acked; entries up to here are released.
    public private(set) var ackedSeq: Int64 = 0

    /// Sum of `bytes.count` over all currently-retained (un-acked) entries.
    ///
    /// This is maintained incrementally on every ``append(bytes:)`` / ``ack(upTo:)``
    /// so it is O(1) to read and always equals the true retained total.
    public private(set) var retainedBytes: Int = 0

    /// Whether the connection layer currently considers the client reachable.
    ///
    /// Set by the transport when a channel becomes ready (`true`) or fails/cancels
    /// (`false`). Drives the offline gate via ``shouldPauseDrain``.
    public var isClientOnline: Bool = true

    /// The effective caps for THIS buffer. Default to the ET constants
    /// (``maxBackupBytes`` / ``offlineGateBytes``); injectable so the relay's read-loop-pause wiring can
    /// be integration-tested at a tiny cap (no 64 MiB allocation) and so a deployment could tune them.
    public let maxBackupBytesCap: Int
    public let offlineGateBytesCap: Int

    public init(
        maxBackupBytes: Int = ReplayBuffer.maxBackupBytes,
        offlineGateBytes: Int = ReplayBuffer.offlineGateBytes
    ) {
        self.maxBackupBytesCap = max(0, maxBackupBytes)
        self.offlineGateBytesCap = max(0, offlineGateBytes)
    }

    // MARK: Derived signals

    /// Whether the PTY relay should **pause draining** the PTY right now.
    ///
    /// `true` when either:
    /// 1. the client is **offline** and retained bytes have reached
    ///    ``offlineGateBytes`` (4 MiB) — the ET `SKIPPED` state; or
    /// 2. retained bytes have reached ``maxBackupBytes`` (64 MiB) regardless of
    ///    online state — the slow-consumer guard. We still never drop un-acked data;
    ///    we hold the pause until acks drain the backlog.
    ///
    /// When this is `true` the host (WF-3) stops `read()`ing the PTY master, so the
    /// kernel PTY buffer fills and backpressures the child — no output is generated
    /// that we would otherwise have to drop. This is the mechanism that bounds memory
    /// while honoring the never-drop invariant.
    public var shouldPauseDrain: Bool {
        if retainedBytes >= maxBackupBytesCap { return true }
        if !isClientOnline && retainedBytes >= offlineGateBytesCap { return true }
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

    /// Records a client ack, dropping all retained entries with `seq <= seq` and
    /// updating ``retainedBytes``.
    ///
    /// Idempotent and monotonic: a stale or duplicate ack (`seq <= ackedSeq`) is a
    /// no-op; ``ackedSeq`` only ever advances. Acking past ``highestSeq`` simply
    /// clears everything and pins `ackedSeq` to the requested value (harmless — the
    /// next `append` still produces `highestSeq + 1`).
    public mutating func ack(upTo seq: Int64) {
        guard seq > ackedSeq else { return }
        ackedSeq = seq
        // entries are ascending by seq; drop the released prefix.
        var dropCount = 0
        var releasedBytes = 0
        for entry in entries {
            if entry.seq <= seq {
                dropCount += 1
                releasedBytes += entry.bytes.count
            } else {
                break
            }
        }
        if dropCount > 0 {
            entries.removeFirst(dropCount)
            retainedBytes -= releasedBytes
        }
    }

    /// Returns the retained output payloads with `seq > lastReceivedSeq`, in
    /// ascending seq order, for replay after reconnect.
    ///
    /// - `messages(after: 0)` returns the entire retained tail.
    /// - `messages(after: highestSeq)` returns an empty array (client is current).
    /// - Entries already released by ``ack(upTo:)`` are gone and never returned.
    public func messages(after lastReceivedSeq: Int64) -> [(seq: Int64, bytes: Data)] {
        entries
            .filter { $0.seq > lastReceivedSeq }
            .map { (seq: $0.seq, bytes: $0.bytes) }
    }

    // MARK: Compatibility API (used by AislopdeskHost WF-3 stub + transport)

    /// Assigns the next monotonic seq, retains the payload, and reports the resulting
    /// ``DrainState`` — the convenience form the host relay consumes so it can act on
    /// backpressure in the same call that produces the seq.
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

    /// Returns the retained `output` messages with `seq > lastReceivedSeq`, in order,
    /// already wrapped as ``WireMessage/output(seq:bytes:)`` ready to re-send.
    public func replay(after lastReceivedSeq: Int64) -> [WireMessage] {
        messages(after: lastReceivedSeq).map { WireMessage.output(seq: $0.seq, bytes: $0.bytes) }
    }
}
