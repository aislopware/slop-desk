// PasteProtectionSheet — the macOS confirmation surface for Paste Protection.
//
// libghostty TRIPS the gate (`clipboard-paste-protection`) and hands the embedder an approve/deny
// decision; this is the dialog that decision renders. It shows the flagged dangers and a preview of
// the payload, and resolves to "Paste Anyway" / "Cancel". The OSC-52 read and write asks reuse the
// same surface with different words, via ``PasteSafetyAnalyzer/Ask``.
//
// It lived in the draining floor until it had no reason to: an `NSAlert` is macOS's, it names no
// view from that target, and the whole-file `#if os(macOS)` it wore was the tell. Here the gate is
// the TARGET, so the file has none — docs/56 §3. The phone asks the same three questions through
// `SlopDeskPhoneUI/Overlays/ClipboardConfirmCard.swift`; it used to auto-approve two of them and
// drop the third, which is what increment 65 closed.
//
// NOTHING HERE IS A DECISION, AND NOTHING HERE IS A SENTENCE. The four dangers, the skip rules, the
// heading, the button title, the bullets and the defused preview are all `slopdesk_terminal::paste`
// (docs/55), reached through `PasteSafetyAnalyzer`; the SHAPE they take — bullets or the ask's
// reason, the preview where there is one, and the single-string join an `NSAlert` needs — is
// ``ClipboardConfirmPresentation``, which the phone's card reads too. What is left in this file is
// the alert: the one part of the sheet that could not cross.

import AppKit
import SlopDeskClientCore
import SlopDeskWorkspaceCore

/// Presents the paste-protection confirmation.
@preconcurrency
@MainActor
public enum PasteProtectionSheet {
    /// Presents the confirmation. When `window` is non-nil the alert is shown as a document-modal
    /// SHEET (non-blocking — the pending libghostty clipboard request is preserved until
    /// `completion` runs); otherwise it falls back to an app-modal `runModal`. `completion(true)` =
    /// the affirmative button, `completion(false)` = Cancel. Always invoked on the main actor.
    public static func present(
        ask: PasteSafetyAnalyzer.Ask = .unsafePaste,
        preview: String,
        dangers: PasteSafetyAnalyzer.PasteDangers,
        in window: NSWindow?,
        completion: @escaping (Bool) -> Void,
    ) {
        let alert = makeAlert(ask: ask, preview: preview, dangers: dangers)
        if let window {
            alert.beginSheetModal(for: window) { response in
                completion(response == .alertFirstButtonReturn)
            }
        } else {
            let response = alert.runModal()
            completion(response == .alertFirstButtonReturn)
        }
    }

    // MARK: Private

    private static func makeAlert(
        ask: PasteSafetyAnalyzer.Ask,
        preview: String,
        dangers: PasteSafetyAnalyzer.PasteDangers,
    ) -> NSAlert {
        // The heading, the button word, the bullets-or-reason branch and the defused preview are all
        // ``ClipboardConfirmPresentation``'s — the same reading the phone's card lays out as rows.
        // This file used to compose the body itself, which made the join a second copy of a decision
        // the two dialogs have to make identically.
        let reading = ClipboardConfirmPresentation.reading(ask: ask, preview: preview, dangers: dangers)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = reading.title
        alert.informativeText = reading.informativeText

        // FIRST button is the affirmative action the user explicitly invoked (⌘V). "Cancel" is
        // auto-bound to Escape by AppKit (a button titled "Cancel"), so a stray Return pastes and
        // Escape cancels.
        alert.addButton(withTitle: reading.affirmative)
        alert.addButton(withTitle: "Cancel")
        return alert
    }
}
