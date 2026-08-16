// SlateFactLine — a run of MEASURED facts under the thing they describe.
//
// The shape recurs wherever chrome captions a live object: a runtime and a pixel size under a device
// name, a codec and a bitrate under a stream, a branch and an ahead/behind count under a project. It
// is always the same three rules, and they are worth stating once rather than re-deciding per
// surface:
//
//   1. FIGURES SPEAK THE INSTRUMENT VOICE (MERIDIAN L2). `1206 × 2622` in the proportional face is a
//      phrase; in the mono face it is a reading. Prose facts (a runtime name, an orientation) stay in
//      the system face, so the line itself tells you which of its parts were measured.
//   2. EVERY FACT IS COPYABLE ON ITS OWN. A caption whose figures can only be retyped is decoration.
//      Each carries its own label, its own tooltip and its own Copy — the label names the fact, so a
//      menu item reads "Copy Resolution" rather than "Copy".
//   3. THE SEPARATOR IS A MIDDLE DOT, and it belongs to the line rather than to the facts. Facts
//      appear and disappear (a position is only pinned sometimes, an orientation is only worth
//      printing when it is not portrait), and a separator baked into a fact's own text leaves a
//      dangling `·` the moment its neighbour goes away.
//   4. THE LABEL IS DRAWN, not just hovered — grey, ahead of its value, on the same line. A run like
//      `1206 × 2622 · 01D1D359` is a riddle at rest: correct, unreadable, and it makes a panel look
//      generated rather than designed. `Resolution 1206 × 2622` costs one grey word and the line
//      becomes legible without the pointer (user-directed 2026-08-04, against a reference design
//      that labels every figure this way).
//
// Facts that appear ONLY when abnormal can opt out via `showsLabel`. Their presence is already the
// news — an orientation prints at all only when it is not portrait — and in a column this narrow the
// label would push the always-present facts off the end.
//
// Still deliberately NOT a grid of labelled ROWS. Inline is one word ahead of a value; a grid spends
// a whole column of width on words that never change, and a caption under a title has no width to
// spend.

#if canImport(SwiftUI)
import SlopDeskWorkspaceCore
import SwiftUI

/// One measured fact in a ``SlateFactLine``.
struct SlateFact: Identifiable {
    /// Names the fact, in title case — the tooltip, the Copy verb, and the row's identity. Unique
    /// within one line, which is what lets the line animate a fact in or out without reshuffling.
    let label: String
    /// What is drawn. May be an abbreviation of ``copies`` (a shortened UDID, a rounded figure).
    let text: String
    /// What Copy hands over — the WHOLE value, never the abbreviation. The reason the short form is
    /// safe to draw at all is that the full one is one right-click away.
    var copies: String
    var tint: Color
    /// Whether this fact was MEASURED. Measured facts render mono; named ones render in the system
    /// face. Not a styling flag with a technical name — the distinction is what rule 1 is about.
    var isMeasured = false
    /// Whether the label is DRAWN ahead of the value. False for a fact that only appears when it is
    /// abnormal — its presence is the news, and the width is worth more to its neighbours.
    var showsLabel = true

    var id: String { label }

    init(
        _ label: String, _ text: String, copies: String? = nil, tint: Color,
        isMeasured: Bool = false, showsLabel: Bool = true,
    ) {
        self.label = label
        self.text = text
        self.copies = copies ?? text
        self.tint = tint
        self.isMeasured = isMeasured
        self.showsLabel = showsLabel
    }
}

/// The facts, middle-dot separated, each with its own tooltip and Copy.
struct SlateFactLine: View {
    let facts: [SlateFact]
    /// Point size for the whole line — one size, so a run of facts reads as one sentence. Defaults to
    /// the caption rung.
    var size: CGFloat = Slate.Typeface.footnote

    var body: some View {
        HStack(spacing: Slate.Metric.space1) {
            ForEach(Array(facts.enumerated()), id: \.element.id) { index, fact in
                if index > 0 { separator }
                view(for: fact)
            }
            Spacer(minLength: 0)
        }
    }

    private var separator: some View {
        Text("·")
            .font(.system(size: size))
            .foregroundStyle(Slate.Text.tertiary)
    }

    /// The label and its value are ONE hit target — the tooltip, the Copy menu and the truncation all
    /// belong to the pair, not to the word in front of it.
    private func view(for fact: SlateFact) -> some View {
        HStack(spacing: Slate.Metric.space1) {
            if fact.showsLabel {
                Text(fact.label)
                    .font(.system(size: size))
                    .foregroundStyle(Slate.Text.tertiary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            Text(fact.text)
                .font(fact.isMeasured
                    ? Slate.Typeface.instrument(size, weight: .regular)
                    : .system(size: size))
                .foregroundStyle(fact.tint)
                .lineLimit(1)
        }
        .help(fact.label)
        .contextMenu {
            Button("Copy \(fact.label)") { Self.copy(fact.copies) }
        }
    }

    /// Through the ONE funnel, never a second `NSPasteboard.general` pair. The clear-then-write is
    /// load-bearing on AppKit and the platform fork belongs with it, both of which
    /// ``ClientPasteboard/write(_:)`` already owns; a copy of them here is the drift that gate
    /// exists to catch.
    static func copy(_ text: String) { ClientPasteboard.write(text) }
}
#endif
