// PhoneCodeWorkbenchView — mounting the pooled workbench on the PHONE, and nothing else.
//
// It replaces the deleted `CodeSidebar/CodeSidebarWebView.swift`, which was a `UIViewRepresentable`
// doing four UIKit calls: make a clipping container, put the pooled `WKWebView` in it, write a colour
// and tell the pool it had remounted. The wrapper existed because the thing above it happened to be a
// `View`; the four calls were never SwiftUI work. The Mac reached the same file one framework earlier
// (``SlopDeskMacUI/MacCodeWorkbenchView``) and this is its twin.
//
// ⚠️ PARITY ONLY. code-server is retired after this release and a native editor replaces it, so nothing
// here is an investment in the webview: it is the same four calls and the same veil the deleted file
// had, in the shape a controller can mount. Do not grow it.
//
// WHAT IS LEFT HERE IS THE ONLY PART OF A CODE PAGE THAT IS A VIEW. The page itself — the mint, and the
// `WKWebView` subclass that holds the responder seam — went down to `SlopDeskClientCore` with the pool
// it belongs to (docs/56 increment 45), because a `WKWebView` is the platform's view class rather than
// a drawn surface: nothing about minting one lays anything out or reads a design token. Mounting one
// does both, so the mount stayed.
//
// THE MOUNT IS A CLIPPING CONTAINER, NEVER THE WEBVIEW ITSELF. Under SwiftUI that was because a
// representable's product is destroyed on structural identity changes; here it is because a surface
// swap tears the surface down and ``CodeSidebarWebViewPool``'s whole purpose is that the workbench
// outlives it. The container is disposable; what it holds is not.
//
// THE GROUND TONE IS WRITTEN ON EVERY MOUNT, and that is why the pool's page mint could descend while
// this could not. A pooled page outlives a theme switch, so a creation-time snapshot flashes the OLD
// theme's tone on a scroll bounce — this re-apply never was redundant with the mint's copy, it
// OUTRANKED it. And it could not have gone down with the mint: `SlopDeskSlate` depends on
// `SlopDeskClientCore`, so the tokens are not readable from there at all.
//
// NO HIT-TEST OVERRIDE, unlike the Mac's. The overhang would otherwise sit under the panel's own bar
// and eat its taps; `clipsToBounds` already stops UIKit delivering touches outside the container's
// bounds, and on AppKit it does not — which is the whole of the difference between the two files.

#if os(iOS)
import QuartzCore
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import UIKit
import WebKit

/// The webview's mount that DECAPITATES the web title bar.
///
/// The workbench force-shows its title bar while the activity bar sits at "top" (seed v12), and the
/// grid positions every part with inline absolute geometry, so a CSS `display: none` leaves a dead gap
/// instead of reflowing. The clip is the clean cut: the webview is laid out taller than this view by
/// exactly ``CodePanelPresentation/clippedTitleBarHeight`` and shifted up, so the band renders above the
/// clip line — the workbench still believes in it, the reader never sees it.
@MainActor
final class PhoneCodeWorkbenchView: UIView {
    private let projectRoot: String
    private let url: URL

    /// The waiting surface that stays on top from load-start until the main-frame navigation settles.
    /// Without it the boot reads as black → WebKit's white canvas → workbench.
    private let veil: PhonePanelWaitingView

    /// The veil's following, kept for its ``ObservationFollow/stop()``. This is the case a weak owner
    /// does not cover: the pool is APP-LIFETIME, so a dismissed panel's container would otherwise go on
    /// re-arming against it to fade a veil nobody can see (docs/62 hazard 2).
    private var veilFollow: ObservationFollow?

    init(projectRoot: String, url: URL, waitingLabel: String) {
        self.projectRoot = projectRoot
        self.url = url
        veil = PhonePanelWaitingView(waitingLabel)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = true
        backgroundColor = Slate.Native.Surface.field

        mountPooledWebView()
        mountVeil()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Stop following. Called by the surface that mounted this before it lets go, so a swap to another
    /// tab does not leave a tracker armed on the pool.
    func teardown() {
        veilFollow?.stop()
        veilFollow = nil
    }

    /// The pooled page, re-parented under this container and re-toned.
    ///
    /// The pool answers with the SAME `WKWebView` for a root it already holds, so a project switch back
    /// is a re-parent rather than a load — which is the warm swap the pool exists for. Both ends of that
    /// swap are this view's: the ASK, and the remount note that may owe the keyboard back.
    ///
    /// The re-parenting in between is the floor's (``PanelChromeWorkbenchMount/pin(_:in:liftedBy:)``),
    /// which the two shells had transcribed line for line — nothing in it was UIKit, since `WKWebView`
    /// is one class on both platforms and the anchors are one Auto Layout. The lift it is given is
    /// ``CodePanelPresentation``'s one number, named here because this is the view that clips to match
    /// it.
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
        veil.backgroundColor = Slate.Native.Surface.field
        addSubview(veil)
        NSLayoutConstraint.activate(veil.slateEdges(of: self))
        followVeil()
    }

    /// Follow the pooled load state until it lifts.
    ///
    /// ⚠️ `loadState(for:)` IS RESOLVED ONCE, HERE, and deliberately outside the tracked read: the pool
    /// answers from a dictionary, and `Observation` tracks at property granularity, so looking the state
    /// up inside `read` would put every OTHER project's load state in this veil's dependency set. What
    /// the follow watches is the one state object's `veiled`, which is the whole question.
    private func followVeil() {
        let state = CodeSidebarWebViewPool.shared.loadState(for: projectRoot)
        veilFollow = ObservationFollow.arm(
            self,
            read: { _ in state.veiled },
            apply: { view, veiled in view.applyVeil(veiled) },
        )
    }

    /// Cross-fade the veil to match the pooled load state. Outside the tracked read, so the animation's
    /// own reads register nothing.
    private func applyVeil(_ veiled: Bool) {
        guard veil.isHidden != !veiled else { return }
        if veiled { veil.isHidden = false }
        UIView.animate(
            withDuration: Slate.Motion.smallFade.duration,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut],
            animations: { [veil] in veil.alpha = veiled ? 1 : 0 },
            completion: { [weak self] _ in
                // Hidden only once it has finished fading — a veil hidden on the first frame is a cut,
                // and the fade is what keeps the workbench's first paint from reading as a flash.
                self?.veil.isHidden = !veiled
            },
        )
    }
}
#endif
