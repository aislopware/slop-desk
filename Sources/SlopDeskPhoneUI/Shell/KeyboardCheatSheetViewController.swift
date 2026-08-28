// KeyboardCheatSheetViewController — ⌘/, the one overlay the phone presents natively.
//
// ⚠️ SKELETON. This file carries the CONTRACT ``WorkspaceRootViewController`` presents (the
// initializer and ``onDismiss``) so the presentation is real while the rows are rebuilt. The body is
// owned by the overlays cluster.
//
// It left the shared overlay host when the Mac's half became an `NSPanel`, and the two now meet only
// at ``CheatSheetContent`` — the rows, the glyphs and the column deal — which is the layer docs/56
// says a divergent surface shares.
//
// ⚠️ `cheatSheetVisible` IS `private(set)` ON THE COORDINATOR, so the shell can only ever be told
// about a dismissal, never infer one. ``onDismiss`` must fire for the swipe and for a hardware Esc
// alike — `presentationControllerDidDismiss` covers the swipe, which `viewWillDisappear` does not
// distinguish from the shell's own programmatic dismissal.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskSlate
import UIKit

@MainActor
final class KeyboardCheatSheetViewController: UIViewController {
    /// Called for a dismissal the USER performed. Bound by the shell to `overlay.closeCheatSheet()`,
    /// which is the only writer of the coordinator's flag.
    var onDismiss: (() -> Void)?

    private let coordinator: OverlayCoordinator

    init(coordinator: OverlayCoordinator) {
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Slate.Native.Surface.field
        presentationController?.delegate = self
    }
}

extension KeyboardCheatSheetViewController: UIAdaptivePresentationControllerDelegate {
    /// The swipe. Fires only for a user-driven dismissal — a programmatic `dismiss(animated:)` does
    /// not call it, which is exactly the distinction the shell needs to avoid a re-entrant close.
    func presentationControllerDidDismiss(_: UIPresentationController) {
        onDismiss?()
    }
}
#endif
