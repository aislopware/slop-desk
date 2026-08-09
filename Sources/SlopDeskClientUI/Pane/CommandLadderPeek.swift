// CommandLadderPeek — the command ladder's HOVER PEEK (user-directed 2026-08-09): dwell on a tick
// for a beat and the ladder opens a card beside it carrying that command, its outcome, and a short
// excerpt of what it printed.
//
// IT IS A MODE, NOT A TOOLTIP. The first tick costs a dwell; from then on the ladder is ARMED and
// moving down it swaps the card at once, so reading back through a session is one gesture rather
// than one-second-per-command. Leaving the rail disarms it after a short grace — long enough to
// cross the gap to the card, short enough that the mode never outlives the reading.
//
// The excerpt follows the OUTCOME (``BlockOutputPreviewBuilder``): a clean command is read from its
// first lines, a failed one from its last, because the first lines of a failing build are the same
// banner every build prints. The card says which end it took.
//
// The card is drawn in the GLASS's own vocabulary (``Slate/Terminal``) and in the mono face, because
// it is terminal output shown inside the terminal island — a paper card here would be a bright plate
// over the glass carrying dark-on-light terminal text. It NEVER takes a hit
// (`allowsHitTesting(false)`): the ladder's whole rule is that nothing it draws can intercept a
// click meant for a cell, and a 320pt card hanging over the pane is the biggest way to break it.

#if canImport(SwiftUI)
import SlopDeskWorkspaceCore
import SwiftUI

/// The peek's TIMING and GEOMETRY — pure + static, so the dwell rule and the card's placement are
/// unit-pinned without a window server.
enum CommandLadderPeekLayout {
    /// How long the pointer must rest on a tick before the peek ARMS. A beat: long enough that
    /// sweeping the pointer across the rail on the way somewhere else opens nothing.
    static let dwell: Duration = .seconds(1)

    /// How long the peek survives the pointer leaving the rail. Covers the crossing of the gap and a
    /// jittery exit at the rail's edge; past it the mode is over and the next tick costs a dwell again.
    static let grace: Duration = .milliseconds(400)

    /// The card's height for an excerpt of `lineCount` lines, with a footer row when some output was
    /// left out. DECLARED rather than measured so the placement below can be solved before the card
    /// is drawn — a measured height would put the card at the wrong y for one frame.
    static func cardHeight(lineCount: Int, hasFooter: Bool) -> CGFloat {
        let rows = CGFloat(max(0, lineCount) + (hasFooter ? 1 : 0))
        // header row + hairline + the excerpt rows, inside the card's own padding.
        return Slate.Metric.space2 * 2 + Slate.Metric.ladderPeekLine + Slate.Metric.hairline
            + Slate.Metric.space1 * 2 + rows * Slate.Metric.ladderPeekLine
    }

    /// The card's TOP, in the rail's own coordinate space, for a card of `cardHeight` opened against
    /// the tick centred at `tickCenterY` in a rail `available` points tall.
    ///
    /// Centred on the tick, then CLAMPED inside the pane with ``Slate/Metric/ladderInset`` to spare —
    /// the same inset the ladder itself holds off the pane's ends, so a card opened from the newest
    /// tick (which sits at the very bottom) rides up instead of hanging out of the island. A card
    /// taller than the pane pins to the top rather than centring its overflow across both edges.
    static func cardTop(tickCenterY: CGFloat, cardHeight: CGFloat, available: CGFloat) -> CGFloat {
        let margin = Slate.Metric.ladderInset
        let ideal = tickCenterY - cardHeight / 2
        let lowest = available - margin - cardHeight
        guard lowest > margin else { return margin }
        return Swift.min(Swift.max(ideal, margin), lowest)
    }
}

/// One block's peek content as the ladder knows it: still being fetched, ready, or nothing to show.
/// `Equatable` so the card animates on a real content change rather than on every re-render.
enum CommandLadderPeekEntry: Equatable {
    /// The output request is in flight (wire type 15 → 29).
    case loading
    /// The excerpt arrived. An `isEmpty` preview means the command printed nothing.
    case ready(BlockOutputPreview)
    /// No output to show: the host evicted the block, the link is down, or the command is still
    /// running (the host retains output only once a command COMPLETES —
    /// `CommandBlockTracker.ingest` only holds `completed` blocks).
    case unavailable

    /// How many excerpt rows this entry draws — the card's height is solved from it before the card
    /// exists, so every state that can be shown must be able to state its own row count.
    var lineCount: Int {
        switch self {
        case .loading,
             .unavailable:
            1 // the one quiet row: the loading beat / the reason there is nothing
        case let .ready(preview):
            preview.isEmpty ? 1 : preview.lines.count
        }
    }

    /// Whether the card carries the trailing "what was left out" row.
    var hasFooter: Bool {
        if case let .ready(preview) = self { return preview.hiddenCount > 0 }
        return false
    }
}

/// The peek CARD — the command, its outcome, and the excerpt, drawn on the glass beside its tick.
struct CommandLadderPeekCard: View {
    let block: CommandBlock
    let entry: CommandLadderPeekEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(Slate.Terminal.edge)
                .frame(height: Slate.Metric.hairline)
                .padding(.vertical, Slate.Metric.space1)
            excerpt
        }
        .padding(Slate.Metric.space2)
        .frame(width: Slate.Metric.ladderPeekWidth, alignment: .leading)
        .background(Slate.Terminal.raised, in: shape)
        .overlay { shape.strokeBorder(Slate.Terminal.edge, lineWidth: Slate.Metric.hairline) }
        .slateShadow(.panel, color: Slate.State.overlayShadow)
        // A preview must never be a target: the ladder's rule is that nothing it draws intercepts a
        // click meant for a cell, and this is the largest thing it draws.
        .allowsHitTesting(false)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Slate.Metric.radiusCard, style: .continuous)
    }

    /// The command line and its outcome on one row — the command truncates, the outcome never does.
    private var header: some View {
        HStack(spacing: Slate.Metric.space2) {
            Text(block.commandText.isEmpty ? "(command)" : block.commandText)
                .font(Slate.Typeface.instrument(Slate.Typeface.footnote))
                .foregroundStyle(Slate.Terminal.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Text(outcomeLabel)
                .font(Slate.Typeface.instrument(Slate.Typeface.small))
                .foregroundStyle(outcomeInk)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .frame(height: Slate.Metric.ladderPeekLine)
    }

    @ViewBuilder
    private var excerpt: some View {
        switch entry {
        case .loading:
            note("…")
        case let .ready(preview) where preview.isEmpty:
            note("no output")
        case let .ready(preview):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(preview.lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(Slate.Typeface.instrument(Slate.Typeface.footnote))
                        .foregroundStyle(Slate.Terminal.ink)
                        .lineLimit(1)
                        .frame(
                            height: Slate.Metric.ladderPeekLine,
                            alignment: .leading,
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if preview.hiddenCount > 0 { note(hiddenLabel(preview)) }
            }
        case .unavailable:
            note(block.status == .running ? "still running" : "output unavailable")
        }
    }

    /// A quiet one-row line in the excerpt's own rhythm — the loading beat, the empty case, and the
    /// "what was left out" footer all speak in it, so the card's height stays computable.
    private func note(_ text: String) -> some View {
        Text(text)
            .font(Slate.Typeface.instrument(Slate.Typeface.footnote))
            .foregroundStyle(Slate.Terminal.ink2)
            .lineLimit(1)
            .frame(height: Slate.Metric.ladderPeekLine, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Says WHICH END the excerpt came from, not merely how much is missing — the count alone would
    /// read as "there is more below" even when the card is showing the tail of a failure.
    private func hiddenLabel(_ preview: BlockOutputPreview) -> String {
        preview.fromTail ? "\(preview.hiddenCount) lines above" : "+\(preview.hiddenCount) more lines"
    }

    private var outcomeLabel: String {
        let duration = block.durationLabel.map { " · \($0)" } ?? ""
        switch block.status {
        case .running: return "running…"
        case .succeeded: return "exit \(block.exitCode ?? 0)\(duration)"
        case let .failed(code): return "exit \(code)\(duration)"
        }
    }

    /// The same three inks the tick itself is dealt — the card is that tick, opened.
    private var outcomeInk: Color {
        switch block.status {
        case .running: Slate.Terminal.accent
        case .succeeded: Slate.Terminal.ok
        case .failed: Slate.Terminal.err
        }
    }
}
#endif
