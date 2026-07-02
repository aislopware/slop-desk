// BlockRowView — one command-block row in the Commands inspector (REBUILD-V2, L3).
//
// A compact, Warp-style row: a leading status icon (green/secondary/red by status; a small spinner
// overlaid while running), the command text in a monospaced font (truncating), and a trailing caption
// pairing the status label ("exit 0" / "running…") with the duration ("1.3s" / "340ms").
//
// PURE presentation over a `CommandBlock` value (the model's derived `statusSymbol` / `statusLabel` /
// `durationLabel` / `status` do all the mapping). SYSTEM colours, SF Symbols + system/monospaced fonts
// only — NO design-system.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI

struct BlockRowView: View {
    let block: CommandBlock
    /// Whether the block is bookmarked — shows a trailing star so a starred block reads at a glance.
    var isBookmarked: Bool = false
    /// The block's coarse relative first-seen stamp ("4m", "2h" — `OutlinePresentation.relativeTime`),
    /// shown right-aligned. `nil` hides the column (an unknown / evicted first-seen). Folded in from the
    /// old standalone Outline tab when it merged into this panel.
    var relativeTime: String?

    /// The status tint: green for success, red for a failure, secondary while running.
    private var statusTint: Color {
        switch block.status {
        case .running: Slate.Text.secondary
        case .succeeded: Slate.Status.ok
        case .failed: Slate.Status.err
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(block.commandText.isEmpty ? "(no command)" : block.commandText)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(block.commandText.isEmpty ? Slate.Text.secondary : Slate.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                caption
            }
            Spacer(minLength: 0)
            if isBookmarked {
                Image(systemSymbol: .starFill)
                    .font(.caption2)
                    .foregroundStyle(Slate.Status.warn)
            }
            if let relativeTime {
                Text(relativeTime)
                    .font(.caption)
                    .foregroundStyle(Slate.Text.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// The leading status glyph; a small spinner is overlaid (not replacing) while the block runs so the
    /// row keeps a stable leading width.
    private var statusIcon: some View {
        ZStack {
            Image(systemName: block.statusSymbol)
                .foregroundStyle(statusTint)
                .opacity(block.status == .running ? 0.35 : 1)
            if block.status == .running {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: 18, height: 18)
        .font(.system(size: Slate.Typeface.body))
    }

    /// The trailing caption: status label + an optional duration, both secondary + small.
    private var caption: some View {
        HStack(spacing: 6) {
            Text(block.statusLabel)
                .foregroundStyle(block.isFailed ? Slate.Status.err : Slate.Text.secondary)
            if let duration = block.durationLabel {
                Text("·").foregroundStyle(Slate.Text.tertiary)
                Text(duration).foregroundStyle(Slate.Text.secondary)
            }
        }
        .font(.caption)
        .lineLimit(1)
    }
}
#endif
