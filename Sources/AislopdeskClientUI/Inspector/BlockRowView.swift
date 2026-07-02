// BlockRowView — one command-block row in the Commands inspector (REBUILD-V2, L3).
//
// A SINGLE-LINE, quiet row (the Outline-merge restyle): a small status gutter (✓ / ✗ / a spinner —
// the old Outline tab's gutter idiom, not a filled badge), the command in a monospaced line, then a
// right-aligned tertiary meta column (the clock time the command ran) and the bookmark star. A failed
// row carries a compact red `exit N` beside the command so the red ✗ is explained in place.
//
// PURE presentation over a `CommandBlock` value (the model's derived `durationLabel` / `status` do the
// mapping). Slate tokens + SF Symbols only.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI

struct BlockRowView: View {
    let block: CommandBlock
    /// Whether the block is bookmarked — shows a trailing star so a starred block reads at a glance.
    var isBookmarked: Bool = false
    /// The clock time the command RAN ("19:32:05" — the block's client-receive first-seen stamp),
    /// shown right-aligned tertiary. `nil` hides the column (an unknown / evicted first-seen).
    var clockTime: String?

    var body: some View {
        HStack(spacing: Slate.Metric.space2) {
            gutter
                .frame(width: 14, alignment: .center)
            Text(block.commandText.isEmpty ? "—" : block.commandText)
                .font(.system(size: Slate.Typeface.base, design: .monospaced))
                .foregroundStyle(block.commandText.isEmpty ? Slate.Text.secondary : Slate.Text.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            if case let .failed(code) = block.status {
                Text("exit \(code)")
                    .font(.system(size: Slate.Typeface.small, weight: .medium))
                    .foregroundStyle(Slate.Status.err)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            Spacer(minLength: Slate.Metric.space2)
            meta
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    /// The status gutter glyph — the old Outline tab's treatment: a small green ✓ (succeeded), a small
    /// red ✗ (failed), a tiny spinner while running. Quieter than a filled badge; the fixed 14pt slot
    /// keeps every command's text at one left edge.
    @ViewBuilder
    private var gutter: some View {
        switch block.status {
        case .succeeded:
            Image(systemSymbol: .checkmark)
                .font(.system(size: Slate.Typeface.small, weight: .bold))
                .foregroundStyle(Slate.Status.ok)
        case .failed:
            Image(systemSymbol: .xmark)
                .font(.system(size: Slate.Typeface.small, weight: .bold))
                .foregroundStyle(Slate.Status.err)
        case .running:
            ProgressView()
                .controlSize(.mini)
        }
    }

    /// The right-aligned tertiary meta column: the bookmark star + the clock time the command ran —
    /// one quiet cluster so the command text stays the row's only loud element.
    private var meta: some View {
        HStack(spacing: Slate.Metric.space2) {
            if isBookmarked {
                Image(systemSymbol: .starFill)
                    .font(.system(size: Slate.Typeface.small))
                    .foregroundStyle(Slate.Status.warn)
            }
            if let clockTime {
                Text(clockTime)
                    .foregroundStyle(Slate.Text.tertiary)
                    .monospacedDigit()
            }
        }
        .font(.system(size: Slate.Typeface.footnote))
        .lineLimit(1)
    }
}
#endif
