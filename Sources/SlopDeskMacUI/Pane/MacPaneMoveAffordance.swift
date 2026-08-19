// MacPaneMoveAffordance — the pane's GRAB PILL and the drag overlay it lifts, in AppKit (docs/56 wave
// R, batch R8; the AppKit half of `PaneMoveHandle` + `PaneMoveOverlay`).
//
// A short drag handle (a `-` pill) is revealed near the TOP of a pane on hover; you grab it to move the
// pane. The remote-app rule survives the port unchanged: the drag mutates NOTHING in the store — it
// reports a cursor point per frame and ``PaneCanvasDragController`` holds the live `PaneMoveDrag` that
// drives this overlay. Only on release does exactly ONE store op run, so the layout / terminal-grid /
// remote-window redraw fires once rather than per drag frame.
//
// The drop is not just a swap. The cursor's position resolves to a `PaneDropZone` — SWAP the target,
// RE-SPLIT it into a new column/row, or DOCK to a whole container edge — and each zone draws a
// visually distinct preview so the committed action reads before release. Which zone that is, and what
// releasing there commits, is not asked here: it is the controller's, which is the whole reason wave P
// evacuated it before this file was written a second time.
//
// ⚠️ NOT THIS FILE'S, AND EACH FOR A DIFFERENT REASON:
//   • THE DRAG'S DECISIONS. `detachPaneToWindow`, `recordPlacement` and the destination resolution are
//     ``PaneCanvasDragController``'s. This view reports mouse points and draws what it is told; a gate
//     enforces exactly that for the canvas and the same rule applies to its handle.
//   • THE CANCEL KEY. The `NSEvent` monitor is ``PaneMoveEscapeMonitorController``'s (`SlopDeskClientCore`),
//     because a monitor draws nothing. What is left here is the arm/disarm BALANCE, and it is here
//     rather than in the canvas because this view's mouse-down..mouse-up IS the drag's lifetime: a
//     `defer`-shaped pair around one gesture is a balance a reader can check, where a flag set from a
//     mount two files away is one nobody can. A monitor left installed eats Escape for the WHOLE APP
//     with no crash and no log, which is why the counting seams are injected and pinned by a test.
//   • THE PILL'S NUMBERS. Every one is ``Slate/GrabPill``'s. The satellite window's strip draws the
//     SAME pill, and merging a detached pane home means grabbing one pill, crossing the window and
//     releasing on the other — so a 44 that became a 42 does not read as two files disagreeing, it
//     reads as the thing in the user's hand changing size. This port is the third drawing that file
//     was written for.
//   • THE CHIP. The cursor-pinned ghost chip IS ``MacPaneDragChip`` — the very capsule the cross-window
//     `NSPanel` carries, mounted in-tree here. The SwiftUI halves were two drawings of one capsule kept
//     in step by ``Slate/DropChip``'s numbers; in AppKit they can be one object, and both can be on
//     screen inside a single drag, so being the same object is strictly better than agreeing.
//   • THE PREVIEW RECTS. `slabRect` / `seamSize` / `seamCenter` / `railRect` are ``PaneDropGeometry``'s.
//     The resolver that decides WHICH zone a point is in and the arithmetic that turns that answer back
//     into a rectangle are two halves of one round trip; a renderer that re-derived the second half by
//     eye would preview a drop the shared commit does not make.
//
// WHAT THE PORT HAD TO ANSWER FOR ITSELF, because AppKit spells them differently:
//
// 1. HOVER IS A TRACKING AREA, AND A TRACKING AREA IS RECT-BASED. `.onHover` respects SwiftUI's
//    hit-testing; an `NSTrackingArea` respects nothing — it keeps firing under a subtree at
//    `alphaValue = 0` and it keeps firing when `hitTest` returns nil. The canvas keeps EVERY tab
//    mounted (the invariant that keeps a libghostty surface alive across a tab switch) and reveals one,
//    so a hidden tab's pills would light up over the visible tab's panes. That is docs/56 risk 3, and
//    the answer is ``tracksHover(interactive:hidden:hasWindow:)``: the area is torn down and rebuilt on
//    every `updateTrackingAreas`, and it is not installed at all unless the leaf is the interactive
//    tab's. Removing before adding is mandatory rather than tidy — AppKit calls that method on every
//    frame change, and an `addTrackingArea` without the matching remove accumulates one duplicate per
//    resize, each of which fires.
// 2. A REBUILT AREA DOES NOT RE-FIRE `mouseEntered`. AppKit only synthesises entry on the next pointer
//    move, so a strip whose width changed under a stationary cursor would keep a stale reveal —
//    forever, in the "stuck visible" direction. The rebuild re-reads the pointer and syncs.
// 3. THE ESCAPE CANCEL IS STICKY UNTIL THE RELEASE. See ``cancelDrag()``.
//
// The SwiftUI half's `PaneMoveSpace` (a named coordinate space) has no AppKit spelling: a point is
// converted into a VIEW, so the space is ``MacPaneMoveHandle/moveSpace`` — the view the solver's rects
// are measured in. Same fact, named by an object instead of by a string.

import AppKit
import SlopDeskClientCore // the drag's decisions, its vocabulary, and the cancel key's monitor
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskWorkspaceModel

// MARK: - The grab handle

/// The per-leaf top grab handle: fills its leaf, but only a SHORT top strip is hit-testable (the rest
/// passes clicks through to the terminal under it). The strip senses hover to reveal the pill and owns
/// the drag.
///
/// The callbacks take the `PaneID` rather than closing over a leaf, and that is not a style choice. The
/// controller resolves every frame against the layout it is HANDED, precisely so a drag can never run
/// against a staler copy than the one that drew the handle; closures rebound per layout pass would put
/// that copy back, one indirection further away. The mount answers "which leaf, among which leaves, in
/// which container" at call time, from the layout it is holding.
@MainActor
final class MacPaneMoveHandle: NSView {
    /// The pane this handle grabs. Stable for the handle's whole life — the mount reuses a handle
    /// across layout passes and never re-points it, exactly as the SwiftUI `ForEach` keyed on it.
    let paneID: PaneID

    /// Whether THIS leaf's tab is the interactive one — the AppKit spelling of the compositor's
    /// `.allowsHitTesting(isActive)`. It gates the hit test AND the tracking area, because in AppKit
    /// those are two separate promises and only the first has a SwiftUI equivalent (see the header).
    var isInteractive = true {
        didSet {
            guard isInteractive != oldValue else { return }
            updateTrackingAreas()
        }
    }

    /// Whether this leaf renders UNTHEMED content (a `.desktop` video stream). The bare tertiary pill is
    /// tuned to the terminal palette and disappears over an arbitrary — usually light — streamed
    /// desktop, so the pill gains a small `Surface.face` plate (the same chip voice as the rest of the
    /// over-video chrome). Terminal leaves keep the flat pill.
    var contentIsUnthemed = false {
        didSet {
            guard contentIsUnthemed != oldValue else { return }
            placePill(animated: false)
        }
    }

    /// The view the drag reports its points in — the AppKit spelling of `PaneMoveSpace`. It must be the
    /// view the solver's leaf rects are measured in, or a cursor point and a leaf rect describe
    /// different places. `nil` falls back to the superview, which is what the mount does today: the
    /// handles are placed directly in the tab layer, at the leaf rects that same layer was solved for.
    weak var moveSpace: NSView?

    private let onChanged: (PaneID, CGPoint) -> Void
    private let onEnded: (PaneID, CGPoint) -> Void
    private let onTap: (PaneID) -> Void
    private let onInterrupted: (PaneID) -> Void

    /// Escape-to-cancel for the length of ONE drag. Owned per handle rather than shared by the canvas
    /// because only one mouse button can be down at a time — two handles can never be armed at once —
    /// and because the arm and the disarm then sit in the same object as the mouse-down that needs
    /// them. Injected so a test can COUNT the two calls, which is the only way a balance is provably
    /// kept (``PaneMoveEscapeMonitorController``'s own argument, applied to its owner).
    private let escape: PaneMoveEscapeMonitorController

    private let plate = MacGrabPillCapsule(curve: .continuous)
    private let bar = MacGrabPillCapsule(curve: .circular)

    private var hoverArea: NSTrackingArea?
    private var hovering = false
    private var phase = Phase.idle
    private var pressOrigin = CGPoint.zero
    /// Whether the closed-hand cursor is currently PUSHED. The stack is only balanced if every push has
    /// exactly one pop, and a drag has three ends (release, Escape, teardown).
    private var cursorPushed = false

    /// Where the gesture is, and the reason it is a value rather than two Bools: `.cancelled` is a
    /// state neither "dragging" nor "idle" can express — the button is still down and nothing more may
    /// be reported.
    private enum Phase {
        case idle
        /// Pressed, but not yet past the slop — a release from here is a TAP.
        case pressed
        case dragging
        /// Escape was pressed and the button is still down. Absorbs every remaining event of the
        /// gesture; the release commits nothing.
        case cancelled
    }

    /// The slop a press must exceed before it counts as a drag rather than a click — the AppKit
    /// spelling of `DragGesture(minimumDistance: 2)`. Without it the tap that focuses a pane would
    /// publish a one-pixel move on every hand tremor.
    private static let minimumDragDistance: CGFloat = 2

    init(
        paneID: PaneID,
        escape: PaneMoveEscapeMonitorController = PaneMoveEscapeMonitorController(),
        onChanged: @escaping (PaneID, CGPoint) -> Void,
        onEnded: @escaping (PaneID, CGPoint) -> Void,
        onTap: @escaping (PaneID) -> Void,
        onInterrupted: @escaping (PaneID) -> Void,
    ) {
        self.paneID = paneID
        self.escape = escape
        self.onChanged = onChanged
        self.onEnded = onEnded
        self.onTap = onTap
        self.onInterrupted = onInterrupted
        super.init(frame: .zero)
        for pill in [plate, bar] {
            pill.translatesAutoresizingMaskIntoConstraints = true
            pill.alphaValue = 0
            addSubview(pill)
        }
        plate.fill = Slate.Native.Surface.face
        plate.rim = Slate.Native.Line.subtle
        plate.castsChipShadow = true
        plate.isHidden = true
        bar.fill = Slate.Native.Text.tertiary
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Top-left origin, like the solver that placed this handle. `y == 0` IS the leaf's top edge, so the
    /// strip's rect needs no `maxY` arithmetic that a later reader could get backwards.
    override var isFlipped: Bool { true }

    /// The pill is decoration for the pointer and never a stop on the keyboard's tour — the pane it
    /// belongs to is what takes focus, and moving a pane by keyboard is the ⌥⌘⇧arrow chords' job.
    override var acceptsFirstResponder: Bool { false }

    /// ⚠️ A transparent view with no background is a window-drag region by default on some paths. This
    /// one owns a drag of its own, and losing it to "move the window" would be silent: the pill would
    /// simply never lift, and the whole window would slide instead.
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: The hit footprint

    /// The strip — the ONLY hit-testable part of this view, flush to the leaf's top edge and centred.
    ///
    /// Its width is ``Slate/GrabPill/stripWidth(forLeafWidth:)`` of the leaf's own width, which is why
    /// this is derived rather than stored and why ``layout()`` is the right hook: the pill's size is a
    /// function of a width nothing knows until the leaf is placed. The satellite window's strip asks the
    /// same function.
    var stripFrame: NSRect {
        let width = Slate.GrabPill.stripWidth(forLeafWidth: bounds.width)
        return NSRect(
            x: (bounds.width - width) / 2, y: 0, width: width, height: Slate.GrabPill.stripHeight,
        )
    }

    /// Everything below the strip belongs to the terminal underneath. Returning `self` for the whole
    /// leaf would make the pane's top half un-clickable and un-selectable, and nothing would say why.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isInteractive else { return nil }
        // The point arrives in the SUPERVIEW's coordinates; with no superview there is no other space
        // it could already be in (which is also what lets a test ask this without a window).
        let local = superview.map { convert(point, from: $0) } ?? point
        return stripFrame.contains(local) ? self : nil
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        placePill(animated: false)
        // The tracking rect IS the strip, so it is rebuilt where the strip is resolved. Anything else
        // leaves a window in which the pointer reveals a pill it is not over.
        updateTrackingAreas()
    }

    /// Every number here is ``Slate/GrabPill``'s — see the header for whose drawing this has to match.
    ///
    /// The pill is SIZED rather than transformed for its hover growth. A layer transform would have to
    /// fight AppKit for the layer's geometry (it rewrites `position`/`bounds` from the view's frame on
    /// every layout pass), and a frame is the one description of a subview AppKit will not overwrite.
    private func placePill(animated: Bool) {
        let strip = stripFrame
        // Hover ONLY: once the drag is live the pill is at rest again, because the thing that moves
        // from then on is the pane.
        let scale = hovering && !isDragging ? CGFloat(Slate.GrabPill.hoverScale) : 1
        let barFrame = Self.centred(
            width: Slate.GrabPill.barWidth * scale, height: Slate.GrabPill.barHeight * scale, in: strip,
        )
        let plateFrame = Self.centred(
            width: Slate.GrabPill.plateWidth * scale, height: Slate.GrabPill.plateHeight * scale,
            in: strip,
        )
        let alpha: CGFloat = revealed ? 1 : 0
        plate.isHidden = !contentIsUnthemed
        // Not animated with the reveal: the ink flips on the grab, which is one frame of a mouse-down
        // no eye is on, and a cross-faded accent there reads as lag rather than as a response.
        bar.fill = isDragging ? Slate.Native.accent : Slate.Native.Text.tertiary
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
        NSRect(
            x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height,
        )
    }

    // MARK: Hover (the tracking area — see the header, and docs/56 risk 3)

    /// Whether this handle may own a tracking area at all.
    ///
    /// Stated as a predicate rather than as a condition inside ``updateTrackingAreas()`` because it is
    /// the one rule in this file that cannot be checked by looking at the screen: a hidden tab's pill
    /// reveals at `alphaValue = 0`, so the bug is INVISIBLE where it happens and shows up as the
    /// visible tab's pane lighting up a pill the pointer is nowhere near.
    static func tracksHover(interactive: Bool, hidden: Bool, hasWindow: Bool) -> Bool {
        interactive && !hidden && hasWindow
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // REMOVE FIRST, ALWAYS. AppKit calls this on every frame and hierarchy change; an add without
        // the matching remove leaves one live duplicate per resize, and every one of them fires.
        if let hoverArea {
            removeTrackingArea(hoverArea)
            self.hoverArea = nil
        }
        guard Self.tracksHover(
            interactive: isInteractive, hidden: isHiddenOrHasHiddenAncestor, hasWindow: window != nil,
        ) else {
            // A pill left revealed on a tab that is leaving would come back revealed with the pointer
            // somewhere else entirely.
            setHovering(false)
            return
        }
        let area = NSTrackingArea(
            rect: stripFrame,
            // `.activeInActiveApp`, not `.activeInKeyWindow`: a satellite window's pane reveals its
            // pill on hover too, and a reveal is not a focus claim. `.enabledDuringMouseDrag` is
            // deliberately ABSENT — that omission is what stops every other leaf's pill from lighting
            // up as a live drag crosses it, which is the SwiftUI half's `.allowsHitTesting(false)` on
            // the non-source handles.
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp],
            owner: self,
            userInfo: nil,
        )
        addTrackingArea(area)
        hoverArea = area
        // A freshly added area does NOT synthesise `mouseEntered` for a pointer already inside it, so
        // the reveal is re-read from the pointer instead of waiting for a move that may never come.
        setHovering(pointerIsOverStrip())
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { abandonGesture() }
        updateTrackingAreas()
    }

    /// The `will` half rather than the `did`, and only for the removal: `removeFromSuperview()` is the
    /// call the mount makes when a pane closes, and this is the hook it always runs. A leaf whose tab
    /// never had a window would otherwise reach no teardown at all — ``viewDidMoveToWindow()`` cannot
    /// fire for a window that was never there.
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        if newSuperview == nil { abandonGesture() }
    }

    override func mouseEntered(with _: NSEvent) { setHovering(true) }

    override func mouseExited(with _: NSEvent) { setHovering(false) }

    /// ``PanePointer/grabIdle``, in AppKit's spelling: an open hand says "this can be picked up".
    ///
    /// Only the idle half is here, and that is not an omission. `cursorUpdate` is a HOVER callback and
    /// AppKit does not deliver it while a button is down, so ``PanePointer/grabActive`` — the closed
    /// hand — is PUSHED for the length of the drag instead (see ``beginDrag()``), which is also the only
    /// spelling that hands the previous cursor back exactly.
    override func cursorUpdate(with _: NSEvent) {
        NSCursor.openHand.set()
    }

    private func setHovering(_ value: Bool) {
        guard value != hovering else { return }
        hovering = value
        placePill(animated: true)
    }

    /// Whether the pointer really is over the strip right now — read from the window rather than from
    /// an event, because this answers the question no event was delivered for.
    private func pointerIsOverStrip() -> Bool {
        guard let window, window.isVisible, NSApplication.shared.isActive else { return false }
        return stripFrame.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    // MARK: The gesture

    /// `true` for exactly as long as the drag is live — which the SwiftUI half could only learn by
    /// reading the controller's `move.source`, because a `DragGesture`'s liveness is not readable from
    /// the view that owns it. Here the handle IS the only thing that can start this leaf's tree drag,
    /// so the answer is local and no mount can forget to supply it.
    var isDragging: Bool { phase == .dragging }

    override func mouseDown(with event: NSEvent) { press(at: spacePoint(event)) }

    override func mouseDragged(with event: NSEvent) { dragged(to: spacePoint(event)) }

    override func mouseUp(with event: NSEvent) { released(at: spacePoint(event)) }

    // The gesture in POINTS, one step below the three overrides above. The split is
    // ``PaneMoveEscapeMonitorController``'s own: the seam owns the `NSEvent` and hands down only what
    // the decision needs, which is what lets the arm/disarm balance be pinned without an `NSEvent`,
    // a window or a run loop in sight.

    /// The button went down. Nothing is published yet — a press that never travels is a TAP.
    func press(at point: CGPoint) {
        pressOrigin = point
        phase = .pressed
    }

    /// One drag frame. Below the slop it is still a click; above it, the drag begins exactly once.
    func dragged(to point: CGPoint) {
        switch phase {
        case .idle,
             .cancelled:
            return
        case .pressed:
            let dx = point.x - pressOrigin.x
            let dy = point.y - pressOrigin.y
            guard hypot(dx, dy) >= Self.minimumDragDistance else { return }
            beginDrag()
        case .dragging:
            break
        }
        onChanged(paneID, point)
    }

    /// The release. A drag COMMITS at this point; a press that never travelled focuses the pane, so the
    /// top strip is not a focus dead-zone; a cancelled gesture does neither.
    func released(at point: CGPoint) {
        let ending = phase
        endGesture()
        switch ending {
        case .dragging: onEnded(paneID, point)
        case .pressed: onTap(paneID)
        case .idle,
             .cancelled: break
        }
    }

    private func beginDrag() {
        phase = .dragging
        escape.arm { [weak self] in self?.cancelDrag() }
        NSCursor.closedHand.push()
        cursorPushed = true
        placePill(animated: true)
    }

    /// ESCAPE, WITH THE BUTTON STILL DOWN. The gesture stays `.cancelled` until the release, because a
    /// bail-out that un-bails on a tremor is worse than no bail-out — the user has already stopped
    /// watching. Clearing the drag state without latching is not enough on its own: the pointer is
    /// still down, so the next movement simply refills whatever the cancel emptied and the release
    /// commits the landing the user bailed out of. Stickiness IS the cancel.
    ///
    /// This used to be recorded here as a deliberate DIFFERENCE from the SwiftUI half, which cleared
    /// the controller's `move` while its `DragGesture` kept running and had exactly that defect. It was
    /// never a difference worth keeping — it was that half's bug, and it is now fixed there on the same
    /// three-phase latch this uses. **The two halves agree.**
    private func cancelDrag() {
        guard phase == .dragging else { return }
        phase = .cancelled
        releaseDragChrome()
        onInterrupted(paneID)
    }

    /// The leaf closed under a live drag — this handle was torn out of the mount before a release could
    /// reach it. The two hierarchy hooks below are the whole safety net.
    ///
    /// This comment used to call that net "the one the SwiftUI half got from `@GestureState`'s automatic
    /// reset", and **that reset never covered this case in either half.** It fires on an end and on a
    /// cancel, but it is OBSERVED through an `.onChange` that is part of the view, so an unmount mid-drag
    /// destroys the observer instead of firing it — the SwiftUI half was stranding the same state this
    /// guards, and now spells the same net as `.onDisappear`. The claim survived here only because it was
    /// written from the other file's comment rather than from its behaviour, which is the cheapest way to
    /// launder an assumption into two languages at once.
    ///
    /// Not clearing it wedges the canvas: the mount gates every OTHER handle on the drag being over, so
    /// a stranded drag leaves every pill but one dead forever — and leaves Escape swallowed app-wide.
    private func abandonGesture() {
        guard phase != .idle else { return }
        let wasDragging = isDragging
        endGesture()
        if wasDragging { onInterrupted(paneID) }
    }

    private func endGesture() {
        phase = .idle
        releaseDragChrome()
    }

    /// Disarm Escape and hand the cursor back. Idempotent in both halves — a release, an Escape and a
    /// teardown can all reach it for one gesture, and the pop must happen exactly as often as the push.
    private func releaseDragChrome() {
        escape.disarm()
        if cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
        placePill(animated: true)
    }

    private var revealed: Bool { hovering || isDragging }

    private func spacePoint(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        guard let space = moveSpace ?? superview else { return local }
        return convert(local, to: space)
    }
}

// MARK: - The pill itself

/// One capsule of the grab pill — the `-` bar, or the contrast plate under it over a video stream.
///
/// The radius follows the HEIGHT rather than being a rung, which is what a capsule is: the pill grows
/// on hover and has to stay the same shape at both sizes.
@MainActor
private final class MacGrabPillCapsule: NSView {
    var fill = NSColor.clear {
        didSet {
            guard fill != oldValue else { return }
            needsDisplay = true
        }
    }

    /// The plate's hairline. `nil` on the bar — the bar is ink, not a plate, and a rim on it would read
    /// as a second pill drawn behind the first.
    var rim: NSColor? {
        didSet {
            guard rim != oldValue else { return }
            // The WIDTH goes with the colour. A layer's default border colour is opaque black, so a
            // non-zero width on a rimless bar draws one before the first `updateLayer` ever runs — and
            // a display pass is not promised for a view that is never in a window.
            layer?.borderWidth = rim == nil ? 0 : Slate.Metric.hairline
            needsDisplay = true
        }
    }

    /// The chip elevation, spent only by the contrast plate: the same voice as the rest of the
    /// over-video chrome, so a video leaf and a terminal leaf reveal the same pill with one of them
    /// standing on paper.
    var castsChipShadow = false {
        didSet {
            guard castsChipShadow != oldValue else { return }
            applyShadow()
        }
    }

    init(curve: CALayerCornerCurve) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = curve
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override var wantsUpdateLayer: Bool { true }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    /// The radius is re-derived from the size rather than in `layout()`, because the pill is placed by
    /// FRAME (see ``MacPaneMoveHandle/placePill(animated:)``) and a layout pass is not promised for
    /// every frame change.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layer?.cornerRadius = newSize.height / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateLayer() {
        // `effectiveAppearance` has to be the CURRENT one while a dynamic colour resolves, or every
        // rung answers for whatever appearance happened to be drawing last.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill.cgColor
            layer?.borderColor = rim?.cgColor
            layer?.shadowColor = Slate.Native.State.shadow.cgColor
        }
    }

    private func applyShadow() {
        guard castsChipShadow else {
            layer?.shadowOpacity = 0
            return
        }
        layer?.masksToBounds = false
        layer?.shadowRadius = Slate.Elevation.chip.radius
        layer?.shadowOffset = CGSize(width: 0, height: -Slate.Elevation.chip.y)
        layer?.shadowOpacity = 1
        needsDisplay = true
    }
}

// MARK: - The drag overlay

/// The drag overlay drawn ABOVE the panes while a move is in flight: a zone-specific drop preview, the
/// dashed "lifted" outline on the source, and a ghost chip pinned to the cursor. Purely visual — every
/// click during a drag belongs to the handle that captured the mouse.
///
/// Rects arrive in the compositor's solver space and are placed by FRAME, because that is what they
/// already are: absolute rectangles a pure solver emitted. Constraints would be a second description of
/// the same numbers, kept in step by hand.
@MainActor
final class MacPaneMoveOverlay: NSView {
    private let outline = MacMoveLiftedOutline()
    private let chip = MacPaneDragChip()
    private var zonePreview: NSView?
    /// The zone currently drawn, or `nil` before the first frame. The preview is rebuilt only on a zone
    /// CHANGE — a drag publishes 60+ frames a second and the shape changes on a destination transition,
    /// which is ``MacPaneDragChipPanel``'s content-compare argument applied to a rectangle.
    private var zone: PaneDropZone?

    init() {
        super.init(frame: .zero)
        for view in [outline, chip] {
            // `MacPaneDragChip` turns this OFF in its own init (the panel drives it by constraints).
            // Left off with no constraints attached, the engine would resolve its frame to zero and the
            // chip would simply never appear.
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Top-left origin — the space the solver's leaf rects are in.
    override var isFlipped: Bool { true }

    /// Transparent to the pointer, the whole way down. A live drag's events belong to the handle that
    /// captured the mouse, and a decoration that answered a hit test would end the gesture it exists to
    /// describe.
    override func hitTest(_: NSPoint) -> NSView? { nil }

    /// One drag frame: the zone preview, the source's lifted outline, the chip under the cursor.
    func show(
        drag: PaneMoveDrag, frames: [PaneID: CGRect], container: CGRect, sourceTitle: String?,
    ) {
        applyZone(drag.zone, frames: frames, container: container)
        if let rect = frames[drag.source] {
            outline.isHidden = false
            outline.frame = rect
        } else {
            outline.isHidden = true
        }
        // The chip's WORDING and its MARK are ``PaneDropRegister``'s. The cross-window panel says the
        // same things in the same voice off the same register, which is what stops the two chips — both
        // of which a user can see inside one drag — from ever disagreeing.
        chip.content = MacPaneDragChip.Content(
            symbol: PaneDropRegister.mark(for: drag.zone).symbol,
            label: PaneDropRegister.label(for: drag.zone, title: sourceTitle),
            cancels: drag.zone == .none,
        )
        let size = chip.fittingSize
        chip.frame = NSRect(
            x: drag.location.x - size.width / 2, y: drag.location.y - size.height / 2,
            width: size.width, height: size.height,
        )
    }

    /// Forget the drag. Called when the move ends so a later drag cannot cross-fade FROM a zone that
    /// belonged to the previous one.
    func clear() {
        zone = nil
        zonePreview?.removeFromSuperview()
        zonePreview = nil
        outline.isHidden = true
    }

    /// A zone change CROSS-FADES rather than interpolating the slab's frame across the pane: animating
    /// the frame would sweep a big rectangle from edge to edge, which reads as heavy, where a quick
    /// opacity snap stays out of the way.
    private func applyZone(_ next: PaneDropZone, frames: [PaneID: CGRect], container: CGRect) {
        guard next != zone else { return }
        zone = next
        let arriving = MacPaneMovePreview.view(for: next, frames: frames, container: container)
        let leaving = zonePreview
        zonePreview = arriving
        if let arriving {
            arriving.translatesAutoresizingMaskIntoConstraints = true
            arriving.alphaValue = 0
            addSubview(arriving, positioned: .below, relativeTo: outline)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Slate.Motion.smallFade.duration
            context.timingFunction = Slate.Motion.smallFade.timingFunction
            leaving?.animator().alphaValue = 0
            arriving?.animator().alphaValue = 1
        } completionHandler: {
            leaving?.removeFromSuperview()
        }
    }
}

// MARK: - The three zone previews

/// The drop vocabulary as drawings — one shape per zone, `static` so any other surface that has to
/// preview a landing draws the SAME thing (the canvas's own external-drop preview asks these too).
///
/// Every rectangle is ``PaneDropGeometry``'s. What is decided here is only which shape goes where.
@MainActor
enum MacPaneMovePreview {
    /// The preview for a resolved zone, already framed in solver space, or `nil` where there is nothing
    /// to draw (a cancel, or a target whose frame this layer does not hold).
    static func view(
        for zone: PaneDropZone, frames: [PaneID: CGRect], container: CGRect,
    ) -> NSView? {
        switch zone {
        case .none:
            nil
        case let .swap(target):
            frames[target].map { wash($0) }
        case let .resplit(target, edge):
            frames[target].map { slab(in: $0, edge: edge) }
        case let .dock(edge):
            rail(in: container, edge: edge)
        }
    }

    /// SWAP / whole-area wash: a wash + border over the WHOLE rect — "this entire area".
    static func wash(_ rect: CGRect) -> NSView {
        let plate = MacMoveZonePlate(rim: zoneRim, rimAlpha: 1)
        plate.frame = rect
        return plate
    }

    /// RE-SPLIT: an accent SLAB over the drop-side HALF of the target, with a bright seam line on the
    /// inner boundary where the new divider lands — the user literally sees a column vs a row form.
    static func slab(in rect: CGRect, edge: PaneDropEdge) -> NSView {
        let host = MacMoveFlippedBox(frame: rect)
        let slab = PaneDropGeometry.slabRect(in: rect, edge: edge)
        let seam = PaneDropGeometry.seamSize(slab, edge: edge)
        let centre = PaneDropGeometry.seamCenter(slab, edge: edge)
        let plate = MacMoveZonePlate(rim: slabRim, rimAlpha: slabRimAlpha)
        plate.frame = slab.offsetBy(dx: -rect.minX, dy: -rect.minY)
        // The seam: an accent bar on the slab's INNER edge (the would-be new divider).
        let bar = MacMoveSeamBar(frame: .zero)
        bar.frame = NSRect(
            x: centre.x - rect.minX - seam.width / 2, y: centre.y - rect.minY - seam.height / 2,
            width: seam.width, height: seam.height,
        )
        host.addSubview(plate)
        host.addSubview(bar)
        return host
    }

    /// DOCK: a full-length accent RAIL pinned to the whole container edge — "full span, tab-wide",
    /// visually distinct from the per-pane half-slab.
    static func rail(in container: CGRect, edge: PaneDropEdge) -> NSView {
        let plate = MacMoveZonePlate(rim: zoneRim, rimAlpha: 1)
        plate.frame = PaneDropGeometry.railRect(in: container, edge: edge)
        return plate
    }

    // ⚠️ THESE FOUR ARE NOT ON THE LADDER YET, and they are the SECOND spelling of numbers the SwiftUI
    // overlay already carries as literals (`PaneMoveAffordance.swift`, `washPreview` / `slabPreview` /
    // `railPreview` / `sourceOutline`). They are reported for central minting as `Slate.DropPreview.*`
    // rather than invented here — a rim width two renderers both need is a pair the day it is written,
    // which is exactly what `Slate.GrabPill` and `Slate.DropChip` were minted for one dimension over.

    /// The whole-area preview's border — a full-strength accent edge round a promise about a WHOLE pane.
    static let zoneRim: CGFloat = 2
    /// The half-slab's border, a step finer and a shade quieter than ``zoneRim``: the slab already
    /// stands inside a pane whose own edge is right there, so a full-strength rim would read as two
    /// borders rather than as one preview.
    static let slabRim: CGFloat = 1.5
    static let slabRimAlpha = 0.7
    /// The dashed "lifted" outline on the SOURCE pane — the pane that is in the air.
    static let liftedAlpha = 0.55
    static let liftedDash: [CGFloat] = [5, 4]
}

/// An accent wash with an accent border — the shape all three zone previews are drawn from, which is
/// what makes a swap, a re-split and a dock read as one vocabulary at three sizes.
@MainActor
private final class MacMoveZonePlate: NSView {
    private let rimAlpha: Double

    init(rim: CGFloat, rimAlpha: Double) {
        self.rimAlpha = rimAlpha
        super.init(frame: .zero)
        wantsLayer = true
        // `.circular`, deliberately: the SwiftUI half draws a `RoundedRectangle(cornerRadius:)`, whose
        // default corner style is the circular one. A layer border also strokes INSIDE its bounds, the
        // way `.strokeBorder` does and unlike a bezier stroke — which is why these are layers and the
        // dashed outline below is not.
        layer?.cornerRadius = Slate.Metric.radiusCard
        layer?.borderWidth = rim
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override var isFlipped: Bool { true }

    override var wantsUpdateLayer: Bool { true }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.State.accentMuted.cgColor
            layer?.borderColor = Slate.Native.accent.slateScalingAlpha(rimAlpha).cgColor
        }
    }
}

/// The re-split preview's seam — the would-be new divider, at full accent so it reads as the one line
/// the drop is about.
@MainActor
private final class MacMoveSeamBar: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override var wantsUpdateLayer: Bool { true }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // A capsule: the radius follows the SHORT side, so the bar keeps its shape whether it is the
        // vertical seam of a column split or the horizontal seam of a row.
        layer?.cornerRadius = Double.minimum(Double(newSize.width), Double(newSize.height)) / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.accent.cgColor
        }
    }
}

/// The dashed outline on the pane being MOVED — the one preview that says "this is the thing in the
/// air" rather than "this is where it lands".
///
/// Drawn rather than layer-configured, because a dash is the one thing a layer border cannot express:
/// `CALayer.borderWidth` has no pattern, so the alternative is a `CAShapeLayer` whose dynamic stroke
/// colour then has to be re-resolved by hand on every appearance change. Inside `draw(_:)` AppKit has
/// already made the view's appearance current, so the accent resolves for free.
@MainActor
private final class MacMoveLiftedOutline: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func draw(_: NSRect) {
        // A bezier strokes CENTRED on its path where SwiftUI's `.strokeBorder` strokes inside the
        // shape, so the path is inset by half the width to land on the same pixels.
        let inset = MacPaneMovePreview.slabRim / 2
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: inset, dy: inset),
            xRadius: Slate.Metric.radiusCard, yRadius: Slate.Metric.radiusCard,
        )
        path.lineWidth = MacPaneMovePreview.slabRim
        path.setLineDash(
            MacPaneMovePreview.liftedDash, count: MacPaneMovePreview.liftedDash.count, phase: 0,
        )
        Slate.Native.accent.slateScalingAlpha(MacPaneMovePreview.liftedAlpha).setStroke()
        path.stroke()
    }
}

/// A flipped, non-hit-testing box — the slab preview's local space, so its two parts are placed at the
/// coordinates ``PaneDropGeometry`` returned rather than at the same numbers turned upside down.
@MainActor
private final class MacMoveFlippedBox: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_: NSPoint) -> NSView? { nil }
}
