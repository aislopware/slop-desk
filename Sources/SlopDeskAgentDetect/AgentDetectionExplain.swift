import Foundation

/// Diagnostic evaluation trace (herdr `DetectionExplain`, ported 1:1). This is the
/// differential-parity surface: `scripts/herdr-differential.py` runs the real herdr binary's
/// `agent explain --file … --json` next to ours and diffs these fields per rule, so every
/// region resolver and gate is checked against upstream byte-for-byte. Not on any hot path —
/// the engine's `evaluate` stays the runtime entry point.
public struct AgentDetectionExplain: Sendable, Equatable {
    public struct MatchedRule: Sendable, Equatable {
        public let id: String
        public let priority: Int32
        public let region: String
        public let state: AgentScreenState
    }

    public struct RuleEvidence: Sendable, Equatable {
        public let contains: [String]
        public let regex: [String]
        public let lineRegex: [String]
        public let allCount: Int
        public let anyCount: Int
        public let notCount: Int
        /// UTF-8 byte length of the resolved region text (Rust `str::len`).
        public let regionBytes: Int
        public let regionPreview: String
    }

    public struct EvaluatedRule: Sendable, Equatable {
        public let id: String
        public let priority: Int32
        public let region: String
        public let evidence: RuleEvidence
        public let state: AgentScreenState
        public let matched: Bool
    }

    public let agent: String?
    public let state: AgentScreenState
    /// `"bundled"` when a bundled manifest evaluated; `nil` for no-manifest agents.
    public let manifestSource: String?
    public let manifestVersion: String?
    public let matchedRule: MatchedRule?
    public let visibleIdle: Bool
    public let visibleBlocker: Bool
    public let visibleWorking: Bool
    public let skipStateUpdate: Bool
    public let skippedUpdateReason: String?
    public let fallbackReason: String?
    public let evaluatedRules: [EvaluatedRule]
}

public extension CompiledAgentManifest {
    /// herdr `evaluate_loaded_manifest` with explain output: evaluates every rule, records
    /// per-rule evidence, then applies the same winner/fallback logic as `evaluate`.
    func explain(agent: AgentKind, input: AgentDetectionInput) -> AgentDetectionExplain {
        var winner: CompiledRule?
        var evaluated: [AgentDetectionExplain.EvaluatedRule] = []
        evaluated.reserveCapacity(rules.count)

        for compiled in rules {
            let text = compiled.region.resolve(input)
            let matched = Self.matches(compiled.gate, text: text, input: input)
            let rule = compiled.rule
            evaluated.append(AgentDetectionExplain.EvaluatedRule(
                id: rule.id,
                priority: rule.priority,
                region: rule.region,
                evidence: AgentDetectionExplain.RuleEvidence(
                    contains: rule.gate.contains,
                    regex: rule.gate.regex,
                    lineRegex: rule.gate.lineRegex,
                    allCount: rule.gate.all.count,
                    anyCount: rule.gate.any.count,
                    notCount: rule.gate.not.count,
                    regionBytes: text.utf8.count,
                    regionPreview: Self.boundedPreview(text),
                ),
                state: rule.state ?? .unknown,
                matched: matched,
            ))
            guard matched else { continue }
            if let current = winner, current.rule.priority >= compiled.rule.priority { continue }
            winner = compiled
        }

        guard let winner else {
            return .fallback(agent: agent, manifest: manifest, evaluatedRules: evaluated)
        }
        let rule = winner.rule
        let state = rule.state ?? .unknown
        return AgentDetectionExplain(
            agent: agent.label,
            state: state,
            manifestSource: "bundled",
            manifestVersion: manifest.version,
            matchedRule: AgentDetectionExplain.MatchedRule(
                id: rule.id,
                priority: rule.priority,
                region: rule.region,
                state: state,
            ),
            visibleIdle: rule.visibleIdle && state == .idle,
            visibleBlocker: rule.visibleBlocker && state == .blocked,
            visibleWorking: rule.visibleWorking && state == .working,
            skipStateUpdate: rule.skipStateUpdate,
            skippedUpdateReason: rule.skipStateUpdate ? "matched_rule:\(rule.id)" : nil,
            fallbackReason: nil,
            evaluatedRules: evaluated,
        )
    }

    /// herdr `bounded_preview`: first 240 Unicode scalars (Rust `char`s), `"..."` appended
    /// when truncated.
    static func boundedPreview(_ text: String) -> String {
        let maxChars = 240
        var preview = String(String.UnicodeScalarView(text.unicodeScalars.prefix(maxChars)))
        if text.unicodeScalars.count > maxChars { preview += "..." }
        return preview
    }
}

public extension AgentDetectionExplain {
    /// herdr `fallback_explain` for a known agent: plain idle, no visible flags. `manifest`
    /// is nil for agents without a bundled manifest (source/version stay nil, like upstream's
    /// context-less fallback).
    static func fallback(
        agent: AgentKind,
        manifest: AgentManifest?,
        evaluatedRules: [EvaluatedRule],
    ) -> Self {
        AgentDetectionExplain(
            agent: agent.label,
            state: .idle,
            manifestSource: manifest == nil ? nil : "bundled",
            manifestVersion: manifest?.version,
            matchedRule: nil,
            visibleIdle: false,
            visibleBlocker: false,
            visibleWorking: false,
            skipStateUpdate: false,
            skippedUpdateReason: nil,
            fallbackReason: AgentScreenDetection.knownAgentIdleFallbackReason,
            evaluatedRules: evaluatedRules,
        )
    }

    /// herdr `explain_for_label` for an unrecognized label.
    static func unknownAgent(label: String) -> Self {
        AgentDetectionExplain(
            agent: label,
            state: .unknown,
            manifestSource: nil,
            manifestVersion: nil,
            matchedRule: nil,
            visibleIdle: false,
            visibleBlocker: false,
            visibleWorking: false,
            skipStateUpdate: false,
            skippedUpdateReason: nil,
            fallbackReason: "unknown_agent",
            evaluatedRules: [],
        )
    }
}

public extension AgentManifestCatalog {
    /// herdr `explain_for_label` (the `agent explain --file` path): screen-only input, OSC
    /// fields empty.
    static func explain(agentLabel: String, screen: String) -> AgentDetectionExplain {
        guard let agent = AgentKind(rawValue: agentLabel) else {
            return .unknownAgent(label: agentLabel)
        }
        let input = AgentDetectionInput(screen: screen)
        guard let compiled = compiled[agent] else {
            return .fallback(agent: agent, manifest: nil, evaluatedRules: [])
        }
        return compiled.explain(agent: agent, input: input)
    }
}
