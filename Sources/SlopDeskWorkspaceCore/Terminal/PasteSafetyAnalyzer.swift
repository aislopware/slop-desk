import Foundation

// MARK: - Paste-protection danger analyzer (E8 / ES-E8-3)

/// PURE analyzer for the **Paste Protection** safety net (Settings ▸ Controls). It classifies a
/// clipboard payload against the four dangers the confirmation dialog flags and decides whether the
/// dialog should appear at all (the skip rules). No view, no pasteboard, no surface — the testable heart
/// of the paste-protection sheet (`PasteProtectionSheet`), wired into the libghostty embedder's
/// `confirm_read_clipboard_cb` decision point (`GhosttyTerminalView`).
///
/// This is DISTINCT from ``SecretPasteClassifier`` (which classifies a SECRET-into-field shape for the
/// host's "Paste as Keystrokes" guard). They are deliberately separate engines: this one answers "would
/// this paste run something dangerous at a shell prompt?", the other answers "would this paste leak a
/// credential / splat a file into a hidden field?". Do not overload one with the other.
///
/// ## The four dangers (per `docs/ui-shell/spec/terminal-features__copy-and-paste.md`)
/// - **Multi-line text** — earlier lines would execute the moment they are pasted (newline = Enter).
/// - **Trailing newline** — the command runs on paste, before the user can review it.
/// - **`sudo` / `su`** — the paste may run with elevated privileges.
/// - **Control characters** — possible terminal-escape injection hidden in the text.
///
/// ## Skip rules (``shouldWarn(text:protectionOn:bracketedSafe:programAdvertisedBracketed:isAlternateScreen:)``)
/// - protection off → never warn.
/// - empty payload → never warn (validate-then-skip).
/// - full-screen TUI (alternate screen — vim / less / …) → the paste lands inertly, so skip.
/// - bracketed-safe AND the program advertised bracketed paste (DEC `?2004h`) → the app frames the paste
///   as an inert block, so the danger does not apply.
public enum PasteSafetyAnalyzer {
    /// The set of dangers a payload trips. An `OptionSet` so a payload can carry several at once
    /// (e.g. a multi-line block that also ends in a newline and invokes `sudo`).
    public struct PasteDangers: OptionSet, Sendable, Equatable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// More than one line of content — earlier lines run as soon as they are pasted.
        public static let multiLine = Self(rawValue: 1 << 0)
        /// Ends with a line terminator — the final command runs on paste, unreviewed.
        public static let trailingNewline = Self(rawValue: 1 << 1)
        /// Contains a `sudo` / `su` command token — may run with elevated privileges.
        public static let sudoOrSu = Self(rawValue: 1 << 2)
        /// Contains C0 control characters (other than TAB/LF/CR) — possible escape injection.
        public static let controlChars = Self(rawValue: 1 << 3)
    }

    /// Classifies `text` against the four paste dangers. Returns an empty set for empty / plainly-safe
    /// input (validate-then-skip on empty). Pure + allocation-light; the caller decides what to do with
    /// the result (show the sheet, or list the flags inside it).
    public static func analyze(_ text: String) -> PasteDangers {
        var dangers: PasteDangers = []
        guard !text.isEmpty else { return dangers }

        let scalars = Array(text.unicodeScalars)

        // Trailing newline: last scalar is LF or CR (covers "\r\n", bare "\n", bare "\r").
        if let last = scalars.last, last == "\n" || last == "\r" {
            dangers.insert(.trailingNewline)
        }

        // Multi-line: strip ONE trailing terminator (CRLF / LF / CR) then look for any remaining LF/CR.
        // A single trailing newline alone is NOT multi-line — it is exactly the .trailingNewline case.
        var end = scalars.count
        if end > 0, scalars[end - 1] == "\n" {
            end -= 1
            if end > 0, scalars[end - 1] == "\r" { end -= 1 }
        } else if end > 0, scalars[end - 1] == "\r" {
            end -= 1
        }
        for i in 0..<end where scalars[i] == "\n" || scalars[i] == "\r" {
            dangers.insert(.multiLine)
            break
        }

        // Control characters: any C0 byte < 0x20 EXCEPT TAB (0x09) / LF (0x0A) / CR (0x0D). ESC (0x1B) —
        // the classic terminal-escape-injection vector — is < 0x20 so it is covered here.
        for s in scalars {
            let v = s.value
            if v < 0x20, v != 0x09, v != 0x0A, v != 0x0D {
                dangers.insert(.controlChars)
                break
            }
        }

        // sudo / su as a COMMAND token (word-boundary, not a bare substring — so "supervisor" / "issue"
        // / "status" never trip it).
        if containsElevationToken(scalars) { dangers.insert(.sudoOrSu) }

        return dangers
    }

    /// Whether the paste-protection sheet should be shown for `text`, applying the skip rules above.
    /// The booleans are supplied by the embedder from the live config + terminal state so this stays
    /// AppKit-free and unit-testable.
    public static func shouldWarn(
        text: String,
        protectionOn: Bool,
        bracketedSafe: Bool,
        programAdvertisedBracketed: Bool,
        isAlternateScreen: Bool,
    ) -> Bool {
        guard protectionOn else { return false }
        guard !text.isEmpty else { return false }
        // Full-screen TUI (vim / less / …): the paste is delivered inertly to the application; skip.
        if isAlternateScreen { return false }
        // Bracketed-safe: the program framed the paste as an inert block, so the danger does not apply.
        if bracketedSafe, programAdvertisedBracketed { return false }
        return !analyze(text).isEmpty
    }

    /// Human-readable one-line descriptions of the flagged dangers, in a stable order, for the sheet body.
    public static func descriptions(for dangers: PasteDangers) -> [String] {
        var out: [String] = []
        if dangers.contains(.multiLine) {
            out.append("Multiple lines — earlier lines run the moment they are pasted.")
        }
        if dangers.contains(.trailingNewline) {
            out.append("Ends with a newline — the command runs on paste, before you can review it.")
        }
        if dangers.contains(.sudoOrSu) {
            out.append("Contains sudo or su — the paste may run with elevated privileges.")
        }
        if dangers.contains(.controlChars) {
            out.append("Contains control characters — possible hidden terminal-escape injection.")
        }
        return out
    }

    // MARK: Private

    /// Scans `scalars` for a `sudo` / `su` token at a word boundary. Tokens are maximal runs of
    /// non-separator scalars; separators are whitespace and the common shell command separators
    /// (`;` `|` `&` `(` `)`). A conservative safety net: it matches the token wherever it appears
    /// (favouring an extra warning over a missed `sudo`), but a longer word that merely CONTAINS the
    /// letters (e.g. "subscribe", "issue") is a different token and never matches.
    private static func containsElevationToken(_ scalars: [Unicode.Scalar]) -> Bool {
        func isSeparator(_ s: Unicode.Scalar) -> Bool {
            switch s {
            case " ",
                 "\t",
                 "\n",
                 "\r",
                 ";",
                 "|",
                 "&",
                 "(",
                 ")":
                true
            default:
                false
            }
        }
        let n = scalars.count
        var i = 0
        while i < n {
            if isSeparator(scalars[i]) { i += 1
                continue
            }
            var j = i
            while j < n, !isSeparator(scalars[j]) { j += 1 }
            // Compare the [i, j) run against the literal tokens without allocating a String per token.
            let len = j - i
            if len == 4,
               scalars[i] == "s", scalars[i + 1] == "u", scalars[i + 2] == "d", scalars[i + 3] == "o"
            {
                return true
            }
            if len == 2, scalars[i] == "s", scalars[i + 1] == "u" {
                return true
            }
            i = j
        }
        return false
    }
}
