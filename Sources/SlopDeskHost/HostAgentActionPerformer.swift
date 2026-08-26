#if os(macOS)
import Foundation
import SlopDeskProtocol

/// The THIN macOS shim that actuates the THREE agent-hooks metadata verbs
/// (``MetadataVerb/installAgentHooks`` = 11 / ``MetadataVerb/uninstallAgentHooks`` = 12 /
/// ``MetadataVerb/agentHookStatus`` = 13) on the HOST's own `~/.claude/settings.json`. It is the
/// install/uninstall twin of ``HostPathActionPerformer``: ``MuxChannelSession/serveMetadata`` routes a
/// `metadataRequest` whose verb is 11/12/13 HERE (BEFORE the pure ``MetadataResponseBuilder``, which
/// performs NO side effects and never sees these verbs in production), and forwards every OTHER verb to
/// the builder. Like ``HostPathActionPerformer`` it is **compiled + code-reviewed ONLY** — never
/// instantiated in a unit test (it touches the host's home-directory settings file on disk; the
/// hang/IO-safety rule). The CLIENT routing (verb 11/12/13 encode + ok/error decode + the 2-byte status
/// flags) is the unit-tested half (``MetadataClient`` + `MetadataClientAgentHooksTests`), and the pure
/// install/uninstall/marker logic is `slopdesk-agenthooks`'s, tested by `install::tests`.
///
/// **Host-global, not pane-scoped.** Install/uninstall act on the host's single `~/.claude/settings.json`
/// regardless of which pane's mux channel carried the request, so this shim ignores the request payload
/// (the wire verbs carry an EMPTY payload). ``AgentHooks`` resolves the target from the environment
/// hostd is running in, honoring `CLAUDE_CONFIG_DIR`.
///
/// **No exfiltration → no cwd confinement.** 11/12 return ONLY a status byte + empty payload; 13 returns
/// the 2-byte `[installed][listenerActive]` flags (docs/20) — no host FILE contents ever cross the wire,
/// so (like 9/10) they are not an exfiltration vector. The host ALWAYS replies for 11/12/13 so the client's
/// pending-request registry never hangs; a thrown install/uninstall maps to ``MetadataStatus/error``
/// (validate-then-drop — never force-unwraps, never traps on a hostile verb).
///
/// `#if os(macOS)` — the host daemon is macOS-only; this is NEVER compiled into the iOS slice (the iOS
/// client routes install/uninstall/status TO the host over this same wire, it never performs them locally).
enum HostAgentActionPerformer {
    /// Actuates one of the agent-hooks verbs (11/12/13) against the host's default Claude config and
    /// answers the `metadataResponse`. Which verbs reach here is
    /// ``MetadataAdmission/performer(for:)``'s answer, not this shim's. The request `payload` is
    /// intentionally ignored (host-global, empty by contract).
    ///
    /// `hookListenerActive` is the LIVE bind state of the hostd hook listener: verb 13's reply carries it
    /// as a second flag byte so the client can distinguish "hooks written to settings.json" from "hooks
    /// actually flowing" — a green "Installed" over an unbound socket would be a lie (every installed
    /// hook exits silently without `$SLOPDESK_SOCKET_PATH`). The listener is unconditional now, so the
    /// flag reports a bind FAILURE rather than a configuration choice.
    static func response(
        requestID: UInt32, verb: UInt8, payload _: Data, hookListenerActive: Bool = false,
    ) -> WireMessage {
        switch MetadataVerb(rawValue: verb) {
        case .installAgentHooks:
            return statusResponse(requestID: requestID, status: installHooks())
        case .uninstallAgentHooks:
            return statusResponse(requestID: requestID, status: uninstallHooks())
        case .agentHookStatus:
            let installed = AgentHooks.isInstalled()
            return .metadataResponse(
                requestID: requestID,
                status: MetadataStatus.ok.rawValue,
                payload: statusFlags(installed: installed, listenerActive: hookListenerActive),
            )
        default:
            // Unreachable: which verbs reach here is ``MetadataAdmission/performer(for:)``'s
            // answer. `.error` rather than a second opinion about who owns a verb.
            return statusResponse(requestID: requestID, status: .error)
        }
    }

    /// The verb-13 response payload: `[installed][listenerActive]` (docs/20). PURE (no disk) so the
    /// exact byte shape is unit-pinned without instantiating the disk-touching verbs — and spelled
    /// by the same codec the client decodes with, so the encoder and the decoder cannot disagree
    /// about which byte means yes.
    static func statusFlags(installed: Bool, listenerActive: Bool) -> Data {
        MetadataCodec.encodeAgentHookStatus(
            MetadataCodec.AgentHookStatus(installed: installed, listenerActive: listenerActive),
        )
    }

    /// Installs the slopdesk Claude Code hooks (relay binary + `settings.json` merge) on the host.
    /// `.ok` on a successful write, `.error` if the installer reported one (a disk / permission
    /// failure, or a relay that was never staged beside the host) or could not be run at all. Named
    /// `installHooks`, NOT `install`, to keep the shim's surface self-describing alongside
    /// `uninstallHooks`.
    static func installHooks() -> MetadataStatus {
        succeeded(AgentHooks.install())
    }

    /// Uninstalls the slopdesk Claude Code hooks (strips exactly our `settings.json` entries) on the
    /// host. `.ok` on success, `.error` if the uninstall reported one.
    static func uninstallHooks() -> MetadataStatus {
        succeeded(AgentHooks.uninstall())
    }

    /// Maps one installer answer to the wire status. A `nil` answer — no installer on this host —
    /// is an error for the same reason a thrown one was: the client asked for a state change that
    /// did not happen, and a green reply for it would be a lie.
    private static func succeeded(_ answer: AgentHooks.Answer?) -> MetadataStatus {
        guard let answer, answer.error == nil else { return .error }
        return .ok
    }

    /// Builds an empty-payload `metadataResponse` carrying `status` (the 11/12 reply shape).
    private static func statusResponse(requestID: UInt32, status: MetadataStatus) -> WireMessage {
        .metadataResponse(requestID: requestID, status: status.rawValue, payload: Data())
    }
}
#endif
