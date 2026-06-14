#if canImport(SwiftUI)
import SwiftUI
#if os(macOS)
import AppKit

// MARK: - ScrollPanForwarder (BUG-2 "pan stops at the pane edge")

/// A transparent AppKit view that forwards a trackpad/wheel scroll to the canvas pan
/// (``WorkspaceStore/scrollPan(by:)``). The pane's SwiftUI chrome — the resize-handle PERIMETER (the
/// pane "edge"), the floating pill, the dead scrim — is hit-OPAQUE (`.contentShape`), so a scroll over
/// it would be SWALLOWED: it cannot fall through to the single background pan-catcher behind the
/// panes, and the pan "stops at the edge of the pane". Used as the resize-grip fill, the pill's hit
/// fill, the scrim's hit fill, and a pane background, this makes every NON-content part of a pane pan
/// the canvas exactly like the empty background does. It overrides ONLY `scrollWheel`, so SwiftUI's
/// resize / move / tap gestures (which use `mouseDown`/`mouseDragged`) still work unobstructed — the
/// default `NSView` mouse handling propagates up to SwiftUI's recognizers untouched. Sign matches
/// ``CanvasView``'s `PanView` so panning over a pane feels identical to panning empty space.
struct ScrollPanForwarder: NSViewRepresentable {
    let store: WorkspaceStore
    func makeNSView(context _: Context) -> NSView { ForwardingView(store: store) }
    func updateNSView(_ nsView: NSView, context _: Context) { (nsView as? ForwardingView)?.store = store }

    final class ForwardingView: NSView {
        weak var store: WorkspaceStore?
        init(store: WorkspaceStore) { self.store = store
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError("not used") }
        override func scrollWheel(with event: NSEvent) {
            let dx: CGFloat, dy: CGFloat
            if event.hasPreciseScrollingDeltas { dx = event.scrollingDeltaX
                dy = event.scrollingDeltaY
            } else { dx = event.scrollingDeltaX * 10
                dy = event.scrollingDeltaY * 10
            }
            store?.scrollPan(by: CGSize(width: -dx, height: -dy)) // natural-scroll, same sign as PanView
        }
    }
}
#endif

// MARK: - CanvasItemView (one positioned pane on the infinite plane)

/// Renders one ``CanvasItem`` as a BORDERLESS floating window: the bare ``PaneLeafView`` content with
/// a rounded clip + a static soft shadow (no header bar, no focus-ring border — docs/31 follow-up),
/// plus the canvas-only affordances — the ``FloatingPaneHandle`` pill at the top centre (hold+drag
/// moves the pane, click opens the ``PaneMenuView`` popover), the ``PaneDeadScrim`` on terminal
/// connection failure, and the 8 invisible edge/corner resize grips. The parent ``CanvasView``
/// positions this view at the item's canvas-space frame (under one rigid camera `.offset`); this view
/// only previews a live move/resize and commits once on `.onEnded` (the `SplitContainer`
/// commit-on-end discipline — no per-frame store mutation, no `TIOCSWINSZ` storm).
///
/// ### Smart snapping (CanvasSnap)
/// Move + resize previews route through the pure ``CanvasSnap`` solver against `snapTargets` (the
/// viewport-near sibling frames) + `snapViewport`: the `@GestureState` holds the full snapped
/// ``CanvasSnap/Resolution`` (so the preview is magnetic AND the guides auto-vanish on any gesture
/// end/cancel), while a plain `@State` chain mirrors the hysteresis token into the `.onEnded` commit —
/// preview ≡ commit by construction, even inside the engage/release band. Guides render in THIS
/// view's own overlay (item-local — no shared channel to go stale). Holding ⌘ (macOS) or the menu
/// toggles disable snapping.
///
/// ### Drag-vs-click on the pill (one recognizer, no races)
/// ONE `DragGesture(minimumDistance: 0)` with a dead zone (4pt macOS / 10pt iOS): below the dead zone
/// nothing previews and `.onEnded` treats the gesture as a CLICK (focus + menu); once past it, the
/// latch holds for the whole gesture (returning to the start pixel still commits a move, never opens
/// the menu). NEVER SwiftUI `Menu` (it opens its tracking on mouseDown — the drag dies) and NEVER
/// `NSMenu` (its event-tracking runloop stalls the video panes).
///
/// ### Why the body keeps its click (docs/30 §6.5)
/// The move gesture lives on the small floating pill only, and the resize gesture only on the thin
/// edge/corner grips — both plain `.gesture` (never `.highPriorityGesture`). The terminal body has NO
/// ancestor gesture, so libghostty's own `mouseDown` (selection / mouse reporting) is never stolen;
/// body focus comes from `onRequestFocus` (``wireFocusOnClick(for:)``), a remote-GUI pane focuses via
/// its `RemotePaneContext.onActivate`, and on iOS from a `.simultaneousGesture(Tap)`.
struct CanvasItemView: View {
    let item: CanvasItem
    let store: WorkspaceStore
    /// The named coordinate space of the canvas plane (so a drag translation is the canvas-space delta,
    /// 1:1 since the camera is a pure translate).
    let coordSpace: String

    /// The viewport SIZE (frame-stable — changes only on window resize). The full snap environment
    /// (sibling target frames + the visible canvas rect) is deliberately NOT a stored input: it would
    /// change every pan/scroll frame and re-evaluate EVERY pane body per frame (the BUG-1/BUG-2 class).
    /// Instead ``snapEnvironment()`` reads the store INSIDE the gesture closures at solve time —
    /// closures run outside body evaluation, so no observation dependency is registered.
    var viewportSize: CGSize = .zero

    /// Non-nil ⇒ this pane is MAXIMIZED: render at this fixed size (the full viewport minus a small
    /// inset) instead of ``CanvasItem/frame``, and suppress the live move/resize offset. The parent
    /// ``CanvasView`` positions us at the camera-anchored viewport centre. Passing a SIZE (not swapping
    /// in a separate full-screen view) is what keeps the maximized pane at the SAME SwiftUI identity as
    /// its canvas tile, so libghostty's surface is merely RESIZED — never torn down + rebuilt. The old
    /// separate-subtree maximize rebuilt the surface, which replayed stale bytes (garbled glyphs) and
    /// crashed the app on repeated maximize/restore cycles.
    var displaySize: CGSize?

    /// Live drag-to-move preview — the full snapped resolution, or `nil` when not dragging / inside
    /// the dead zone. Auto-resets on ANY gesture end/cancel (no stuck preview, no stuck guides); the
    /// committed move lands via ``WorkspaceStore/movePane(_:by:)`` on `.onEnded`.
    @GestureState private var movePreview: CanvasSnap.Resolution?
    /// Live resize preview — the full snapped resolution, or `nil` when not resizing. Auto-resets on
    /// gesture end; the committed frame lands via ``WorkspaceStore/resizePane(_:to:)``.
    @GestureState private var resizePreview: CanvasSnap.Resolution?
    /// Hysteresis mirrors: `.updating` chains `previous` through the gesture state itself, while
    /// `.onChanged` maintains these PLAIN copies for `.onEnded` (which cannot read `@GestureState`) —
    /// both sequences see chain_{n−1} per event, so they are identical by construction.
    @State private var moveChain: CanvasSnap.Resolution?
    @State private var resizeChain: CanvasSnap.Resolution?
    /// The snap config the LAST preview solve actually used, replayed by the `.onEnded` commit —
    /// without this, releasing ⌘ between the final drag event and mouse-up would re-poll the modifier
    /// and commit a frame the user never previewed (preview ≢ commit).
    @State private var moveConfig: CanvasSnap.Config?
    @State private var resizeConfig: CanvasSnap.Config?
    /// Whether the pill's action popover is open (toggled by the click branch of the pill gesture).
    @State private var menuShown = false

    /// The non-overlap config the LAST move/resize preview solve actually used, replayed by the
    /// `.onEnded` commit so releasing ⌘ between the final drag event and mouse-up cannot commit a
    /// non-overlap decision the user never previewed (the `moveConfig` discipline, extended to overlap).
    @State private var moveNoOverlap: CanvasNonOverlap.Config?
    @State private var resizeNoOverlap: CanvasNonOverlap.Config?

    /// Interaction prefs (shared with ``PaneMenuView``'s toggles — also the iOS snap-disable path).
    @AppStorage(SettingsKey.snapPanes) private var snapPanes = true
    @AppStorage(SettingsKey.snapGrid) private var snapGrid = true
    @AppStorage(SettingsKey.nonOverlap) private var nonOverlap = true

    private var isFocused: Bool { store.isFocused(item.id) }

    /// Breathing room between the border line and the content, so glyphs never sit flush
    /// against the stroke.
    private static let contentPadding: CGFloat = 10
    /// Below this travel a pill gesture is a CLICK; past it, a latched MOVE (touch jitter needs more).
    #if os(macOS)
    private static let dragDeadZone: CGFloat = 4
    #else
    private static let dragDeadZone: CGFloat = 10
    #endif

    var body: some View {
        let maximized = displaySize != nil
        // Maximized → fixed viewport size (parent centres us); otherwise the live snapped preview
        // (resize wins — the two gestures are on disjoint regions and cannot run together), else the
        // persisted frame.
        let shown = displaySize.map { CGRect(origin: .zero, size: $0) }
            ?? resizePreview?.frame
            ?? movePreview?.frame
            ?? item.frame
        // The parent positions us at the PERSISTED frame's centre; shift by the previewed centre
        // delta (move: the snapped translation; resize: keeps the anchored edge pinned). A maximized
        // pane can't be moved/resized → no live offset. A NON-anchor pane in a live GROUP drag follows
        // the anchor's broadcast delta so the whole cohort moves together on screen (the anchor uses
        // its own gesture preview; `groupDragOffset` returns .zero for it).
        // A pane follows TWO live cohort offsets: the multi-select group drag (`groupDragOffset`) and the
        // PaneGroup-handle drag (`groupHandleOffset`, when it is a member of the group being handle-moved).
        let groupOffset = maximized ? .zero : store.groupDragOffset(for: item.id)
        let handleOffset = maximized ? .zero : store.groupHandleOffset(for: item.id)
        let offsetX = (maximized ? 0 : shown.midX - item.frame.midX) + groupOffset.width + handleOffset.width
        let offsetY = (maximized ? 0 : shown.midY - item.frame.midY) + groupOffset.height + handleOffset.height
        let status = PanePresentation.connectionStatus(store.handle(for: item.id))

        return PaneLeafView(
            handle: store.handle(for: item.id),
            spec: item.spec,
            isFocused: isFocused,
            focusCoordinator: store.focusCoordinator,
            store: store,
            // The dead scrim (below) carries the failure reason + the reconnect tap for the SAME
            // states — suppress the in-leaf orange banner so the pane doesn't say it twice (the
            // neutral "Session ended" banner is untouched; the scrim never shows for it).
            suppressFailureBanner: PaneDeadScrim.isShown(status),
        )
        // Maximized: inset the content below the pill so the terminal's FIRST ROW (where the prompt
        // lives) is never occluded by it. Geometry-only (same view identity — guardrail 2 safe).
        .padding(.top, maximized ? 34 : Self.contentPadding)
        .padding([.horizontal, .bottom], Self.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(width: shown.width, height: shown.height) // resize previews live (intended reflow)
        #if os(macOS)
            // BUG-2: catch a scroll over any non-NSView pane region (placeholder / padding) and pan the
            // canvas, instead of it being swallowed. Behind the content, so the video/terminal NSView (in
            // front) still gets — and forwards — its own scroll. The resize-grip PERIMETER is the OVERLAY
            // in front of this, so its grips forward via `gripBase` (below); together they make the whole
            // pane pan like empty space.
            .background { ScrollPanForwarder(store: store) }
        #endif
            // The pane plate: a flat opaque fill behind the padded content (the border-to-content gap
            // must cover the canvas dots) — no shadow, the border below carries the focus cue.
            .background(.background)
            // The pane border: a flat 1pt line, accent while focused (the header stays gone — the pill
            // is the only other chrome). A pane in the MULTI-SELECTION gets a thicker accent ring (so a
            // shift-click cohort reads as one group). Hit-testing off so it never steals the grips' slivers.
            .overlay {
                let selected = store.isSelected(item.id)
                Rectangle()
                    .strokeBorder(
                        isFocused || selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.separator),
                        lineWidth: selected ? 2.5 : 1,
                    )
                    .allowsHitTesting(false)
            }
            // Terminal connection failure dims the (stale) body into a big "click to reconnect" target.
            // Declared BEFORE the grips + pill: the perimeter must keep RESIZING a dead pane (the grips
            // win hit-testing where they overlap the scrim's edge), and the pill stays usable above it.
            .overlay {
                if PaneDeadScrim.isShown(status) {
                    PaneDeadScrim(status: status, store: store) { store.reconnect(item.id) }
                }
            }
            .overlay { resizeHandles }
            // The floating pill, frontmost (declared last → wins hit-testing over the top-edge grip
            // sliver it overlaps — the same declared-last-wins pattern the corner grips use).
            .overlay(alignment: .top) { pill(maximized: maximized) }
            // The smart-snap alignment guides of OUR in-flight drag, item-local: they live in the gesture
            // state, so a cancelled gesture cleans them up by construction. Gated off while maximized —
            // a maximize mid-drag does NOT cancel the in-flight gesture (identity survives by design), so
            // a frozen preview must not paint guides over the maximized pane.
            .overlay {
                if displaySize == nil, let resolution = resizePreview ?? movePreview, !resolution.guides.isEmpty {
                    SnapGuideOverlay(guides: resolution.guides, origin: shown.origin)
                }
            }
            .offset(x: offsetX, y: offsetY)
            // NOTE: the dragged pane floats above its siblings via the OUTER `.zIndex` in CanvasView (sibling
            // stacking lives there) — driven by `store.isFocused`, which the move/resize gestures set at drag
            // START (`raiseOnGestureStart`). A `.zIndex` here would be inert (no siblings at this level).
            .onAppear { wireFocusOnClick(for: item.id) }
            // A maximize toggle mid-drag does NOT cancel the in-flight gesture (the pane keeps its SwiftUI
            // identity by design — guardrail 2), but every gesture closure guards itself out while
            // maximized; this drops the plain-@State mirrors so no stale hysteresis token / config can
            // leak into the next drag (the proven livePan repair pattern).
            .onChange(of: store.workspace.maximizedPane) { _, _ in
                moveChain = nil
                resizeChain = nil
                moveConfig = nil
                resizeConfig = nil
                moveNoOverlap = nil
                resizeNoOverlap = nil
            }
            // General cancellation repair: ANY gesture that dies without `.onEnded` (system cancel, view
            // dismantle) auto-resets the preview to nil — mirror that into the chain, or the NEXT pill
            // gesture would see a stale non-nil chain, bypass the dead-zone click branch, and commit a
            // zero-distance "move" instead of opening the menu.
            .onChange(of: movePreview == nil) { _, gone in if gone { moveChain = nil
                moveConfig = nil
                moveNoOverlap = nil
            } }
            .onChange(of: resizePreview == nil) { _, gone in if gone { resizeChain = nil
                resizeConfig = nil
                resizeNoOverlap = nil
            } }
        #if os(iOS)
            // Absorb a touch on the body → focus this pane AND block the background pan from firing under
            // it (the bottom Color.clear pan layer never sees a touch that lands on a pane).
            .simultaneousGesture(TapGesture().onEnded { store.focus(item.id) })
        #endif
    }

    // MARK: The pill (move/menu affordance — the header's replacement)

    private func pill(maximized: Bool) -> some View {
        FloatingPaneHandle(
            id: item.id,
            spec: item.spec,
            handle: store.handle(for: item.id),
            isFocused: isFocused,
            isMaximized: maximized,
            store: store,
            menuShown: $menuShown,
        )
        .gesture(pillGesture)
        .padding(.top, 6)
    }

    // MARK: Gestures

    /// The smart-snap config for the CURRENT solve: the menu toggles select the classes; holding ⌘
    /// (macOS) disables everything for a free drag (polled per solve — DragGesture carries no
    /// modifiers — so pressing/releasing ⌘ mid-drag takes effect on the next pixel of travel).
    private var snapConfig: CanvasSnap.Config {
        #if os(macOS)
        if NSEvent.modifierFlags.contains(.command) { return .disabled }
        #endif
        var config = CanvasSnap.Config()
        config.snapsToPanes = snapPanes
        config.snapsToGrid = snapGrid
        return config
    }

    /// The non-overlap config for the CURRENT solve: enabled by the setting, but bypassed (`.disabled`)
    /// while ⌘ is held (macOS) so one ⌘-drag frees BOTH snapping and overlap for a deliberate stack.
    /// Polled per solve like ``snapConfig`` (the gesture carries no modifiers).
    private var nonOverlapConfig: CanvasNonOverlap.Config {
        #if os(macOS)
        if NSEvent.modifierFlags.contains(.command) { return .disabled }
        #endif
        return nonOverlap ? CanvasNonOverlap.Config() : .disabled
    }

    /// The non-overlap collision bodies ({ungrouped panes} ∪ {group boxes}, excluding the dragged pane
    /// and its own group), read AT SOLVE TIME inside the gesture closures from the SAME viewport math as
    /// ``snapEnvironment()`` — so the live slide preview and the store's commit see the same bodies
    /// (preview ≡ commit). Never a stored body input (the BUG-1/BUG-2 per-pan re-render class).
    private func collisionEnvironment() -> [CanvasNonOverlap.Body] {
        let camera = store.workspace.canvas.camera
        guard viewportSize.width > 0, viewportSize.height > 0 else { return [] }
        let viewport = CGRect(
            origin: CGPoint(
                x: camera.origin.x - store.liveCameraOffset.width,
                y: camera.origin.y - store.liveCameraOffset.height,
            ),
            size: viewportSize,
        )
        let region = viewport.insetBy(dx: -200, dy: -200)
        return store.workspace.canvas.collisionBodies(
            excludingPane: item.id, excludingGroup: item.groupID, region: region, groups: store.workspace.groups,
        )
    }

    /// The smart-snap inputs, read AT SOLVE TIME inside the gesture closures (never a body input —
    /// the visible canvas rect changes every pan frame, and as a stored property it would re-evaluate
    /// every pane body per frame, the BUG-1/BUG-2 re-render class). Reading the `@Observable` store
    /// here registers no observation dependency (closures run outside body evaluation). `livePan` is
    /// deliberately ignored: a background-drag pan cannot be concurrent with a pill/grip drag (one
    /// pointer); the wheel-scroll offset IS folded in, keeping viewport-edge snapping honest mid-drag.
    private func snapEnvironment() -> (targets: [CGRect], viewport: CGRect?) {
        let camera = store.workspace.canvas.camera
        guard viewportSize.width > 0, viewportSize.height > 0 else { return ([], nil) }
        let viewport = CGRect(
            origin: CGPoint(
                x: camera.origin.x - store.liveCameraOffset.width,
                y: camera.origin.y - store.liveCameraOffset.height,
            ),
            size: viewportSize,
        )
        // Snapping to far-off-screen panes would be invisible surprise; a small margin keeps
        // almost-visible neighbours snappable.
        let region = viewport.insetBy(dx: -200, dy: -200)
        let targets = store.workspace.canvas.items
            .filter { $0.id != item.id && $0.frame.intersects(region) }
            .map(\.frame)
        return (targets, viewport)
    }

    /// The pill's single gesture: dead-zone-latched drag-to-move with a click branch.
    /// `minimumDistance: 0` so a plain mouse-down is OURS from the first event (no second recognizer
    /// to race); the dead zone keeps a click from nudging the pane, and the latch (preview != nil)
    /// keeps a drag that returns near its origin from opening the menu.
    private var pillGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(coordSpace))
            .updating($movePreview) { value, state, _ in
                // Maximized: click-only — and CLEAR a preview frozen by a maximize-mid-drag (the
                // gesture itself is never cancelled; identity survives by design).
                guard displaySize == nil else { state = nil
                    return
                }
                if state == nil, !Self.pastDeadZone(value.translation) { return }
                // GROUP drag: the anchor moves RAW (no per-pane snap — snapping individual cohort
                // members would scatter the group); the cohort stays rigid.
                if store.isSelected(item.id), store.selectedPanes.count > 1 {
                    state = CanvasSnap.Resolution(
                        frame: item.frame.offsetBy(dx: value.translation.width, dy: value.translation.height),
                        guides: [],
                    )
                    return
                }
                let (targets, viewport) = snapEnvironment()
                let snap = CanvasSnap.move(
                    item.frame.offsetBy(dx: value.translation.width, dy: value.translation.height),
                    others: targets, viewport: viewport,
                    config: snapConfig, previous: state,
                )
                state = Self.previewResolution(
                    snap: snap,
                    item: item,
                    config: nonOverlapConfig,
                    bodies: collisionEnvironment,
                )
            }
            .onChanged { value in
                guard displaySize == nil else { return }
                if moveChain == nil, !Self.pastDeadZone(value.translation) { return }
                raiseOnGestureStart()
                // GROUP drag: broadcast the raw delta so the OTHER selected panes follow live.
                if store.isSelected(item.id), store.selectedPanes.count > 1 {
                    store.updateGroupDrag(anchor: item.id, delta: value.translation)
                    return
                }
                let (targets, viewport) = snapEnvironment()
                let config = snapConfig
                moveConfig = config
                moveNoOverlap = nonOverlapConfig
                moveChain = CanvasSnap.move(
                    item.frame.offsetBy(dx: value.translation.width, dy: value.translation.height),
                    others: targets, viewport: viewport,
                    config: config, previous: moveChain,
                )
            }
            .onEnded { value in
                let chain = moveChain
                let config = moveConfig ?? snapConfig
                let noOverlap = moveNoOverlap ?? nonOverlapConfig
                moveChain = nil
                moveConfig = nil
                moveNoOverlap = nil
                // Maximized: a click opens the menu; a DRAG does nothing (the pane cannot move, and
                // surprising the user with the menu after a drag would be worse than a no-op).
                if displaySize != nil {
                    if !Self.pastDeadZone(value.translation) {
                        store.focus(item.id)
                        menuShown.toggle()
                    }
                    return
                }
                // CLICK: never latched into a move. SHIFT-click toggles the multi-selection instead of
                // focusing + opening the menu (the cohort-building affordance).
                if chain == nil, !Self.pastDeadZone(value.translation) {
                    if Self.shiftHeld {
                        store.toggleSelection(item.id)
                    } else {
                        // A plain click on a pane clears any multi-selection and focuses just this one.
                        store.clearSelection()
                        store.focus(item.id)
                        menuShown.toggle()
                    }
                    return
                }
                // GROUP MOVE: if this pane is in a multi-selection, translate the WHOLE selection by the
                // raw delta (group drags move together, un-snapped — snapping each pane would scatter the
                // cohort). Clear the live broadcast FIRST so there's no double-offset flash, then commit.
                if store.isSelected(item.id), store.selectedPanes.count > 1 {
                    // The cohort members tracked the pointer via their live `.offset`; committing their
                    // frame must be INSTANT (no `.animation(value: pos)` spring) or each non-anchor member
                    // flashes back to its pre-drag origin and glides forward (the offset drops to zero the
                    // instant the spring starts from the old position). The anchor is exempt via `isFocused`;
                    // this transaction covers the rest.
                    var instant = Transaction()
                    instant.disablesAnimations = true
                    withTransaction(instant) {
                        store.endGroupDragLive()
                        store.moveSelection(by: value.translation, anchor: item.id)
                    }
                    return
                }
                // MOVE: one commit, recomputed from the RAW final translation with the last chain
                // token AND the last previewed config — identical to the last preview (the solver is
                // idempotent at a fixed input, and the config can't drift under a ⌘ release).
                let (targets, viewport) = snapEnvironment()
                let final = CanvasSnap.move(
                    item.frame.offsetBy(dx: value.translation.width, dy: value.translation.height),
                    others: targets, viewport: viewport,
                    config: config, previous: chain,
                )
                // NON-OVERLAP: route the snapped target through the slide + (insert-intent) make-space
                // commit so the pane lands flush — or the neighbours part to admit it. A disabled config
                // (⌘ / setting off) degrades to a plain move-to inside the store, so this stays uniform.
                if noOverlap.enabled {
                    store.movePaneNonOverlapping(item.id, snapped: final.frame, config: noOverlap)
                } else {
                    store.movePane(item.id, by: CGSize(
                        width: final.frame.minX - item.frame.minX,
                        height: final.frame.minY - item.frame.minY,
                    ))
                }
            }
    }

    /// Folds the non-overlap slide into a CanvasSnap move resolution for the live preview: the dragged
    /// pane glides flush along its neighbours (only the dragged box moves — item-local). The snap GUIDES
    /// are kept only when the slide did NOT move the box off the snapped position (else they would assert
    /// an alignment the flush slide just broke — the flush slide is its own affordance). The snap
    /// hysteresis sticks pass through verbatim (the slide is stateless; ``CanvasSnap`` reads only the
    /// sticks from `previous`).
    private static func previewResolution(
        snap: CanvasSnap.Resolution,
        item: CanvasItem,
        config: CanvasNonOverlap.Config,
        bodies: () -> [CanvasNonOverlap.Body],
    ) -> CanvasSnap.Resolution {
        guard config.enabled else { return snap }
        let slid = CanvasNonOverlap.slide(snap.frame, from: item.frame.origin, bodies: bodies(), config: config).frame
        let moved = abs(slid.minX - snap.frame.minX) > 0.5 || abs(slid.minY - snap.frame.minY) > 0.5
        return CanvasSnap.Resolution(
            frame: slid,
            guides: moved ? [] : snap.guides,
            stickX: snap.stickX,
            stickY: snap.stickY,
        )
    }

    private static func pastDeadZone(_ translation: CGSize) -> Bool {
        translation.width * translation.width + translation.height * translation.height
            >= dragDeadZone * dragDeadZone
    }

    /// Whether Shift is held RIGHT NOW (macOS). `DragGesture` carries no modifiers, so the pill reads
    /// the live global modifier flags at commit time to tell a shift-click (toggle selection) from a
    /// plain click. Always `false` off macOS (no multi-select-by-modifier there).
    private static var shiftHeld: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.shift)
        #else
        false
        #endif
    }

    /// Floats this pane to the top the instant a move/resize drag begins (so it is never occluded by a
    /// higher-z sibling mid-gesture). Raising focuses it → CanvasView's outer `.zIndex` lifts it. The
    /// `!isFocused` guard makes it fire at most once per gesture (after the first raise it is focused),
    /// so there is no per-frame store churn; the committed z/frame still land on `.onEnded`.
    private func raiseOnGestureStart() {
        if !store.isFocused(item.id) { store.raisePane(item.id) }
    }

    /// 8-anchor resize for `anchor`: live `.frame` preview (deliberately reflows for native feel) with
    /// the moving edge(s) magnetic via ``CanvasSnap/resize``, ONE commit on `.onEnded`. The downstream
    /// `sendResize` dedup + host resize-debounce absorb the intermediate sizes, so only the final
    /// frame is persisted.
    private func resizeGesture(_ anchor: ResizeAnchor) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(coordSpace))
            .updating($resizePreview) { value, state, _ in
                // The grips are hit-disabled while maximized, but an IN-FLIGHT resize survives a
                // maximize toggle (the gesture is never cancelled) — guard every closure so it can
                // neither keep previewing nor commit onto the hidden restore frame.
                guard displaySize == nil else { state = nil
                    return
                }
                state = resizeResolution(
                    anchor,
                    translation: value.translation,
                    config: snapConfig,
                    previous: state,
                )
            }
            .onChanged { value in
                guard displaySize == nil else { return }
                raiseOnGestureStart()
                let config = snapConfig
                resizeConfig = config
                resizeNoOverlap = nonOverlapConfig
                resizeChain = resizeResolution(
                    anchor,
                    translation: value.translation,
                    config: config,
                    previous: resizeChain,
                )
            }
            .onEnded { value in
                let chain = resizeChain
                let config = resizeConfig ?? snapConfig
                let noOverlap = resizeNoOverlap ?? nonOverlapConfig
                resizeChain = nil
                resizeConfig = nil
                resizeNoOverlap = nil
                guard displaySize == nil else { return }
                store.resizePane(
                    item.id,
                    to: resizeResolution(
                        anchor,
                        translation: value.translation,
                        config: config,
                        previous: chain,
                        noOverlap: noOverlap,
                    )
                    .frame,
                )
            }
    }

    /// Geometry-resize → snap → non-overlap clamp: the pure pipeline shared by the live preview and the
    /// commit. After ``CanvasSnap/resize`` magnetizes the moving edge, ``CanvasNonOverlap/clampResize``
    /// stops it one gutter short of any neighbour (the growing edge yields rather than overlapping). The
    /// snap guides are dropped when the clamp moved an edge (the flush stop is its own affordance).
    /// `noOverlap` replays the last-previewed config at commit (the `⌘`-release preview≡commit discipline).
    private func resizeResolution(
        _ anchor: ResizeAnchor,
        translation: CGSize,
        config: CanvasSnap.Config,
        previous: CanvasSnap.Resolution?,
        noOverlap: CanvasNonOverlap.Config? = nil,
    ) -> CanvasSnap.Resolution {
        let raw = CanvasGeometry.resizing(item.frame, anchor: anchor, by: translation, minSize: Canvas.minItemSize)
        let (targets, viewport) = snapEnvironment()
        let snapped = CanvasSnap.resize(
            raw,
            anchor: anchor,
            others: targets,
            viewport: viewport,
            config: config,
            previous: previous,
        )
        let no = noOverlap ?? nonOverlapConfig
        guard no.enabled else { return snapped }
        let clamped = CanvasNonOverlap.clampResize(
            snapped.frame,
            anchor: anchor,
            bodies: collisionEnvironment(),
            minSize: Canvas.minItemSize,
            config: no,
        )
        let changed = abs(clamped.minX - snapped.frame.minX) > 0.5 || abs(clamped.maxX - snapped.frame.maxX) > 0.5
            || abs(clamped.minY - snapped.frame.minY) > 0.5 || abs(clamped.maxY - snapped.frame.maxY) > 0.5
        return CanvasSnap.Resolution(
            frame: clamped,
            guides: changed ? [] : snapped.guides,
            stickX: snapped.stickX,
            stickY: snapped.stickY,
        )
    }

    // MARK: Resize handles

    /// Thin invisible grips at the 4 corners + 4 edges. Edges are laid out first so the corners (added
    /// last) win hit-testing where they overlap. Only the grip area is interactive (the gesture is on
    /// the small grip, not the full-bleed positioning frame), so the terminal body stays clickable.
    private var resizeHandles: some View {
        ZStack {
            edgeHandle(.top, alignment: .top)
            edgeHandle(.bottom, alignment: .bottom)
            edgeHandle(.left, alignment: .leading)
            edgeHandle(.right, alignment: .trailing)
            cornerHandle(.topLeft, alignment: .topLeading)
            cornerHandle(.topRight, alignment: .topTrailing)
            cornerHandle(.bottomLeft, alignment: .bottomLeading)
            cornerHandle(.bottomRight, alignment: .bottomTrailing)
        }
        .allowsHitTesting(store.workspace.maximizedPane == nil) // no resize while maximized
    }

    private static let cornerGrip: CGFloat = 16
    private static let edgeThickness: CGFloat = 8

    /// The invisible fill of a resize grip. On macOS it is a ``ScrollPanForwarder`` so a scroll over the
    /// grip — the pane PERIMETER, i.e. the "cạnh của pane" — pans the canvas instead of being swallowed
    /// (BUG-2); the SwiftUI resize `.gesture` still fires because the forwarder overrides only
    /// `scrollWheel`. On iOS (no scroll wheel) it is a plain clear rectangle.
    @ViewBuilder private var gripBase: some View {
        #if os(macOS)
        ScrollPanForwarder(store: store)
        #else
        Rectangle().fill(Color.clear)
        #endif
    }

    private func cornerHandle(_ anchor: ResizeAnchor, alignment: Alignment) -> some View {
        gripBase
            .frame(width: Self.cornerGrip, height: Self.cornerGrip)
            .contentShape(Rectangle())
            .gesture(resizeGesture(anchor))
        #if os(macOS)
            .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
        #endif
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    @ViewBuilder
    private func edgeHandle(_ anchor: ResizeAnchor, alignment: Alignment) -> some View {
        let horizontal = (anchor == .top || anchor == .bottom)
        gripBase
            .frame(
                width: horizontal ? nil : Self.edgeThickness,
                height: horizontal ? Self.edgeThickness : nil,
            )
            .frame(maxWidth: horizontal ? .infinity : nil, maxHeight: horizontal ? nil : .infinity)
            .contentShape(Rectangle())
            .gesture(resizeGesture(anchor))
        #if os(macOS)
            .onHover { inside in
                if inside { (horizontal ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).push() }
                else { NSCursor.pop() }
            }
        #endif
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    // MARK: Focus wiring (ported verbatim from the old PaneTreeView.wireFocusOnClick)

    /// Points the leaf's terminal renderer at `store.focus(id)` so a click on the terminal BODY focuses
    /// the pane (libghostty's `mouseDown` consumes the tap before any SwiftUI gesture). A faked /
    /// `.remoteGUI` handle has no `terminalModel`, so this is a no-op there. Captures only `store` + `id`
    /// (both stable), so the closure stays correct across reshapes.
    private func wireFocusOnClick(for id: PaneID) {
        guard let live = store.handle(for: id) as? LivePaneSession,
              let model = live.terminalModel else { return }
        model.onRequestFocus = { [weak store] in store?.focus(id) }
        // "Only the active pane swallows scroll": a scroll on a NON-focused terminal pans the canvas
        // instead of scrolling its scrollback (the renderer calls this only when `!isFocusedPane`).
        model.onCanvasScroll = { [weak store] delta in
            // Debounced live accumulator (not a per-step commitCamera) so panning over a background
            // terminal is smooth and never thrashes the canvas re-render cascade (BUG-2/BUG-1 fix).
            store?.scrollPan(by: delta)
        }
        // Synchronized input (tmux synchronize-panes): when broadcast is armed, the bytes this pane sends
        // are mirrored into the other target panes. The store no-ops when disarmed / when this pane is not
        // a broadcast target, and guards its own re-entry — so this is inert for the common single-pane case.
        model.broadcastTap = { [weak store] data in store?.fanBroadcastInput(from: id, data) }
    }
}

// MARK: - SnapGuideOverlay (the alignment guides of OUR in-flight drag)

/// Renders the active ``CanvasSnap/Guide``s in the dragged pane's LOCAL coordinate space: local (0,0)
/// corresponds to the previewed (snapped) frame's top-leading corner, so `local = canvas −
/// previewOrigin` exactly. Guides routinely extend OUTSIDE the pane's bounds (they span the aligned
/// neighbours) — nothing here clips, the canvas clips only at the viewport, and the dragged pane is
/// focused (zIndex 1_000_000) so the lines render above every sibling. Solid 1pt accent lines;
/// centre-alignment guides draw dashed (the Keynote distinction). No animation — animated guides read
/// as lag. Never hit-testable.
private struct SnapGuideOverlay: View {
    let guides: [CanvasSnap.Guide]
    /// The previewed frame's origin (canvas space) — the local-space anchor.
    let origin: CGPoint

    /// Visual overshoot past the guide's true span at each end (Figma-style).
    private static let overshoot: CGFloat = 16

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(guides, id: \.self) { guide in
                let vertical = guide.orientation == .vertical
                let length = guide.end - guide.start + Self.overshoot * 2
                GuideLineShape(vertical: vertical)
                    .stroke(
                        Color.accentColor.opacity(0.9),
                        style: StrokeStyle(lineWidth: 1, dash: guide.kind == .center ? [4, 3] : []),
                    )
                    .frame(width: vertical ? 1 : length, height: vertical ? length : 1)
                    .position(
                        x: vertical ? guide.position - origin.x : (guide.start + guide.end) / 2 - origin.x,
                        y: vertical ? (guide.start + guide.end) / 2 - origin.y : guide.position - origin.y,
                    )
            }
        }
        .allowsHitTesting(false)
    }
}

/// A 1-D line through the middle of its frame (strokable with a dash, unlike a filled Rectangle).
private struct GuideLineShape: Shape {
    let vertical: Bool
    func path(in rect: CGRect) -> Path {
        var path = Path()
        if vertical {
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
        return path
    }
}
#endif
