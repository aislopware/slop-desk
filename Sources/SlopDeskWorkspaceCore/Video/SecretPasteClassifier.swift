import CSlopDeskFFI

// MARK: - Secret-aware paste guard

/// The risk verdict for a "Paste as Keystrokes" action — surfaced as a confirmation before the host
/// actually types the clipboard into a remote field. The point: the same capability that can
/// type into a `sudo` / SecurityAgent password field can also type a SECRET into a field that echoes it,
/// or splat a whole FILE into a password prompt. This classifies the payload-shape × target so the UI can
/// warn before either happens.
///
/// Case order is the discriminant order `slopdesk-workspace`'s `secrets::PasteRisk::ALL` gives, which
/// `scripts/check-supervisor.sh` pins.
public enum PasteRisk: Sendable, Equatable {
    /// Nothing notable — paste freely.
    case ok
    /// The payload looks like a credential and the target is NOT a secure (password) field — it would be
    /// typed where it echoes visibly. Warn before leaking it.
    case secretIntoInsecureField
    /// A large / multi-line blob into a SECURE (password) field — a password is one short token, so this
    /// is almost certainly a mis-paste (a file / command block) you don't want typed into a hidden field.
    case bulkIntoSecureField
    /// Beyond ``KeystrokeReplay/maxLength`` — too long to type as keystrokes at all; refuse.
    case tooLarge
}

/// The paste guard, as a face over `slopdesk-workspace`'s `secrets`. The shapes it recognises are the
/// ones ``SecretRedactor`` masks — one vocabulary, so a payload the redactor would scrub out of a title
/// is one this refuses to type into a field that echoes it — plus a Shannon-entropy and
/// charset-diversity heuristic for unrecognized high-entropy blobs.
public enum SecretPasteClassifier {
    /// Classifies pasting `text` into a field that is (or isn't) a secure password input.
    ///
    /// ``KeystrokeReplay/maxLength`` crosses as an argument rather than living in the crate: it is a
    /// transport ceiling on what can be typed at all, not a rule about secrets.
    public static func assess(text: String, targetIsSecure: Bool) -> PasteRisk {
        var bytes = Array(text.utf8)
        let raw = bytes.withUnsafeMutableBufferPointer { input in
            slopdesk_ws_paste_risk(input.baseAddress, input.count, targetIsSecure, KeystrokeReplay.maxLength)
        }
        switch raw {
        case 1: return .secretIntoInsecureField
        case 2: return .bulkIntoSecureField
        case 3: return .tooLarge
        default: return .ok
        }
    }

    /// Whether `text` looks like a credential: a shape ``SecretRedactor`` recognizes, or a single
    /// high-entropy token. The clipboard-ring preview asks this before it renders anything.
    public static func looksSecret(_ text: String) -> Bool {
        var bytes = Array(text.utf8)
        return bytes.withUnsafeMutableBufferPointer { input in
            slopdesk_ws_looks_secret(input.baseAddress, input.count)
        }
    }
}
