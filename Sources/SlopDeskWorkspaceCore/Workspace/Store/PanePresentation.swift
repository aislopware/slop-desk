import Foundation
import SlopDeskWorkspaceModel

// L0: what is LEFT of the namespace extracted from the deleted SwiftUI `FloatingPaneHandle.swift`.
// Three of its four derivations — `connectionStatus`, `isRunning`, `latencyMS` — went with the
// chrome they were extracted for and had no caller left in either `Sources/` or `Tests/`; they are
// deleted here, and `PaneConnectionStatus` (which only `connectionStatus` named) with them.
//
// ⚠️ `displayTitle` is kept DELIBERATELY, and it is not reached from the live UI. It is the only
// implementation in the tree that redacts a pane title, and the live rail / tab-strip / switcher
// path does NOT go through it: those surfaces read `WorkspaceStore.liveProgramTitle(for:)` — the raw
// OSC 0/2 title as `WorkspaceStore+WorkspaceMirror.noteTitlePushed` wrote it to
// `WorkspacePaneField.liveTitle` — and hand it to `RailRowsBuilder` / `PaneSwitcherRows` /
// `JumpBreadcrumb`, which compose through `slopdesk_ws_tab_display_title`. Neither that door nor any
// of its callers redacts. `SecretRedactor.redact` has exactly three production call sites and this
// is one of them; the other two are `CommandCompletionNotifier` (Notification Center) and
// `Toast.redactSecretsIfEnabled`.
//
// So deleting this would delete the tree's only title-redaction rule AND its only test, in a change
// whose subject is "port some Swift to Rust" — which is how a security behaviour disappears without
// anybody deciding it should. It stays until the redaction lands on the live path (the natural home
// is `rust/slopdesk-workspace`'s `rail_title`, beside the composition that already runs there), at
// which point this file goes and `ReviewFixTests` repoints at that door.
@MainActor
enum PanePresentation {
    /// The display title: the LIVE OSC 0/2 terminal title when the shell has set one, else the static
    /// `spec.title` (whitespace-only titles fall back so a pane is never blank).
    static func displayTitle(_ handle: (any PaneSessionHandle)?, spec: PaneSpec) -> String {
        let raw: String =
            if let live = (handle as? LivePaneSession)?.terminalModel?.title,
            !live.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                live
            } else {
                spec.title
            }
        // A remote shell controls the OSC title; mask any secret before it lands on a persistent
        // surface. Gated so it is an opt-out.
        return SettingsKey.redactSecretsEnabled ? SecretRedactor.redact(raw) : raw
    }
}
