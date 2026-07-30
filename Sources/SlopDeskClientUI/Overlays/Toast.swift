// Toast — one transient notification card. A value type so the lifecycle (push / de-dupe by id /
// auto-dismiss) is pure + unit-testable without a view.
//
// A notification here is A PANE SPEAKING FROM OFF-SCREEN: every construction site is gated on the source
// pane NOT being focused (`isSourcePaneFocused`), so a toast always names a place the user is not looking
// at. That shapes the whole model — it carries WHO spoke (``source`` + ``flavor``), WHAT happened
// (title/body), and WHERE to go (``paneKey``, the jump target). `autoDismiss` is the dwell the view
// spends down (nil ⇒ sticky, closed only by the X).
//
// The mark the view draws is resolved from ``source`` + ``flavor`` TOGETHER, never from flavour alone —
// `.success` means "agent finished its turn" for an agent and "command exited 0" for a command, and those
// are two different speakers in the rail's status vocabulary (ring vs dot, docs/DECISIONS.md round 21).
// Fusing them into one flavour and letting the view guess is the exact mistake `TabBadgeResolver` made.

import Foundation
import SlopDeskClient // SessionResumeOutcome (the fresh-vs-resumed reconnect verdict)
import SlopDeskWorkspaceCore // SettingsKey.redactSecretsEnabled + SecretRedactor (OSC-text masking parity)

public struct Toast: Identifiable, Sendable, Equatable {
    /// Stable id — a newer toast with the same id replaces the older (warp `object_id` discipline).
    public let id: String
    public let flavor: Flavor
    /// WHO is speaking — decides the mark's GEOMETRY (agent ⇒ ring, everything else ⇒ dot).
    public let source: Source
    public let title: String
    public let body: String?
    /// Auto-dismiss delay; nil ⇒ sticky (only the X closes it). Default 4s.
    public let autoDismiss: Duration?
    /// The pane this notification is ABOUT, as a `PaneID.raw.uuidString` — the jump target that makes the
    /// card a door back to the place it names. `nil` for the window-level notices with nowhere to go (a
    /// host-path action that failed, the dropped-folder cwd advisory), which render as plain cards.
    public let paneKey: String?
    /// The EYEBROW: the caps micro-label that opens the card and carries the event class in the flavour ink
    /// (MERIDIAN L2 — typography is the only ornament). `nil` ⇒ derived from ``source`` + ``flavor`` by
    /// ``ToastStackView/eyebrow(for:)``; a factory sets it explicitly when it knows a truer word than the
    /// derivation can reach (a reconnect verdict is `REATTACHED` / `RECONNECTED`, which no flavour encodes).
    ///
    /// This REPLACED the leading `StatusDotView` mark. The ring/dot pair is the RAIL's vocabulary — correct
    /// in a 10pt sidebar column, but in a notification it was a tiny abstract speck where the eye expects
    /// something concrete, and a coloured caps word carries the same bit with far more legible ink.
    public let eyebrow: String?
    /// Dwell-timer identity, stamped by ``OverlayCoordinator/pushToast(_:)``. A re-push of the SAME `id`
    /// must RESTART the dwell, but `.task(id:)` keyed on the id alone would not re-fire (the id is
    /// unchanged), leaving the replacement card to inherit the dead one's nearly-elapsed timer — the bug
    /// `ChipNotice.epoch` already exists to prevent. Set by the coordinator, never by a call site.
    public var epoch: Int = 0

    /// Which of the workspace's two status speakers raised this notification. Not a style knob: it picks
    /// the mark's geometry, so it must name a real distinction in the rail's vocabulary.
    public enum Source: String, Sendable, Equatable {
        /// A living agent session with a lifecycle (needs input / finished a turn) ⇒ the RING.
        case agent
        /// A command's outcome, or any other one-off event at a pane (OSC 9/777, a reconnect verdict)
        /// ⇒ the DOT. An event that happened while you were away, not a state that persists.
        case command
    }

    public enum Flavor: String, Sendable, Equatable {
        case `default`
        case success
        case error
        case attention
    }

    public init(
        id: String,
        flavor: Flavor = .default,
        source: Source = .command,
        title: String,
        body: String? = nil,
        autoDismiss: Duration? = .seconds(4),
        paneKey: String? = nil,
        eyebrow: String? = nil,
    ) {
        self.id = id
        self.flavor = flavor
        self.source = source
        self.title = title
        self.body = body
        self.autoDismiss = autoDismiss
        self.paneKey = paneKey
        self.eyebrow = eyebrow
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
            // A program in the pane announced something — an EVENT at that pane, not an agent's lifecycle.
            source: .command,
            title: redactSecretsIfEnabled(title),
            body: body.map { redactSecretsIfEnabled($0) },
            paneKey: paneIDRaw.uuidString,
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
            source: .command,
            title: paneTitle.isEmpty ? "Command finished" : redactSecretsIfEnabled(paneTitle),
            // `exit N · Ms` — the instrument register the card sets this line in (mono, secondary ink),
            // so it reads as the technical readout it is rather than a sentence about one.
            body: "exit \(exitCode.map(String.init) ?? "?") · \(secs)s",
            paneKey: paneIDKey,
        )
    }

    /// The in-app toast for a completed RECONNECT's fresh-vs-resumed verdict — the ONLY
    /// signal the user gets for whether a dropped link reattached the SAME live shell (scrollback/history
    /// intact) or spawned a FRESH shell (the previous session, and its context, ended). `.resumedSession` is
    /// reassuring (`.success`); `.freshShell` is a soft warning that context is gone (`.attention`).
    /// `.undetermined` is never a user-facing edge (the verdict has not resolved) ⇒ `nil` (nothing to show).
    /// No untrusted text (both strings are fixed templates), so no secret redaction is needed. The stable
    /// `pane.<key>` id de-dupes with the pane's other toasts so a newer event replaces this one.
    static func sessionResume(
        paneIDKey: String, outcome: SlopDeskClient.SessionResumeOutcome,
    ) -> Self? {
        switch outcome {
        // The verdict itself is the EYEBROW (no flavour encodes "reattached vs reconnected"), which frees
        // the subject line to say what it MEANS for the user's context.
        case .resumedSession:
            Self(
                id: "pane.\(paneIDKey)",
                flavor: .success,
                source: .command,
                title: "session preserved",
                paneKey: paneIDKey,
                eyebrow: "REATTACHED",
            )
        case .freshShell:
            Self(
                id: "pane.\(paneIDKey)",
                flavor: .attention,
                source: .command,
                title: "fresh shell",
                body: "previous session ended",
                paneKey: paneIDKey,
                eyebrow: "RECONNECTED",
            )
        case .undetermined:
            nil
        }
    }
}
