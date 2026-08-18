import CSlopDeskFFI

// MARK: - Prevent-sleep decision (marshalling)

/// The host's "prevent sleep while an agent is processing" feature, asked of `slopdesk_agent::sleep`.
/// The macOS glue (``PreventSleepAssertion``) holds the actual `IOPMAssertion` and is driven by this
/// verdict in `slopdesk-hostd`.
///
/// The host already computes a per-pane ``ClaudeStatus`` (the foreground-process watch + hooks); the daemon
/// aggregates the live `.working` panes into `anyAgentWorking` and asks here whether to hold the assertion.
/// The toggle reaches the host via the ``AgentPreferences`` sidecar (`SLOPDESK_AGENT_PREVENT_SLEEP`,
/// default-OFF), surfaced as `enabled`.
public enum PreventSleepPolicy {
    /// Whether the host should hold a system-sleep assertion right now. The answer is the WHOLE state, so
    /// the glue's create⇄release stays strictly balanced against it — a leaked assertion keeps the Mac awake.
    public static func shouldAssert(anyAgentWorking: Bool, enabled: Bool) -> Bool {
        slopdesk_agent_should_prevent_sleep(anyAgentWorking, enabled)
    }
}
