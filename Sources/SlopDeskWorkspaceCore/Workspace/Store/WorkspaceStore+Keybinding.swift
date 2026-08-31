// WorkspaceStore+Keybinding — the per-pane WS-B / B4·B5 keybinding-interceptor wiring, factored out of
// `wireMaterializedLeaf` so the `WorkspaceStore` primary body stays under the SwiftLint type-body ceiling
// (the same split as `WorkspaceStore+Blocks.seedBlockBookmarks`). Pure wiring; no new behaviour.

import SlopDeskWorkspaceModel

/// The view-injected overlay-toggle closures the per-pane hardware-keyboard ``TerminalKeyInterceptor`` threads
/// into ``WorkspaceBindingRegistry/route`` (held on ``WorkspaceStore/overlayKeyToggles``). Each mirrors one
/// `route` toggle param. iOS wires these to the ``OverlayCoordinator`` so a focused-pane hardware chord opens
/// the matching overlay; macOS leaves them `nil` (its app-level NSEvent dispatcher owns those chords before the
/// surface). A `nil` member is a graceful no-op — the chord's `route` arm then falls back to its store path or
/// does nothing, never a dead/destructive control.
public struct WorkspaceOverlayKeyToggles {
    public var palette: (() -> Void)?
    public var cheatSheet: (() -> Void)?
    public var globalSearch: (() -> Void)?
    public var jumpTo: (() -> Void)?
    public var openQuickly: (() -> Void)?
    public var peekReply: (() -> Void)?
    /// The two CHROME toggles. Not overlays at all — they flip the live ``WorkspaceChromeState`` — but they
    /// arrive by exactly the same road on iOS, and for the same reason: with no app-level monitor a chord
    /// reaches the focused terminal surface first, so ⌘⇧L and ⌘⇧R would otherwise die at a nil closure while
    /// the panels they name sit right there.
    public var sidebar: (() -> Void)?
    public var codeSidebar: (() -> Void)?
    /// ⌥⌘R. On the Mac this hands the keyboard to the embedded workbench and takes it back; the phone has
    /// no such duel, so it reveals the panel and stops there — which is what "focus the code panel" means
    /// on a device that shows one surface at a time.
    public var focusCodePanel: (() -> Void)?

    public init(
        palette: (() -> Void)? = nil,
        cheatSheet: (() -> Void)? = nil,
        globalSearch: (() -> Void)? = nil,
        jumpTo: (() -> Void)? = nil,
        openQuickly: (() -> Void)? = nil,
        peekReply: (() -> Void)? = nil,
        sidebar: (() -> Void)? = nil,
        codeSidebar: (() -> Void)? = nil,
        focusCodePanel: (() -> Void)? = nil,
    ) {
        self.palette = palette
        self.cheatSheet = cheatSheet
        self.globalSearch = globalSearch
        self.jumpTo = jumpTo
        self.openQuickly = openQuickly
        self.peekReply = peekReply
        self.sidebar = sidebar
        self.codeSidebar = codeSidebar
        self.focusCodePanel = focusCodePanel
    }
}

extension WorkspaceStore {
    /// Route a hardware-keyboard `action` resolved by a per-pane ``TerminalKeyInterceptor`` through
    /// ``WorkspaceBindingRegistry/route``, threading the view-injected ``overlayKeyToggles`` so an OVERLAY chord
    /// (⌘⇧P / ⇧⌘F / ⌘⇧O / ⌘J / ⌘⌥J) fires its panel on a platform with no app-level NSEvent monitor (iOS).
    /// macOS installs no toggles here (its dispatcher owns the chord BEFORE the surface ever sees it), so this
    /// degenerates to the bare `route` there. A `nil` toggle is a graceful no-op (the `route` arm's own fallback).
    func routeInterceptedKey(_ action: WorkspaceAction) {
        WorkspaceBindingRegistry.route(
            action, to: self,
            togglePalette: overlayKeyToggles.palette,
            toggleCheatSheet: overlayKeyToggles.cheatSheet,
            togglePeekReply: overlayKeyToggles.peekReply,
            toggleSidebar: overlayKeyToggles.sidebar,
            toggleCodeSidebar: overlayKeyToggles.codeSidebar,
            toggleGlobalSearch: overlayKeyToggles.globalSearch,
            toggleJumpTo: overlayKeyToggles.jumpTo,
            openQuickly: overlayKeyToggles.openQuickly,
            focusCodePanel: overlayKeyToggles.focusCodePanel,
        )
    }

    /// Hand pane `id`'s terminal surface its PURE ``TerminalKeyInterceptor`` (the override-aware
    /// single-chord table). The surface's `keyDown` consults it BEFORE its own raw-byte branches, so the
    /// rebindable ⌘D/⌘⇧D split is owned by the shared engine (B5 removed the hard-coded split branch). A
    /// resolved action routes through the SAME `WorkspaceBindingRegistry.route` the app-level monitor (B3)
    /// uses; a new-pane action (split / new-tab / …) mints a terminal pane directly via the store. A `nil`
    /// `terminal` (headless / non-terminal handle) is a no-op.
    func wireKeyInterceptor(terminal: TerminalViewModel?) {
        terminal?.keyInterceptor = makeKeyInterceptor()
    }

    /// A ``TerminalKeyInterceptor`` bound to this store — the pane's, and the one the phone's LAST
    /// RESPONDER holds too.
    ///
    /// A key path that can swallow a chord is not a property of a PANE: on iOS the same table has to
    /// resolve when the focused pane is a video surface, when no pane is focused, and under the
    /// panel's cover, none of which have a `TerminalViewModel` to hang an interceptor off. So the
    /// factory is public and the interceptor is the one implementation both rungs consult — a second
    /// resolve-and-route written at the root would be the same table read twice, which is exactly
    /// what ``TerminalKeyInterceptor``'s header says it exists to prevent.
    ///
    /// `survives` FILTERS which resolved actions may be spent, and defaults to all of them. Its one
    /// caller is the phone's root rung under the panel cover (`CodePanelKeyYield.survives`): a chord
    /// the filter refuses resolves to nothing, so the interceptor forwards it and the press goes on
    /// its way rather than being swallowed into a workspace the reader cannot see.
    public func makeKeyInterceptor(
        allowing survives: @escaping (WorkspaceAction) -> Bool = { _ in true },
    ) -> TerminalKeyInterceptor {
        TerminalKeyInterceptor(
            resolveChord: { chord in
                // An `unbind:` target keeps its chord but loses its ACTION — the press falls through
                // to whatever would have had it, which for a terminal pane is the PTY. The Mac's
                // dispatcher has always honoured this (`WorkspaceKeyDispatcher`), and the interceptor
                // did not, so one shared config file produced two behaviours: an unbound ⌘D still
                // split the pane on the phone, and still split it on the Mac whenever the press
                // reached the surface rather than the monitor. Asked HERE because this factory is the
                // one resolve both of the phone's rungs and the Mac's pane surface share.
                guard !WorkspaceBindingRegistry.isUnbound(chord),
                      let action = WorkspaceBindingRegistry.resolvedChordTable[chord],
                      survives(action) else { return nil }
                return action
            },
            onAction: { [weak self] action in
                guard let self else { return }
                // Thread the view-injected overlay toggles (iOS hardware-keyboard path — macOS leaves them nil
                // and its NSEvent dispatcher owns overlay chords before the surface). `nil` ⇒ graceful no-op.
                routeInterceptedKey(action)
            },
        )
    }

    /// The terminal surface's right-click "Split Right/Down" landing (factored out of `wireMaterializedLeaf`
    /// to keep the `WorkspaceStore` body under the lint ceiling). A split MINTS a pane, so — like the `+` /
    /// ⌘D / title-menu split — it mints a focused terminal pane.
    /// Focuses `paneID` first so the active-pane split targets the surface the user acted on.
    /// `horizontal == true` → side-by-side.
    func splitFromContextMenu(paneID: PaneID, horizontal: Bool) {
        let axis: SplitAxis = horizontal ? .horizontal : .vertical
        focusPaneTree(paneID)
        newTerminalPane(.split(axis: axis))
    }
}
