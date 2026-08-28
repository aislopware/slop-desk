// SlopDeskMacApp+Window — everything the macOS shell does TO its `NSWindow`, in one place.
//
// The workspace window's close gate, its once-per-open geometry (remember / grid / frame), the
// traffic-light line, and the automation bring-to-front. Each is a `static` over an explicit
// `NSWindow` rather than a method on the delegate, because each is a pure actuator over a window it
// does not own — which is what makes the geometry ones testable against a plain window and keeps the
// delegate's launch path a list of calls rather than a second place window policy lives.
//
// ⚠️ THREE OF THE FOUR USED TO CARRY AN `objc_setAssociatedObject` ONE-SHOT, AND THE ONE-SHOTS ARE
// GONE WITH THE HOOK THAT NEEDED THEM. The only caller used to be SwiftUI's `.introspect(.window)`
// closure, which RE-FIRES on every scene re-render — and terminal and video output mutate
// `@Observable` state continuously, so "on every re-render" meant tens of times a second. Anything
// that activated a window, installed a delegate or declared a toolbar therefore had to detect that it
// had already run. ``MacWorkspaceWindowController`` creates the window once and the delegate calls
// each of these once, at `applicationDidFinishLaunching`, so:
//
//   * the close gate no longer asks whether it is already the delegate,
//   * the automation activate no longer marks the window it activated,
//   * the toolbar declaration no longer asks whether a toolbar is already there.
//
// ⚠️ ONE GUARD SURVIVES, WITH A DIFFERENT REASON. ``applyInitialWindowSize(to:store:chrome:
// fontPointSize:)`` is still called TWICE — once at launch and once more if the first call landed on
// a `grid` window whose terminal had not reported its true cell advance yet (see
// ``MacWorkspaceWindowController/retryGridSizeWhenCellMetricsArrive(_:)``). Its guard is what makes
// the second call a no-op once the first has committed, so a user's later manual resize is never
// re-fought. It is now guarding against a second call rather than against a hundred, and it is the
// reason the retry can be offered unconditionally.
//
// The math itself is not here. `WindowSizeMath` (`SlopDeskWorkspaceCore`) resolves every content size
// and clamps every input; this file is the actuator that hands it real cell metrics and a real screen.

import AppKit
import Combine
import ObjectiveC
import SlopDeskClientCore
import SlopDeskTerminal
import SlopDeskWorkspaceCore

extension SlopDeskMacApp {
    /// The keybinding dispatcher's key-window gate, as a PURE identity predicate so it is unit-pinnable
    /// without an `NSWindow` (`AnyObject` — tests inject plain fakes): the workspace owns the keyboard ONLY
    /// when the window the delegate captured IS the application's current key window.
    /// A `nil` capture (pre-launch, or the weak ``WeakWindowBox`` going stale after the workspace window
    /// closed) NEVER claims the keyboard — a `window.map(\.isKeyWindow) ?? true` form would default a nil
    /// capture to "workspace is key", letting a stale box swallow chords while another window is frontmost.
    /// Identity against `NSApp.keyWindow` also stays truthful if the box ever
    /// held a non-workspace window: that window being key is exactly the state where yielding is wrong only
    /// for the REAL workspace window — and only the ONE workspace window can land in the box: there is no
    /// New Window item, and the detach-pane satellites (``SatellitePaneWindow``) are separate windows the
    /// delegate never puts in the box. A key SATELLITE therefore correctly yields the chord
    /// keyboard (workspace chords act on the main window; satellites take plain first-responder input).
    static func workspaceWindowIsKey(captured: AnyObject?, keyWindow: AnyObject?) -> Bool {
        guard let captured else { return false }
        return captured === keyWindow
    }

    /// Associated-object key under which a window retains its ``WindowCloseConfirmationDelegate`` (the
    /// delegate is referenced WEAKLY by `NSWindow.delegate`, so it needs an explicit owner for the window's
    /// lifetime). Only its ADDRESS is used (as the associated-object key), never its value — `nonisolated`
    /// (unsafe) because an address-only key carries no shared mutable state to race on.
    private nonisolated(unsafe) static var windowCloseDelegateKey: UInt8 = 0

    /// Installs the window-close confirmation gate on `window`. ``MacWorkspaceWindowController`` is its
    /// own window's delegate; a transparent shim (``WindowCloseConfirmationDelegate``) wraps it —
    /// implementing only `windowShouldClose(_:)` and forwarding every other selector to the controller —
    /// so the controller's window bookkeeping is preserved while the close attempt routes through the
    /// store.
    @MainActor
    static func installWindowCloseGate(on window: NSWindow, store: WorkspaceStore) {
        let shim = WindowCloseConfirmationDelegate(store: store, next: window.delegate)
        window.delegate = shim
        objc_setAssociatedObject(window, &windowCloseDelegateKey, shim, .OBJC_ASSOCIATION_RETAIN)
    }

    /// Associated-object key marking a window whose initial size has been applied, so the deferred
    /// grid re-measure cannot re-fight a manual resize. Only its ADDRESS is used as the key, never its
    /// value — `nonisolated(unsafe)` like ``windowCloseDelegateKey``.
    private nonisolated(unsafe) static var windowSizeAppliedKey: UInt8 = 0

    /// AUTOMATION ONLY: bring the workspace window to front + make it key, so an autoconnect launch goes
    /// live without a manual click. A non-automation launch is a no-op — `showWindow(_:)` has already
    /// ordered the window front by then, and a plain launch has no reason to steal activation from
    /// whatever the user was doing.
    @MainActor
    static func automationBringToFront(_ window: NSWindow) {
        guard ClientComposition.hasAutomationEnvironment() else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Declare a taller system titlebar so AppKit itself parks the three window controls on the
    /// band's TOP LINE (``Slate/Metric/bandInset``) instead of at its own default 8pt corner inset,
    /// which left them a full grid step above the island's top edge and everything else in the band
    /// (user-directed 2026-08-09). MEASURED on the running app: `.unifiedCompact` yields a 40pt
    /// `AXToolbar` and lands the discs 13 from the top, 12 from the leading edge — one point under
    /// the line, which on a 16pt disc is nothing, and the ONLY tool the system offers is this
    /// height (the inset is not settable).
    ///
    /// ⚠️ THIS DOES NOT MOVE THE BUTTONS, AND THAT IS THE WHOLE POINT. The first cut nudged their
    /// frames directly and it FLICKERED: AppKit rebuilds the titlebar whenever `NSWindow.title`
    /// changes, which resets the cluster to the corner, and the correction then landed a frame later
    /// as a visible jump. The window title tracks the focused pane's cwd folder name, so switching
    /// panes inside one project usually kept the same string and looked clean while crossing to
    /// another project re-titled the window and jumped — the symptom read as a pane-switch bug and
    /// was a title-change bug. Owning the HEIGHT instead of the POSITION makes the placement
    /// AppKit's own layout, so every rebuild re-derives it and there is nothing left to correct.
    ///
    /// The toolbar is EMPTY and has no delegate — it is a height declaration, not a toolbar. With no
    /// items and customization off, AppKit adds no "Show Toolbar" / "Customize Toolbar…" to the View
    /// menu (checked: it still reads Show Tab Bar / Show All Tabs / Enter Full Screen), and the
    /// window's own `titlebarAppearsTransparent` keeps it from painting anything.
    @MainActor
    static func lowerTrafficLightsToTheTopLine(on window: NSWindow) {
        window.toolbar = NSToolbar(identifier: "SlopDeskBandHeight")
        window.toolbarStyle = .unifiedCompact
    }

    /// Apply the configured initial window size at most once per window open (guarded by an
    /// associated object, mirroring the close-gate retain idiom), so a later manual resize always stands:
    ///   * ``WindowSizeMode/remember`` → restore the app-persisted frame descriptor + install the
    ///     save-on-change observers (``applyRememberedFrame(to:)``) and commit;
    ///   * ``WindowSizeMode/grid`` / ``WindowSizeMode/frame`` → resolve a CONTENT size via the pure
    ///     ``WindowSizeMath/resolvedContentSize(mode:cols:rows:widthPx:heightPx:cell:visible:chromeInsets:chromeOverhead:)``
    ///     and `setContentSize`.
    ///
    /// Two correctness points the pure math + this glue enforce:
    ///   1. The grid sizes the TERMINAL, not the whole content view — `chromeOverhead` adds the revealed
    ///      sidebar (TABS) width (the SAME constant the split item adopts) so an
    ///      80-col grid yields an 80-col TERMINAL, not 80 cols minus the sidebar. The hover-reveal titlebar is
    ///      an OVERLAY (no layout height) and there is no horizontal tab bar, so the vertical overhead is 0.
    ///   2. Real cell metrics: `grid` uses the LIVE per-cell advance of the active terminal surface; before it
    ///      lays out we use a font-DERIVED fallback (`WindowSizeMath.fallbackCell`) instead of a wrong hard
    ///      8×16, and DEFER the commit until real metrics exist — so the window recomputes to the
    ///      exact cols×rows once libghostty reports its true cell advance, on the ONE deferred re-measure
    ///      ``MacWorkspaceWindowController/retryGridSizeWhenCellMetricsArrive(_:)`` offers, rather than
    ///      permanently committing the approximation.
    ///
    /// All numeric inputs are clamped inside ``WindowSizeMath`` (never 0×0 / off-screen-gigantic).
    @MainActor
    static func applyInitialWindowSize(
        to window: NSWindow,
        store: WorkspaceStore,
        chrome: WorkspaceChromeState,
        fontPointSize: CGFloat,
    ) {
        guard objc_getAssociatedObject(window, &windowSizeAppliedKey) == nil else { return }

        let mode = SettingsKey.windowSize
        if mode == .remember {
            // Automation launches keep the deterministic odiff geometry: no restore, and no
            // observers — an automation run must never overwrite the user's saved frame either.
            if !ClientComposition.hasAutomationEnvironment() { applyRememberedFrame(to: window) }
            objc_setAssociatedObject(window, &windowSizeAppliedKey, true, .OBJC_ASSOCIATION_RETAIN)
            return
        }
        // Live per-cell advance of the active terminal pane, or a font-derived fallback before the first
        // surface lays out (NOT a hard 8×16, which is wrong for any non-default font).
        let liveCell = Self.activeCellMetrics(store: store)
        let cell = liveCell ?? WindowSizeMath.fallbackCell(fontPointSize: fontPointSize)
        let visible = window.screen?.visibleFrame ?? .zero
        // Chrome insets = full window frame minus the content layout rect (title bar + borders). Separate
        // subtraction per axis (no fma) — `WindowSizeMath` keeps the same float discipline.
        let chromeInsets = CGSize(
            width: window.frame.size.width - window.contentLayoutRect.size.width,
            height: window.frame.size.height - window.contentLayoutRect.size.height,
        )
        // In-window non-terminal overhead for `grid` mode: the revealed sidebar width
        // (the titlebar is an overlay → no vertical cost; vertical-tabs-only → no horizontal tab bar).
        let overheadWidth =
            chrome.sidebarCollapsed ? 0 : SlopDeskSplitViewController.defaultSidebarWidth
        let chromeOverhead = CGSize(width: overheadWidth, height: 0)
        guard let size = WindowSizeMath.resolvedContentSize(
            mode: mode,
            cols: SettingsKey.windowCols,
            rows: SettingsKey.windowRows,
            widthPx: SettingsKey.windowWidthPx,
            heightPx: SettingsKey.windowHeightPx,
            cell: cell,
            visible: visible,
            chromeInsets: chromeInsets,
            chromeOverhead: chromeOverhead,
        ) else { return }
        window.setContentSize(size)

        // Commit the guard EXCEPT for a `grid` window still on the font-derived fallback (no real
        // metrics yet): leave it UNSET so the deferred re-measure recomputes to the exact cols×rows once the
        // terminal surface has laid out. `.frame` (no cell dependency) and grid-with-real-metrics commit now.
        if mode == .frame || liveCell != nil {
            objc_setAssociatedObject(window, &windowSizeAppliedKey, true, .OBJC_ASSOCIATION_RETAIN)
        }
    }

    /// The window-CREATION seed for ``WindowSizeMode/remember`` — the parsed saved frame, or `nil`
    /// (other modes / nothing saved / malformed descriptor / automation). Consumed by
    /// ``MacWorkspaceWindowController``'s `init` so the window is CREATED at the remembered geometry and
    /// the first paint is already right; ``applyRememberedFrame(to:)`` then reconciles exactly via
    /// `setFrame(from:)` (screen topology changes — the created size is proportional-safe, not absolute).
    /// Automation launches opt out (matching ``applyRememberedFrame(to:)``): the odiff reference
    /// geometry must stay the deterministic 1280×800.
    static var rememberedFrameSeed: (frame: CGRect, screen: CGRect)? {
        guard SettingsKey.windowSize == .remember, !ClientComposition.hasAutomationEnvironment() else { return nil }
        return WindowSizeMath.parseFrameDescriptor(SettingsKey.savedWindowFrame)
    }

    /// Associated-object key retaining the `.remember`-mode frame-save subscription — tied to the
    /// window so the observer lives exactly as long as it does. Address-only key, `nonisolated(unsafe)`
    /// like ``windowCloseDelegateKey``.
    private nonisolated(unsafe) static var frameSaveObserversKey: UInt8 = 0

    /// ``WindowSizeMode/remember``: restore the frame persisted under the app's OWN Defaults key
    /// (``SettingsKey/savedWindowFrame``) and install the save-on-change observers.
    ///
    /// ⚠️ `setFrameAutosaveName` IS STILL NOT USED, AND THE REASON CHANGED. It was excluded because
    /// SwiftUI asserted its own type-derived autosave name on the scene window (containing a
    /// per-launch `(unknown context at $…)` address), so AppKit's autosave machinery saved under a key
    /// that changed every launch and could never restore. Nothing asserts a name now — but AppKit's
    /// autosave writes on EVERY frame change, where both halves owned here are deliberately
    /// end-of-gesture (`didEndLiveResize` / `didMove` — not per-tick `didResize`) plus the delegate's
    /// `applicationWillTerminate` save, and re-applied via `setFrame(from:)`, which itself constrains
    /// an off-screen / stale-display frame back onto a live screen on the next window open.
    @MainActor
    private static func applyRememberedFrame(to window: NSWindow) {
        let saved = SettingsKey.savedWindowFrame
        if !saved.isEmpty { window.setFrame(from: saved) }
        // Combine publishers (not block-based `addObserver`) — both notifications post on the main
        // thread, so the MainActor-formed sink closure needs no Sendable dance to read the window.
        let cancellable = NotificationCenter.default
            .publisher(for: NSWindow.didEndLiveResizeNotification, object: window)
            .merge(with: NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: window))
            .sink { [weak window] _ in
                guard let window else { return }
                SettingsKey.savedWindowFrame = window.frameDescriptor
            }
        objc_setAssociatedObject(window, &frameSaveObserversKey, cancellable, .OBJC_ASSOCIATION_RETAIN)
    }

    /// The live per-cell advance of the active terminal pane, or `nil` when the active pane is not
    /// a laid-out terminal surface (a remote-GUI pane, or before the first layout) — the grid math then falls
    /// back to a sane default. Reaches the surface ONLY through the public ``WorkspaceStore/handle(for:)``
    /// chain (no private store reach-around), and only READS geometry (hang-safe: no surface instantiation).
    @MainActor
    private static func activeCellMetrics(store: WorkspaceStore) -> TerminalCellMetrics? {
        guard let id = store.tree.activeSession?.activeTab?.activePane,
              let live = store.handle(for: id) as? LivePaneSession,
              let snapshot = live.terminalModel?.surface as? TerminalViewportSnapshotting
        else { return nil }
        return snapshot.cellMetrics()
    }
}
