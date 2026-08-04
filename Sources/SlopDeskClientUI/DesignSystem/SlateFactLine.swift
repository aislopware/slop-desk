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
//
// Deliberately NOT a grid of labelled rows. A caption sits under a title in a column two hundred
// points wide; spelling out `RUNTIME  iOS 26.5` down the side spends the width on words that never
// change and pushes the figures — the only part that does — off the end.

#if canImport(SwiftUI)
#if canImport(AppKit)
import AppKit
#endif
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

    var id: String { label }

    init(
        _ label: String, _ text: String, copies: String? = nil, tint: Color,
        isMeasured: Bool = false,
    ) {
        self.label = label
        self.text = text
        self.copies = copies ?? text
        self.tint = tint
        self.isMeasured = isMeasured
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

    private func view(for fact: SlateFact) -> some View {
        Text(fact.text)
            .font(fact.isMeasured
                ? Slate.Typeface.instrument(size, weight: .regular)
                : .system(size: size))
            .foregroundStyle(fact.tint)
            .lineLimit(1)
            .help(fact.label)
            .contextMenu {
                Button("Copy \(fact.label)") { Self.copy(fact.copies) }
            }
    }

    static func copy(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
#endif
