import CSlopDeskFFI
import Foundation
import SlopDeskProtocol

/// The Swift face of `rust/slopdesk-muxsession`'s `outbox`, reached through the `pane_outbox` door.
///
/// One pane's outbound frame queue. hostd's read loop appends a chunk per supervised read and ONE
/// drain pops, but what it pops is not what was appended: adjacent chunks COALESCE up to the
/// credit-safe frame cap so a flood costs one seq/encode/envelope/send round instead of N; an
/// over-cap head SPLITS so the 13-byte `.output` header can never push a frame past the receiver's
/// grant threshold; and `.exit` is a merge BARRIER, which is what keeps the reaper's exit code
/// strictly after the final output tail.
///
/// **The bytes never cross.** The far side holds `(slot, len)` and answers which slots make up the
/// next frame; this side holds the `Data` and does the concatenation where that `Data` already is.
/// docs/55 §4c prices a door that materialized a `Data` per 32 KiB chunk at 227.5 ns against a
/// crossing's 1.0 — which is why the verdict names lengths and slots, and nothing else.
///
/// **A run is CONSECUTIVE**, so the verdict is four scalars and not a counted buffer: the slot is
/// minted on the far side, and the exit barrier takes none.
///
/// Not `Sendable` and deliberately unlocked: ``MuxChannelSession`` holds every call under its
/// `fifoLock`, exactly as it did when this state was its own stored properties. What stayed on that
/// side is what a queue must not hold — the `AsyncStream` continuation the producers yield, the
/// drain `Task`, and the bounded-queue gate's pause sink.
final class PaneOutbox {
    /// One frame the drain must ship, with its payload already assembled.
    enum Frame {
        /// `byteCount` bytes of merged output plus the sniffed control that rode with them. The two
        /// are separate because `byteCount` is what the bounded-queue gate dequeues and `bytes` is
        /// what goes on the wire; they agree by construction, and naming both keeps the caller from
        /// re-deriving one from the other on the send path.
        case output(bytes: Data, byteCount: Int, control: [WireMessage])
        /// The pane's exit code, popped whole.
        case exit(code: Int32)
    }

    /// What one slot holds until its frame ships.
    private struct Payload {
        var bytes: Data
        var control: [WireMessage]
    }

    /// The far side, which owns the order, the merge and the split.
    private let handle: OpaquePointer?

    /// The bytes, by the slot the door minted for them. A dictionary rather than the array-plus-
    /// cursor deque this replaces: a split leaves its slot at the head holding a remainder, so the
    /// keys are what a frame names — and the compaction the array needed to keep `removeFirst()`
    /// from being an O(count) memmove per pop is now the `VecDeque` on the other side.
    private var payloads: [UInt64: Payload] = [:]

    /// An empty queue for a fresh pane session.
    init() { handle = slopdesk_pane_outbox_new() }

    deinit { slopdesk_pane_outbox_free(handle) }

    /// Enqueues one chunk with the sniffed control that arrived in it.
    func append(bytes: Data, control: [WireMessage]) {
        let slot = slopdesk_pane_outbox_append_chunk(handle, UInt64(bytes.count))
        payloads[slot] = Payload(bytes: bytes, control: control)
    }

    /// Enqueues the exit barrier. It takes no slot and never coalesces with a chunk.
    func appendExit(code: Int32) { slopdesk_pane_outbox_append_exit(handle, code) }

    /// Whether anything is waiting — the "carried frames" question a restarted drain asks before
    /// deciding whether the rebind owes it a kick.
    var isEmpty: Bool { slopdesk_pane_outbox_is_empty(handle) }

    /// Pops the next frame, or `nil` when the queue is empty.
    ///
    /// The single-slot fast path returns the chunk's `Data` UNCHANGED — the interactive steady state
    /// stays byte-identical work, with no added copy. A multi-chunk backlog pays one concatenation
    /// into a right-sized buffer, amortized by the N−1 send rounds it skips; an over-cap head pays
    /// the same prefix/remainder pair it always did.
    func take() -> Frame? {
        var verdict = SlopDeskOutboxFrame()
        slopdesk_pane_outbox_take(handle, &verdict)
        switch verdict.kind {
        case UInt8(SLOPDESK_OUTBOX_EXIT):
            return .exit(code: verdict.exit_code)
        case UInt8(SLOPDESK_OUTBOX_OUTPUT):
            return output(verdict)
        default:
            return nil
        }
    }

    /// Assembles the payload of one `.output` verdict.
    private func output(_ verdict: SlopDeskOutboxFrame) -> Frame? {
        let byteCount = Int(verdict.byte_count)
        // SPLIT: the slot stays queued holding what did not fit. Its sniffed control rides the
        // PREFIX — a per-channel control FIFO is the only order anything downstream relies on — so
        // the remainder keeps none.
        if verdict.split {
            guard var payload = payloads[verdict.first_slot] else { return nil }
            let prefix = Data(payload.bytes.prefix(byteCount))
            let control = payload.control
            payload.bytes = Data(payload.bytes.dropFirst(byteCount))
            payload.control = []
            payloads[verdict.first_slot] = payload
            return .output(bytes: prefix, byteCount: prefix.count, control: control)
        }
        // Single slot: hand the chunk's own `Data` through untouched.
        if verdict.slots == 1 {
            guard let payload = payloads.removeValue(forKey: verdict.first_slot) else { return nil }
            return .output(bytes: payload.bytes, byteCount: byteCount, control: payload.control)
        }
        var merged = Data(capacity: byteCount)
        var control: [WireMessage] = []
        for slot in verdict.first_slot..<(verdict.first_slot + verdict.slots) {
            guard let payload = payloads.removeValue(forKey: slot) else { continue }
            merged.append(payload.bytes)
            control.append(contentsOf: payload.control)
        }
        return .output(bytes: merged, byteCount: byteCount, control: control)
    }
}
