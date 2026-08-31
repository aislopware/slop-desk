// PasteProtectionSheet — the AppKit half of every terminal confirmation.
//
// Three questions share this one surface: a ⌘V whose payload tripped one of the four paste dangers,
// an OSC-52 clipboard READ, and an OSC-52 clipboard WRITE. `PasteSafetyAnalyzer.Ask` is which.
//
// It sits in the RENDERER's target because the caller is the renderer: `MacTerminalRendererView`
// decides a paste needs asking about, and an `NSAlert` presented from anywhere else would need the
// window it is already holding handed to it. It used to live in `SlopDeskMacUI` beside views it
// never named, back when the asker was a C callback in a fork that no longer exists.
//
// The phone asks the same three questions and does NOT use this file: `NSAlert.beginSheetModal(for:)`
// can be called from inside a drain — the presenter IS a function — and UIKit has no such function,
// so `PhoneTerminalRendererView` files the question with `ClipboardConfirmRequests` and a mounted
// card draws it.
//
// NOTHING HERE IS A DECISION, AND NOTHING HERE IS A SENTENCE. The four dangers, the skip rules, the
// heading, the button title, the bullets and the defused preview are all `slopdesk_terminal::paste`
// (docs/55), reached through `PasteSafetyAnalyzer`; the SHAPE they take is
// `ClipboardConfirmPresentation`, which the phone's card reads too. What is left in this file is the
// alert: the one part of the sheet that could not cross.

#if canImport(AppKit)
import AppKit
import SlopDeskClientCore
import SlopDeskWorkspaceCore

/// Presents the paste-protection confirmation.
@preconcurrency
@MainActor
public enum PasteProtectionSheet {
    /// Presents the confirmation. When `window` is non-nil the alert is shown as a document-modal
    /// SHEET, which is non-blocking — the caller's completion holds whatever is waiting on the
    /// answer; otherwise it falls back to an app-modal `runModal`. `completion(true)` = the
    /// affirmative button, `completion(false)` = Cancel. Always invoked on the main actor.
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
#endif
