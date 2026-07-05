import Foundation

/// Splits an incrementally-growing byte stream into complete `\n`-terminated lines.
///
/// This is the **pure, deterministic core** of the tailer (the part that must "not
/// miss a line and not double-emit"). The tailer feeds it raw byte deltas as the file
/// grows; it returns only *complete* lines and holds back a partial trailing line
/// until its newline arrives. Pulling this logic out of the I/O lets us test the hard
/// part (partial line, burst, multi-byte boundary) with zero file system.
public struct LineAccumulator {
    /// Hard cap on the buffered partial line (R17 INSP-PARSE-1). The transcript is UNTRUSTED
    /// append-only NDJSON; a line that never terminates with a newline (a corrupt/truncated feed, or a
    /// deliberately huge single line) would otherwise grow ``pending`` without bound — exhausting host
    /// RAM (a DoS by transcript content alone). Once the partial tail passes this, we enter SKIP mode:
    /// bytes are discarded until the next newline, which terminates the over-long line and re-syncs.
    /// 16 MB dwarfs any real Claude transcript line. Injectable so tests can drive a tiny cap.
    private let maxPendingBytes: Int

    /// Bytes received but not yet terminated by a newline (the partial tail).
    private var pending = Data()
    /// True while discarding an over-long (cap-exceeded) line until its terminating newline (INSP-PARSE-1).
    private var skippingOverlongLine = false

    public init(maxPendingBytes: Int = 16 * 1024 * 1024) {
        precondition(maxPendingBytes > 0, "maxPendingBytes must be positive")
        self.maxPendingBytes = maxPendingBytes
    }

    /// Appends a delta and returns every newly-completed line (newline stripped).
    /// A trailing partial line (no `\n` yet) stays buffered and is NOT returned —
    /// it surfaces only once its terminating newline arrives, so a line written in
    /// two writes ("abc" then "def\n") emits exactly once, as "abcdef".
    public mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        return drainCompleteLines()
    }

    /// Resets the accumulator (used on file truncation/rotation: the byte offset
    /// restarts, so any half-line we were holding is stale and must be dropped).
    public mutating func reset() {
        pending.removeAll(keepingCapacity: true)
        skippingOverlongLine = false
    }

    private mutating func drainCompleteLines() -> [String] {
        var lines: [String] = []
        let newline = UInt8(ascii: "\n")
        // Single linear pass (R17 INSP-PARSE-2): advance a search cursor and slice each complete line,
        // then drop the whole consumed prefix ONCE at the end. The old code did `removeSubrange` from
        // the FRONT of `pending` per line — each front removal memmoves the entire tail, making a
        // newline-dense delta O(n²) (a 1 MB all-newlines poll took ~10s and blocked the tailer actor).
        var searchStart = pending.startIndex
        while let nlIndex = pending[searchStart...].firstIndex(of: newline) {
            if skippingOverlongLine {
                // This newline ends the over-long line we were discarding — resync, emit nothing.
                skippingOverlongLine = false
            } else {
                var bytes = Data(pending[searchStart..<nlIndex])
                if bytes.last == UInt8(ascii: "\r") { bytes.removeLast() } // CRLF tolerance
                // Lossy UTF-8 (U+FFFD substitution) so a line with invalid bytes still SURFACES as a
                // line (the caller maps an unparseable one to `.unknown`) rather than being silently
                // dropped by a failed `String(data:encoding:)` — the never-miss-a-line contract (INSP-PARSE-3).
                // The failable initializer the lint rule prefers returns nil on invalid UTF-8 (would drop the
                // line and break the INSP-PARSE-3 regression test), so the lossy decode is mandatory here.
                // swiftlint:disable:next optional_data_string_conversion
                lines.append(String(decoding: bytes, as: UTF8.self))
            }
            searchStart = pending.index(after: nlIndex)
        }

        if skippingOverlongLine {
            // No newline arrived to end the over-long line; the whole buffer is its (still-unterminated)
            // remainder — discard it and keep skipping.
            pending.removeAll(keepingCapacity: false)
        } else {
            // Drop everything up to the last completed line; keep the trailing partial.
            if searchStart > pending.startIndex {
                pending.removeSubrange(pending.startIndex..<searchStart)
            }
            // Cap the surviving partial: if it has grown past the cap with no newline, discard it and
            // enter skip mode so the rest of the over-long line (until its newline) is dropped instead
            // of accumulating to OOM (INSP-PARSE-1).
            if pending.count > maxPendingBytes {
                pending.removeAll(keepingCapacity: false)
                skippingOverlongLine = true
            }
        }
        return lines
    }

    /// Bytes currently held back as an incomplete line (for tests / introspection).
    public var bufferedByteCount: Int { pending.count }
}
