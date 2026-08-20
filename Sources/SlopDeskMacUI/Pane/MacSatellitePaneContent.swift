// MacSatellitePaneContent — what a satellite window SHOWS, in AppKit (docs/56 wave R, batch R11, third
// of three files). It closes the last `NSHostingView` in the pane tree.
//
// A DETACHED pane lives outside every tab's split tree but keeps its spec and its live registry
// handle. The WINDOWS that carry it are `SatellitePaneWindows.swift`; what is here is the CONTENT they
// mount — the SAME ``MacPaneContainer`` a split slot mounts, so the terminal ring-replays into a fresh
// surface and a video pane re-hellos while the PTY / host session never dies.
//
// THE SEAM IS GONE, not re-implemented. `SatellitePaneHost.contentView` existed because the window
// target sat above `SlopDeskClientUI` and so could not name a SwiftUI view; it handed back a mounted
// `NSView` instead. The content is an `NSView` outright now, the window target already owns this file,
// and the environment injection that made the seam awkward (a hosting root inherits NOTHING from the
// main scene) has nothing left to inject — the overlay coordinator crosses as a plain init parameter.
//
// ALWAYS ON-SCREEN. A satellite has no tab to hide behind, and miniaturising keeps it streaming (v1),
// so `isVisible` is `true` for the pane's whole life here. Focus follows the WINDOW's key state.

import AppKit
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

// MARK: - The window's content

/// The satellite window's root: the pane, edge to edge, with a hover-revealed grab strip on top.
@MainActor
final class MacSatellitePaneRootView: NSView {
    private let store: WorkspaceStore
    private let paneID: PaneID
    private let keyState: SatelliteWindowKeyState

    private let pane: MacPaneContainer
    private var strip: MacSatelliteDragStrip?
    private var generation = 0

    init(
        store: WorkspaceStore,
        paneID: PaneID,
        keyState: SatelliteWindowKeyState,
        paneDrag: PaneDragCoordinator?,
        overlay: OverlayCoordinator?,
        chrome: WorkspaceChromeState?,
    ) {
        self.store = store
        self.paneID = paneID
        self.keyState = keyState
        pane = MacPaneContainer(
            store: store, paneID: paneID, isFocused: keyState.isKey, isVisible: true,
            overlay: overlay, chrome: chrome,
        )
        super.init(frame: .zero)
        wantsLayer = true
        paint()

        addSubview(pane)
        NSLayoutConstraint.activate([
            pane.topAnchor.constraint(equalTo: topAnchor),
            pane.bottomAnchor.constraint(equalTo: bottomAnchor),
            pane.leadingAnchor.constraint(equalTo: leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // A `.desktop` satellite has NO merge-back affordance — the desktop never joins a tab
        // (docs/DECISIONS.md 2026-07-22), so the grab strip would be a dead gesture.
        if let paneDrag, store.tree.spec(for: paneID)?.kind != .desktop {
            let made = MacSatelliteDragStrip(store: store, paneID: paneID, coordinator: paneDrag)
            made.translatesAutoresizingMaskIntoConstraints = false
            addSubview(made)
            NSLayoutConstraint.activate([
                made.topAnchor.constraint(equalTo: topAnchor),
                made.centerXAnchor.constraint(equalTo: centerXAnchor),
            ])
            strip = made
        }
        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Top-left origin, matching the canvas and everything under it. A satellite is one pane at the
    /// window's full size, so nothing here depends on it — it is stated so a reader moving between the
    /// two mounts never has to check which convention this one is in.
    override var isFlipped: Bool { true }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() { paint() }

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.Surface.terminal.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// The window's key state IS this pane's focus. Tracked rather than pushed because the window sets
    /// it on its own notifications, and this view has no other reason to hear from the window.
    private func follow() {
        generation &+= 1
        let generation = generation
        var isKey = false
        withObservationTracking {
            isKey = keyState.isKey
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation else { return }
                    self.follow()
                }
            }
        }
        pane.setFocused(isKey)
    }

    /// The window is closing for good.
    func teardown() {
        generation &+= 1
        pane.teardown()
    }
}

// MARK: - The merge-back affordance

/// The satellite's top grab strip: the same hover-revealed `-` pill the canvas handle draws, but the
/// drag tracks the GLOBAL mouse (`NSEvent.mouseLocation`) — the destinations live in OTHER windows, so
/// a local coordinate is meaningless out here.
///
/// Release commits ONE store op, in the reattach family: beside a canvas target, docked at the canvas
/// edge, beside a sidebar row's pane, or into a fresh tab. `.tearOff` and `.none` fall through
/// ``PaneDragCommit`` untouched, which is the honest answer here — the pane already IS its own window,
/// so releasing anywhere else keeps it one. Every path keeps the `PaneID`, so the live PTY / video
/// session survives and only the view remounts.
///
/// THE PILL'S RUNGS ARE ``Slate/GrabPill``'s, the same ones ``MacPaneMoveHandle`` reads, and that
/// sharing is the pair `PaneGrabPillArt` was minted for: the drag that starts on THIS pill ends on one
/// of those, so a user merging a satellite back into the canvas sees both inside a single gesture. A
/// pill that changed size on the way across would read as the thing they are holding changing shape.
@MainActor
final class MacSatelliteDragStrip: NSView {
    private let store: WorkspaceStore
    private let paneID: PaneID
    private let coordinator: PaneDragCoordinator

    private let plate = MacGrabPillCapsule(curve: .continuous)
    private let bar = MacGrabPillCapsule(curve: .continuous)

    private var hovering = false
    private var dragging = false
    private var tracking: NSTrackingArea?

    /// ``PaneGrabPill/isRevealed(input:hovering:isDragging:)``'s — the same rule the canvas handles on
    /// both halves read, for the reason ``Slate/GrabPill`` owns the shape: one affordance, three
    /// drawings, and no compiler that can see two of them at once.
    private var revealed: Bool {
        PaneGrabPill.isRevealed(input: .pointer, hovering: hovering, isDragging: dragging)
    }

    init(store: WorkspaceStore, paneID: PaneID, coordinator: PaneDragCoordinator) {
        self.store = store
        self.paneID = paneID
        self.coordinator = coordinator
        super.init(frame: .zero)
        for pill in [plate, bar] {
            pill.translatesAutoresizingMaskIntoConstraints = true
            pill.alphaValue = 0
            addSubview(pill)
        }
        // The same contrast plate the canvas handle draws under an unthemed pane: a satellite usually
        // hosts a video stream, and the bare tertiary pill disappears over a light desktop.
        plate.fill = Slate.Native.Surface.face
        plate.rim = Slate.Native.Line.subtle
        plate.castsChipShadow = true
        plate.isHidden = store.tree.spec(for: paneID)?.kind != .desktop
        bar.fill = Slate.Native.Text.tertiary
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { false }

    /// ⚠️ A transparent view with no background is a window-drag region by default on some paths. This
    /// one owns a drag of its own, and losing it to "move the window" would be silent out here in a way
    /// it is not on the canvas: the satellite would simply slide across the screen instead of merging.
    override var mouseDownCanMoveWindow: Bool { false }

    /// THE CEILING RUNG OUTRIGHT, not the canvas handle's leaf-share clamp. A detached window is wide
    /// enough that the share resolves here for any window worth detaching into, and a strip measured
    /// off the WINDOW would grow with a resize while the pane inside it does not. Named rather than
    /// re-derived, so it cannot fall out of step with the clamp's top.
    override var intrinsicContentSize: NSSize {
        NSSize(width: Slate.GrabPill.stripWidthMax, height: Slate.GrabPill.stripHeight)
    }

    override func layout() {
        super.layout()
        placePill(animated: false)
        updateTrackingAreas()
    }

    private func placePill(animated: Bool) {
        // Hover ONLY: once the drag is live the pill is at rest again, because the thing that moves
        // from then on is the window.
        let scale = hovering && !dragging ? CGFloat(Slate.GrabPill.hoverScale) : 1
        let barFrame = Self.centred(
            width: Slate.GrabPill.barWidth * scale, height: Slate.GrabPill.barHeight * scale,
            in: bounds,
        )
        let plateFrame = Self.centred(
            width: Slate.GrabPill.plateWidth * scale, height: Slate.GrabPill.plateHeight * scale,
            in: bounds,
        )
        let alpha: CGFloat = revealed ? 1 : 0
        // Not animated with the reveal: the ink flips on the grab, which is one frame of a mouse-down
        // no eye is on, and a cross-faded accent there reads as lag rather than as a response.
        bar.fill = dragging ? Slate.Native.accent : Slate.Native.Text.tertiary
        guard animated else {
            bar.frame = barFrame
            bar.alphaValue = alpha
            plate.frame = plateFrame
            plate.alphaValue = alpha
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Slate.Motion.dividerHover.duration
            context.timingFunction = Slate.Motion.dividerHover.timingFunction
            bar.animator().frame = barFrame
            bar.animator().alphaValue = alpha
            plate.animator().frame = plateFrame
            plate.animator().alphaValue = alpha
        }
    }

    private static func centred(width: CGFloat, height: CGFloat, in rect: NSRect) -> NSRect {
        NSRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = nil
        guard window != nil else { return }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(area)
        tracking = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
    }

    override func mouseEntered(with _: NSEvent) {
        hovering = true
        placePill(animated: true)
    }

    override func mouseExited(with _: NSEvent) {
        hovering = false
        placePill(animated: true)
    }

    override func resetCursorRects() {
        // Through ``PanePointer`` like every other piece of pane chrome, never a raw `NSCursor` name:
        // the rule grew a third spelling once already by being written out at the call site.
        addCursorRect(bounds, cursor: MacPaneDivider.cursor(for: dragging ? .grabActive : .grabIdle))
    }

    // MARK: The drag

    /// The slop a press must exceed before it counts as a drag — the AppKit reading of the SwiftUI
    /// half's `DragGesture(minimumDistance: 2)`.
    private static let minimumDragDistance: CGFloat = 2

    private var pressOrigin: NSPoint?

    /// The gesture is tracked in a LOCAL EVENT LOOP rather than through the responder chain, and that
    /// is forced by where the drag goes: it leaves this window almost immediately, and only the
    /// window that began tracking keeps receiving the events after that. A responder-chain
    /// `mouseDragged` would stop firing at the frame edge and strand the coordinator mid-drag.
    override func mouseDown(with _: NSEvent) {
        pressOrigin = NSEvent.mouseLocation
        window?.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking,
        ) { event, stop in
            switch event?.type {
            case .leftMouseDragged: self.dragMoved()
            case .leftMouseUp:
                self.dragReleased()
                stop.pointee = true
            default:
                // A `nil` event is the timeout, which `.infinity` rules out — anything else reaching
                // here is a class this loop did not ask for, and continuing would spin.
                self.dragReleased()
                stop.pointee = true
            }
        }
    }

    private func dragMoved() {
        guard let origin = pressOrigin else { return }
        let now = NSEvent.mouseLocation
        if !dragging {
            let travelled = hypot(now.x - origin.x, now.y - origin.y)
            guard travelled >= Self.minimumDragDistance else { return }
            dragging = true
            placePill(animated: false)
            // The cursor changes with the phase, and the rects are only re-asked on invalidation.
            window?.invalidateCursorRects(for: self)
        }
        // The COORDINATOR resolves where a global point lands — every destination is in another
        // window, so there is nothing this view could decide about it.
        coordinator.updateDetachedDrag(source: paneID)
    }

    private func dragReleased() {
        pressOrigin = nil
        guard dragging else { return }
        dragging = false
        placePill(animated: true)
        window?.invalidateCursorRects(for: self)
        // ONE store op on release, in the reattach family — the SAME four-case decision the canvas
        // commits a spring-loaded landing through, asked once.
        PaneDragCommit.commit(
            coordinator.takeDestination(), pane: paneID, origin: .detached, in: store,
        )
    }
}
