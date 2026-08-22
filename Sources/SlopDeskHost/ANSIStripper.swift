import CSlopDeskFFI
import Foundation

/// PTY bytes as the plain text a pattern is matched against.
///
/// Removes the terminal escape sequences from a pane's output, so the `wait --until` predicate's
/// regex sees words rather than cursor moves, and an agent reading a pane is not handed an
/// `OSC 133` prompt mark. Nerd-font / Powerline private-use glyphs go too: they are valid UTF-8 a
/// byte scanner passes through, and they are decoration.
///
/// A face over `slopdesk-sanitize`'s `plaintext`, which reads this grammar through the same scanner
/// the seven replay passes share. It is NOT one of them — a replay pass keeps a faithful terminal
/// stream and removes only churn, because the client renders what survives.
public enum ANSIStripper {
    /// Returns `input` with all recognised ANSI/VT escape sequences removed.
    public static func strip(_ input: String) -> String {
        let stripped = strip(bytes: Array(input.utf8))
        // The scanner only ever drops WHOLE codepoints and whole sequences, so what comes back is
        // valid UTF-8; the fallback is the byte-per-scalar reading the Swift original ended with.
        return String(bytes: stripped, encoding: .utf8)
            ?? String(stripped.map { Character(UnicodeScalar($0)) })
    }

    /// The stripped bytes of a raw chunk, for a caller that has not decoded it yet.
    ///
    /// ## Why the buffer is GUESSED at the INPUT's length, and why that guess is exact
    /// `plaintext::strip` only ever copies a codepoint through or drops it whole — no arm of the
    /// scanner emits a byte the input did not carry — so the answer is never longer than what was
    /// handed in. `bytes.count` is therefore an upper bound rather than an estimate, and the retry
    /// below is unreachable by construction; it is kept because a bound that lives in another
    /// crate's control flow is a bound only a test can hold, and §4's protocol costs nothing to
    /// honour.
    ///
    /// Asking `(NULL, 0)` for the length first — what this did until 2026-08-22 — ran the whole VT
    /// grammar over the chunk, allocated the answer and discarded it, then ran it again. Measured
    /// against the shipped `macos-arm64` slice, `swiftc -O`, two runs agreeing, over a 183 KB
    /// SGR-dense pane capture: **646 µs and 629 µs probe-then-fill against 302 µs and 310 µs**.
    /// Every caller is an agent reading a pane (`ctl` `peek` / `read` / the pane-output verb), so
    /// the input is a scrollback window rather than a chunk.
    public static func strip(bytes: [UInt8]) -> [UInt8] {
        bytes.withUnsafeBufferPointer { input -> [UInt8] in
            var room = [UInt8](repeating: 0, count: input.count)
            var needed = room.withUnsafeMutableBufferPointer { out in
                slopdesk_plaintext_strip(input.baseAddress, input.count, out.baseAddress, out.count)
            }
            if needed > room.count {
                room = [UInt8](repeating: 0, count: needed)
                needed = room.withUnsafeMutableBufferPointer { out in
                    slopdesk_plaintext_strip(input.baseAddress, input.count, out.baseAddress, out.count)
                }
            }
            guard needed > 0, needed <= room.count else { return [] }
            room.removeLast(room.count - needed)
            return room
        }
    }

    /// The index from which the tail of `bytes` must be HELD BACK into the next chunk: the start of
    /// a trailing escape sequence that has not terminated yet, or of a trailing truncated UTF-8
    /// codepoint — either can only be stripped once its continuation arrives. `bytes.count` means
    /// nothing is held.
    ///
    /// The same grammar ``strip(bytes:)`` reads, asked the other way, so the two cannot disagree
    /// about where a sequence ends.
    ///
    /// No Swift caller today, and kept for the reason ``BlobImageValidator/looksLikePNG(_:)`` is:
    /// `check-supervisor` pins the pair, and the face IS the door. Without one, the next caller that
    /// needs a cut point writes a second incremental scan in Swift — which is exactly how the strip
    /// and the holdback drifted apart before.
    public static func holdbackStart(in bytes: [UInt8]) -> Int {
        bytes.withUnsafeBufferPointer { input in
            slopdesk_plaintext_holdback(input.baseAddress, input.count)
        }
    }
}
