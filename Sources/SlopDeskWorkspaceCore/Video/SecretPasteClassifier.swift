import Foundation

// MARK: - Secret-aware paste guard

/// The risk verdict for a "Paste as Keystrokes" action — surfaced as a confirmation before the host
/// actually types the clipboard into a remote field. The point: the same capability that can
/// type into a `sudo` / SecurityAgent password field can also type a SECRET into a field that echoes it,
/// or splat a whole FILE into a password prompt. This classifies the payload-shape × target so the UI can
/// warn before either happens.
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

/// Pure classifier for the paste guard — no view, no pasteboard, no session. Table-tested. Reuses
/// ``SecretRedactor`` to recognize known token shapes and adds a Shannon-entropy + charset-diversity
/// heuristic for unrecognized high-entropy blobs.
public enum SecretPasteClassifier {
    /// Classifies pasting `text` into a field that is (or isn't) a secure password input.
    public static func assess(text: String, targetIsSecure: Bool) -> PasteRisk {
        if text.count > KeystrokeReplay.maxLength { return .tooLarge }
        if targetIsSecure {
            // A password is a single short token. Many lines or a long blob into a hidden field is a
            // mis-paste (e.g. a whole config/file accidentally pasted into SecurityAgent).
            let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
            if lines > 1 || text.count > 256 { return .bulkIntoSecureField }
            return .ok
        }
        // Non-secure (echoing) field: warn if the payload looks like a credential.
        return looksSecret(text) ? .secretIntoInsecureField : .ok
    }

    /// Whether `text` looks like a credential: a recognized token shape, or a single high-entropy token.
    static func looksSecret(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        // A shape SecretRedactor recognizes (AWS / GitHub / JWT / key=value / generic) is definitely secret.
        if SecretRedactor.redact(t) != t { return true }
        // Otherwise: a single token (no whitespace, no '/' so a PATH is excluded), reasonably long, with
        // ≥2 character classes and HIGH per-character entropy. No hard digit requirement (a random
        // base64/url key often has none — and the redactor's own backstop already demands a digit, so
        // requiring one here too left digit-free random keys uncovered on BOTH paths). The high entropy +
        // length floor keeps camelCase identifiers and dictionary words out. Favours false-negatives.
        guard !t.contains(where: { $0 == " " || $0 == "\t" || $0.isNewline || $0 == "/" }),
              t.count >= 20, t.count <= 256,
              charClassCount(t) >= 2 else { return false }
        return shannonEntropyPerChar(t) >= 3.8
    }

    /// How many of {lower, upper, digit, symbol} appear in `s`.
    private static func charClassCount(_ s: String) -> Int {
        var lower = false, upper = false, digit = false, symbol = false
        for c in s {
            if c.isLowercase { lower = true } else if c.isUppercase { upper = true }
            else if c.isNumber { digit = true } else { symbol = true }
        }
        return (lower ? 1 : 0) + (upper ? 1 : 0) + (digit ? 1 : 0) + (symbol ? 1 : 0)
    }

    /// Shannon entropy per character (bits): -Σ p·log2(p) over the character-frequency distribution.
    /// A random token approaches ~4-6 bits/char; a repeated/dictionary string is much lower.
    static func shannonEntropyPerChar(_ s: String) -> Double {
        guard !s.isEmpty else { return 0 }
        var counts: [Character: Int] = [:]
        for c in s { counts[c, default: 0] += 1 }
        let n = Double(s.count)
        var h = 0.0
        for c in counts.values {
            let p = Double(c) / n
            h -= p * log2(p)
        }
        return h
    }
}
