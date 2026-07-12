// SlopDeskSplitViewController — the macOS shell. An `NSSplitViewController` with
// two `NSSplitViewItem`s (sidebar | content), each an `NSHostingController` over a SwiftUI
// column. Modelled on CodeEdit's `CodeEditSplitViewController`: an AppKit split shell with SwiftUI INSIDE
// each column. Keeping the split in AppKit (not a SwiftUI `HSplitView` that rebuilds subtrees) is the
// load-bearing no-teardown choice for L2's libghostty panes — a torn-down NSView kills the surface.
// There is no right-hand inspector / Details column — the app is keyboard-centric; the Git details
// window opens from the palette / View menu instead.

#if os(macOS)
import AppKit
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

    /// Retained so the titlebar toggle can animate its collapse (set in `viewDidLoad`).
    private var sidebarItem: NSSplitViewItem?
    /// The RIGHT Host Windows rail (docs/45) — retained like `sidebarItem` so `applyCollapse` can
    /// animate it. A third PLAIN split item (never `.inspector` — that unmounts content and kills
    /// live video panes; a plain sibling item never remounts the centre column).
    private var hostRailItem: NSSplitViewItem?
    /// The host-windows feed store (app-owned) the rail column renders. `nil` (tests/previews)
    /// skips mounting the rail entirely.
    private let hostWindowFeed: HostWindowFeed?

    /// The sidebar (TABS panel) default thickness, shared with
    /// the window-size glue (`SlopDeskClientApp.applyInitialWindowSize`) so the `grid` mode's `chromeOverhead`
    /// uses the SAME width the split item adopts (no magic-number drift between the layout and the math).
    static let defaultSidebarWidth: CGFloat = 220

    /// The centre column's floor — shared between the split item and the rail divider's manual
    /// drag clamp (`FlatDividerSplitView.clampRailDividerPosition`) so they can never disagree.
    static let contentMinWidth: CGFloat = 420

    init(
        store: WorkspaceStore,
        connection: AppConnection,
        chrome: WorkspaceChromeState,
        preferences: PreferencesStore? = nil,
        hostWindowFeed: HostWindowFeed? = nil,
        onConnect: @escaping () -> Void = {},
    ) {
        self.store = store
        self.connection = connection
        self.chrome = chrome
        self.preferences = preferences
        self.hostWindowFeed = hostWindowFeed
        self.onConnect = onConnect
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
        // a harsh blacked-out seam on the lighter Monokai chrome. We cannot subclass `NSSplitView` via `loadView`
        // (it traps `_setupSplitView` during the controller's constraint setup — see the OBSERVE note below),
        // so we let the controller build its default split view, then ISA-SWIZZLE that fully-set-up instance
        // to a subclass that ONLY overrides `drawDivider(in:)` to fill the divider with the flat theme
        // backdrop. `object_setClass` is memory-safe here — `FlatDividerSplitView` adds no stored properties
        // (identical ivar layout) — and side-steps the constructor path that traps.
        object_setClass(splitView, FlatDividerSplitView.self)

        // 1) Sidebar — the navigator (sessions / panes). A PLAIN split item, NOT
        //    `NSSplitViewItem(sidebarWithViewController:)`: the native sidebar style paints system vibrancy +
        //    inset-grouped/rounded selection, which is the "native SwiftUI rounded corners" look we are
        //    replacing. A plain item lets `NavigatorColumn` paint its own flat warm panel + white-card rows.
        //    Holding priority above the content's default so window-resize grows the content, not the sidebar.
        let navigator = NSHostingController(rootView: NavigatorColumn(
            store: store, preferences: preferences, chrome: chrome,
            connection: connection, onConnect: onConnect,
        ))
        let sidebarItem = NSSplitViewItem(viewController: navigator)
        sidebarItem.minimumThickness = Self.defaultSidebarWidth
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)

        // 2) Content — the pane grid (terminal / claude / remote) + the hover-reveal titlebar overlay.
        //    The non-collapsible centre. `chrome` drives the titlebar's sidebar toggle; `onConnect` wires
        //    the titlebar's connection-status cluster to the Connect-to-Host editor.
        let content = NSHostingController(
            rootView: ContentColumn(store: store, connection: connection, chrome: chrome, onConnect: onConnect),
        )
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = Self.contentMinWidth

        // Each column hosts SwiftUI in its own NSHostingController, which by DEFAULT insets its content below
        // the window's titlebar safe area (the traffic-light strip). With `.hiddenTitleBar` that pushed every
        // column's top chrome — the hover-reveal titlebar's centred title, and the sidebar's
        // "TABS" header — a full row BELOW the traffic lights. Dropping the safe-area regions lets each column
        // start at the window's top edge, so the titlebar's controls land ON the traffic-light row (each
        // column still reserves its own titlebar-height strip at the top).
        navigator.safeAreaRegions = []
        content.safeAreaRegions = []

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)

        // 3) Host Windows rail (docs/45) — the RIGHT column listing the host machine's windows. A
        //    PLAIN item like the sidebar (never `NSSplitViewItem(inspectorWithViewController:)` /
        //    SwiftUI `.inspector`: both unmount the centre on toggle, which kills live video panes).
        //    Same holding priority as the sidebar so window-resize grows the content, not the rail.
        //    Starts collapsed per the persisted chrome flag (`updateNSViewController` applies it
        //    every update; setting it before the first layout avoids a flash-of-rail at launch).
        if let hostWindowFeed {
            let hostRail = NSHostingController(rootView: HostWindowsColumn(
                store: store, feed: hostWindowFeed, chrome: chrome,
            ))
            let hostRailItem = NSSplitViewItem(viewController: hostRail)
            hostRailItem.minimumThickness = Slate.Metric.hostRailMinWidth
            hostRailItem.maximumThickness = Slate.Metric.hostRailMaxWidth
            hostRailItem.canCollapse = true
            hostRailItem.holdingPriority = NSLayoutConstraint.Priority(260)
            hostRailItem.isCollapsed = chrome.hostRailCollapsed
            hostRail.safeAreaRegions = []
            addSplitViewItem(hostRailItem)
            self.hostRailItem = hostRailItem
        }

        self.sidebarItem = sidebarItem

        // Defer remote terminal grid-resize forwarding while a sidebar/inspector divider (or the window edge)
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

        // D3: SwiftUI `@Environment`/`.preferredColorScheme` does NOT cross into the three
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

    /// Pin the WINDOW's appearance to the active theme. The three columns are hosted in
    /// `NSHostingController`s inside this AppKit split controller, so they do NOT inherit the SwiftUI
    /// `.preferredColorScheme` set on `WorkspaceRootView` — any system-dynamic colour / material in a column
    /// would otherwise resolve to the OS appearance and clash with the pinned theme palette (e.g. white text
    /// on the light Paper chrome when the user's Mac is in Dark mode). Setting it on the NSWindow propagates
    /// to every hosted NSView. Done in `viewDidAppear` because the window only exists once attached.
    override func viewDidAppear() {
        super.viewDidAppear()
        pinWindowAppearance()
    }

    /// Pin the WINDOW's `NSAppearance` to the active theme. Factored out so both `viewDidAppear` (first
    /// attach) and `themeDidChange` (runtime switch) drive the SAME re-pin.
    private func pinWindowAppearance() {
        // Concrete sRGB backdrop (NOT `NSColor(Slate.theme.window)`): the SwiftUI-Color→NSColor bridge resolves
        // through the effective appearance and left the divider reading black on the LIGHT themes; a plain
        // sRGB triple is appearance-stable. The theme's `terminalBackgroundHex` IS the flat window tone in hex.
        let backdrop = NSColor(slateHex6: Slate.theme.terminalBackgroundHex)
        view.window?.appearance = NSAppearance(named: Slate.theme.isLight ? .aqua : .darkAqua)
        view.window?.backgroundColor = backdrop
        // The sidebar/content divider is the 1px GAP between the hosting columns. It is painted TWO ways that
        // must agree: `FlatDividerSplitView.drawDivider(in:)` fills it, AND (once the split view is layer-backed
        // for its `NSHostingController` columns) the gap also shows this layer `backgroundColor`. Both are set
        // to `flatDividerTone()` (the sidebar `ground`), so the seam is just the ground→face luminance step.
        //
        // CRITICAL — repaint on a RUNTIME theme switch: `drawDivider` draws OPAQUE ground pixels that AppKit
        // CACHES in the layer; a plain `needsDisplay` does NOT re-invoke it for the divider rect, so after a
        // light→dark (or dark→light) switch the seam kept its STALE pre-switch colour — a bright near-white
        // line on the freshly-dark chrome (the SwiftUI columns repaint via `@Observable`, but this AppKit seam
        // did not). `layer?.setNeedsDisplay()` invalidates the layer's drawn CONTENT so `drawDivider` re-runs
        // with the now-current theme; `displayIfNeeded()` forces it synchronously so no stale frame is shown.
        splitView.wantsLayer = true
        splitView.layer?.backgroundColor = flatDividerTone().cgColor
        splitView.needsDisplay = true
        splitView.layer?.setNeedsDisplay()
        splitView.displayIfNeeded()
    }

    /// React to a runtime theme switch (the `AppearanceApplier` hook already repointed `ThemeStore.shared`).
    /// Re-pin the window appearance AND force each hosted column to re-read the theme tokens — a SwiftUI
    /// `@Observable` change inside `ThemeStore` re-renders views that READ it, but the AppKit window
    /// appearance + any system-dynamic resolution must be re-pinned explicitly here (the boundary SwiftUI
    /// observation does not cross). `needsDisplay` on each column view nudges a redraw so no pane is left
    /// half-painted in the old palette.
    @objc
    private func themeDidChange() {
        pinWindowAppearance()
        for item in splitViewItems {
            item.viewController.view.needsDisplay = true
        }
    }

    /// Apply the toolbar collapse flags to the sidebar + host-rail items (idempotent — only animates
    /// a real change so a steady-state update doesn't re-trigger the animation).
    func applyCollapse(sidebarCollapsed: Bool, hostRailCollapsed: Bool = true) {
        let sidebarChanging = sidebarItem.map { $0.isCollapsed != sidebarCollapsed } ?? false
        let railChanging = hostRailItem.map { $0.isCollapsed != hostRailCollapsed } ?? false
        // LOST-PROMPT FIX: `animator().isCollapsed = …` applies the FIRST collapse-animation layout frame
        // SYNCHRONOUSLY, which fires `GhosttyLayerBackedView.layout()` and forwards an INTERMEDIATE grid
        // size to the host BEFORE `splitViewSubviewsDidResize` (the notification) suspends forwarding. That
        // premature SIGWINCH makes zsh run `zle reset-prompt` at the wrong width, double-firing against the
        // final-width reset and erasing the prompt line. Suspend FIRST so the intermediate frames are held;
        // the settle timer in `splitViewSubviewsDidResize` resumes + flushes the FINAL grid (the
        // idempotency guard in `setResizeSuspended` prevents a double-flush). The host rail's collapse
        // resizes the SAME centre column, so it takes the identical suspend-first treatment.
        if sidebarChanging || railChanging {
            resizeForwardingSuspended = true
            store.setTerminalResizeSuspended(true)
        }
        if sidebarChanging, let sidebarItem {
            sidebarItem.animator().isCollapsed = sidebarCollapsed
        }
        if railChanging, let hostRailItem {
            hostRailItem.animator().isCollapsed = hostRailCollapsed
        }
    }
}

/// A drop-in `NSSplitView` whose ONLY change is a flat, theme-coloured divider — installed via
/// `object_setClass` onto the controller's already-built split view (so it never goes through the
/// `NSSplitViewController` construction path that traps `_setupSplitView` when a custom split view is
/// supplied up front). `drawDivider(in:)` fills the 1px `.thin` divider rect with the active theme backdrop,
/// so the sidebar/content/inspector seam blends into the flat chrome instead of AppKit's default pure-black
/// hairline. Adds NO stored properties — the isa-swizzle keeps the original instance's ivar layout intact.
private final class FlatDividerSplitView: NSSplitView {
    override func drawDivider(in rect: NSRect) {
        flatDividerTone().setFill()
        NSBezierPath(rect: rect).fill()
    }

    /// The RAIL divider (content | host rail) is dragged by hand, not by AppKit's built-in
    /// constraint tracking. AppKit's `_doConstraintBasedDragDivider` pins the drag at a priority
    /// derived from the LEADING item's holding priority, so a trailing item that holds HARDER than
    /// its leading neighbour (rail 260 > content 250 — deliberate, window-resize must feed the
    /// content) can never be grown by its divider: the engine grows a hole at the split view's
    /// 749-priority trailing glue instead and snaps everything back on release. The left divider
    /// is immune (its growing item is the LEADING side). So for the rail divider we run the
    /// standard event-tracking loop ourselves and place the divider each step via
    /// `setPosition(_:ofDividerAt:)`, which AppKit applies at a priority the holds cannot veto.
    override func mouseDown(with event: NSEvent) {
        guard let railDivider = railDividerIndex(under: event) else {
            super.mouseDown(with: event)
            return
        }
        trackRailDividerDrag(with: event, dividerIndex: railDivider)
    }

    /// The rail divider's index iff `event` grabs it: the LAST divider of a 3-column layout, hit
    /// within the same ±few-pt slop AppKit's own hit-test claims for a `.thin` divider. A
    /// COLLAPSED rail bows out (its divider is hidden; a click 4 pt from the window edge is a
    /// content click, and drag-to-expand would desync the chrome collapse flag).
    private func railDividerIndex(under event: NSEvent) -> Int? {
        guard arrangedSubviews.count == 3,
              (delegate as? NSSplitViewController)?.splitViewItems.last?.isCollapsed == false
        else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        guard dividerEffectiveRect(at: 1).insetBy(dx: -4, dy: 0).contains(point) else { return nil }
        return 1
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

    private func trackRailDividerDrag(with event: NSEvent, dividerIndex: Int) {
        guard let window else { return }
        let grabX = convert(event.locationInWindow, from: nil).x
        let startPosition = arrangedSubviews[dividerIndex].frame.maxX
        dividerCursor(at: dividerIndex).push()
        defer {
            NSCursor.pop()
            // Rebuild the hover cursors for the widths the drag settled on (a drag that ends
            // pinned at a limit must immediately hover as one-directional).
            window.invalidateCursorRects(for: self)
        }
        while true {
            guard let next = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture, inMode: .eventTracking, dequeue: true,
            ) else { continue }
            if next.type == .leftMouseUp { return }
            let x = convert(next.locationInWindow, from: nil).x
            let target = clampRailDividerPosition(startPosition + (x - grabX))
            setPosition(target, ofDividerAt: dividerIndex)
            window.layoutIfNeeded()
            // Track the limit state live: pinned at min/max shows the one-way arrow mid-drag too.
            dividerCursor(at: dividerIndex).set()
        }
    }

    private func clampRailDividerPosition(_ proposed: CGFloat) -> CGFloat {
        SlopDeskSplitViewController.clampedRailDividerPosition(
            proposed: proposed,
            contentMinX: arrangedSubviews[1].frame.minX,
            splitWidth: bounds.width,
            dividerThickness: dividerThickness,
        )
    }

    // MARK: Divider hover cursors (owned — AppKit's lie at the minimum)

    /// Install our OWN divider cursor rects instead of AppKit's. AppKit picks the two-way vs
    /// one-way resize arrow from its notion of movability, which counts drag-to-collapse as "can
    /// still move": an item AT its minimum next to a `canCollapse` neighbour keeps the two-way
    /// arrow even though this app never collapses by shoving a divider (the rail's manual drag
    /// clamps at min; collapse belongs to the toggles). At the MAXIMUM AppKit already shows the
    /// one-way arrow, so the two limits read inconsistently. We derive movability purely from the
    /// items' width ranges (`SlopDeskSplitViewController.dividerMovability`), so both limits wear
    /// the one-way arrow. The rect mirrors the divider gap widened by the same ±few-pt slop the
    /// hit-testing claims; a divider beside a collapsed item gets no rect (it is hidden).
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
    /// Clamp a proposed rail-divider position to the same limits the split items declare: content
    /// ≥ its minimum, rail within min…max. Drag-to-collapse is deliberately not offered — the rail
    /// collapses via its toggle (⌘⇧R / titlebar / palette), never by shoving the divider. In an
    /// over-constrained window (content floor + rail max cannot both hold) the rail's MINIMUM wins:
    /// the divider can then only be pushed toward the rail's floor, never below it.
    static func clampedRailDividerPosition(
        proposed: CGFloat, contentMinX: CGFloat, splitWidth: CGFloat, dividerThickness: CGFloat,
    ) -> CGFloat {
        let lowest = CGFloat.maximum(
            contentMinX + contentMinWidth,
            splitWidth - dividerThickness - Slate.Metric.hostRailMaxWidth,
        )
        let highest = splitWidth - dividerThickness - Slate.Metric.hostRailMinWidth
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

/// The flat divider tone: the sidebar `ground` surface as an OPAQUE sRGB colour — NO drawn hairline.
///
/// MERIDIAN L5 (depth by light, not lines): the sidebar (`ground`) and the content (`face`) are separated by
/// ONE luminance step, NO divider line. So the 1px split gap must NOT be a hairline lighter/darker than both
/// surfaces — it must blend into the sidebar so only the natural ground→face step reads as the seam.
///
/// Why not composite the `Slate.Line.divider` hairline here: the sidebar seam borders
/// the DARKER `ground` on one side and the LIGHTER `face` on the other, and the hairline's tint FLIPS per
/// appearance (near-white on dark, near-black on light). Over `face` the white hairline read as a bright
/// near-white seam against the dark sidebar; over `ground` the black hairline
/// read as a heavy dark line on the light chrome. No single composite base is faint against
/// BOTH a dark-ish and a light-ish neighbour, so we draw NO line at all — the gap is `ground`, and the seam is
/// purely the ground→face luminance step, faint and clean in both appearances (the pane-grid dividers keep
/// their own faint hairline; the sidebar boundary is chrome, not a content split).
///
/// Resolved via `Color.resolve(in:)` (NOT `NSColor(_: SwiftUI.Color)`, which resolves through the effective
/// appearance and read black on the light themes) — `ground` is a concrete `Color(.sRGB, …)`, so resolve is
/// appearance-stable and exact.
@MainActor
private func flatDividerTone() -> NSColor {
    let g = Slate.theme.ground.resolve(in: EnvironmentValues())
    return NSColor(srgbRed: CGFloat(g.red), green: CGFloat(g.green), blue: CGFloat(g.blue), alpha: 1)
}

private extension NSColor {
    /// Concrete sRGB `NSColor` from a 6-hex backdrop string (the theme's flat window tone). Avoids the
    /// appearance-sensitivity of `NSColor(_: SwiftUI.Color)` — a plain sRGB triple resolves identically in
    /// `.aqua` and `.darkAqua`, so the flat divider doesn't read black on the light themes.
    convenience init(slateHex6 hex: String) {
        let v = UInt64(hex, radix: 16) ?? 0
        self.init(
            srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1,
        )
    }
}
#endif
