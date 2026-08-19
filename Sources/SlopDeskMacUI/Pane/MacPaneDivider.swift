// MacPaneDivider — the draggable seam between two panes, in AppKit (docs/56 wave R, batch R6).
//
// The AppKit half of ``PaneDivider``: a thin separator hairline drawn inside a comfortable hit band,
// a resize cursor over that band, and a drag that resizes the panes LIVE — the layout updates every
// frame, like an `NSSplitView` divider — while the host grid-resize SEND is deferred until release
// (the shell brackets the drag with `setTerminalResizeSuspended`, so the server gets ONE resize event
// when the drag settles, not one per frame). A double-click evens out THIS seam only, never the tab.
//
// LIVE-RESIZE RULE, unchanged by the port: the drag sets the leading child's ABSOLUTE weight each
// frame — `handle.leadingWeight` captured at drag start, plus the cursor translation converted to
// weight (`Δpx · flexSum / parentSpan`). A ghost-seam preview with a separate commit-on-release step
// is unnecessary and would risk a "divider chases itself, seam barely travels" mismatch; two things
// keep it cursor-matched instead:
//   1. the translation is read in WINDOW coordinates — the AppKit spelling of the SwiftUI half's
//      stable `PaneMoveSpace` coordinate space, and stable for the same reason: this view's own
//      bounds slide out from under the cursor as the panes resize, so a delta measured in them
//      would under-report every frame; and
//   2. it is ABSOLUTE-from-start (not an accumulated per-frame delta), so an over-drag into the
//      min-weight clamp HOLDS and resumes exactly when the cursor returns — no drift.
// The handle clamps the weight at the solver's pixel floor, so the seam stops on the neighbour by
// itself: no ghost-seam preview and no travel clamp are needed.
//
// ⚠️ WINDOW COORDINATES ARE Y-UP AND THE SOLVER'S RECTS ARE NOT. `leadingWeight` grows the leading
// child, which for a `.vertical` (stacked) split is the TOP one, so a downward cursor move must read
// as a POSITIVE translation — exactly what SwiftUI's `translation.height` gives and exactly what
// `locationInWindow.y` does not. ``MacPaneDivider/axisTranslation(axis:from:to:)`` negates the
// vertical arm for that one reason, and is a `static` so a test can pin the sign without a window.
//
// THE GRAB ZONE AND THE CURSOR ZONE ARE THE SAME RECT, on purpose: both are this view's whole
// `bounds`, which the mounter sets to `handle.rect` — the FAT band the solver already emits around
// the drawn hairline (`SplitLayoutSolver.dividerThickness`). A cursor rect wider than the hit band
// promises a grab that does nothing; a narrower one hides a seam that is there. Neither is inset,
// so the two cannot drift apart.
//
// NO TRACKING AREA. Cursor rects are torn down with the view and never fire for a hidden tab, which
// is the trap `NSTrackingArea` sets for this directory (docs/56 risk 3). What they cost instead is
// staleness: they are rebuilt only when asked, so a seam whose movability changed on the last solve
// re-asks through ``handleUpdated()``.
//
// SYSTEM / DS colours only — the accent hairline is a drag affordance, not a hover state.

import AppKit
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

/// One resize seam between two adjacent panes: the hit band, the hairline in it, the resize cursor
/// over it, and the drag.
///
/// The mounter (batch R11) owns the FRAME — it sets `frame` to the handle's solved rect in its own
/// coordinate space each solve, and re-assigns ``handle`` with it. Identity is the handle's
/// ``SplitDividerHandle/key``, which pins `axis`, so the axis of a live instance never changes and
/// the hairline's constraints are installed once. Re-using the instance across solves is not an
/// optimisation: rebuilding the view under a live drag would destroy the tracking mouse-down, which
/// is the same failure the SwiftUI half keys its `ForEach` on `handle.key` to avoid.
@MainActor
final class MacPaneDivider: NSView {
    /// The live seam. Re-assigned on every solve — the pair weights inside it are what the cursor's
    /// direction and the drag's clamp are both read from, so they are never a frame behind.
    var handle: SplitTreeRenderModel.DividerHandle {
        didSet { handleUpdated() }
    }

    /// Drag start — wired to `store.setTerminalResizeSuspended(true)`, holding the host grid-resize
    /// for the whole drag ("update the layout live, defer the server event to drag-end").
    var onResizeBegin: () -> Void = {}
    /// Each frame — the new ABSOLUTE leading-child weight (already clamped). Wired to
    /// `store.setDividerWeightLive`, which re-solves the layout WITHOUT reconciling / persisting.
    var onResizeChange: (_ leadingWeight: Double) -> Void = { _ in }
    /// Drag end / interruption — wired to `store.setTerminalResizeSuspended(false)` (flush the
    /// settled grid to the host) + `store.commitDividerResize()` (reconcile + persist ONCE).
    var onResizeEnd: () -> Void = {}
    /// Double-click → even out THIS seam (50/50, sum-preserving). Wired to `store.evenDividerTree`
    /// with this handle's `(splitID, childIndex)` — never the whole-tab `balanceActivePaneSplits`.
    var onReset: () -> Void = {}

    /// The drawn seam, centred in the band. Its thickness is the only geometry that animates.
    private let seam = Hairline()
    /// The live `62 · 38` readout, mounted for the drag and hidden the rest of the time.
    private let readout = RatioReadout()
    /// The hairline's animatable thickness — one constraint rather than a frame set in `layout()`,
    /// because it is what `NSAnimationContext` can drive.
    private var seamThickness: NSLayoutConstraint?

    /// The cursor's position in WINDOW coordinates when the button went down, or `nil` at rest. Set
    /// on mouse-down and NOT on the first drag frame, so the slop below is measured from the press
    /// rather than from wherever the pointer first got sampled.
    private var grab: NSPoint?
    /// The leading child's weight captured when the drag actually STARTED — the absolute anchor for
    /// the whole gesture, and the flag for "a drag is in flight". `nil` between drags.
    private var startLead: Double?

    /// How far the pointer must travel before a press becomes a resize, matching the SwiftUI half's
    /// `DragGesture(minimumDistance: 1)`. It is what keeps a double-click from spending a
    /// suspend/commit round-trip on the way to `onReset` — the press alone begins nothing.
    private static let dragSlop: CGFloat = 1

    init(
        handle: SplitTreeRenderModel.DividerHandle,
        onResizeBegin: @escaping () -> Void = {},
        onResizeChange: @escaping (Double) -> Void = { _ in },
        onResizeEnd: @escaping () -> Void = {},
        onReset: @escaping () -> Void = {},
    ) {
        self.handle = handle
        self.onResizeBegin = onResizeBegin
        self.onResizeChange = onResizeChange
        self.onResizeEnd = onResizeEnd
        self.onReset = onReset
        super.init(frame: handle.rect)
        build()
        handleUpdated()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// ⚠️ `translatesAutoresizingMaskIntoConstraints` is deliberately left TRUE on this view, which
    /// is the one place in this directory it is. The seam's position is re-solved on every frame of
    /// a live drag, so the mounter places it by assigning `frame` — a constraint pair rewritten 60
    /// times a second is the same placement bought through the solver. Everything INSIDE the band is
    /// Auto Layout as usual, which works unchanged under a manually-framed container.
    private func build() {
        // The readout is WIDER than the band it is centred on — a seam is a few points across and a
        // two-number chip is not. Explicit rather than inherited: an ancestor that clipped would
        // leave a sliver of chip and no way to see it was there.
        clipsToBounds = false

        addSubview(seam)
        addSubview(readout)

        // A `.horizontal` split lays its children out in columns, so its seam is a VERTICAL line
        // that spans the band's height and is dragged left/right; `.vertical` is the quarter turn.
        let thickness: NSLayoutConstraint = handle.axis == .horizontal
            ? seam.widthAnchor.constraint(equalToConstant: Slate.Metric.hairline)
            : seam.heightAnchor.constraint(equalToConstant: Slate.Metric.hairline)
        seamThickness = thickness

        var constraints: [NSLayoutConstraint] = [
            thickness,
            readout.centerXAnchor.constraint(equalTo: centerXAnchor),
            readout.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if handle.axis == .horizontal {
            constraints += [
                seam.centerXAnchor.constraint(equalTo: centerXAnchor),
                seam.topAnchor.constraint(equalTo: topAnchor),
                seam.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]
        } else {
            constraints += [
                seam.centerYAnchor.constraint(equalTo: centerYAnchor),
                seam.leadingAnchor.constraint(equalTo: leadingAnchor),
                seam.trailingAnchor.constraint(equalTo: trailingAnchor),
            ]
        }
        NSLayoutConstraint.activate(constraints)
    }

    // MARK: - The pointer

    /// The whole band asks for the resize cursor — the same rect the drag is taken in. See the file
    /// header for why neither is inset.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: seamCursor)
    }

    /// This seam's reading of ``PaneCanvasMetrics/resizePointer(axis:toLeading:toTrailing:)`` — the
    /// truth-at-the-clamp rule, taken from the handle's own pair weights so the glyph can never
    /// disagree with the gesture's clamp.
    private var seamCursor: NSCursor {
        Self.cursor(for: PaneCanvasMetrics.resizePointer(
            axis: handle.axis,
            toLeading: handle.canMoveTowardLeading,
            toTrailing: handle.canMoveTowardTrailing,
        ))
    }

    /// The pane-chrome pointer vocabulary drawn as an `NSCursor` — the AppKit half of the gate
    /// ``PanePointer``'s header says must exist exactly once per framework.
    ///
    /// Flat on purpose: the specific direction pairs first, then the bare case as the two-way
    /// fallback for a seam that can still move both ways AND for a DEAD one that can move neither.
    /// There is no "cannot resize" cursor, and a plain arrow over a seam reads as a dead zone rather
    /// than as a seam sitting on its floor — the same verdict the shell's column dividers reached
    /// (`SlopDeskSplitViewController.dividerMovability`).
    static func cursor(for pointer: PanePointer) -> NSCursor {
        switch pointer {
        case .columnResize(toLeading: true, toTrailing: false): .resizeLeft
        case .columnResize(toLeading: false, toTrailing: true): .resizeRight
        case .columnResize: .resizeLeftRight
        // `toUp` is the LEADING (top) child of a stacked split — the solver's rects are top-left
        // origin — so the leading direction is the one the up-arrow points in.
        case .rowResize(toUp: true, toDown: false): .resizeUp
        case .rowResize(toUp: false, toDown: true): .resizeDown
        case .rowResize: .resizeUpDown
        // A seam never asks for these: `resizePointer` answers only the two resize cases. The
        // two-way arrow is the least-wrong glyph if one ever arrived, for the reason above.
        case .grabIdle,
             .grabActive: .resizeLeftRight
        }
    }

    // MARK: - The drag

    override func mouseDown(with event: NSEvent) {
        // Evens THIS seam only. The press that carried it began nothing (the slop above), so there
        // is no in-flight resize to unwind first — just the pending grab to drop.
        if event.clickCount == 2 {
            grab = nil
            onReset()
            return
        }
        grab = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grab else { return }
        let translation = Self.axisTranslation(
            axis: handle.axis, from: grab, to: event.locationInWindow,
        )
        if startLead == nil {
            guard abs(translation) >= Self.dragSlop else { return }
            startLead = handle.leadingWeight
            onResizeBegin()
            setDragging(true)
            // Held for the whole gesture: without the push, leaving the band's rect mid-drag hands
            // the pointer back to whatever cursor rect is under it and the arrow vanishes while the
            // seam is still tracking. Balanced by the single `pop()` in `endDrag()`.
            seamCursor.push()
        }
        onResizeChange(targetLeadingWeight(translation: translation))
        // The seam can reach a neighbour's floor mid-drag: the arrow becomes one-way THERE, not on
        // the next hover.
        seamCursor.set()
    }

    override func mouseUp(with _: NSEvent) {
        endDrag()
    }

    /// The interruption safety net — this seam disappearing out of the tree while the button is
    /// still down (a pane closed, the tab was torn out). SwiftUI's `@GestureState` reset made the
    /// end-cleanup unskippable for free; AppKit delivers no cancel for a mouse drag, so the view
    /// leaving its window is the event that stands in for one.
    ///
    /// Skipping it wedges the workspace, not just this seam: `setTerminalResizeSuspended(true)` is
    /// still held, so the host never hears another grid resize.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { endDrag() }
    }

    private func endDrag() {
        grab = nil
        guard startLead != nil else { return }
        startLead = nil
        setDragging(false)
        NSCursor.pop()
        // Rebuild the hover cursor for the ratio the drag settled on — a drag that ended pinned at
        // a floor must immediately hover as one-directional.
        window?.invalidateCursorRects(for: self)
        onResizeEnd()
    }

    /// The cursor translation along the split axis, in the stable WINDOW space.
    ///
    /// ⚠️ THE VERTICAL ARM IS NEGATED AND MUST STAY THAT WAY. Window coordinates are y-UP and the
    /// solver's rects are top-left origin, so `leadingWeight` — which grows the TOP child of a
    /// stacked split — has to read a DOWNWARD cursor move as positive. That is what SwiftUI's
    /// `translation.height` gives for free and what `locationInWindow.y` gives the opposite of.
    /// Drop the negation and a stacked seam runs away from the cursor while the column seam stays
    /// right, which is the shape of bug that reads as "only one of the two is broken".
    static func axisTranslation(axis: SplitAxis, from grab: NSPoint, to point: NSPoint) -> CGFloat {
        axis == .horizontal ? point.x - grab.x : grab.y - point.y
    }

    /// The absolute leading weight for a cursor translation of `translation` points along the split
    /// axis: `startLead +` the translation converted to weight via
    /// ``SplitDividerHandle/weightDelta(pixelIncrement:)`` (`Δpx · flexSum / parentSpan` — the
    /// inverse of a flex child's `extent = weight/flexSum·span`, and the same conversion the
    /// keyboard resize uses). It returns 0 for a zero/non-finite span, leaving `base` unchanged.
    /// Clamped by the handle so BOTH panes keep the solver's pixel floor; over-drags hold at the
    /// floor and resume when the cursor returns.
    private func targetLeadingWeight(translation: CGFloat) -> Double {
        let base = startLead ?? handle.leadingWeight
        return handle.clampedLeadingWeight(base + handle.weightDelta(pixelIncrement: translation))
    }

    // MARK: - The drawing

    /// A new solve arrived: refresh the readout's numbers and re-ask for the cursor.
    ///
    /// The cursor rects are NOT rebuilt mid-drag — the drag sets the cursor itself on every frame,
    /// and invalidating underneath it would let a cursor update reset the glyph the drag just chose.
    private func handleUpdated() {
        applyReadout()
        if startLead == nil { window?.invalidateCursorRects(for: self) }
    }

    /// The seam's two states, in one transaction: the accent line and the extra point of weight
    /// arrive together, on the hover rung.
    ///
    /// The readout is mounted OUTSIDE the animation — MERIDIAN L3 status is present only while the
    /// drag is working and hard-cut on release, never faded in behind the thing it measures.
    private func setDragging(_ active: Bool) {
        applyReadout()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Slate.Motion.dividerHover.duration
            context.timingFunction = Slate.Motion.dividerHover.timingFunction
            context.allowsImplicitAnimation = true
            seam.active = active
            seamThickness?.animator().constant = active
                ? Slate.Metric.dividerHoverWidth : Slate.Metric.hairline
            layoutSubtreeIfNeeded()
        }
    }

    /// The live ratio readout's whole visibility rule, in one place so the two conditions cannot
    /// fight: it shows while the drag is working AND the pair is non-degenerate. A `.fixed` side
    /// reports no percentages, and the cue is then ABSENT rather than wrong.
    private func applyReadout() {
        let percents = handle.splitPercents
        readout.percents = percents
        readout.isHidden = startLead == nil || percents == nil
    }

    // MARK: - The seam line

    /// The crisp resting hairline — the profile's edge tone, one step off the glass (the
    /// JetBrains-Islands internal divider, never a chrome-coloured gap), and the accent while the
    /// drag is actually working.
    ///
    /// Both thicknesses are the ladder's. The resting one used to be a private `1` on the SwiftUI
    /// struct — the same value ``Slate/Metric/hairline`` already carried, spelled a second time one
    /// floor up — and it is not spelled a third time here.
    private final class Hairline: NSView {
        var active = false {
            didSet { paint() }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            translatesAutoresizingMaskIntoConstraints = false
            wantsLayer = true
            paint()
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError("not from a nib") }

        /// Transparent to the pointer, so the whole band belongs to the divider's own drag. Without
        /// this the line down the middle of the hit band — the part a user actually aims at — would
        /// swallow the mouse-down and the seam would only be grabbable beside itself.
        override func hitTest(_: NSPoint) -> NSView? { nil }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            paint()
        }

        /// Assigns the layer colour directly rather than through `updateLayer()`, because the caller
        /// wraps this in an `NSAnimationContext` group with implicit animation on: a display-time
        /// repaint would land outside the transaction and the colour would cut instead of easing.
        private func paint() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = (active
                    ? Slate.Native.accent
                    : Slate.Native.Terminal.edge).cgColor
            }
        }
    }

    // MARK: - The live ratio readout

    /// The instrument-voice split percentages, centred on the seam: the answer to "am I at the ratio
    /// I was aiming for?" while the eye is already on the divider (feedback at the trigger — never a
    /// HUD elsewhere). Each frame's re-solve rebuilds the handle with fresh pair weights, so the
    /// numbers track the seam live.
    ///
    /// ⚠️ ON-GLASS VOCABULARY (``Slate/Native/Terminal``), not the semantic chrome tiers — the rule
    /// for anything drawn inside the island. The semantic set is pinned on the LIGHT side only, so
    /// on the glass it would draw `#585751` ink on a system fill over `#22212C`: a chip that is
    /// there but unreadable. The rim is ``Slate/Native/Terminal/rim`` and NOT `edge`, because `edge`
    /// and `raised` are the SAME profile tone — a border in `edge` on a `raised` plate is literally
    /// invisible, which is how the SwiftUI chips ended up floating unbounded over terminal output.
    private final class RatioReadout: NSView {
        var percents: (leading: Int, trailing: Int)? {
            didSet { applyText() }
        }

        /// Three labels rather than one string, because the `·` is a TIER and not a character: the
        /// numbers are the reading and the dot is the punctuation between them, so they are set in
        /// different inks and separated by the grid step the SwiftUI half's `HStack` spends.
        private let leadPct = NSTextField(labelWithString: "")
        private let dot = NSTextField(labelWithString: "")
        private let trailPct = NSTextField(labelWithString: "")

        init() {
            super.init(frame: .zero)
            build()
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError("not from a nib") }

        /// Hit-transparent, so the drag beneath is untouched: the chip sits centred ON the seam and
        /// is at its widest exactly where the pointer is holding the divider.
        override func hitTest(_: NSPoint) -> NSView? { nil }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            paint()
        }

        private func build() {
            translatesAutoresizingMaskIntoConstraints = false
            wantsLayer = true
            layer?.cornerRadius = Slate.Metric.radiusControl
            layer?.cornerCurve = .continuous
            layer?.borderWidth = Slate.Metric.hairline
            // The cast has to fall OUTSIDE the plate — a chip clipped to its own bounds keeps the
            // rim and loses the lift that makes it legible over busy terminal output.
            layer?.masksToBounds = false
            layer?.shadowRadius = Slate.Elevation.chip.radius
            layer?.shadowOffset = CGSize(width: 0, height: -Slate.Elevation.chip.y)
            layer?.shadowOpacity = 1

            for field in [leadPct, dot, trailPct] {
                field.translatesAutoresizingMaskIntoConstraints = false
                field.isSelectable = false
                field.maximumNumberOfLines = 1
                // The chip carries ONE accessibility label ("62 to 38 percent split"); three
                // separate fields would read as three unrelated numbers mid-drag.
                field.setAccessibilityElement(false)
                addSubview(field)
            }

            NSLayoutConstraint.activate([
                leadPct.leadingAnchor.constraint(
                    equalTo: leadingAnchor, constant: Slate.Metric.space2,
                ),
                leadPct.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space1),
                leadPct.bottomAnchor.constraint(
                    equalTo: bottomAnchor, constant: -Slate.Metric.space1,
                ),
                dot.leadingAnchor.constraint(
                    equalTo: leadPct.trailingAnchor, constant: Slate.Metric.space1,
                ),
                dot.centerYAnchor.constraint(equalTo: leadPct.centerYAnchor),
                trailPct.leadingAnchor.constraint(
                    equalTo: dot.trailingAnchor, constant: Slate.Metric.space1,
                ),
                trailPct.centerYAnchor.constraint(equalTo: leadPct.centerYAnchor),
                trailPct.trailingAnchor.constraint(
                    equalTo: trailingAnchor, constant: -Slate.Metric.space2,
                ),
            ])
            setAccessibilityRole(.staticText)
            applyText()
            paint()
        }

        private func applyText() {
            guard let percents else { return }
            leadPct.attributedStringValue = Self.run(
                "\(percents.leading)", ink: Slate.Native.Text.primary,
            )
            dot.attributedStringValue = Self.run("·", ink: Slate.Native.Text.tertiary)
            trailPct.attributedStringValue = Self.run(
                "\(percents.trailing)", ink: Slate.Native.Text.primary,
            )
            setAccessibilityLabel("\(percents.leading) to \(percents.trailing) percent split")
        }

        /// One run of the instrument voice — the same face, size and engraving the SwiftUI chip shell
        /// sets. Through ``macInstrumentString``, not spelled here: `MacCapsLabel.swift` owns this
        /// recipe for the whole target and a gate enforces that, because the kerning constant is the
        /// one part of it a seventh copy cannot fake its way around.
        private static func run(_ text: String, ink: SlateNativeColor) -> NSAttributedString {
            macInstrumentString(text, color: ink)
        }

        private func paint() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = Slate.Native.Terminal.raised.cgColor
                layer?.borderColor = Slate.Native.Terminal.rim.cgColor
                layer?.shadowColor = Slate.Native.State.overlayShadow.cgColor
            }
        }
    }
}
