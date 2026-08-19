// CodeSidebarWebView — mounting the pooled workbench, and nothing else.
//
// WHAT IS LEFT HERE IS THE ONLY PART OF A CODE PAGE THAT IS A VIEW. The page itself — the mint, and
// on the Mac the `WKWebView` subclass that holds the responder seam — went down to
// `SlopDeskClientCore` with the pool it belongs to (docs/56 increment 45), because a `WKWebView` is
// the platform's view class rather than a drawn surface: nothing about minting one lays anything out
// or reads a design token. Mounting one does both, so the mount stayed.
//
// The MOUNT is a clipping container rather than the webview itself, on both platforms, and for a
// reason that has nothing to do with either: SwiftUI destroys a representable's product on
// structural identity changes, and the whole point of ``CodeSidebarWebViewPool`` is that the
// workbench outlives the column's re-renders and project switches. The container is disposable; what
// it holds is not.
//
// THE GROUND TONE IS WRITTEN HERE, ON EVERY UPDATE, AND IT IS THE REASON THE MINT COULD DESCEND. A
// pooled page outlives a theme switch, so a creation-time snapshot would flash the OLD theme's tone
// on a scroll bounce — the re-apply below was never redundant with the mint's copy, it OUTRANKED it,
// and the mint's copy was the redundant one. It also could not have gone down: `SlopDeskSlate`
// depends on `SlopDeskClientCore`, so the tokens cannot be read from there at all. One writer, in
// the target that has them.
//
// The two halves differ only in framework. Both clip the same overhang, both re-apply the same
// colour, both hand the pool a remount note; the Mac's container additionally guards hit-testing,
// which its own doc comment explains.

import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI
import WebKit

#if os(macOS)
import AppKit

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

    /// The web workbench title bar's laid-out height at zoom 1 (30px on Code 1.131). The webview
    /// overhangs the container by this much; see ``CodeSidebarClippedContainer``. Coupled to seed
    /// v12's `activityBar.location: "top"` — a seed that stops forcing the title bar should retire
    /// this to 0.
    ///
    /// It is NOT a CSS constant to grep: the workbench grid positions its parts with inline
    /// geometry, so the honest measurement is the laid-out box —
    /// `document.querySelector('#workbench\\.parts\\.titlebar').getBoundingClientRect().height`
    /// against a real workbench. It went 35 → 30 across Code 1.112 → 1.131; re-measure on every
    /// code-server bump, because being wrong here clips the editor tab row instead.
    static let clippedTitleBarHeight: CGFloat = 30

    private var topOverhang: CGFloat { Self.clippedTitleBarHeight }

    func makeNSView(context _: Context) -> NSView {
        let container = CodeSidebarClippedContainer()
        container.wantsLayer = true
        container.clipsToBounds = true
        return container
    }

    func updateNSView(_ container: NSView, context _: Context) {
        let webView = CodeSidebarWebViewPool.shared.webView(for: projectRoot, url: url)
        // Re-apply the theme backdrop on every update: the pooled webview outlives a theme
        // switch, and the creation-time snapshot would otherwise flash the OLD theme's tone on
        // scroll bounce (an appearance flip re-runs this via the colorScheme environment change).
        webView.underPageBackgroundColor = SlateNativeColor(slateHex: Slate.theme.groundHexValue)
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor, constant: -topOverhang),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        // A (re)mount may owe the keyboard back — the warm-swap focus restore (a first-ever mount
        // has no restore armed; the call is then a no-op).
        CodeSidebarWebViewPool.shared.noteRemount(projectRoot: projectRoot)
    }
}

#elseif os(iOS)
import UIKit

/// The webview's mount that DECAPITATES the web title bar — the phone's half of
/// ``CodeSidebarClippedContainer``. Same clip, same reason: the workbench force-shows its title bar
/// while the activity bar sits at "top" (seed v12), and the grid positions every part with inline
/// absolute geometry, so a CSS `display: none` leaves a dead gap instead of reflowing. The webview is
/// laid out TALLER than the container by exactly the title-bar height and shifted up.
///
/// No hit-test override here. The Mac's exists because the overhang would otherwise sit under the
/// panel's AppKit strip and eat its clicks; `clipsToBounds` already stops UIKit delivering touches
/// outside the container's bounds.
final class CodeSidebarClippedContainer: UIView {}

/// Mounts the pooled webview for one project inside a clipping container view — see the header for
/// why the container and not the webview is what SwiftUI owns.
struct CodeSidebarWebView: UIViewRepresentable {
    let projectRoot: String
    let url: URL

    /// The web workbench title bar's laid-out height at zoom 1 — one number, measured once, shared
    /// with the AppKit half's ``CodeSidebarWebView/clippedTitleBarHeight``. It is NOT a CSS constant
    /// to grep: the workbench grid positions its parts with inline geometry, so the honest
    /// measurement is the laid-out box. Re-measure on every code-server bump, because being wrong
    /// here clips the editor tab row instead.
    static let clippedTitleBarHeight: CGFloat = 30

    private var topOverhang: CGFloat { Self.clippedTitleBarHeight }

    func makeUIView(context _: Context) -> UIView {
        let container = CodeSidebarClippedContainer()
        container.clipsToBounds = true
        return container
    }

    func updateUIView(_ container: UIView, context _: Context) {
        let webView = CodeSidebarWebViewPool.shared.webView(for: projectRoot, url: url)
        // Re-apply the theme backdrop on every update, for the reason the AppKit half records: the
        // pooled webview outlives a theme switch, and the creation-time snapshot would otherwise
        // flash the OLD theme's tone on scroll bounce.
        webView.underPageBackgroundColor = SlateNativeColor(slateHex: Slate.theme.groundHexValue)
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor, constant: -topOverhang),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        CodeSidebarWebViewPool.shared.noteRemount(projectRoot: projectRoot)
    }
}
#endif
