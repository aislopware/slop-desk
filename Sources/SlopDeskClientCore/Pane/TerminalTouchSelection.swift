// TerminalTouchSelection — what a finger held over the terminal grid means, decided once.
//
// The Mac selects terminal text with a pointer: a press starts a selection, motion extends it, a release
// leaves it standing, and a right-click asks what to do with it. A phone has none of those events — a touch
// is ambiguous until it has lasted long enough to say what it is — so the phone's half of the libghostty
// embedder (`ThirdParty/ghostty/integration/GhosttySurface/GhosttyTerminalView.swift`, the `#elseif os(iOS)`
// block) turns a LONG PRESS into that same press/motion/release triple. libghostty owns everything after
// that: the selection state, its painting, the granularity, and the text extraction — exactly as on the Mac,
// where the AppKit view also only forwards.
//
// What is left over is this file: the four numbers and two rules the gesture needs but libghostty cannot
// answer, which would otherwise be typed into a UIKit view where nothing can reach them. They are kept here
// rather than beside the recognizer for the reason docs/56 §3 gives — a decision lives below the UI and each
// half actuates it — and because the Mac's own pointer path will want the same edge ramp the day a trackpad
// drag on an iPad runs through it.
//
// ⚠️ NOTHING HERE MEASURES A CELL. A touch point goes to libghostty as POINTS (`sendMousePos`), which applies
// the content scale and resolves the cell itself, so there is no point→cell arithmetic on this path and no
// second copy of the grid geometry `TerminalCellMetrics` (`Sources/SlopDeskTerminal/TerminalSurface.swift`)
// already owns. `linkHitSlop` does not break that and is the reason to say it again: it is a distance a
// FINGER is wrong by, in points, and the only thing that ever compares it to a cell is
// `TerminalLinkHitTest`, which is where the grid arithmetic lives for both platforms.

import Foundation

/// The phone's touch-selection thresholds and the two decisions around them — PURE, so the ramp is
/// pinnable without a touch.
public enum TerminalTouchSelection {
    // MARK: - The long press that starts a selection

    /// How long a finger must rest before the touch becomes a SELECTION rather than a click.
    ///
    /// Below UIKit's own 0.5s default on purpose: the system default is tuned for a press that opens a
    /// menu, and this one only ARMS a drag the user then has to make, so the extra 100ms reads as lag
    /// rather than as deliberation. Still long enough that a tap meant for a mouse-mode TUI (which the
    /// tap recognizer forwards as a click report) never crosses it.
    public static let longPressDuration: TimeInterval = 0.4

    /// How far the finger may wander (points) BEFORE recognition without cancelling the long press.
    ///
    /// Wider than UIKit's 10pt default because the competing gesture on this view is a scroll pan: a
    /// finger that means to select is resting, and a finger that means to scroll has already travelled
    /// far past this by the time the press would fire. Past `.began` the movement no longer cancels —
    /// it IS the selection drag.
    public static let longPressAllowableMovement: Double = 12

    /// How far off a detected path / URL a finger may land and still be understood to have pressed it
    /// (points), fed to ``TerminalLinkHitTest/link(in:metrics:pointX:pointY:slop:)`` when the long-press
    /// menu asks what it is being offered ON. The Mac passes nothing at all and keeps its exact cell
    /// reading — a pointer lands where it is aimed.
    ///
    /// A fingertip does not. The contact patch is tens of points across and the centre UIKit reports is a
    /// guess at its middle, while a cell at the default face is about 8 × 17 points — so a press a person
    /// would swear landed on `src/lib.rs:42` can resolve a cell or two off it, and unlike the pointer
    /// there is no hover to correct the aim before the menu opens. One long press is the whole
    /// interaction.
    ///
    /// Deliberately SMALLER than ``longPressAllowableMovement``, which is the same kind of number for the
    /// same finger one step earlier (how far it may wander before the press is even recognized): a press
    /// that stayed still enough to be a press should not then be re-aimed further than it was allowed to
    /// drift. It is not a 44pt touch target either — that is the minimum size for a control drawn at a
    /// known place, and this is a correction applied to a target the terminal placed, several of which sit
    /// side by side in one line of compiler output. Wide enough to forgive the aim, narrow enough that the
    /// menu still names the path the user was looking at.
    public static let linkHitSlop: Double = 10

    // MARK: - Edge autoscroll (a selection drag that reaches the top or bottom)

    /// The band at the top and bottom of the surface (points) inside which a live selection drag scrolls
    /// the viewport. Roughly two grid rows at the default face — deep enough to hit with a finger that is
    /// already at the edge of the glass, shallow enough that a drag across the last visible row does not
    /// scroll by accident.
    public static let autoScrollEdgeInset: Double = 28

    /// The scroll fed per display tick (points) at FULL overshoot — the finger at or past the surface
    /// edge. At 60Hz this is ~540 points/second, a little under two screens per second on a phone: fast
    /// enough to reach an off-screen line without lifting, slow enough to stop on one.
    public static let autoScrollPointsPerTick: Double = 9

    /// The scroll delta a live selection drag should feed per tick with the finger at `y` in a surface
    /// `viewHeight` points tall, or `0` when the finger is in the middle and nothing should scroll.
    ///
    /// SIGN — the same convention `handlePanToScroll` documents in the embedder: a POSITIVE `deltaY`
    /// reveals OLDER lines. So the finger at the TOP edge (reaching up, past the first visible row)
    /// scrolls POSITIVE, and at the BOTTOM edge NEGATIVE. The ramp is linear in the overshoot, clamped at
    /// one inset of overshoot, so a finger just inside the band creeps and a finger held past the glass
    /// edge runs at ``autoScrollPointsPerTick``.
    ///
    /// `Double.maximum`/`.minimum` rather than `<`/`>` ternaries, and the multiply is kept off the divide
    /// (CLAUDE.md's bit-exact float habit) so the ramp is reproducible.
    public static func autoScrollDelta(y: Double, viewHeight: Double) -> Double {
        let inset = Double.minimum(autoScrollEdgeInset, viewHeight / 2)
        guard inset > 0 else { return 0 }
        // How far the finger is past each edge; both are 0 in the middle, and only one can be positive
        // because `inset` never exceeds half the height.
        let above = Double.maximum(0, inset - y)
        let below = Double.maximum(0, y - (viewHeight - inset))
        let overshoot = above - below
        let clamped = Double.minimum(Double.maximum(overshoot, -inset), inset)
        let fraction = clamped / inset
        return fraction * autoScrollPointsPerTick
    }

    // MARK: - What a release means

    /// Whether the release that ends a long press should present the edit menu.
    ///
    /// A mouse-reporting program (vim `set mouse=a`, tmux, htop) has CAPTURED the pointer: every press,
    /// motion and release of that gesture was encoded as a report and became a drag INSIDE the program,
    /// so there is no selection of ours to act on and the menu would be an interruption of the program's
    /// own gesture. Off capture the menu always shows, selection or not — Paste / Select All / Clear /
    /// Find are exactly what the Mac's `menu(for:)` offers on an empty right-click, and
    /// ``TerminalContextMenu/isEnabled(_:context:)`` greys out the rest.
    public static func presentsMenuOnRelease(mouseCaptured: Bool) -> Bool {
        !mouseCaptured
    }
}
