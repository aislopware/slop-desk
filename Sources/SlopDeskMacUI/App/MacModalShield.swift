// MacModalShield — a column root that goes hit-test DEAF while a modal card floats over the window.
//
// Every hosted column lives in its own view inside the AppKit split, while the floating overlay layer
// lives in the window root's — so a card floating over a column does NOT occlude that column's hover
// tracking. AppKit tracking areas are rect-based and keep firing under the card: the navigator's rows
// lit their hover plates, and the band's chips lit theirs, while the pointer was on the palette.
//
// Going deaf silences hover the way the card's dismiss floor already silences clicks. Global Search
// (non-modal by design) leaves it open.

import AppKit
import SlopDeskClientCore

@MainActor
final class MacModalShield: NSView {
    private let overlay: OverlayCoordinator?
    /// A theme flip does not follow a `CGColor`, and the VIEW is what hears about the change — so the
    /// controller above hands its repaint down here.
    var onAppearanceChange: () -> Void = {}

    init(overlay: OverlayCoordinator?) {
        self.overlay = overlay
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard overlay?.anyModalVisible != true else { return nil }
        return super.hitTest(point)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange()
    }
}
