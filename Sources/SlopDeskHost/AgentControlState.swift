import CSlopDeskFFI
import SlopDeskAgentDetect

/// The supervision vocabulary the agent-control NDJSON socket speaks: `idle` / `working` / `done`
/// / `blocked`.
///
/// A face over `slopdesk-agent`'s `supervision`, which is where the two collapses are stated and
/// tested — `needsPermission → "blocked"` (herdr's and Warp's term, because the socket's audience
/// is another agent and an enum case name is not an API), and `none → "idle"` (for a supervisor, a
/// pane with no agent is blocking nothing and running nothing).
///
/// The `none → idle` collapse costs the stream one bit: a pane whose agent EXITED emits the same
/// `"idle"` it already sat at, and the subscriber's consecutive-duplicate dedupe swallows it, so an
/// orchestrator watching `events` could never see one leave. ``presence(from:)`` carries that bit
/// beside the state rather than widening the closed set to five.
public enum AgentControlState {
    /// The four supervision states, in increasing urgency — the closed set the `report` verb
    /// validates against and both error messages print.
    public static let allStates: [String] = {
        var count = 0
        let blob = hostAnswerBytes(capacity: 256) { out, cap in
            Int(slopdesk_agent_supervision_states(out, cap, &count))
        }
        return hostRuns(blob, count: count)
    }()

    /// Maps a host ``ClaudeStatus`` to its ctl wire string.
    public static func string(from status: ClaudeStatus) -> String {
        hostAnswerText(capacity: 32) { out, cap in
            Int(slopdesk_agent_supervision_state(status.ffiByte, out, cap))
        }
    }

    /// Whether an agent is PRESENT in the pane at all — the bit ``string(from:)`` collapses away.
    public static func presence(from status: ClaudeStatus) -> Bool {
        slopdesk_agent_supervision_presence(status.ffiByte)
    }

    /// Whether `s` is one of the four known supervision states. The `report` verb's
    /// validate-then-drop guard, asked BEFORE it touches any session.
    public static func isValid(_ s: String) -> Bool {
        let bytes = Array(s.utf8)
        return bytes.withUnsafeBufferPointer { input in
            slopdesk_agent_supervision_valid(input.baseAddress, input.count)
        }
    }
}
