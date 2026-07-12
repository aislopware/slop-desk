import Foundation

// MARK: - Clipboard "Paste as Keystrokes" menu model

/// The PURE model behind the remote-GUI pane's clipboard affordances (the "Paste as Keystrokes" item +
/// the "Clipboard Ring" submenu): given the LOCAL clipboard ring + whether the live pane can type, it
/// produces the menu's enablement + the per-clip row previews — classifier-aware, with SECRET clips
/// MASKED so a password preview never renders in the menu. No view / pasteboard / session here, so the
/// UI stays a thin renderer and the enablement + masking are unit-tested headlessly.
///
/// WHY this exists: ``RemoteWindowModel/pasteAsKeystrokes(_:)`` (paced `CGEvent` replay into the host's
/// secure field) + ``WorkspaceStore/clipboardRing`` were both live but UNREACHABLE — a plain ⌘V into a
/// GUI pane forwards a raw Cmd+V that pastes the HOST clipboard, so LOCAL text (e.g. a password for the
/// auto-spawned SecurityAgent dialog pane) could never reach a remote field. This model backs the
/// context-menu + ⌥⌘V affordances that close that gap.
public enum ClipboardPasteMenu {
    /// One row of the "Clipboard Ring" submenu — the full `text` to type (NEVER shown) plus a masked /
    /// truncated `label` for display. `index` is the ring position (0 = most recent), also the stable id.
    public struct Row: Equatable, Sendable, Identifiable {
        /// Ring position (0 = most recent) — also the SwiftUI list identity.
        public let index: Int
        /// The full clip to replay as keystrokes. Never rendered — only handed to `pasteAsKeystrokes`.
        public let text: String
        /// The display preview: a single-line truncation, or a MASK when the clip looks secret.
        public let label: String
        /// Whether the clip was classified as a credential (→ the label is masked, not the content).
        public let isSecret: Bool
        public var id: Int { index }

        public init(index: Int, text: String, label: String, isSecret: Bool) {
            self.index = index
            self.text = text
            self.label = label
            self.isSecret = isSecret
        }
    }

    /// Max characters of a non-secret preview before it is ellipsized.
    public static let previewLimit = 48
    /// How many recent clips the submenu lists (the ring caps at ``WorkspaceStore/clipboardRingCap``).
    public static let defaultRowLimit = 12

    /// The submenu rows for `ring` (most-recent-first, capped at `limit`) — each carries the full clip
    /// plus a display-safe preview. Empty `ring` ⇒ no rows (the view shows a disabled "No recent clips").
    public static func rows(_ ring: [String], limit: Int = defaultRowLimit) -> [Row] {
        ring.prefix(limit).enumerated().map { index, text in
            let (label, isSecret) = preview(text)
            return Row(index: index, text: text, label: label, isSecret: isSecret)
        }
    }

    /// The display preview for a clip: MASK it when ``SecretPasteClassifier/looksSecret(_:)`` flags a
    /// credential (a password preview must never render), else a whitespace-collapsed, ellipsized
    /// single line. Never returns the raw secret. Pure for tests.
    public static func preview(_ text: String) -> (label: String, isSecret: Bool) {
        if SecretPasteClassifier.looksSecret(text) {
            // Mask: length only, never the bytes — mirrors the redactor's "don't echo the secret" rule.
            return ("•••• hidden secret (\(text.count) chars)", true)
        }
        // Collapse every run of whitespace / newlines to a single space so a multi-line clip is one line.
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        let flattened = collapsed.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : collapsed
        guard flattened.count > previewLimit else { return (flattened, false) }
        let end = flattened.index(flattened.startIndex, offsetBy: previewLimit)
        return (String(flattened[..<end]) + "…", false)
    }

    /// Whether the "Paste as Keystrokes" item (types the CURRENT local clipboard) is enabled: the live
    /// pane can type (`canPasteKeystrokes` — streaming + a live key sink, false while read-only) AND the
    /// local clipboard holds non-whitespace text. Pure for tests.
    public static func canPaste(canPasteKeystrokes: Bool, clipboard: String?) -> Bool {
        guard canPasteKeystrokes, let clipboard else { return false }
        return !clipboard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
