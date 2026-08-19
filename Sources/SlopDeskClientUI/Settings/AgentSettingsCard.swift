// AgentSettingsCard — what the Agents card shows when nothing is behind it.
//
// The card is driven by an OPTIONAL ``AgentHooksController`` injected at the Settings scene root, and
// the whole content of this file is the two answers for `nil`. They are here rather than inline in the
// page because a `nil` controller must NEVER read as a live card, and that is a rule with a test
// (`AgentSettingsCardWiringTests`) rather than a fallback typed twice — the iOS sheet shipped without
// the injection once, and an inline `?? true` is exactly how that became a card claiming an
// integration was installed.
//
// The environment slot is here for the same reason: the reader and the writer of one key belong
// together.

#if canImport(SwiftUI)
import SlopDeskClientCore // FirstLaunchStepPresentation — where the nil fallback now lives
import SlopDeskWorkspaceCore
import SwiftUI

/// The Agents card's derived state from the (optional) injected ``AgentHooksController`` — the ONE place the
/// nil-controller fallbacks live, so the macOS scene and iOS ``SettingsSheet`` derive the card identically. A
/// `nil` controller (no injection — e.g. the iOS-sheet wiring this regression fixes) MUST fall back to
/// ``AgentHooksController/InstallState/disconnected`` + behaviour-disabled, NEVER a false live card. Pure +
/// cross-platform, unit-pinned headlessly (`AgentSettingsCardWiringTests`).
@MainActor
enum AgentSettingsCard {
    /// The install-card state to show: the controller's state, or `.disconnected` when no controller backs it.
    ///
    /// ⚠️ FORWARDED, not spelled here any more. The Mac's AppKit first-launch checklist needs the same
    /// fallback and cannot reach this target (docs/56 stage D — `SlopDeskMacUI` does not import the phone's
    /// half), so the rule descended to ``FirstLaunchStepPresentation/hooksState(_:)`` in `SlopDeskClientCore`
    /// and this stays as the name the settings pages and `AgentSettingsCardWiringTests` already call. Two
    /// callers, ONE answer — which is the whole point of the fallback existing as a function at all.
    static func installState(_ controller: AgentHooksController?) -> AgentHooksController.InstallState {
        FirstLaunchStepPresentation.hooksState(controller)
    }

    /// Whether the Agent-Behaviour toggles are configurable (an integration is installed). A nil controller ⇒
    /// `false` ⇒ the whole behaviour section is greyed (the exact iOS bug when the controller is not injected).
    static func behaviourEnabled(_ controller: AgentHooksController?) -> Bool {
        controller?.isInstalled ?? false
    }
}

// MARK: - Agents settings-card environment slot

extension EnvironmentValues {
    /// The single app-owned ``AgentHooksController``, injected at the Settings scene root so the
    /// Agents card reaches it. `nil` outside the app scene (previews / the iOS sheet before its wiring lands)
    /// → the card renders disabled rather than crashing.
    @Entry var agentHooksController: AgentHooksController?
}

package extension View {
    /// Inject the app-owned ``AgentHooksController`` into the environment (called at the Settings scene root).
    func agentHooksController(_ controller: AgentHooksController?) -> some View {
        environment(\.agentHooksController, controller)
    }
}
#endif
