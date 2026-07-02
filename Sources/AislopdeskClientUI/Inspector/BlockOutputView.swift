// BlockOutputView — the expanded output of a selected command block (REBUILD-V2, L3).
//
// Renders the raw captured bytes COLOURED (`ANSIOutputStyler`, SGR → the active theme's ANSI palette) as a
// scrollable, SELECTABLE monospaced `Text` with a copy button (the copy path strips the colour runs through
// `BlockOutputSanitizer` — the clipboard always gets clean plain text). While the host reply is in flight it
// shows a `ProgressView`; a block the host captured no bytes for (`outputLen == 0`) shows a neutral note; an
// unavailable/evicted block (`bytes == nil` after fetch) says so.
//
// (The old opt-in "Render Markdown" toggle is gone — it re-rendered the same text through `MarkdownText`
// and was never the right read for terminal output; plain/coloured VT text is the one rendering.)

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct BlockOutputView: View {
    /// The fetched, RAW captured VT output bytes. `nil` while still being fetched OR when the host reported
    /// the block unavailable — disambiguated by `isFetching`. The SGR colour runs are rendered by
    /// `ANSIOutputStyler`; the copy path strips them through `BlockOutputSanitizer`.
    let bytes: Data?
    /// Whether a `blockOutput` request is currently in flight (drives the spinner vs. the unavailable note).
    let isFetching: Bool
    /// The host's byte-count hint for the block — `0` means "command produced no output" (a distinct empty
    /// state from "output unavailable / evicted").
    let outputLen: UInt32

    /// The VT-stripped plain text (for the copy button and the empty checks) — derived from the raw
    /// `bytes` on demand.
    private var plainText: String? { bytes.map { BlockOutputSanitizer.plainText(from: $0) } }

    /// The COLOURED render of the raw bytes, mapped to the active terminal theme's ANSI palette.
    private var coloured: AttributedString? {
        guard let bytes else { return nil }
        let theme = Slate.theme
        return ANSIOutputStyler.attributed(
            from: bytes,
            palette: theme.ansiPalette.map { UInt32(hex6: $0) },
            defaultFg: UInt32(hex6: theme.terminalForegroundHex),
            defaultBg: UInt32(hex6: theme.terminalBackgroundHex),
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var content: some View {
        if isFetching {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Fetching output…").font(.callout).foregroundStyle(Slate.Text.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        } else if let text = plainText, !text.isEmpty {
            ScrollView([.vertical, .horizontal]) {
                // Render the COLOURED bytes (SGR → theme ANSI palette) — falls back to the plain
                // text if the styler produced nothing. The base monospaced font applies to any run
                // the styler did not override (bold/italic runs carry their own font).
                Text(coloured ?? AttributedString(text))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .slateCard()
        } else if outputLen == 0 {
            note("No output", "The command produced no captured output.")
        } else {
            note("Output unavailable", "The host no longer holds this block's output.")
        }
    }

    /// The header row: a small label + a copy button (disabled until there is text to copy). The copy
    /// button flashes a checkmark after firing (the ConfirmFlashButton feedback beat) — a silent
    /// pasteboard write otherwise reads as a no-op.
    private var header: some View {
        HStack {
            Text("Output")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Slate.State.header)
            Spacer(minLength: 0)
            ConfirmFlashButton(action: copy) { confirming in
                // Fixed 16×16 — the copy/checkmark glyphs differ in intrinsic size, and letting the
                // swap resize the button shifted the header row.
                Label("Copy", systemImage: confirming ? "checkmark" : "doc.on.doc")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(confirming ? Slate.Status.ok : Slate.Text.icon)
                    .frame(width: 16, height: 16)
                    .contentShape(.rect)
            }
            .help("Copy output")
            .disabled((plainText ?? "").isEmpty)
            .accessibilityLabel("Copy output")
        }
    }

    private func note(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout).foregroundStyle(Slate.Text.secondary)
            Text(detail).font(.caption).foregroundStyle(Slate.Text.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    private func copy() {
        guard let text = plainText, !text.isEmpty else { return }
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
#endif
