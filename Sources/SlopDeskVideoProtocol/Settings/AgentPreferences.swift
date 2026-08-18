/// Claude-Code / agent detection preferences (decision #5 / §7.5). Maps to the agent flags consumed
/// by the TERMINAL host daemon (`slopdesk-hostd`, via `HostEnvironment`). The detection core
/// (`SlopDeskAgentDetect`) is env-free and pure; these prefs gate host-side POLICY only.
///
/// The Claude hook listener is deliberately ABSENT: it has no gate any more (it binds always), so
/// there is no preference to carry. An older sidecar still naming `agentHooks` decodes fine — an
/// unknown key is simply not read, which is this repo's no-migration contract.
///
/// Like ``VideoPreferences``, these gate host-daemon behaviour read at launch, so they ride the same
/// `video-prefs.json` sidecar → ``EnvConfig/overlay`` mechanism (decision #10, "applies on reconnect").
/// `slopdesk-hostd` loads that sidecar at launch, so these flags actually reach `HostEnvironment`.
/// Default = `nil` (unset) ⇒ EMPTY env overlay ⇒ today's compile-time-default behaviour.
public struct AgentPreferences: Codable, Sendable, Equatable {
    /// Hold a system-sleep assertion while ANY agent is processing (the "Prevent Sleep
    /// While Processing" toggle) → `SLOPDESK_AGENT_PREVENT_SLEEP` (default-OFF host gate, `== "1"`). Host-LOCAL
    /// policy: the daemon holds the `IOPMAssertion` (``PreventSleepAssertion``) driven by the `claudeStatus
    /// .working` aggregate it already computes, so it needs no live wire verb — it rides this sidecar like the
    /// other two flags (surfaced with the `.reconnect` timing chip). `nil` ⇒ unset (the daemon default-OFF).
    public var preventSleep: Bool?
    /// Re-arm a detached agent session on connection recovery (the "Resume on Recovery" toggle) →
    /// `SLOPDESK_AGENT_RESUME_ON_RECOVERY` (default-ON host gate, `!= "0"`). Host-LOCAL, sidecar-borne like
    /// ``preventSleep``. `nil` ⇒ unset (the daemon default-ON).
    public var resumeOnRecovery: Bool?

    /// What the daemon does with ``preventSleep`` unset, and what a control over it must therefore
    /// SHOW while it is unset. Named rather than spelled at the control: a toggle that read `nil` as
    /// `false` would misreport ``resumeOnRecovery``, whose absent state is ON.
    public static let preventSleepDefault = false
    /// What the daemon does with ``resumeOnRecovery`` unset — see ``preventSleepDefault``.
    public static let resumeOnRecoveryDefault = true

    public init(
        preventSleep: Bool? = nil,
        resumeOnRecovery: Bool? = nil,
    ) {
        self.preventSleep = preventSleep
        self.resumeOnRecovery = resumeOnRecovery
    }
}
