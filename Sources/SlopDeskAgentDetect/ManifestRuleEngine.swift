import Foundation

/// A compiled manifest ready for evaluation (herdr `LoadedManifest`/`CompiledRule`):
/// `contains` needles pre-lowercased, regexes pre-compiled. Immutable after construction —
/// `NSRegularExpression` is documented thread-safe, so evaluation is freely concurrent.
public final class CompiledAgentManifest: @unchecked Sendable {
    public let manifest: AgentManifest
    let rules: [CompiledRule]

    struct CompiledRule {
        let rule: AgentManifest.Rule
        let region: ManifestRegion
        let gate: CompiledGate
    }

    struct CompiledGate {
        let all: [Self]
        let any: [Self]
        let not: [Self]
        /// Pre-lowercased needles.
        let contains: [String]
        let regex: [NSRegularExpression]
        let lineRegex: [NSRegularExpression]
    }

    /// Compiles a VALIDATED manifest. Throws only if a regex fails to compile — validation
    /// already checked them, so this is a defensive second net (herdr compiles twice too).
    public init(manifest: AgentManifest) throws {
        self.manifest = manifest
        rules = try manifest.rules.map { rule in
            let spec = rule.region.trimmingCharacters(in: .whitespaces)
            guard let region = ManifestRegion.parse(spec) else {
                throw AgentManifest.ValidationError(message: "invalid region '\(spec)'")
            }
            return try CompiledRule(rule: rule, region: region, gate: Self.compile(rule.gate))
        }
    }

    private static func compile(_ gate: AgentManifest.Gate) throws -> CompiledGate {
        try CompiledGate(
            all: gate.all.map(compile),
            any: gate.any.map(compile),
            not: gate.not.map(compile),
            contains: gate.contains.map { $0.lowercased() },
            regex: gate.regex.map { try NSRegularExpression(pattern: $0) },
            lineRegex: gate.lineRegex.map { try NSRegularExpression(pattern: $0) },
        )
    }

    // MARK: - Evaluation (herdr evaluate_loaded_manifest, exact)

    /// Evaluates every rule; the highest-priority match wins, first-declared wins ties;
    /// no match → the known-agent plain-idle fallback.
    public func evaluate(_ input: AgentDetectionInput) -> AgentScreenDetection {
        var winner: CompiledRule?
        for compiled in rules {
            let text = compiled.region.resolve(input)
            guard Self.matches(compiled.gate, text: text) else { continue }
            if let current = winner, current.rule.priority >= compiled.rule.priority { continue }
            winner = compiled
        }
        guard let winner else { return .knownAgentIdleFallback }
        let state = winner.rule.state ?? .unknown
        return AgentScreenDetection(
            state: state,
            skipStateUpdate: winner.rule.skipStateUpdate,
            visibleIdle: winner.rule.visibleIdle && state == .idle,
            visibleBlocker: winner.rule.visibleBlocker && state == .blocked,
            visibleWorking: winner.rule.visibleWorking && state == .working,
            matchedRuleID: winner.rule.id,
        )
    }

    /// herdr `compiled_gate_matches`: contains (ALL, case-folded) → regex (ALL, whole region)
    /// → line_regex (ALL patterns, each with ≥1 matching line) → all (ALL) → any (≥1 unless
    /// empty) → not (ANY match vetoes).
    static func matches(_ gate: CompiledGate, text: String) -> Bool {
        let lower = text.lowercased()
        for needle in gate.contains where !lower.contains(needle) { return false }
        for pattern in gate.regex where !isMatch(pattern, text) { return false }
        if !gate.lineRegex.isEmpty {
            let lines = RegionText.rustLines(text)
            for pattern in gate.lineRegex {
                guard lines.contains(where: { isMatch(pattern, $0) }) else { return false }
            }
        }
        for nested in gate.all where !matches(nested, text: text) { return false }
        if !gate.any.isEmpty, !gate.any.contains(where: { matches($0, text: text) }) { return false }
        for nested in gate.not where matches(nested, text: text) { return false }
        return true
    }

    static func isMatch(_ regex: NSRegularExpression, _ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}

/// The bundled manifest catalog: herdr's 19 screen-manifest agents, compiled once, cached
/// for the process lifetime (herdr's cache is likewise sticky-until-explicit-reload).
public enum AgentManifestCatalog {
    /// Compiled manifests keyed by agent. A bundled manifest that fails to parse/validate is
    /// excluded (and asserts in debug — the bundled set is test-pinned to always parse).
    public static let compiled: [AgentKind: CompiledAgentManifest] = {
        var out: [AgentKind: CompiledAgentManifest] = [:]
        for (agent, toml) in BundledAgentManifests.all {
            do {
                let manifest = try AgentManifest.parse(toml: toml)
                out[agent] = try CompiledAgentManifest(manifest: manifest)
            } catch {
                assertionFailure("bundled manifest for \(agent.label) invalid: \(error)")
            }
        }
        return out
    }()

    /// The engine entry point (herdr `detect_agent_with_osc`): `nil` agent → `unknown`;
    /// a known agent without a bundled manifest (omp/mastracode) → the idle fallback.
    public static func detect(agent: AgentKind?, input: AgentDetectionInput) -> AgentScreenDetection {
        guard let agent else { return AgentScreenDetection(state: .unknown) }
        guard let compiled = compiled[agent] else { return .knownAgentIdleFallback }
        return compiled.evaluate(input)
    }

    /// herdr `should_skip_state_update` — deliberately re-evaluates WITHOUT the OSC fields
    /// (upstream constructs the input with empty title/progress on this path; a parity port
    /// keeps the two entry points' differing OSC visibility).
    public static func shouldSkipStateUpdate(agent: AgentKind?, screen: String) -> Bool {
        detect(agent: agent, input: AgentDetectionInput(screen: screen)).skipStateUpdate
    }
}
