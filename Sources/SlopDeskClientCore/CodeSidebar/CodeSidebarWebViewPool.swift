// CodeSidebarWebViewPool — one warm WKWebView per project root, and the user scripts every one of
// them wears.
//
// The pool is the load-bearing piece (the cmux lesson): ONE webview per project root, created on
// first expand and kept for as long as the cap allows, so switching the focused pane between
// projects swaps an already-warm workbench back in instantly instead of re-booting the whole VS Code
// renderer (multi-second, editor state lost). A detached webview keeps its web-content process
// alive; the idle throttling that comes with being unparented is fine for an editor.
//
// THE POOL'S WHOLE SUBJECT IS PROJECTS AND THEIR PAGES, on both platforms, AND SAYING SO NOW COSTS
// NOT ONE `#if` — nor an import that needs one. The five user scripts, the LRU and its eviction, the
// veil state and the reload are one law with no platform in it, and the file is to be kept that way:
// a gate appearing here again is the signal that whatever it guards belongs in a file that already
// has halves, not that this file needs coats. What used to sit under all of that — the per-tab focus
// region, the resign classification, the ⌥⌘R toggle and the orphan repair — was never about projects
// at all: it exists because a focused embedded VS Code and a focused terminal are two AppKit first
// responders duelling over one window. That is `MacCodeSidebarKeyboard` (`SlopDeskMacUI`) now, and it
// left because a platform gate inside a shared file is a file wearing two coats (docs/56 §3). iOS has
// no such duel — no app-level event monitor, no menu bar, no shared field editor — so the phone
// installs nothing and every keyboard line below costs one nil-check. The last gate, the MINT, went
// to `CodeSidebarWebView.swift` for the same reason and by the same argument (docs/56 increment 43).
//
// THE SEAM IS TWO NARROW PROTOCOLS AND NEITHER NAMES A FRAMEWORK. ``CodeSidebarKeyboard`` is the duel
// as the pool sees it (a project root, a page — the pool's own vocabulary, so the AppKit stays on the
// far side of it), and ``CodeSidebarKeyboardPage`` is a pooled page as the duel sees it. The second
// one has to exist: the Mac's `WKWebView` subclass IS the responder seam, `check-supervisor.sh` keeps
// its name inside the two files that own it, and the duel one target up therefore has to ask a page
// for what it can do rather than for what it is.
//
// HANG-SAFETY: nothing in the unit-test dependency closure may construct a WKWebView — the pool is
// only reached from a mounted panel column; all decision logic lives in `CodeSidebarFocusPolicy` and
// `CodeSidebarModel` (both pure).
//
// NO APPKIT/UIKIT IMPORT, AND THE ONE PLATFORM MEMBER LEFT DOES NOT NEED ONE. `window` — the mounted
// test in ``protectedProjectRoots()`` and ``mountedPage()`` — is inherited from `NSView` here and
// `UIView` there, and WebKit already brings its own superclass's framework into scope, so the member
// resolves without this file naming either. That is not a trick: it is the same fact the pool's whole
// design rests on, that `WKWebView` IS the platform's view type on both. Everything else the pool
// touches is `WKWebView`, `URL` and `String`.

import SlopDeskWorkspaceCore
import WebKit

/// The platform's keyboard duel, as the pool and its pages see it — installed by the shell that has
/// one. macOS installs ``SlopDeskMacUI/MacCodeSidebarKeyboard`` at app composition; the phone leaves
/// it nil, because nothing there claims the keyboard for a project in the first place.
///
/// Every member is stated in projects and pages, never in views, which is what lets the pool hold one
/// of these without a gate.
@MainActor
package protocol CodeSidebarKeyboard: AnyObject {
    /// The project roots OWED a keyboard hand-back on their next remount. Eviction must leave them
    /// alone — the debt dies with the page, and the user would land in a terminal they never aimed at.
    var projectRootsOwedKeyboard: Set<String> { get }

    /// A pooled page re-entered the view hierarchy and may be owed the keyboard back.
    func noteRemount(projectRoot: String)

    /// A page took the keyboard — by a click, or by the duel's own app-directed restore.
    func noteKeyboardClaimed(projectRoot: String)

    /// A page gave the keyboard up. Called SYNCHRONOUSLY from the resign so the duel can read the tab
    /// it happened in; the cause is classified a runloop later, once any swap has finished unparenting.
    func noteResign(of page: CodeSidebarPooledPage)

    /// A page REFUSED a focus pull mid-`makeFirstResponder`, which strands first responder on the
    /// window — every key dead until the next click. Hand the keyboard back to whoever held it.
    func repairOrphanedFocus(after page: CodeSidebarPooledPage)
}

/// What a duel needs of a pooled page: which project it serves, and the two moves only the page
/// itself can make. Nothing here is a decision — every one of those is in ``CodeSidebarFocusPolicy``.
@MainActor
package protocol CodeSidebarKeyboardPage: AnyObject {
    /// The pool key this page serves — the focus-region bookkeeping is keyed by it.
    var projectRoot: String { get }
    /// Take the keyboard because the APP said so. The one non-click path a page may become first
    /// responder through; a page-level `focus()` can never reach it.
    func claimKeyboardForRestore()
    /// Make the PAGE agree about whether it has the keyboard, so only the real owner draws a caret.
    func syncFocusTruth()
}

/// A pooled page as the duel handles it — the webview AND the seam it carries. A composition rather
/// than a `window` member on the protocol, because `WKWebView` already IS the platform's view type on
/// both platforms: the duel reads `page.window` directly and this line still needs no gate.
package typealias CodeSidebarPooledPage = CodeSidebarKeyboardPage & WKWebView

/// Per-project veil state for the workbench's main-frame navigation. The webview stays COVERED by
/// the column's dark waiting surface from load-start until the navigation settles — WebKit paints
/// its default white between the provisional commit and the page's own (dark) first paint, and in a
/// multi-second code-server cold boot that reads as black → white flash → workbench. `@Observable`
/// so the column's overlay fades out exactly on settle; a reload re-veils through the same events.
@MainActor
@Observable
package final class CodeSidebarWebLoadState {
    package private(set) var veiled = true
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

    /// The platform's keyboard duel, or `nil` where there is none to fight. Installed by the shell
    /// that has one — never built here, because the target that owns the duel sits ABOVE this one
    /// (docs/56 §2) and a floor cannot name its own ceiling.
    package var keyboard: (any CodeSidebarKeyboard)?

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

    /// The project's veil state — the column reads `veiled` to hold its dark waiting surface over
    /// the webview until the workbench paints. Created on demand so the read can precede the
    /// webview's own creation in the same body evaluation.
    package func loadState(for projectRoot: String) -> CodeSidebarWebLoadState {
        if let existing = loadStates[projectRoot] { return existing }
        let state = CodeSidebarWebLoadState()
        loadStates[projectRoot] = state
        return state
    }

    /// The (created-on-first-use) webview for `projectRoot`, pointed at `url`. An existing entry is
    /// re-loaded ONLY when the endpoint moved (`CodeSidebarModel.endpointMoved` — a respawned
    /// service on a fresh port); the page otherwise owns its own navigation.
    ///
    package func webView(for projectRoot: String, url: URL) -> WKWebView {
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
        // Minting the page is the ONE thing about a warm page that is not one law — subclass-vs-plain,
        // chrome polarity, base-canvas kill: three decisions, three spellings, one meaning. It lives
        // in `CodeSidebarWebView.swift`, which is already two per-platform halves, so the pool builds
        // the configuration (which has no platform in it) and takes back a dressed page whose class
        // it never learns. That is the whole reason this file has no `#if` in it.
        let webView = CodeSidebarPageMint.page(projectRoot: projectRoot, configuration: configuration)
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

    /// The roots eviction must leave alone: whatever is on screen, and whatever the platform's duel
    /// says is owed a keyboard hand-back on remount. The phone has no such debt and no duel, so the
    /// second half of that union is empty there rather than absent — which is what turns a gate into
    /// one `??`.
    private func protectedProjectRoots() -> Set<String> {
        let mounted = Set(webViews.filter { $0.value.window != nil }.keys)
        return mounted.union(keyboard?.projectRootsOwedKeyboard ?? [])
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
    /// rotation ahead of the ones the user has stopped visiting — and where a duel exists it may also
    /// owe the keyboard back. Two things in one word, which is precisely why the pool could not cross
    /// until they came apart: the recency touch is every platform's, the hand-back is the duel's.
    package func noteRemount(projectRoot: String) {
        touch(projectRoot)
        keyboard?.noteRemount(projectRoot: projectRoot)
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

    // MARK: The duel's window onto the pool

    /// The pooled page currently IN the view hierarchy, if it carries a responder seam. At most one
    /// is mounted at a time (the column shows the active project's workbench and unmounts the rest —
    /// that is what makes a project switch a warm swap), so this is the duel's unambiguous target.
    /// Always `nil` on the phone, where no page conforms and there is nothing asking.
    package func mountedPage() -> CodeSidebarPooledPage? {
        webViews.values.lazy.compactMap { $0 as? CodeSidebarPooledPage }.first { $0.window != nil }
    }

    /// This project's warm page, mounted or not — the duel tells a page it does NOT have the keyboard
    /// on a remount it is not owed, and that page may be off-window at the time.
    package func page(for projectRoot: String) -> CodeSidebarPooledPage? {
        webViews[projectRoot] as? CodeSidebarPooledPage
    }

    /// Every warm page. The duel walks them to answer whether the key window's first responder sits
    /// inside the embedded workbench — WebKit's actual first responder is an internal content
    /// subview, so that question is a DESCENDANT walk rather than an identity check, and it needs the
    /// whole set rather than the mounted one (a satellite window can be key over an unmounted page).
    package func pooledWebViews() -> [WKWebView] {
        Array(webViews.values)
    }
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
