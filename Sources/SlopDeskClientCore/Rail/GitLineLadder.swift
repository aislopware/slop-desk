// GitLineLadder — the git line MEASURED, once, for both shells.
//
// ``SidebarGitLine`` decides the dialect: which runs the line has, in what order, at what weight,
// and which of them give up their place as the column narrows. What neither it nor the palette can
// answer is WHICH RUNG FITS, because that needs a measured string against a real width — and that
// is what this file does.
//
// ⚠️ WHY THIS IS NOT A VIEW, AND WHY IT IS NOT PER-SHELL. The measurement is `NSAttributedString`
// arithmetic and nothing else. `NSAttributedString`, `NSMutableParagraphStyle` and `draw(in:)` are
// spelled IDENTICALLY on both platforms — only the face and the colour types differ, and those are
// already one name each (``SlateNativeFont`` / ``SlateNativeColor``). So the ladder typed twice was
// forty-four lines of the same arithmetic in two targets, which is what `no-cross-target-clone`
// counts (`rust/slopdesk-invariants/src/rules/two_shells.rs`, docs/56 §3, docs/62 stage H — that
// stage named this exact pair as the campaign's likeliest new clone, and it was).
//
// The two views keep what is genuinely theirs: `MacGitLineView` is `isFlipped` and repaints via
// `needsDisplay`, `SidebarGitLineView` sets `contentMode = .redraw` and repaints via
// `setNeedsDisplay()`. Neither difference is arithmetic.
//
// ⚠️ MEMOIZED, and this is the whole reason the type exists rather than a free function. `draw(_:)`
// and `intrinsicContentSize` are both called by the framework — a repaint, a layout pass, every
// frame of a sidebar divider drag or a split-view drag — while `summary` moves on a git poll,
// seconds apart. Measured in a scratch `swiftc -O` harness against this exact ladder (8 runs, a
// 24-character branch): `intrinsicContentSize` **17.1 µs**, the shedding `draw` **62 µs**, the roomy
// `draw` **20 µs**; building the ladder once costs **51 µs** and every read after it is **5 ns**.
// Six project islands re-measuring on one 60 fps drag frame is ~370 µs of a 16.6 ms budget, to
// answer a question whose inputs did not move. `macui_memos` M1 and docs/62 §3.3 carry the numbers.

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

import SlopDeskSlate
import SlopDeskWorkspaceCore

/// The git line in every form it can be drawn in, measured once.
///
/// Roomy: the whole dialect inline, branch then counts. Tight: the counts fold to
/// ``SidebarGitLine/compactStatus(_:shedding:)``'s bare sigils pinned flush to the trailing edge,
/// one cluster with no gaps so they read as a single readout rather than a second sentence. Presence
/// is what a sigil reports — `!` says there is uncommitted work at any width — so the NUMBERS
/// retreat to the accessibility hint first.
///
/// Narrower still, the branch and the readout compete for the same line, and the readout starts
/// SHEDDING down the dialect's ladder — one rung per candidate — rather than crowding the name into
/// a stub. Only when even the worktree core cannot buy the branch enough room does the name truncate
/// (tail: a long branch loses its end, which is the part that repeats).
///
/// The whole ladder exists because one tail-truncating line took the counts down WITH the branch:
/// `feature/some-very-long-name…` spelled three more characters of a name you already know and ate
/// the readout you were actually watching.
/// `@MainActor` because the faces and the inks are: ``Slate/Typeface/instrumentNative(_:weight:)``
/// and ``Slate/Native/gitInk(_:)`` are main-actor-isolated, and both callers are views. The type is
/// a VALUE all the same — nothing here is shared across actors, so the isolation costs nothing.
@MainActor
package struct GitLineLadder {
    /// One written form and the width it takes — a pair, because every reader of one reads the other
    /// and `NSAttributedString.size()` is a full text layout rather than a field.
    private struct Run {
        let text: NSAttributedString
        let width: CGFloat
    }

    private let inline: NSAttributedString
    private let inlineWidth: CGFloat
    /// The branch alone, `nil` for a line with no status runs at all — the one shape that never
    /// sheds.
    private let name: Run?
    /// The four shed rungs, in ladder order — empty when there is nothing to shed.
    private let rungs: [Run]

    /// The height the line claims, at any width: the runs are one register, so shedding never
    /// changes it.
    package let height: CGFloat

    /// The gap the tight form keeps: the branch never touches the readout, however little room is
    /// left for it. Not a spacing rung — it is the minimum legible separation between two runs of
    /// one line, which is a fact about this line rather than about the ladder.
    private static let gap: CGFloat = 4

    /// Measures every form of `summary`'s line. `nil` is a collapsed header, a directory with no
    /// repo, or any summary the dialect spells as nothing — which draws nothing and claims no
    /// height.
    package init?(_ summary: PaneGitSummary?) {
        guard let summary else { return nil }
        let segments = SidebarGitLine.segments(summary)
        guard !segments.isEmpty else { return nil }
        inline = Self.attributed(segments)
        let inlineSize = inline.size()
        inlineWidth = inlineSize.width
        height = inlineSize.height
        // No status run at all ⇒ every segment IS the branch, so the inline form is the whole line
        // and there is nothing to shed. That is the one shape with no ladder above rung zero.
        guard segments.contains(where: { $0.ink != .branch }) else {
            name = nil
            rungs = []
            return
        }
        let branch = Self.attributed(segments.filter { $0.ink == .branch })
        name = Run(text: branch, width: branch.size().width)
        rungs = (0...3).map { level in
            // One call rather than a shed followed by a compaction: the dialect folds both in the
            // same crossing.
            let text = Self.attributed(SidebarGitLine.compactStatus(summary, shedding: level), separator: "")
            return Run(text: text, width: text.size().width)
        }
    }

    /// Paints the widest rung that fits `bounds`.
    ///
    /// Rung 0 is the whole dialect inline. Every rung after it splits the line — branch left,
    /// compact sigils pinned right — and sheds one more role from the readout. The branch is held at
    /// its FULL width in every rung but the last, so a rung stops fitting exactly when the name
    /// would start losing characters: that is the signal to shed one more sigil instead.
    package func draw(in bounds: CGRect) {
        guard let name else {
            inline.draw(in: bounds)
            return
        }
        if inlineWidth <= bounds.width {
            inline.draw(in: bounds)
            return
        }
        for rung in rungs where name.width + Self.gap + rung.width <= bounds.width {
            split(name.text, rung.text, in: bounds)
            return
        }
        // The last rung's escape hatch — the worktree core stays whole and the NAME truncates.
        guard let last = rungs.last else { return }
        split(name.text, last.text, in: bounds)
    }

    private func split(_ name: NSAttributedString, _ status: NSAttributedString, in bounds: CGRect) {
        let statusWidth = status.size().width
        status.draw(in: CGRect(
            x: bounds.maxX - statusWidth, y: 0, width: statusWidth, height: bounds.height,
        ))
        name.draw(in: CGRect(
            x: 0, y: 0, width: CGFloat.maximum(0, bounds.width - statusWidth - Self.gap),
            height: bounds.height,
        ))
    }

    /// The painted runs: ONE attributed string, so the whole thing still truncates as a single line
    /// (a stack of labels would clip a whole run instead of the tail). The compact form passes an
    /// EMPTY separator — bare sigils cluster tighter than they space out.
    ///
    /// The line is DATA — the instrument mono, one register with the rows' process labels. But it is
    /// data with STATES, and rendering all of them in one flat grey made the counts that matter (a
    /// conflict, unpushed work) read exactly like the ones that don't. Each run wears its own ink
    /// and weight instead; the mono grid keeps the line from turning into confetti.
    package static func attributed(
        _ segments: [GitSegment], separator: String = " ",
    ) -> NSAttributedString {
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
    private static func weight(_ segment: GitSegment) -> SlateNativeFont.Weight {
        switch segment.weight {
        case .regular: .regular
        case .semibold: .semibold
        case .bold: .bold
        }
    }
}
