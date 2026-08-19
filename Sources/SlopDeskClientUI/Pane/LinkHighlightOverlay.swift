// LinkHighlightOverlay — the ⌘-hold link underline.
//
// A DECORATION overlay layered OVER the terminal surface in `TerminalLeafView` (never a content branch —
// the libghostty-freeze guardrail): while the pane model reports ⌘ is held (``TerminalViewModel/linkHighlightActive``),
// it runs the pure ``TerminalLinkDetector`` over the live VISIBLE viewport rows (the
// ``TerminalViewportSnapshotting`` seam) and draws a 1pt accent underline under every detected path / URL /
// `file://` / `mailto:` span, mapped to points by the ``TerminalCellMetrics`` (`full-path-hover.png`'s
// `CREDITS.md` underline). The renderer still resolves the hovered link's full path into the dormant
// ``TerminalViewModel/hoveredLinkFullPath`` seam, which has no status-bar consumer; this overlay only
// paints the underlines.
//
// Honest ceiling: a headless / `BuildStatusPlaceholderView` surface does NOT conform to
// ``TerminalViewportSnapshotting`` (the real surface hangs without a window server — CLAUDE.md rule #6), so
// `cellMetrics()` is absent and the overlay simply renders nothing — an ABSENT underline, never a wrong one.
//
// INERT on iOS: there is no ⌘ modifier, so the renderer never sets ``linkHighlightActive`` true on iOS and the
// overlay body short-circuits to empty (the iOS link affordance is tap-on-label / long-press). The view
// still compiles for iOS (no `#if os` here — `Canvas` is iOS 15+; the gate is runtime state, not platform).
//
// Never intercepts hits (`allowsHitTesting(false)`): clicks fall through to the renderer, which owns ⌘click /
// ⌘⇧click / right-click on a detected link, and now the POINTING-HAND cursor too
// (`GhosttyTerminalView.setLinkHoverCursor(_:)` — libghostty used to supply that as part of its own link
// highlight, which `link-url = false` retired along with its duplicate underline). THEME colours only, from
// the on-glass vocabulary (`Slate.Terminal.ink` — the cell foreground).

#if canImport(SwiftUI)
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskTerminal
import SlopDeskWorkspaceCore
import SwiftUI

struct LinkHighlightOverlay: View {
    /// The pane's terminal model — read for the OBSERVABLE ⌘-hold flag (`linkHighlightActive`) + the alt-screen
    /// gate, and dereferenced (non-reactively) for its `surface` viewport snapshot at draw time.
    let model: TerminalViewModel
    /// The pane cwd (OSC 7 `pane/cwd`) so a RELATIVE detected path resolves — only affects the
    /// detector's `resolvedAbsolute` (used by the hover preview), never the underline rect, which is pure cells.
    let cwd: String?

    var body: some View {
        // Reading `linkHighlightActive` / `alternateScreenActive` here registers observation, so the overlay
        // reveals / clears the instant ⌘ is pressed / released (or the screen flips to a TUI). The SECOND of
        // those is the observable TWIN, and the distinction is the whole reason it exists: `isAlternateScreen`
        // reads through an `@ObservationIgnored` tracker and registers NOTHING, so this comment used to
        // describe a dependency the code did not have. The miss was quiet — a flip arrives with bytes, so the
        // `bytesReceived` read below covered it whenever output kept coming — and it showed up exactly when it
        // was worst: ⌘ held over a pane that flips to a TUI and goes silent left the underlines drawn over vim.
        // The heavy reads
        // (`bytesReceived`, the surface snapshot, the detector) live INSIDE the active branch so the dependency
        // on streaming output is only registered while the underline is actually live — no idle re-eval per
        // ingest when ⌘ is not held.
        if LinkUnderlineGeometry.isArmed(
            highlightActive: model.linkHighlightActive,
            detectionEnabled: SettingsKey.linkDetectionEnabled,
            isAlternateScreen: model.alternateScreenActive,
        ),
            let snapshot = model.surface as? TerminalViewportSnapshotting,
            let metrics = snapshot.cellMetrics()
        {
            // Re-detect under a held ⌘ on EITHER viewport-change signal: new streaming output (`bytesReceived`)
            // OR a LOCAL scrollback scroll (`viewportRevision`, bumped by the renderer's scroll/pan handler).
            // A local scroll moves the viewport WITHOUT new wire bytes, so `bytesReceived` alone would leave
            // the underlines stranded at their pre-scroll screen rows over unrelated text — observing both
            // re-runs detection against the moved `viewportTextRows()`. `let _` (not a bare `_ =`) is required
            // — a `@ViewBuilder` rejects a bare Void discard statement.
            // swiftlint:disable:next redundant_discardable_let
            let _ = model.bytesReceived
            // swiftlint:disable:next redundant_discardable_let
            let _ = model.viewportRevision
            // The CELL FOREGROUND, not the brand accent (user-directed 2026-08-09). Two reasons it is the
            // better ink and not just the preferred one: an underline is a property OF the text it sits
            // under, so it should be the colour that text is already drawn in; and this overlay lives inside
            // the terminal island, where the on-glass vocabulary (``Slate/Terminal``) governs and the
            // semantic `State`/`Text` tiers do not — those are appearance-tuned for the chrome and can
            // invert against a profile that keeps its own palette under either OS appearance.
            let ink = Slate.Terminal.ink
            // WHERE each underline goes is a value — clamped to the visible grid, inset off the row
            // boundary — so it is decided in ``LinkUnderlineGeometry`` and pinned by tests. What was
            // here before was that same arithmetic INSIDE a `Canvas` closure, which is a place nothing
            // can call: the one rule the underline has could not be checked at all.
            let strokes = LinkUnderlineGeometry.strokes(
                links: TerminalLinkDetector.detect(
                    rows: snapshot.viewportTextRows(),
                    cwd: cwd,
                    schemes: SettingsKey.linkSchemePolicy,
                ),
                metrics: metrics,
            )
            Canvas { context, _ in
                let shading = GraphicsContext.Shading.color(ink)
                for stroke in strokes {
                    var underline = Path()
                    underline.move(to: stroke.start)
                    underline.addLine(to: stroke.end)
                    context.stroke(underline, with: shading, lineWidth: stroke.lineWidth)
                }
            }
            // DECORATION only: never swallow a click — the renderer owns ⌘click / right-click on the link.
            .allowsHitTesting(false)
        }
    }
}
#endif
