// PanelChromeWorkbenchMount — hanging the pooled workbench in a container, once for both shells.
//
// The two code-panel hosts (``SlopDeskMacUI/MacCodeWorkbenchView`` and
// ``SlopDeskPhoneUI/PhoneCodeWorkbenchView``) had carried this ladder character for character: take
// the page off whatever container held it last, turn its autoresizing mask off, add it, and pin it to
// three edges plus a top LIFTED clear of the container. Eight identical lines, and not one of them is
// AppKit or UIKit — `WKWebView` is one class on both platforms, the anchors are one Auto Layout, and
// the only word that differed between the two copies was the type of the container, which is what
// ``SlateHostView`` is.
//
// ⚠️ THE POOL CONVERSATION STAYS UP IN THE SHELLS, and that is a boundary rather than a leftover.
// Asking for the page and telling the pool it was remounted are the two ends of a WARM SWAP whose
// other half — the focus restore, the veil, the load state — is the mounting view's own business;
// what descends here is the container wiring in between, which has no opinion about pooling at all.
// This function would do the same thing for a page nobody pooled.
//
// ⚠️ AND THE CONTAINER IS THE CALLER'S. A surface swap tears the container down and the pool's whole
// purpose is that the workbench OUTLIVES it, so the disposable half belongs to whoever is disposable.
// Whether that container clips is the caller's too: the Mac guards its hit-testing by hand and the
// phone gets it from `clipsToBounds`, which is the one genuine difference between the two mounts.

import WebKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
package enum PanelChromeWorkbenchMount {
    /// Re-parent `page` under `host`, filling it but lifted by `liftedBy` at the top.
    ///
    /// Re-parenting a view that still has a superview is legal and is what `addSubview` does; the
    /// explicit removal is for the CONSTRAINTS, which do not follow it — and a pooled page that has
    /// been mounted before still carries the last container's four.
    ///
    /// `liftedBy` is how far the page is laid out ABOVE the container's top edge. The workbench
    /// force-shows a title bar it positions with inline absolute geometry, so a CSS `display: none`
    /// leaves a dead gap instead of reflowing; lifting the page and clipping the container is the
    /// clean cut. How far is ``CodePanelPresentation/clippedTitleBarHeight``, named by the caller
    /// because the caller is what has to clip to match it.
    package static func pin(_ page: WKWebView, in host: SlateHostView, liftedBy: CGFloat) {
        page.removeFromSuperview()
        page.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            page.topAnchor.constraint(equalTo: host.topAnchor, constant: -liftedBy),
            page.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }
}
