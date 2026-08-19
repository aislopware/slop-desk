// CodeSidebarWebView — mounting the pooled workbench on the PHONE, and nothing else.
//
// WHAT IS LEFT HERE IS THE ONLY PART OF A CODE PAGE THAT IS A VIEW. The page itself — the mint, and
// the `WKWebView` subclass that holds the responder seam — went down to `SlopDeskClientCore` with the
// pool it belongs to (docs/56 increment 45), because a `WKWebView` is the platform's view class rather
// than a drawn surface: nothing about minting one lays anything out or reads a design token. Mounting
// one does both, so the mount stayed.
//
// iOS-ONLY SINCE INCREMENT 51. The macOS half was a representable doing four AppKit calls, and it left
// with the rest of the panel — it is ``SlopDeskMacUI/MacCodeWorkbenchView`` now, an `NSView` that does
// the same four things without a `View` above it to justify the wrapper.
//
// The MOUNT is a clipping container rather than the webview itself: SwiftUI destroys a representable's
// product on structural identity changes, and the whole point of ``CodeSidebarWebViewPool`` is that the
// workbench outlives the column's re-renders and project switches. The container is disposable; what
// it holds is not.
//
// THE GROUND TONE IS WRITTEN HERE, ON EVERY UPDATE, AND IT IS THE REASON THE MINT COULD DESCEND. A
// pooled page outlives a theme switch, so a creation-time snapshot would flash the OLD theme's tone
// on a scroll bounce — the re-apply below was never redundant with the mint's copy, it OUTRANKED it,
// and the mint's copy was the redundant one. It also could not have gone down: `SlopDeskSlate`
// depends on `SlopDeskClientCore`, so the tokens cannot be read from there at all.

import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI
import WebKit

#if os(iOS)
import UIKit

/// The webview's mount that DECAPITATES the web title bar. The workbench force-shows its title bar
/// while the activity bar sits at "top" (seed v12), and the grid positions every part with inline
/// absolute geometry, so a CSS `display: none` leaves a dead gap instead of reflowing. The webview is
/// laid out TALLER than the container by exactly the title-bar height and shifted up.
///
/// No hit-test override here. The Mac's has one because the overhang would otherwise sit under the
/// panel's AppKit strip and eat its clicks; `clipsToBounds` already stops UIKit delivering touches
/// outside the container's bounds.
final class CodeSidebarClippedContainer: UIView {}

/// Mounts the pooled webview for one project inside a clipping container view — see the header for
/// why the container and not the webview is what SwiftUI owns.
struct CodeSidebarWebView: UIViewRepresentable {
    let projectRoot: String
    let url: URL

    /// The overhang this container clips — ``CodePanelPresentation/clippedTitleBarHeight``, measured
    /// once and read by both halves. It used to be a `static let` on each mount, which made one
    /// measurement a number two files carried; the doc comment that explains how to re-measure it went
    /// down with the value in increment 51.
    private var topOverhang: CGFloat { CodePanelPresentation.clippedTitleBarHeight }

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
