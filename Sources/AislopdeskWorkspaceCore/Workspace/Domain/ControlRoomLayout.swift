import CoreGraphics
import Foundation

// ControlRoomLayout — the pure grid solver behind the Control Room overview (design-craft big-swing B,
// 2026-07-04). Given N mounted tab layers (each rendered at the FULL canvas size and shrunk by a pure
// render transform — never a frame change, so no PTY/grid resize), it places N aspect-preserving slots
// in a near-square grid. Pure + headlessly unit-tested; the view derives each layer's scale from
// `slot.width / bounds.width`.

public enum ControlRoomLayout {
    /// The frame each tab's SCALED-DOWN card occupies inside `bounds`, in tab order. Every slot keeps the
    /// canvas aspect (uniform scale), is centred in its grid cell, and the grid is near-square
    /// (`cols = ceil(sqrt(N))`). Empty input / degenerate bounds ⇒ `[]` (validate-then-drop).
    public static func slots(count: Int, in bounds: CGRect, gap: CGFloat = 28) -> [CGRect] {
        guard count > 0, bounds.width > 1, bounds.height > 1 else { return [] }
        let columns = Int(Double(count).squareRoot().rounded(.up))
        let rows = (count + columns - 1) / columns
        let cellWidth = (bounds.width - gap * CGFloat(columns + 1)) / CGFloat(columns)
        let cellHeight = (bounds.height - gap * CGFloat(rows + 1)) / CGFloat(rows)
        guard cellWidth > 1, cellHeight > 1 else { return [] }
        // One uniform scale for every card (a mixed-size grid reads as noise, not an overview).
        let scale = min(cellWidth / bounds.width, cellHeight / bounds.height)
        let cardWidth = bounds.width * scale
        let cardHeight = bounds.height * scale

        var result: [CGRect] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            let column = index % columns
            let row = index / columns
            // Centre the LAST row's stragglers so a 5-in-3×2 grid reads balanced, not left-packed.
            let inRow = row == rows - 1 ? count - row * columns : columns
            let rowLeadIn = (bounds.width - gap * CGFloat(inRow + 1) - cellWidth * CGFloat(inRow)) / 2
            let cellX = bounds.minX + rowLeadIn + gap * CGFloat(column + 1) + cellWidth * CGFloat(column)
            let cellY = bounds.minY + gap * CGFloat(row + 1) + cellHeight * CGFloat(row)
            result.append(CGRect(
                x: cellX + (cellWidth - cardWidth) / 2,
                y: cellY + (cellHeight - cardHeight) / 2,
                width: cardWidth,
                height: cardHeight,
            ))
        }
        return result
    }
}
