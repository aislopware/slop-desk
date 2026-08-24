// MacTerminalLeafView — the terminal pane leaf's content, in AppKit (docs/56 wave R, batch R9).
//
// The Mac half of ``TerminalLeafView``. Like its SwiftUI twin it is minimal by design: the terminal
// surface seam (``TerminalRendererFactory/makeNative(model:isFocused:)``, else the headless
// ``MacBuildStatusPlaceholderView``), four decoration overlays coincident with it, one top-trailing
// chip column and one bottom hint bar. No cwd chrome, no per-pane status strip, no mounted command
// row — text delivery routes through `InputBarModel` headlessly on both platforms.
//
// WHAT IS LEFT HERE IS THE DRAWING AND THE TRIGGER, and that split is not this file's invention: it
// is ``TerminalPaneWiring``'s (`SlopDeskClientCore`, stage F batch P1). The five callback pairs, the
// dial, the autotype seam, the secure-input reconcile and the chip `×` all live there precisely so
// the retain-cycle discipline, the teardown ORDER and the `EnableSecureEventInput` reference balance
// are written ONCE rather than hand-translated into a second language. The SwiftUI half keeps
// `.task` / `.onChange` / `.onDisappear`; this half keeps `withObservationTracking` and the AppKit
// lifecycle, and neither keeps a decision.
//
// ## The seam takes the NSView, not an `AnyView`
//
// ``TerminalRendererFactory/nativeShared`` hands back the layer-hosting `NSView` itself (docs/56
// risk 2, landed increment 57d). The alternative — an `NSHostingView` around the SwiftUI
// `make(model:isFocused:)` — would put a full-bleed hosting layer over the ONE surface in this app
// that must take every keystroke, which is exactly the hit-claim stage D spent five increments
// removing. Nothing here names `GhosttyLayerBackedView`; a headless `swift build` registers no native
// factory at all and gets the placeholder.
//
// ## RISK 3 — occlusion is not visibility, and the tracking areas are the reason
//
// The full argument is on ``setOccluded(_:)`` and on ``MacLeafOcclusion``. In one paragraph: a hidden
// tab's leaf is faded with `alphaValue`, never `isHidden`, because a layer-hosting view sizes its
// `IOSurfaceLayer` frame and `contentsScale` in `layout()` and `layout()` does not run on a hidden
// subtree — so an un-hide after a display change would present stale geometry. But `alphaValue = 0`
// plus `hitTest → nil` only settles CLICKS. `NSTrackingArea`s are rect-based: they keep firing under
// anything composited above them, so a background tab's terminal would go on feeding pointer
// positions to a mouse-reporting TUI while the user works in the foreground tab. So the tracking
// areas' LIFECYCLE follows the leaf's occlusion rather than its visibility, and that is what
// ``MacLeafOcclusion`` is.
//
// ## Three iOS arms this port did NOT read
//
// The SwiftUI twin mounts `TerminalInputHost` (the phone's only key responder — a Metal layer answers
// no key event, so without it an iPad cannot type) and wraps the pixels in
// `TerminalLetterboxContainer` (a phone is size-passive host-side, so it letterboxes a grid it did
// not choose and prints `120×40 · sized by MacBook Pro`). Both are whole-file iOS and stay with
// `SlopDeskPhoneUI`. On the Mac the window IS a grid contributor, so the surface fills the pane and a
// letterbox would frame a pane that is already right; and the renderer is the first responder, so
// there is nothing for an input host to hold. A `#if` here would be dead text reading as a live rule
// (docs/56 §3), which is why this file has none.
//
// ## The Command Navigator card (⌃⌘O)
//
// It IS here now, and the ⚠️ this paragraph used to carry was right about the shape of the hole:
// ``TerminalPaneWiring`` has always toggled ``CommandNavigatorChrome/isVisible`` for this pane — that
// is what `onRequestBlockNavigator` is bound to — but the Mac had nothing that READ the flag, so
// `view.commandNavigator` was taken away from the PTY to flip a `Bool` nobody drew. The reader is
// ``MacCommandNavigatorView`` (`Pane/MacCommandNavigator.swift`), mounted by ``applyNavigator(_:)``
// below off the same ``follow()`` arm every other piece of chrome rides. `CommandNavigatorView` is
// filed `Platform::Both` at `binding_rows.rs:131`, so the AppKit card JOINS the phone's SwiftUI one
// rather than replacing it (docs/56 §3.5 step 4) — the decisions underneath (the list, the ranking,
// the clamp, the jump, the words, the two measurements) are shared, and only the drawing is twice.

import AppKit
import Foundation
import SlopDeskClientCore // TerminalPaneWiring / TerminalLeafPolicy / PaneStatusPillPresentation
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskVideoProtocol // ConfigRevision — the config-file edge the tracked read arms on
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel // PaneID — the two task keys

// MARK: - The leaf

/// One terminal pane's content: the pixels, the decorations over them, and the chrome beside them.
///
/// Built once per pane and kept — the mounter is expected to key it by ``PaneID`` exactly as the
/// SwiftUI half's `.id(PaneID)` does, so the surface and the connection are never reused across panes
/// (the identity hazard the SwiftUI header names).
@MainActor
final class MacTerminalLeafView: NSView {
    // MARK: What the leaf was handed

    /// The live workspace store — the dial gate, the per-tab sync-input arming, and what the wiring's
    /// host-path actions resolve a project key against.
    private let store: WorkspaceStore
    /// The scene's overlay coordinator, for the ⇧⌘F escalation and the host-action failure toast.
    /// `nil` outside the app scene (tests) ⇒ the failure is swallowed, never a crash.
    private let overlay: OverlayCoordinator?
    /// The shared chrome model, used ONLY to reveal the right code panel when an open-in-code-panel
    /// action lands. `nil` ⇒ the file still opens host-side, the panel just is not auto-revealed.
    private let chrome: WorkspaceChromeState?

    /// This pane's wiring — the find bar, the Secure Keyboard Entry actuator and the Command
    /// Navigator chrome, plus every callback they are driven by. The SwiftUI half holds the same
    /// object as `@State`; an AppKit canvas holds it as a stored property. Neither owns a decision in
    /// it.
    private let wiring: TerminalPaneWiring

    /// The pane's session handle, or `nil` for a not-yet-live / non-terminal pane. Settable because a
    /// session ARRIVES under a stable pane id — the SwiftUI half sees that as `live?.id` moving off
    /// `nil` and re-runs its wiring `.onChange`; this half sees it as ``setLive(_:)``.
    private var live: LivePaneSession?
    /// The host-reported working directory (`pane/cwd`, live-set from OSC 7), mirrored onto the model
    /// so the renderer's ⌘-hover hit-test can resolve a RELATIVE detected path to its absolute form.
    private var cwd: String?
    /// The pane's WORKSPACE focus. Drives the renderer's first responder — only the focused pane
    /// types — and never render-liveness, so an unfocused split sibling keeps repainting.
    private var isFocused: Bool

    // MARK: The tree

    /// The padded interior. The SwiftUI half spends `.padding(Slate.Metric.space2)` on the surface so
    /// terminal content is not flush against the pane edges / split divider; EVEN on all four sides
    /// since the command ladder was removed and the gutter carries nothing. The inset shrinks the
    /// libghostty surface, so the host PTY grid loses ~1 col/row each side and reflows through the
    /// existing size → resize-scrim → `TIOCSWINSZ` path. No new signal.
    private let surfaceArea = NSView()

    /// The pixels: the production renderer's own view, or the headless placeholder. Held as `NSView`
    /// because that is all this file may know about it.
    private var surfaceView: NSView?
    /// The renderer behind ``surfaceView``, when there is one. `nil` for the placeholder and for a
    /// pane with no model yet.
    private var surfaceHost: TerminalSurfaceHosting?

    /// The four DECORATION overlays, coincident with the surface (origin 0,0 = surface top-left) and
    /// each inert until its own gate opens. They are decorations and never a content branch — the
    /// libghostty-freeze guardrail — so all four answer `hitTest` with `nil` except hint mode, which
    /// is deliberately opaque while it is armed.
    private var decorations: [NSView] = []

    /// The top-trailing column: the vi-mode pill, then the status chips, then the find bar, stacked
    /// top→down so an open find bar reflows BELOW the persistent pills instead of overlapping them.
    private let chipColumn = NSStackView()
    /// The bottom slot, holding the vi key-hint bar when `⌘/` has toggled it on during a vi session.
    /// A one-tenant stack rather than a bare child so the reveal helper is the same code as the
    /// column's.
    private let hintSlot = NSStackView()

    /// What is mounted in the column right now, keyed by slot so a re-render moves nothing that has
    /// not changed. The ORDER is ``desiredSlots(_:)``'s, which is
    /// ``PaneStatusPillPresentation/visible(_:)``'s — never re-derived here.
    private var mounted: [MacLeafChipSlot: NSView] = [:]
    /// The vi key-hint bar, when it is up. Separate from ``mounted`` because it lives in the bottom
    /// slot rather than the column.
    private var hintBar: MacViKeyHintBar?

    /// The Command Navigator card (⌃⌘O), while it is up. Not a chip and not a decoration: it is a
    /// MODAL card over this one pane, so it covers the whole surface area — the column and the hint
    /// slot included — rather than taking a slot beside them.
    private var navigator: MacCommandNavigatorView?

    // MARK: The live reads

    /// The observation generation. `withObservationTracking` has no cancel, so an arm that has been
    /// superseded — by a live-session swap, by a settings flip, by a re-attach — must DROP its
    /// callback rather than re-arm from it. Without this the arms DOUBLE on every swap and quadruple
    /// on the next, which reads as the pane getting slower the longer it is open and has no crash to
    /// find it by.
    private var generation = 0
    /// `controls.auto-secure-input`, as last ACTED on. Kept because the lock is reconciled on the
    /// EDGE, not on the reading: a config edit to an unrelated key re-runs ``follow()`` and must not
    /// re-engage a process-global lock the user turned off.
    private var autoSecureInput = SettingsKey.autoSecureInputEnabled
    /// `controls.secure-input-indicator` — the chip gate. No edge to speak of; re-reading the pill
    /// conditions is the whole of applying it.
    private var secureInputIndicator = SettingsKey.secureInputIndicatorEnabled

    /// The two `.task(id:)` keys, as last acted on. A task fires when its key MOVES, which is the
    /// whole of ``TerminalLeafPolicy``'s argument: a key that is already the pane's id while the gate
    /// is shut is a task that ran once, too early, and never again.
    private var dialKey: PaneID?
    private var autotypeKey: PaneID?
    private var dialTask: Task<Void, Never>?
    private var autotypeTask: Task<Void, Never>?

    /// Whether the wiring is installed. The wiring is idempotent, but re-installing it on every
    /// window change would also re-arm the observation for no reason.
    private var isWired = false

    // MARK: Occlusion (docs/56 risk 3)

    /// Whether this leaf is behind another tab. See ``setOccluded(_:)`` — it is NOT `isHidden`, and
    /// it is not only about drawing.
    private var occluded = false
    /// Whether a subtree tracking sweep is already queued for the end of this runloop turn.
    private var sweepQueued = false

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
        wantsLayer = true

        surfaceArea.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surfaceArea)

        // The column and the slot are TRANSPARENT trays: every tenant delineates itself, so the
        // containers only place and space them.
        chipColumn.orientation = .vertical
        chipColumn.alignment = .trailing
        chipColumn.spacing = Slate.Metric.space2
        chipColumn.translatesAutoresizingMaskIntoConstraints = false
        hintSlot.orientation = .vertical
        hintSlot.alignment = .centerX
        hintSlot.spacing = Slate.Metric.space2
        hintSlot.translatesAutoresizingMaskIntoConstraints = false
        surfaceArea.addSubview(chipColumn)
        surfaceArea.addSubview(hintSlot)

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
        ])
        paint()
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        paint()
    }

    /// The pane's paper. `effectiveAppearance` has to be the CURRENT one while a dynamic colour
    /// resolves, or the rung answers for whatever appearance happened to be drawing last.
    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.Surface.terminal.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// The hint bar is measured rather than constrained: it picks a column rung from the width it is
    /// PROPOSED, which is the AppKit stand-in for the `ProposedViewSize` its SwiftUI twin is handed.
    /// The proposal is the surface area minus this file's own two insets.
    override func layout() {
        super.layout()
        hintBar?.availableWidth = surfaceArea.bounds.width - 2 * Slate.Metric.space2
        sweepIfOccluded()
    }

    // MARK: - Attach / detach, and the one thing that is not symmetric

    /// The AppKit spelling of `.onAppear` / `.onDisappear`, with ONE deliberate asymmetry.
    ///
    /// The WIRING detaches automatically when the leaf leaves the view tree, because the thing it
    /// holds that must never leak is process-global: an engaged `EnableSecureEventInput` outliving
    /// its pane holds the keyboard for every other app on the machine, with nothing on screen to say
    /// so. It is idempotent and re-installable, so re-attaching costs nothing.
    ///
    /// The SURFACE does not. ``TerminalSurfaceHosting/detachSurface()`` drops libghostty's renderer
    /// and io threads, which is not re-installable and would take the session with it — and a leaf
    /// can leave the tree without its pane going away (a split rearrange re-parents it). So the
    /// surface is dropped only by ``teardown()``, which the mounter calls when the pane is closed for
    /// good.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
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
        // The card is a MODAL over this pane and the leaf is leaving the tree: it goes with it, and
        // the shield it raised goes with it too. The chrome flag is left alone — it is the wiring's,
        // and a re-attach re-reads it, so a pane re-parented by a split rearrange comes back with
        // its navigator still open.
        dropNavigator()
        wiring.clear(live: live)
    }

    /// The pane is closed for good: drop the wiring AND the libghostty surface. See
    /// ``viewDidMoveToWindow()`` for why the second half is not automatic.
    func teardown() {
        detach()
        surfaceHost?.detachSurface()
        surfaceHost = nil
        surfaceView?.removeFromSuperview()
        surfaceView = nil
        for decoration in decorations { decoration.removeFromSuperview() }
        decorations = []
    }

    // MARK: - What the mounter pushes

    /// A session arrived, or was swapped under a stable pane id. Re-wires and rebuilds the pixels if
    /// the model changed, which is the AppKit reading of the SwiftUI half's
    /// `.onChange(of: live?.id, initial: true)`.
    func setLive(_ live: LivePaneSession?) {
        guard live !== self.live else { return }
        let hadModel = self.live?.terminalModel
        if isWired { wiring.clear(live: self.live) }
        self.live = live
        if live?.terminalModel !== hadModel {
            surfaceHost?.detachSurface()
            mountSurface()
            // The card holds the OLD model — its block store, its bookmarks — so it cannot be left
            // standing over a pane whose session was swapped underneath it. Dropped rather than
            // re-pointed: ``follow()`` below rebuilds it against the new model if the chrome flag is
            // still set, which is one path instead of two.
            dropNavigator()
        }
        if isWired {
            wiring.wire(
                live: live, store: store, overlay: overlay, chrome: chrome,
                autoSecureInput: autoSecureInput,
            )
            applyCwd()
            follow()
        }
    }

    /// The pane's workspace focus moved. `updateNSView` is what SwiftUI would have re-run for this;
    /// an AppKit canvas has none, so the push is explicit (the seam says so at
    /// ``TerminalRendererFactory/makeNative(model:isFocused:)``).
    func setFocused(_ isFocused: Bool) {
        guard isFocused != self.isFocused else { return }
        self.isFocused = isFocused
        surfaceHost?.setPaneFocused(isFocused)
    }

    /// The host reported a new cwd (OSC 7). It changes independently of the session id, which is why
    /// the SwiftUI half gives it its own `onChange` rather than folding it into the wiring's.
    func setCwd(_ cwd: String?) {
        guard cwd != self.cwd else { return }
        self.cwd = cwd
        applyCwd()
        // The link overlay resolves relative paths against this, and it reads the model rather than
        // a copy — so nothing else has to be pushed.
    }

    private func applyCwd() {
        live?.terminalModel?.linkCwd = cwd
    }

    // MARK: - Occlusion (docs/56 risk 3)

    /// This leaf is behind another tab, or is back in front.
    ///
    /// THREE THINGS MOVE, AND ONLY THE FIRST IS ABOUT DRAWING.
    ///
    /// 1. `alphaValue`, NEVER `isHidden`. The terminal surface is a LAYER-HOSTING view: libghostty
    ///    installs its own `IOSurfaceLayer` in the `layer` slot and sizes that layer's frame and
    ///    `contentsScale` in `layout()`. AppKit does not run `layout()` on a hidden subtree, so a
    ///    window dragged to a display with a different backing scale while this tab was hidden would
    ///    un-hide onto stale geometry — the surface presenting at the old scale, in the old rect,
    ///    until something else dirtied it. Faded, the leaf keeps laying out and there is nothing to
    ///    catch up on.
    ///
    /// 2. `hitTest`. A faded leaf still occupies its rect, so without this a click meant for the
    ///    front tab could resolve into the back one.
    ///
    /// 3. THE TRACKING AREAS, which is the half that `.allowsHitTesting(false)` gave the SwiftUI leaf
    ///    for free and AppKit does not give at all. SwiftUI suppresses hits for a whole COMPOSED
    ///    subtree; an `NSTrackingArea` is a RECT plus an owner, and AppKit matches the pointer against
    ///    it with no reference to what is composited above, what `hitTest` answers, or what the
    ///    view's alpha is. A background tab's terminal therefore keeps taking `mouseMoved` and
    ///    forwarding cursor positions to libghostty — which presents as a mouse-reporting TUI in the
    ///    BACKGROUND tab tracking the pointer the user is moving in the FOREGROUND one, and as
    ///    focus-follows-mouse handing the workspace to a pane nobody can see. It is the same failure
    ///    ``TerminalPointerShield`` already answers for a modal card floating over the workspace;
    ///    that one is a process-wide flag and cannot say WHICH pane is covered, so occlusion needs
    ///    its own answer. ``MacLeafOcclusion`` is it: the area's LIFECYCLE follows the occlusion, so
    ///    while this leaf is behind another tab its subtree owns no tracking areas at all.
    func setOccluded(_ occluded: Bool) {
        guard occluded != self.occluded else { return }
        self.occluded = occluded
        alphaValue = occluded ? 0 : 1
        if occluded {
            MacLeafOcclusion.suspendTracking(under: self)
        } else {
            MacLeafOcclusion.resumeTracking(under: self)
        }
    }

    /// Whether this leaf is currently behind another tab.
    var isOccluded: Bool { occluded }

    /// Transparent to the pointer while occluded — see ``setOccluded(_:)``, point 2.
    override func hitTest(_ point: NSPoint) -> NSView? {
        occluded ? nil : super.hitTest(point)
    }

    /// The re-arm hook, and the reason a single sweep on the occlusion edge is not enough.
    ///
    /// `updateTrackingAreas()` is the ONE place a well-behaved AppKit view installs its areas, and
    /// AppKit drives that pass over the window's views whenever geometry moves — so a background
    /// tab's terminal, which is still laying out (point 1 above), will re-install what the edge
    /// sweep removed. Sweeping again from here answers the leaf's own pass; ``sweepIfOccluded()``
    /// answers a DESCENDANT's, by coalescing one more sweep to the end of the current runloop turn.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        sweepIfOccluded()
    }

    /// Queue a subtree sweep for the end of this runloop turn, at most one per turn.
    ///
    /// The end of the turn is early enough because AppKit dispatches `mouseEntered` / `mouseExited` /
    /// `mouseMoved` from the EVENT LOOP and never from inside a tracking-areas update pass: a block
    /// enqueued on the main queue during this turn runs before the next event is dequeued. So an area
    /// a descendant re-installed at any point in the pass is gone again before it can fire once.
    private func sweepIfOccluded() {
        guard occluded, !sweepQueued else { return }
        sweepQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sweepQueued = false
                guard self.occluded else { return }
                MacLeafOcclusion.suspendTracking(under: self)
            }
        }
    }

    // MARK: - The pixels

    /// The terminal surface seam — the production renderer if the app registered a native factory,
    /// else the headless placeholder. This target NEVER imports libghostty or Metal: it only calls
    /// the factory.
    ///
    /// The decorations are rebuilt with it because every one of them is constructed AROUND a model.
    private func mountSurface() {
        surfaceView?.removeFromSuperview()
        surfaceView = nil
        surfaceHost = nil
        for decoration in decorations { decoration.removeFromSuperview() }
        decorations = []
        hintBar = nil

        guard let model = live?.terminalModel else { return }

        let pixels: NSView
        if let host = TerminalRendererFactory.makeNative(model: model, isFocused: isFocused) {
            surfaceHost = host
            pixels = host.surfaceView
        } else {
            pixels = MacBuildStatusPlaceholderView(model: model)
        }
        surfaceView = pixels
        fill(pixels, below: chipColumn)

        // The four decorations, in the SwiftUI half's z-order. Each is coincident with the surface —
        // the surface area IS the surface's rect here, since a Mac pane is never letterboxed — so the
        // cell metrics (origin 0,0 = surface top-left) map straight onto them.
        for decoration in [
            MacLinkHighlightOverlay(model: model, cwd: cwd) as NSView,
            MacPromptJumpFlashOverlay(model: model),
            MacViCursorOverlay(model: model),
            MacHintModeOverlay(model: model),
        ] {
            decorations.append(decoration)
            fill(decoration, below: chipColumn)
        }
    }

    /// Pin `view` to the surface area's four edges, under `sibling` so the chrome stays on top.
    private func fill(_ view: NSView, below sibling: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        surfaceArea.addSubview(view, positioned: .below, relativeTo: sibling)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: surfaceArea.topAnchor),
            view.bottomAnchor.constraint(equalTo: surfaceArea.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: surfaceArea.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: surfaceArea.trailingAnchor),
        ])
    }

    /// ``fill(_:below:)``'s other side: pin `view` to the same four edges but ABOVE everything, which
    /// is what a card over the pane needs and a decoration must never have. `relativeTo: nil` with
    /// `.above` is AppKit's spelling of "topmost", so the card covers the chip column and the hint
    /// slot too — a modal over a pane that left its own chrome clickable is not modal.
    private func cover(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        surfaceArea.addSubview(view, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: surfaceArea.topAnchor),
            view.bottomAnchor.constraint(equalTo: surfaceArea.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: surfaceArea.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: surfaceArea.trailingAnchor),
        ])
    }

    // MARK: - The live read

    /// ONE tracked read of everything this leaf draws or triggers on, re-armed by its own `onChange`.
    ///
    /// It is one arm rather than one per concern deliberately. `withObservationTracking` fires on the
    /// FIRST change to anything it read, so N arms cost N callbacks for one edit and give nothing
    /// back — every read below is a property access on an object this leaf already holds.
    ///
    /// The generation check is the file's other observation rule: this method is called from the
    /// callback AND from ``attach()`` and ``setLive(_:)``, and an arm cannot be cancelled. A superseded arm must therefore drop its callback instead of re-arming from it.
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
            // The config-file edge. `AppConfig` is a plain locked global, so the two settings below
            // are not observable on their own — the REVISION is, and reading it here is what makes
            // a saved config file reconcile every open pane. See ``ConfigRevision``.
            _ = ConfigRevision.shared.generation
            auto = SettingsKey.autoSecureInputEnabled
            secureInputIndicator = SettingsKey.secureInputIndicatorEnabled
            conditions = pillConditions()
            hintsToggled = live?.terminalModel?.showViKeyHints ?? false
            findVisible = wiring.findBar.visible && live?.terminalModel != nil
            // ⌃⌘O toggles the chrome flag through `onRequestBlockNavigator`; THIS read is what makes
            // the chord actuate. Gated on a live model for the find bar's reason — the card's whole
            // data source is that model's block store, and a pane with no session has none.
            navigatorVisible = wiring.navigatorChrome.isVisible && live?.terminalModel != nil
            dial = TerminalLeafPolicy.dialTaskKey(pane: live?.id, mayDial: store.panesMayDial)
            autotype = TerminalLeafPolicy.autotypeTaskKey(
                pane: live?.id,
                isTarget: live?.isAutotypeTarget ?? false,
                status: live?.connection?.status,
            )
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation else { return }
                    self.follow()
                }
            }
        }

        // The lock is reconciled only on the AUTO edge: the wiring re-syncs on a pane swap, so
        // without this an engaged process-global lock would linger past the user turning
        // `controls.auto-secure-input` off. Inline rather than a callback, because this method IS the
        // observation callback — a hop back through it would recurse.
        if auto != autoSecureInput {
            autoSecureInput = auto
            wiring.reconcileSecureInput(live: live, autoSecureInput: auto)
            conditions = pillConditions()
        }
        applyChrome(conditions: conditions, hintsToggled: hintsToggled, findVisible: findVisible)
        applyNavigator(navigatorVisible)
        applyTriggers(dial: dial, autotype: autotype)
    }

    /// Everything the pill gates read, taken once per pass.
    ///
    /// Every field is an OBSERVABLE mirror — never the `@ObservationIgnored` `isReadOnly` /
    /// `isCopyMode` the renderer's keyDown path reads — so reading them HERE is what makes the chips
    /// light and clear reactively. A not-yet-live pane reads as all-false, which shows no chip.
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
    /// ``PaneStatusPillPresentation/visible(_:)``, so this half asks the same question its SwiftUI
    /// twin does rather than re-deriving "read-only hides under vi, secure input hides under
    /// read-only, sync input hides under nothing" from the same prose and being right by luck.
    private func desiredSlots(
        _ conditions: PaneStatusConditions, findVisible: Bool,
    ) -> [MacLeafChipSlot] {
        var slots: [MacLeafChipSlot] = []
        if PaneStatusPillPresentation.showsViModePill(conditions), live?.terminalModel != nil {
            slots.append(.viMode)
        }
        slots.append(contentsOf: PaneStatusPillPresentation.visible(conditions).map { .pill($0) })
        if findVisible { slots.append(.find) }
        return slots
    }

    private func applyColumn(_ desired: [MacLeafChipSlot]) {
        for (slot, view) in mounted where !desired.contains(slot) {
            mounted[slot] = nil
            MacLeafChipReveal.dismiss(view, towards: .top)
        }
        for slot in desired where mounted[slot] == nil {
            guard let view = makeChip(slot) else { continue }
            mounted[slot] = view
            // The insertion point is measured against what is STILL in the stack, which includes
            // anything currently animating out. Counting only the kept predecessors would put a new
            // chip above a leaving one and make the column jump.
            let index = desired.prefix(while: { $0 != slot })
                .compactMap { mounted[$0] }
                .compactMap { chipColumn.arrangedSubviews.firstIndex(of: $0) }
                .max()
                .map { $0 + 1 } ?? 0
            MacLeafChipReveal.present(view, in: chipColumn, at: index, from: .top)
        }
    }

    private func makeChip(_ slot: MacLeafChipSlot) -> NSView? {
        switch slot {
        case .viMode:
            guard let model = live?.terminalModel else { return nil }
            // `exitCopyMode()` is the SINGLE exit seam — it also resets the count, the visual mode
            // and the hint bar, so the `×`, `Esc`/`q` and a programmatic dismiss converge on one
            // state rather than on three nearly-identical teardowns.
            return MacViModePill(model: model, onExit: { [weak model] in model?.exitCopyMode() })
        case let .pill(pill):
            return MacPaneStatusPillView(pill: pill, onDismiss: { [weak self] in
                guard let self else { return }
                TerminalPaneWiring.dismiss(pill, live: live, store: store)
            })
        case .find:
            return MacTerminalFindBar(model: wiring.findBar)
        }
    }

    /// The vi key-hint bar along the pane BOTTOM. The gate is `copyModeBadgeActive`-first, so the
    /// card tears down the instant vi mode exits (which also resets `showViKeyHints`).
    private func applyHintBar(_ wanted: Bool) {
        if wanted, hintBar == nil {
            let bar = MacViKeyHintBar()
            bar.availableWidth = surfaceArea.bounds.width - 2 * Slate.Metric.space2
            hintBar = bar
            MacLeafChipReveal.present(bar, in: hintSlot, at: 0, from: .bottom)
        } else if !wanted, let bar = hintBar {
            hintBar = nil
            MacLeafChipReveal.dismiss(bar, towards: .bottom)
        }
    }

    // MARK: - The Command Navigator card (⌃⌘O)

    /// Mounts or drops the navigator, which is the whole of what makes the chord actuate.
    ///
    /// It is NOT a chip: it covers the surface area rather than joining the column, it fades straight
    /// in rather than travelling from an edge (the phone's `.transition(.opacity)`), and it raises
    /// the pane-card pointer shield while it is up. That last part is the correctness half — an
    /// `NSTrackingArea` is rect-based, so a mouse-reporting TUI under the card would go on receiving
    /// pointer positions through it. ``MacLeafOcclusion``'s subtree sweep is the wrong tool here: it
    /// would also strip the card's OWN rows of the tracking areas their hover selection runs on.
    private func applyNavigator(_ wanted: Bool) {
        if wanted, navigator == nil {
            guard let model = live?.terminalModel else { return }
            let card = MacCommandNavigatorView(model: model, store: store) { [weak self] in
                self?.wiring.navigatorChrome.isVisible = false
            }
            navigator = card
            cover(card)
            MacPaneCardShield.raise()
            card.reveal()
        } else if !wanted, let card = navigator {
            // Forgotten FIRST, retired second — exactly the column's rule: a card still fading out
            // must not be found by the next open, or ⌃⌘O pressed twice quickly would re-show the
            // one on its way off screen instead of building a fresh one.
            navigator = nil
            MacPaneCardShield.lower()
            card.retire()
            // The card held the keyboard; the pane has to be given it back explicitly, or the pane
            // the chord was fired from is left unable to type. The store's reclaim is the same seam
            // every other summoned surface closes through.
            store.reclaimKeyboardFocusInActivePane()
        }
    }

    /// Takes the card down NOW — no fade — and balances the shield.
    ///
    /// Un-animated because its callers are the torn-down paths (``detach()`` and ``teardown()``),
    /// where there is nothing left to animate over. A shield left raised by a card removed during
    /// teardown would leave the terminal permanently pointer-deaf, which is why the removal and the
    /// balance are one function rather than two statements anyone could separate.
    private func dropNavigator() {
        guard let card = navigator else { return }
        navigator = nil
        card.removeFromSuperview()
        MacPaneCardShield.lower()
    }

    // MARK: - The two triggers

    /// The AppKit reading of two `.task(id:)`s: a task runs when its key MOVES, and a key that went
    /// to `nil` cancels rather than starts.
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

// MARK: - What can stand in the column

/// One tenant of the pane's top-trailing column, as an identity.
///
/// It exists so the column can be DIFFED rather than rebuilt: a chip that is still wanted keeps the
/// view it already has, which is what keeps a `MacTerminalFindBar` from losing its field editor (and
/// with it the insertion point and any in-flight IME composition) every time an unrelated chip
/// appears beside it.
private enum MacLeafChipSlot: Hashable {
    case viMode
    case pill(PaneStatusPill)
    case find
}

// MARK: - The reveal

/// Which edge a chip travels from, and back to.
private enum MacLeafChipEdge {
    case top
    case bottom
}

/// The column's arrival and departure motion.
///
/// The SwiftUI half spends `.transition(.move(edge:).combined(with: .opacity))` under
/// `.animation(Slate.Anim.reveal, value:)`. Three things make up that transition and AppKit spells
/// them in two places: the FADE and the stack's own REFLOW are `NSAnimationContext` over the
/// animator proxy (`isHidden` on an arranged subview is what makes the neighbours slide), and the
/// TRAVEL is a `CABasicAnimation` on the layer's translation, which composes on top of whatever
/// Auto Layout resolved instead of fighting it — the same trap the titlebar band's two halves hit
/// (docs/56 increment "the band's marks cross").
@MainActor
private enum MacLeafChipReveal {
    static func present(_ view: NSView, in stack: NSStackView, at index: Int, from edge: MacLeafChipEdge) {
        view.wantsLayer = true
        view.alphaValue = 0
        view.isHidden = true
        stack.insertArrangedSubview(view, at: min(index, stack.arrangedSubviews.count))
        // `fittingSize`, not `frame`: the view is hidden, so the stack has given it no height yet,
        // and a travel of zero is no travel at all.
        travel(view, by: offset(view.fittingSize.height, edge: edge), reversed: true)
        animate {
            view.animator().isHidden = false
            view.animator().alphaValue = 1
        }
    }

    static func dismiss(_ view: NSView, towards edge: MacLeafChipEdge) {
        travel(view, by: offset(view.frame.height, edge: edge), reversed: false)
        animate({
            view.animator().alphaValue = 0
            view.animator().isHidden = true
        }, thenRemoving: view)
    }

    /// How far, and in which direction. AppKit's default coordinate space is y-UP, so a chip that
    /// arrives "from the top" starts at a POSITIVE offset and one that arrives from the bottom at a
    /// negative one. The gap is included so the chip clears the neighbour it is sliding past.
    private static func offset(_ height: CGFloat, edge: MacLeafChipEdge) -> CGFloat {
        let distance = height + Slate.Metric.space2
        switch edge {
        case .top: return distance
        case .bottom: return -distance
        }
    }

    private static func travel(_ view: NSView, by distance: CGFloat, reversed: Bool) {
        let curve = Slate.Motion.reveal
        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.fromValue = reversed ? distance : 0
        slide.toValue = reversed ? 0 : distance
        slide.duration = curve.duration
        slide.timingFunction = curve.timingFunction
        view.layer?.add(slide, forKey: "chipTravel")
    }

    /// The reveal curve around one mutation, optionally retiring a view when it settles.
    ///
    /// A VIEW TO REMOVE, NOT A CLOSURE TO RUN, and the distinction is forced rather than stylistic.
    /// `runAnimationGroup`'s completion handler is `@Sendable` while everything here is main-actor, so
    /// a plain `(() -> Void)?` cannot cross into it — the compiler is right that nothing in the closure's
    /// TYPE promises which thread runs it, even though AppKit always calls it on the main one and simply
    /// never annotated that. An `NSView` crosses freely because `@MainActor` classes are implicitly
    /// `Sendable`; all their access is isolated already. So the parameter names the only completion any
    /// caller in this target has ever wanted, which is also the shape `MacPaneMoveAffordance`,
    /// `MacSimulatorSurface` and `MacSimulatorStageView` all reached independently.
    private static func animate(
        _ body: @escaping () -> Void, thenRemoving retiring: NSView? = nil,
    ) {
        let curve = Slate.Motion.reveal
        NSAnimationContext.runAnimationGroup { context in
            context.duration = curve.duration
            context.timingFunction = curve.timingFunction
            context.allowsImplicitAnimation = true
            body()
        } completionHandler: {
            // The handler is `@Sendable` and `removeFromSuperview` is main-actor isolated, which the
            // compiler is right to flag: nothing in the handler's TYPE promises which thread runs it.
            // AppKit always runs it on the main one and simply never annotated that, so the assertion
            // is the honest spelling — and it traps rather than corrupting a view tree if that ever
            // stops being true.
            MainActor.assumeIsolated { retiring?.removeFromSuperview() }
        }
    }
}

// MARK: - The occlusion sweep (docs/56 risk 3)

/// Suspending and resuming an occluded subtree's `NSTrackingArea`s.
///
/// ## Why this is a subtree walk and not a property
///
/// AppKit has no "disable" for a tracking area. It has an install (`addTrackingArea`), a remove, and
/// ONE documented place a view is expected to (re)install from — `updateTrackingAreas()`, which
/// AppKit itself calls whenever the window's geometry moves. So "the area exists while the leaf is
/// visible and does not while it is occluded" is expressible only as: remove them all, and let the
/// owners rebuild from the hook they already use.
///
/// It is a WALK because the areas that matter are not the leaf's. The one that produces the reported
/// symptom belongs to the terminal renderer — a view in `ThirdParty/` that neither UI target may name
/// — and the others belong to the hover plates on the chips (``MacPaneStatusPillCloseView`` and the
/// hint-mode badge's `×` say so in their own headers). None of them can be asked to consult a flag
/// this file owns without every future pane part having to remember to, and *a trap that survives
/// only if every future caller remembers it has not been answered* (docs/56, increment 57d). Removing
/// the areas needs no cooperation at all: it is the same operation whoever installed them would have
/// performed, and `updateTrackingAreas()` is their own re-entry point.
///
/// ## Why the areas do not simply come back
///
/// They do, and that is expected — the whole point of the hook is that AppKit re-drives it. The
/// occluded leaf answers by sweeping again, both from its own `updateTrackingAreas()` and from one
/// sweep coalesced to the end of the runloop turn (see
/// ``MacTerminalLeafView/setOccluded(_:)`` and its `sweepIfOccluded`). What makes that sufficient
/// rather than a race is a fact about AppKit's event dispatch: tracking events are delivered from the
/// EVENT LOOP, never from inside a tracking-areas update pass, so an area installed at any point in
/// the pass is removed again before the next event is dequeued.
///
/// ## What this is NOT
///
/// It is not `isHidden`. A hidden subtree stops laying out, and the terminal surface sizes its
/// `IOSurfaceLayer` in `layout()` — see ``MacTerminalLeafView/setOccluded(_:)``. It is also not
/// ``TerminalPointerShield``, which answers the same class of failure for a MODAL card and is
/// process-wide by construction: it cannot say which pane is covered, and a background tab is a
/// per-pane fact.
@MainActor
enum MacLeafOcclusion {
    /// Remove every tracking area in `root`'s subtree, `root` included. Returns how many were
    /// removed, which is what makes the sweep observable from a test without a window.
    @discardableResult
    static func suspendTracking(under root: NSView) -> Int {
        var removed = 0
        for area in root.trackingAreas {
            root.removeTrackingArea(area)
            removed += 1
        }
        for subview in root.subviews {
            removed += suspendTracking(under: subview)
        }
        return removed
    }

    /// Ask every view in `root`'s subtree to rebuild its tracking areas — the documented re-entry
    /// point, and the only one that works for a view this target may not name.
    static func resumeTracking(under root: NSView) {
        root.updateTrackingAreas()
        for subview in root.subviews {
            resumeTracking(under: subview)
        }
    }
}
