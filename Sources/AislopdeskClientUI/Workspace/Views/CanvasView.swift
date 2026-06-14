#if canImport(SwiftUI)
import SwiftUI

// MARK: - CanvasView (the pannable infinite plane)

/// The regular-width workspace surface (docs/31): the single infinite ``Canvas`` rendered under a
/// single rigid camera `.offset` (a pure translate — NEVER a scale, so every libghostty surface keeps
/// `bounds == frame == 1:1` and its points-with-y-flip mouse mapping is unchanged). It:
/// - mounts the kind-aware visible items (terminals never culled; off-viewport video culled),
/// - positions each at its canvas-space frame and applies the camera as one `.offset`,
/// - draws a labeled bounding box behind each ``PaneGroup``'s panes (the Figma-style group frame),
/// - pans via a background drag (both platforms) and trackpad scroll/wheel (macOS),
/// - renders the maximized pane full-viewport when one is set (the old zoom branch),
/// - reports the solved layout (geometric focus), the viewport size, and viewport membership
///   (the video-cap "on screen" signal) back to the store.
///
/// Replaces the recursive `PaneTreeView` and the per-tab canvas. The compact (phone) projection stays
/// the carousel.
struct CanvasView: View {
    let store: WorkspaceStore

    /// Screen-space additive offset applied to the content during a LIVE background pan (before commit).
    /// View `@State` so the per-frame pan never touches the store (the `@GestureState` discipline);
    /// only `.onEnded` / a scroll step commits via ``WorkspaceStore/commitCamera(_:)``.
    @State private var livePan: CGSize = .zero

    /// Whether the background dot grid renders (the ``PaneMenuView`` "Show Grid" toggle).
    @AppStorage(SettingsKey.showGrid) private var showGrid = true

    private static let coordSpace = "canvas"
    /// Outward padding of a group's bounding box around its panes (so the frame doesn't touch the panes).
    private static let groupPadding: CGFloat = 16

    private var canvas: Canvas { store.workspace.canvas }

    var body: some View {
        GeometryReader { geo in
            let camera = canvas.camera
            // The maximized pane, but ONLY if it is actually on the canvas (a dangling id falls back to
            // the normal canvas — load-repair already clears it; this is belt-and-suspenders).
            let maxID: PaneID? = store.workspace.maximizedPane.flatMap { canvas.contains($0) ? $0 : nil }
            ZStack(alignment: .topLeading) {
                // Background pan/scroll catcher — only when NOT maximized (a maximized pane can't be panned).
                if maxID == nil {
                    backgroundPanLayer(camera: camera)
                    // The dot grid (every dot an honest snap site — 32pt dots over the 16pt snap
                    // quantum), riding the SAME total offset the content applies so the dots are
                    // pinned to canvas space. Non-interactive AND not an NSView — every event falls
                    // through to the pan catcher below / the panes above.
                    if showGrid {
                        CanvasGridLayer(
                            offset: CGSize(
                                width: -camera.origin.x + livePan.width + store.liveCameraOffset.width,
                                height: -camera.origin.y + livePan.height + store.liveCameraOffset.height,
                            ),
                            viewport: geo.size,
                        )
                        .allowsHitTesting(false)
                    }
                }
                // ONE always-mounted content path: maximize is per-item GEOMETRY (the maximized pane is
                // sized to the viewport, the others hidden-but-mounted), NOT a separate full-screen
                // subtree. This keeps every pane at its exact SwiftUI identity across maximize/restore, so
                // libghostty surfaces are only RESIZED — never torn down + rebuilt (the prior subtree-swap
                // rebuilt them, replaying stale bytes → garbled glyphs, then crashing on repeated cycles).
                canvasContent(camera: camera, viewport: geo.size, maxID: maxID)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .coordinateSpace(.named(Self.coordSpace))
            .overlay { if maxID == nil,
                          !store.overviewActive { offscreenBeaconLayer(viewport: geo.size, camera: camera) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !store.overviewActive {
                    // The Recenter button's `.transition(.opacity)` had no driver, so it popped. The
                    // fade animation is scoped to the OVERLAY CONTENT (not the outer chain) so it can
                    // never animate the canvas camera `.offset` — addPane's in-view recenter pans the
                    // camera in the same update, and an outer-scoped animation would ease that pan with
                    // the wrong (0.18s) curve. The committed camera feeds `needsRecenter`, so a live
                    // pan doesn't churn it (it flips once on commit).
                    recenterButton(viewport: geo.size)
                        .animation(
                            .easeInOut(duration: 0.18),
                            value: store.workspace.maximizedPane == nil
                                && !canvas.items.isEmpty
                                && canvas.needsRecenter(viewport: geo.size),
                        )
                }
            }
            .overlay { if store.overviewActive { overviewLayer(viewport: geo.size) } }
            // Synchronized-input indicator: broadcast is a global ARMED mode that silently changes what
            // every keystroke does (it fans to the group). It MUST be visible while armed — a top-centre
            // pill naming the reach, tap to disarm. Scoped fade so it never animates the camera offset.
            .overlay(alignment: .top) {
                if store.broadcastActive, !store.overviewActive, maxID == nil {
                    broadcastBanner
                        .padding(.top, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            // Multi-selection count: a small top-leading chip so the active selection (which Arrange /
            // Group / Broadcast all act on) is visible; tap to deselect. Shown for ≥2 (a single focused
            // pane already reads as focused).
            .overlay(alignment: .topLeading) {
                if store.selectedPanes.count >= 2, !store.overviewActive, maxID == nil {
                    selectionChip
                        .padding(.leading, 12)
                        .padding(.top, 12)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: store.selectedPanes.count >= 2)
            .animation(.easeInOut(duration: 0.18), value: store.broadcastActive)
            .animation(.easeInOut(duration: 0.2), value: store.overviewActive)
            .onAppear { report(geo.size, camera: canvas.camera) }
            .onChange(of: geo.size) { _, s in report(s, camera: canvas.camera) }
            .onChange(of: canvas) { _, _ in report(geo.size, camera: canvas.camera) }
            // Maximize is a workspace flag (not on `canvas`), so `.onChange(of: canvas)` does NOT fire —
            // recompute membership here so entering/leaving maximize correctly reports exactly the
            // maximized pane (or the full canvas) and the now-hidden video panes free their slots.
            .onChange(of: store.workspace.maximizedPane) { _, _ in
                // A maximize toggle mid-background-drag dismantles the pan catcher before its mouseUp can
                // clear `livePan` — drop any stale pan so it never offsets the camera-anchored maximized
                // pane off-centre (a `@State`, unlike `moveLive`, it does not auto-reset).
                livePan = .zero
                // Same dismantle hazard for the two live cohort broadcasts: maximize removes the whole
                // `groupLayer` (the group-handle gesture, `if maxID == nil`) and short-circuits the cohort
                // pill's `.onEnded` (`displaySize != nil`) before either can clear its store-side live
                // offset — leaving the group / selected panes rendered permanently shifted. Clear both here.
                store.endGroupHandleDrag()
                store.endGroupDragLive()
                report(geo.size, camera: canvas.camera)
            }
            // When the canvas view disappears (a regular→compact projection flip), clear membership so
            // the compact carousel falls back to `isPaneOnCanvas` instead of inheriting a stale set.
            .onDisappear { store.clearViewportMembership() }
        }
        .background(.background)
    }

    // MARK: Content

    private func canvasContent(camera: CanvasCamera, viewport: CGSize, maxID: PaneID?) -> some View {
        let visible = CanvasGeometry.visibleItems(
            canvas.items,
            camera: camera,
            viewport: viewport,
            focused: store.workspace.focusedPane,
        )
        // Canvas-space rect a maximized pane occupies: viewport-sized (minus a small inset for a thin
        // border), anchored at the camera origin so the single camera `.offset` below lands it exactly
        // on the viewport.
        let maxInset: CGFloat = 4
        let maxSize = CGSize(
            width: max(1, viewport.width - maxInset * 2),
            height: max(1, viewport.height - maxInset * 2),
        )
        return ZStack(alignment: .topLeading) {
            // Group bounding boxes, BEHIND every pane. The dashed frame is decorative (never intercepts);
            // only the move handle + corner resize grips (which live in the clear padding RING outside the
            // member panes) are hit-testable, so panes and the background pan stay interactive through it.
            // Hidden while a pane is maximized — the maximized pane covers the whole plane.
            if maxID == nil {
                groupLayer
                    .zIndex(-1)
            }
            ForEach(visible.sorted { $0.z < $1.z }) { item in
                let isMax = (item.id == maxID)
                // Maximized pane: anchored to the camera so the rigid `.offset` below lands it on the
                // viewport centre. Others: their canvas-space centre (CONSTANT during a pan).
                let pos = isMax
                    ? CGPoint(x: camera.origin.x + viewport.width / 2, y: camera.origin.y + viewport.height / 2)
                    : CGPoint(x: item.frame.midX, y: item.frame.midY)
                CanvasItemView(
                    item: item,
                    store: store,
                    coordSpace: Self.coordSpace,
                    viewportSize: viewport,
                    displaySize: isMax ? maxSize : nil,
                )
                // Lifecycle transition: a new pane scales+fades IN, a closed one scales+fades OUT.
                // Fires ONLY inside the item-id-keyed animation below (a real add/remove), never on
                // pan-culling (the cull changes `visible`, not the full id list → no transaction).
                .transition(.scale(scale: 0.92, anchor: .center).combined(with: .opacity))
                .position(x: pos.x, y: pos.y)
                // Non-overlap MAKE-SPACE (and Tidy / Align / Distribute) spring: a NON-focused pane
                // whose canvas frame changed eases to its new slot — critically damped (no overshoot
                // past the slot, the research's reflow guidance). The focused (dragged / resized /
                // maximized) pane is EXCLUDED so ITS commit stays instant: it carries a live gesture
                // offset that resets to zero on `.onEnded`, and easing its `.position` from the OLD
                // frame while the offset snaps to zero would flash it back to its pre-drag origin. A
                // pure pan moves the camera `.offset`, not `pos`, so this never fires on scroll.
                .animation(
                    store.isFocused(item.id) || isMax ? nil
                        : .spring(response: 0.28, dampingFraction: 1),
                    value: pos,
                )
                // Maximized pane on top of everything; otherwise the focused pane renders above the
                // rest (the pane you are interacting with is on top; the dragged pane is usually the
                // focused one and is raised on commit).
                .zIndex(isMax ? 2_000_000 : (store.isFocused(item.id) ? 1_000_000 : Double(item.z)))
                // While maximized the OTHER panes stay MOUNTED (so their surfaces survive restore with
                // no rebuild → no garbled re-render) but are hidden + non-interactive behind it.
                .opacity(maxID != nil && !isMax ? 0 : 1)
                .allowsHitTesting(maxID == nil || isMax)
                .id(item.id) // LOAD-BEARING (.id(PaneID))
            }
        }
        // Explicit size so `.position` lays out absolutely; off-frame items are NOT clipped here (the
        // outer GeometryReader `.clipped()` clips the viewport), so panned-in panes appear.
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
        // LIFECYCLE ANIMATION (value-scoped, drag-safe): an animation transaction fires ONLY when the
        // canvas's FULL pane-id list changes (a real add / close), so the item transitions above play
        // then. It is keyed to `canvas.items` ids — NOT the culled `visible` list — so a pan (which
        // changes `visible` via culling) creates NO transaction and stays instant; and it is applied
        // here, INSIDE the camera `.offset` below, so the camera pan/drag is never animated by it.
        // Maximize changes per-item geometry, not the id list, so it stays instant too.
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: canvas.items.map(\.id))
        // The ONLY camera application (rigid). `livePan` = a live background DRAG (view @State); the store's
        // `liveCameraOffset` = a live trackpad/wheel SCROLL pan that has not yet committed (BUG-2/BUG-1
        // freeze fix) — both are visual-only, folded into `camera.origin` on commit with no jump.
        .offset(
            x: -camera.origin.x + livePan.width + store.liveCameraOffset.width,
            y: -camera.origin.y + livePan.height + store.liveCameraOffset.height,
        )
    }

    // MARK: Group bounding boxes (the Figma-style labeled frame around each group's panes)

    private var groupLayer: some View {
        ZStack(alignment: .topLeading) {
            ForEach(store.workspace.groups) { group in
                if let box = canvas.groupBoundingBox(group.id) {
                    CanvasGroupView(
                        store: store,
                        group: group,
                        unpaddedBox: box,
                        padding: Self.groupPadding,
                        coordSpace: Self.coordSpace,
                    )
                }
            }
        }
    }

    // MARK: Background pan

    @ViewBuilder
    private func backgroundPanLayer(camera _: CanvasCamera) -> some View {
        #if os(macOS)
        // macOS: a bottom NSView catches scroll-wheel / trackpad-scroll AND empty-background drag to pan
        // (a SwiftUI DragGesture cannot see scroll, and an overlay returning nil from hitTest would get
        // no scroll either — so the catcher sits BEHIND the panes; panes above intercept their own
        // region, and scroll over a terminal still reaches libghostty's scrollback).
        CanvasBackingView(
            onLiveDrag: { livePan = $0 },
            onCommitDrag: { translation in
                // A background click (negligible drag) clears the multi-selection — the standard
                // "click empty space to deselect" idiom.
                if abs(translation.width) < 3, abs(translation.height) < 3 { store.clearSelection() }
                commitPan(translation)
                livePan = .zero
            },
            // Scroll-pan goes through the debounced live accumulator (NOT a per-step commitCamera) so a pan
            // no longer thrashes the canvas re-render + report() cascade that froze the video/cursor.
            onScroll: { delta in store.scrollPan(by: delta) },
        )
        #else
        // iOS: one-finger drag on the empty background pans (a touch that starts on a pane is absorbed by
        // that pane's `.simultaneousGesture(Tap)`, so the background never sees it).
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .named(Self.coordSpace))
                    .onChanged { v in livePan = v.translation }
                    .onEnded { v in commitPan(v.translation)
                        livePan = .zero
                    },
            )
        #endif
    }

    /// Commits a finished background drag: the camera moves OPPOSITE the drag (grab-the-canvas feel), so
    /// the steady offset after commit equals the live offset (no jump).
    private func commitPan(_ translation: CGSize) {
        store.commitCamera(canvas.camera.translated(by: CGSize(width: -translation.width, height: -translation.height)))
    }

    // MARK: Overview (fit-all peek)

    /// The fit-all overview: a dimmed backdrop over the (still-mounted) canvas with a STATIC card per
    /// pane at its scaled position. Static cards — not live-surface `scaleEffect` — deliberately avoid
    /// transforming CAMetalLayer / libghostty surfaces (which tear/blank under SwiftUI scale); the live
    /// canvas sits untouched beneath, so exiting is instant with no surface rebuild. Click a card to
    /// jump+exit; Esc / a backdrop tap exits. (A live-thumbnail overview is a deferred HW-gated idea.)
    @ViewBuilder
    private func overviewLayer(viewport: CGSize) -> some View {
        let layout = CanvasGeometry.overviewLayout(canvas.items, viewport: viewport)
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { store.exitOverview() }
            ForEach(canvas.items) { item in
                if let rect = layout.cards[item.id] {
                    OverviewCard(
                        title: PanePresentation.displayTitle(store.handle(for: item.id), spec: item.spec),
                        kind: item.spec.kind,
                        focused: store.focusedPane == item.id,
                    ) {
                        store.selectFromOverview(item.id)
                    }
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                }
            }
        }
        // Esc exits — a hidden focusable button catches the key without stealing the pane's responder
        // when overview is off (the overlay only mounts while active).
        .background(
            Button("") { store.exitOverview() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0),
        )
        .transition(.opacity)
    }

    // MARK: Off-screen beacons + recenter affordance

    /// Edge-clamped "a pane is over there" pills for every pane entirely outside the viewport — click
    /// pans to centre it. systemDialog beacons PULSE until focused (an off-screen password prompt must
    /// not wait invisibly). Geometry is the pure ``CanvasGeometry/offscreenBeacons(_:camera:viewport:)``;
    /// computed from the COMMITTED camera (not the live drag offset) so it never recomputes per pan frame.
    @ViewBuilder
    private func offscreenBeaconLayer(viewport: CGSize, camera: CanvasCamera) -> some View {
        let beacons = CanvasGeometry.offscreenBeacons(canvas.items, camera: camera, viewport: viewport)
        ForEach(beacons, id: \.id) { beacon in
            let isDialog = canvas.spec(for: beacon.id)?.kind == .systemDialog
            OffscreenBeaconPill(
                title: beacon.id == store.focusedPane
                    ? (canvas.spec(for: beacon.id).map { PanePresentation.displayTitle(
                        store.handle(for: beacon.id),
                        spec: $0,
                    ) } ?? "Pane")
                    : (canvas.spec(for: beacon.id)?.title ?? "Pane"),
                kind: canvas.spec(for: beacon.id)?.kind ?? .terminal,
                edge: beacon.edge,
                pulsing: isDialog && store.focusedPane != beacon.id,
            ) {
                store.revealPane(beacon.id)
            }
            .position(beacon.screenPoint)
        }
        .allowsHitTesting(true)
    }

    @ViewBuilder
    private func recenterButton(viewport: CGSize) -> some View {
        if store.workspace.maximizedPane == nil, canvas.needsRecenter(viewport: viewport), !canvas.items.isEmpty {
            Button {
                store.centerOnAll()
            } label: {
                Label("Recenter", systemImage: "scope")
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding(16)
            .help("Pan back to your panes")
            .transition(.opacity)
        }
    }

    /// The armed-broadcast indicator pill (top-centre): names how many panes a keystroke now reaches and
    /// disarms on tap. The count is resolved live from ``WorkspaceStore/broadcastTargets()`` so it tracks
    /// the focus/selection that defines the target group; "no panes" reads honestly when the focused pane
    /// is not text-capable (e.g. a video pane is focused) so the mode never looks active-but-silent.
    private var broadcastBanner: some View {
        let count = store.broadcastTargets().count
        return Button {
            store.setBroadcast(false)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                Text(count == 0 ? "Broadcasting — no panes in range"
                    : "Broadcasting to \(count) pane\(count == 1 ? "" : "s")")
                    .font(.callout.weight(.medium))
                Text("⇧⌘B").font(.caption2.monospaced()).opacity(0.7)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(.white)
            .background(Color.accentColor, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .help("Synchronized input is on — typing fans out to every pane in the group. Click or press ⇧⌘B to stop.")
    }

    /// The multi-selection count chip (top-leading). Names how many panes are selected — the set that
    /// Arrange / Group / Broadcast act on — and clears the selection on tap.
    private var selectionChip: some View {
        Button {
            store.clearSelection()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.rectangle.stack")
                Text("\(store.selectedPanes.count) selected").font(.callout.weight(.medium))
                Image(systemName: "xmark.circle.fill").opacity(0.7)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .help("\(store.selectedPanes.count) panes selected — click to deselect")
    }

    // MARK: Reporting (geometric focus + viewport + video-cap membership)

    private func report(_ size: CGSize, camera: CanvasCamera) {
        guard size.width > 0, size.height > 0 else { return }
        store.updateViewport(size)
        if let maxID = store.workspace.maximizedPane, canvas.contains(maxID) {
            // Maximize: exactly ONE pane is visible (the others stay MOUNTED but `.opacity(0)` so their
            // surfaces survive restore) → membership is just that pane, so every hidden video pane's
            // `isPaneVisible` flips false and frees its slot. Geometric focus sees the single full pane.
            store.updateViewportMembership([maxID])
            store.updateSolvedLayout(SolvedLayout(frames: [maxID: CGRect(origin: .zero, size: size)]))
        } else {
            store.updateViewportMembership(CanvasGeometry.viewportMembers(canvas.items, camera: camera, viewport: size))
            store.updateSolvedLayout(canvas.solvedLayout()) // canvas-space; FocusResolver consumes unchanged
        }
    }
}

// MARK: - CanvasGridLayer (the dot grid riding the camera)

// MARK: - OffscreenBeaconPill

/// One edge-clamped "a pane is over there" pill: a glass capsule with the pane's kind glyph, a
/// direction arrow toward the off-screen pane, and a truncated title. Clicking pans the canvas to
/// centre that pane. A `pulsing` beacon (an unfocused off-screen system-dialog/password prompt) gently
/// breathes so it can't be missed.
private struct OffscreenBeaconPill: View {
    let title: String
    let kind: PaneKind
    let edge: CanvasGeometry.OffscreenBeacon.Edge
    let pulsing: Bool
    let onTap: () -> Void

    @State private var pulse = false

    private var arrow: String {
        switch edge {
        case .top: "chevron.up"
        case .bottom: "chevron.down"
        case .left: "chevron.left"
        case .right: "chevron.right"
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Image(systemName: arrow).font(.caption2.weight(.bold))
                Image(systemName: PaneLeafView.icon(for: kind)).font(.caption2)
                Text(title).font(.caption2).lineLimit(1).frame(maxWidth: 120)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(
                pulsing ? Color.accentColor : Color.secondary.opacity(0.4),
                lineWidth: pulsing ? 1.5 : 1,
            ))
            .shadow(radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .scaleEffect(pulsing && pulse ? 1.08 : 1.0)
        .opacity(pulsing && pulse ? 1.0 : (pulsing ? 0.82 : 0.95))
        .animation(pulsing ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default, value: pulse)
        .onAppear { if pulsing { pulse = true } }
        .onChange(of: pulsing) { _, now in pulse = now }
        .help(title)
        .accessibilityLabel("Off-screen pane: \(title). Activate to jump to it.")
    }
}

// MARK: - OverviewCard

/// One static pane card in the fit-all overview: a rounded rect at the pane's scaled position carrying
/// its kind glyph + title, accent-bordered when focused. Clicking it jumps to that pane and exits.
private struct OverviewCard: View {
    let title: String
    let kind: PaneKind
    let focused: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                Image(systemName: PaneLeafView.icon(for: kind))
                    .font(.title3)
                    .foregroundStyle(focused ? Color.accentColor : .secondary)
                Text(title)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        focused ? Color.accentColor : Color.secondary.opacity(0.35),
                        lineWidth: focused ? 2 : 1,
                    ),
            )
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel("Pane \(title). Activate to jump to it.")
    }
}

/// The canvas background dot grid: 2pt dots every 32pt of CANVAS space — 2× the 16pt snap quantum
/// (and the 16pt gutter), so every dot is an honest snap site and gutter-tiled panes sit exactly half
/// a cell apart. A snapped pane's origin visibly lands on the lattice.
///
/// Cheap by construction for 60fps pans: the `SwiftUI.Canvas` draws ONE over-sized static tile
/// (viewport + one spacing on each side) whose content depends only on its size + colour scheme — the
/// per-frame pan only changes the `.offset` (a GPU transform, `offset mod spacing`, pixel-rounded so
/// the dots never shimmer between pixel boundaries), never re-running the draw closure.
private struct CanvasGridLayer: View {
    /// The SAME total content offset ``CanvasView`` applies (−camera.origin + live pan/scroll).
    let offset: CGSize
    let viewport: CGSize

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    /// Dot pitch — 2 × ``CanvasSnap/Config/gridSpacing`` (the dots are the visible super-grid of the
    /// snap quantum; phase math stays exact because the quantum divides the pitch).
    static let spacing: CGFloat = 32

    var body: some View {
        let s = Self.spacing
        // The tile itself is an EquatableView whose inputs are frame-stable during a pan (size
        // changes only on window resize; opacity only on a colour-scheme flip) — so the per-frame
        // offset below diffs the tile as unchanged and the dot drawing never re-runs.
        DotGridTile(
            size: CGSize(width: viewport.width + 2 * s, height: viewport.height + 2 * s),
            // Dark canvases swallow contrast — and with no pane borders the dots also help separate
            // near-black terminal panes from the background.
            opacity: colorScheme == .dark ? 0.11 : 0.07,
        )
        .equatable()
        .offset(x: phase(offset.width, s), y: phase(offset.height, s))
    }

    /// The tile offset for a content offset `value`: the positive residue mod `spacing`, shifted one
    /// tile up-left so the over-sized tile always covers the viewport, and rounded to the PIXEL grid
    /// (not the point grid) so a fractional pan never lands dots between pixels (shimmer/moiré).
    private func phase(_ value: CGFloat, _ spacing: CGFloat) -> CGFloat {
        let m = (value.truncatingRemainder(dividingBy: spacing) + spacing).truncatingRemainder(dividingBy: spacing)
        let scale = max(1, displayScale)
        return ((m - spacing) * scale).rounded() / scale
    }
}

/// The static dot tile: pure function of (size, opacity), `Equatable` so SwiftUI provably skips the
/// draw closure while only the parent's `.offset` changes per pan frame.
private struct DotGridTile: View, Equatable {
    let size: CGSize
    let opacity: Double

    private static let dotRadius: CGFloat = 1

    var body: some View {
        SwiftUI.Canvas { context, canvasSize in
            var path = Path()
            var y: CGFloat = 0
            while y <= canvasSize.height {
                var x: CGFloat = 0
                while x <= canvasSize.width {
                    path.addEllipse(in: CGRect(
                        x: x - Self.dotRadius,
                        y: y - Self.dotRadius,
                        width: Self.dotRadius * 2,
                        height: Self.dotRadius * 2,
                    ))
                    x += CanvasGridLayer.spacing
                }
                y += CanvasGridLayer.spacing
            }
            context.fill(path, with: .color(.primary.opacity(opacity)))
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - CanvasGroupView (the interactive labeled frame around a group's panes)

/// The Figma-style group frame drawn behind a ``PaneGroup``'s panes (docs/31), now INTERACTIVE: the
/// dashed box itself is decorative (`.allowsHitTesting(false)`), but the **name-chip move handle** (top
/// leading) drags the whole group as a unit, and the **four corner resize grips** rescale its footprint
/// — both routed through ``CanvasNonOverlap`` so the group slides flush / parts other groups (move) and
/// shoves overlapped neighbours (resize). The grips + handle live in the clear PADDING RING outside the
/// member panes, so panes and the background pan stay fully interactive through the box.
///
/// Live feel: a move broadcasts a raw offset so the members + box follow in real time (``WorkspaceStore``
/// `groupHandleOffset` / `groupBoxOffset`); a resize previews only the box OUTLINE (the members remap on
/// the single `.onEnded` commit, matching the commit-only make-space decision). ⌘ bypasses overlap.
private struct CanvasGroupView: View {
    let store: WorkspaceStore
    let group: PaneGroup
    /// The members' tight bounding box (canvas space). The drawn box is this padded out by `padding`.
    let unpaddedBox: CGRect
    let padding: CGFloat
    let coordSpace: String

    @AppStorage(SettingsKey.nonOverlap) private var nonOverlap = true
    /// Previewed PADDED box during a resize drag (members stay put live; they remap on commit).
    @GestureState private var resizePreview: CGRect?
    /// The overlap config CAPTURED at gesture start, replayed at `.onEnded` so a ⌘ release between the
    /// final drag event and mouse-up cannot flip the committed decision (the pane path's `moveNoOverlap`
    /// discipline, for the group handle + grips).
    @State private var moveOverlapConfig: CanvasNonOverlap.Config?
    @State private var resizeOverlapConfig: CanvasNonOverlap.Config?

    private var paddedBox: CGRect { unpaddedBox.insetBy(dx: -padding, dy: -padding) }
    /// Padded box can't shrink below one min pane plus both rings.
    private var minPaddedSize: CGSize {
        CGSize(width: Canvas.minItemSize.width + 2 * padding, height: Canvas.minItemSize.height + 2 * padding)
    }

    private var overlapConfig: CanvasNonOverlap.Config {
        #if os(macOS)
        if NSEvent.modifierFlags.contains(.command) { return .disabled }
        #endif
        return nonOverlap ? CanvasNonOverlap.Config() : .disabled
    }

    /// Grip footprint == the padding ring depth, so the whole grip sits in the CLEAR ring and no part is
    /// occluded by a member pane reaching the box corner (an 18pt grip overhung the 16pt ring by 2pt).
    private var gripSize: CGFloat { padding }

    var body: some View {
        let liveMove = store.groupBoxOffset(for: group.id)
        let shown = resizePreview ?? paddedBox.offsetBy(dx: liveMove.width, dy: liveMove.height)
        ZStack(alignment: .topLeading) {
            CanvasGroupFrame()
                .frame(width: shown.width, height: shown.height)
                .allowsHitTesting(false)
            nameHandle
            cornerGrip(.topLeading)
            cornerGrip(.topTrailing)
            cornerGrip(.bottomLeading)
            cornerGrip(.bottomTrailing)
        }
        .frame(width: shown.width, height: shown.height, alignment: .topLeading)
        .position(x: shown.midX, y: shown.midY) // canvas-space; rides the same camera offset
    }

    // MARK: Move handle (the name chip)

    private var nameHandle: some View {
        Text(group.name)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5))
            .contentShape(Capsule())
            .padding(.leading, 10)
            .padding(.top, -12) // straddle the top stroke, like a fieldset legend
        #if os(macOS)
            .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
        #endif
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named(coordSpace))
                    .onChanged { v in
                        if moveOverlapConfig == nil { moveOverlapConfig = overlapConfig }
                        let cfg = moveOverlapConfig ?? overlapConfig
                        // Broadcast the SLID offset (not the raw translation) so the members + box glide
                        // flush along neighbours live — matching the rest-flush commit (preview ≡ commit).
                        store.updateGroupHandleDrag(
                            group.id,
                            delta: store.groupSlideOffset(group.id, rawDelta: v.translation, config: cfg),
                        )
                    }
                    .onEnded { v in
                        let cfg = moveOverlapConfig ?? overlapConfig
                        moveOverlapConfig = nil
                        // Instant commit (no `.animation(value: pos)` spring): the members already tracked
                        // the pointer via their live offset, so springing `pos` from the old origin would
                        // flash them backward.
                        var instant = Transaction()
                        instant.disablesAnimations = true
                        withTransaction(instant) {
                            store.endGroupHandleDrag()
                            store.moveGroupNonOverlapping(
                                group.id,
                                snappedBox: unpaddedBox.offsetBy(dx: v.translation.width, dy: v.translation.height),
                                config: cfg,
                            )
                        }
                    },
            )
    }

    // MARK: Corner resize grips (in the clear ring corners)

    private func cornerGrip(_ alignment: Alignment) -> some View {
        let anchor = Self.anchor(for: alignment)
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.accentColor.opacity(0.55))
            .frame(width: gripSize, height: gripSize)
            .contentShape(Rectangle())
        #if os(macOS)
            .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
        #endif
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named(coordSpace))
                    .updating($resizePreview) { v, state, _ in
                        state = CanvasGeometry.resizing(
                            paddedBox,
                            anchor: anchor,
                            by: v.translation,
                            minSize: minPaddedSize,
                        )
                    }
                    .onChanged { _ in if resizeOverlapConfig == nil { resizeOverlapConfig = overlapConfig } }
                    .onEnded { v in
                        let cfg = resizeOverlapConfig ?? overlapConfig
                        resizeOverlapConfig = nil
                        let newPadded = CanvasGeometry.resizing(
                            paddedBox,
                            anchor: anchor,
                            by: v.translation,
                            minSize: minPaddedSize,
                        )
                        store.resizeGroupNonOverlapping(
                            group.id,
                            newBox: newPadded.insetBy(dx: padding, dy: padding),
                            config: cfg,
                        )
                    },
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    private static func anchor(for alignment: Alignment) -> ResizeAnchor {
        switch alignment {
        case .topLeading: .topLeft
        case .topTrailing: .topRight
        case .bottomLeading: .bottomLeft
        default: .bottomRight
        }
    }
}

/// The bare decorative group frame: a dashed rounded rectangle with a faint fill (no name, no
/// interaction — the parent ``CanvasGroupView`` overlays the interactive handle + grips).
private struct CanvasGroupFrame: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.secondary.opacity(0.05)),
            )
    }
}

// MARK: - CanvasBackingView (macOS scroll + background-drag pan)

#if os(macOS)
import AppKit

/// The macOS background pan surface: a bottom NSView that converts trackpad/wheel scroll AND an
/// empty-background mouse drag into camera pans (docs/30 §6.3). It sits BEHIND the panes so a click /
/// scroll over a pane reaches the pane (libghostty mouseDown + terminal scrollback), and only
/// empty-background events reach it. The `WindowWidthReader` drop-to-AppKit idiom.
private struct CanvasBackingView: NSViewRepresentable {
    /// Called repeatedly during a background drag with the running translation (screen-space).
    let onLiveDrag: (CGSize) -> Void
    /// Called once on mouse-up with the final translation.
    let onCommitDrag: (CGSize) -> Void
    /// Called per scroll step with the camera delta to apply (already sign-adjusted for natural scroll).
    let onScroll: (CGSize) -> Void

    func makeNSView(context _: Context) -> NSView {
        PanView(onLiveDrag: onLiveDrag, onCommitDrag: onCommitDrag, onScroll: onScroll)
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        guard let v = nsView as? PanView else { return }
        v.onLiveDrag = onLiveDrag
        v.onCommitDrag = onCommitDrag
        v.onScroll = onScroll
    }

    final class PanView: NSView {
        var onLiveDrag: (CGSize) -> Void
        var onCommitDrag: (CGSize) -> Void
        var onScroll: (CGSize) -> Void
        private var dragStart: NSPoint?

        init(
            onLiveDrag: @escaping (CGSize) -> Void,
            onCommitDrag: @escaping (CGSize) -> Void,
            onScroll: @escaping (CGSize) -> Void,
        ) {
            self.onLiveDrag = onLiveDrag
            self.onCommitDrag = onCommitDrag
            self.onScroll = onScroll
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError("init(coder:) not used") }

        // Bottom layer: receives only events not consumed by a pane above it.
        override func scrollWheel(with event: NSEvent) {
            let dx: CGFloat, dy: CGFloat
            if event.hasPreciseScrollingDeltas {
                dx = event.scrollingDeltaX
                dy = event.scrollingDeltaY
            } else {
                dx = event.scrollingDeltaX * 10
                dy = event.scrollingDeltaY * 10
            }
            // Natural scroll: the content follows the fingers, so the camera moves opposite the scroll.
            onScroll(CGSize(width: -dx, height: -dy))
        }

        override func mouseDown(with event: NSEvent) {
            dragStart = convert(event.locationInWindow, from: nil)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = dragStart else { return }
            let p = convert(event.locationInWindow, from: nil)
            // AppKit y grows UP; SwiftUI / canvas y grows DOWN → flip dy so a drag feels natural.
            onLiveDrag(CGSize(width: p.x - start.x, height: -(p.y - start.y)))
        }

        override func mouseUp(with event: NSEvent) {
            guard let start = dragStart else { return }
            let p = convert(event.locationInWindow, from: nil)
            onCommitDrag(CGSize(width: p.x - start.x, height: -(p.y - start.y)))
            dragStart = nil
        }
    }
}
#endif
#endif
