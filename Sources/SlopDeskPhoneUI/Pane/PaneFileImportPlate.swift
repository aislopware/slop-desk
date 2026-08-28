// PaneFileImportPlate — the iPhone's only door for sending a file into a pane, in UIKit.
//
// IT HAS NO MAC TWIN, and that is the whole reason it exists. Drag-and-drop is how a file gets into a
// pane everywhere else: ``PaneDropReceiverView`` works, and an iPad in Split View can even feed it —
// but a phone has no drag SOURCE to feed it from, so the receiver has nothing to receive.
// ``PaneFileImportPolicy`` (`SlopDeskClientCore`) is the answer to "what does a PICKED file do to a
// pane", written once so the Mac can be owed the same picker later without a second meaning for the
// same gesture.
//
// THIS FILE IS THE READER AND NOTHING ELSE. It presents the picker and hands the URLs back; the zone,
// the classification, the action and the actuation are all the policy's, and none of the four is
// re-derived here. Not even the ACCEPTED TYPES: ``PaneFileImportPolicy/pickerTypes`` is what the
// picker is built from, because "the pane accepts a path, not a format" is a decision rather than a
// platform detail.
//
// ⚠️ `.fileImporter` → `UIDocumentPickerViewController` (docs/62 §2.1). The declarative modifier took
// a completion `Result` and needed no object; the controller reports through a DELEGATE, and that
// delegate is held `weak`. Something in the view tree therefore has to outlive the presentation and
// own the callback — which is what buys the one hosting view below its keep, and it is the only
// reason for it: ``SlatePlateVerbButton`` is `final` and holds nothing of its caller's.

#if os(iOS)
import Foundation
import SlopDeskClientCore // PaneFileImportPolicy — the zone, the types and the actuation
import SlopDeskSlate
import UIKit
import UniformTypeIdentifiers // UTType — the element type of the policy's `pickerTypes`

/// The pane's send-a-file plate: one chrome plate that opens the system document picker and hands
/// what came back to ``PaneFileImportPolicy``.
///
/// ⚠️ IT CAPTURES NO PANE. The chip is built when the column decides to show it and may be tapped
/// arbitrarily later — after a session swap, after a reconnect — so what it carries is one closure the
/// MOUNTER resolves at fire time. A plate holding a `LivePaneSession` would send a file to whichever
/// session was live when the chip appeared.
@MainActor
final class PaneFileImportPlateView: UIView, UIDocumentPickerDelegate {
    /// What the picker returned, handed straight up. Cancellation never calls it — see
    /// ``documentPickerWasCancelled(_:)``.
    private let onPicked: ([URL]) -> Void

    init(onPicked: @escaping ([URL]) -> Void) {
        self.onPicked = onPicked
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let button = SlatePlateVerbButton(
            symbol: .documentBadgePlus, help: Self.help, tint: Slate.Native.Text.icon,
        )
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        button.addTarget(self, action: #selector(summon), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// The plate's one word, and it is a LITERAL here rather than a reading.
    ///
    /// Every other string this card family shows crossed from Rust, but there is no picker vocabulary
    /// on the far side to ask: ``PaneFileImportPolicy`` holds the decision and no words, and the
    /// deleted half carried this same sentence inline. Minting a presentation entry for one string
    /// that no second renderer reads would be the crossing paid for and not used — when the Mac is
    /// owed its picker, that is the change that earns it.
    private static let help = "Send a File to This Pane"

    @objc
    private func summon() {
        // `forOpeningContentTypes:` — the current initializer; `init(documentTypes:in:)` is the
        // deprecated one. It opens the file IN PLACE rather than copying it into the app container,
        // which is what the policy wants: only `path` and folder-ness are ever read, the pane's other
        // end is a HOST, and a copy would hand the terminal a path inside a sandbox nobody can reach.
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: PaneFileImportPolicy.pickerTypes,
        )
        // One file. The policy accepts a selection and the drop path can carry several, but the plate
        // sends a PATH to the prompt — and a prompt with four paths pasted into it is not the sentence
        // anyone was finishing. This is the deleted half's choice, kept.
        picker.allowsMultipleSelection = false
        picker.delegate = self
        presentingController()?.present(picker, animated: true)
    }

    func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        onPicked(urls)
    }

    /// Cancelling is the normal case, not a fault: nothing happens, and nothing is reported. The
    /// declarative half said the same thing by dropping every non-`.success` `Result`.
    func documentPickerWasCancelled(_: UIDocumentPickerViewController) {}

    /// The nearest controller up the responder chain, which is what a modal presentation needs.
    ///
    /// The pane column is `UIView`s all the way down from ``ContentColumnViewController``, so this
    /// plate has no controller of its own to ask — the chain is the only thing that knows. Same walk
    /// as ``GuiLeafView``'s, and deliberately private in both: it is a fact about where a view is
    /// mounted, not an API.
    private func presentingController() -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }
}
#endif
