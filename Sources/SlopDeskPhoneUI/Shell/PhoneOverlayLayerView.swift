// PhoneOverlayLayerView — the always-mounted passthrough layer over both columns.
//
// ⚠️ SKELETON. This file carries the CONTRACT ``WorkspaceRootViewController`` mounts (the initializer
// and ``onJumpToPane``) so the shell's layering is real while the cards themselves are rebuilt. The
// body is owned by the overlays cluster.
//
// It replaces FOUR SwiftUI `.overlay` modifiers, in the order they stacked — the palette host, the
// toast corner, and the clipboard questions — and it is mounted for the reason each of them was:
// ALWAYS PRESENT, rendering nothing when there is nothing to render, so an arriving card animates in
// without a re-mount.
//
// ⚠️ THE HIT-TESTING IS THE WHOLE POINT, and it is the one thing this skeleton already implements.
// A layer that swallowed touches everywhere would take every keystroke away from the terminal
// underneath it; the SwiftUI half spelled this `.allowsHitTesting(!overlay.toasts.isEmpty)` per
// overlay, re-evaluated on every state change. Here it is structural: a touch that lands on this view
// ITSELF — rather than on a card inside it — belongs to whatever is beneath.
//
// ⚠️ THE CLIPBOARD QUESTIONS ARE TOPMOST, and stay an in-window layer rather than a presented sheet.
// They are raised by a remote PROGRAM rather than summoned, so they may not be covered by a card the
// user opened, and the system's modal stack DECLINES a second presentation — a declined presentation
// here would leave libghostty holding the request forever.
//
// ⚠️ AND NOTHING DRAINS THAT MAILBOX TODAY. `ClipboardConfirmRequests.shared` is filled by the
// embedder's OSC 52 callback and was emptied by the deleted `ClipboardConfirmCard`; the demolition
// took the only reader. Until the clipboard card lands here, a `clipboard-read = ask` profile on iOS
// files a question nobody can answer — libghostty holds the request and the paste never completes.
// This is a REBUILD OBLIGATION, not a pre-existing bug: the drain existed before `3f11c6e6`.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskWorkspaceCore
import UIKit

@MainActor
final class PhoneOverlayLayerView: UIView {
    /// Jump to the pane a notification card names. Wired by the shell to the store's own jump.
    var onJumpToPane: ((String) -> Void)?

    private let store: WorkspaceStore
    private let connection: AppConnection
    private let overlay: OverlayCoordinator

    init(store: WorkspaceStore, connection: AppConnection, overlay: OverlayCoordinator) {
        self.store = store
        self.connection = connection
        self.overlay = overlay
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Passthrough: this view takes a touch only where one of its cards is. `super.hitTest` returns
    /// `self` for a touch in the empty space between cards — returning `nil` there is what lets the
    /// columns underneath keep working while the layer stays mounted.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}
#endif
