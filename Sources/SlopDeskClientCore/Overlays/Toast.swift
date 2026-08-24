// Toast — one transient notification card. A value type so the lifecycle (push / de-dupe by id /
// auto-dismiss) is pure + unit-testable without a view.
//
// A notification here is A PANE SPEAKING FROM OFF-SCREEN: every construction site is gated on the source
// pane NOT being focused (`isSourcePaneFocused`), so a toast always names a place the user is not looking
// at. That shapes the whole model — it carries WHO spoke (``source`` + ``flavor``), WHAT happened
// (title/body), and WHERE to go (``paneKey``, the jump target). `autoDismiss` is the dwell the view
// spends down (nil ⇒ sticky, closed only by the X).
//
// The headline the view sets is resolved from ``source`` + ``flavor`` TOGETHER, never from flavour alone —
// `.success` means "agent finished its turn" for an agent and "command exited 0" for a command, and those
// are two different speakers saying two different sentences ("Claude is done" vs "make check finished").
// Fusing them into one flavour and letting the view guess is the exact mistake `TabBadgeResolver` made.

import CSlopDeskFFI
import Foundation
import SlopDeskClient // SessionResumeOutcome (the fresh-vs-resumed reconnect verdict)
import SlopDeskWorkspaceCore // SettingsKey.redactSecretsEnabled (the SETTING; the masker itself is Rust)
import SlopDeskWorkspaceModel

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
    /// The HEADLINE override: the sentence-case event phrase that leads the card. `nil` ⇒ derived from
    /// ``source`` + ``flavor`` + ``title`` by ``ToastStackView/headline(for:)`` ("Claude needs input",
    /// "make check failed"); a factory sets it explicitly when it knows a truer phrase than the derivation
    /// can reach (a reconnect verdict is "Session reattached", which no flavour+title suffix encodes).
    public let headline: String?
    /// Dwell-timer identity, stamped by ``OverlayCoordinator/pushToast(_:)``. A re-push of the SAME `id`
    /// must RESTART the dwell, but `.task(id:)` keyed on the id alone would not re-fire (the id is
    /// unchanged), leaving the replacement card to inherit the dead one's nearly-elapsed timer — the bug
    /// `ChipNotice.epoch` already exists to prevent. Set by the coordinator, never by a call site.
    public var epoch: Int = 0

    /// Which of the workspace's two status speakers raised this notification. Not a style knob: it picks
    /// the headline's VERB, so it must name a real distinction between the speakers.
    public enum Source: String, Sendable, Equatable {
        /// A living agent session with a lifecycle — its `.success` is "finished a turn" ("Claude is done").
        case agent
        /// A command's outcome, or any other one-off event at a pane (OSC 9/777, a reconnect verdict) —
        /// its `.success` is "exited clean" ("make check finished").
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
        headline: String? = nil,
    ) {
        self.id = id
        self.flavor = flavor
        self.source = source
        self.title = title
        self.body = body
        self.autoDismiss = autoDismiss
        self.paneKey = paneKey
        self.headline = headline
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
    ///
    /// The masking happens on the FAR side: the masker is already a Rust face, and a near side that
    /// masked first would be a second implementation of the one rule. What stays here is the SETTING —
    /// a `UserDefaults` read, which no door can make for us — handed over as a bool.
    public static func explicitOSC(paneIDRaw: UUID, title: String, body: String?) -> Self {
        let key = paneIDRaw.uuidString
        let titleBytes = Array(title.utf8)
        let bodyBytes = Array((body ?? "").utf8)
        let keyBytes = Array(key.utf8)
        let redact = SettingsKey.redactSecretsEnabled
        let blob = keyBytes.withUnsafeBufferPointer { pane in
            titleBytes.withUnsafeBufferPointer { title in
                bodyBytes.withUnsafeBufferPointer { bodyRun in
                    wsAnswerBytes { out, cap in
                        Int(slopdesk_ws_toast_explicit_osc(
                            pane.baseAddress, pane.count,
                            title.baseAddress, title.count,
                            bodyRun.baseAddress, bodyRun.count,
                            body != nil, redact, out, cap,
                        ))
                    }
                }
            }
        }
        return unpacked(blob, paneKey: key) ?? Self(id: "pane.\(key)", title: "", paneKey: key)
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
        let keyBytes = Array(paneIDKey.utf8)
        let titleBytes = Array(paneTitle.utf8)
        let redact = SettingsKey.redactSecretsEnabled
        let blob = keyBytes.withUnsafeBufferPointer { pane in
            titleBytes.withUnsafeBufferPointer { title in
                wsAnswerBytes { out, cap in
                    Int(slopdesk_ws_toast_long_command(
                        pane.baseAddress, pane.count,
                        title.baseAddress, title.count,
                        exitCode ?? 0, exitCode != nil, durationMS, redact, out, cap,
                    ))
                }
            }
        }
        return unpacked(blob, paneKey: paneIDKey)
            ?? Self(id: "pane.\(paneIDKey)", title: "", paneKey: paneIDKey)
    }

    /// The in-app toast for a completed RECONNECT's fresh-vs-resumed verdict — the ONLY
    /// signal the user gets for whether a dropped link reattached the SAME live shell (scrollback/history
    /// intact) or spawned a FRESH shell (the previous session, and its context, ended). `.resumedSession` is
    /// reassuring (`.success`); `.freshShell` is a soft warning that context is gone (`.attention`).
    /// `.undetermined` is never a user-facing edge (the verdict has not resolved) ⇒ `nil` (nothing to show).
    /// No untrusted text (both strings are fixed templates), so no secret redaction is needed. The stable
    /// `pane.<key>` id de-dupes with the pane's other toasts so a newer event replaces this one.
    package static func sessionResume(
        paneIDKey: String, outcome: SlopDeskClient.SessionResumeOutcome,
    ) -> Self? {
        let index: UInt8 =
            switch outcome {
            case .undetermined: 0
            case .freshShell: 1
            case .resumedSession: 2
            }
        let keyBytes = Array(paneIDKey.utf8)
        let blob = keyBytes.withUnsafeBufferPointer { pane in
            wsAnswerBytes { out, cap in
                Int(slopdesk_ws_toast_session_resume(pane.baseAddress, pane.count, index, out, cap))
            }
        }
        // `docs/55` §4's `0` is the undetermined verdict itself: a reconnect that has not resolved is
        // not a user-facing edge, and a card for it would announce a fact nobody has yet.
        return unpacked(blob, paneKey: paneIDKey)
    }

    // MARK: - Reading a card

    /// One card's delivery: `[u8 flavor][u8 source][u8 flags]` then four runs — id, title, body,
    /// headline. `nil` for §4's `0`.
    ///
    /// `flags` bit 0 is "the body is present", bit 1 "the headline is present". An absent line and an
    /// empty one are DIFFERENT — a card with `Some("")` draws a blank second row and one with `nil`
    /// draws none — and a length prefix alone cannot tell them apart.
    private static func unpacked(_ blob: [UInt8], paneKey: String) -> Self? {
        guard blob.count >= 3 else { return nil }
        let flags = blob[2]
        let text = wsRuns(Array(blob.dropFirst(3)), count: 4)
        let flavor: Flavor =
            switch blob[0] {
            case 1: .success
            case 2: .error
            case 3: .attention
            default: .default
            }
        return Self(
            id: text[0],
            flavor: flavor,
            source: blob[1] == 1 ? .command : .agent,
            title: text[1],
            body: flags & 1 == 1 ? text[2] : nil,
            paneKey: paneKey,
            headline: flags & 2 == 2 ? text[3] : nil,
        )
    }
}
