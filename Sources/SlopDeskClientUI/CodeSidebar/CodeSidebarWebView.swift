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

/// The per-project webview pool. `@MainActor` (WKWebView is main-thread only); keyed by the
/// project's canonical root (the host-pushed `projectKey` — the same key the sidebar sections and the
/// host's `CodeServerManager` instances use, so pool entry ↔ code-server instance is 1:1).
@MainActor
final class CodeSidebarWebViewPool {
    static let shared = CodeSidebarWebViewPool()

    private var webViews: [String: WKWebView] = [:]

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
        let webView = WKWebView(frame: .zero, configuration: configuration)
        // Right-click → Inspect Element on the embedded workbench (Safari Web Inspector) — the only
        // window into a misbehaving code-server page.
        webView.isInspectable = true
        // Paint the theme backdrop behind the page so the first load / a bounce never flashes white
        // against the dark chrome (the cmux `underPageBackgroundColor` trick).
        webView.underPageBackgroundColor = NSColor(slateBackdropHex: Slate.theme.terminalBackgroundHex)
        webView.load(URLRequest(url: url))
        webViews[projectRoot] = webView
        return webView
    }

    /// Hard-reload the project's webview (the header's reload button) — a no-op if none exists yet
    /// (the accompanying generation bump re-ensures and mints one).
    func reload(projectRoot: String) {
        webViews[projectRoot]?.reload()
    }

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

/// Mounts the pooled webview for one project inside a plain container view. A container (not the
/// webview itself) because the pooled NSView must survive this representable's teardown — SwiftUI
/// destroys `makeNSView`'s product on structural identity changes, and the whole point of the pool
/// is that the workbench outlives the column's re-renders and project switches.
struct CodeSidebarWebView: NSViewRepresentable {
    let projectRoot: String
    let url: URL

    func makeNSView(context _: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
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
            webView.topAnchor.constraint(equalTo: container.topAnchor),
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
