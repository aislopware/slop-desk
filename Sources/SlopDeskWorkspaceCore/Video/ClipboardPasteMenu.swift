// ClipboardPasteMenu — the face over `slopdesk_workspace::paste_menu`, which owns the remote-GUI
// pane's clipboard affordances: the "Paste as Keystrokes" item's enablement and the "Clipboard Ring"
// submenu's per-row previews.
//
// WHY this exists: `RemoteWindowModel.pasteAsKeystrokes(_:)` (paced `CGEvent` replay into the host's
// secure field) + `WorkspaceStore.clipboardRing` were both live but UNREACHABLE — a plain ⌘V into a
// GUI pane forwards a raw Cmd+V that pastes the HOST clipboard, so LOCAL text (e.g. a password for
// the auto-spawned SecurityAgent dialog pane) could never reach a remote field.
//
// The MASK and the LIMITS crossed; the `Row` did not. A row carries the full clip so it can be typed
// and a masked label so it can be drawn, and only the second ever comes back: the ring is the
// caller's OWN clipboard history, so sending the clips across and back would be handing somebody
// their own secrets for no reason. `rows(_:limit:)` below zips the labels the door answered against
// the prefix of the ring it asked about — the clip text never leaves this process's Swift half.

import CSlopDeskFFI
import Foundation
import SlopDeskWorkspaceModel

public enum ClipboardPasteMenu {
    /// One row of the "Clipboard Ring" submenu — the full `text` to type (NEVER shown) plus a masked /
    /// truncated `label` for display. `index` is the ring position (0 = most recent), also the stable id.
    public struct Row: Equatable, Sendable, Identifiable {
        /// Ring position (0 = most recent) — also the row's identity, which is what the ``id`` below returns.
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
    ///
    /// Asked for rather than transcribed: the tests assert a truncated label's length against it, and
    /// a copy that drifted would pass against a limit the crate had stopped applying.
    public static let previewLimit = slopdesk_ws_paste_preview_limit()

    /// How many recent clips the submenu lists (the ring caps at ``WorkspaceStore/clipboardRingCap``).
    public static let defaultRowLimit = slopdesk_ws_paste_row_limit()

    /// The submenu rows for `ring` (most-recent-first, capped at `limit`) — each carries the full clip
    /// plus a display-safe preview. Empty `ring` ⇒ no rows (the view shows a disabled "No recent clips").
    ///
    /// ONE crossing for the whole submenu, not one per row. The submenu is rebuilt whole every time it is
    /// about to open, so a door per row would charge `limit` crossings for a menu the user may not read.
    public static func rows(_ ring: [String], limit: Int = defaultRowLimit) -> [Row] {
        // The prefix is a marshalling economy — there is no point lending clips the door is about to
        // cut — not a second cap: `limit` is the SAME value the door applies, so the two cannot
        // disagree, and the door is still the one that decides how many rows come back.
        let clips = Array(ring.prefix(limit))
        guard !clips.isEmpty else { return [] }
        var blob: [UInt8] = []
        for clip in clips {
            let bytes = Array(clip.utf8)
            withUnsafeBytes(of: UInt32(clamping: bytes.count).bigEndian) { blob.append(contentsOf: $0) }
            blob.append(contentsOf: bytes)
        }
        let answer = blob.withUnsafeMutableBufferPointer { lent -> [UInt8] in
            wsAnswerBytes { out, cap in
                slopdesk_ws_paste_rows(lent.baseAddress, lent.count, clips.count, limit, out, cap)
            }
        }
        // Each run is `[flag byte][label]`, so the verdict and the label are ONE classification: two
        // doors could disagree and draw a masked row that pasted as ordinary text.
        return zip(clips.indices, wsRuns(answer, count: clips.count)).map { index, run in
            let (label, isSecret) = split(run)
            return Row(index: index, text: clips[index], label: label, isSecret: isSecret)
        }
    }

    /// The display preview for a clip: MASKED when the crate's classifier flags a credential (a
    /// password preview must never render), else a whitespace-collapsed, ellipsized single line.
    /// Never returns the raw secret.
    public static func preview(_ text: String) -> (label: String, isSecret: Bool) {
        var bytes = Array(text.utf8)
        let answer = bytes.withUnsafeMutableBufferPointer { lent -> [UInt8] in
            wsAnswerBytes { out, cap in
                slopdesk_ws_paste_preview(lent.baseAddress, lent.count, out, cap)
            }
        }
        return split(wsRuns(answer, count: 1)[0])
    }

    /// Whether the "Paste as Keystrokes" item (types the CURRENT local clipboard) is enabled: the live
    /// pane can type (`canPasteKeystrokes` — streaming + a live key sink, false while read-only) AND
    /// there is text to type.
    ///
    /// ⚠️ `clipboardHasText` is a `Bool`, and that is the whole point: enablement must be answerable
    /// WITHOUT the clipboard's content, because on iOS reading it from a renderer raises the modal
    /// "Allow Paste?" alert (``SystemPasteboard``'s header). A caller that already holds the content
    /// because it is about to paste — the Mac's menu, rebuilt at OPEN — reduces it through
    /// ``isPastable(_:)``; a caller deciding at RENDER time asks a probe
    /// (``WorkspaceStore/localClipboardHasText()``). There is deliberately no `String?` spelling of
    /// this function: an enablement path that could take content is one that will.
    public static func canPaste(canPasteKeystrokes: Bool, clipboardHasText: Bool) -> Bool {
        slopdesk_ws_paste_can_paste(canPasteKeystrokes, clipboardHasText)
    }

    /// Whether `clipboard` — content already in hand — is worth typing: present, and not only
    /// whitespace. Both the fire-time guard and the content-in-hand half of ``canPaste(canPasteKeystrokes:clipboardHasText:)``,
    /// so "nothing to paste" is decided in ONE place whichever end asks it.
    ///
    /// An absent clipboard lends the null pair, which the door reads as the same nothing an empty
    /// clip is — so `nil` never needs a branch of its own here.
    public static func isPastable(_ clipboard: String?) -> Bool {
        guard var bytes = clipboard.map({ Array($0.utf8) }) else {
            return slopdesk_ws_paste_is_pastable(nil, 0)
        }
        return bytes.withUnsafeMutableBufferPointer {
            slopdesk_ws_paste_is_pastable($0.baseAddress, $0.count)
        }
    }

    /// Splits one delivered run into its verdict and its label. The flag is the run's FIRST byte, so a
    /// run of exactly one byte is an empty label (a whitespace-only clip), never a missing answer.
    private static func split(_ run: String) -> (label: String, isSecret: Bool) {
        let bytes = Array(run.utf8)
        guard let flag = bytes.first else { return ("", false) }
        // swiftlint:disable:next optional_data_string_conversion
        return (String(decoding: bytes.dropFirst(), as: UTF8.self), flag == 1)
    }
}
