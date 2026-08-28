// TerminalLeafView — the terminal pane leaf's content, in UIKit (docs/62 stage E, the pane-leaf cluster).
//
// Minimal by design, and the same shape the Mac landed: the terminal surface seam
// (``TerminalRendererFactory/make(model:isFocused:)``, else the headless ``BuildStatusPlaceholderView``),
// four decoration overlays coincident with it, one top-trailing chip column and one bottom hint slot. No
// cwd chrome, no per-pane status strip, no mounted command row — text delivery routes through
// `InputBarModel` headlessly on both platforms.
//
// WHAT IS LEFT HERE IS THE DRAWING AND THE TRIGGER. The split is ``TerminalPaneWiring``'s
// (`SlopDeskClientCore`): the five callback pairs, the dial, the autotype seam, the secure-input
// reconcile and the chip `×` all live there so the retain-cycle discipline, the teardown ORDER and the
// reference balance are written ONCE. This file keeps `withObservationTracking` and the UIKit lifecycle,
// and keeps no decision.
//
// ## The seam hands back a `UIView`, and nothing may sit between it and the touch
//
// ``TerminalRendererFactory/shared`` returns a ``TerminalSurfaceHosting`` whose `surfaceView` is a
// `PlatformView` — a `UIView` here. It is mounted DIRECTLY; there is no hosting view left to interpose,
// and interposing one is exactly the hit-claim the crossing exists to remove. A headless `swift build`
// registers no factory at all and gets the placeholder; nothing in this file names libghostty or Metal.
//
// ## THREE THINGS THE MAC DOES NOT HAVE, and this file does
//
//   1. THE KEY RESPONDER. A Metal layer answers no key event, so without ``TerminalInputHostView`` — a
//      zero-sized, touch-transparent SIBLING of the pixels — the pane cannot receive a keystroke at all.
//      On the Mac the renderer IS the first responder and there is nothing to hold. It is a sibling and
//      not a wrapper for exactly the reason above: it must never be in the way of a touch.
//   2. THE LETTERBOX. A phone is size-passive host-side (docs/45 §8.3), so the pane holds a grid it did
//      not choose and the surface is framed at its NATURAL size, scaled to fit, and centred, with the
//      `120×40 · sized by MacBook Pro` readout naming the client that picked the size. A Mac window IS a
//      grid contributor, so a letterbox there would frame a pane that is already right.
//   3. WHAT FALLS OUT OF (2): THE DECORATIONS RIDE INSIDE THE LETTERBOX. On the Mac the surface area IS
//      the surface's rect, so the four overlays are coincident with it by construction. Here the surface
//      is scaled, and every decoration reads ``TerminalCellMetrics`` in the surface's own UNSCALED point
//      space — so they are siblings of the renderer INSIDE ``stage``, and the scale is applied to the
//      stage. Mounted beside the stage instead they would draw a link underline a scale factor away from
//      the glyphs it underlines, on exactly the devices that letterbox.
//
// ⚠️ NO FLIP ANYWHERE. `UIView`'s coordinate space is top-left origin, which is the space
// ``TerminalCellMetrics``, ``TerminalLetterbox`` and ``PaneDropZoneLayout`` all already answer in. The
// AppKit half spends an `isFlipped` override per decoration to get there; here there is nothing to say,
// and the one place the y-axis DOES bite is the chip travel — see ``LeafChipReveal/offset(_:edge:)``.
//
// TWO THINGS THIS LEAF MOUNTS THAT ARE NOT THE PIXELS OR THE CHIPS, and each was a hole this header
// used to record rather than fill:
//
//   • THE COMMAND NAVIGATOR CARD (⌃⌘O). ``TerminalPaneWiring`` toggles ``CommandNavigatorChrome/isVisible``
//     for this pane — that is what `onRequestBlockNavigator` is bound to — and the flag went UNREAD here
//     while the chord took ⌃⌘O away from the PTY to flip a `Bool` nobody drew. It is read inside
//     ``follow()``'s arm now and mounted by ``applyNavigator(_:)`` as ``PhoneCommandNavigatorView``,
//     covering the whole surface area (the column and the hint slot included) because it is added after
//     them. Its Mac twin is ``SlopDeskMacUI/MacCommandNavigatorView`` and the divergences are written on
//     the card, not here.
//   • THE SEND-A-FILE PLATE, at the HEAD of the chip column on the FOCUSED pane — the iPhone's only door
//     for sending a file, since it has no second app to drag out of and ``PaneDropReceiverView`` therefore
//     has nothing to receive. It has no Mac twin. ``PaneFileImportPlateView`` presents the picker;
//     ``PaneFileImportPolicy`` decides what a picked file DOES, and this file resolves the pane at fire
//     time so a tap after a session swap cannot send to the pane that is gone.

#if os(iOS)
import Foundation
import SlopDeskClientCore // TerminalPaneWiring / TerminalLeafPolicy / PaneStatusPillPresentation
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import SlopDeskTerminal // TerminalLetterbox / TerminalViewportSnapshotting — the placement's two inputs
import SlopDeskVideoProtocol // ConfigRevision — the config-file edge the tracked read arms on
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel // PaneID — the two task keys
import UIKit

// MARK: - The leaf

/// One terminal pane's content: the pixels, the decorations over them, and the chrome beside them.
///
/// Built once per pane and kept — ``PaneContainerView`` keys it by ``PaneID``, so the surface and the
/// connection are never reused across panes (the identity hazard).
@MainActor
final class TerminalLeafView: UIView {
    // MARK: What the leaf was handed

    /// The live workspace store — the dial gate, the per-tab sync-input arming, the resolved grid, and
    /// what the wiring's host-path actions resolve a project key against.
    private let store: WorkspaceStore
    /// The scene's overlay coordinator, for the ⇧⌘F escalation and the host-action failure toast. `nil`
    /// outside the app scene (tests) ⇒ the failure is swallowed, never a crash.
    private let overlay: OverlayCoordinator?
    /// The shared chrome model, used ONLY to reveal the right code panel when an open-in-code-panel
    /// action lands. `nil` ⇒ the file still opens host-side, the panel just is not auto-revealed.
    private let chrome: WorkspaceChromeState?

    /// This pane's wiring — the find bar, the Secure Keyboard Entry actuator and the Command Navigator
    /// chrome, plus every callback they are driven by. Held as a stored property, exactly as the Mac
    /// holds it; neither half owns a decision in it.
    private let wiring: TerminalPaneWiring

    /// The pane's session handle, or `nil` for a not-yet-live / non-terminal pane. Settable because a
    /// session ARRIVES under a stable pane id.
    private var live: LivePaneSession?
    /// The host-reported working directory (`pane/cwd`, live-set from OSC 7), mirrored onto the model so
    /// the renderer's link hit-test can resolve a RELATIVE detected path to its absolute form.
    private var cwd: String?
    /// The pane's WORKSPACE focus. Drives the renderer's first responder — only the focused pane types —
    /// and never render-liveness, so an unfocused split sibling keeps repainting.
    private var isFocused: Bool

    // MARK: The tree

    /// The padded interior — `Slate.Metric.space2` on all four sides, so terminal content is not flush
    /// against the pane edges / split divider. EVEN on all four sides since the command ladder was
    /// removed and the gutter carries nothing. The inset shrinks the surface, so the host PTY grid loses
    /// ~1 col/row each side and reflows through the existing size → resize-scrim → `TIOCSWINSZ` path.
    private let surfaceArea = UIView()

    /// THE LETTERBOX STAGE: the renderer and its four decorations, at the grid's NATURAL size, scaled and
    /// centred inside ``surfaceArea``. See the header's point 3 for why the decorations live in here.
    ///
    /// Laid out by hand — ``place(_:)`` sets `bounds`, `transform` and `center`, and never `frame`, which
    /// is undefined under a non-identity transform. Its own children are laid out by
    /// ``TerminalStageView``, so no Auto Layout constraint ever crosses the scale.
    private let stage = TerminalStageView()

    /// The pixels: the production renderer's own view, or the headless placeholder. Held as `UIView`
    /// because that is all this file may know about it.
    private var surfaceView: UIView?
    /// The renderer behind ``surfaceView``, when there is one. `nil` for the placeholder and for a pane
    /// with no model yet.
    private var surfaceHost: TerminalSurfaceHosting?

    /// The four DECORATION overlays, coincident with the surface (origin 0,0 = surface top-left) and each
    /// inert until its own gate opens. They are decorations and never a content branch — the
    /// libghostty-freeze guardrail — so all four refuse touches except hint mode, which is deliberately
    /// interactive while it is armed.
    private var decorations: [UIView] = []

    /// The pane's key responder — see the header's point 1. Built with the first live session and kept:
    /// it registers with ``PaneFocusCoordinator`` under the pane id, and re-registering under a new id is
    /// what moves first responder when a session is swapped underneath a stable pane.
    private var inputHost: TerminalInputHostView?

    /// The top-trailing column: the vi-mode pill, then the status chips, then the find bar, stacked
    /// top→down so an open find bar reflows BELOW the persistent pills instead of overlapping them.
    private let chipColumn = UIStackView()
    /// The bottom slot, holding the vi key-hint bar when `⌘/` has toggled it on during a vi session. A
    /// one-tenant stack rather than a bare child so the reveal helper is the same code as the column's.
    private let hintSlot = UIStackView()
    /// `120×40 · sized by MacBook Pro`, in the letterbox BAR rather than in the stage — it explains the
    /// bars, so it may not be inside the thing they surround (and it must not be scaled with it).
    private let readoutCaption = GridReadoutCaptionView()

    /// What is mounted in the column right now, keyed by slot so a re-render moves nothing that has not
    /// changed. The ORDER is ``desiredSlots(_:findVisible:)``'s, which is
    /// ``PaneStatusPillPresentation/visible(_:)``'s — never re-derived here.
    private var mounted: [LeafChipSlot: UIView] = [:]
    /// The vi key-hint bar, when it is up. Separate from ``mounted`` because it lives in the bottom slot.
    private var hintBar: ViKeyHintBarView?

    /// The Command Navigator card, while it is up. Held so the leaf can forget it BEFORE the fade
    /// starts — a second ⌃⌘O during the retirement must build a fresh card rather than find this one on
    /// its way out.
    private var navigator: PhoneCommandNavigatorView?

    // MARK: The live reads

    /// The observation generation. `withObservationTracking` has no cancel, so an arm that has been
    /// superseded — by a live-session swap, by a settings flip, by a re-attach — must DROP its callback
    /// rather than re-arm from it. Without this the arms DOUBLE on every swap and quadruple on the next,
    /// which reads as the pane getting slower the longer it is open and has no crash to find it by.
    private var generation = 0
    /// `controls.auto-secure-input`, as last ACTED on. Kept because the lock is reconciled on the EDGE,
    /// not on the reading: a config edit to an unrelated key re-runs ``follow()`` and must not re-engage
    /// a lock the user turned off. Inert on this platform (the actuator's phone half is a no-op seam),
    /// and kept anyway so the two shells drive the controller through the same one door.
    private var autoSecureInput = SettingsKey.autoSecureInputEnabled
    /// `controls.secure-input-indicator` — the chip gate. No edge to speak of; re-reading the pill
    /// conditions is the whole of applying it.
    private var secureInputIndicator = SettingsKey.secureInputIndicatorEnabled

    /// The grid the HOST resolved for this pane, and the line that names who resolved it. Both are store
    /// reads taken inside the tracked arm, so a reflow driven by another client re-letterboxes an idle
    /// pane here without anything having to poke it.
    private var grid: (cols: Int, rows: Int)?
    private var readout: String?

    /// The two `.task(id:)` keys, as last acted on. A task fires when its key MOVES, which is the whole
    /// of ``TerminalLeafPolicy``'s argument: a key that is already the pane's id while the gate is shut is
    /// a task that ran once, too early, and never again.
    private var dialKey: PaneID?
    private var autotypeKey: PaneID?
    private var dialTask: Task<Void, Never>?
    private var autotypeTask: Task<Void, Never>?

    /// Whether the wiring is installed. It is idempotent, but re-installing it on every window change
    /// would also re-arm the observation for no reason.
    private var isWired = false

    /// Whether this leaf is behind another tab — see ``setOccluded(_:)``.
    private var occluded = false

    // MARK: - Life

    init(
        live: LivePaneSession?,
        isFocused: Bool,
        cwd: String?,
        store: WorkspaceStore,
        overlay: OverlayCoordinator?,
        chrome: WorkspaceChromeState?,
        wiring: TerminalPaneWiring = TerminalPaneWiring(),
    ) {
        self.live = live
        self.isFocused = isFocused
        self.cwd = cwd
        self.store = store
        self.overlay = overlay
        self.chrome = chrome
        self.wiring = wiring
        super.init(frame: .zero)
        build()
        mountSurface()
        attach()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        // The pane's paper. A dynamic `UIColor` on the VIEW re-resolves itself on a theme flip; only a
        // `CGColor` hung on a layer is flat, which is what the Mac's `updateLayer` + appearance override
        // is spent on and what does not survive the crossing.
        backgroundColor = Slate.Native.Surface.terminal

        surfaceArea.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surfaceArea)
        // The stage is placed by hand and must not be reached by the constraint engine — see its own
        // declaration. It is added FIRST so every piece of chrome below sits above it.
        surfaceArea.addSubview(stage)

        // The column and the slot are TRANSPARENT trays: every tenant delineates itself, so the
        // containers only place and space them.
        chipColumn.axis = .vertical
        chipColumn.alignment = .trailing
        chipColumn.spacing = Slate.Metric.space2
        chipColumn.translatesAutoresizingMaskIntoConstraints = false
        hintSlot.axis = .vertical
        hintSlot.alignment = .center
        hintSlot.spacing = Slate.Metric.space2
        hintSlot.translatesAutoresizingMaskIntoConstraints = false
        surfaceArea.addSubview(readoutCaption)
        surfaceArea.addSubview(chipColumn)
        surfaceArea.addSubview(hintSlot)
        readoutCaption.isHidden = true

        NSLayoutConstraint.activate([
            surfaceArea.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space2),
            surfaceArea.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: Slate.Metric.space2,
            ),
            trailingAnchor.constraint(
                equalTo: surfaceArea.trailingAnchor, constant: Slate.Metric.space2,
            ),
            bottomAnchor.constraint(
                equalTo: surfaceArea.bottomAnchor, constant: Slate.Metric.space2,
            ),
            chipColumn.topAnchor.constraint(
                equalTo: surfaceArea.topAnchor, constant: Slate.Metric.space2,
            ),
            surfaceArea.trailingAnchor.constraint(
                equalTo: chipColumn.trailingAnchor, constant: Slate.Metric.space2,
            ),
            hintSlot.centerXAnchor.constraint(equalTo: surfaceArea.centerXAnchor),
            surfaceArea.bottomAnchor.constraint(
                equalTo: hintSlot.bottomAnchor, constant: Slate.Metric.space2,
            ),
            // The caption sits UNDER the hint slot in z-order and on the same edge: the two are never up
            // together in practice (a vi session in a letterboxed pane is the only overlap, and the bar
            // is the louder of the two), and the caption is hit-transparent either way.
            readoutCaption.centerXAnchor.constraint(equalTo: surfaceArea.centerXAnchor),
            surfaceArea.bottomAnchor.constraint(
                equalTo: readoutCaption.bottomAnchor, constant: Slate.Metric.space2,
            ),
        ])
    }

    /// The stage is the one thing here Auto Layout does not place, so a layout pass is where its
    /// placement is recomputed — the surface area's size is the letterbox's container, and it moves for
    /// every reason a pane moves (a divider commit, a rotation, the keyboard, a zoom, a tab switch).
    ///
    /// It READS the model and sets frames, and writes nothing back (docs/62 hazard 7): the grid and the
    /// readout are pulled from ``follow()``'s tracked arm, and only the placement arithmetic runs here.
    override func layoutSubviews() {
        super.layoutSubviews()
        place()
        // The hint bar is MEASURED rather than constrained: it picks a column rung from the width it is
        // offered, which is the UIKit stand-in for the `ProposedViewSize` its SwiftUI twin was handed.
        hintBar?.availableWidth = surfaceArea.bounds.width - 2 * Slate.Metric.space2
    }

    // MARK: - Attach / detach, and the one thing that is not symmetric

    /// The UIKit spelling of `.onAppear` / `.onDisappear`, with ONE deliberate asymmetry.
    ///
    /// The WIRING detaches when the leaf leaves the view tree. It is idempotent and re-installable, so
    /// re-attaching costs nothing.
    ///
    /// The SURFACE does not. ``TerminalSurfaceHosting/detachSurface()`` drops libghostty's renderer and
    /// io threads, which is not re-installable and would take the session with it — and a leaf can leave
    /// the tree without its pane going away (a split rearrange re-parents it). So the surface is dropped
    /// only by ``teardown()``, which the mounter calls when the pane is closed for good.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil, superview == nil {
            detach()
        } else if window != nil {
            attach()
        }
    }

    private func attach() {
        guard !isWired else { return }
        isWired = true
        wiring.wire(
            live: live, store: store, overlay: overlay, chrome: chrome,
            autoSecureInput: autoSecureInput,
        )
        applyCwd()
        follow()
    }

    private func detach() {
        guard isWired else { return }
        isWired = false
        // Supersede every armed observation FIRST: a callback that lands after the wiring is cleared
        // would re-arm against a model this leaf no longer drives.
        generation &+= 1
        dialTask?.cancel()
        dialTask = nil
        autotypeTask?.cancel()
        autotypeTask = nil
        dialKey = nil
        autotypeKey = nil
        // The card carries an observation arm of its own against this pane's block model, and an arm
        // cannot be cancelled — so it is dropped HERE rather than left to fade off a tree the leaf has
        // stopped driving.
        dropNavigator()
        wiring.clear(live: live)
    }

    /// The pane is closed for good: drop the wiring, the responder AND the libghostty surface. See
    /// ``didMoveToWindow()`` for why the last is not automatic.
    func teardown() {
        detach()
        // The responder goes with the pane, and it goes EXPLICITLY: it holds first responder and a
        // registration in the focus coordinator, neither of which a `deinit` can be relied on to reach
        // in time (docs/62 hazard 6).
        inputHost?.detach()
        inputHost?.removeFromSuperview()
        inputHost = nil
        surfaceHost?.detachSurface()
        surfaceHost = nil
        surfaceView?.removeFromSuperview()
        surfaceView = nil
        for decoration in decorations { retire(decoration) }
        decorations = []
        hintBar = nil
    }

    /// Every decoration that owns a beat is told to end it. `teardown()` is the ONLY caller — the four
    /// types each explain why a `deinit` cancel would be cancelling nothing.
    private func retire(_ decoration: UIView) {
        (decoration as? LinkHighlightOverlayView)?.teardown()
        (decoration as? PromptJumpFlashOverlayView)?.teardown()
        (decoration as? ViCursorOverlayView)?.teardown()
        (decoration as? HintModeOverlayView)?.teardown()
        decoration.removeFromSuperview()
    }

    // MARK: - What the mounter pushes

    /// A session arrived, or was swapped under a stable pane id. Re-wires and rebuilds the pixels if the
    /// model changed.
    func setLive(_ live: LivePaneSession?) {
        guard live !== self.live else { return }
        let hadModel = self.live?.terminalModel
        if isWired { wiring.clear(live: self.live) }
        self.live = live
        if live?.terminalModel !== hadModel {
            surfaceHost?.detachSurface()
            mountSurface()
        }
        applyInputHost()
        if isWired {
            wiring.wire(
                live: live, store: store, overlay: overlay, chrome: chrome,
                autoSecureInput: autoSecureInput,
            )
            applyCwd()
            follow()
        }
    }

    /// The pane's workspace focus moved. There is no render pass to re-run for this, so the push is
    /// explicit (the seam says so at ``TerminalRendererFactory/make(model:isFocused:)``).
    ///
    /// The RESPONDER is not moved from here: which pane holds first responder is
    /// ``PaneFocusCoordinator``'s, driven off the store's active pane, and a second mover would race it.
    func setFocused(_ isFocused: Bool) {
        guard isFocused != self.isFocused else { return }
        self.isFocused = isFocused
        surfaceHost?.setPaneFocused(isFocused)
        // ⚠️ AND THE CHROME IS RECONCILED, because one chip is focus-gated. `isFocused` is a PUSHED
        // property, not an observable one, so nothing wakes ``follow()``'s arm for it — and the
        // send-a-file plate would then appear on whichever pane happened to be focused when the leaf
        // last drew and stay there. Re-running the arm is the supersede pattern the method already
        // documents, not a second one.
        if isWired { follow() }
    }

    /// The host reported a new cwd (OSC 7). It changes independently of the session id, which is why it
    /// gets its own push rather than being folded into the wiring's.
    func setCwd(_ cwd: String?) {
        guard cwd != self.cwd else { return }
        self.cwd = cwd
        applyCwd()
        // The link overlay resolves relative paths against the MODEL, not a copy, so nothing else moves.
    }

    private func applyCwd() {
        live?.terminalModel?.linkCwd = cwd
    }

    // MARK: - Occlusion (docs/56 risk 3, and the half of it that dissolves here)

    /// This leaf is behind another tab, or is back in front.
    ///
    /// TWO THINGS MOVE, where the Mac needs three.
    ///
    /// 1. `layer.opacity`, NEVER `isHidden`. The terminal surface is a layer-hosting view: libghostty
    ///    installs its own surface layer in the `layer` slot and sizes that layer's frame and
    ///    `contentsScale` in `layoutSubviews`, which does not run on a hidden subtree. A device rotated
    ///    or moved to an external display while this tab was hidden would un-hide onto stale geometry.
    ///    Faded, the leaf keeps laying out and there is nothing to catch up on.
    ///
    /// 2. `isUserInteractionEnabled`, which is the whole of the Mac's points 2 AND 3. UIKit refuses hits
    ///    for a view AND ITS ENTIRE SUBTREE when the flag is off, so a background tab's terminal cannot
    ///    take a touch — and there is no `NSTrackingArea` on this platform to keep firing under whatever
    ///    is composited above it, so ``MacLeafOcclusion``'s subtree sweep, its runloop-coalesced re-sweep
    ///    and its `updateTrackingAreas` hook have no counterpart at all. A pointer on an iPad reaches a
    ///    view through `UIHoverGestureRecognizer`, which is a RECOGNISER on a view and dies with the same
    ///    flag rather than surviving as a free-standing rect.
    ///
    /// 3. `accessibilityElementsHidden`, which neither shell gets for free: a faded leaf is still in the
    ///    accessibility tree, and a VoiceOver rotor that walked into the hidden tab's terminal would read
    ///    out a pane the user cannot see.
    func setOccluded(_ occluded: Bool) {
        guard occluded != self.occluded else { return }
        self.occluded = occluded
        layer.opacity = occluded ? 0 : 1
        isUserInteractionEnabled = !occluded
        accessibilityElementsHidden = occluded
    }

    /// Whether this leaf is currently behind another tab.
    var isOccluded: Bool { occluded }

    // MARK: - The pixels

    /// The terminal surface seam — the production renderer if the app registered a native factory, else
    /// the headless placeholder. This target NEVER imports libghostty or Metal: it only calls the factory.
    ///
    /// The decorations are rebuilt with it because every one of them is constructed AROUND a model.
    private func mountSurface() {
        surfaceView?.removeFromSuperview()
        surfaceView = nil
        surfaceHost = nil
        for decoration in decorations { retire(decoration) }
        decorations = []
        hintBar = nil

        applyInputHost()
        guard let model = live?.terminalModel else { return }

        let pixels: UIView
        if let host = TerminalRendererFactory.make(model: model, isFocused: isFocused) {
            surfaceHost = host
            pixels = host.surfaceView
        } else {
            pixels = BuildStatusPlaceholderView(model: model)
        }
        surfaceView = pixels
        stage.addSubview(pixels)

        // The four decorations, in the Mac half's z-order and in the stage's own space — see the header's
        // point 3. Cell metrics answer with origin 0,0 at the surface's top-left, which is the stage's
        // origin exactly, so the rects map straight on however the stage is scaled.
        for decoration in [
            LinkHighlightOverlayView(model: model, cwd: cwd) as UIView,
            PromptJumpFlashOverlayView(model: model),
            ViCursorOverlayView(model: model),
            HintModeOverlayView(model: model),
        ] {
            decorations.append(decoration)
            stage.addSubview(decoration)
        }
        setNeedsLayout()
    }

    /// The pane's key responder, mounted for as long as there is a session to type into.
    ///
    /// Zero-sized and touch-transparent, and a SIBLING of the pixels rather than an ancestor: it holds
    /// first responder, the accessory row and the press handlers, and nothing visual. It is added to
    /// ``surfaceArea`` and not to the stage because it is not a decoration — it is not in the surface's
    /// coordinate space and must not be scaled with it.
    private func applyInputHost() {
        guard let live else {
            inputHost?.detach()
            inputHost?.removeFromSuperview()
            inputHost = nil
            return
        }
        let host = inputHost ?? {
            let made = TerminalInputHostView()
            made.frame = .zero
            surfaceArea.addSubview(made)
            inputHost = made
            return made
        }()
        host.attach(to: live, store: store, focusCoordinator: store.focusCoordinator)
    }

    // MARK: - The letterbox (docs/45 §8.3)

    /// Places the stage: the grid at its natural size, scaled to fit, centred, with the readout in the
    /// bar it leaves.
    ///
    /// DEGRADES TO FULL-BLEED, and the degrade is ``TerminalLetterbox/placement(grid:cellSize:in:)``'s
    /// own contract: every input can legitimately be absent — the roster has not landed, the renderer is
    /// a placeholder with no cell metrics, or the layout pass has not run — and in each of those cases
    /// the surface fills the area exactly as it always did. An absent letterbox, never a wrong one.
    ///
    /// `bounds` + `center`, never `frame`: under a non-identity transform a view's `frame` is undefined,
    /// so assigning it would place the stage at a rect nothing can predict.
    private func place() {
        let container = surfaceArea.bounds.size
        guard container.width > 0, container.height > 0 else { return }
        guard let placement = TerminalLetterbox.placement(
            grid: grid, cellSize: cellSize(), in: container,
        ) else {
            stage.transform = .identity
            stage.bounds = CGRect(origin: .zero, size: container)
            stage.center = CGPoint(x: container.width / 2, y: container.height / 2)
            readoutCaption.isHidden = true
            return
        }
        // The surface is framed at the grid's NATURAL size and then transformed, so the renderer lays out
        // exactly `cols × rows` and the scale is a layer transform over the result. Sizing it to the
        // SCALED rect instead would make the renderer derive a different grid from its own bounds — the
        // phone would reflow to its own window, which is what size-passivity exists to stop.
        stage.transform = .identity
        stage.bounds = CGRect(origin: .zero, size: placement.natural)
        stage.transform = CGAffineTransform(scaleX: placement.fit.scale, y: placement.fit.scale)
        stage.center = CGPoint(x: placement.fit.contentRect.midX, y: placement.fit.contentRect.midY)
        // Only when there IS a bar: on an exact fit the caption would sit on top of the terminal's last
        // row, which is the one place it explains nothing.
        readoutCaption.isHidden = !(placement.fit.isLetterboxed && readout != nil)
        readoutCaption.text = readout
    }

    /// The renderer's own natural per-cell advance, in POINTS. A NON-REACTIVE readback off the live
    /// surface's ``TerminalViewportSnapshotting`` seam — it is a fact about the mounted renderer, not
    /// observable state, and a placeholder / headless / pre-layout surface has none, which is exactly
    /// when the placement degrades.
    private func cellSize() -> CGSize? {
        guard let snapshot = live?.terminalModel?.surface as? TerminalViewportSnapshotting else {
            return nil
        }
        let metrics = snapshot.cellMetrics()
        return metrics.map { CGSize(width: $0.cellWidth, height: $0.cellHeight) }
    }

    // MARK: - The live read

    /// ONE tracked read of everything this leaf draws or triggers on, re-armed by its own `onChange`.
    ///
    /// One arm rather than one per concern deliberately: `withObservationTracking` fires on the FIRST
    /// change to anything it read, so N arms cost N callbacks for one edit and give nothing back — every
    /// read below is a property access on an object this leaf already holds.
    ///
    /// The generation check is the file's other observation rule: this method is called from the callback
    /// AND from ``attach()`` and ``setLive(_:)``, and an arm cannot be cancelled. A superseded arm must
    /// therefore drop its callback instead of re-arming from it.
    private func follow() {
        generation &+= 1
        let generation = generation

        var conditions = PaneStatusConditions()
        var hintsToggled = false
        var findVisible = false
        var navigatorVisible = false
        var dial: PaneID?
        var autotype: PaneID?
        var auto = autoSecureInput

        withObservationTracking {
            // The config-file edge. `AppConfig` is a plain locked global, so the two settings below are
            // not observable on their own — the REVISION is, and reading it HERE (never hoisted out of
            // the block, which silently unsubscribes the view) is what makes a saved config file
            // reconcile every open pane. See ``ConfigRevision``.
            _ = ConfigRevision.shared.generation
            auto = SettingsKey.autoSecureInputEnabled
            secureInputIndicator = SettingsKey.secureInputIndicatorEnabled
            conditions = pillConditions()
            hintsToggled = live?.terminalModel?.showViKeyHints ?? false
            findVisible = wiring.findBar.visible && live?.terminalModel != nil
            // ⌃⌘O. The model guard is the card's own precondition — it reads a live block store — and
            // it is the same pairing the find bar's read above uses.
            navigatorVisible = wiring.navigatorChrome.isVisible && live?.terminalModel != nil
            // THE LETTERBOX'S TWO STORE READS, INSIDE THE ARM. The resolved grid is the host's answer for
            // this pane and moves when ANOTHER client joins or leaves the fold; read outside the arm this
            // pane would keep the grid it happened to have at mount and never re-place, on a device that
            // cannot cause a reflow itself and so has nothing else to poke it.
            grid = live.flatMap { store.paneResolvedGrid(for: $0.id) }
            readout = live.flatMap { store.paneGridReadout(for: $0.id) }
            dial = TerminalLeafPolicy.dialTaskKey(pane: live?.id, mayDial: store.panesMayDial)
            autotype = TerminalLeafPolicy.autotypeTaskKey(
                pane: live?.id,
                isTarget: live?.isAutotypeTarget ?? false,
                status: live?.connection?.status,
            )
        } onChange: { [weak self] in
            // The hop is required, not stylistic: `onChange` runs INSIDE the mutation, so re-arming from
            // it would read half-written state. `assumeIsolated` is the honest spelling of what the main
            // queue already guarantees.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation else { return }
                    self.follow()
                }
            }
        }

        // The lock is reconciled only on the AUTO edge: the wiring re-syncs on a pane swap, so without
        // this an engaged lock would linger past the user turning `controls.auto-secure-input` off.
        // Inline rather than a callback, because this method IS the observation callback — a hop back
        // through it would recurse.
        if auto != autoSecureInput {
            autoSecureInput = auto
            wiring.reconcileSecureInput(live: live, autoSecureInput: auto)
            conditions = pillConditions()
        }
        place()
        applyChrome(conditions: conditions, hintsToggled: hintsToggled, findVisible: findVisible)
        applyNavigator(navigatorVisible)
        applyTriggers(dial: dial, autotype: autotype)
    }

    /// Everything the pill gates read, taken once per pass.
    ///
    /// Every field is an OBSERVABLE mirror — never the `@ObservationIgnored` `isReadOnly` / `isCopyMode`
    /// the renderer's key path reads — so reading them HERE is what makes the chips light and clear
    /// reactively. A not-yet-live pane reads as all-false, which shows no chip.
    private func pillConditions() -> PaneStatusConditions {
        guard let model = live?.terminalModel else { return PaneStatusConditions() }
        return PaneStatusConditions(
            readOnly: model.readOnlyBadgeActive,
            copyMode: model.copyModeBadgeActive,
            hintMode: model.hintMode != nil,
            secureInput: model.secureInputActive,
            secureInputIndicator: secureInputIndicator,
            syncInput: live.map { store.syncInputArmed(for: $0.id) } ?? false,
        )
    }

    // MARK: - The chrome

    private func applyChrome(
        conditions: PaneStatusConditions, hintsToggled: Bool, findVisible: Bool,
    ) {
        applyColumn(desiredSlots(conditions, findVisible: findVisible))
        applyHintBar(
            PaneStatusPillPresentation.showsViKeyHintBar(conditions, hintsToggled: hintsToggled),
        )
    }

    /// The column's tenants, TOP-DOWN.
    ///
    /// WHICH chips are up and in WHAT ORDER is not this view's to say: it is one ordered list in
    /// ``PaneStatusPillPresentation/visible(_:)``, so this half asks the same question the Mac's does
    /// rather than re-deriving "read-only hides under vi, secure input hides under read-only, sync input
    /// hides under nothing" from the same prose and being right by luck.
    ///
    /// ⚠️ THE ONE TENANT THAT IS NOT A READING OF THE PANE'S STATE is the send-a-file plate at the head:
    /// it is a VERB, always available, and it is gated on FOCUS rather than on a condition because the
    /// column belongs to every pane while the picker sends to exactly one. A chooser pane has no
    /// terminal model and still takes a file — ``PaneFileImportPolicy`` says so by taking the model as
    /// an optional — so the gate is the session, not the model.
    private func desiredSlots(
        _ conditions: PaneStatusConditions, findVisible: Bool,
    ) -> [LeafChipSlot] {
        var slots: [LeafChipSlot] = []
        if isFocused, live != nil { slots.append(.fileImport) }
        if PaneStatusPillPresentation.showsViModePill(conditions), live?.terminalModel != nil {
            slots.append(.viMode)
        }
        slots.append(contentsOf: PaneStatusPillPresentation.visible(conditions).map { .pill($0) })
        if findVisible { slots.append(.find) }
        return slots
    }

    private func applyColumn(_ desired: [LeafChipSlot]) {
        for (slot, view) in mounted where !desired.contains(slot) {
            mounted[slot] = nil
            LeafChipReveal.dismiss(view, towards: .top)
        }
        for slot in desired where mounted[slot] == nil {
            guard let view = makeChip(slot) else { continue }
            mounted[slot] = view
            // The insertion point is measured against what is STILL in the stack, which includes anything
            // currently animating out. Counting only the kept predecessors would put a new chip above a
            // leaving one and make the column jump.
            let index = desired.prefix(while: { $0 != slot })
                .compactMap { mounted[$0] }
                .compactMap { chipColumn.arrangedSubviews.firstIndex(of: $0) }
                .max()
                .map { $0 + 1 } ?? 0
            LeafChipReveal.present(view, in: chipColumn, at: index, from: .top)
        }
    }

    private func makeChip(_ slot: LeafChipSlot) -> UIView? {
        switch slot {
        case .fileImport:
            // EVERY INPUT RESOLVED AT FIRE TIME, none at build time. The chip outlives a session swap
            // under a stable pane id (that is what ``setLive(_:)`` is for), so a plate that had captured
            // `live` would send the file to a pane that is gone. The decision itself is the policy's and
            // is not touched here.
            return PaneFileImportPlateView { [weak self] urls in
                guard let self, let live else { return }
                PaneFileImportPolicy.actuate(
                    picked: urls, store: store, terminalModel: live.terminalModel,
                    overlay: overlay, paneID: live.id,
                )
            }
        case .viMode:
            guard let model = live?.terminalModel else { return nil }
            // `exitCopyMode()` is the SINGLE exit seam — it also resets the count, the visual mode and the
            // hint bar, so the `×`, `Esc`/`q` and a programmatic dismiss converge on one state rather than
            // on three nearly-identical teardowns.
            return ViModePillView(model: model, onExit: { [weak model] in model?.exitCopyMode() })
        case let .pill(pill):
            return PaneStatusPillView(pill: pill, onDismiss: { [weak self] in
                guard let self else { return }
                TerminalPaneWiring.dismiss(pill, live: live, store: store)
            })
        case .find:
            return TerminalFindBarView(model: wiring.findBar)
        }
    }

    /// The vi key-hint bar along the pane BOTTOM. The gate is `copyModeBadgeActive`-first, so the card
    /// tears down the instant vi mode exits (which also resets `showViKeyHints`).
    private func applyHintBar(_ wanted: Bool) {
        if wanted, hintBar == nil {
            let bar = ViKeyHintBarView()
            bar.availableWidth = surfaceArea.bounds.width - 2 * Slate.Metric.space2
            hintBar = bar
            LeafChipReveal.present(bar, in: hintSlot, at: 0, from: .bottom)
        } else if !wanted, let bar = hintBar {
            hintBar = nil
            LeafChipReveal.dismiss(bar, towards: .bottom)
        }
    }

    // MARK: - The Command Navigator card

    /// Mounts or retires the ⌃⌘O card over this pane's whole surface area.
    ///
    /// It is added LAST, so it covers the chip column and the hint slot as well as the pixels — the
    /// card is modal over the pane, and a chip standing on top of it would be the one thing on screen
    /// that still took a touch.
    ///
    /// THE ORDER ON THE WAY OUT IS THE MAC'S, with one line UIKit adds. The leaf forgets the card
    /// first, so a second ⌃⌘O during the fade builds a fresh one; then ``PhoneCommandNavigatorView/teardown()``
    /// supersedes the card's observation arm, which the Mac's twin has no counterpart for because the
    /// generation guard is this platform's rule (docs/62 §3.1); then the fade runs; then the pane takes
    /// its keyboard back. There is no ``SlopDeskMacUI/MacPaneCardShield`` half — the card's own header
    /// says why a tracking-area shield has nothing to guard against here.
    private func applyNavigator(_ wanted: Bool) {
        if wanted, navigator == nil {
            guard let model = live?.terminalModel else { return }
            let card = PhoneCommandNavigatorView(model: model, store: store) { [weak self] in
                self?.wiring.navigatorChrome.isVisible = false
            }
            navigator = card
            card.translatesAutoresizingMaskIntoConstraints = false
            surfaceArea.addSubview(card)
            NSLayoutConstraint.activate([
                card.leadingAnchor.constraint(equalTo: surfaceArea.leadingAnchor),
                card.trailingAnchor.constraint(equalTo: surfaceArea.trailingAnchor),
                card.topAnchor.constraint(equalTo: surfaceArea.topAnchor),
                card.bottomAnchor.constraint(equalTo: surfaceArea.bottomAnchor),
            ])
            card.reveal()
        } else if !wanted, let card = navigator {
            navigator = nil
            card.teardown()
            card.retire()
            store.reclaimKeyboardFocusInActivePane()
        }
    }

    /// The card goes NOW, with no fade — the leaf is being detached or torn down, so there is nothing
    /// left for it to fade over.
    private func dropNavigator() {
        guard let card = navigator else { return }
        navigator = nil
        card.teardown()
        card.removeFromSuperview()
    }

    // MARK: - The two triggers

    /// The UIKit reading of two `.task(id:)`s: a task runs when its key MOVES, and a key that went to
    /// `nil` cancels rather than starts.
    private func applyTriggers(dial: PaneID?, autotype: PaneID?) {
        if dial != dialKey {
            dialKey = dial
            dialTask?.cancel()
            dialTask = nil
            if dial != nil {
                let live = live
                let store = store
                dialTask = Task { @MainActor in
                    await TerminalPaneWiring.connectIfNeeded(live: live, store: store)
                }
            }
        }
        if autotype != autotypeKey {
            autotypeKey = autotype
            autotypeTask?.cancel()
            autotypeTask = nil
            if autotype != nil {
                let live = live
                autotypeTask = Task { @MainActor in
                    await TerminalPaneWiring.runAutotypeIfRequested(live: live)
                }
            }
        }
    }
}

// MARK: - The stage

/// The letterbox stage: a manual-layout container whose every child fills its bounds.
///
/// It exists as a type rather than as a bare `UIView` for one reason — the stage carries a SCALE
/// transform, and a constraint that crossed it would be solved in the wrong space. Sizing the children by
/// hand keeps Auto Layout entirely outside the scaled subtree, so the renderer and its four decorations
/// all lay out at the grid's natural size and the scale is applied once, above them, by the leaf.
@MainActor
private final class TerminalStageView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        for subview in subviews {
            subview.frame = bounds
        }
    }

    override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        // Manual layout all the way down: a child that kept the flag would have the engine synthesise
        // constraints from a frame this view is about to overwrite.
        subview.translatesAutoresizingMaskIntoConstraints = true
        subview.frame = bounds
    }
}

// MARK: - The readout caption

/// The `120×40 · sized by MacBook Pro` caption, in the bar below the grid (docs/45 §8.3 rule 7).
///
/// Without it a user sees a pane that is the wrong size for no stated reason, and a rule reads as a bug.
/// Hit-transparent — it explains, it does not act.
@MainActor
private final class GridReadoutCaptionView: UIView {
    var text: String? {
        didSet {
            guard text != oldValue else { return }
            label.text = text
            accessibilityLabel = text
        }
    }

    private let label = UILabel()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        layer.cornerRadius = Slate.Metric.radiusControl
        layer.cornerCurve = .continuous
        layer.borderWidth = Slate.Metric.hairline
        backgroundColor = Slate.Native.Surface.raised

        label.font = .systemFont(ofSize: Slate.Typeface.footnote, weight: .medium)
        label.textColor = Slate.Native.Text.secondary
        label.numberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space2),
            trailingAnchor.constraint(equalTo: label.trailingAnchor, constant: Slate.Metric.space2),
            label.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space1),
            bottomAnchor.constraint(equalTo: label.bottomAnchor, constant: Slate.Metric.space1),
        ])
        // A `CGColor` on a layer is RESOLVED, never dynamic — it froze at whichever appearance was
        // current when it was assigned. The registration names the ONE trait this view depends on.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _: UITraitCollection) in
            view.reink()
        }
        reink()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    private func reink() {
        layer.borderColor = Slate.Native.Line.subtle.resolvedColor(with: traitCollection).cgColor
    }
}

// MARK: - What can stand in the column

/// One tenant of the pane's top-trailing column, as an identity.
///
/// It exists so the column can be DIFFED rather than rebuilt: a chip that is still wanted keeps the view
/// it already has, which is what keeps a ``TerminalFindBarView`` from losing its `UITextField` — and with
/// it the insertion point and any in-flight IME composition — every time an unrelated chip appears beside
/// it.
private enum LeafChipSlot: Hashable {
    /// The send-a-file plate. No payload: there is one per leaf and it is the same plate whatever the
    /// pane is showing — the pane it acts on is resolved when it is tapped, not when it is keyed.
    case fileImport
    case viMode
    case pill(PaneStatusPill)
    case find
}

// MARK: - The reveal

/// Which edge a chip travels from, and back to.
private enum LeafChipEdge {
    case top
    case bottom
}

/// The column's arrival and departure motion.
///
/// Three things make up the transition and UIKit spells all three in ONE animator, which is the whole
/// simplification over the AppKit half: the FADE is `alpha`, the stack's own REFLOW is `isHidden` on an
/// arranged subview (`UIStackView` animates that inside an animation block — it is the documented
/// idiom), and the TRAVEL is `transform`. AppKit needs a `CABasicAnimation` for the travel because the
/// animator proxy fights Auto Layout; a `UIView` transform composes on top of whatever the engine
/// resolved and never argues with it.
///
/// ⚠️ THE DIRECTION IS INVERTED FROM THE MAC'S, and this is the one place rule 7's coordinate flip
/// actually bites in this file. See ``offset(_:edge:)``.
@MainActor
private enum LeafChipReveal {
    static func present(_ view: UIView, in stack: UIStackView, at index: Int, from edge: LeafChipEdge) {
        view.alpha = 0
        view.isHidden = true
        stack.insertArrangedSubview(view, at: min(index, stack.arrangedSubviews.count))
        // The compressed fitting size, not `frame`: the view is hidden, so the stack has given it no
        // height yet, and a travel of zero is no travel at all.
        let height = view.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height
        view.transform = CGAffineTransform(translationX: 0, y: offset(height, edge: edge))
        animate {
            view.isHidden = false
            view.alpha = 1
            view.transform = .identity
        }
    }

    static func dismiss(_ view: UIView, towards edge: LeafChipEdge) {
        let travel = offset(view.bounds.height, edge: edge)
        animate({
            view.alpha = 0
            view.isHidden = true
            view.transform = CGAffineTransform(translationX: 0, y: travel)
        }, thenRemoving: view)
    }

    /// How far, and in which direction.
    ///
    /// ⚠️ `UIView`'s coordinate space is y-DOWN, so a chip that arrives "from the top" starts at a
    /// NEGATIVE offset and one that arrives from the bottom at a positive one — the exact opposite of
    /// `MacLeafChipReveal.offset`, whose own comment names AppKit's y-up default as its reason.
    /// Transliterated sign-for-sign, every chip would enter from the wrong side of the column. The gap is
    /// included so the chip clears the neighbour it is sliding past.
    private static func offset(_ height: CGFloat, edge: LeafChipEdge) -> CGFloat {
        let distance = height + Slate.Metric.space2
        switch edge {
        case .top: return -distance
        case .bottom: return distance
        }
    }

    /// The reveal curve around one mutation, optionally retiring a view when it settles.
    ///
    /// `UIViewPropertyAnimator` rather than `UIView.animate(withDuration:)`, because the rung is a CUBIC
    /// BEZIER and the convenience API takes only a `UIView.AnimationOptions` easing name. `Slate` owns the
    /// four control points and the duration; this file owns only which properties move.
    ///
    /// The retiring view is reset to identity before it goes: a `UIStackView` recycles nothing, but a
    /// transform left on a view the caller might re-insert is a chip that arrives already displaced.
    private static func animate(_ body: @escaping () -> Void, thenRemoving retiring: UIView? = nil) {
        let curve = Slate.Motion.reveal
        let animator = UIViewPropertyAnimator(
            duration: curve.duration,
            controlPoint1: CGPoint(x: curve.x1, y: curve.y1),
            controlPoint2: CGPoint(x: curve.x2, y: curve.y2),
            animations: body,
        )
        animator.addCompletion { _ in
            guard let retiring else { return }
            retiring.removeFromSuperview()
            retiring.transform = .identity
            retiring.alpha = 1
            retiring.isHidden = false
        }
        animator.startAnimation()
    }
}

// MARK: - The pane's key responder

// The phone's terminal input surface — the UIKit half of `SlopDeskWorkspaceCore.PhoneKey`.
//
// Until this existed the phone's terminal could not receive a keystroke at all: the rules were written,
// ported and tested, and nothing mounted a responder to ask them. This is that responder, and it is
// deliberately thin — it reads a `UIKey` into a `PhoneKey.Press`, asks which of the two paths the press
// takes, and writes the answer to the pane. It decides nothing: which keys are special, what bytes they
// send under the live cursor-key mode, which press is a chord and when the accessory row is worth its
// space are all `slopdesk_workspace::phone_key`.
//
// ## One view, two paths
//
// A touch device is forced to split physical input: some presses a terminal needs RAW (⌃C must be 0x03,
// not the letter c), and some are the visible half of a composition that has not finished yet (a Pinyin
// candidate is three keystrokes before it is one character). `PhoneKey.route` is that split, and the split
// is between PATHS, not between views — `pressesBegan` runs it before deciding whether to call `super`. A
// press routed to the proxy is one this view never touches, so UIKit's text system composes it and commits
// through `insertText`; a press routed to the encoder never reaches that system at all. Two first
// responders would have been the alternative, and it is the worse one: the order between them is UIKit's
// rather than ours, which is how a half-composed candidate ends up on the wire.
//
// ## A third path, above both: a MODE
//
// While Copy Mode or Hint Mode is armed the pane ANSWERS keys instead of forwarding them, and that
// question is asked before the two-path split rather than inside it. It has to be: copy mode's vocabulary
// is mostly bare letters, and a bare letter is exactly what `PhoneKey.route` hands to the proxy.
// `TerminalViewModel.takeModalKey` is the seam, and the abstract keys it feeds are the SAME ones the Mac's
// `keyDown` builds — the phone brings its own key identity and nothing else.
//
// ## A FOURTH path, above the mode: a workspace OVERLAY
//
// A mode belongs to a PANE. The ⌃⇥ pane switcher belongs to the WORKSPACE — it is drawn over every pane at
// once and its state is `WorkspaceStore.paneSwitcher`, not any model's — so it is asked one rung higher,
// off the store, and it is asked FIRST. That order is the Mac's: over there `consumePaneSwitcher` runs in
// the app-level `NSEvent` monitor, which preempts the surface's `keyDown` where copy mode lives, so an Esc
// under both an open walk and an armed copy mode peels the walk. The phone has no monitor — this responder
// is the whole chain — so the same precedence is spelled here, exactly as the mode's own chord precedence
// is.
//
// It is a SECOND predicate rather than a wider `takesModalKeys`, and deliberately: that flag is a property
// of one pane's terminal model, and answering "does a workspace overlay own the keyboard" through it would
// mean handing every `TerminalViewModel` a store it has no other use for. It is also not the first member
// of a general "which overlay holds the keys" rung, because on this device it is the only member there
// could be: every other summoned surface either IS a system presentation (the cheat sheet, Connect, the
// close confirmation, Settings) or mounts a pre-focused field that takes first responder away from this
// view (the palette, Open Quickly, Peek & Reply, Global Search). The switcher is the one card drawn
// in-window that takes no keyboard focus — which is what made it the one card whose keys reached the shell
// behind it.
//
// ## What is NOT here yet
//
// `UITextInput` — marked text and the floating cursor. iOS shows CJK candidates in the keyboard's own bar
// and commits through `insertText`, so typing Chinese works without it; what it costs is INLINE
// composition display and space-bar-drag cursor movement. `PhoneKey`'s `FloatingCursor` is the prepared
// half of the second, and stays caller-less until that conformance lands.

/// The pane's first responder: hardware presses, software-keyboard commits, and the accessory row.
///
/// ⚠️ THE NAME IS LOAD-BEARING. `SlopDeskWorkspaceCore.PaneFocusCoordinator`,
/// `SlopDeskWorkspaceCore.TerminalViewModel` and `SlopDeskClientCore.PhoneRootKeyRung` all name this type
/// as the producer of the phone's key path.
final class TerminalInputHostView: UIView, UIKeyInput {
    /// The pane's session. Weak — the leaf owns the mount, the store owns the session, and a responder
    /// that outlived its detach must go inert rather than write to a dead pane.
    private weak var live: LivePaneSession?
    /// The workspace, read for the ⌃⇥ walk. Weak for the same reason `live` is: the app root owns the
    /// store for the process's life, and a responder that outlived its detach must go inert rather than
    /// keep driving a workspace nothing is showing.
    private weak var store: WorkspaceStore?
    private weak var focusCoordinator: PaneFocusCoordinator?
    private var paneID: PaneID?

    /// The accessory row's ⌃, which ARMS rather than toggles: the next commit folds to its control byte
    /// and the arming clears. A phone has no way to hold a modifier down while tapping a letter, so the
    /// modifier has to outlive the tap that set it and nothing else.
    private var controlArmed = false {
        didSet { accessoryBar?.setControlArmed(controlArmed) }
    }

    /// UIKit fires `pressesBegan`/`pressesEnded` exactly ONCE per physical key — there is no auto-repeat
    /// the way `keyDown` has one on macOS — so holding an arrow does nothing past the first event unless
    /// the embedder re-emits it. This is that re-emission.
    ///
    /// Latched by ``PhoneKey/Held``, whose identity is the PHYSICAL key rather than the press: the release
    /// UIKit delivers carries its own sample of the modifier flags, so a ⌃ lifted before the letter would
    /// otherwise leave the repeat running forever.
    private lazy var repeater = KeyRepeater<PhoneKey.Held>(
        scheduler: DispatchRepeatScheduler(),
        onFire: { [weak self] held in
            // The scheduler fires on its own queue; every write below is main-actor state.
            Task { @MainActor [weak self] in self?.send(held.press) }
        },
    )

    private var accessoryBar: TerminalAccessoryBar?

    // MARK: Mounting

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false // the renderer beside this owns every touch
        backgroundColor = .clear
        // The row's producer. `willChangeFrame` rather than `willShow`: a hardware keyboard paired
        // mid-session never "shows", it changes the frame from hundreds of points to a shortcut bar's few
        // — and that transition is exactly the one that must take the row away again.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardFrameChanged(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
        )
    }

    @objc
    private func keyboardFrameChanged(_ note: Notification) {
        let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        // An end frame parked below the screen is a keyboard on its way OUT, which is no keyboard at all —
        // its height is still hundreds of points at that moment, so the height alone would keep the row up
        // through the dismissal.
        guard let end, let screen = window?.screen, end.minY < screen.bounds.maxY else {
            reconcileAccessoryBar(keyboardHeight: 0)
            return
        }
        reconcileAccessoryBar(keyboardHeight: Double(end.height))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    /// Points this responder at `session`, registering with the coordinator under its pane. Idempotent —
    /// the leaf calls it on every mount and every live-session swap, and a re-register under the same id
    /// is what re-claims first responder after a rebuild.
    func attach(
        to session: LivePaneSession, store: WorkspaceStore, focusCoordinator: PaneFocusCoordinator,
    ) {
        let changed = live !== session || paneID != session.id
        live = session
        self.store = store
        self.focusCoordinator = focusCoordinator
        guard changed else { return }
        if let previous = paneID, previous != session.id { focusCoordinator.unregister(previous) }
        paneID = session.id
        focusCoordinator.register(self, for: session.id)
    }

    /// Drops every registration and stops any key still repeating. Called from the leaf's teardown, which
    /// can happen mid-hold if the pane closes under a held key.
    func detach() {
        repeater.stop()
        if let paneID { focusCoordinator?.unregister(paneID) }
        focusCoordinator?.unregister(host: self)
        paneID = nil
        live = nil
        store = nil
        resignFirstResponder()
    }

    override var canBecomeFirstResponder: Bool { true }

    // MARK: Physical keys

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key, !handle(Self.read(key)) else { continue }
            unhandled.insert(press)
        }
        // Everything this view did not take goes on down the chain, which is what lets UIKit's own text
        // system compose the presses `PhoneKey` routed to it.
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            repeater.keyUp(PhoneKey.Held(Self.read(key)))
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        repeater.stop()
        super.pressesCancelled(presses, with: event)
    }

    /// One `UIKey` as the rules' vocabulary — `PhoneKey.Press.init(_:)`, which the chord recorder reads
    /// its presses with too, so there is one answer to "which key is this".
    private static func read(_ key: UIKey) -> PhoneKey.Press { PhoneKey.Press(key) }

    // MARK: The four editing chords

    /// ⌘C / ⌘X / ⌘V / ⌘A over the terminal.
    ///
    /// The Mac gets these for free: its terminal view IS the window's first responder, so AppKit's
    /// standard `copy:`/`cut:`/`paste:`/`selectAll:` selectors land on the surface that owns the
    /// selection. Here the pane's first responder is THIS view — zero-sized, holding no surface — and the
    /// renderer that owns the selection is a sibling, absent from the chain. So the four chords reached
    /// nothing at all: they are not workspace chords (the table deliberately leaves C/X/V/A alone), and a
    /// ⌘ combination encodes to no bytes, so each one fell out of `handle(_:)` and died. The long-press
    /// menu could copy and paste; a keyboard could not.
    ///
    /// Declared as KEY COMMANDS rather than as the standard editing selectors because a command is
    /// unconditional — it does not depend on this process having built a menu — and because a command
    /// carries the TITLE, so the ⌘-hold discoverability HUD names these four out of the same
    /// ``TerminalContextMenu/Item`` vocabulary the menu draws. `wantsPriorityOverSystemBehavior` because
    /// this view is a `UIKeyInput` and the system would otherwise read ⌘A as select-all over a text input
    /// that holds no text.
    ///
    /// A chord the BINDING TABLE claims is not offered. Nothing binds C/X/V/A by default, but a user
    /// override may, and the workspace's own table must win the way it does on macOS — where the app-level
    /// monitor resolves before the surface's responder ever runs.
    ///
    /// Offered only while the SINK IS BOUND, and that guard is the load-bearing half. A key command is
    /// registered with the system and SWALLOWS its chord; one whose action reaches a nil closure is
    /// strictly worse than never having declared it, because ⌘C stops falling through to whatever would
    /// otherwise have had it and starts doing nothing instead — a dead chord that looks alive. The
    /// renderer binds `onRequestMenuItem` when it attaches, so asking here means the four chords exist
    /// exactly while something can run them.
    override var keyCommands: [UIKeyCommand]? {
        guard live?.terminalModel?.onRequestMenuItem != nil else { return nil }
        return Self.editingChords.compactMap { input, item in
            guard !Self.isWorkspaceBound(input) else { return nil }
            let command = UIKeyCommand(
                title: item.title, action: #selector(runEditingChord(_:)),
                input: input, modifierFlags: .command,
                propertyList: item.rawValue,
            )
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    /// The four, in the Edit-menu order every platform draws them in.
    private static let editingChords: [(String, TerminalContextMenu.Item)] = [
        ("x", .cut), ("c", .copy), ("v", .paste), ("a", .selectAll),
    ]

    /// Whether the workspace's own table claims this ⌘-chord — the SAME override-aware table the pane's
    /// interceptor and the Mac's dispatcher resolve against.
    private static func isWorkspaceBound(_ input: String) -> Bool {
        guard let character = input.first else { return false }
        let chord = KeyChord(character: character, [.command])
        return WorkspaceBindingRegistry.resolvedChordTable[chord] != nil
    }

    /// Hand the resolved item to the renderer, which already runs every one of them for its long-press
    /// menu — paste-protection pre-check, cut's editable-prompt policy and all. This side names the verb
    /// and nothing else; a second implementation of paste is exactly what the seam exists to prevent.
    @objc
    private func runEditingChord(_ sender: UIKeyCommand) {
        guard let raw = sender.propertyList as? String,
              let item = TerminalContextMenu.Item(rawValue: raw),
              let model = live?.terminalModel
        else { return }
        model.onRequestMenuItem?(item)
    }

    /// Takes the press, or reports that the chain should have it. `true` means handled — spent on the ⌃⇥
    /// walk, answered by an armed mode, swallowed as a workspace chord, or handed to the repeater, which
    /// writes it.
    ///
    /// The bytes are asked for TWICE on a press that is taken: once here, discarded, to learn whether the
    /// press writes anything at all, and once inside the repeater's immediate fire. That is one table
    /// lookup per human keystroke, and it buys the property that matters — a press that sends nothing
    /// never starts a 20 Hz repeat of nothing.
    @discardableResult
    private func handle(_ press: PhoneKey.Press) -> Bool {
        // The ⌃⇥ walk owns the keyboard above every pane, so it is asked before the pane's own mode and
        // long before the encoder (see "A FOURTH path" above). Nothing else on this device gets a rung
        // here — every other overlay is answered by UIKit's own responder chain.
        if takesPaneSwitcherKey(press) { return true }
        // A pane in Copy Mode or Hint Mode reads every press as a COMMAND, and this branch has to come
        // ABOVE THE TWO-PATH SPLIT: copy mode's vocabulary is mostly bare letters (`j`, `y`, `v`), and a
        // bare letter is exactly what `routesToKeyEncoding` hands to the proxy. Asked in the other order
        // the phone drew the VI pill and the hint card — this leaf mounts both — over a dispatch with no
        // caller, and every key went to the shell instead.
        //
        // Through the REPEATER, not straight to the model, so a held `j` walks the scrollback the way it
        // does on macOS, where `keyDown` repeats for free.
        if live?.terminalModel?.takesModalKeys == true, !press.command {
            // A bound workspace chord still wins while a mode is up. On macOS the app-level
            // `WorkspaceKeyDispatcher` monitor runs BEFORE the surface's `keyDown`, so ⌃⇧Space leaves vi
            // mode from outside the mode's own dispatch; the phone has no monitor — this responder is the
            // whole chain — so the same precedence is spelled here. Only a press that already bypasses the
            // text proxy is offered: a bare letter is the mode's vocabulary, never a chord.
            if PhoneKey.routesToKeyEncoding(press), swallowsAsWorkspaceChord(press) { return true }
            repeater.keyDown(PhoneKey.Held(press))
            return true
        }
        guard PhoneKey.routesToKeyEncoding(press) else { return false }
        if swallowsAsWorkspaceChord(press) { return true }
        // UNDO AT PROMPT, below the binding table and above the encoder — the same rung the Mac gives it,
        // where the app-level monitor has already had the chord and libghostty has not yet seen it. Not
        // through the repeater: an undo that fired twenty times a second on a held ⌘Z would roll the line
        // back past what the reader can see, which is the argument `swallowsAsWorkspaceChord(_:)` makes
        // for a held ⌘D.
        if takesPromptUndo(press) { return true }
        guard encodedBytes(press) != nil else { return false }
        repeater.keyDown(PhoneKey.Held(press))
        return true
    }

    /// ⌘Z at an editable shell prompt, which is the ONE ⌘ combination that is terminal input rather than
    /// an app shortcut.
    ///
    /// `controls.undoAtPrompt` is drawn, written and persisted on this device, and until this branch
    /// existed nothing on it read the key: `PhoneKey.encode` answers `nil` to every ⌘ press by design, so
    /// ⌘Z fell out of `handle(_:)` and died while the Mac emitted the readline undo byte.
    ///
    /// The rule is `slopdesk_terminal::surface::prompt_edit_byte` through ``PromptEditPolicy`` — the SAME
    /// function the libghostty surface's `keyDown` calls, including the byte itself and why redo is
    /// recognised and deliberately unanswered. What is this side's is only the mapping of a `UIKey` to
    /// that call, which is what an `NSEvent` needs its own of over there.
    ///
    /// The prompt zone is read LIVE off the model's public OSC-133 truth, identically to the Mac:
    /// connected AND idle AND not on the alternate screen, so ⌘Z passes through to a full-screen program
    /// that keeps its own undo. ⌃ and ⌥ are refused because those are other line-edit chords, and the key
    /// is read off `charactersIgnoringModifiers` so the chord is layout-aware.
    private func takesPromptUndo(_ press: PhoneKey.Press) -> Bool {
        guard SettingsKey.undoAtPromptEnabled,
              press.command, !press.control, !press.option,
              let model = live?.terminalModel
        else { return false }
        let base = press.charactersIgnoringModifiers.lowercased()
        let isUndo = base == "z" && !press.shift
        let isRedo = (base == "z" && press.shift) || base == "y"
        guard isUndo || isRedo else { return false }
        let inPromptZone = model.connectionStatus.isLive
            && model.shellActivity == .idle
            && !model.isAlternateScreen
        guard let bytes = PromptEditPolicy.bytes(forUndo: isUndo, redo: isRedo, inPromptZone: inPromptZone)
        else { return false }
        live?.sendBytes(bytes)
        return true
    }

    /// The ⌃⇥ switcher's key handling — the phone's twin of the Mac's
    /// `WorkspaceKeyDispatcher.consumePaneSwitcher`, over a `PhoneKey.Press` instead of an `NSEvent`.
    /// `true` means the press was consumed and must never reach the PTY.
    ///
    /// Both halves of the answer live below the view layer — ``PhoneKey/paneSwitcherKey(_:isOpen:)`` reads
    /// the press and ``WorkspaceStore/takePaneSwitcherKey(_:)`` spends it — so the macOS runner can drive
    /// the whole thing and this stays what every other branch here is: a call and a verdict.
    ///
    /// NOT through the repeater, which is the one decision that is genuinely this file's. An unarmed walk
    /// ends on Return or a tap rather than on a modifier release, so a held ⌃⇥ stepping twenty times a
    /// second would race the card past the row the reader is reading — the same argument
    /// ``swallowsAsWorkspaceChord(_:)`` makes for a held ⌘D. A phone steps with the card's own plates.
    private func takesPaneSwitcherKey(_ press: PhoneKey.Press) -> Bool {
        store?.takePaneSwitcherKey(press) ?? false
    }

    /// Whether the workspace's binding table claims this press. The SAME user-overridable table the Mac's
    /// dispatcher resolves against, so a rebind made once fires on both. A bound chord is swallowed — it
    /// never reaches the PTY, and it does not repeat: a split that fired twenty times a second is not what
    /// holding ⌘D means.
    ///
    /// A `text:`/`csi:`/`esc:` LITERAL-BYTE binding is answered first, exactly as the Mac's dispatcher
    /// answers it before the action table. It had no answer here at all: the config file is shared between
    /// the two shells, so `keybind = cmd+shift+h=text:hello` typed on a Mac and typed on the phone were
    /// one line producing two behaviours — bytes there, silence here. The payload arrives with its ESC/CSI
    /// lead bytes already baked in by `KeybindGrammar`; this side resolves nothing and writes what it is
    /// given.
    ///
    /// It is answered on the PANE's rung and not the root one, and that is the same line the root rung's
    /// own header draws: literal bytes are terminal INPUT, so they belong to the pane holding the keyboard
    /// rather than to a rung that runs when no pane does.
    private func swallowsAsWorkspaceChord(_ press: PhoneKey.Press) -> Bool {
        guard let chord = PhoneKey.keyChord(for: press) else { return false }
        if let binding = WorkspaceBindingRegistry.textBinding(for: chord) {
            live?.sendBytes(binding.payload)
            return true
        }
        guard let interceptor = live?.terminalModel?.keyInterceptor,
              case .swallow = interceptor.intercept(chord)
        else { return false }
        return true
    }

    /// This press's bytes under the LIVE cursor-key mode, read per press off the model the far-side
    /// program is driving. A remembered copy would be one parse behind the screen the user is looking at,
    /// which is how arrows go dead in vim.
    private func encodedBytes(_ press: PhoneKey.Press) -> [UInt8]? {
        guard let live else { return nil }
        return PhoneKey.encode(
            press,
            applicationCursorKeys: live.terminalModel?.isCursorKeysApplication ?? false,
        )
    }

    /// Writes one press to the pane, or hands it to the armed mode. A press that sends nothing is a no-op
    /// — a ⌘ combination that matched no binding is a shortcut that missed, not terminal input.
    ///
    /// The mode is asked per FIRE rather than once at key-down, because a mode can END inside one: copy
    /// mode's `y` yanks and exits, and every repeat after it has to find the mode gone. It then falls
    /// through to the encoder, which is what the Mac does too — a bare letter encodes to nothing, so the
    /// tail of a held yank writes nothing to the PTY.
    private func send(_ press: PhoneKey.Press) {
        guard let live else { return }
        if live.terminalModel?.takeModalKey(press) == true { return }
        guard let bytes = encodedBytes(press) else { return }
        live.sendBytes(bytes)
    }

    // MARK: The software keyboard's commits

    var hasText: Bool { true }

    /// A commit from the software keyboard — a tapped letter, or the string an input method settled on
    /// after however many keystrokes it needed.
    func insertText(_ text: String) {
        guard let live else { return }
        // A pane in Copy Mode or Hint Mode reads a SOFT-keyboard commit as commands too. Without this the
        // modes would work only for the minority of phones with a keyboard attached: the on-screen
        // keyboard commits through here, never through `pressesBegan`, so a tapped `j` went to the shell
        // while the pill said VI. The accessory row's armed ⌃ rides along on the FIRST character exactly
        // as it does below, which is what makes ⌃d half-page with no hardware keyboard at all.
        if let model = live.terminalModel, model.takesModalKeys {
            let armed = controlArmed
            controlArmed = false
            for (index, character) in text.enumerated() {
                model.takeModalKey(PhoneKey.Press(
                    charactersIgnoringModifiers: String(character),
                    control: armed && index == 0,
                ))
            }
            return
        }
        // An ARMED ⌃ folds the commit's first scalar to its control byte, which must go RAW because a PTY
        // never echoes one; the rest is ordinary text on the recorded path so the input bar can dedupe the
        // echo.
        if let folded = PhoneKey.foldArmedControl(text, armed: controlArmed) {
            controlArmed = false
            live.sendBytes([folded.controlByte])
            if !folded.rest.isEmpty { live.sendText(folded.rest) }
            return
        }
        live.sendText(text)
    }

    /// Backspace from the software keyboard. DEL, not BS — that is what a terminal's line editor reads as
    /// "erase the character behind the cursor".
    func deleteBackward() {
        send(PhoneKey.Press(hidUsage: PhoneKeyUsage.backspace))
    }

    // MARK: The accessory row

    override var inputAccessoryView: UIView? {
        guard let bar = accessoryBar else { return nil }
        return bar
    }

    /// Installs or removes the row for a keyboard of `height` points. Driven by the keyboard-frame
    /// notification rather than by a guess: `PhoneKey.showsAccessoryBar` is what separates a software
    /// keyboard — which has no ⌃, Esc or arrows and needs the row — from a hardware one, whose user
    /// already has all four.
    func reconcileAccessoryBar(keyboardHeight: Double) {
        let wanted = PhoneKey.showsAccessoryBar(keyboardHeight: keyboardHeight)
        guard wanted != (accessoryBar != nil) else { return }
        if wanted {
            let bar = TerminalAccessoryBar { [weak self] plate in self?.tap(plate) }
            bar.setControlArmed(controlArmed)
            accessoryBar = bar
        } else {
            accessoryBar = nil
            controlArmed = false
        }
        reloadInputViews()
    }

    /// One accessory plate. ⌃ arms; every other plate is a synthesized press through the same encoder a
    /// hardware key takes, so the bar cannot drift from the keyboard.
    private func tap(_ plate: TerminalAccessoryBar.Plate) {
        switch plate {
        case .control:
            controlArmed.toggle()
        case .dismiss:
            resignFirstResponder()
        case let .key(usage):
            handle(PhoneKey.Press(hidUsage: usage))
        }
    }
}

// MARK: - The focus seam

extension TerminalInputHostView: PaneFocusCoordinator.FocusableInputHost {
    @discardableResult
    func resignFocus() -> Bool { resignFirstResponder() }

    @discardableResult
    func becomeFocus() -> Bool { becomeFirstResponder() }
}

// MARK: - The usages the bar synthesizes

/// The HID keyboard usages this file names, read off `UIKeyboardHIDUsage` so there is no second table
/// anywhere — the responder reports the same numbers for a real key, and `slopdesk_workspace::phone_key`
/// is the only thing that says what each one MEANS.
enum PhoneKeyUsage {
    static let escape = UInt16(UIKeyboardHIDUsage.keyboardEscape.rawValue)
    static let tab = UInt16(UIKeyboardHIDUsage.keyboardTab.rawValue)
    static let backspace = UInt16(UIKeyboardHIDUsage.keyboardDeleteOrBackspace.rawValue)
    static let left = UInt16(UIKeyboardHIDUsage.keyboardLeftArrow.rawValue)
    static let right = UInt16(UIKeyboardHIDUsage.keyboardRightArrow.rawValue)
    static let up = UInt16(UIKeyboardHIDUsage.keyboardUpArrow.rawValue)
    static let down = UInt16(UIKeyboardHIDUsage.keyboardDownArrow.rawValue)
}

// MARK: - The row itself

/// The ⌃ / Esc / Tab / arrows row above the software keyboard.
///
/// Every plate but ⌃ and the dismiss chevron is a KEY, and each one goes through the same
/// `PhoneKey.encode` a hardware press takes — the bar has no byte table of its own, so it cannot send an
/// arrow the hardware path would have sent differently.
final class TerminalAccessoryBar: UIInputView {
    /// What a plate does when tapped.
    enum Plate: Equatable {
        /// Arm ⌃ for the next commit.
        case control
        /// Send a key.
        case key(UInt16)
        /// Put the keyboard away.
        case dismiss
    }

    private let onTap: (Plate) -> Void
    private var controlButton: UIButton?

    init(onTap: @escaping (Plate) -> Void) {
        self.onTap = onTap
        super.init(
            frame: CGRect(x: 0, y: 0, width: 0, height: Slate.Metric.plate + Slate.Metric.space2 * 2),
            inputViewStyle: .keyboard,
        )
        buildPlates()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    /// Lights ⌃ while it is armed. The arming has to be VISIBLE — a modifier that outlives the tap that
    /// set it and shows nothing is a keystroke the user cannot predict.
    func setControlArmed(_ armed: Bool) {
        controlButton?.backgroundColor = armed ? Slate.Native.accent : Slate.Native.Surface.raised
        controlButton?.tintColor = armed ? Slate.Native.Surface.face : Slate.Native.Text.primary
        controlButton?.setTitleColor(armed ? Slate.Native.Surface.face : Slate.Native.Text.primary, for: .normal)
    }

    private func buildPlates() {
        let plates: [(String, Plate)] = [
            ("⌃", .control),
            ("esc", .key(PhoneKeyUsage.escape)),
            ("⇥", .key(PhoneKeyUsage.tab)),
            ("←", .key(PhoneKeyUsage.left)),
            ("↓", .key(PhoneKeyUsage.down)),
            ("↑", .key(PhoneKeyUsage.up)),
            ("→", .key(PhoneKeyUsage.right)),
        ]
        let row = UIStackView(arrangedSubviews: plates.map { button(title: $0.0, plate: $0.1) })
        row.axis = .horizontal
        row.spacing = Slate.Metric.space1
        row.distribution = .fillEqually

        let dismiss = button(title: "⌄", plate: .dismiss)
        let outer = UIStackView(arrangedSubviews: [row, dismiss])
        outer.axis = .horizontal
        outer.spacing = Slate.Metric.space2
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space2),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space2),
            outer.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space2),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Slate.Metric.space2),
            dismiss.widthAnchor.constraint(equalToConstant: Slate.Metric.plate),
        ])
    }

    private func button(title: String, plate: Plate) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = SlateNativeFont.monospacedSystemFont(ofSize: 15, weight: .medium)
        button.setTitleColor(Slate.Native.Text.primary, for: .normal)
        button.backgroundColor = Slate.Native.Surface.raised
        button.layer.cornerRadius = Slate.Metric.radiusSmall
        button.addAction(UIAction { [weak self] _ in self?.onTap(plate) }, for: .touchUpInside)
        if plate == .control { controlButton = button }
        return button
    }
}
#endif
