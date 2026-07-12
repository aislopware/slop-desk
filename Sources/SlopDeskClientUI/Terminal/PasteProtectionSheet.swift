// PasteProtectionSheet — the macOS confirmation surface for Paste Protection.
//
// libghostty already TRIPS the gate (`clipboard-paste-protection`) and hands the embedder an
// approve/deny decision via `confirm_read_clipboard_cb`; this is the user-facing dialog that decision
// renders. It shows a preview of the clipboard content + the flagged dangers (from the pure
// `PasteSafetyAnalyzer`) and resolves to "Paste Anyway" / "Cancel". The same surface is reused by the
// OSC-52 read "ask" path with different copy via ``Kind``.
//
// macOS-only (NSAlert). iOS auto-approves the paste in the embedder (no sheet) — see GhosttyTerminalView.

#if os(macOS)
import AppKit
import SlopDeskWorkspaceCore

/// Presents the paste-protection confirmation. AppKit-thin: ALL danger classification lives in the
/// pure ``PasteSafetyAnalyzer`` (headless-tested) — this type only renders the verdict and relays the
/// user's choice, so the GUI stays compile-and-review while the decision logic stays unit-tested.
@preconcurrency
@MainActor
public enum PasteProtectionSheet {
    /// Which confirmation copy to render. `.unsafePaste` is the ⌘V protection dialog; `.clipboardRead`
    /// is the OSC-52 "a program wants to read your clipboard" ask; `.clipboardWrite` is the OSC-52
    /// "a program wants to set your clipboard" ask (`clipboard-write = ask`) — all reuse this surface.
    public enum Kind: Sendable {
        case unsafePaste
        case clipboardRead
        case clipboardWrite
    }

    /// How many characters of the clipboard preview to show before eliding — enough to see the shape of
    /// the paste without rendering a megabyte blob into the alert.
    private static let previewLimit = 480

    /// Presents the confirmation. When `window` is non-nil the alert is shown as a document-modal SHEET
    /// (non-blocking — the pending libghostty clipboard request is preserved until `completion` runs);
    /// otherwise it falls back to an app-modal `runModal`. `completion(true)` = "Paste Anyway",
    /// `completion(false)` = "Cancel". Always invoked on the main actor.
    public static func present(
        kind: Kind = .unsafePaste,
        preview: String,
        dangers: PasteSafetyAnalyzer.PasteDangers,
        in window: NSWindow?,
        completion: @escaping (Bool) -> Void,
    ) {
        let alert = makeAlert(kind: kind, preview: preview, dangers: dangers)
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
        kind: Kind,
        preview: String,
        dangers: PasteSafetyAnalyzer.PasteDangers,
    ) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning

        switch kind {
        case .unsafePaste:
            alert.messageText = "Paste potentially dangerous content?"
        case .clipboardRead:
            alert.messageText = "Allow this program to read the clipboard?"
        case .clipboardWrite:
            alert.messageText = "Allow this program to set the clipboard?"
        }

        alert.informativeText = informativeText(kind: kind, preview: preview, dangers: dangers)

        // FIRST button is the affirmative action the user explicitly invoked (⌘V). "Cancel" is auto-bound
        // to Escape by AppKit (a button titled "Cancel"), so a stray Return pastes and Escape cancels.
        alert.addButton(withTitle: kind == .unsafePaste ? "Paste Anyway" : "Allow")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    private static func informativeText(
        kind: Kind,
        preview: String,
        dangers: PasteSafetyAnalyzer.PasteDangers,
    ) -> String {
        var sections: [String] = []

        let descriptions = PasteSafetyAnalyzer.descriptions(for: dangers)
        if !descriptions.isEmpty {
            sections.append(descriptions.map { "•  \($0)" }.joined(separator: "\n"))
        } else if kind == .clipboardRead {
            sections.append("A terminal program is requesting clipboard access via OSC 52.")
        } else if kind == .clipboardWrite {
            sections.append("A terminal program is requesting to set the clipboard via OSC 52.")
        }

        let trimmed = elidedPreview(preview)
        if !trimmed.isEmpty {
            sections.append("Clipboard preview:\n\(trimmed)")
        }
        return sections.joined(separator: "\n\n")
    }

    /// A single-block, length-capped preview with control characters made visible so an injection hidden
    /// in the payload is not itself rendered into the alert. Never force-unwraps; tolerant of any input.
    private static func elidedPreview(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        var out = String()
        out.reserveCapacity(min(text.count, previewLimit) + 1)
        var count = 0
        for scalar in text.unicodeScalars {
            if count >= previewLimit { out += "…"
                break
            }
            switch scalar {
            case "\n":
                out += "\n"
            case "\t":
                out += "    "
            default:
                // Render any other C0 control / DEL as its caret notation (e.g. ESC → ^[) instead of
                // letting it perturb the alert text.
                let v = scalar.value
                if v < 0x20 || v == 0x7F {
                    out += "^"
                    out.unicodeScalars.append(Unicode.Scalar((v ^ 0x40) & 0x7F) ?? scalar)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
            count += 1
        }
        return out
    }
}
#endif
