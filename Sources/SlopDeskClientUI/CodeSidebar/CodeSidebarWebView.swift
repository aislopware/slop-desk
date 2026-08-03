// CodeSidebarWebView — the WKWebView carrying the project-scoped embedded VS Code (code-server),
// plus the per-project keep-alive pool behind it.
//
// The pool is the load-bearing piece (the cmux lesson): ONE WKWebView per project root, created on
// first expand and kept for the app's lifetime, so switching the focused pane between projects swaps
// an already-warm workbench back in instantly instead of re-booting the whole VS Code renderer
// (multi-second, editor state lost). A detached WKWebView keeps its web-content process alive; the
// idle throttling that comes with being unparented is fine for an editor (no background work needed).
//
// HANG-SAFETY: nothing in the unit-test dependency closure may construct a WKWebView — the pool is
// only reached from the macOS column view; all decision logic lives in `CodeSidebarModel` (pure).

#if os(macOS)
import AppKit
import SwiftUI
import WebKit

/// When a `becomeFirstResponder` on the embedded workbench may be HONORED. VS Code aggressively
/// focuses its own editor — on load, on file open, on layout changes — and WebKit forwards each
/// page-level `focus()` as a first-responder claim. Unguarded, an autofocus mid-keystroke silently
/// re-routes the keyboard from the terminal to the editor (the cmux focus-steal lesson). The rule:
/// only a direct user MOUSE-DOWN inside the webview hands VS Code the keyboard; everything else
/// (JS autofocus arrives with no current event, or riding whatever unrelated event is current) is
/// refused. Pure — pinned by `CodeSidebarFocusPolicyTests`.
enum CodeSidebarFocusPolicy {
    static func shouldAcceptFocus(eventType: NSEvent.EventType?, clickWasInsideWebView: Bool) -> Bool {
        switch eventType {
        case .leftMouseDown,
             .otherMouseDown,
             .rightMouseDown:
            clickWasInsideWebView
        default:
            false
        }
    }

    /// App/window-management chords the embedded workbench may NEVER own. `WKWebView`'s
    /// `performKeyEquivalent` claims ⌘-chords for the page BEFORE the main menu gets a look, so with
    /// the editor focused ⌘Q simply vanished into VS Code's key handling instead of quitting. These
    /// are refused at the responder seam (the event falls through to the menu bar); everything else —
    /// ⌘W (close editor tab), ⌘, (VS Code settings), ⌘P/⌘F/… — stays with the workbench, which the
    /// user focused ON PURPOSE (the click-to-focus rule above). Pure — pinned by
    /// `CodeSidebarFocusPolicyTests`. The key arrives as `charactersIgnoringModifiers` lowercased.
    static func isReservedAppChord(modifiers: NSEvent.ModifierFlags, key: String?) -> Bool {
        guard let key else { return false }
        let chord = modifiers.intersection([.command, .shift, .option, .control])
        switch (chord, key) {
        case ([.command], "q"), // Quit
             ([.command], "h"), // Hide SlopDesk
             ([.command, .option], "h"), // Hide Others
             ([.command], "m"), // Minimize
             ([.command], "`"): // Cycle app windows
            return true
        default:
            return false
        }
    }
}

/// The pooled webview class: applies ``CodeSidebarFocusPolicy`` at the responder seam, so the
/// embedded VS Code can never STEAL the keyboard — it can only be handed it by a click.
final class CodeSidebarWKWebView: WKWebView {
    override func becomeFirstResponder() -> Bool {
        // `NSApp` is nil in a headless test process — optional access, never the implicit unwrap.
        guard let app = NSApp as NSApplication?,
              CodeSidebarFocusPolicy.shouldAcceptFocus(
                  eventType: app.currentEvent?.type,
                  clickWasInsideWebView: app.currentEvent.map(eventLandsInside) ?? false,
              )
        else { return false }
        return super.becomeFirstResponder()
    }

    /// Whether `event`'s location falls inside THIS webview — same window, point within bounds.
    private func eventLandsInside(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        return bounds.contains(convert(event.locationInWindow, from: nil))
    }

    /// Refuse the app-reserved chords (``CodeSidebarFocusPolicy/isReservedAppChord(modifiers:key:)``)
    /// so they continue up to the main menu — WebKit's own implementation forwards ⌘-chords to the
    /// page and returns `true`, which is how a focused editor swallowed ⌘Q whole.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if CodeSidebarFocusPolicy.isReservedAppChord(
            modifiers: event.modifierFlags,
            key: event.charactersIgnoringModifiers?.lowercased(),
        ) { return false }
        return super.performKeyEquivalent(with: event)
    }
}

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
final class CodeSidebarWebViewPool {
    static let shared = CodeSidebarWebViewPool()

    private var webViews: [String: WKWebView] = [:]
    private var loadStates: [String: CodeSidebarWebLoadState] = [:]
    private var navigationObservers: [String: CodeSidebarNavigationObserver] = [:]

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
    /// code-server on a fresh port); the workbench otherwise owns its own navigation.
    func webView(for projectRoot: String, url: URL) -> WKWebView {
        if let existing = webViews[projectRoot] {
            if CodeSidebarModel.endpointMoved(current: existing.url, target: url) {
                existing.load(URLRequest(url: url))
            }
            return existing
        }
        let configuration = WKWebViewConfiguration()
        // No user-gesture gate on media — VS Code's own UI sounds/previews must not silently stall.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // The finishing coat (terminal-mono + nerd-font @font-faces, Slate softening, slopcat
        // letterpress) rides every navigation — user scripts persist on the controller, so a
        // reload/respawn re-dresses itself.
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.dressingScriptSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
        ))
        // The clipboard BRIDGE: WebKit's async clipboard API drops the workbench's copy (the
        // transient user activation is spent by the time VS Code's async path calls `writeText`),
        // so ⌘C in the editor never reached NSPasteboard. The wrap posts the text to the native
        // handler, which writes the pasteboard directly — document START (before the workbench
        // captures the API) and ALL frames (extension webviews copy too).
        configuration.userContentController.addUserScript(WKUserScript(
            source: CodeSidebarPageDressing.clipboardBridgeScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
        ))
        configuration.userContentController.add(
            Self.clipboardBridge, name: CodeSidebarPageDressing.clipboardHandlerName,
        )
        let webView = CodeSidebarWKWebView(frame: .zero, configuration: configuration)
        // Right-click → Inspect Element on the embedded workbench (Safari Web Inspector) — the only
        // window into a misbehaving code-server page.
        webView.isInspectable = true
        // Paint the theme backdrop behind the page so the first load / a bounce never flashes white
        // against the dark chrome (the cmux `underPageBackgroundColor` trick).
        webView.underPageBackgroundColor = NSColor(slateBackdropHex: Slate.theme.terminalBackgroundHex)
        // WebKit's own base canvas is WHITE until the page's first paint — with a multi-second
        // workbench boot that is a visible flash between the dark chrome and the dark editor. There
        // is no public macOS API for it; the long-standing KVC key makes the canvas transparent so
        // the dark column shows through instead.
        webView.setValue(false, forKey: "drawsBackground")
        let observer = CodeSidebarNavigationObserver(state: loadState(for: projectRoot))
        navigationObservers[projectRoot] = observer
        webView.navigationDelegate = observer
        webView.load(URLRequest(url: url))
        webViews[projectRoot] = webView
        return webView
    }

    /// Hard-reload the project's webview (the header's reload button) — a no-op if none exists yet
    /// (the accompanying generation bump re-ensures and mints one).
    func reload(projectRoot: String) {
        webViews[projectRoot]?.reload()
    }

    /// The dressing user-script source, built ONCE per process — the base64 font payloads total
    /// ~4 MB (nerd symbols + the two JetBrains Mono variable faces), shared by every pooled
    /// webview. Any missing bundle resource degrades to the remaining sheet parts, never a crash.
    private static let dressingScriptSource: String = CodeSidebarPageDressing.userScript(
        styleSheet: CodeSidebarPageDressing.styleSheet(
            nerdFontBase64: base64Resource(NerdSymbolFont.bundledFontURL),
            monoUprightBase64: base64Resource(JetBrainsMonoFont.bundledUprightURL),
            monoItalicBase64: base64Resource(JetBrainsMonoFont.bundledItalicURL),
        ),
    )

    private static func base64Resource(_ url: URL?) -> String? {
        url.flatMap { try? Data(contentsOf: $0) }?.base64EncodedString()
    }

    /// The clipboard bridge's native side — retained by every pool configuration's user-content
    /// controller; writes each posted copy straight to the general pasteboard.
    private static let clipboardBridge = CodeSidebarClipboardBridge()

    /// Whether the key window's first responder sits inside ANY pooled webview — the
    /// `WorkspaceKeyDispatcher`'s webview-yield predicate (while true, the embedded VS Code owns the
    /// keyboard). Checked per keystroke against the live responder; WebKit's actual first responder is
    /// an internal content subview, hence the descendant walk rather than an identity check.
    func holdsFirstResponder() -> Bool {
        // `NSApp` is an IMPLICITLY-unwrapped global that is genuinely nil in a headless test process —
        // touch it optionally or the default dispatcher predicate traps every dispatcher unit test.
        guard let app = NSApp as NSApplication?,
              let responder = app.keyWindow?.firstResponder as? NSView
        else { return false }
        return webViews.values.contains { responder === $0 || responder.isDescendant(of: $0) }
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
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// The webview's mount that DECAPITATES the web title bar. The workbench force-shows its title
/// bar while the activity bar sits at "top" (seed v12 — the band must host the relocated
/// accounts/manage actions), and the grid positions every part with inline absolute geometry, so
/// a CSS `display: none` leaves a dead gap instead of reflowing. The clip is the clean cut: the
/// webview is laid out TALLER than the container by exactly the title-bar height and shifted up,
/// so the band renders above the clip line — the workbench still believes in it, the user never
/// sees it (user-directed 2026-08-03). Hit-testing is bounds-guarded: without it the overhang
/// would sit under the panel's strip and eat its clicks.
final class CodeSidebarClippedContainer: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview, bounds.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
}

/// Mounts the pooled webview for one project inside a clipping container view. A container (not
/// the webview itself) because the pooled NSView must survive this representable's teardown —
/// SwiftUI destroys `makeNSView`'s product on structural identity changes, and the whole point of
/// the pool is that the workbench outlives the column's re-renders and project switches.
struct CodeSidebarWebView: NSViewRepresentable {
    let projectRoot: String
    let url: URL

    /// The web workbench title bar's CSS height (35px at zoom 1 — VS Code's fixed titlebar
    /// metric, pixel-verified against 4.112). The webview overhangs the container by this much;
    /// see ``CodeSidebarClippedContainer``. Coupled to seed v12's `activityBar.location: "top"` —
    /// a seed that stops forcing the title bar should retire this to 0.
    static let clippedTitleBarHeight: CGFloat = 35

    func makeNSView(context _: Context) -> NSView {
        let container = CodeSidebarClippedContainer()
        container.wantsLayer = true
        container.clipsToBounds = true
        return container
    }

    func updateNSView(_ container: NSView, context _: Context) {
        let webView = CodeSidebarWebViewPool.shared.webView(for: projectRoot, url: url)
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(
                equalTo: container.topAnchor, constant: -Self.clippedTitleBarHeight,
            ),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

private extension NSColor {
    /// Concrete sRGB colour from the theme's 6-hex backdrop string — appearance-stable (the
    /// SwiftUI-Color→NSColor bridge resolves through the effective appearance and can read wrong on
    /// light themes; a plain sRGB triple cannot).
    convenience init(slateBackdropHex hex: String) {
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
