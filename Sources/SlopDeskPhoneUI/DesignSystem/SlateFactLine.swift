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

#if os(iOS)
import SlopDeskSlate
import SlopDeskWorkspaceCore
// ⚠️ THE LAST SwiftUI IN THIS FILE, and it is one type: ``SlateFact/tint`` is still a `Color`, so the
// draw bridges it with `UIColor(_:)`. Nothing here builds a `View`. The import goes when the Slate
// token collapses to its native spelling.
import SwiftUI
import UIKit

/// One measured fact in a ``SlateFactLineView``.
struct SlateFact: Identifiable {
    /// Names the fact, in title case — the tooltip, the Copy verb, and the row's identity. Unique
    /// within one line, which is what lets the line animate a fact in or out without reshuffling.
    let label: String
    /// What is drawn. May be an abbreviation of ``copies`` (a shortened UDID, a rounded figure).
    let text: String
    /// What Copy hands over — the WHOLE value, never the abbreviation. The reason the short form is
    /// safe to draw at all is that the full one is one right-click away.
    var copies: String
    /// ⚠️ Still SwiftUI-typed — see the note on the imports. The renderer bridges it at the draw.
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
@MainActor
final class SlateFactLineView: UIView {
    /// Assigning rebuilds the run. ⚠️ UNANIMATED, and deliberately: the `smallFade` on a fact
    /// appearing or leaving is spent by the CALLER, around its own state change — a line that faded
    /// on every assignment would fade for a re-measure that changed one digit.
    var facts: [SlateFact] = [] { didSet { restage() } }

    /// Point size for the whole line — one size, so a run of facts reads as one sentence.
    private let size: CGFloat
    private let run = UIStackView()

    init(size: CGFloat = Slate.Typeface.footnote) {
        self.size = size
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        run.translatesAutoresizingMaskIntoConstraints = false
        run.axis = .horizontal
        // Centre, not baseline: the mono and the proportional face on one line have different metrics,
        // and centring is what keeps a run of mixed facts sitting on one visual line.
        run.alignment = .center
        run.spacing = Slate.Metric.space1
        addSubview(run)
        NSLayoutConstraint.activate([
            run.leadingAnchor.constraint(equalTo: leadingAnchor),
            run.topAnchor.constraint(equalTo: topAnchor),
            run.bottomAnchor.constraint(equalTo: bottomAnchor),
            // The run is LEFT-SET and any surplus width is slack, never distributed into the gaps.
            run.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// The run and its interleaved separators, as arranged subviews. Torn down whole rather than
    /// diffed: a fact line is a handful of labels, and ``SlateFact/id`` — the only thing a diff could
    /// key on — exists for an ANIMATION there is none of here (see ``facts``).
    private func restage() {
        for view in run.arrangedSubviews {
            run.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, fact) in facts.enumerated() {
            // Rule 3: the middle dot belongs to the LINE, so it is minted between facts and can never
            // be left dangling by a fact that went away.
            if index > 0 { run.addArrangedSubview(separator()) }
            run.addArrangedSubview(SlateFactView(fact: fact, size: size))
        }
    }

    private func separator() -> UILabel {
        let dot = UILabel()
        dot.text = "·"
        dot.font = .systemFont(ofSize: size)
        dot.textColor = Slate.Native.Text.tertiary
        dot.isAccessibilityElement = false
        dot.setContentCompressionResistancePriority(.required, for: .horizontal)
        return dot
    }
}

/// One fact: its grey label and its value, as ONE hit target — the tooltip, the Copy menu and the
/// truncation all belong to the pair, not to the word in front of it.
///
/// A TYPE rather than a build step, because UIKit's tooltip and menu are INTERACTIONS: they attach to
/// a view, where a declarative `.help`/`.contextMenu` pair would have wrapped one.
@MainActor
private final class SlateFactView: UIView, UIContextMenuInteractionDelegate {
    private let fact: SlateFact
    private let labelText = UILabel()
    private let valueText = UILabel()

    init(fact: SlateFact, size: CGFloat) {
        self.fact = fact
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let pair = UIStackView()
        pair.translatesAutoresizingMaskIntoConstraints = false
        pair.axis = .horizontal
        pair.alignment = .center
        pair.spacing = Slate.Metric.space1

        if fact.showsLabel {
            labelText.text = fact.label
            labelText.font = .systemFont(ofSize: size)
            labelText.numberOfLines = 1
            // The grey word is what gives way first, so a squeezed line keeps its FIGURES and loses
            // the word naming them.
            labelText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            pair.addArrangedSubview(labelText)
        }
        // Rule 1: a measured fact is a READING and wears the instrument face; a named one is a phrase
        // and stays in the system face. One line can hold both, and that is the point.
        valueText.text = fact.text
        valueText.font = fact.isMeasured
            ? Slate.Typeface.instrumentNative(size, weight: .regular)
            : .systemFont(ofSize: size)
        valueText.numberOfLines = 1
        valueText.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        pair.addArrangedSubview(valueText)

        addSubview(pair)
        NSLayoutConstraint.activate([
            pair.leadingAnchor.constraint(equalTo: leadingAnchor),
            pair.trailingAnchor.constraint(equalTo: trailingAnchor),
            pair.topAnchor.constraint(equalTo: topAnchor),
            pair.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Rule 2's tooltip — pointer-only, and that is the whole of it: the label names the fact for
        // whoever hovers it.
        addInteraction(UIToolTipInteraction(defaultToolTip: fact.label))
        // Rule 2's Copy. A long press on the phone, a right-click with a trackpad.
        addInteraction(UIContextMenuInteraction(delegate: self))

        // Rule 2 again, for VoiceOver: the pair reads as one thing, because it IS one.
        isAccessibilityElement = true
        accessibilityLabel = fact.showsLabel ? "\(fact.label) \(fact.text)" : fact.text

        ink()
        // ⚠️ `UIColor(_: Color)` is a BRIDGE — ``SlateFact/tint`` is still SwiftUI-typed, which is
        // the last SwiftUI thing in this file and the reason `import SwiftUI` survives it. A bridged
        // dynamic colour is only as dynamic as what it wrapped, so re-taking it on the one trait that
        // decides the answer costs nothing and removes the question; the bridge itself goes when the
        // token collapses to `UIColor`.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _: UITraitCollection) in
            view.ink()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// A fact is TEXT, so it reports the value's baseline rather than its own bottom edge — a caller
    /// that baseline-aligns this against a title gets the alignment it asked for.
    override var forFirstBaselineLayout: UIView { valueText }
    override var forLastBaselineLayout: UIView { valueText }

    private func ink() {
        labelText.textColor = Slate.Native.Text.tertiary
        valueText.textColor = UIColor(fact.tint)
    }

    func contextMenuInteraction(
        _: UIContextMenuInteraction, configurationForMenuAtLocation _: CGPoint,
    ) -> UIContextMenuConfiguration? {
        // The label names the fact, so the verb reads "Copy Resolution" rather than "Copy".
        let title = "Copy \(fact.label)"
        // ⚠️ Only the STRING is captured, never `self` or the fact: the menu outlives the gesture, and
        // a handler that reaches back into a view is a handler that can run against a dead one.
        let copies = fact.copies
        let copy = UIAction(title: title) { _ in
            // Through the ONE funnel, never a second `UIPasteboard.general` pair: the clear-then-write
            // and the platform fork both belong to ``ClientPasteboard/write(_:)``, and a copy of them
            // here is the drift its gate exists to catch. `assumeIsolated` because a menu handler is
            // already delivered on the main actor; it is the assertion, not a hop.
            MainActor.assumeIsolated { ClientPasteboard.write(copies) }
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [copy])
        }
    }
}
#endif
