// AislopdeskSplitViewController — the macOS shell (REBUILD-V2, L1). An `NSSplitViewController` with
// two `NSSplitViewItem`s (sidebar | content), each an `NSHostingController` over a SwiftUI
// column. Modelled on CodeEdit's `CodeEditSplitViewController`: an AppKit split shell with SwiftUI INSIDE
// each column. Keeping the split in AppKit (not a SwiftUI `HSplitView` that rebuilds subtrees) is the
// load-bearing no-teardown choice for L2's libghostty panes — a torn-down NSView kills the surface.
// (The old right-hand inspector / Details column is REMOVED — the app is keyboard-centric; its surviving
// surface, the Git details window, opens from the palette / View menu instead.)

#if os(macOS)
import AislopdeskWorkspaceCore
import AppKit
import ObjectiveC
import SwiftUI

final class AislopdeskSplitViewController: NSSplitViewController {
    private let store: WorkspaceStore
    private let connection: AppConnection
    private let chrome: WorkspaceChromeState
    /// The live ``PreferencesStore`` — forwarded into the sidebar's ``NavigatorColumn`` so the tab context menu
    /// can surface the host-LOCAL "Prevent Sleep While Processing" flag (Batch 4). The sidebar is hosted in a
    /// SEPARATE `NSHostingController` that does not inherit the WindowGroup `\.preferencesStore` environment, so
    /// it is threaded explicitly. `nil` (a preview / pre-injection scene) hides the Prevent-Sleep row.
    private let preferences: PreferencesStore?
    /// Opens the Connect-to-Host editor — wired into the titlebar's connection-status cluster (ES-E2-6,
    /// reseated from the old sidebar footer). The shell binds this to `overlay.openConnect()`; the no-op
    /// default keeps the controller buildable without an overlay.
    private let onConnect: () -> Void

    /// Retained so the titlebar toggle can animate its collapse (set in `viewDidLoad`).
    private var sidebarItem: NSSplitViewItem?
    /// The RIGHT remote-windows column (TabSide partition) — retained so ⌘⇧E / the GUI-tab auto-reveal
    /// can animate its collapse (set in `viewDidLoad`; starts collapsed — terminal-first).
    private var guiItem: NSSplitViewItem?
    /// The SIDE-column widths the user last chose by dragging a divider (seeded at the defaults). In
    /// this SwiftUI-hosted shell the split view does NOT durably hold divider positions on its own:
    /// its imperative layout re-derives both side columns at their MINIMUM thickness on every pass
    /// (`NSSplitViewItem.holdingPriority` never materializes any width constraint, and an explicitly
    /// installed one is overwritten — the frames come from `NSSplitView`'s internal divider
    /// bookkeeping, not the constraint engine). So a divider drag moved the columns live and every
    /// subsequent layout — mid-drag via the SwiftUI hosting views, or the GUI column's 4s dock poll
    /// re-render — snapped them straight back: the user-reported "kéo thả tay ra lại về kích thước
    /// cũ". The shell therefore holds the widths itself: ``trackDividerDrag()`` records the MOUSE
    /// position of a live divider drag here (the frames lie mid-fight; the mouse is the user's true
    /// intent), and ``reassertDividerPositions()`` writes deviations back through
    /// `setPosition(_:ofDividerAt:)` — the one sanctioned API that updates the split view's internal
    /// bookkeeping — after every layout pass.
    private var desiredSidebarWidth: CGFloat = AislopdeskSplitViewController.defaultSidebarWidth
    private var desiredGuiWidth: CGFloat = 380
    /// Re-entrancy latch: `setPosition` inside `viewDidLayout` triggers another layout + resize
    /// notification; the latch keeps the re-assert from tracking or re-asserting its own effects.
    private var reassertingDividers = false
    /// Opens the Remote-Window picker — wired into the GUI column's `+` / empty state. The shell binds
    /// this to `overlay.openRemotePicker()`.
    private let onOpenRemotePicker: () -> Void

    /// E19 WI-4 (A29) — the sidebar (TABS panel) default thickness, shared with
    /// the window-size glue (`AislopdeskClientApp.applyInitialWindowSize`) so the `grid` mode's `chromeOverhead`
    /// uses the SAME width the split item adopts (no magic-number drift between the layout and the math).
    static let defaultSidebarWidth: CGFloat = 220

    init(
        store: WorkspaceStore,
        connection: AppConnection,
        chrome: WorkspaceChromeState,
        preferences: PreferencesStore? = nil,
        onConnect: @escaping () -> Void = {},
        onOpenRemotePicker: @escaping () -> Void = {},
    ) {
        self.store = store
        self.connection = connection
        self.chrome = chrome
        self.preferences = preferences
        self.onConnect = onConnect
        self.onOpenRemotePicker = onOpenRemotePicker
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported — AislopdeskSplitViewController is created in code")
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
        // a harsh "đen xì" seam on the lighter Monokai chrome. We cannot subclass `NSSplitView` via `loadView`
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
            store: store, preferences: preferences,
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
        contentItem.minimumThickness = 420

        // Each column hosts SwiftUI in its own NSHostingController, which by DEFAULT insets its content below
        // the window's titlebar safe area (the traffic-light strip). With `.hiddenTitleBar` that pushed every
        // column's top chrome — the hover-reveal titlebar's centred title, and the sidebar's
        // "TABS" header — a full row BELOW the traffic lights. Dropping the safe-area regions lets each column
        // start at the window's top edge, so the titlebar's controls land ON the traffic-light row (each
        // column still reserves its own titlebar-height strip at the top).
        // 3) GUI column — the RIGHT remote-windows region (TabSide partition): the window strip + the GUI
        //    side's pane compositor. Collapsible; the root view's auto-reveal expands it the moment a GUI
        //    tab exists, and ⌘⇧E toggles it manually. Holding priority above the content's default so a
        //    window-resize grows the content, not this column.
        let gui = NSHostingController(rootView: GuiColumn(
            store: store, connection: connection, chrome: chrome, onOpenPicker: onOpenRemotePicker,
        ))
        let guiItem = NSSplitViewItem(viewController: gui)
        guiItem.minimumThickness = 380
        guiItem.canCollapse = true
        guiItem.holdingPriority = NSLayoutConstraint.Priority(261)
        // Seed from the LIVE chrome flag, never a hard-coded `true`: on a workspace-restore launch the
        // root view's GUI auto-reveal can flip `chrome.guiCollapsed` to `false` BEFORE this view loads
        // (SwiftUI runs `.onChange(initial:)` off the first body render; `viewDidLoad` runs on first
        // view access) — a constant here then sticks, because the next `updateNSViewController` sees no
        // FLAG change to re-apply, and a restored remote-window tab streams into an invisible column.
        guiItem.isCollapsed = chrome.guiCollapsed
        // Same discipline for the sidebar (its default `false` matches the chrome default, but seeding
        // keeps the pair ordering-proof).
        sidebarItem.isCollapsed = chrome.sidebarCollapsed

        navigator.safeAreaRegions = []
        content.safeAreaRegions = []
        gui.safeAreaRegions = []

        // The SPLIT ITEMS own the column widths (min/max thickness + holding priority) — the hosting
        // controllers must NOT also publish SwiftUI-derived size constraints. The default `sizingOptions`
        // (`.standardBounds` = min/intrinsic/max) pins each column at its content's IDEAL width at
        // priorities that beat the holding priorities — the GUI column's window-dock strip (a horizontal
        // ScrollView whose ideal width is the FULL tile run, easily >1000pt) made the content|GUI divider
        // undraggable (every drag solved straight back) and, on a window too narrow for the over-constrained
        // system, let the solver break frames so the content column overlapped the GUI column and swallowed
        // its input. `[]` leaves layout entirely to the split view.
        navigator.sizingOptions = []
        content.sizingOptions = []
        gui.sizingOptions = []

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        addSplitViewItem(guiItem)

        self.sidebarItem = sidebarItem
        self.guiItem = guiItem

        desiredGuiWidth = guiItem.minimumThickness

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
        trackDividerDrag()
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
        // The sidebar/content divider is the 1px GAP between the hosting columns. Once the split view is
        // layer-backed (it hosts layer-backed `NSHostingController` columns) `drawDivider(in:)` is bypassed and
        // the gap shows the split view's OWN backdrop — the default dark seam, invisible on the dark themes but
        // a black line on the LIGHT ones. Pin that backdrop to the faint DIVIDER tone (the theme hairline
        // composited over the window tone) so the seam reads as the SAME mờ-mờ line as the pane dividers
        // (which draw `Slate.Line.divider` over the flat pane) — theme-aware, in both appearances.
        splitView.wantsLayer = true
        splitView.layer?.backgroundColor = flatDividerTone().cgColor
        splitView.needsDisplay = true
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

    /// Which divider the current left-mouse gesture is dragging: `0` / `1` once identified, `-1` for a
    /// left-mouse gesture that started AWAY from every divider (sticky-ignored until mouse-up), `nil`
    /// between gestures. Identified on the gesture's FIRST resize notification by mouse-to-divider
    /// proximity — see ``trackDividerDrag()``.
    private var draggingDivider: Int?
    /// The last tracked drag event's timestamp — a stale gesture (no mouse-up notification ever fired)
    /// is discarded after ``dragGestureTimeout``.
    private var lastDragEventTime: TimeInterval = 0
    private let dragGestureTimeout: TimeInterval = 1.0
    /// First-contact tolerance (points) between the mouse and a divider for the gesture to count as a
    /// divider drag. Tight enough that a window-edge resize (mouse at the window frame, hundreds of
    /// points from a divider) can never false-positive.
    private let dividerGrabTolerance: CGFloat = 16

    /// LIVE divider-drag tracker, driven from the resize notification (which fires for every step of a
    /// divider drag with `NSApp.currentEvent` = the mouse event). The frames mid-drag LIE (the split
    /// view's imperative layout keeps snapping the side column back within the same event), so the
    /// MOUSE is the user's true intent: identify the dragged divider on first contact, then record the
    /// mouse-derived width each step. ``reassertDividerPositions()`` applies it.
    private func trackDividerDrag() {
        guard !reassertingDividers else { return }
        guard let event = NSApp.currentEvent else { return }
        switch event.type {
        case .leftMouseDown,
             .leftMouseDragged,
             .leftMouseUp: break
        default: return
        }
        guard event.window === splitView.window else { return }
        // Stale-gesture reset by WALL clock (never `event.timestamp` — a synthetic/injected event can
        // carry 0, which would keep one divider grabbed forever): a mouse-up whose final frame didn't
        // change fires no resize notification, so the release can be invisible here — any >1s gap in
        // tracked drag events starts a fresh gesture instead.
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastDragEventTime > dragGestureTimeout { draggingDivider = nil }
        lastDragEventTime = now
        let x = splitView.convert(event.locationInWindow, from: nil).x

        if draggingDivider == nil {
            // First tracked event of this gesture: which divider (if any) did it grab?
            var grabbed = -1
            if let sidebarItem, !sidebarItem.isCollapsed {
                let div0 = sidebarItem.viewController.view.frame.width
                if abs(x - div0) <= dividerGrabTolerance { grabbed = 0 }
            }
            if grabbed == -1, let guiItem, !guiItem.isCollapsed {
                let div1 = splitView.bounds.width
                    - guiItem.viewController.view.frame.width - splitView.dividerThickness
                if abs(x - div1) <= dividerGrabTolerance { grabbed = 1 }
            }
            draggingDivider = grabbed
        }

        switch draggingDivider {
        case 0:
            if let sidebarItem, !sidebarItem.isCollapsed {
                let maxW = sidebarItem.maximumThickness
                var w = Swift.max(x, sidebarItem.minimumThickness)
                if maxW >= 0 { w = Swift.min(w, maxW) } // unset maximum is NSSplitViewItemUnspecifiedDimension (<0)
                desiredSidebarWidth = w
            }
        case 1:
            if let guiItem, !guiItem.isCollapsed {
                let proposed = splitView.bounds.width - x - splitView.dividerThickness
                desiredGuiWidth = Swift.max(proposed, guiItem.minimumThickness)
            }
        default:
            break
        }

        if event.type == .leftMouseUp { draggingDivider = nil }
        if draggingDivider != nil, draggingDivider != -1 { reassertDividerPositions() } // live-follow the mouse
    }

    /// Write the user-chosen side-column widths back through `setPosition(_:ofDividerAt:)` whenever a
    /// layout pass produced something else (the snap-back — see ``desiredSidebarWidth``). Idempotent:
    /// only acts on a real deviation, never on a collapsed column, and skips a column's collapse/reveal
    /// animation frames (width below the item's minimum). `setPosition` routes through the delegate
    /// min/max arbitration, so a too-narrow window degrades gracefully.
    private func reassertDividerPositions() {
        guard !reassertingDividers, isViewLoaded else { return }
        reassertingDividers = true
        defer { reassertingDividers = false }
        if let sidebarItem, !sidebarItem.isCollapsed {
            let w = sidebarItem.viewController.view.frame.width
            if w >= sidebarItem.minimumThickness, abs(w - desiredSidebarWidth) > 0.5 {
                splitView.setPosition(desiredSidebarWidth, ofDividerAt: 0)
            }
        }
        if let guiItem, !guiItem.isCollapsed {
            let w = guiItem.viewController.view.frame.width
            if w >= guiItem.minimumThickness, abs(w - desiredGuiWidth) > 0.5 {
                let position = splitView.bounds.width - desiredGuiWidth - splitView.dividerThickness
                splitView.setPosition(position, ofDividerAt: 1)
            }
        }
    }

    /// The snap-back happens inside a layout pass — re-assert right after every one (a cheap no-op
    /// when nothing deviates).
    override func viewDidLayout() {
        super.viewDidLayout()
        reassertDividerPositions()
    }

    /// Apply the chrome collapse flags to the sidebar + GUI-column items (idempotent — only animates a
    /// real change so a steady-state update doesn't re-trigger the animation).
    func applyCollapse(sidebarCollapsed: Bool, guiCollapsed: Bool) {
        let sidebarChanging = sidebarItem.map { $0.isCollapsed != sidebarCollapsed } ?? false
        let guiChanging = guiItem.map { $0.isCollapsed != guiCollapsed } ?? false
        // LOST-PROMPT FIX: `animator().isCollapsed = …` applies the FIRST collapse-animation layout frame
        // SYNCHRONOUSLY, which fires `GhosttyLayerBackedView.layout()` and forwards an INTERMEDIATE grid
        // size to the host BEFORE `splitViewSubviewsDidResize` (the notification) suspends forwarding. That
        // premature SIGWINCH makes zsh run `zle reset-prompt` at the wrong width, double-firing against the
        // final-width reset and erasing the prompt line. Suspend FIRST so the intermediate frames are held;
        // the settle timer in `splitViewSubviewsDidResize` resumes + flushes the FINAL grid (the
        // idempotency guard in `setResizeSuspended` prevents a double-flush). The GUI column reuses the
        // same suspension — its collapse re-lays the content column, so the terminal grid resizes too.
        if sidebarChanging || guiChanging {
            resizeForwardingSuspended = true
            store.setTerminalResizeSuspended(true)
        }
        if sidebarChanging, let sidebarItem {
            sidebarItem.animator().isCollapsed = sidebarCollapsed
        }
        if guiChanging, let guiItem {
            guiItem.animator().isCollapsed = guiCollapsed
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
}

/// The flat divider tone: the theme hairline ``Slate/Line/divider`` composited OVER the flat window backdrop
/// into an OPAQUE sRGB colour, so the 1px split gap reads as the SAME faint line as the pane dividers (which
/// draw that hairline over the flat pane) — in BOTH appearances. Built from concrete sRGB components (the
/// window tone from the theme hex, the overlay resolved through `.sRGB`) so it never resolves to black on the
/// light themes the way a raw `NSColor(_: SwiftUI.Color)` fill did.
@MainActor
private func flatDividerTone() -> NSColor {
    let backdrop = NSColor(slateHex6: Slate.theme.terminalBackgroundHex)
    guard let base = backdrop.usingColorSpace(.sRGB) else { return backdrop }
    // Resolve the hairline to concrete sRGB components via `Color.resolve(in:)`, NOT `NSColor(_: SwiftUI.Color)`:
    // the bridge drops the `.opacity()` modifier on these `Color(slateHex:).opacity(0.07)` hairlines, so the gap
    // rendered with alpha=1 — the FULL near-white foreground on the dark Monokai default — a bright seam unlike
    // the faint pane divider (which SwiftUI composites at the real 7% over the pane). `.resolve(in:)` carries the
    // opacity faithfully and is appearance-stable for these concrete sRGB colours. Compositing base over the SAME
    // pane backdrop (`terminalBackgroundHex` == `card` on every flat theme) makes the gap the SAME tone as the
    // pane hairline.
    let overlay = Slate.theme.divider.resolve(in: EnvironmentValues())
    let a = CGFloat(overlay.opacity)
    return NSColor(
        srgbRed: base.redComponent * (1 - a) + CGFloat(overlay.red) * a,
        green: base.greenComponent * (1 - a) + CGFloat(overlay.green) * a,
        blue: base.blueComponent * (1 - a) + CGFloat(overlay.blue) * a,
        alpha: 1,
    )
}

private extension NSColor {
    /// Concrete sRGB `NSColor` from a 6-hex backdrop string (the theme's flat window tone). Avoids the
    /// appearance-sensitivity of `NSColor(_: SwiftUI.Color)` — a plain sRGB triple resolves identically in
    /// `.aqua` and `.darkAqua`, so the flat divider no longer reads black on the light themes.
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
