// Toast — one transient notification card (warp-overlays-actions.md §3.2 `DismissibleToast`). A value
// type so the lifecycle (push / de-dupe by id / auto-dismiss) is pure + unit-testable without a view.
//
// Flavors map to the Warp set (Default / Success / Error) → an SF Symbol + a tint role; the view resolves
// the actual colors from the theme. `autoDismiss` is the timeout the toast view schedules (nil ⇒ sticky,
// dismissed only by the X button).

import AislopdeskClient // SessionResumeOutcome (the fresh-vs-resumed reconnect verdict)
import AislopdeskWorkspaceCore // SettingsKey.redactSecretsEnabled + SecretRedactor (OSC-text masking parity)
import Foundation

public struct Toast: Identifiable, Sendable, Equatable {
    /// Stable id — a newer toast with the same id replaces the older (warp `object_id` discipline).
    public let id: String
    public let flavor: Flavor
    public let title: String
    public let body: String?
    /// Auto-dismiss delay; nil ⇒ sticky (only the X closes it). Default 4s.
    public let autoDismiss: Duration?

    public enum Flavor: String, Sendable, Equatable {
        case `default`
        case success
        case error
        case attention

        /// The leading SF Symbol for this flavor.
        public var icon: String {
            switch self {
            case .default: "bell"
            case .success: "checkmark.circle"
            case .error: "exclamationmark.triangle"
            case .attention: "asterisk"
            }
        }
    }

    public init(
        id: String,
        flavor: Flavor = .default,
        title: String,
        body: String? = nil,
        autoDismiss: Duration? = .seconds(4),
    ) {
        self.id = id
        self.flavor = flavor
        self.title = title
        self.body = body
        self.autoDismiss = autoDismiss
    }

    // MARK: - Secret redaction (parity with the OS banner + the pane title)

    /// Masks likely secrets in untrusted, remote-controlled OSC text when `redactSecrets` (default ON) is
    /// set — the SHARED seam so every in-app toast matches the macOS Notification-Center banner
    /// (`CommandCompletionNotifier`) and the redacted sidebar/pill title (`PanePresentation`). Critically,
    /// the toast is the ONLY notification surface on iOS (the macOS-only `UNUserNotification` never runs),
    /// so without this an OSC 9/777 title or body carrying an API key / token / `PASSWORD=…` would render
    /// VERBATIM on-screen — a shoulder-surf / screen-share / recording leak. Idempotent (re-masking is a
    /// no-op), so it stays safe even where the source already passed through a redacting ingress.
    public static func redactSecretsIfEnabled(_ text: String) -> String {
        SettingsKey.redactSecretsEnabled ? SecretRedactor.redact(text) : text
    }

    /// Builds the in-app toast for an explicit OSC 9/777 notification, masking secrets in the (untrusted)
    /// title + body at the single toast-construction site so both platforms benefit.
    public static func explicitOSC(paneIDRaw: UUID, title: String, body: String?) -> Self {
        Self(
            id: "pane.\(paneIDRaw.uuidString)",
            flavor: .default,
            title: redactSecretsIfEnabled(title),
            body: body.map { redactSecretsIfEnabled($0) },
        )
    }

    /// Builds the in-app toast for a finished LONG-running command (the background "your build finished" cue).
    /// `paneTitle` is the live OSC 0/2 pane title — untrusted, remote/PTY-settable text (commonly the running
    /// command line, e.g. `mysql -pSECRET`, or an explicit `\e]2;…token…\a`), so it is masked at this single
    /// construction site for parity with the macOS banner (`CommandCompletionNotifier.post`) and the OSC toast
    /// above — the toast is the ONLY notification surface on iOS. The body is a FIXED exit-code + duration
    /// template (no untrusted text), so it needs no redaction. A clean exit is `.success`; a non-zero exit is
    /// `.error` (a green checkmark on a failed build would mislead).
    public static func longCommand(
        paneIDKey: String,
        paneTitle: String,
        exitCode: Int32?,
        durationMS: UInt32,
    ) -> Self {
        let secs = Int((Double(durationMS) / 1000).rounded())
        let cleanExit = (exitCode ?? 0) == 0
        return Self(
            id: "pane.\(paneIDKey)",
            flavor: cleanExit ? .success : .error,
            title: paneTitle.isEmpty ? "Command finished" : redactSecretsIfEnabled(paneTitle),
            body: "command finished (exit \(exitCode.map(String.init) ?? "?"), \(secs)s)",
        )
    }

    /// C8 improvement 1: the in-app toast for a completed RECONNECT's fresh-vs-resumed verdict — the ONLY
    /// signal the user gets for whether a dropped link reattached the SAME live shell (scrollback/history
    /// intact) or spawned a FRESH shell (the previous session, and its context, ended). `.resumedSession` is
    /// reassuring (`.success`); `.freshShell` is a soft warning that context is gone (`.attention`).
    /// `.undetermined` is never a user-facing edge (the verdict has not resolved) ⇒ `nil` (nothing to show).
    /// No untrusted text (both strings are fixed templates), so no secret redaction is needed. The stable
    /// `pane.<key>` id de-dupes with the pane's other toasts so a newer event replaces this one.
    static func sessionResume(
        paneIDKey: String, outcome: AislopdeskClient.SessionResumeOutcome,
    ) -> Self? {
        switch outcome {
        case .resumedSession:
            Self(
                id: "pane.\(paneIDKey)",
                flavor: .success,
                title: "Reattached",
                body: "Session preserved.",
            )
        case .freshShell:
            Self(
                id: "pane.\(paneIDKey)",
                flavor: .attention,
                title: "Reconnected",
                body: "Fresh shell — previous session ended.",
            )
        case .undetermined:
            nil
        }
    }
}
