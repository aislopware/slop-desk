// AgentSettingsCard — what the Agents card shows when nothing is behind it.
//
// The card is driven by an OPTIONAL ``AgentHooksController`` injected at the Settings scene root, and
// the whole content of this file is the two answers for `nil`. They are here rather than inline in the
// page because a `nil` controller must NEVER read as a live card, and that is a rule with a test
// (`AgentSettingsCardWiringTests` in the phone app's own bundle, plus the pure fallback pin in
// `SlopDeskClientCoreTests`) rather than a fallback typed twice — the iOS sheet shipped without
// the injection once, and an inline `?? true` is exactly how that became a card claiming an
// integration was installed.
//
// docs/56: this enum names no view framework — `AgentHooksController` is `SlopDeskWorkspaceCore`'s, and
// both static funcs return a plain enum / `Bool` — so it descended here from the old shared SwiftUI
// target in batch 2 of the draining-floor split. What stayed behind is the `@Entry` environment slot
// (`EnvironmentValues.agentHooksController` / `View.agentHooksController(_:)`): an environment key IS
// SwiftUI, so the reader-and-writer-of-one-key pairing lives in
// `SlopDeskPhoneUI/Settings/AgentSettingsCard.swift` beside the views that inject and read it.

import SlopDeskWorkspaceCore

/// `package`: read from `SlopDeskPhoneUI` (`SettingsPages.swift`, and the environment slot's own file)
/// across the module boundary, the way `SettingsCatalog` and `SettingsIndexPresentation` beside it are.
package enum AgentSettingsCard {
    /// The install-card state to show: the controller's state, or `.disconnected` when no controller backs it.
    ///
    /// ⚠️ FORWARDED, not spelled here any more. The Mac's AppKit first-launch checklist needs the same
    /// fallback and cannot reach this target (docs/56 stage D — `SlopDeskMacUI` does not import the phone's
    /// half), so the rule descended to ``FirstLaunchStepPresentation/hooksState(_:)`` in `SlopDeskClientCore`
    /// and this stays as the name the settings pages and `AgentSettingsCardWiringTests` already call. Two
    /// callers, ONE answer — which is the whole point of the fallback existing as a function at all.
    package static func installState(_ controller: AgentHooksController?) -> AgentHooksController.InstallState {
        FirstLaunchStepPresentation.hooksState(controller)
    }

    /// Whether the Agent-Behaviour toggles are configurable (an integration is installed). A nil controller ⇒
    /// `false` ⇒ the whole behaviour section is greyed (the exact iOS bug when the controller is not injected).
    package static func behaviourEnabled(_ controller: AgentHooksController?) -> Bool {
        controller?.isInstalled ?? false
    }
}
