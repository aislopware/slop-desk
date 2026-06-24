// BlockOutputView — the expanded output of a selected command block (REBUILD-V2, L3).
//
// Renders the VT-stripped PLAIN TEXT (the model's `BlockOutputSanitizer.plainText`, already applied by
// `TerminalViewModel.copyBlockOutput`) as a scrollable, SELECTABLE monospaced `Text` with a copy button.
// While the host reply is in flight it shows a `ProgressView`; a block the host captured no bytes for
// (`outputLen == 0`) shows a neutral note; an unavailable/evicted block (`text == nil` after fetch) says so.
//
// NO ANSI-colour renderer (none exists; plain text is the reliable v1 — per the L3 brief). SYSTEM colours
// + monospaced/system fonts only.

#if canImport(SwiftUI)
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct BlockOutputView: View {
    /// The fetched, VT-stripped output text. `nil` while still being fetched OR when the host reported the
    /// block unavailable — disambiguated by `isFetching`.
    let text: String?
    /// Whether a `blockOutput` request is currently in flight (drives the spinner vs. the unavailable note).
    let isFetching: Bool
    /// The host's byte-count hint for the block — `0` means "command produced no output" (a distinct empty
    /// state from "output unavailable / evicted").
    let outputLen: UInt32

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
                Text("Fetching output…").font(.callout).foregroundStyle(Otty.Text.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        } else if let text, !text.isEmpty {
            ScrollView([.vertical, .horizontal]) {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(Otty.Text.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Otty.Surface.element)
            .clipShape(RoundedRectangle(cornerRadius: Otty.Metric.radiusControl))
            .overlay(
                RoundedRectangle(cornerRadius: Otty.Metric.radiusControl)
                    .strokeBorder(Otty.Line.subtle, lineWidth: 1),
            )
        } else if outputLen == 0 {
            note("No output", "The command produced no captured output.")
        } else {
            note("Output unavailable", "The host no longer holds this block's output.")
        }
    }

    /// The header row: a small label + a copy button (disabled until there is text to copy).
    private var header: some View {
        HStack {
            Text("Output")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Otty.State.header)
            Spacer(minLength: 0)
            Button {
                copy()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Copy output")
            .disabled((text ?? "").isEmpty)
        }
    }

    private func note(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout).foregroundStyle(Otty.Text.secondary)
            Text(detail).font(.caption).foregroundStyle(Otty.Text.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    private func copy() {
        guard let text, !text.isEmpty else { return }
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
#endif
