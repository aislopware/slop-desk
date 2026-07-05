import Foundation

// MARK: - E13 WI-3 (ES-E13-3): prevent-sleep decision (pure, headless)

/// The pure decision behind the host's "prevent sleep while an agent is processing" feature. Kept tiny and
/// dependency-free (no `IOPMAssertion`, no PTY, no clock) so it is unit-pinned headlessly; the macOS glue
/// (``PreventSleepAssertion``) holds the actual assertion and is driven by this verdict in `slopdesk-hostd`.
///
/// The host already computes a per-pane ``ClaudeStatus`` (the foreground-process watch + hooks); the daemon
/// aggregates the live `.working` panes into `anyAgentWorking` and asks here whether to hold the assertion.
/// The toggle reaches the host via the ``AgentPreferences`` sidecar (`SLOPDESK_AGENT_PREVENT_SLEEP`,
/// default-OFF), surfaced as `enabled`.
public enum PreventSleepPolicy {
    /// Whether the host should hold a system-sleep assertion right now: only when the feature is `enabled`
    /// AND at least one agent is currently working. When either is false, the assertion must be released
    /// (the strictly-balanced create⇄release the glue mirrors — a leaked assertion keeps the Mac awake).
    public static func shouldAssert(anyAgentWorking: Bool, enabled: Bool) -> Bool {
        enabled && anyAgentWorking
    }
}
