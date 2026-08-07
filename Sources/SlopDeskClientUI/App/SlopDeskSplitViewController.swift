// SlopDeskSplitViewController — the macOS shell. An `NSSplitViewController` with
// two `NSSplitViewItem`s (sidebar | content), each an `NSHostingController` over a
// SwiftUI column. Modelled on CodeEdit's `CodeEditSplitViewController`: an AppKit split shell with SwiftUI
// INSIDE each column. Keeping the split in AppKit (not a SwiftUI `HSplitView` that rebuilds subtrees) is the
// load-bearing no-teardown choice for L2's libghostty panes — a torn-down NSView kills the surface.
// There is no Details column — the app is keyboard-centric; the Git details window opens from the
// palette / View menu instead.

#if os(macOS)
import AppKit
import Defaults
import ObjectiveC
import SlopDeskWorkspaceCore
import SwiftUI

final class SlopDeskSplitViewController: NSSplitViewController {
    private let store: WorkspaceStore
    private let connection: AppConnection
    private let chrome: WorkspaceChromeState
    /// The live ``PreferencesStore`` — forwarded into the sidebar's ``NavigatorColumn`` so the tab context menu
    /// can surface the host-LOCAL "Prevent Sleep While Processing" flag. The sidebar is hosted in a
    /// SEPARATE `NSHostingController` that does not inherit the WindowGroup `\.preferencesStore` environment, so
    /// it is threaded explicitly. `nil` (a preview / pre-injection scene) hides the Prevent-Sleep row.
    private let preferences: PreferencesStore?
    /// Opens the Connect-to-Host editor — wired into the titlebar's connection-status cluster. The shell
    /// binds this to `overlay.openConnect()`; the no-op default keeps the controller buildable without
    /// an overlay.
    private let onConnect: () -> Void
    /// The scene ``OverlayCoordinator`` — re-injected into BOTH hosted columns' environments
    /// (`\.overlayCoordinator`): like `preferences`, the columns' separate `NSHostingController`s do not
    /// inherit the WindowGroup environment, and the connection cluster (sidebar footer + titlebar
    /// trailing) reads the coordinator's prefix-ARMED flag for its pill swap. `nil` (previews/tests)
    /// simply never shows the armed pill.
    private let overlay: OverlayCoordinator?
    /// The cross-container pane-drag rendezvous — threaded into BOTH columns (the sidebar's rows are
    /// drop targets; the canvas is the drag source + the satellite-drop target). The two columns live in
    /// SEPARATE hosting views, which is exactly why this shared object exists. `nil` (previews/tests)
    /// keeps the pane drag canvas-only.
    private let paneDrag: PaneDragCoordinator?

    /// Retained so the titlebar toggle can animate its collapse (set in `viewDidLoad`).
    private var sidebarItem: NSSplitViewItem?
    /// The RIGHT code panel (project-scoped embedded VS Code) — retained like `sidebarItem` so
    /// `applyCollapse` can animate it.
    private var codeSidebarItem: NSSplitViewItem?

    /// The sidebar (TABS panel) default thickness, shared with
    /// the window-size glue (`SlopDeskClientApp.applyInitialWindowSize`) so the `grid` mode's `chromeOverhead`
    /// uses the SAME width the split item adopts (no magic-number drift between the layout and the math).
    static let defaultSidebarWidth: CGFloat = 220

    /// The centre column's floor.
    static let contentMinWidth: CGFloat = 420

    /// The code panel's floor — wide enough for a usable VS Code workbench (activity bar + explorer +
    /// an editor column); anything narrower collapses the workbench into its mobile layout.
    static let codeSidebarMinWidth: CGFloat = 380

    init(
        store: WorkspaceStore,
        connection: AppConnection,
        chrome: WorkspaceChromeState,
        preferences: PreferencesStore? = nil,
        onConnect: @escaping () -> Void = {},
        overlay: OverlayCoordinator? = nil,
        paneDrag: PaneDragCoordinator? = nil,
    ) {
        self.store = store
        self.connection = connection
        self.chrome = chrome
        self.preferences = preferences
        self.onConnect = onConnect
        self.overlay = overlay
        self.paneDrag = paneDrag
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported — SlopDeskSplitViewController is created in code")
    }

    /// Coalesces the bursts of `NSSplitView.didResizeSubviewsNotification` a divider (or window-edge) drag
    /// emits: `true` once the burst starts, flipped back `false` `resizeSettleDelay` after it stops.
    private var resizeForwardingSuspended = false
    private var resizeSettleWork: DispatchWorkItem?
    private let resizeSettleDelay: TimeInterval = 0.1

    override func viewDidLoad() {
        super.viewDidLoad()

        splitView.dividerStyle = .thin
        // FLAT DIVIDER: the default `.thin` NSSplitView draws its divider PURE BLACK in `drawDivider(in:)`,
        // a harsh blacked-out seam on the lighter theme chrome. We cannot subclass `NSSplitView` via `loadView`
        // (it traps `_setupSplitView` during the controller's constraint setup — see the OBSERVE note below),
        // so we let the controller build its default split view, then ISA-SWIZZLE that fully-set-up instance
        // to a subclass that ONLY overrides `drawDivider(in:)` to fill the divider with the flat theme
        // backdrop. `object_setClass` is memory-safe here — `FlatDividerSplitView` adds no stored properties
        // (identical ivar layout) — and side-steps the constructor path that traps.
        object_setClass(splitView, FlatDividerSplitView.self)

        // 1) Sidebar — the navigator (sessions / panes), FLAT on the one window field
        //    (user-directed 2026-08-07, islands round: "the whole floor under the island must be ONE
        //    colour" — the earlier `.sidebar` NSVisualEffectView material gave this column its own
        //    vibrancy tone and a visible seam against the content field, which is exactly the mixed
        //    figure-ground the round removed; both references, JetBrains Islands and Canario, run one
        //    flat field under everything). A PLAIN split item rather than `sidebarWithViewController:`
        //    — the automatic sidebar treatment brings its own collapse/glass behaviours that fight the
        //    swizzled 3-column divider machinery below. Holding priority above the content's default
        //    so window-resize grows the content, not the sidebar.
        let navigator = NSHostingController(rootView: NavigatorColumn(
            store: store, preferences: preferences, chrome: chrome,
            connection: connection, paneDrag: paneDrag, onConnect: onConnect,
        ).overlayCoordinator(overlay))
        let sidebarItem = NSSplitViewItem(viewController: navigator)
        sidebarItem.minimumThickness = Self.defaultSidebarWidth
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)

        // 2) Content — the pane grid (terminal / desktop / remote window) + the hover-reveal titlebar
        //    overlay. The non-collapsible centre. `chrome` drives the titlebar's sidebar toggle; `onConnect`
        //    wires the titlebar's connection-status cluster to the Connect-to-Host editor.
        let content = NSHostingController(
            rootView: ContentColumn(
                store: store, connection: connection, chrome: chrome, onConnect: onConnect,
                paneDrag: paneDrag,
            )
            .overlayCoordinator(overlay),
        )
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = Self.contentMinWidth

        // Each column hosts SwiftUI in its own NSHostingController, which by DEFAULT insets its content below
        // the window's titlebar safe area (the traffic-light strip). With `.hiddenTitleBar` that pushed every
        // column's top chrome — the hover-reveal titlebar's controls, and the sidebar's
        // "TABS" header — a full row BELOW the traffic lights. Dropping the safe-area regions lets each column
        // start at the window's top edge, so the titlebar's controls land ON the traffic-light row (each
        // column still reserves its own titlebar-height strip at the top).
        // 3) Code panel — the RIGHT sidebar: the project-scoped embedded VS Code (code-server in a
        //    pooled WKWebView, `CodeSidebarColumn`). A PLAIN trailing split item, deliberately NOT
        //    `NSSplitViewItem(inspectorWithViewController:)` — the inspector style's collapse tears the
        //    hosted view down, which would kill the webview; a plain item just unparents it while the
        //    pooled WKWebView (and its web-content process) survives for a warm re-expand. Same holding
        //    priority as the left sidebar so a window resize grows the CONTENT column.
        let codeColumn = NSHostingController(
            rootView: CodeSidebarColumn(
                store: store, connection: connection, chrome: chrome, preferences: preferences,
            )
            .overlayCoordinator(overlay),
        )
        let codeSidebarItem = NSSplitViewItem(viewController: codeColumn)
        codeSidebarItem.minimumThickness = Self.codeSidebarMinWidth
        codeSidebarItem.canCollapse = true
        codeSidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
        // Seed the collapse from the persisted chrome flag BEFORE the item is added — the panel is
        // opt-in (default hidden), and letting the representable's first update collapse it would
        // flash a fully-expanded column on every launch.
        codeSidebarItem.isCollapsed = chrome.codeSidebarCollapsed

        navigator.safeAreaRegions = []
        content.safeAreaRegions = []
        codeColumn.safeAreaRegions = []

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        addSplitViewItem(codeSidebarItem)

        self.sidebarItem = sidebarItem
        self.codeSidebarItem = codeSidebarItem

        // Defer remote terminal grid-resize forwarding while a sidebar divider (or the window edge)
        // is being dragged: NSSplitView re-lays its subviews every step and posts this notification, so each
        // step would otherwise be a host PTY reflow + a re-streamed redraw. We pause forwarding on the first
        // step and flush the FINAL grid once the drag settles (see `splitViewSubviewsDidResize`). We OBSERVE
        // the default split view rather than subclassing it — a custom `NSSplitView` destabilises
        // `NSSplitViewController._setupSplitView` and traps during constraint setup.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(splitViewSubviewsDidResize(_:)),
            name: NSSplitView.didResizeSubviewsNotification,
            object: splitView,
        )

        // D3: SwiftUI `@Environment`/`.preferredColorScheme` does NOT cross into the
        // `NSHostingController` columns, so a runtime theme change can't be observed inside them. Observe
        // the appearance-changed notification (posted by the `AppearanceApplier` hook after it repoints
        // `ThemeStore.shared`) and re-pin the WINDOW appearance + nudge each column to re-read the tokens —
        // otherwise the window half-repaints (the chrome flips but the columns keep the old palette).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: ThemeStore.didChangeNotification,
            object: nil,
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Resume terminal grid-resize forwarding if the column disappears mid-drag. The settle that resumes it is
    /// a `[weak self]` work item fired ~`resizeSettleDelay` after the last step; were this controller torn down
    /// inside that window (window closed mid-resize), the work item would early-return on the nil `self` and
    /// leave forwarding suspended (the next session on the SAME store would never flush its grid). Resuming
    /// here on a real lifecycle hook (not a timer) closes that gap.
    override func viewWillDisappear() {
        super.viewWillDisappear()
        guard resizeForwardingSuspended else { return }
        resizeSettleWork?.cancel()
        resizeForwardingSuspended = false
        store.setTerminalResizeSuspended(false)
    }

    /// One step of a divider/window-edge resize burst: suspend remote terminal resize forwarding on the first
    /// step, then (re)arm a settle timer that resumes + flushes the final grid `resizeSettleDelay` after the
    /// last step — i.e. when the drag is released. Commit-on-release, without subclassing the split view.
    @objc
    private func splitViewSubviewsDidResize(_: Notification) {
        if !resizeForwardingSuspended {
            resizeForwardingSuspended = true
            store.setTerminalResizeSuspended(true)
        }
        resizeSettleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            resizeForwardingSuspended = false
            store.setTerminalResizeSuspended(false) // flush the grid the drag settled on
        }
        resizeSettleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + resizeSettleDelay, execute: work)
    }

    /// Pin the WINDOW's appearance to the active theme. The columns are hosted in
    /// `NSHostingController`s inside this AppKit split controller, so they do NOT inherit the SwiftUI
    /// `.preferredColorScheme` set on `WorkspaceRootView` — any system-dynamic colour / material in a column
    /// would otherwise resolve to the OS appearance and clash with the pinned theme palette (e.g. white text
    /// on the light Paper chrome when the user's Mac is in Dark mode). Setting it on the NSWindow propagates
    /// to every hosted NSView. Done in `viewDidAppear` because the window only exists once attached.
    override func viewDidAppear() {
        super.viewDidAppear()
        pinWindowAppearance()
        // A panel expanded AT LAUNCH must come back at its persisted width — the split item's
        // thickness is session state AppKit never saves. (An expand-toggle mid-session restores via
        // `applyItemCollapse`'s completion instead.) Here the window frame is final.
        restoreCodeSidebarWidth()
    }

    /// Re-apply the persisted code-panel width (`Defaults[.codeSidebarWidth]`, written when a
    /// divider drag settles). No-op while collapsed, on a never-dragged install (`0`), or when the
    /// panel already sits within a point of the target. The saved width runs through the SAME clamp
    /// as a live drag, so a smaller screen degrades to the widest position both floors allow.
    private func restoreCodeSidebarWidth() {
        let saved = CGFloat(Defaults[.codeSidebarWidth])
        guard saved > 0,
              codeSidebarItem?.isCollapsed == false,
              splitView.arrangedSubviews.count == 3,
              let panel = splitView.arrangedSubviews.last
        else { return }
        guard abs(panel.frame.width - saved) > 1 else { return }
        let target = Self.clampedCodeDividerPosition(
            proposed: splitView.bounds.width - splitView.dividerThickness - saved,
            contentMinX: splitView.arrangedSubviews[1].frame.minX,
            splitWidth: splitView.bounds.width,
            dividerThickness: splitView.dividerThickness,
        )
        splitView.setPosition(target, ofDividerAt: 1)
    }

    /// Refresh the window-level chrome. The window carries NO pin of its own (`appearance = nil`):
    /// since the whole-app theme round (user-directed 2026-08-07) the pin lives at the APP level —
    /// `ThemeStore.pinAppAppearance` sets `NSApp.appearance` from the active theme's polarity, and
    /// every window (this one, Settings, overlays) inherits it. Only the split view's divider layer
    /// needs an explicit refresh here.
    private func pinWindowAppearance() {
        // Clear any historic per-window pin (an upgraded install's window may still carry one) so
        // the app-level pin is the one voice.
        view.window?.appearance = nil
        // The sidebar/content divider is the 1px GAP between the hosting columns. It is painted TWO ways that
        // must agree: `FlatDividerSplitView.drawDivider(in:)` fills it, AND (once the split view is layer-backed
        // for its `NSHostingController` columns) the gap also shows this layer `backgroundColor`. Both wear the
        // ONE field tone every column paints (`Slate.Surface.fieldNSColor`) — so the seam is deliberately
        // invisible: the islands' margins are the only structure the floor shows.
        //
        // Repaint on a RUNTIME profile/appearance change: `drawDivider` pixels are CACHED in the layer; a
        // plain `needsDisplay` does NOT re-invoke it for the divider rect. `layer?.setNeedsDisplay()`
        // invalidates the drawn content so `drawDivider` re-runs; `displayIfNeeded()` forces it synchronously.
        splitView.wantsLayer = true
        // The floor is a FIXED colour per profile (no appearance-dependent resolution), so this
        // `.cgColor` cannot go stale on an appearance flip — it only needs re-assigning when the
        // PROFILE changes, which is exactly when this method runs (`themeDidChange`).
        splitView.layer?.backgroundColor = Slate.Surface.fieldNSColor.cgColor
        splitView.needsDisplay = true
        splitView.layer?.setNeedsDisplay()
        splitView.displayIfNeeded()
    }

    /// React to a runtime terminal-profile switch (the `AppearanceApplier` hook already repointed
    /// `ThemeStore.shared`). Refresh the divider layer AND force each hosted column to re-read the
    /// glass tokens — a SwiftUI `@Observable` change inside `ThemeStore` re-renders views that READ
    /// it, but the AppKit seam must be refreshed explicitly here (the boundary SwiftUI observation
    /// does not cross). `needsDisplay` on each column view nudges a redraw so no pane is left
    /// half-painted in the old palette.
    @objc
    private func themeDidChange() {
        pinWindowAppearance()
        for item in splitViewItems {
            item.viewController.view.needsDisplay = true
        }
    }

    /// Apply the chrome collapse flags to both flanking items (idempotent — only animates
    /// a real change so a steady-state update doesn't re-trigger the animation).
    func applyCollapse(sidebarCollapsed: Bool, codeSidebarCollapsed: Bool) {
        applyItemCollapse(sidebarItem, collapsed: sidebarCollapsed)
        applyItemCollapse(codeSidebarItem, collapsed: codeSidebarCollapsed)
    }

    private func applyItemCollapse(_ item: NSSplitViewItem?, collapsed: Bool) {
        guard let item, item.isCollapsed != collapsed else { return }
        // LOST-PROMPT FIX: `animator().isCollapsed = …` applies the FIRST collapse-animation layout frame
        // SYNCHRONOUSLY, which fires `GhosttyLayerBackedView.layout()` and forwards an INTERMEDIATE grid
        // size to the host BEFORE `splitViewSubviewsDidResize` (the notification) suspends forwarding. That
        // premature SIGWINCH makes zsh run `zle reset-prompt` at the wrong width, double-firing against the
        // final-width reset and erasing the prompt line. Suspend FIRST so the intermediate frames are held;
        // the settle timer in `splitViewSubviewsDidResize` resumes + flushes the FINAL grid (the
        // idempotency guard in `setResizeSuspended` prevents a double-flush).
        resizeForwardingSuspended = true
        store.setTerminalResizeSuspended(true)
        // The code panel re-expands at its persisted width — applied in the animation's completion
        // (a `setPosition` mid-animation is overridden by the collapse animation's final frame).
        // The left sidebar restores nothing: its width is capped/session-scoped by design.
        if item === codeSidebarItem, !collapsed {
            NSAnimationContext.runAnimationGroup { _ in
                item.animator().isCollapsed = collapsed
            } completionHandler: { [weak self] in
                // Fires on the main thread; the handler's type is just not annotated.
                MainActor.assumeIsolated { self?.restoreCodeSidebarWidth() }
            }
        } else {
            item.animator().isCollapsed = collapsed
        }
    }
}

/// A drop-in `NSSplitView` whose ONLY change is a flat, theme-coloured divider — installed via
/// `object_setClass` onto the controller's already-built split view (so it never goes through the
/// `NSSplitViewController` construction path that traps `_setupSplitView` when a custom split view is
/// supplied up front). `drawDivider(in:)` fills the 1px `.thin` divider rect with the active theme backdrop,
/// so the sidebar/content seam blends into the flat chrome instead of AppKit's default pure-black
/// hairline. Adds NO stored properties — the isa-swizzle keeps the original instance's ivar layout intact.
private final class FlatDividerSplitView: NSSplitView {
    /// Re-assign the divider gap's layer colour when the OS appearance flips. The floor colour is
    /// FIXED per profile now, so the assignment itself cannot resolve stale — but under the System
    /// theme an OS flip re-resolves ``ThemeStore/active`` to the other built-in, and this hook is the
    /// AppKit-side nudge that re-reads the new profile's floor (the SwiftUI columns re-render on
    /// their own; the layer does not).
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = Slate.Surface.fieldNSColor.cgColor
        needsDisplay = true
        layer?.setNeedsDisplay()
    }

    override func drawDivider(in rect: NSRect) {
        // NO drawn seam (user-directed 2026-08-07, islands round): every column paints the SAME
        // field tone and the islands float on it — a hard hairline between columns would cut the
        // window back into boxes. The divider strip wears that same field colour (resolved in the
        // view's current appearance), so the gap is literally invisible: three columns, one
        // uninterrupted floor.
        Slate.Surface.fieldNSColor.setFill()
        NSBezierPath(rect: rect).fill()
    }

    /// The CODE-panel divider (content | code) is dragged by hand, not by AppKit's built-in
    /// constraint tracking — the host-rail lesson, restored with the panel. AppKit's
    /// `_doConstraintBasedDragDivider` pins the drag at a priority derived from the LEADING item's
    /// holding priority, so a trailing item that holds HARDER than its leading neighbour (panel 260
    /// > content 250 — deliberate, window-resize must feed the content) can never be grown by its
    /// divider: the engine grows a hole at the split view's 749-priority trailing glue instead and
    /// snaps everything back on release. The left divider is immune (its growing item is the
    /// LEADING side). So for this divider we run the standard event-tracking loop ourselves and
    /// place the divider each step via `setPosition(_:ofDividerAt:)`, which AppKit applies at a
    /// priority the holds cannot veto.
    override func mouseDown(with event: NSEvent) {
        guard let divider = codeDividerIndex(under: event) else {
            super.mouseDown(with: event)
            return
        }
        trackCodeDividerDrag(with: event, dividerIndex: divider)
    }

    /// The code divider's index iff `event` grabs it: the LAST divider of a 3-column layout, hit
    /// within the same ±few-pt slop AppKit's own hit-test claims for a `.thin` divider. A
    /// COLLAPSED panel bows out (its divider is hidden; a click 4 pt from the window edge is a
    /// content click, and drag-to-expand would desync the chrome collapse flag).
    private func codeDividerIndex(under event: NSEvent) -> Int? {
        guard arrangedSubviews.count == 3,
              (delegate as? NSSplitViewController)?.splitViewItems.last?.isCollapsed == false
        else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        guard dividerEffectiveRect(at: 1).insetBy(dx: -4, dy: 0).contains(point) else { return nil }
        return 1
    }

    private func trackCodeDividerDrag(with event: NSEvent, dividerIndex: Int) {
        guard let window else { return }
        let grabX = convert(event.locationInWindow, from: nil).x
        let startPosition = arrangedSubviews[dividerIndex].frame.maxX
        dividerCursor(at: dividerIndex).push()
        defer {
            NSCursor.pop()
            // Rebuild the hover cursors for the widths the drag settled on (a drag that ends
            // pinned at a limit must immediately hover as one-directional).
            window.invalidateCursorRects(for: self)
            // Persist the settled panel width — the ONLY gesture that changes it (window resizes
            // hold the panel at its width via the holding priorities), so save-on-release is the
            // complete write set for the restore in `restoreCodeSidebarWidth`.
            if let panel = arrangedSubviews.last {
                Defaults[.codeSidebarWidth] = Double(panel.frame.width)
            }
        }
        while true {
            guard let next = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture, inMode: .eventTracking, dequeue: true,
            ) else { continue }
            if next.type == .leftMouseUp { return }
            let x = convert(next.locationInWindow, from: nil).x
            let target = clampCodeDividerPosition(startPosition + (x - grabX))
            setPosition(target, ofDividerAt: dividerIndex)
            window.layoutIfNeeded()
            // Track the limit state live: pinned at min/max shows the one-way arrow mid-drag too.
            dividerCursor(at: dividerIndex).set()
        }
    }

    private func clampCodeDividerPosition(_ proposed: CGFloat) -> CGFloat {
        SlopDeskSplitViewController.clampedCodeDividerPosition(
            proposed: proposed,
            contentMinX: arrangedSubviews[1].frame.minX,
            splitWidth: bounds.width,
            dividerThickness: dividerThickness,
        )
    }

    /// Divider `i`'s grab region: the gap between its neighbours, run through the delegate's
    /// `effectiveRect` refinement when offered (NSSplitViewController trims the titlebar strip off
    /// the top — a grab there belongs to window dragging, and the hover cursor must agree).
    private func dividerEffectiveRect(at i: Int) -> NSRect {
        let gapLeading = arrangedSubviews[i].frame.maxX
        let gapTrailing = arrangedSubviews[i + 1].frame.minX
        let drawn = NSRect(
            x: gapLeading, y: 0, width: gapTrailing - gapLeading, height: bounds.height,
        )
        return delegate?.splitView?(self, effectiveRect: drawn, forDrawnRect: drawn, ofDividerAt: i)
            ?? drawn
    }

    // MARK: Divider hover cursors (owned — AppKit's lie at the minimum)

    /// Install our OWN divider cursor rects instead of AppKit's. AppKit picks the two-way vs
    /// one-way resize arrow from its notion of movability, which counts drag-to-collapse as "can
    /// still move": an item AT its minimum next to a `canCollapse` neighbour keeps the two-way
    /// arrow even though this app never collapses by shoving a divider (collapse belongs to the
    /// toggles). At the MAXIMUM AppKit already shows the one-way arrow, so the two limits read
    /// inconsistently. We derive movability purely from the items' width ranges
    /// (`SlopDeskSplitViewController.dividerMovability`), so both limits wear the one-way arrow.
    /// The rect mirrors the divider gap widened by the same ±few-pt slop the hit-testing claims; a
    /// divider beside a collapsed item gets no rect (it is hidden).
    override func resetCursorRects() {
        guard let items = (delegate as? NSSplitViewController)?.splitViewItems,
              items.count == arrangedSubviews.count
        else {
            super.resetCursorRects()
            return
        }
        for i in 0..<max(arrangedSubviews.count - 1, 0) {
            if items[i].isCollapsed || items[i + 1].isCollapsed { continue }
            addCursorRect(
                dividerEffectiveRect(at: i).insetBy(dx: -2, dy: 0),
                cursor: dividerCursor(at: i),
            )
        }
    }

    /// The hover/drag cursor for divider `i`, from pure width-range movability.
    private func dividerCursor(at i: Int) -> NSCursor {
        guard let items = (delegate as? NSSplitViewController)?.splitViewItems,
              items.count == arrangedSubviews.count, i + 1 < items.count
        else { return .resizeLeftRight }
        let movability = SlopDeskSplitViewController.dividerMovability(
            leadingWidth: arrangedSubviews[i].frame.width,
            leadingMin: items[i].minimumThickness,
            leadingMax: items[i].maximumThickness,
            trailingWidth: arrangedSubviews[i + 1].frame.width,
            trailingMin: items[i + 1].minimumThickness,
            trailingMax: items[i + 1].maximumThickness,
        )
        switch (movability.left, movability.right) {
        case (true, true): return .resizeLeftRight
        case (true, false): return .resizeLeft
        case (false, true): return .resizeRight
        // Wedged (both neighbours at their floors in an over-tight window): the two-way arrow is
        // the least-wrong glyph — there is no "no resize" cursor, and a plain arrow over a divider
        // reads as a dead zone.
        case (false, false): return .resizeLeftRight
        }
    }
}

extension SlopDeskSplitViewController {
    /// Clamp a proposed code-divider position to the band both floors allow: the content keeps at
    /// least ``contentMinWidth`` and the panel at least ``codeSidebarMinWidth`` (no upper cap — the
    /// workbench happily takes half the window). Drag-to-collapse is deliberately not offered — the
    /// panel HIDES via its toggle (⌘⇧R / titlebar / palette), never by shoving the divider. In an
    /// over-constrained window (both floors cannot hold) the PANEL's floor wins: the divider can
    /// then only be pushed toward the panel's floor, never below it.
    static func clampedCodeDividerPosition(
        proposed: CGFloat, contentMinX: CGFloat, splitWidth: CGFloat, dividerThickness: CGFloat,
    ) -> CGFloat {
        let lowest = contentMinX + contentMinWidth
        let highest = splitWidth - dividerThickness - codeSidebarMinWidth
        return CGFloat.minimum(CGFloat.maximum(proposed, lowest), highest)
    }

    /// Whether a divider can move each way, PURELY from its neighbours' width ranges — no
    /// drag-to-collapse affordance (this app collapses via toggles only, so a divider pinned at a
    /// limit really is immovable that way and the cursor must say so). Moving LEFT shrinks the
    /// leading item and grows the trailing one; RIGHT is the mirror. `NSSplitViewItem`'s
    /// "unspecified" maximum arrives as a negative sentinel — treated as unbounded. Widths compare
    /// with a half-point tolerance (layout rounds to the pixel grid).
    static func dividerMovability(
        leadingWidth: CGFloat, leadingMin: CGFloat, leadingMax: CGFloat,
        trailingWidth: CGFloat, trailingMin: CGFloat, trailingMax: CGFloat,
    ) -> (left: Bool, right: Bool) {
        let slack: CGFloat = 0.5
        let leadingCeiling = leadingMax < 0 ? CGFloat.infinity : leadingMax
        let trailingCeiling = trailingMax < 0 ? CGFloat.infinity : trailingMax
        let left = leadingWidth > leadingMin + slack && trailingWidth < trailingCeiling - slack
        let right = leadingWidth < leadingCeiling - slack && trailingWidth > trailingMin + slack
        return (left, right)
    }
}

#endif
