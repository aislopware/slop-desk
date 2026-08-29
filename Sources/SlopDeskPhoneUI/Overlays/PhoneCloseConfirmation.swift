// PhoneCloseConfirmation — "are you sure you want to close this?", as the alert it always was.
//
// The successor ``CloseConfirmationCopy``'s header was waiting for. Between the SwiftUI shell's deletion
// and this file the phone had NO answer to a parked close: `WorkspaceStore.requestClosePaneTree(_:)`
// parks the unit and returns, and nothing on this side resolved the park — the swipe simply did nothing,
// for as long as the configured policy kept gating it. That is not a missing ornament, it is a verb the
// user pressed that never happened.
//
// AN ALERT, NOT A CARD, and the one overlay on this side that is presented rather than mounted in
// ``PhoneOverlayLayerView``. The layer exists because UIKit DROPS a second `present(_:animated:)`, and
// every surface in it is one a REMOTE PROGRAM or the palette can raise at any moment. This one cannot
// arrive at an arbitrary moment: the only door to a phone close is the navigator's trailing swipe
// (``NavigatorColumnViewController``), which is untappable while anything is presented over the split.
// So the hazard the layer answers does not reach here, and the platform's own modal is what a
// destructive confirmation should be on both platforms — the Mac raises an `NSAlert` sheet
// (``SlopDeskMacUI/MacCloseConfirmation``) for the same reason.
//
// DRIVEN OFF THE PARK, not off a flag, and off ``CloseConfirmationCopy/request(store:)`` in particular:
// that one call reads every observable field the question depends on, so the follow's dependency set is
// the question's own, and the tab park it also answers costs nothing to be ready for.
//
// ⚠️ A CHANGED QUESTION IS RE-WORDED IN PLACE, not re-presented. `UIAlertController` publishes `title`
// and `message`, and a live alert redraws when they are written — where the Mac tears its sheet down and
// raises a new one. Dismiss-then-present would be the transliteration, and it races its own animation:
// the second `present` lands while the first is still going out, and UIKit drops it. There is nothing
// else to rebuild, because the two buttons never differ.
//
// ⚠️ NO GENERATION TOKEN, and that is a difference in the frameworks rather than in the behaviour. The
// Mac needs one because `beginSheetModal`'s completion fires for a PROGRAMMATIC `endSheet` exactly as it
// does for a click, so a re-ask would cancel the park it was about to re-ask about. A `UIAlertAction`
// handler runs only for a tap; `dismiss(animated:)` invokes none. Clearing the stored alert is the whole
// guard.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskWorkspaceCore
import UIKit

/// Raises the pane/tab close confirmation over the workspace shell, and resolves the store's park with
/// the answer.
@MainActor
final class PhoneCloseConfirmation {
    private let store: WorkspaceStore

    /// The live alert, or `nil` when nothing is parked. Kept so a park cleared from elsewhere — the pane
    /// closed by another path — can order it out: an alert whose question has stopped applying must not
    /// stay up over a workspace it no longer describes.
    private var alert: UIAlertController?

    /// What the live alert is asking about, so an unchanged reading re-words nothing. Every field is
    /// resolved live by ``CloseConfirmationCopy``, so a pane opened elsewhere retires the project-loss
    /// line under an alert that is already up.
    private var asking: CloseConfirmationCopy.Request?

    /// Where the alert is raised from. WEAK, and re-read on every presentation rather than resolved
    /// once: the shell presents the panel and the cheat sheet over itself, and an alert presented from a
    /// controller that is itself covered never appears.
    private weak var host: UIViewController?

    init(store: WorkspaceStore) { self.store = store }

    /// Begins following the store's parks, and answers one that is already armed.
    ///
    /// ⚠️ CALL THIS FROM `viewDidAppear`, ONCE. The first reading applies synchronously, and a
    /// presentation attempted before the host reaches a window fails silently — the same trap
    /// ``WorkspaceRootViewController``'s `canPresent` exists for.
    func start(host: UIViewController) {
        self.host = host
        ObservationFollow.arm(
            self,
            read: { CloseConfirmationCopy.request(store: $0.store) },
            apply: { $0.sync($1) },
        )
    }

    /// Reconciles the alert against the store's live park.
    private func sync(_ request: CloseConfirmationCopy.Request?) {
        guard let request else {
            dismiss()
            return
        }
        guard request != asking else { return }
        asking = request
        let title = CloseConfirmationCopy.title(request)
        let message = CloseConfirmationCopy.message(request)
        if let alert {
            alert.title = title
            alert.message = message
            return
        }
        guard let presenter = topPresenter() else {
            // ⚠️ UNREACHABLE WHILE THE SHELL IS APP-LIFETIME, and there is no retry: the follow wakes on
            // a CHANGED reading, so a park that finds no presenter is one nobody will ask about again.
            // ``start(host:)`` sets the host before the first apply and the root controller outlives the
            // session, so the only way here is a host that was torn down — and then the park belongs to
            // a workspace that is going away too. Clearing `asking` keeps a later reading from being
            // mistaken for an unchanged one; resolving the park silently, which is the other option,
            // would be a close that happened without the question.
            asking = nil
            return
        }
        let raised = UIAlertController(title: title, message: message, preferredStyle: .alert)
        // "Close" is the destructive action — it stops a running command and discards the unit — so
        // Cancel is the safe default and the one Esc lands on.
        raised.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.resolve(confirming: false)
        })
        raised.addAction(UIAlertAction(title: "Close", style: .destructive) { [weak self] _ in
            self?.resolve(confirming: true)
        })
        alert = raised
        presenter.present(raised, animated: true)
    }

    /// Answers the park, and hands the keyboard back. The alert took first responder while it was up, so
    /// the pane underneath has to be given it back — the debt every overlay on this side owes, and the
    /// one ``PhoneOverlayLayerView`` pays through `onDrained`.
    private func resolve(confirming: Bool) {
        alert = nil
        asking = nil
        if confirming { store.confirmPendingClose() } else { store.cancelPendingClose() }
        store.reclaimKeyboardFocusInActivePane()
    }

    /// Takes the alert down WITHOUT answering — the park is already gone. Clearing the stored alert
    /// first is what makes the dismissal programmatic rather than a resolution.
    private func dismiss() {
        guard let alert else { return }
        self.alert = nil
        asking = nil
        alert.dismiss(animated: true)
        store.reclaimKeyboardFocusInActivePane()
    }

    /// The deepest presented controller, which is the only one that can present. The shell hangs the
    /// panel and the cheat sheet off itself, and `present` from a covered controller is dropped with a
    /// console line and no error.
    private func topPresenter() -> UIViewController? {
        var presenter = host
        while let next = presenter?.presentedViewController { presenter = next }
        return presenter
    }
}
#endif
