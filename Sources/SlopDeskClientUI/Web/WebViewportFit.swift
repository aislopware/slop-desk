// WebViewportFit — the arithmetic that makes the page FILL the space DevTools gives it.
//
// The problem it solves, measured. DevTools' screencast scales the page to FIT its column, keeping
// the page's aspect: a 1440×900 browser inside a column that is tall and narrow renders as a short
// band with empty room above and below it, however wide the panel is dragged. So the browser's own
// shape has to follow the column's, which is exactly what a browser window does when you resize it —
// this is the panel doing for the host's browser what a user does by dragging a corner.
//
// WHY THE WINDOW AND NOT `Emulation.setDeviceMetricsOverride`: an emulation override belongs to the
// CDP client that set it and is dropped the moment that client disconnects, so honouring it would
// mean holding a session open for the panel's whole lifetime beside the frontend's own. A window
// resize is browser state. It survives the socket closing, it survives a frontend reload, and every
// tab shares it because they share the window.
//
// Measured against Chrome 150 on 2026-08-05:
//   • `Browser.setWindowBounds` CLAMPS the width at 500 and accepts any height (2049 was honoured,
//     far past the virtual screen) — hence ``minimumViewportWidth``.
//   • A headless window still spends 87 points on browser chrome: a 2049-tall window reports
//     `innerHeight` 1962.
//   • DevTools' screencast reserves 44 points across and 71 down of its column for the device frame
//     and the navigation bar it draws above the page.

import Foundation

enum WebViewportFit {
    /// Chrome refuses to make a window narrower than this, so asking for less silently yields 500
    /// and an aspect that is not the one that was asked for. It is also about the narrowest a page
    /// can be laid out at and still be a page, which is why the floor is applied to the WIDTH and
    /// paid for in height.
    static let minimumViewportWidth: CGFloat = 500
    /// What a headless window spends on browser chrome, vertically.
    static let browserChromeHeight: CGFloat = 87
    /// What DevTools keeps for itself inside the screencast column.
    static let screencastInset = CGSize(width: 44, height: 71)
    /// A refit costs a window resize and a relayout of whatever the user is looking at, so a column
    /// that moved by less than this is treated as the same column. Below about this the change is
    /// not visible in the scaled render anyway.
    static let refitThreshold: CGFloat = 12

    /// The window box that makes a page fill a screencast column of `column` points.
    ///
    /// `nil` for a column too small to be a page — a collapsed panel, or a frontend measured before
    /// it has laid out. Resizing the browser to match one of those would leave the window absurd
    /// after the panel opens again.
    static func windowSize(column: CGSize) -> CGSize? {
        let usable = CGSize(
            width: column.width - screencastInset.width,
            height: column.height - screencastInset.height,
        )
        guard usable.width >= 1, usable.height >= 1 else { return nil }
        // Width first, then height from the column's aspect: the floor has to be paid in the
        // dimension that is free, or the shape stops matching and the empty band comes back.
        let width = Swift.max(minimumViewportWidth, usable.width)
        let height = width * usable.height / usable.width
        return CGSize(width: width.rounded(), height: (height + browserChromeHeight).rounded())
    }

    /// Whether `column` is far enough from the one the window was last fitted to to be worth another
    /// resize. Pure, and the reason the fit can ride a poll rather than a geometry observer: a
    /// measurement that jitters by a point must not resize the browser every round.
    static func isWorthRefitting(_ column: CGSize, fitted: CGSize) -> Bool {
        abs(column.width - fitted.width) >= refitThreshold
            || abs(column.height - fitted.height) >= refitThreshold
    }
}
