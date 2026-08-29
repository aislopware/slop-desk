// MacLinkHighlightOverlay — the ⌘-hold link underline, in AppKit (docs/56 wave R, batch R3).
//
// The AppKit half of ``LinkHighlightOverlayView``. A DECORATION coincident with the terminal surface
// (never a content branch — the libghostty-freeze guardrail): while the pane model reports ⌘ is held,
// it runs the pure ``TerminalLinkDetector`` over the live VISIBLE viewport rows and draws a hairline
// under every detected path / URL / `file://` / `mailto:` span, mapped to points by the
// ``TerminalCellMetrics``. Only the underlines: the renderer owns ⌘click / ⌘⇧click / right-click and
// the pointing-hand cursor, and the hovered link's resolved path is the model's.
//
// Honest ceiling: a headless / `BuildStatusPlaceholderView` surface does NOT conform to
// ``TerminalViewportSnapshotting`` (the real surface hangs without a window server — CLAUDE.md rule
// #6), so `cellMetrics()` is absent and this draws nothing — an ABSENT underline, never a wrong one.
//
// THE ARM PREDICATE AND THE PATH ARE VALUES, not code in here: ``LinkUnderlineGeometry`` owns the
// three gates and the baseline inset, and is pinned by its own tests. What this file owns is the
// FLIPPED coordinate space (see `isFlipped`) and the conditional dependency below — the reason the
// heavy reads sit inside the armed branch of the tracked closure rather than beside it.
//
// THEME colours only, from the on-glass vocabulary: `Slate.Native.Terminal.ink` — the CELL
// FOREGROUND, not the brand accent (user-directed 2026-08-09). An underline is a property OF the text
// it sits under, so it is the colour that text is already drawn in; and this overlay lives inside the
// terminal island, where the on-glass vocabulary governs and the semantic tiers (tuned for the
// chrome) do not.

import AppKit
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskTerminal
import SlopDeskWorkspaceCore

@MainActor
final class MacLinkHighlightOverlay: NSView {
    /// The pane's terminal model — observed for the ⌘-hold flag and the two viewport-change signals,
    /// dereferenced non-reactively for its `surface` snapshot at detection time.
    private let model: TerminalViewModel

    /// The pane cwd (OSC 7 `pane/cwd`) so a RELATIVE detected path resolves. It only affects the
    /// detector's `resolvedAbsolute` (the hover preview's), never the underline rect, which is pure
    /// cells — but it is a `var` because cwd changes under a live pane and the SwiftUI half got the
    /// re-detect for free by being handed a new value.
    var cwd: String? {
        didSet {
            guard cwd != oldValue else { return }
            refresh()
        }
    }

    /// The underline strokes for the current viewport, in the surface's top-left-origin space.
    private var strokes: [TerminalStroke] = []

    init(model: TerminalViewModel, cwd: String?) {
        self.model = model
        self.cwd = cwd
        super.init(frame: .zero)
        setAccessibilityElement(false)
        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// ⚠️ FLIPPED — ``TerminalCellMetrics`` answers in the surface's TOP-LEFT-origin space (row 0 at
    /// the top, y growing downward), the space SwiftUI's `Canvas` already draws in. Unflipped, every
    /// underline would land under the row mirrored about the viewport's middle: still one hairline per
    /// link, under the wrong text.
    override var isFlipped: Bool { true }

    /// DECORATION only: never swallow a click. The renderer owns ⌘click / ⌘⇧click / right-click on a
    /// detected link, and a click that this view answered would open nothing at all. The AppKit
    /// spelling of `.allowsHitTesting(false)`; sufficient here because this view owns no
    /// `NSTrackingArea` — the hover cursor is the renderer's.
    override func hitTest(_: NSPoint) -> NSView? { nil }

    /// One hairline per stroke, each at the width the value carries rather than a constant read here —
    /// the underline's own geometry is ``LinkUnderlineGeometry``'s, down to the line width.
    override func draw(_: NSRect) {
        guard !strokes.isEmpty else { return }
        Slate.Native.Terminal.ink.setStroke()
        for stroke in strokes {
            let underline = NSBezierPath()
            underline.move(to: stroke.start)
            underline.line(to: stroke.end)
            underline.lineWidth = stroke.lineWidth
            underline.stroke()
        }
    }

    /// A resize re-wraps the grid, so every detected span moves and several stop existing. No
    /// observable property bumps for it (the metrics are read off the live surface), and stale
    /// underlines over re-wrapped text are the wrong-decoration failure this family refuses.
    override func layout() {
        super.layout()
        refresh()
    }

    /// The on-glass ink is the profile's, and a profile/appearance change re-resolves it.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: The live read

    /// ⚠️ THE DEPENDENCY IS CONDITIONAL AND THAT IS THE POINT, and the conditional itself is
    /// ``DecorationLinkUnderline/track(_:)``'s rather than this file's — the three arm signals, the
    /// two viewport signals read only inside the armed branch, and the observable-twin trap are one
    /// dependency set for both shells. `Observation` registers what a tracking block reads THROUGH a
    /// call exactly as it registers a direct read, so the set does not widen by descending.
    private func follow() {
        ObservationFollow.arm(self) { view in
            DecorationLinkUnderline.track(view.model)
        } apply: { view, _ in
            view.refresh()
        }
    }

    /// Re-detect, and ask for pixels only if the answer moved. Streaming output bumps `bytesReceived`
    /// per chunk while ⌘ is held, and most chunks do not touch a link's row — the detector still runs
    /// (it is the only way to know), but a redraw of the whole pane-sized layer does not.
    private func refresh() {
        let next = DecorationLinkUnderline.strokes(for: model, cwd: cwd)
        guard next != strokes else { return }
        strokes = next
        needsDisplay = true
    }
}
