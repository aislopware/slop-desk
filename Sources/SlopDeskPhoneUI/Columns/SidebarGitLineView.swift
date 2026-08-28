// SidebarGitLineView — the navigator header's git line, in UIKit.
//
// The dialect is not here: which sigils, in what order, at what weight, and what gets shed as the
// column narrows are all ``SidebarGitLine``'s (SlopDeskClientCore), and the palette is
// ``Slate/Native/gitInk(_:)``'s. What IS here is the one thing neither can answer — WHICH RUNG FITS,
// which needs a measured string against a real width.
//
// ⚠️ THE SHEDDING IS MEASURED AND MEMOIZED, not guessed and not re-measured. The deleted SwiftUI half
// (`NavigatorColumn.swift:481-540`) asked `ViewThatFits` to walk five rungs and pick the first that
// fitted; UIKit has no such container, so the rungs are measured directly against the line's own
// width — and the whole ladder is built ONCE per summary, because `draw(_:)` and
// `intrinsicContentSize` are both called by UIKit (a repaint, a layout pass, every frame of a
// rotation or a split-view drag) while `summary` moves on a git poll, seconds apart.
//
// docs/62 §3.3 states that rule for the phone and points at the Mac's measurement for the numbers:
// `macui_memos` M1 timed this exact ladder in a `swiftc -O` harness at `intrinsicContentSize` 17.1 µs
// and a shedding `draw` 62 µs against 51 µs to build the ladder once and 5 ns per read after it.
//
// ⚠️ CLONE HAZARD, DELIBERATELY INCURRED AND REPORTED. ``SlopDeskMacUI/MacGitLineView`` is the same
// ladder over the same `NSAttributedString` API, which on iOS is spelled identically. The right home
// for `attributed(_:separator:)` and the `Ladder` is one floor down in `SlopDeskSlate` (both halves
// already speak `SlateNativeColor`/`SlateNativeFont`), NOT a `no-cross-target-clone` waiver row — see
// docs/62 stage H, which names this file as the campaign's likeliest new clone pair.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import SlopDeskWorkspaceCore
import UIKit

/// The git line as it PAINTS, across the widths the navigator's real column asks for.
///
/// Roomy: the whole dialect inline, branch then counts. Tight: the counts fold to
/// ``SidebarGitLine/compactStatus(_:shedding:)``'s bare sigils pinned flush to the trailing edge, one
/// cluster with no gaps so they read as a single readout rather than a second sentence. Presence is
/// what a sigil reports — `!` says there is uncommitted work at any width — so the NUMBERS retreat to
/// the accessibility hint first.
///
/// Narrower still, the branch and the readout compete for the same line, and the readout starts
/// SHEDDING down the dialect's ladder — one rung per candidate — rather than crowding the name into a
/// stub. The ladder is `slopdesk_workspace::git_line`'s, asked for by rung: this view says how much
/// room it has, never which role should go. Only when even the worktree core cannot buy the branch
/// enough room does the name truncate (tail: a long branch loses its end, which is the part that
/// repeats).
@MainActor
final class SidebarGitLineView: UIView {
    /// The line's COUNTS — the one thing this view holds, and the one thing the dialect answers from.
    /// `nil` is a collapsed header or a directory with no repo.
    var summary: PaneGitSummary? {
        didSet {
            guard summary != oldValue else { return }
            segments = summary.map(SidebarGitLine.segments) ?? []
            // The ladder is `segments` MEASURED, so it dies with them and with nothing else.
            ladder = nil
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }

    /// The whole line, written. Derived, never set: it is `summary` spelled.
    private(set) var segments: [GitSegment] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        isOpaque = false
        // ⚠️ The whole point of the ladder is that the DRAWING depends on the width, so a resize has
        // to repaint. UIKit's default `.scaleToFill` would stretch the last painted rung instead.
        contentMode = .redraw
        isAccessibilityElement = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: measured()?.height ?? 0)
    }

    // ⚠️ NO trait registration here, and that is a real difference from the AppKit twin rather than an
    // omission: `MacGitLineView` stamps nothing into a `CGColor`, and the DYNAMIC `UIColor` this
    // ladder stores in its attributed strings resolves against the trait collection at DRAW time. A
    // theme flip repaints this view with the new inks off the SAME memoized ladder, because the only
    // thing the ladder measures — the glyph widths — does not move with the appearance.

    override func draw(_: CGRect) {
        guard let ladder = measured() else { return }
        guard let name = ladder.name else {
            ladder.inline.draw(in: bounds)
            return
        }
        // Rung 0 is the whole dialect inline. Every rung after it splits the line — branch left,
        // compact sigils pinned right — and sheds one more role from the readout. The branch is held
        // at its FULL width in every rung but the last, so a rung stops fitting exactly when the name
        // would start losing characters: that is the signal to shed one more sigil instead.
        if ladder.inlineWidth <= bounds.width {
            ladder.inline.draw(in: bounds)
            return
        }
        for rung in ladder.rungs {
            // The one gap the tight form keeps: the branch never touches the readout, however little
            // room is left for it.
            guard name.width + 4 + rung.width <= bounds.width else { continue }
            draw(name.text, rung.text)
            return
        }
        // The last rung's escape hatch — the worktree core stays whole and the NAME truncates.
        guard let last = ladder.rungs.last else { return }
        draw(name.text, last.text)
    }

    // MARK: The measured ladder

    /// One written form and the width it takes — a pair, because every reader of one reads the other
    /// and `NSAttributedString.size()` is a full text layout rather than a field.
    private struct Run {
        let text: NSAttributedString
        let width: CGFloat
    }

    /// Every form this line can be drawn in, MEASURED once. `name` is `nil` for a line with no status
    /// runs at all, which is the one shape that never sheds.
    private struct Ladder {
        let inline: NSAttributedString
        let inlineWidth: CGFloat
        let height: CGFloat
        let name: Run?
        /// The four shed rungs, in ladder order — empty when there is nothing to shed.
        let rungs: [Run]
    }

    private var ladder: Ladder?

    /// ⚠️ MEMOIZED — see this file's header for the measurement that made it a rule rather than a
    /// preference. `nil` is a line with no segments, which draws nothing and claims no height.
    private func measured() -> Ladder? {
        if let ladder { return ladder }
        guard !segments.isEmpty else { return nil }
        let inline = Self.attributed(segments)
        let inlineSize = inline.size()
        // No status run at all ⇒ every segment IS the branch, so the inline form is the whole line
        // and there is nothing to shed. That is the one shape with no ladder above rung zero.
        guard segments.contains(where: { $0.ink != .branch }) else {
            let bare = Ladder(
                inline: inline, inlineWidth: inlineSize.width, height: inlineSize.height,
                name: nil, rungs: [],
            )
            ladder = bare
            return bare
        }
        let name = Self.attributed(segments.filter { $0.ink == .branch })
        let built = Ladder(
            inline: inline,
            inlineWidth: inlineSize.width,
            height: inlineSize.height,
            name: Run(text: name, width: name.size().width),
            rungs: (0...3).map { level in
                let text = Self.attributed(shed(to: level), separator: "")
                return Run(text: text, width: text.size().width)
            },
        )
        ladder = built
        return built
    }

    /// The readout at one rung of the ladder, as bare sigils. One call rather than a shed followed by
    /// a compaction: the dialect folds both in the same crossing.
    private func shed(to level: Int) -> [GitSegment] {
        guard let summary else { return [] }
        return SidebarGitLine.compactStatus(summary, shedding: level)
    }

    private func draw(_ name: NSAttributedString, _ status: NSAttributedString) {
        let statusWidth = status.size().width
        status.draw(in: CGRect(
            x: bounds.maxX - statusWidth, y: 0, width: statusWidth, height: bounds.height,
        ))
        name.draw(in: CGRect(
            x: 0, y: 0, width: CGFloat.maximum(0, bounds.width - statusWidth - 4),
            height: bounds.height,
        ))
    }

    /// The painted runs: ONE attributed string, so the whole thing still truncates as a single line (a
    /// stack of labels would clip a whole run instead of the tail). The compact form passes an EMPTY
    /// separator — bare sigils cluster tighter than they space out.
    ///
    /// The line is DATA — the instrument mono, one register with the rows' process labels. But it is
    /// data with STATES, and rendering all of them in one flat grey made the counts that matter (a
    /// conflict, unpushed work) read exactly like the ones that don't. Each run wears its own ink and
    /// weight instead; the mono grid keeps the line from turning into confetti.
    static func attributed(_ segments: [GitSegment], separator: String = " ") -> NSAttributedString {
        let line = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        for (index, segment) in segments.enumerated() {
            line.append(NSAttributedString(
                string: index == 0 ? segment.text : separator + segment.text,
                attributes: [
                    .font: Slate.Typeface.instrumentNative(
                        Slate.Typeface.small, weight: weight(segment),
                    ),
                    .foregroundColor: Slate.Native.gitInk(segment.ink),
                    .paragraphStyle: paragraph,
                ],
            ))
        }
        return line
    }

    /// A run's three rungs, in the face's own units. The RUNG is the dialect's — it arrives on the
    /// segment — so this maps and never decides.
    private static func weight(_ segment: GitSegment) -> UIFont.Weight {
        switch segment.weight {
        case .regular: .regular
        case .semibold: .semibold
        case .bold: .bold
        }
    }
}
#endif
