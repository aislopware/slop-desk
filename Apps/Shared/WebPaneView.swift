// WebPaneView — the PRODUCTION local web-browser surface (`PaneKind.web`, E18; otty
// `spec/user-interface__files-and-links.md` › Web Browser Pane, `web-broswer.png`).
//
// This is the real `WKWebView` the cross-platform `WebLeafView` renders through the headless-safe
// `WebRendererFactory` seam (registered in `AppMain.main()`, exactly like `VideoWindowFactory`). It lives in
// the GUI app target — NOT in any `Package.swift` target — because a `WKWebView` is a GUI/WebKit object that
// must never be instantiated in a headless `swift build` / unit test (the CLAUDE.md hang-safety rule, the
// same reason `SCStream` / `VTCompressionSession` live behind seams). It is compiled by xcodegen+xcodebuild
// (`scripts/check-macos.sh` / `scripts/check-ios.sh`) and verified by GUI run, not by `swift test`.
//
// D9 / otty-spec posture, set on the `WKWebViewConfiguration`:
//   • `websiteDataStore = .nonPersistent()` — no on-disk cookies/cache; nothing bleeds across panes or
//     survives a restart (the pane is a throwaway local surface, never an auth boundary).
//   • `mediaTypesRequiringUserActionForPlayback = .all` — no autoplay; audio/video needs a user gesture.
//
// IN/OUT through the seam:
//   • OUT — a navigation committed inside the live page (`didCommit`) flows back through
//     `WebPaneContext.onNavigated` (address-bar tracking + `PaneSpec.webURL` write-back) and the page title
//     through `onTitle`.
//   • IN  — the view publishes a `WebPaneController` through `onControllerReady` once it exists (and `nil` on
//     teardown), so the chrome's Back / Forward / hard-Reload drive THIS web view and its `canGoBack` /
//     `canGoForward` history greys the buttons (faithful to `web-broswer.png`).
//
// Untrusted-content discipline (CLAUDE.md validate-then-drop): a page-initiated jump to a non-web scheme
// (`javascript:` / `file:` / `data:` …) is CANCELLED in `decidePolicyFor` — only `http(s)`/`about` commit.

#if canImport(WebKit) && (os(macOS) || os(iOS))
import AislopdeskWorkspaceCore
import SwiftUI
import WebKit

#if os(macOS)
import AppKit

typealias WebViewRepresentable = NSViewRepresentable
#else
import UIKit

typealias WebViewRepresentable = UIViewRepresentable
#endif

/// The production `WKWebView`-backed web pane. Cross-platform: an `NSViewRepresentable` on macOS, a
/// `UIViewRepresentable` on iOS (both `@MainActor` protocols, so every method below is main-thread).
struct WebPaneView: WebViewRepresentable {
    let descriptor: WebPaneDescriptor
    let context: WebPaneContext

    func makeCoordinator() -> Coordinator { Coordinator(context: context) }

    #if os(macOS)
    func makeNSView(context ctx: Context) -> WKWebView { makeWebView(ctx.coordinator) }
    func updateNSView(_ webView: WKWebView, context ctx: Context) { sync(webView, ctx.coordinator) }
    static func dismantleNSView(_: WKWebView, coordinator: Coordinator) { coordinator.teardown() }
    #else
    func makeUIView(context ctx: Context) -> WKWebView { makeWebView(ctx.coordinator) }
    func updateUIView(_ webView: WKWebView, context ctx: Context) { sync(webView, ctx.coordinator) }
    static func dismantleUIView(_: WKWebView, coordinator: Coordinator) { coordinator.teardown() }
    #endif

    /// Build the `WKWebView` with the non-persistent store + no-autoplay configuration and kick off the
    /// initial load.
    private func makeWebView(_ coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // D9: no on-disk cookies/cache — nothing persists or bleeds across panes.
        configuration.websiteDataStore = .nonPersistent()
        // otty spec: no autoplay — media requires a user gesture.
        configuration.mediaTypesRequiringUserActionForPlayback = .all

        let webView = WKWebView(frame: .zero, configuration: configuration)
        // otty spec (files-and-links › Web Browser Pane): two-finger trackpad swipe drives Back/Forward.
        // The property lives on `WKWebView` on BOTH macOS and iOS, so this single shared line covers both
        // the `makeNSView` and `makeUIView` slices (alongside the ⌘[/⌘] chords + the chrome buttons).
        webView.allowsBackForwardNavigationGestures = true
        #if os(iOS)
        // Enable the native iOS find-in-page UI so the ⌘F chord (WebLeafView) can present the find navigator.
        webView.isFindInteractionEnabled = true
        #endif
        webView.navigationDelegate = coordinator
        coordinator.attach(webView, initialURL: descriptor.initialURL)
        if let url = descriptor.initialURL {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    /// Re-navigate ONLY when the requested URL LEADS what the live view is showing (an address-bar submit /
    /// Open-In-Place re-nav). The decision is the hang-safe ``WebNavigationGate``: it records page-initiated
    /// navigations (`didCommit`) as already-displayed, so a write-back echo — or a redirect / Back-Forward the
    /// page drove itself — never re-issues a load (ES-E18-4).
    private func sync(_ webView: WKWebView, _ coordinator: Coordinator) {
        coordinator.context = context
        guard let url = coordinator.gate.loadIfLeading(descriptor.initialURL) else { return }
        webView.load(URLRequest(url: url))
    }

    /// Bridges the live `WKWebView` to the cross-platform seam: forwards navigation OUT
    /// (`onNavigated`/`onTitle`) and publishes a `WebPaneController` IN (Back/Forward/Reload). `@MainActor`
    /// because every `WKWebView` touch is main-thread.
    @MainActor
    final class Coordinator: NSObject {
        var context: WebPaneContext
        private weak var webView: WKWebView?
        private var controller: WebPaneController?
        /// The hang-safe load-decision gate: tracks the URL the live view is already showing (the last URL we
        /// loaded OR the last navigation the page committed) so `sync` re-loads only a leading request, never
        /// a page-initiated nav / write-back echo (ES-E18-4).
        var gate = WebNavigationGate()

        init(context: WebPaneContext) {
            self.context = context
            super.init()
        }

        /// Wire the live commands (weakly, so a retained controller can't keep a torn-down web view alive)
        /// and publish the controller so the chrome can drive the page.
        func attach(_ webView: WKWebView, initialURL: URL?) {
            self.webView = webView
            gate = WebNavigationGate(displayedURL: initialURL)
            let controller = WebPaneController(
                goBack: { [weak webView] in webView?.goBack() },
                goForward: { [weak webView] in webView?.goForward() },
                reload: { [weak webView] in webView?.reload() },
                // ⌘⇧R: hard-reload ignoring the cache (re-fetches every resource end-to-end).
                hardReload: { [weak webView] in webView?.reloadFromOrigin() },
                // ⌘F: present the platform's native find-in-page UI.
                find: { [weak webView] in WebPaneView.Coordinator.presentFind(webView) },
            )
            self.controller = controller
            context.onControllerReady?(controller)
        }

        /// Present the native find-in-page UI for `webView`: `UIFindInteraction` on iOS, the macOS find bar
        /// (WKWebView responds to the standard `performTextFinderAction(_:)` → show-find-interface). A no-op
        /// when `webView` is gone or the platform does not surface the action (validate-then-drop).
        static func presentFind(_ webView: WKWebView?) {
            guard let webView else { return }
            #if os(iOS)
            webView.findInteraction?.presentFindNavigator(showingReplace: false)
            #else
            webView.window?.makeFirstResponder(webView)
            let sender = NSMenuItem()
            sender.tag = NSTextFinder.Action.showFindInterface.rawValue
            NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: sender)
            #endif
        }

        /// Clear the published controller so the leaf's model drops its reference when the pane closes.
        func teardown() {
            context.onControllerReady?(nil)
            controller = nil
            webView = nil
        }

        /// Push the live page's navigation history into the controller so the chrome enables/greys
        /// Back / Forward.
        func syncHistory(_ webView: WKWebView) {
            controller?.updateHistory(canGoBack: webView.canGoBack, canGoForward: webView.canGoForward)
        }
    }
}

extension WebPaneView.Coordinator: WKNavigationDelegate {
    /// A navigation committed (link click / redirect / Back-Forward / address-bar load). Record what the view
    /// now shows as already-displayed BEFORE forwarding the write-back, so the `onNavigated` echo (which
    /// changes `WebPaneModel.requestedURL` → a fresh descriptor → `sync`) can't re-load the destination — a
    /// genuine page-driven navigation must NOT double-load or truncate history (ES-E18-4).
    func webView(_ webView: WKWebView, didCommit _: WKNavigation?) {
        gate.recordCommitted(webView.url)
        if let url = webView.url { context.onNavigated(url) }
        syncHistory(webView)
    }

    /// The page finished loading — final history + title (otty titles the pane after the loaded page).
    func webView(_ webView: WKWebView, didFinish _: WKNavigation?) {
        syncHistory(webView)
        if let title = webView.title, !title.isEmpty { context.onTitle(title) }
    }

    // Validate-then-drop: only http(s)/about commit; a page-initiated jump to a non-web scheme
    // (javascript:/file:/data: …) is cancelled (the non-persistent local surface is never coaxed into a
    // dangerous scheme). The async delegate variant takes no escaping completion handler; `async` is
    // required to match the refined WKNavigationDelegate signature even though the decision is synchronous.
    // swiftlint:disable:next async_without_await
    func webView(_: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let scheme = action.request.url?.scheme?.lowercased() else { return .cancel }
        return (scheme == "http" || scheme == "https" || scheme == "about") ? .allow : .cancel
    }
}
#endif
