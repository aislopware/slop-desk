// WebViewportFit — the arithmetic that makes the page FILL the space DevTools gives it.
//
// The problem it solves, measured. DevTools' screencast scales the page to FIT its column, keeping
// the page's aspect: a 1440×900 browser inside a column that is tall and narrow renders as a short
// band with empty room above and below it, however wide the panel is dragged. So the page's own
// shape has to follow the column's.
//
// ⚠️ THE VIEWPORT, NOT THE WINDOW. The first cut resized the browser window (`Browser.setWindowBounds`)
// on the belief that an emulation override dies with the CDP client that set it. Measured on Chrome
// 150: it does NOT. An override set from a socket that then closes is still in force minutes later,
// and — this is the part that bites — a LATER session cannot clear it. `Emulation.clearDeviceMetrics`
// answers `{}` and changes nothing, because each session clears only its own. The only thing that
// moves a stale override is another override.
//
// So a window resize is not authority over the page's size, it is a suggestion that any leftover
// override outranks: the symptom is a browser window 500 points wide rendering a 176-point page, and
// nothing the panel does about the window can fix it. Setting the override IS the mechanism. It
// survives the socket closing, it overrides whatever was there, and it needs no window arithmetic.
//
// It is per TARGET, which is the cost: a page the panel has not fitted renders at the window size,
// so the fit has to run again when the selection moves. ``WebSidebarModel`` forgets the fitted column
// on a selection change for that reason.
//
// The floor exists because a page is not a strip. Fitting a 220-point column exactly would mean a
// 176-point viewport, and at that width real sites collapse into a column of wrapped characters —
// the measured failure that started this note. The floor is paid for in HEIGHT so the shape still
// matches the column and the page still fills it, just scaled down to get there.
//
// Measured against Chrome 150 on 2026-08-05: DevTools' screencast reserves 44 points across and 71
// down of its column for the device frame and the navigation bar it draws above the page.

import Foundation

enum WebViewportFit {
    /// The narrowest a page is allowed to be laid out at. Not a protocol limit — a legibility one.
    static let minimumViewportWidth: CGFloat = 500
    /// What DevTools keeps for itself inside the screencast column.
    static let screencastInset = CGSize(width: 44, height: 71)
    /// A refit relays out whatever the user is reading, so a column that moved by less than this is
    /// treated as the same column. Below about this the change is not visible in the scaled render.
    static let refitThreshold: CGFloat = 12

    /// The viewport that makes a page fill a screencast column of `column` points.
    ///
    /// `nil` for a column too small to be a page — a collapsed panel, or a frontend measured before
    /// it has laid out. Fitting the page to one of those leaves it absurd once the panel opens again.
    static func viewportSize(column: CGSize) -> CGSize? {
        let usable = CGSize(
            width: column.width - screencastInset.width,
            height: column.height - screencastInset.height,
        )
        guard usable.width >= 1, usable.height >= 1 else { return nil }
        // Width first, then height from the column's aspect: the floor has to be paid in the
        // dimension that is free, or the shape stops matching and the empty band comes back.
        let width = Swift.max(minimumViewportWidth, usable.width)
        let height = width * usable.height / usable.width
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    /// Whether `column` is far enough from the one the page was last fitted to to be worth another
    /// round. Pure, and the reason the fit can ride a poll rather than a geometry observer: a
    /// measurement that jitters by a point must not relayout the page every time.
    static func isWorthRefitting(_ column: CGSize, fitted: CGSize) -> Bool {
        abs(column.width - fitted.width) >= refitThreshold
            || abs(column.height - fitted.height) >= refitThreshold
    }
}
