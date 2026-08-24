import CSlopDeskFFI

/// The coding agents the screen-manifest engine can detect (herdr `Agent`, ported 1:1).
/// `omp`/`mastracode` are hook-authority-only upstream and ship no screen manifest.
public enum AgentKind: String, CaseIterable, Sendable {
    case pi
    case claude
    case codex
    case gemini
    case cursor
    case devin
    case antigravity = "agy"
    case cline
    case omp
    case mastracode
    case openCode = "opencode"
    case githubCopilot = "copilot"
    case kimi
    case kiro
    case droid
    case amp
    case grok
    case hermes
    case kilo
    case qodercli
    case maki

    /// Canonical label (the raw value) — matches herdr `agent_label`.
    public var label: String { rawValue }

    /// The 19 agents with a bundled screen manifest (herdr `SCREEN_MANIFEST_AGENTS`).
    public static let screenManifestAgents: [Self] = allCases.filter {
        $0 != .omp && $0 != .mastracode
    }

    // MARK: Identification — the tables are `rust/slopdesk-agent`, not this file (docs/55)

    /// Identifies an agent from a process/executable name, or `nil` for a shell or unknown program.
    ///
    /// The alias table it consults has ~40 entries across 21 agents and is ported from herdr; it
    /// lives in `rust/slopdesk-agent::kind` with the differential tests that prove it. What crosses
    /// is an index into ``allCases``, which is the same order as the crate's `AgentKind::ALL` —
    /// `rust/slopdesk-invariants` fails the build if the two ever disagree.
    public static func identify(processName: String) -> Self? {
        at(index: agentPredicateIndex(processName))
    }

    /// A crate-side answer as a case: an index into ``allCases``, or `nil` for the `-1` every door
    /// spells "no agent" with.
    ///
    /// Out of range is `nil` rather than a trap, which is the documented contract for a crate that
    /// grew an agent this build has never heard of — the pane shows no agent instead of crashing.
    public static func at(index: Int) -> Self? {
        guard index >= 0 else { return nil }
        let all = allCases
        guard index < all.count else { return nil }
        return all[all.index(all.startIndex, offsetBy: index)]
    }

    private static func agentPredicateIndex(_ name: String) -> Int {
        var bytes = Array(name.utf8)
        return bytes.withUnsafeMutableBufferPointer { buffer in
            Int(slopdesk_agent_kind_identify(buffer.baseAddress, buffer.count))
        }
    }

    /// A basename that hosts other programs and must never itself count as an agent.
    public static func isGenericRuntimeOrShell(_ name: String) -> Bool {
        agentPredicate(name) { bytes, len in
            slopdesk_agent_kind_is_generic(bytes, len)
        }
    }
}
