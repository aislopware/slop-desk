// CodeSidebarWebViewPool — one warm WKWebView per project root, and the dressing every one of them
// wears.
//
// The pool is the load-bearing piece (the cmux lesson): ONE webview per project root, created on
// first expand and kept for as long as the cap allows, so switching the focused pane between
// projects swaps an already-warm workbench back in instantly instead of re-booting the whole VS Code
// renderer (multi-second, editor state lost). A detached webview keeps its web-content process
// alive; the idle throttling that comes with being unparented is fine for an editor.
//
// WHAT IS PLATFORM-SHAPED IS THE KEYBOARD, and nothing else. The mint, the five user scripts, the
// LRU and its eviction, the veil state and the reload are the same on both platforms — the pool's
// whole subject is projects and their pages. The second half of the class is the Mac's alone: the
// per-tab focus region, the resign classification, the ⌥⌘R toggle and the orphan repair all exist
// because a focused embedded VS Code and a focused terminal are two AppKit first responders duelling
// over one window. iOS has no such duel — no app-level event monitor, no menu bar, no shared field
// editor — so none of it is ported, and none of it is missed.
//
// HANG-SAFETY: nothing in the unit-test dependency closure may construct a WKWebView — the pool is
// only reached from a mounted panel column; all decision logic lives in `CodeSidebarFocusPolicy` and
// `CodeSidebarModel` (both pure).

import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI
import WebKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Per-project veil state for the workbench's main-frame navigation. The webview stays COVERED by
/// the column's dark waiting surface from load-start until the navigation settles — WebKit paints
/// its default white between the provisional commit and the page's own (dark) first paint, and in a
/// multi-second code-server cold boot that reads as black → white flash → workbench. `@Observable`
/// so the column's overlay fades out exactly on settle; a reload re-veils through the same events.
@MainActor
@Observable
final class CodeSidebarWebLoadState {
    private(set) var veiled = true
    func navigationStarted() { veiled = true }
    func navigationSettled() { veiled = false }
}

/// The retained `WKNavigationDelegate` driving a ``CodeSidebarWebLoadState`` (`navigationDelegate`
/// is weak — the pool holds this alongside the webview). Failures also settle: a dead endpoint must
/// surface WebKit's error page, never an eternal spinner veil.
@MainActor
private final class CodeSidebarNavigationObserver: NSObject, WKNavigationDelegate {
    let state: CodeSidebarWebLoadState

    init(state: CodeSidebarWebLoadState) {
        self.state = state
    }

    func webView(_: WKWebView, didStartProvisionalNavigation _: WKNavigation?) {
        state.navigationStarted()
    }

    func webView(_: WKWebView, didFinish _: WKNavigation?) {
        state.navigationSettled()
    }

    func webView(_: WKWebView, didFail _: WKNavigation?, withError _: Error) {
        state.navigationSettled()
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation?, withError _: Error) {
        state.navigationSettled()
    }
}

/// The per-project webview pool. `@MainActor` (WKWebView is main-thread only); keyed by the
/// project's canonical root (the host-pushed `projectKey` — the same key the sidebar sections use).
/// The host's code-server is a single shared instance; each pool entry is one project's WORKBENCH
/// on it (same origin, its own `?folder=` and editor state).
@MainActor
package final class CodeSidebarWebViewPool {
    package static let shared = CodeSidebarWebViewPool()

    /// The workspace's active tab — wired once by the app layer (the pool cannot see the store).
    /// Drives the focus-restore tab match; the `nil` default (headless tests, pre-wiring renders)
    /// simply never restores.
    package static var activeTabID: @MainActor () -> TabID? = { nil }

    /// How many project workbenches stay warm at once. Three covers the rotation a person actually
    /// keeps in their head (the repo, its dependency, the thing they are comparing against) while
    /// bounding what an all-day session can accumulate — see ``CodeSidebarFocusPolicy/evictionVictim(recency:protected:cap:)``.
    static let warmWebViewCap = 3

    private var webViews: [String: WKWebView] = [:]
    /// Project roots in least-recently-used order — the eviction queue. Touched on every mint and
    /// every mount, which between them are the only moments a project is "used".
    private var recency: [String] = []
    private var loadStates: [String: CodeSidebarWebLoadState] = [:]
    private var navigationObservers: [String: CodeSidebarNavigationObserver] = [:]
    #if os(macOS)
    private var keyWindowObservers: [NSObjectProtocol] = []
    /// THE PER-TAB FOCUS REGION — every workspace tab whose keyboard belongs to the code panel,
    /// mapped to the project workbench it belongs to. A tab absent from here reads its terminal.
    /// Written at the responder seam (claim / resign) and honoured on every tab switch and remount;
    /// see ``CodeSidebarFocusPolicy/shouldRestoreOnRemount(memory:activeTab:projectRoot:)``.
    private var sidebarFocusMemory: [TabID: String] = [:]
    /// The last first responder that was a real view OUTSIDE every pooled webview — the repair
    /// target when a refused page focus pull strands the keyboard on the window (see
    /// ``CodeSidebarWKWebView/becomeFirstResponder()``). Tracked from `NSWindow.didUpdate`
    /// (AppKit offers no first-responder-change notification); weak, and re-validated against
    /// the live window at repair time, so a torn-down view can never be revived by the repair.
    private(set) weak var lastKeyboardOwner: NSView?

    init() {
        // The responder overrides keep `CodeSidebarKeyboardState` honest WITHIN one window, but a
        // key-window change moves the keyboard without any responder transition (the webview stays
        // its window's first responder while a satellite pane window is key). Re-derive on both
        // edges so the flag always answers for the window that actually receives keys — but only
        // while SOME window of ours is key: app deactivation is not an intra-app keyboard move
        // (`CodeSidebarFocusPolicy.keyboardOwnership` — the ⌘⇥ round-trip fix).
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyWindowObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main,
            ) { _ in
                MainActor.assumeIsolated {
                    CodeSidebarKeyboardState.shared.set(CodeSidebarFocusPolicy.keyboardOwnership(
                        previous: CodeSidebarKeyboardState.shared.ownsKeyboard,
                        hasKeyWindow: (NSApp as NSApplication?)?.keyWindow != nil,
                        webViewHoldsFirstResponder: Self.shared.holdsFirstResponder(),
                    ))
                }
            })
        }
        // The rightful-owner tracker behind the orphan repair. `didUpdate` fires on every window
        // update pass — the guards are cheap and the write is a weak-pointer store.
        keyWindowObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: nil, queue: .main,
        ) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                Self.shared.noteWindowUpdate(window)
            }
        })
    }

    /// Remember the current first responder as the keyboard's rightful owner when
    /// ``CodeSidebarFocusPolicy/isTrackableKeyboardOwner(responderIsView:responderIsWindow:responderInsidePooledWebView:)``
    /// says it qualifies (a real view, not the window's orphan stand-in, not a pooled webview).
    private func noteWindowUpdate(_ window: NSWindow?) {
        guard let window, window.isKeyWindow else { return }
        let responder = window.firstResponder
        let view = responder as? NSView
        guard CodeSidebarFocusPolicy.isTrackableKeyboardOwner(
            responderIsView: view != nil,
            responderIsWindow: responder === window,
            responderInsidePooledWebView: view.map(isInsidePooledWebView) ?? false,
        ), let view else { return }
        lastKeyboardOwner = view
    }
    #endif

    /// The project's veil state — the column reads `veiled` to hold its dark waiting surface over
    /// the webview until the workbench paints. Created on demand so the read can precede the
    /// webview's own creation in the same body evaluation.
    func loadState(for projectRoot: String) -> CodeSidebarWebLoadState {
        if let existing = loadStates[projectRoot] { return existing }
        let state = CodeSidebarWebLoadState()
        loadStates[projectRoot] = state
        return state
    }

    /// The (created-on-first-use) webview for `projectRoot`, pointed at `url`. An existing entry is
    /// re-loaded ONLY when the endpoint moved (`CodeSidebarModel.endpointMoved` — a respawned
    /// service on a fresh port); the page otherwise owns its own navigation.
    ///
    func webView(for projectRoot: String, url: URL) -> WKWebView {
        touch(projectRoot)
        if let existing = webViews[projectRoot] {
            if CodeSidebarModel.endpointMoved(current: existing.url, target: url) {
                existing.load(URLRequest(url: url))
            }
            return existing
        }
        let configuration = WKWebViewConfiguration()
        // No user-gesture gate on media — VS Code's own UI sounds/previews must not silently stall.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // The client's own faces, served as subresources instead of inlined into the sheet as
        // ~4 MB of base64 (see `CodeSidebarFontScheme`). Must be set BEFORE the webview is built —
        // a configuration is copied at construction.
        configuration.setURLSchemeHandler(
            Self.fontSchemeHandler, forURLScheme: CodeSidebarFontScheme.scheme,
        )
        installWorkbenchDressing(on: configuration.userContentController)
        // The Mac's webview is a SUBCLASS because it has a responder seam to guard; the phone's is a
        // plain `WKWebView` because there is no second first responder to duel with.
        #if os(macOS)
        let webView: WKWebView = CodeSidebarWKWebView(
            projectRoot: projectRoot, frame: .zero, configuration: configuration,
        )
        #else
        let webView = WKWebView(frame: .zero, configuration: configuration)
        #endif
        // Right-click → Inspect Element on the embedded workbench (Safari Web Inspector) — the only
        // window into a misbehaving code-server page.
        webView.isInspectable = true
        // Paint the GROUND behind the page so the first load / a bounce never flashes a tone the
        // column does not wear (the cmux `underPageBackgroundColor` trick).
        webView.underPageBackgroundColor = SlateNativeColor(slateHex: Slate.theme.groundHexValue)
        // CHROME polarity — the workbench is a sunken panel on the ground, not an island (ONE ISLAND
        // law 1): it stands on the same cream ground as the navigator, so it follows the chrome's
        // LIGHT appearance and the seeded colour customizations paint it in the ground tone. Pinned
        // HERE, at creation, and nowhere else — a re-pin pass over the pool existed and was never
        // called, which was correct: `Slate.theme` does not change while the app runs. The two
        // platforms spell the same pin differently, and only that spelling differs.
        #if os(macOS)
        webView.appearance = NSAppearance(named: .aqua)
        #else
        webView.overrideUserInterfaceStyle = .light
        #endif
        // WebKit's own base canvas is WHITE until the page's first paint — with a multi-second
        // workbench boot that is a visible flash between the dark chrome and the dark editor. On the
        // Mac there is no public API for it and the long-standing KVC key makes the canvas
        // transparent; UIKit exposes the same thing honestly, through the view's own opacity.
        #if os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        #else
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        #endif
        let observer = CodeSidebarNavigationObserver(state: loadState(for: projectRoot))
        navigationObservers[projectRoot] = observer
        webView.navigationDelegate = observer
        webView.load(URLRequest(url: url))
        webViews[projectRoot] = webView
        evictColdestIfOverCap()
        return webView
    }

    /// The workbench's five user scripts, in the order their injection times require. Split out so
    /// the mint reads as "pick a dressing" rather than sixty lines of one branch.
    private func installWorkbenchDressing(on controller: WKUserContentController) {
        // The finishing coat (terminal-mono + nerd-font @font-faces, Slate softening, slopcat
        // letterpress) rides every navigation — user scripts persist on the controller, so a
        // reload/respawn re-dresses itself.
        controller.addUserScript(WKUserScript(
            source: Self.dressingScriptSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
        ))
        // The recommendation-tips GRAFT: code-server's boot configuration never carries the
        // recommendation catalogue (its server forwards only the gallery), leaving the Extensions
        // view's RECOMMENDED section empty. The script rewrites the configuration meta tag with
        // the bundled catalogue before the workbench boots — document START (the rewrite must
        // precede the workbench's read), MAIN frame only (the meta lives on the top document).
        controller.addUserScript(WKUserScript(
            source: CodeSidebarPageDressing.recommendationTipsScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
        ))
        // The focus-truth corrector: replay the blur a never-focused page misses, so only the
        // real keyboard owner renders a caret (see `focusTruthScript`). Document START (the
        // timers must span the workbench's whole boot), MAIN frame (the workbench top frame
        // owns the editor).
        controller.addUserScript(WKUserScript(
            source: CodeSidebarPageDressing.focusTruthScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
        ))
        // The clipboard BRIDGE: WebKit's async clipboard API drops the workbench's copy (the
        // transient user activation is spent by the time VS Code's async path calls `writeText`),
        // so ⌘C in the editor never reached NSPasteboard. The wrap posts the text to the native
        // handler, which writes the pasteboard directly — document START (before the workbench
        // captures the API) and ALL frames (extension webviews copy too).
        controller.addUserScript(WKUserScript(
            source: CodeSidebarPageDressing.clipboardBridgeScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
        ))
        // The webview CANVAS: VS Code webview content documents are transparent at every layer
        // and scroll at frame level, so WebKit painted the slivers a markdown-preview scroll
        // exposes WHITE (`underPageBackgroundColor` and the KVC `drawsBackground` never reach a
        // subframe). Document START (the first paint needs the colour) and ALL frames (the
        // preview lives two iframes deep). See `webviewCanvasScript`.
        controller.addUserScript(WKUserScript(
            source: CodeSidebarPageDressing.webviewCanvasScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
        ))
        controller.add(Self.clipboardBridge, name: CodeSidebarPageDressing.clipboardHandlerName)
    }

    // MARK: LRU

    /// Mark `projectRoot` most-recently-used.
    private func touch(_ projectRoot: String) {
        recency.removeAll { $0 == projectRoot }
        recency.append(projectRoot)
    }

    /// Discard the coldest evictable workbench while the pool sits over
    /// ``warmWebViewCap``. Loops because a burst of mints (or a run of protected entries) can leave
    /// more than one over the line.
    private func evictColdestIfOverCap() {
        while let victim = CodeSidebarFocusPolicy.evictionVictim(
            recency: recency, protected: protectedProjectRoots(), cap: Self.warmWebViewCap,
        ) {
            evict(victim)
        }
    }

    /// The roots eviction must leave alone: whatever is on screen, and whatever is owed a keyboard
    /// The roots eviction must leave alone: whatever is on screen…
    private func protectedProjectRoots() -> Set<String> {
        let mounted = Set(webViews.filter { $0.value.window != nil }.keys)
        #if os(macOS)
        // …and whatever is owed a keyboard hand-back on remount. There is no such debt on
        // the phone: nothing there claims the keyboard for a project in the first place.
        return mounted.union(sidebarFocusMemory.values)
        #else
        return mounted
        #endif
    }

    /// Tear one project's workbench down completely. The webview is unparented by construction (a
    /// mounted one is never a victim); stopping the load first keeps a half-finished navigation
    /// from resolving into a released observer. Every side table drops with it, so the next visit
    /// mints a fresh webview and re-veils honestly through its boot.
    private func evict(_ projectRoot: String) {
        let webView = webViews.removeValue(forKey: projectRoot)
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        navigationObservers.removeValue(forKey: projectRoot)
        loadStates.removeValue(forKey: projectRoot)
        recency.removeAll { $0 == projectRoot }
    }

    /// Hard-reload the project's webview (the strip's reload plate) — a no-op if none exists yet
    /// (the accompanying generation bump re-ensures and mints one). `package` because the plate that
    /// calls it is AppKit, one target up: the panel's strip crossed with docs/56 stage D.
    package func reload(projectRoot: String) {
        webViews[projectRoot]?.reload()
    }

    /// A pooled webview re-entered the hierarchy. A mount is a USE — it is what keeps the project in
    /// rotation ahead of the ones the user has stopped visiting — and on the Mac it may also owe the
    /// keyboard back (``restoreKeyboardOnRemount(projectRoot:)``).
    func noteRemount(projectRoot: String) {
        touch(projectRoot)
        #if os(macOS)
        restoreKeyboardOnRemount(projectRoot: projectRoot)
        #endif
    }

    /// The dressing user-script source, built ONCE per process and shared by every pooled webview.
    /// The faces themselves ride the `slopdesk-font:` scheme (``CodeSidebarFontScheme``) rather
    /// than base64 data URIs, so this string is a couple of KB instead of ~4 MB. A face whose
    /// bundle resource is missing is simply left out of the sheet, never a crash.
    private static let dressingScriptSource: String = CodeSidebarPageDressing.userScript(
        styleSheet: CodeSidebarPageDressing.styleSheet(
            nerdFontURL: fontURL(.nerdSymbols),
            monoUprightURL: fontURL(.monoUpright),
            monoItalicURL: fontURL(.monoItalic),
        ),
    )

    /// The sheet's `src` URL for a face, or `nil` when the bundle has no such resource — the
    /// presence check stays HERE so the sheet never names a URL the handler would 404.
    private static func fontURL(_ face: CodeSidebarFontScheme.Face) -> String? {
        CodeSidebarFontScheme.bundledURL(for: face).map { _ in CodeSidebarFontScheme.url(for: face) }
    }

    /// Serves the `slopdesk-font:` faces to every pooled configuration. One instance for the
    /// process — the handler is stateless (it maps a URL to a memory-mapped bundle file).
    private static let fontSchemeHandler = CodeSidebarFontSchemeHandler()

    /// The clipboard bridge's native side — retained by every pool configuration's user-content
    /// controller; writes each posted copy straight to the general pasteboard.
    private static let clipboardBridge = CodeSidebarClipboardBridge()

    #if os(macOS)

    // MARK: Keyboard restore across warm swaps

    /// A webview took the keyboard (click or restore) — the tab it happened in is a PANEL tab from
    /// now on, reading this project's workbench.
    func noteKeyboardClaimed(projectRoot: String) {
        guard let tab = Self.activeTabID() else { return }
        sidebarFocusMemory[tab] = projectRoot
    }

    /// The one-hop-deferred verdict on a webview resign (see
    /// ``CodeSidebarWKWebView/resignFirstResponder()``) —
    /// ``CodeSidebarFocusPolicy/memoryAfterResign(_:resigningTab:stillInWindow:)`` decides whether
    /// the tab stops being a panel tab.
    func classifyResign(tab: TabID?, stillInWindow: Bool) {
        sidebarFocusMemory = CodeSidebarFocusPolicy.memoryAfterResign(
            sidebarFocusMemory, resigningTab: tab, stillInWindow: stillInWindow,
        )
    }

    /// The Mac's half of a remount. When the tab being remounted into is a PANEL tab
    /// reading THIS project (``CodeSidebarFocusPolicy/shouldRestoreOnRemount(memory:activeTab:projectRoot:)``),
    /// the keyboard is handed back; otherwise the page is told it does not have the keyboard, because
    /// the workbench autofocuses its editor on the remount and would blink a caret beside the
    /// terminal's (see ``CodeSidebarWKWebView/syncFocusTruth()``).
    func restoreKeyboardOnRemount(projectRoot: String) {
        guard CodeSidebarFocusPolicy.shouldRestoreOnRemount(
            memory: sidebarFocusMemory, activeTab: Self.activeTabID(), projectRoot: projectRoot,
        ) else {
            (webViews[projectRoot] as? CodeSidebarWKWebView)?.syncFocusTruth()
            return
        }
        claimWhenMounted(projectRoot: projectRoot)
    }

    /// The workspace switched tabs — honour the arriving tab's focus region
    /// (``CodeSidebarFocusPolicy/tabSwitchFocus(incoming:memory:editorHoldsKeyboard:)``).
    ///
    /// `liveTabs` prunes the memory of tabs that have since closed: the pool cannot see the store,
    /// and a `TabID` nobody can reach again would otherwise sit in the map for the session's life.
    package func noteActiveTabChanged(to tab: TabID?, liveTabs: Set<TabID>) {
        sidebarFocusMemory = sidebarFocusMemory.filter { liveTabs.contains($0.key) }
        switch CodeSidebarFocusPolicy.tabSwitchFocus(
            incoming: tab, memory: sidebarFocusMemory, editorHoldsKeyboard: holdsFirstResponder(),
        ) {
        case let .claimEditor(projectRoot):
            claimWhenMounted(projectRoot: projectRoot)
        case .yieldToWorkspace:
            yieldKeyboardToWorkspace()
        case .leaveAlone:
            break
        }
    }

    /// The workspace moved its focus to a PANE inside the tab already on screen (a split's new leaf,
    /// ⌘-arrow, a rail row, a palette landing) — the tab reads its terminal again, and the keyboard
    /// has to follow.
    ///
    /// Without this the move was silently swallowed whenever the panel held the keyboard: the pane
    /// tree gates every pane's rendered focus on ``CodeSidebarKeyboardState/ownsKeyboard`` (so the
    /// terminal never re-lights and never claims first responder), and no workspace path asks the
    /// webview to resign. A fresh split then arrived with no keyboard, no focus corner and a hollow
    /// cursor, and only a CLICK into it — which forces first responder the hard way — put things
    /// right, which is what made it read as intermittent (user-reported 2026-08-10).
    package func noteWorkspacePaneFocused(tab: TabID?) {
        if let tab { sidebarFocusMemory.removeValue(forKey: tab) }
        guard holdsFirstResponder() else { return }
        yieldKeyboardToWorkspace()
    }

    /// Hand the keyboard to `projectRoot`'s workbench once the pass that asked for it has mounted it
    /// — deferred TWO runloop hops so it lands after the focused terminal's own deferred one-hop
    /// claim (the transition claim scheduled by the same render), settling the race in the editor's
    /// favour exactly once. Re-checked on arrival against BOTH the live memory and what is actually
    /// on screen, so a tab switch the user has already moved on from claims nothing.
    private func claimWhenMounted(projectRoot: String) {
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let pool = Self.shared
                    guard let webView = pool.mountedWebView(),
                          webView.projectRoot == projectRoot,
                          CodeSidebarFocusPolicy.shouldRestoreOnRemount(
                              memory: pool.sidebarFocusMemory,
                              activeTab: Self.activeTabID(),
                              projectRoot: projectRoot,
                          )
                    else { return }
                    webView.claimKeyboardForRestore()
                }
            }
        }
    }

    /// Give the keyboard back to the workspace: drop the ownership flag, which re-lights the active
    /// tab's focused pane and — through the terminal's focus-gated responder claim — has it take
    /// first responder, which is what actually resigns the webview.
    ///
    /// The flag leads the responder move by a hop on purpose (the pool cannot reach into the pane
    /// tree to name a view), so it is re-checked afterwards: when nothing claimed — the tab's
    /// focused pane is a video surface, or there is no pane at all — the editor really does still
    /// have the keyboard and the flag must say so, or the workspace would draw a live cursor for a
    /// pane the keys are not going to.
    private func yieldKeyboardToWorkspace() {
        CodeSidebarKeyboardState.shared.set(false)
        // Long enough for the SwiftUI pass and the pane's own deferred `makeFirstResponder` — this
        // is a repair, and being late costs nothing while being early would undo the hand-back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated {
                guard Self.shared.holdsFirstResponder() else { return }
                CodeSidebarKeyboardState.shared.set(true)
            }
        }
    }

    // MARK: Keyboard focus by chord (⌥⌘R)

    /// Actuates ``CodeSidebarFocusPolicy/focusToggle(webViewHoldsKeyboard:hasMountedWebView:panelCollapsed:)``.
    /// `reveal` shows the panel when it is collapsed; the claim is then deferred until the webview
    /// has actually been mounted by the resulting SwiftUI pass (two hops, the same settling the
    /// warm-swap restore uses). Returns nothing — every outcome is best-effort chrome.
    package func toggleKeyboardFocus(panelCollapsed: Bool, reveal: @MainActor () -> Void) {
        switch CodeSidebarFocusPolicy.focusToggle(
            webViewHoldsKeyboard: holdsFirstResponder(),
            hasMountedWebView: mountedWebView() != nil,
            panelCollapsed: panelCollapsed,
        ) {
        case .handBack:
            guard let owner = lastKeyboardOwner, let window = owner.window else { return }
            window.makeFirstResponder(owner)
        case .claimEditor:
            mountedWebView()?.claimKeyboardForRestore()
        case .revealThenClaim:
            reveal()
            DispatchQueue.main.async {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        Self.shared.mountedWebView()?.claimKeyboardForRestore()
                    }
                }
            }
        case .none:
            break
        }
    }

    /// The pooled webview currently IN the view hierarchy. At most one is mounted at a time (the
    /// column shows the active project's workbench and unmounts the rest — that is what makes a
    /// project switch a warm swap), so this is the chord's unambiguous target.
    private func mountedWebView() -> CodeSidebarWKWebView? {
        webViews.values.lazy.compactMap { $0 as? CodeSidebarWKWebView }.first { $0.window != nil }
    }

    /// Whether the key window's first responder sits inside ANY pooled webview — the
    /// `WorkspaceKeyDispatcher`'s webview-yield predicate (while true, the embedded VS Code owns the
    /// keyboard). Checked per keystroke against the live responder; WebKit's actual first responder is
    /// an internal content subview, hence the descendant walk rather than an identity check.
    package func holdsFirstResponder() -> Bool {
        // `NSApp` is an IMPLICITLY-unwrapped global that is genuinely nil in a headless test process —
        // touch it optionally or the default dispatcher predicate traps every dispatcher unit test.
        guard let app = NSApp as NSApplication?,
              let responder = app.keyWindow?.firstResponder as? NSView
        else { return false }
        return isInsidePooledWebView(responder)
    }

    /// Whether `view` is (inside) any pooled webview — WebKit's actual first responder is an
    /// internal content subview, hence the descendant walk rather than an identity check.
    private func isInsidePooledWebView(_ view: NSView) -> Bool {
        webViews.values.contains { view === $0 || view.isDescendant(of: $0) }
    }
    #endif
}

/// The native side of the clipboard bridge (`CodeSidebarPageDressing.clipboardBridgeScript()`):
/// every copy the embedded workbench performs posts its plain text here, and the handler writes
/// NSPasteboard directly — the WebKit async-clipboard permission dance can no longer drop it.
private final class CodeSidebarClipboardBridge: NSObject, WKScriptMessageHandler {
    func userContentController(
        _: WKUserContentController, didReceive message: WKScriptMessage,
    ) {
        guard message.name == CodeSidebarPageDressing.clipboardHandlerName,
              let text = message.body as? String
        else { return }
        ClientPasteboard.write(text)
    }
}
