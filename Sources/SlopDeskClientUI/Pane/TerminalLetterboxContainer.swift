// TerminalLetterboxContainer — where a grid the phone did NOT choose goes (docs/45 §8.3).
//
// iOS is size-passive HOST-side: a phone's window never votes in a pane's `min` fold, so the pane's
// grid is whatever the Macs on it settled on. A phone therefore has to place a grid that is almost
// never its own aspect. It shrinks it to fit, centres it, fills the remainder with the pane surface
// colour, and SAYS WHY — `120×40 · sized by MacBook Pro`. Without that readout a user sees a pane
// that is the wrong size for no stated reason and a rule reads as a bug.
//
// iOS-ONLY on purpose. A Mac contributes to the fold, so its window IS the grid and a letterbox
// there would be a bar around a pane that is already right. `swift build` never compiles this file;
// `bash scripts/check-ios.sh` is what proves it.
//
// The geometry is a pure value (``SlopDeskTerminal/TerminalLetterbox``) so it carries unit tests the
// SwiftUI path cannot — INCLUDING the placement's five-way degrade-to-full-bleed, which used to be a
// `private func` here and so was geometry `swift build` never even compiled (only `check-ios.sh` did).
// `Slate.*` tokens ONLY — raw literals fail `scripts/check-ds-leaks.sh`. No libghostty / Metal is
// touched: the surface is placed and transformed, never reached into.

#if canImport(SwiftUI) && os(iOS)
import SlopDeskSlate
import SlopDeskTerminal
import SwiftUI

/// Places `content` at the HOST's resolved grid inside the space this pane has, centred with
/// letterbox bars, and captions it with §8.3 rule 7's readout.
///
/// DEGRADES TO FULL-BLEED. Every input can legitimately be absent — the roster has not landed, the
/// document is off, the renderer is a placeholder with no cell metrics, or the layout pass has not
/// run — and in each of those cases the content fills the container exactly as it always did. That
/// is the honest ceiling this file's neighbours already keep: an absent overlay, never a wrong one.
struct TerminalLetterboxContainer<Content: View>: View {
    /// The grid the host resolved for this pane (``WorkspaceStore/paneResolvedGrid(for:)``).
    let grid: (cols: Int, rows: Int)?
    /// The renderer's natural per-cell advance in POINTS, read from the live surface's
    /// ``SlopDeskTerminal/TerminalViewportSnapshotting`` seam. `nil` for a headless / placeholder /
    /// pre-layout surface.
    let cellSize: CGSize?
    /// `120×40 · sized by MacBook Pro` (``WorkspaceStore/paneGridReadout(for:)``).
    let readout: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            if let placement = TerminalLetterbox.placement(
                grid: grid, cellSize: cellSize, in: proxy.size,
            ) {
                ZStack {
                    // The bars. The pane surface colour, not a black mask: the letterbox is empty
                    // space around a terminal, not a video pillarbox.
                    Slate.Surface.terminal
                    // The surface is framed at its NATURAL size for the host's grid and then
                    // transformed, so the renderer lays out exactly `cols × rows` and the scale is a
                    // layer transform over the result. Sizing the frame to the SCALED rect instead
                    // would make the renderer derive a different grid from it — the phone would
                    // reflow to its own window, which is the thing size-passivity exists to stop.
                    content()
                        .frame(width: placement.natural.width, height: placement.natural.height)
                        .scaleEffect(placement.fit.scale)
                        .frame(width: placement.fit.contentRect.width, height: placement.fit.contentRect.height)
                        .position(x: placement.fit.contentRect.midX, y: placement.fit.contentRect.midY)
                }
                .overlay(alignment: .bottom) {
                    if let readout, placement.fit.isLetterboxed {
                        GridReadoutCaption(text: readout)
                            .padding(Slate.Metric.space2)
                    }
                }
            } else {
                content()
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }
}

/// The `120×40 · sized by MacBook Pro` caption, in the bar below the grid.
///
/// Only rendered when there IS a bar: on an exact fit it would sit on top of the terminal's last
/// row. Hit-transparent — it explains, it does not act.
private struct GridReadoutCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: Slate.Typeface.footnote, weight: .medium))
            .foregroundStyle(Slate.Text.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Slate.Metric.space2)
            .padding(.vertical, Slate.Metric.space1)
            .background(Slate.Surface.raised, in: .rect(cornerRadius: Slate.Metric.radiusControl))
            .overlay(
                RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                    .strokeBorder(Slate.Line.subtle, lineWidth: Slate.Metric.hairline),
            )
            .allowsHitTesting(false)
            .accessibilityLabel(text)
    }
}
#endif
