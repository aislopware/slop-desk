// MacPromptJumpFlashOverlay — the prompt-jump "landed" flash, in AppKit (docs/56 wave R, batch R3).
//
// The AppKit half of ``PromptJumpFlashOverlay`` (the vim-highlightedyank idiom). A ⌘PageUp/⌘PageDown
// (or navigator) prompt jump replaces the whole viewport in one frame — the eye has no scroll motion
// to follow, so the user lands with zero orientation. This overlay paints ONE accent fade over the
// landed prompt row the instant the jump settles, anchoring the eye where the jump went. libghostty
// PINS the jumped-to prompt at viewport row 0, so row 0 is the honest target, and the model's
// arm/settle logic already SUPPRESSED the epoch bump for the one case where that would lie (a forward
// jump clamped into the active area) — absent, never wrong.
//
// A DECORATION coincident with the surface (origin 0,0 = the cell grid's top-left), mapped through
// the same ``TerminalCellMetrics``, hit-transparent, and inert for a placeholder/headless surface (no
// viewport seam ⇒ nothing drawn). WHERE it paints is ``PromptJumpFlashGeometry``'s — the anchor walk
// and the soft-wrap continuation rule are values with their own tests.
//
// MOTION: a plain opacity decay (mechanical, MERIDIAN L4 — the flash APPEARS as a hard cut and
// decays; nothing travels). The rung, the curve and the hold are `Slate`'s and are not restated here.
//
// ⚠️ THE VIEW RESTS INVISIBLE. `layer.opacity` is 0 at mount and 0 again the instant the decay ends —
// the flash is entirely the `CABasicAnimation`'s `fromValue`, so there is no model state that can be
// left raised by a cancelled sleep, a torn-down pane or a jump that retargets mid-fade. That is the
// AppKit answer to the same hazard the SwiftUI half handles with a `disablesAnimations` transaction
// and a `Task.yield()`: a flash whose peak lived in the model value could be stranded ON over a
// pane's content, which is far worse than a missed flash.

import AppKit
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskTerminal
import SlopDeskWorkspaceCore

@MainActor
final class MacPromptJumpFlashOverlay: NSView {
    /// The pane's terminal model — observed for ``TerminalViewModel/promptJumpFlashEpoch`` (one bump =
    /// one flash), dereferenced non-reactively for the surface's viewport snapshot at flash time.
    private let model: TerminalViewModel

    /// The landed prompt line's per-row rects, computed ONCE when the epoch bumps. Several when the
    /// prompt line soft-WRAPS: each wrapped row gets its own text-extent rect and they fade as one,
    /// which is why the decay is on the view's layer and not per rect. Static rects are truthful for
    /// the whole of the hold because the viewport is PINNED for it.
    private var flashRects: [CGRect] = []

    /// The last epoch that reached ``flash(epoch:)``. Epoch 0 is the mount state — no jump has settled
    /// — and the comparison is `>` so a re-arm that re-reads the same epoch cannot double-paint it.
    private var paintedEpoch = 0

    /// The beat that unmounts the rects. Cancelled by a rapid re-jump, which repaints from scratch and
    /// owes the predecessor no cleanup.
    private var unmount: Task<Void, Never>?

    private static let fadeKey = "slopdesk.promptFlash"

    init(model: TerminalViewModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.opacity = 0
        setAccessibilityElement(false)
        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// ⚠️ FLIPPED — ``TerminalCellMetrics`` answers in the surface's TOP-LEFT-origin space, the space
    /// SwiftUI's `offset` already places in. Unflipped, a jump that pins the prompt at viewport row 0
    /// would flash the BOTTOM row of the pane: the one place the eye is certain the prompt is not.
    override var isFlipped: Bool { true }

    /// Transparent to the pointer. A jump lands and the user's next act is to click into the pane it
    /// landed in — a decoration that answered `hitTest` with itself would eat exactly that click, for
    /// the whole quarter-second the flash is up. Sufficient as a plain override because this view owns
    /// no `NSTrackingArea`.
    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func draw(_: NSRect) {
        guard !flashRects.isEmpty else { return }
        Slate.Native.accent.setFill()
        for rect in flashRects {
            NSBezierPath(rect: rect).fill()
        }
    }

    // MARK: The live read

    /// Only the epoch is tracked: the viewport snapshot and the alt-screen gate are read
    /// non-reactively at flash time, exactly as the SwiftUI half reads them inside its `.task` (which
    /// tracks nothing either).
    private func follow() {
        ObservationFollow.arm(self) { view in
            view.model.promptJumpFlashEpoch
        } apply: { view, epoch in
            view.flash(epoch: epoch)
        }
    }

    /// One settled jump: paint at peak instantly, decay, then unmount the rects.
    private func flash(epoch: Int) {
        guard epoch > paintedEpoch else { return }
        paintedEpoch = epoch
        let rects = landedPromptRects()
        guard !rects.isEmpty else {
            Self.debugLog("epoch \(epoch) settled but NO RECT (alt-screen / no seam / blank rows)")
            return
        }
        Self.debugLog("painting epoch \(epoch) rows=\(rects.count) first=\(rects[0])")
        unmount?.cancel()
        flashRects = rects
        needsDisplay = true
        decay()
        // ONE DURATION, ONE SPELLING. `promptFlashHold` IS the fade's duration plus its slack, so the
        // beat that tears the rects out cannot stop being longer than the fade when the curve is
        // retuned. `Slate` owns the numbers; this file owns only the order they happen in.
        unmount = Task { [weak self] in
            guard await (try? Task.sleep(for: .seconds(Slate.Anim.promptFlashHold))) != nil else { return }
            self?.clear()
        }
    }

    /// The decay, on the layer's opacity — the AppKit view of the rung ``Slate/Anim/promptFlash``
    /// names, which is why the curve is taken from `Slate.Motion` and never re-typed as control
    /// points here.
    ///
    /// The peak is the animation's `fromValue` and nothing else: the layer's model opacity stays 0
    /// throughout, so the presentation rises to the peak on the first frame (the hard cut ON), decays
    /// over the curve, and lands back on a value that was already correct. Nothing to reset, nothing
    /// to strand.
    private func decay() {
        guard let layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = Slate.Anim.promptFlashPeak
        fade.toValue = 0
        fade.duration = Slate.Motion.promptFlash.duration
        fade.timingFunction = Slate.Motion.promptFlash.timingFunction
        // A re-jump mid-fade restarts from the peak rather than cross-fading two decays — the flash is
        // one cut per landing, and two overlapping curves read as a stutter.
        layer.removeAnimation(forKey: Self.fadeKey)
        layer.add(fade, forKey: Self.fadeKey)
    }

    private func clear() {
        guard !flashRects.isEmpty else { return }
        flashRects = []
        needsDisplay = true
    }

    /// The landed prompt line's rects, from the pure ``PromptJumpFlashGeometry/rects(rows:metrics:isAlternateScreen:)``
    /// — the pinned prompt block's first TEXT row plus its soft-WRAP continuation rows, each spanning
    /// that row's text extent (a full-grid-width bar reads as a selection band; the line's own width
    /// reads as "this line"). Empty — no flash — for an alt-screen TUI, a placeholder surface (no
    /// viewport seam), or a blank landing (nothing to anchor to).
    private func landedPromptRects() -> [CGRect] {
        guard let snapshot = model.surface as? TerminalViewportSnapshotting else { return [] }
        return PromptJumpFlashGeometry.rects(
            rows: snapshot.viewportTextRows(),
            metrics: snapshot.cellMetrics(),
            isAlternateScreen: model.isAlternateScreen,
        )
    }

    /// stderr diagnostics gated by `SLOPDESK_BLOCKS_DEBUG == "1"` — the paint end of the one-flag jump
    /// trace (issue → arm → scrollbar echo → settle → THIS paint / no-rect drop). One flag, both ends,
    /// which is the point of it being one flag: a Mac renderer that dropped its half would make the
    /// trace go quiet at exactly the step being debugged.
    private static func debugLog(_ message: String) {
        DebugTrace.blocks.write("flash", message)
    }
}
