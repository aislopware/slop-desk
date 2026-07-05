import Foundation

/// Claude-Code / agent detection preferences (decision #5 / §7.5). Maps to the two agent-detection
/// flags consumed by the TERMINAL host daemon (`slopdesk-hostd`, via `HostEnvironment`) — the
/// foreground-process watch (`SLOPDESK_AGENT_DETECT`, default-ON) and the opt-in Claude hooks
/// (`SLOPDESK_AGENT_HOOKS`, default-OFF). The detection core (`SlopDeskAgentDetect`, W7) is env-free
/// and pure; these prefs gate whether the HOST emits the type-26/27 signals at all.
///
/// Like ``VideoPreferences``, these gate host-daemon behaviour read at launch, so they ride the same
/// `video-prefs.json` sidecar → ``EnvConfig/overlay`` mechanism (decision #10, "applies on reconnect").
/// W12 wires `slopdesk-hostd` to load that sidecar at launch (it previously did not), so these two
/// flags actually reach `HostEnvironment.agentDetectEnabled()` / `agentHooksEnabled()`.
/// Default = `nil` (unset) ⇒ EMPTY env overlay ⇒ today's compile-time-default behaviour.
public struct AgentPreferences: Codable, Sendable, Equatable {
    /// Host foreground-process watch (the primary, zero-config Claude signal, wire type 26) →
    /// `SLOPDESK_AGENT_DETECT`. `nil` ⇒ unset (the daemon default).
    public var agentDetect: Bool?
    /// Claude Code hooks (the richest, opt-in signal, wire type 27) → `SLOPDESK_AGENT_HOOKS`.
    public var agentHooks: Bool?
    /// E13 WI-3 (ES-E13-3): hold a system-sleep assertion while ANY agent is processing (the "Prevent Sleep
    /// While Processing" toggle) → `SLOPDESK_AGENT_PREVENT_SLEEP` (default-OFF host gate, `== "1"`). Host-LOCAL
    /// policy: the daemon holds the `IOPMAssertion` (``PreventSleepAssertion``) driven by the `claudeStatus
    /// .working` aggregate it already computes, so it needs no live wire verb — it rides this sidecar like the
    /// other two flags (surfaced with the `.reconnect` timing chip). `nil` ⇒ unset (the daemon default-OFF).
    public var preventSleep: Bool?
    /// E13 WI-3: re-arm a detached agent session on connection recovery (the "Resume on Recovery" toggle) →
    /// `SLOPDESK_AGENT_RESUME_ON_RECOVERY` (default-ON host gate, `!= "0"`). Host-LOCAL, sidecar-borne like
    /// ``preventSleep``. `nil` ⇒ unset (the daemon default-ON).
    public var resumeOnRecovery: Bool?

    public init(
        agentDetect: Bool? = nil,
        agentHooks: Bool? = nil,
        preventSleep: Bool? = nil,
        resumeOnRecovery: Bool? = nil,
    ) {
        self.agentDetect = agentDetect
        self.agentHooks = agentHooks
        self.preventSleep = preventSleep
        self.resumeOnRecovery = resumeOnRecovery
    }
}
