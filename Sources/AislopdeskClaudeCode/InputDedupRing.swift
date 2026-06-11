import Foundation

/// Suppresses the PTY's echo of bytes the compose-box (input-box B1) just sent, so a
/// prompt the user typed in the overlay is not shown twice (doc 14 §"Thực thi B1" —
/// "Duplicate prompt dedup (BẮT BUỘC, bài học Happy/Happier"). The compose-box writes
/// input to the PTY *and* optimistically renders it; the PTY then echoes the same bytes
/// back in the output stream. This ring records recently-sent input and strips the
/// echoed copy out of incoming output.
///
/// ## Matching strategy — hold-and-confirm (no optimistic drops)
/// We keep a bounded ring of the bytes we expect the PTY to echo back, oldest first. On
/// output, we match bytes against the *front* of that expected echo, but we never drop a
/// byte until the match is **confirmed**:
/// - A byte that matches the next expected-echo byte is **held** (tentatively suppressed)
///   and advances the match cursor.
/// - When the held run completes the whole pending echo, the held bytes are **dropped**
///   (confirmed echo) and the ring resets.
/// - A byte that breaks the match means the held run was *not* the echo after all: the
///   held bytes are **flushed back** to the passthrough, the cursor resets, and the
///   breaking byte is re-processed from the start of the pending echo.
///
/// This is the key correctness property: a byte that merely *shares a prefix* with the
/// expected echo (e.g. the `l` in `total` vs. an expected `ls`) is held, then flushed
/// intact once the next byte diverges — it is never silently eaten.
///
/// It handles: an exact echo (`ls -la\n` → `ls -la\r\n`), a **partial echo split across
/// chunks** (the held run + cursor persist between ``filter(_:)`` calls), and non-echo
/// output (flushed straight through). We normalize the common terminal newline echo
/// (`\n` sent → `\r\n` echoed, and a bare `\r` echo) so the line-ending transform a PTY
/// applies does not defeat the match.
///
/// ## Ring bound + eviction
/// At most ``capacity`` *bytes* of pending (not-yet-echoed) input are retained, FIFO.
/// When a new send would exceed the bound, the oldest pending bytes are evicted (their
/// echo, if it ever arrives, will then simply pass through — correctness over
/// completeness: we never *hold* output waiting for an echo, and we never suppress
/// non-echo content).
public final class InputDedupRing {
    /// Maximum number of pending (sent-but-not-yet-echoed) bytes retained. A compose-box
    /// prompt is small; this bounds memory and staleness. Default 4096.
    public let capacity: Int

    /// The pending echo we still expect to see in the output, oldest byte first.
    private var pending: [UInt8] = []
    /// How many bytes at the front of `pending` we have already matched against output.
    private var matched: Int = 0
    /// Held (tentatively-suppressed) bytes that were EVICTED before their match could be confirmed
    /// (R17 DEDUP-1). These were real output bytes withheld from passthrough during ``filter(_:)``
    /// awaiting confirmation; eviction is a non-confirmation, so they must be flushed — the next
    /// ``filter(_:)`` emits them first (in stream order, ahead of its own chunk) instead of eating them.
    private var flushBuffer: [UInt8] = []

    public init(capacity: Int = 4096) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
    }

    /// Number of pending (un-echoed) bytes currently retained (diagnostics / tests).
    public var pendingCount: Int { pending.count - matched }

    // MARK: Send

    /// Records bytes the compose-box just wrote to the PTY. Their echo will be suppressed
    /// when it appears in the output. Normalizes the byte form so newline-echo transforms
    /// still match (see `expectedEchoBytes`).
    public func recordSent(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        // Append the expected echo of these bytes. We do NOT compact away a tentative
        // (unconfirmed) match prefix here — those held bytes might still need to be
        // flushed back if the in-flight match diverges. Compaction happens only on a
        // confirmed full match (which clears `pending`) or via FIFO eviction below.
        pending.append(contentsOf: expectedEchoBytes(Array(bytes)))

        // Evict oldest pending bytes beyond the bound (FIFO). If eviction would cut into
        // the already-held match prefix, also retreat the cursor so it stays valid.
        if pending.count > capacity {
            let drop = pending.count - capacity
            // R17 DEDUP-1: the evicted region may overlap the already-HELD (matched) prefix — bytes
            // suppressed from passthrough during filter() awaiting confirmation. Evicting them gives up
            // on the match, so they are real output that must be FLUSHED, not silently eaten. Buffer the
            // held portion (pending[0..<min(matched, drop)]) for the next filter() to emit. The un-held
            // evicted bytes (expected echo not yet seen in output) are correctly dropped — their future
            // echo, if any, simply passes through (the documented correctness-over-completeness rule).
            let heldEvicted = min(matched, drop)
            if heldEvicted > 0 {
                flushBuffer.append(contentsOf: pending[0..<heldEvicted])
            }
            pending.removeFirst(drop)
            matched = max(0, matched - drop)
        }
    }

    /// Convenience overload.
    public func recordSent(_ bytes: [UInt8]) { recordSent(Data(bytes)) }

    // MARK: Filter

    /// Filters an incoming output chunk: drops bytes that are the confirmed echo of
    /// recently-sent input and returns the remaining (non-echo) bytes to render. Non-echo
    /// output passes through untouched. See the type doc for the hold-and-confirm model.
    public func filter(_ output: Data) -> Data {
        // Fast path only when there is nothing held AND nothing to flush.
        guard !pending.isEmpty || !flushBuffer.isEmpty else { return output }

        var passthrough = [UInt8]()
        passthrough.reserveCapacity(flushBuffer.count + output.count)

        // R17 DEDUP-1: emit any held bytes that were evicted unconfirmed BEFORE this chunk — they
        // precede it in the output stream (they were withheld during an earlier filter()).
        if !flushBuffer.isEmpty {
            passthrough.append(contentsOf: flushBuffer)
            flushBuffer.removeAll(keepingCapacity: true)
        }

        if pending.isEmpty {
            passthrough.append(contentsOf: output)
            return Data(passthrough)
        }

        for byte in output {
            stepFilter(byte, into: &passthrough)
        }

        return Data(passthrough)
    }

    private func stepFilter(_ byte: UInt8, into passthrough: inout [UInt8]) {
        if pending.isEmpty {
            passthrough.append(byte)
            return
        }
        if byte == pending[matched] {
            // Tentative match — hold it (do NOT emit yet) and advance.
            matched += 1
            if matched == pending.count {
                // Whole pending echo confirmed: drop the held run, reset the ring.
                pending.removeAll(keepingCapacity: true)
                matched = 0
            }
        } else {
            // Mismatch: the bytes we held were NOT echo. Flush them back intact, then
            // re-process this byte against a reset cursor (it may start a fresh match).
            if matched > 0 {
                passthrough.append(contentsOf: pending[0..<matched])
                matched = 0
                stepFilter(byte, into: &passthrough)
            } else {
                // Nothing held and the very first byte diverges — pass it straight.
                passthrough.append(byte)
            }
        }
    }

    /// Convenience overload returning bytes.
    public func filter(_ output: [UInt8]) -> [UInt8] {
        Array(filter(Data(output)))
    }

    /// Clears all pending state (e.g. on a mode change or focus loss).
    public func reset() {
        pending.removeAll(keepingCapacity: true)
        matched = 0
        flushBuffer.removeAll(keepingCapacity: true)
    }

    // MARK: Newline normalization

    /// The byte form we expect the PTY to echo for a given sent run. A PTY in cooked
    /// mode (`ONLCR`) echoes a sent `\n` as `\r\n`, and the line discipline often echoes
    /// an Enter (`\r`) as `\r\n` too. We expand both so the echo matches regardless.
    private func expectedEchoBytes(_ sent: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(sent.count + 4)
        for byte in sent {
            if byte == 0x0A || byte == 0x0D { // '\n' or '\r'
                out.append(0x0D) // '\r'
                out.append(0x0A) // '\n'
            } else {
                out.append(byte)
            }
        }
        return out
    }
}
