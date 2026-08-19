import CSlopDeskFFI

// MARK: - KeystrokeReplay (clipboard text → key-event sequence)

/// One synthetic keystroke: a macOS virtual key code (`kVK_*`) plus whether Shift is held. The host's
/// per-event input path (`InputInjector.postKey`) posts each as a `CGEvent` key — which types into a
/// `sudo` / SecurityAgent password field (a `CGEvent(.cghidEventTap)` keystroke reaches the secure
/// field even with Secure Event Input active).
public struct ReplayStroke: Sendable, Equatable {
    public var keyCode: UInt16
    public var shift: Bool
    public init(keyCode: UInt16, shift: Bool) {
        self.keyCode = keyCode
        self.shift = shift
    }
}

/// The face over `slopdesk-workspace`'s `keystroke_replay` — the US-QWERTY inverse of unicode text
/// injection, needed because secure fields drop synthetic unicode events but accept HID key events.
///
/// The table, the cap and the skip counting are all Rust's (docs/55). What is here is the crossing:
/// a `String` in, and the door's `[skipped][count][records]` blob back as ``Encoded``.
///
/// ⚠️ The unit on the far side is the grapheme CLUSTER, not the scalar, and that is the difference
/// between a paste and a corruption: a decomposed `é` walked as scalars would type a bare `e` into a
/// password field and report a single skip. Nothing on this side re-derives it — the whole reason
/// the encode crosses at all rather than staying a Swift `for ch in text` is that the two languages
/// would otherwise each have their own answer to what one character is.
public enum KeystrokeReplay {
    /// The encoded result: the strokes to send, and how many input clusters had no mapping (skipped).
    public struct Encoded: Sendable, Equatable {
        public var strokes: [ReplayStroke]
        public var skipped: Int
    }

    /// The largest clipboard payload we will replay as keystrokes, in grapheme clusters. Read off
    /// the header rather than transcribed: ``SecretPasteClassifier`` refuses past the same number,
    /// and two copies of a ceiling is how one of them ends up being the other minus a byte.
    public static let maxLength = Int(SLOPDESK_KEYSTROKE_MAX_LENGTH)

    /// `[uint32 skipped][uint32 count]`.
    private static let headerBytes = 8

    /// `[uint16 keyCode][uint8 shift]`.
    private static let recordBytes = 3

    /// Encodes `text` into key strokes, skipping what US-QWERTY has no key for and everything past
    /// ``maxLength``.
    public static func encode(_ text: String) -> Encoded {
        var bytes = Array(text.utf8)
        return bytes.withUnsafeMutableBufferPointer { input -> Encoded in
            let call = { (out: inout UnsafeMutableBufferPointer<UInt8>) -> Int in
                slopdesk_keystroke_replay(input.baseAddress, input.count, out.baseAddress, out.count)
            }
            // An ARITHMETIC bound, not a guess: a cluster is at least one byte, so no clipboard can
            // yield more strokes than it has UTF-8 bytes, and the cap bounds it again. The §4 retry
            // below is therefore unreachable — it stays because the convention is what makes a short
            // buffer safe, and a bound that silently stopped holding must not become a truncation.
            var out = [UInt8](repeating: 0, count: headerBytes + min(input.count, maxLength) * recordBytes)
            var needed = out.withUnsafeMutableBufferPointer(call)
            if needed > out.count {
                out = [UInt8](repeating: 0, count: needed)
                needed = out.withUnsafeMutableBufferPointer(call)
            }
            return decode(out, needed)
        }
    }

    /// Reads `[uint32 skipped][uint32 count]` and that many fixed-stride records out of the answer.
    ///
    /// A short or truncated answer decodes to NOTHING rather than to a partial list. The payload is
    /// usually a password: half of one typed into a field is not a degraded paste, it is a wrong
    /// one, and the caller's "typed N, skipped M" would be reporting on a string that never existed.
    private static func decode(_ bytes: [UInt8], _ length: Int) -> Encoded {
        guard length >= headerBytes, length <= bytes.count else { return Encoded(strokes: [], skipped: 0) }
        let word = { (at: Int) -> Int in
            var value = 0
            for offset in at..<(at + 4) { value = value << 8 | Int(bytes[offset]) }
            return value
        }
        let skipped = word(0)
        let count = word(4)
        guard length >= headerBytes + count * recordBytes else { return Encoded(strokes: [], skipped: 0) }
        var strokes: [ReplayStroke] = []
        strokes.reserveCapacity(count)
        for index in 0..<count {
            let at = headerBytes + index * recordBytes
            let keyCode = UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1])
            strokes.append(ReplayStroke(keyCode: keyCode, shift: bytes[at + 2] != 0))
        }
        return Encoded(strokes: strokes, skipped: skipped)
    }
}
