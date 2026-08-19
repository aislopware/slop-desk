// FirstLaunchStepPresentation — what the two CROSS-PLATFORM checklist steps say, and what they offer.
//
// docs/56 stage D's ruling applied to the first-launch sheet: the DECISION is shared and lives BELOW
// both halves; the DRAWING is per-half and never is. Until the Mac drew these steps in AppKit the two
// cross-platform bodies were ONE SwiftUI surface (`FirstLaunchStepSurface`) that the Mac HOSTED, so
// every word in them and every state→control answer had a single speller by accident — there was only
// ever one renderer. There are two now, so the words and the answers moved here and are single-spelled
// on purpose. Nothing below reads a framework; nothing above re-decides.
//
// ## What is deliberately NOT here
//
// **No ink, no metric, no font.** `SlopDeskSlate` DEPENDS on this target, so a token read from here
// would be a cycle rather than a widening. A badge therefore names its own SILHOUETTE — an SF Symbol
// both halves ask for by the same name — and leaves the HUE to the renderer, which spells one solved
// value two ways (`Slate.StatusInk.ok` in SwiftUI, `Slate.Native.StatusInk.ok` in AppKit). The badge
// cases are two, so that mapping is two lines per half; a `Slate.hooksInk(_:)` pair would collapse even
// those into one file, and is the only thing about this split still worth doing.
//
// **No step title, subtitle or glyph.** Those are `FirstLaunchStep`'s own, one floor further down in
// `SlopDeskWorkspaceCore` beside the gating that orders the steps — they were already shared and did
// not need lifting.
//
// **No macOS-only step body.** Registering as the default terminal and putting `slopdesk` on the PATH
// are LaunchServices and `/usr/local/bin`; the phone has no version of either, so there is no second
// half to keep in step with and nothing to spell once.

import SlopDeskWorkspaceCore // AgentHooksController, OnLaunchBehavior

// MARK: - Step 1 · On Launch

public extension OnLaunchBehavior {
    /// The choice's spoken name — the label on its radio / list row, and what a reader is told they
    /// picked. Here rather than at the picker because the SAME two words are offered by the guided
    /// checklist's step 1 and by Settings → General, in two frameworks; a raw value is an on-disk
    /// config string and is never shown.
    var title: String {
        switch self {
        case .restoreLastSession: "Restore Last Session"
        case .newWindow: "New Window"
        }
    }
}

// MARK: - Step 4 · Install Claude Code hooks

/// The finished states the hooks step reports as a BADGE rather than as a button — a silhouette and a
/// word, with nothing left to press.
///
/// The two are kept apart because a green check over a dead integration is the one thing this step must
/// never draw: ``inactive`` means the entries reached `~/.claude/settings.json` but the host's hook
/// listener never bound, so every installed hook exits silently. It earns the warning silhouette and
/// carries the fix, not the check.
public enum FirstLaunchHooksBadge: String, Equatable, Sendable, CaseIterable {
    /// Installed AND the host's listener is bound — the only state that earns the check.
    case installed
    /// Written to `settings.json` with the listener unbound: installed, and dead.
    case inactive

    /// The badge's word.
    public var label: String {
        switch self {
        case .installed: "Installed"
        case .inactive: "Installed — inactive"
        }
    }

    /// The badge's silhouette, as an SF-Symbol name both halves ask for by the same name.
    public var systemImage: String {
        switch self {
        case .installed: "checkmark"
        case .inactive: "exclamationmark.triangle"
        }
    }

    /// What to do about it, when there is anything to do — the hover hint beside an ``inactive`` badge.
    /// `nil` for ``installed``, because a working integration has no instruction attached.
    public var hint: String? {
        switch self {
        case .installed: nil
        case .inactive: "The host's hook socket isn't bound. Restart the host daemon, then open new panes."
        }
    }
}

/// What the hooks step's trailing slot holds, by the controller's install state.
///
/// One value for the whole slot rather than a label plus an enabled flag plus a spinner flag: the three
/// are mutually exclusive and were read separately once already, which is how a card ends up drawing a
/// live-looking button with nothing behind it.
public enum FirstLaunchHooksControl: Equatable, Sendable {
    /// A finished state — draw ``FirstLaunchHooksBadge``, no control.
    case badge(FirstLaunchHooksBadge)
    /// The Install button. `enabled` is FALSE while no connected pane backs the card: the button is
    /// shown DISABLED rather than hidden, so the step still says what it is for (docs/DECISIONS, "no
    /// dead UI" — an honest disabled control, never a live-looking one that cannot work).
    case offerInstall(enabled: Bool)
    /// A write is in flight — a spinner owns the slot.
    case working
}

/// The two cross-platform step bodies' shared answers: their wording, and the hooks step's state
/// machine as the drawing sees it.
///
/// ⚠️ THE WORDS ARE NOT ISOLATED; the answers are. Every constant here is a `String` a renderer reads
/// wherever it happens to be, so hoisting `@MainActor` to the type would force an actor hop on a label
/// lookup. Only the four functions that read ``AgentHooksController`` — which IS `@MainActor` — carry it.
public enum FirstLaunchStepPresentation {
    // MARK: Step 1 · On Launch

    /// The picker's options, in the order they are offered. Declaration order, which puts the
    /// RECOMMENDED default first — it is also the behaviour a reader already has, so the list reads
    /// top-down as "keep this" then "change it".
    public static let onLaunchOptions: [OnLaunchBehavior] = OnLaunchBehavior.allCases

    /// The note under the picker: what the recommended choice actually brings back, and where to change
    /// the answer later. Named here so the checklist and any future second renderer cannot drift.
    public static let onLaunchNote =
        "Restore Last Session brings back your scrollback and reconnects agents that kept running "
            + "on the host. You can change this any time in Settings → General."

    // MARK: Step 4 · Install Claude Code hooks

    /// The card's heading — the agent this step integrates with. **Claude Code only**: there is no
    /// codex/opencode equivalent behind ``AgentHooksController``, and the card says so by naming it.
    public static let hooksAgentName = "Claude Code"

    /// The card's one line about what installing does, in the file it does it to.
    public static let hooksBlurb = "Add hooks to ~/.claude/settings.json for real-time agent state."

    /// The verb on the install button, live or dead — one word, so the two halves cannot end up
    /// offering "Install" and "Install Hooks" for the same press.
    public static let hooksInstallTitle = "Install"

    /// The note shown while nothing backs the card. It names the ORDER (connect, then install) and the
    /// later door, because the disabled button alone does not say why it is disabled.
    public static let hooksConnectNote =
        "Connect a session first, then install the hooks. You can also do this later in Settings → Agents."

    /// The install state to draw, with the `nil`-controller fallback folded in.
    ///
    /// ⚠️ A `nil` controller MUST read as ``AgentHooksController/InstallState/disconnected`` and NEVER
    /// as a live card — the iOS settings sheet shipped once without the injection, and an inline
    /// `?? true` at the call site is exactly how that became a card claiming an integration was
    /// installed. This is the ONE place that fallback is spelled: `AgentSettingsCard.installState(_:)`
    /// forwards here, and the Mac's AppKit checklist calls it directly.
    @preconcurrency
    @MainActor
    public static func hooksState(_ controller: AgentHooksController?) -> AgentHooksController.InstallState {
        controller?.state ?? .disconnected
    }

    /// What the trailing slot holds for `controller`.
    ///
    /// `.unknown` is folded in with `.disconnected` on purpose: it is the pre-probe state, it resolves
    /// within one round trip, and offering a live Install button for that beat would be a button whose
    /// backing is unknown — the same lie as the `nil` controller.
    @preconcurrency
    @MainActor
    public static func hooksControl(_ controller: AgentHooksController?) -> FirstLaunchHooksControl {
        switch hooksState(controller) {
        case .installed: .badge(.installed)
        case .installedInactive: .badge(.inactive)
        case .notInstalled: .offerInstall(enabled: true)
        case .working: .working
        case .disconnected,
             .unknown: .offerInstall(enabled: false)
        }
    }

    /// Whether ``hooksConnectNote`` is shown — exactly when the Install button is dead for want of a
    /// pane, which is the only state the note explains.
    @preconcurrency
    @MainActor
    public static func showsConnectNote(_ controller: AgentHooksController?) -> Bool {
        hooksControl(controller) == .offerInstall(enabled: false)
    }

    /// Whether an install that has already re-probed counts as COMPLETING the checklist step.
    ///
    /// The step tracks the `settings.json` WRITE, so ``AgentHooksController/InstallState/installedInactive``
    /// counts: the entries are on disk, and whether the host's listener bound is a hostd-launch concern the
    /// badge surfaces separately. Ticking the step only for the green state would leave a reader who did
    /// everything right looking at an unfinished checklist because of a daemon they have not restarted yet.
    @preconcurrency
    @MainActor
    public static func completesHooksStep(_ controller: AgentHooksController?) -> Bool {
        controller?.isInstalled ?? false
    }
}
