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
    public static func strip(bytes: [UInt8]) -> [UInt8] {
        bytes.withUnsafeBufferPointer { input -> [UInt8] in
            let needed = slopdesk_plaintext_strip(input.baseAddress, input.count, nil, 0)
            guard needed > 0 else { return [] }
            var room = [UInt8](repeating: 0, count: needed)
            let written = room.withUnsafeMutableBufferPointer { out in
                slopdesk_plaintext_strip(input.baseAddress, input.count, out.baseAddress, out.count)
            }
            guard written == needed else { return [] }
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
