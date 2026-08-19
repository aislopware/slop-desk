import CSlopDeskFFI
import Foundation
import SlopDeskWorkspaceModel

// MARK: - Paste-protection danger analyzer

/// The face over the **Paste Protection** safety net (Settings ▸ Controls). It classifies a
/// clipboard payload against the four dangers the confirmation dialog flags and decides whether the
/// dialog should appear at all (the skip rules). No view, no pasteboard, no surface — the seam of
/// the paste-protection sheet (`PasteProtectionSheet`), wired into the libghostty embedder's
/// `confirm_read_clipboard_cb` decision point (`GhosttyTerminalView`).
///
/// ## This is a call, not an implementation
/// The rules are `rust/slopdesk-terminal`'s `paste` (docs/55), reached through
/// `slopdesk_paste_dangers` / `slopdesk_paste_should_warn`. So is every WORD the sheet prints —
/// ``Ask``'s three strings, ``descriptions(for:)``'s bullets and ``preview(of:)``'s defused
/// payload. A sentence describing a danger is as much the guard as the bit that trips it: the two
/// live in one file there so a fifth danger cannot arrive as a blank bullet.
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
    ///
    /// The raw values ARE `slopdesk_terminal::paste`'s bit constants — the mask crosses the boundary
    /// as itself, so there is no second numbering to keep in step.
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

    /// Classifies `text` against the four paste dangers. An empty set means nothing notable — which
    /// is an ANSWER, not a refusal: an empty payload has nothing to run.
    public static func analyze(_ text: String) -> PasteDangers {
        var text = text
        let mask = text.withUTF8 { slopdesk_paste_dangers($0.baseAddress, $0.count) }
        return PasteDangers(rawValue: Int(mask))
    }

    /// Whether the paste-protection sheet should be shown for `text`, applying the skip rules: the
    /// protection being off, an empty payload, a full-screen TUI the paste lands inertly in, and a
    /// program that advertised bracketed paste for a payload that is safe inside those brackets.
    ///
    /// The booleans are supplied by the embedder from the live config + terminal state so this stays
    /// AppKit-free.
    public static func shouldWarn(
        text: String,
        protectionOn: Bool,
        bracketedSafe: Bool,
        programAdvertisedBracketed: Bool,
        isAlternateScreen: Bool,
    ) -> Bool {
        var text = text
        return text.withUTF8 {
            slopdesk_paste_should_warn(
                $0.baseAddress, $0.count,
                protectionOn, bracketedSafe, programAdvertisedBracketed, isAlternateScreen,
            )
        }
    }

    /// One line per flagged danger, in the mask's own bit order, for the sheet body.
    public static func descriptions(for dangers: PasteDangers) -> [String] {
        let mask = UInt32(truncatingIfNeeded: dangers.rawValue)
        return (0..<slopdesk_paste_danger_count(mask)).compactMap { index in
            wsDelivered(capacity: descriptionCapacity) {
                slopdesk_paste_danger_description(mask, index, $0, $1)
            }
        }
    }

    /// The payload as the confirmation shows it: length-capped, with every control character in
    /// caret notation so the escape being warned about cannot run inside the warning.
    public static func preview(of text: String) -> String {
        var text = text
        return text.withUTF8 { bytes in
            wsDelivered(capacity: previewCapacity) {
                slopdesk_paste_preview(bytes.baseAddress, bytes.count, $0, $1)
            }
        } ?? ""
    }

    /// Which confirmation is being drawn. The three asks share one surface because they share one
    /// shape — a preview, a reason and a choice — and only the sentence differs. The raw values are
    /// the boundary's own case indices.
    public enum Ask: UInt8, Sendable, CaseIterable {
        /// ⌘V into a prompt, where the payload tripped at least one of the four dangers.
        case unsafePaste = 0
        /// OSC 52 — a program asked to READ the clipboard (`clipboard-read = ask`).
        case clipboardRead = 1
        /// OSC 52 — a program asked to SET the clipboard (`clipboard-write = ask`).
        case clipboardWrite = 2

        /// The question, as the dialog's heading.
        public var title: String { word { slopdesk_paste_ask_title(rawValue, $0, $1) } }

        /// The affirmative button. It names the ACTION rather than saying "OK".
        public var affirmative: String {
            word { slopdesk_paste_ask_affirmative(rawValue, $0, $1) }
        }

        /// What the body says when the mask flagged nothing. `""` for ``unsafePaste``, which never
        /// arrives without a danger to list.
        public var reason: String { word { slopdesk_paste_ask_reason(rawValue, $0, $1) } }

        private func word(_ door: (UnsafeMutablePointer<UInt8>?, Int) -> Int) -> String {
            wsDelivered(capacity: PasteSafetyAnalyzer.descriptionCapacity, door) ?? ""
        }
    }

    /// Long enough for every heading, button and bullet the crate holds; a longer one makes the door
    /// report its size and the reader ask again.
    private static let descriptionCapacity = 128

    /// Big enough for a FULL preview at the crate's cap: every one of its scalars can widen (a tab
    /// to four spaces, a control character to two) or arrive as four UTF-8 bytes, so this is sized
    /// for the worst payload rather than the typical one and the retry is never travelled. It does
    /// NOT grow with the clipboard — the answer is capped whatever the input.
    private static let previewCapacity = 2048
}
