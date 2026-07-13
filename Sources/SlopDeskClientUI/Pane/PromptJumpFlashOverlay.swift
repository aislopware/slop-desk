// PromptJumpFlashOverlay — the prompt-jump "landed" flash (the vim-highlightedyank idiom).
//
// A ⌘PageUp/⌘PageDown (or navigator) prompt jump replaces the whole viewport in one frame — the eye has
// no scroll motion to follow, so the user lands with zero orientation. This overlay paints ONE ~240ms
// accent fade over the landed prompt row the instant the jump settles, anchoring the eye where the jump
// went. libghostty PINS the jumped-to prompt at viewport row 0 (`PageList.scrollPrompt` sets the
// viewport pin to the prompt), so row 0 is the honest target; the model's arm/settle logic
// (``TerminalViewModel/noteViewportScroll(atBottom:)``) already SUPPRESSED the epoch bump for the one
// case where that would lie (a forward jump clamped into the active area) — absent, never wrong.
//
// A DECORATION overlay like ``LinkHighlightOverlay``: coincident with the surface (origin 0,0 = cell
// grid origin), mapped through the same ``TerminalCellMetrics``, hit-transparent, and inert for a
// placeholder/headless surface (no viewport seam ⇒ nothing drawn). Motion is a plain opacity fade
// (mechanical, MERIDIAN L4 — the flash APPEARS as a hard cut and decays; nothing travels).

#if canImport(SwiftUI)
import SlopDeskTerminal
import SlopDeskWorkspaceCore
import SwiftUI

struct PromptJumpFlashOverlay: View {
    /// The pane's terminal model — observed for ``TerminalViewModel/promptJumpFlashEpoch`` (one bump =
    /// one flash), dereferenced non-reactively for the surface's viewport snapshot at flash time.
    let model: TerminalViewModel

    /// The peak flash opacity over the accent fill — loud enough to catch a saccade, quiet enough to
    /// read as light, not selection.
    private static let peak: Double = 0.28

    /// The live flash: the landed prompt line's per-row rects (computed ONCE when the epoch bumps —
    /// the viewport is pinned for the fade's ~240ms, so static rects are truthful) plus the shared
    /// animating opacity. Several rects when the prompt line soft-WRAPS: each wrapped row gets its own
    /// text-extent rect, and they fade as one.
    @State private var flashRects: [CGRect] = []
    @State private var flashOpacity: Double = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(flashRects.enumerated()), id: \.offset) { _, rect in
                Rectangle()
                    .fill(Slate.State.accent)
                    .opacity(flashOpacity)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        // One task per settled jump: paint at peak instantly (hard cut ON), yield a tick so the fade
        // animates from the committed peak, decay over `Slate.Anim.needle`, then unmount the rect.
        // Epoch 0 is the mount state — no jump has settled, so the task exits without painting.
        // A cancelled sleep (pane torn down / rapid re-jump retargeting the task) just stops — the
        // successor task repaints from scratch, so no cleanup is owed here.
        .task(id: model.promptJumpFlashEpoch) {
            guard model.promptJumpFlashEpoch > 0 else { return }
            let rects = landedPromptRects()
            guard !rects.isEmpty else {
                Self
                    .debugLog(
                        "epoch \(model.promptJumpFlashEpoch) settled but NO RECT (alt-screen / no seam / blank rows)",
                    )
                return
            }
            Self.debugLog("painting epoch \(model.promptJumpFlashEpoch) rows=\(rects.count) first=\(rects[0])")
            var snap = Transaction()
            snap.disablesAnimations = true
            withTransaction(snap) {
                flashRects = rects
                flashOpacity = Self.peak
            }
            await Task.yield()
            withAnimation(Slate.Anim.needle) { flashOpacity = 0 }
            guard await (try? Task.sleep(for: .milliseconds(300))) != nil else { return }
            flashRects = []
        }
    }

    /// The landed prompt line's rects: the pinned prompt block's first TEXT row plus its soft-WRAP
    /// continuation rows (see ``anchorRows(in:cols:searchDepth:maxRows:)``), each spanning that row's
    /// text extent (a full-grid-width bar reads as a selection band; the line's own width reads as
    /// "this line"). Empty — no flash — for an alt-screen TUI, a placeholder surface (no viewport
    /// seam), or a blank landing (nothing to anchor to).
    private func landedPromptRects() -> [CGRect] {
        guard !model.isAlternateScreen,
              let snapshot = model.surface as? TerminalViewportSnapshotting,
              let metrics = snapshot.cellMetrics(),
              metrics.cellWidth > 0, metrics.cellHeight > 0
        else { return [] }
        return Self.anchorRows(in: snapshot.viewportTextRows(), cols: metrics.cols)
            .compactMap { metrics.clampedRect(row: $0.row, colStart: 0, colEnd: $0.cellCount) }
    }

    /// The viewport rows the flash anchors to: the first row with visible TEXT within the top
    /// `searchDepth` rows, PLUS that line's soft-wrap continuations. libghostty pins the jumped-to
    /// prompt at row 0, but the OSC-133 `A` mark is emitted at the pre-prompt cursor position — with a
    /// spacer-printing prompt (starship's default `add_newline` blank line) the PINNED row is that
    /// BLANK spacer and the visible prompt text sits on row 1/2. A whitespace-only row never anchors
    /// (a space-flash reads as a rendering artifact); all blank ⇒ empty (absent, never wrong).
    ///
    /// WRAP RULE: a row whose text fills the whole grid width soft-wrapped, so the next row continues
    /// the SAME logical prompt line — the flash walks those continuations (field report: a wrapped
    /// prompt flashed only its first row, reading as a truncated cue). The walk stops at the first
    /// non-full row (the line's true end), a blank row, or the `maxRows` cap (a pathological
    /// grid-filling line must not flash half the screen). An exactly-grid-width line over-includes at
    /// most one following row — benign versus under-flashing every wrapped prompt.
    ///
    /// `cellCount` is the row's grapheme count — under-measures a wide (2-cell) glyph's span,
    /// acceptable: the flash covers the text from column 0, just stopping a few cells early on
    /// CJK-heavy prompts (and its wrap detection errs the same safe way: a wide-glyph row reads as
    /// non-full, ending the walk early rather than over-flashing). Static + pure so
    /// `PromptJumpFlashAnchorTests` pins the spacer-row + wrap rules.
    static func anchorRows(
        in rows: [String], cols: Int, searchDepth: Int = 3, maxRows: Int = 4,
    ) -> [(row: Int, cellCount: Int)] {
        var anchor: Int?
        for (index, text) in rows.prefix(searchDepth).enumerated()
            where !text.trimmingCharacters(in: .whitespaces).isEmpty
        {
            anchor = index
            break
        }
        guard let start = anchor else { return [] }
        var result: [(row: Int, cellCount: Int)] = []
        var row = start
        while row < rows.count, result.count < maxRows {
            let cellCount = rows[row].count
            guard cellCount > 0 else { break }
            result.append((row, cellCount))
            guard cols > 0, cellCount >= cols else { break } // a non-full row ends the logical line
            row += 1
        }
        return result
    }

    /// stderr diagnostics gated by `SLOPDESK_BLOCKS_DEBUG == "1"` — the paint end of the one-flag
    /// jump trace (issue → arm → scrollbar echo → settle → THIS paint / no-rect drop).
    private static func debugLog(_ message: String) {
        guard ProcessInfo.processInfo.environment["SLOPDESK_BLOCKS_DEBUG"] == "1" else { return }
        FileHandle.standardError.write(Data("[flash] \(message)\n".utf8))
    }
}
#endif
