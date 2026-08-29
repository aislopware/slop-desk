// SidebarGitLineView — the navigator header's git line, in UIKit.
//
// The dialect is not here: which sigils, in what order, at what weight, and what gets shed as the
// column narrows are all ``SidebarGitLine``'s (SlopDeskClientCore), and the palette is
// ``Slate/Native/gitInk(_:)``'s. The MEASURING is not here either — ``GitLineLadder`` builds and
// memoizes every rung, one floor down and shared with ``SlopDeskMacUI/MacGitLineView``, because the
// whole ladder is `NSAttributedString` arithmetic and both platforms spell that identically. The
// file header that used to stand here called that clone "deliberately incurred and reported" and
// named the fix; docs/62 stage H is where it landed.
//
// What is left is what UIKit alone asks for: `contentMode = .redraw`, `setNeedsDisplay()`, and the
// intrinsic height the ladder measured.
//
// ⚠️ NO trait registration here, and that is a real difference from the AppKit twin rather than an
// omission: the ladder stamps nothing into a `CGColor`, and the DYNAMIC `UIColor` it stores in its
// attributed strings resolves against the trait collection at DRAW time. A theme flip repaints this
// view with the new inks off the SAME memoized ladder, because the only thing the ladder measures —
// the glyph widths — does not move with the appearance.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import SlopDeskWorkspaceCore
import UIKit

/// The git line as it PAINTS, across the widths the navigator's real column asks for.
///
/// See ``GitLineLadder`` for what "across the widths" means — the roomy inline form, the tight one
/// with the counts pinned right, and the four shed rungs between them.
@MainActor
final class SidebarGitLineView: UIView {
    /// The line's COUNTS — the one thing this view holds, and the one thing the dialect answers from.
    /// `nil` is a collapsed header or a directory with no repo.
    var summary: PaneGitSummary? {
        didSet {
            guard summary != oldValue else { return }
            // The ladder is `summary` MEASURED, so it dies with it and with nothing else.
            ladder = GitLineLadder(summary)
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }

    /// Whether the line has anything to say — the header hides an empty one rather than reserving a
    /// blank register for it.
    var isEmpty: Bool { ladder == nil }

    /// ⚠️ MEMOIZED — see ``GitLineLadder`` for the measurement that made it a rule rather than a
    /// preference. Built on the `summary` write, never in `draw(_:)`.
    private var ladder: GitLineLadder?

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
        CGSize(width: UIView.noIntrinsicMetric, height: ladder?.height ?? 0)
    }

    override func draw(_: CGRect) {
        ladder?.draw(in: bounds)
    }
}
#endif
