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

    /// The live flash: the landed row's rect (computed ONCE when the epoch bumps — the viewport is
    /// pinned for the fade's ~240ms, so a static rect is truthful) plus its animating opacity.
    @State private var flashRect: CGRect?
    @State private var flashOpacity: Double = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let rect = flashRect {
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
            guard let rect = landedPromptRect() else {
                Self
                    .debugLog(
                        "epoch \(model.promptJumpFlashEpoch) settled but NO RECT (alt-screen / no seam / empty row)",
                    )
                return
            }
            Self.debugLog("painting epoch \(model.promptJumpFlashEpoch) rect=\(rect)")
            var snap = Transaction()
            snap.disablesAnimations = true
            withTransaction(snap) {
                flashRect = rect
                flashOpacity = Self.peak
            }
            await Task.yield()
            withAnimation(Slate.Anim.needle) { flashOpacity = 0 }
            guard await (try? Task.sleep(for: .milliseconds(300))) != nil else { return }
            flashRect = nil
        }
    }

    /// The landed prompt row's rect: the pinned prompt block's first TEXT row (see ``anchorRow(in:)``
    /// — row 0 is often an OSC-133 spacer blank), spanning the row's text extent (a full-grid-width
    /// bar reads as a selection band; the prompt's own width reads as "this line"). `nil` — no flash —
    /// for an alt-screen TUI, a placeholder surface (no viewport seam), or a blank landing (nothing to
    /// anchor to).
    private func landedPromptRect() -> CGRect? {
        guard !model.isAlternateScreen,
              let snapshot = model.surface as? TerminalViewportSnapshotting,
              let metrics = snapshot.cellMetrics(),
              metrics.cellWidth > 0, metrics.cellHeight > 0,
              let anchor = Self.anchorRow(in: snapshot.viewportTextRows())
        else { return nil }
        return metrics.clampedRect(row: anchor.row, colStart: 0, colEnd: anchor.cellCount)
    }

    /// The viewport row the flash anchors to: the first row with visible TEXT within the top
    /// `searchDepth` rows. libghostty pins the jumped-to prompt at row 0, but the OSC-133 `A` mark is
    /// emitted at the pre-prompt cursor position — with a spacer-printing prompt (starship's default
    /// `add_newline` blank line) the PINNED row is that BLANK spacer and the visible prompt text sits
    /// on row 1/2. Flashing the block's first text row anchors the eye identically; a whitespace-only
    /// row never anchors (a space-flash reads as a rendering artifact). All blank ⇒ `nil`.
    ///
    /// `cellCount` is the row's grapheme count — under-measures a wide (2-cell) glyph's span,
    /// acceptable: the flash covers the text from column 0, just stopping a few cells early on
    /// CJK-heavy prompts. Static + pure so `PromptJumpFlashAnchorTests` pins the spacer-row rule.
    static func anchorRow(in rows: [String], searchDepth: Int = 3) -> (row: Int, cellCount: Int)? {
        for (index, text) in rows.prefix(searchDepth).enumerated()
            where !text.trimmingCharacters(in: .whitespaces).isEmpty
        {
            return (index, text.count)
        }
        return nil
    }

    /// stderr diagnostics gated by `SLOPDESK_BLOCKS_DEBUG == "1"` — the paint end of the one-flag
    /// jump trace (issue → arm → scrollbar echo → settle → THIS paint / no-rect drop).
    private static func debugLog(_ message: String) {
        guard ProcessInfo.processInfo.environment["SLOPDESK_BLOCKS_DEBUG"] == "1" else { return }
        FileHandle.standardError.write(Data("[flash] \(message)\n".utf8))
    }
}
#endif
