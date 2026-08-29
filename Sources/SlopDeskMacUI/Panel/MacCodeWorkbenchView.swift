// MacCodeWorkbenchView — mounting the pooled workbench, in AppKit (docs/56 stage D, increment 51).
//
// It came from the macOS half of the deleted `CodeSidebarWebView`, whose phone half is now
// `Sources/SlopDeskPhoneUI/Panel/PhoneCodeWorkbenchView.swift` — this file's twin, one framework
// later. The move is smaller than it looks, and that is the point: the representable was never doing
// SwiftUI work. It made a clipping container, put the pooled `WKWebView` in it, wrote a colour and
// told the pool it had remounted — four AppKit calls wearing an `NSViewRepresentable` because the
// thing above it happened to be a `View`.
//
// THE MOUNT IS A CLIPPING CONTAINER, NEVER THE WEBVIEW ITSELF. Under SwiftUI that was because a
// representable's product is destroyed on structural identity changes; here it is because a surface
// swap tears down the surface and ``CodeSidebarWebViewPool``'s whole purpose is that the workbench
// outlives it. The container is disposable; what it holds is not.
//
// THE GROUND TONE IS WRITTEN ON EVERY MOUNT, and that is why the pool's page mint could descend to
// `SlopDeskClientCore` in increment 45 while this could not. A pooled page outlives a theme switch, so
// a creation-time snapshot flashes the OLD theme's tone on a scroll bounce — this re-apply never was
// redundant with the mint's copy, it OUTRANKED it. And it could not have gone down with the mint:
// `SlopDeskSlate` depends on `SlopDeskClientCore`, so the tokens are not readable from there at all.

import AppKit
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import WebKit

/// The webview's mount that DECAPITATES the web title bar.
///
/// The workbench force-shows its title bar while the activity bar sits at "top" (seed v12), and the
/// grid positions every part with inline absolute geometry, so a CSS `display: none` leaves a dead gap
/// instead of reflowing. The clip is the clean cut: the webview is laid out taller than this view by
/// exactly ``CodePanelPresentation/clippedTitleBarHeight`` and shifted up, so the band renders above
/// the clip line — the workbench still believes in it, the reader never sees it.
///
/// Hit-testing is bounds-guarded: without it the overhang sits under the panel's strip and eats its
/// clicks. That guard is the Mac's alone — the phone's container gets it from `clipsToBounds`, which
/// on UIKit also stops touch delivery, and on AppKit does not.
@MainActor
final class MacCodeWorkbenchView: NSView {
    private let projectRoot: String
    private let url: URL

    /// The dark waiting surface that stays on top from load-start until the main-frame navigation
    /// settles. Without it the boot reads as black → WebKit's white canvas → workbench.
    ///
    /// The caption comes FROM THE FLOOR: the phone's workbench boots behind the same veil saying the
    /// same thing, and a sentence spelled once per shell is a translation bug that has already
    /// happened (docs/56 §3, `shared-vocabulary-ceiling`).
    private let veil = MacPanelWaitingView(PanelChromeCopy.workbenchVeilLabel)
    private var veilObservation: Task<Void, Never>?

    init(projectRoot: String, url: URL) {
        self.projectRoot = projectRoot
        self.url = url
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true

        mountPooledWebView()
        mountVeil()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    deinit { veilObservation?.cancel() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview, bounds.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

    /// The pooled page, re-parented under this container and re-toned.
    ///
    /// The pool answers with the SAME `WKWebView` for a root it already holds, so a project switch back
    /// is a re-parent rather than a load — which is the warm swap the pool exists for. Both ends of that
    /// swap are this view's: the ASK, and the `noteRemount` that may owe the keyboard back.
    ///
    /// The re-parenting in between is the floor's (``PanelChromeWorkbenchMount/pin(_:in:liftedBy:)``),
    /// which the two shells had transcribed line for line — `WKWebView` is one class on both platforms
    /// and the anchors are one Auto Layout. The lift it is given is ``CodePanelPresentation``'s one
    /// number, named here because this is the view that clips to match it.
    private func mountPooledWebView() {
        let page = CodeSidebarWebViewPool.shared.webView(for: projectRoot, url: url)
        page.underPageBackgroundColor = SlateNativeColor(slateHex: Slate.theme.groundHexValue)
        PanelChromeWorkbenchMount.pin(page, in: self, liftedBy: CodePanelPresentation.clippedTitleBarHeight)
        // A (re)mount may owe the keyboard back — the warm-swap focus restore. A first-ever mount has
        // no restore armed, so the call is then a no-op.
        CodeSidebarWebViewPool.shared.noteRemount(projectRoot: projectRoot)
    }

    /// The veil, above the page, on the panel's own ground so the boot never shows WebKit's white.
    ///
    /// Its state is per-project and pooled WITH the webview, which is what makes a warm project swap
    /// mount unveiled rather than flashing a spinner at a page that is already painted.
    private func mountVeil() {
        veil.wantsLayer = true
        veil.layer?.backgroundColor = Slate.Native.Surface.field.cgColor
        addSubview(veil)
        NSLayoutConstraint.activate(veil.slateEdges(of: self))
        followVeil()
    }

    /// Follow the pooled load state until it lifts.
    ///
    /// The following goes quiet once the veil is down, because the state only ever falls: a page that
    /// finished loading does not go back to loading, and the reload path mints a fresh state with a
    /// fresh observer.
    private func followVeil() {
        // The pooled state is resolved OUT here, as it was outside the tracked block before: `read`
        // observes the flag on this one state, never the pool's own bookkeeping.
        let state = CodeSidebarWebViewPool.shared.loadState(for: projectRoot)
        ObservationFollow.arm(self) { _ in
            state.veiled
        } apply: { view, veiled in
            guard view.veil.isHidden != !veiled else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Slate.Motion.smallFade.duration
                context.timingFunction = Slate.Motion.smallFade.timingFunction
                view.veil.animator().alphaValue = veiled ? 1 : 0
            } completionHandler: { [weak view] in
                view?.veil.isHidden = !veiled
            }
        }
    }
}
