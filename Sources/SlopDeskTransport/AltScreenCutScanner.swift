import CSlopDeskFFI
import Foundation

// MARK: - AltScreenCutScanner (front-truncation vs alt-screen segments)

/// Exact alternate-screen state at a front-truncation CUT of a terminal byte stream, and the
/// DECSET that re-opens the segment the cut beheaded.
///
/// ## This is a call, not an implementation
/// The scanner is `rust/slopdesk-altscreen` and has been since stage 14. What used to be here was
/// the second copy of it — 150 lines of Swift doing the same job in the same repository, which is
/// the thing `CLAUDE.md`'s one-implementation rule exists to stop. Stage 29 deleted that copy and
/// left this: an argument marshaller over `slopdesk_altscreen_reopen`, whose semantics are
/// documented where they are decided (`rust/slopdesk-altscreen/src/lib.rs`) rather than restated
/// here where they would drift.
///
/// ## Why
/// Both scrollback retainers cut their stream from the FRONT when it outgrows the cap: the
/// in-memory ring (`slopdesk-wire`'s `ReplayBuffer::ack` eviction) and the on-disk journal (superd's
/// `JournalStore` compaction). A cut that lands INSIDE an open alt-screen segment
/// (`?1049h … ?1049l` — a Claude Code session holds one open for its whole run) beheads it: the
/// surviving stream starts with segment interior and ends with an UNPAIRED `?1049l`. Replay-side
/// segmentation rightly treats an unpaired leave as a defensive reset and passes everything
/// through — so tens of MiB of full-screen TUI churn replays onto the MAIN screen and floods the
/// client's scrollback.
///
/// ## Repair invariant — the state lives IN the bytes
/// When the cut is inside a segment, the evictor PREPENDS the returned re-opener to the surviving
/// head (ring entry / file tail). The surviving stream is then well-formed again, so the NEXT
/// eviction's scan — which starts from that repaired head — needs no carried state. For the
/// journal the repair is on disk, so the invariant survives the daemon.
public enum AltScreenCutScanner {
    /// First guess at the answer's size. A re-opener is a DECSET and nothing else, so this is
    /// generous by an order of magnitude; the retry below exists to be correct, not to be used.
    private static let firstGuessBytes = 64

    /// The DECSET to prepend to the surviving tail when the cut lands inside an open alt-screen
    /// segment (e.g. `ESC [ ? 1049 h`), else `nil`.
    ///
    /// - Parameter keptHead: the first bytes of the SURVIVING stream, used only to resolve a
    ///   sequence straddling the cut. Pass what is cheap; missing bytes degrade to "straddler
    ///   unresolved → state unchanged", never to a wrong transition.
    public static func reopenSequence(afterDropped dropped: Data, keptHead: Data) -> Data? {
        // Two nested `withUnsafeBytes` and nothing else between them: the ABI's whole safety
        // contract is that both pointers stay live for the call, and that is exactly what these
        // scopes mean. `Data` may have no base address when empty — the ABI reads a null pointer as
        // empty, so there is no branch here for it.
        dropped.withUnsafeBytes { droppedRaw in
            keptHead.withUnsafeBytes { keptRaw in
                var buffer = [UInt8](repeating: 0, count: firstGuessBytes)
                var needed = call(droppedRaw, keptRaw, into: &buffer)
                guard needed > 0 else { return nil }
                if needed > buffer.count {
                    // The answer outgrew the guess. Nothing was written, so this is a clean retry;
                    // the wrapped function is pure, so the second call cannot disagree.
                    buffer = [UInt8](repeating: 0, count: needed)
                    needed = call(droppedRaw, keptRaw, into: &buffer)
                    guard needed > 0, needed <= buffer.count else { return nil }
                }
                return Data(buffer.prefix(needed))
            }
        }
    }

    /// One invocation of the C entry point. Returns how many bytes the answer needs; see
    /// `rust/slopdesk-ffi/include/slopdesk_ffi.h` for the convention.
    private static func call(
        _ dropped: UnsafeRawBufferPointer,
        _ keptHead: UnsafeRawBufferPointer,
        into buffer: inout [UInt8],
    ) -> Int {
        buffer.withUnsafeMutableBufferPointer { out in
            slopdesk_altscreen_reopen(
                dropped.baseAddress?.assumingMemoryBound(to: UInt8.self),
                dropped.count,
                keptHead.baseAddress?.assumingMemoryBound(to: UInt8.self),
                keptHead.count,
                out.baseAddress,
                out.count,
            )
        }
    }
}
