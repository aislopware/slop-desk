// MacCloseConfirmation — "are you sure you want to close this?", as the alert it always was.
//
// The second of the two surfaces that were never cards (docs/56 stage D), and the shorter story of the
// two: an alert is an alert. The phone raises a SwiftUI `.alert` off the same store parks; the Mac raises
// an `NSAlert` as a sheet on the workspace window. Neither is a port of the other and neither is owed
// one — what they share is the WORDING, which is ``CloseConfirmationCopy`` in `SlopDeskClientCore`, so
// the three-branch "which line does this park deserve" question is answered once.
//
// DRIVEN OFF THE PARK, not off a flag. `WorkspaceStore` arms one of two mutually-exclusive parks
// (a pane close, a tab close) and clears them through `confirmPendingClose()` / `cancelPendingClose()`;
// this diffs "is a park armed" into an alert exactly the way ``MacOverlayPanels`` diffs the coordinator's
// booleans into panels. Both buttons resolve the park, so the store and the sheet cannot disagree — and
// a park that is cleared from somewhere else (the pane closed by another path) takes the alert down.

import AppKit
import SlopDeskClientCore
import SlopDeskWorkspaceCore

/// Raises the pane/tab close confirmation over the workspace window.
@MainActor
final class MacCloseConfirmation {
    /// The live alert's sheet window, or `nil` when nothing is parked. Kept so a park cleared from
    /// elsewhere can order it out — an alert whose question has stopped applying must not stay up.
    private var sheet: NSWindow?
    /// What the live alert is asking about. A park whose live copy CHANGED under the alert (a pane
    /// opened elsewhere retires the project-loss line) is re-asked rather than left stale.
    private var asking: CloseConfirmationCopy.Request?
    /// Which presentation the in-flight completion belongs to. A PROGRAMMATIC teardown — the park was
    /// resolved elsewhere, or the copy changed and the question is being re-asked — ends the sheet, and
    /// `beginSheetModal`'s completion fires for that ending exactly as it does for a click. Without this
    /// the re-ask would cancel the very park it is about to ask about again.
    private var generation = 0

    /// Reconciles the alert against the store's live parks.
    func sync(store: WorkspaceStore, host: NSWindow?) {
        guard let request = CloseConfirmationCopy.request(store: store), let host else {
            dismiss()
            return
        }
        guard request != asking else { return }
        dismiss()
        asking = request
        let token = generation

        let alert = NSAlert()
        alert.messageText = CloseConfirmationCopy.title(request)
        alert.informativeText = CloseConfirmationCopy.message(request)
        // "Close" is the destructive action (it stops a running command / discards the pane or tab);
        // Cancel is the safe default, so it is the one Return lands on. `hasDestructiveAction` is what
        // gives the platform its own placement and tinting for the pair.
        alert.addButton(withTitle: "Cancel")
        let close = alert.addButton(withTitle: "Close")
        close.hasDestructiveAction = true

        sheet = alert.window
        alert.beginSheetModal(for: host) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, token == self.generation else { return }
                self.sheet = nil
                self.asking = nil
                // `.alertSecondButtonReturn` is "Close" — the second button added. Every other ending
                // (Cancel, Esc, the sheet going away under us) leaves the unit alone.
                if response == .alertSecondButtonReturn { store.confirmPendingClose() }
                else { store.cancelPendingClose() }
            }
        }
    }

    private func dismiss() {
        guard let sheet else { return }
        self.sheet = nil
        asking = nil
        generation &+= 1
        sheet.sheetParent?.endSheet(sheet, returnCode: .alertFirstButtonReturn)
    }
}
