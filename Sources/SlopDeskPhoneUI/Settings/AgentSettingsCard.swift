// AgentSettingsCard's environment slot — the reader and the writer of one key, together.
//
// docs/56: the derivation itself (`installState(_:)` / `behaviourEnabled(_:)`) named no view framework —
// `AgentHooksController` is `SlopDeskWorkspaceCore`'s, and both static funcs return a plain enum / `Bool`
// — so `enum AgentSettingsCard` descended to `SlopDeskClientCore/Settings/AgentSettingsCard.swift` in
// batch 2 of the draining-floor split. What is left here is SwiftUI itself: `@Entry` and
// `EnvironmentValues` are the framework, not decisions about the card, so the slot that carries the
// controller down to the Agents page stays on this side of the fence with the views that inject and
// read it.

#if os(iOS)
import SlopDeskWorkspaceCore
import SwiftUI

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
