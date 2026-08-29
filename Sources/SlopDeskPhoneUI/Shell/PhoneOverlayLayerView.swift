// PhoneOverlayLayerView — the always-mounted passthrough layer over both columns.
//
// It replaces FOUR SwiftUI `.overlay` modifiers, in the order they stacked — the palette host, the
// toast corner, and the clipboard questions — and it is mounted for the reason each of them was:
// ALWAYS PRESENT, rendering nothing when there is nothing to render, so an arriving card animates in
// without a re-mount.
//
// THE STACKING ORDER IS THE MOUNT ORDER, bottom to top: the summoned cards, then the notification
// corner, then the clipboard questions. Each child is FULL-BLEED and decides for itself where inside
// that rectangle it draws, which is what lets the summoned host and the pane switcher own separate
// dismiss floors that mean different things — one closes a card, the other CANCELS a walk.
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
// ⚠️ THE MAILBOX DRAIN LIVES IN ``ClipboardConfirmCardView`` AND IS MOUNTED HERE, which is what makes
// it real: `ClipboardConfirmRequests.shared` is filled by the embedder's OSC 52 callback and was
// emptied by the deleted `ClipboardConfirmCard`, so between `3f11c6e6` and this mount a
// `clipboard-read = ask` profile on iOS filed a question nobody could answer — libghostty held the
// request and the paste never completed. The card arms its reader in `init`, so CONSTRUCTING it is
// the fix; a card that is built but never added to a window is the same hang with more code.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskWorkspaceCore
import UIKit

@MainActor
final class PhoneOverlayLayerView: UIView {
    /// Jump to the pane a notification card names. Wired by the shell to the store's own jump.
    var onJumpToPane: ((String) -> Void)? {
        didSet { toasts.onJump = onJumpToPane }
    }

    /// Whether a palette row shows its ✓ gutter. Forwarded to the summoned host — see its own note for
    /// why this arrives from the shell rather than from the initializer.
    var paletteToggledState: (@MainActor (PaletteItem) -> Bool)? {
        didSet { cards.toggledState = paletteToggledState ?? { _ in false } }
    }

    private let store: WorkspaceStore
    private let connection: AppConnection
    private let overlay: OverlayCoordinator

    /// The four SUMMONED cards, on their own dismiss floor. Bottom of the stack: a notification arriving
    /// over a palette must be readable, and a clipboard question must cover both.
    private let cards: PhoneOverlayCardHostView
    /// The ⌃⇥ walk. It is NOT one of the coordinator's flags — it is the store's live gesture — and it
    /// carries a floor of its own whose tap CANCELS rather than closes, which is exactly why it cannot
    /// share the summoned host's.
    private let switcher: PhonePaneSwitcherView
    /// The notification corner. Deaf everywhere a card is not.
    private let toasts: PhoneToastStackView
    /// The remote program's question. Full-bleed, TOPMOST, and deaf until a question exists.
    private let clipboard = ClipboardConfirmCardView()

    init(store: WorkspaceStore, connection: AppConnection, overlay: OverlayCoordinator) {
        self.store = store
        self.connection = connection
        self.overlay = overlay
        cards = PhoneOverlayCardHostView(store: store, overlay: overlay)
        switcher = PhonePaneSwitcherView(store: store)
        toasts = PhoneToastStackView(overlay: overlay)
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        mount(cards)
        mount(switcher)
        mount(toasts)
        mount(clipboard)
        // The card took the keyboard while it was up (its footer holds the Esc/↩ chords), so the pane
        // underneath has to be handed it back — the deleted SwiftUI host spent an `.onDisappear` on
        // exactly this, and every card mounted here owes the same debt.
        clipboard.onDrained = { [store] in store.reclaimKeyboardFocusInActivePane() }
    }

    /// Add one full-bleed child. Every overlay in this layer covers the whole layer and decides for
    /// itself where inside that rectangle it draws — which is what lets each of them own its own
    /// dismiss floor, and what makes the stacking order simply the mount order.
    private func mount(_ child: UIView) {
        addSubview(child)
        NSLayoutConstraint.activate(child.slateEdges(of: self))
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
