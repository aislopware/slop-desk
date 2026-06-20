import Foundation

/// Claude-Code / agent detection preferences (decision #5 / §7.5). Maps to the two agent-detection
/// flags consumed by the TERMINAL host daemon (`aislopdesk-hostd`, via `HostEnvironment`) — the
/// foreground-process watch (`AISLOPDESK_AGENT_DETECT`, default-ON) and the opt-in Claude hooks
/// (`AISLOPDESK_AGENT_HOOKS`, default-OFF). The detection core (`AislopdeskAgentDetect`, W7) is env-free
/// and pure; these prefs gate whether the HOST emits the type-26/27 signals at all.
///
/// Like ``VideoPreferences``, these gate host-daemon behaviour read at launch, so they ride the same
/// `video-prefs.json` sidecar → ``EnvConfig/overlay`` mechanism (decision #10, "applies on reconnect").
/// W12 wires `aislopdesk-hostd` to load that sidecar at launch (it previously did not), so these two
/// flags actually reach `HostEnvironment.agentDetectEnabled()` / `agentHooksEnabled()`.
/// Default = `nil` (unset) ⇒ EMPTY env overlay ⇒ today's compile-time-default behaviour.
public struct AgentPreferences: Codable, Sendable, Equatable {
    /// Host foreground-process watch (the primary, zero-config Claude signal, wire type 26) →
    /// `AISLOPDESK_AGENT_DETECT`. `nil` ⇒ unset (the daemon default).
    public var agentDetect: Bool?
    /// Claude Code hooks (the richest, opt-in signal, wire type 27) → `AISLOPDESK_AGENT_HOOKS`.
    public var agentHooks: Bool?

    public init(agentDetect: Bool? = nil, agentHooks: Bool? = nil) {
        self.agentDetect = agentDetect
        self.agentHooks = agentHooks
    }
}
