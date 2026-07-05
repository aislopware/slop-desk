// PaneMath — pure, testable helpers for the L3 pane layer (divider drag→weight-delta + cwd truncation).
// Kept free of SwiftUI so `SlopDeskClientUITests` can pin them without a view (the house float idiom:
// ordered `>` guards over a finite span; no fma/addingProduct).

import CoreGraphics

enum PaneMath {
    /// Convert an incremental pixel drag along the split axis into a flex-weight delta over the OWNING
    /// split's span. Because a flex child's on-screen extent is `flexBudget * weight / flexSum` (see
    /// `SplitLayoutSolver.extents`), moving the seam by Δpixels needs `Δweight = Δpixel * flexSum / span`
    /// — without the `flexSum` factor a 50/50 split (`flexSum == 2`) tracked at HALF cursor speed and a
    /// nested split (smaller `span`, `flexSum == 2`) under-tracked further. Returns 0 for a non-finite /
    /// non-positive span or flex-sum (the divider then sends nothing). The drag is the INCREMENT since the
    /// last gesture update.
    static func weightDelta(pixelIncrement: CGFloat, axisSpan: CGFloat, flexSum: CGFloat) -> Double {
        guard axisSpan.isFinite, axisSpan > 0, flexSum.isFinite, flexSum > 0, pixelIncrement.isFinite
        else { return 0 }
        return Double(pixelIncrement) / Double(axisSpan) * Double(flexSum)
    }

    /// Truncate a cwd path from the BEGINNING (keep the trailing leaf dirs visible), max `maxChars`
    /// glyphs incl. the leading ellipsis (spec §5.1 `truncate_from_beginning`, max 40).
    static func truncatedCwd(_ cwd: String, maxChars: Int = 40) -> String {
        guard cwd.count > maxChars else { return cwd }
        guard maxChars > 1 else { return String(cwd.suffix(maxChars)) }
        return "…" + String(cwd.suffix(maxChars - 1))
    }
}
