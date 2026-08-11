import Foundation

/// The parsed + validated form of one agent's detection manifest (herdr `AgentManifest`,
/// `ManifestRule`, `ManifestGate` — ported 1:1, including every validation limit). Parsing is
/// strict (`deny_unknown_fields` at every level): any unknown key, bad type, invalid region,
/// invalid regex, or exceeded limit rejects the WHOLE manifest — never a single rule.
public struct AgentManifest: Sendable, Equatable {
    public var id: String
    public var version: String?
    public var minEngineVersion: UInt32?
    public var aliases: [String]
    public var rules: [Rule]

    public struct Rule: Sendable, Equatable {
        public var id: String
        public var state: AgentScreenState?
        public var priority: Int32
        public var region: String
        public var visibleIdle: Bool
        public var visibleBlocker: Bool
        public var visibleWorking: Bool
        public var skipStateUpdate: Bool
        public var gate: Gate
    }

    /// One nested gate. A rule's own matcher fields form its implicit top-level gate.
    public struct Gate: Sendable, Equatable {
        public var all: [Self]
        public var any: [Self]
        public var not: [Self]
        public var contains: [String]
        public var regex: [String]
        public var lineRegex: [String]

        /// ⚠️ OURS, not herdr's (2026-08-11). A nested gate may name its OWN region, and then it
        /// (and everything under it) is evaluated against THAT text instead of the rule's.
        ///
        /// Upstream evaluates every gate against one region, which makes "…and no modal dialog is
        /// on screen" INEXPRESSIBLE: a dialog's footer sits below the last horizontal rule, and the
        /// prompt box's body sits above it, so the rule that must not fire and the evidence that
        /// would stop it are in different regions by construction. `live_prompt_box` therefore
        /// carried five `not` needles that could never match anything, and a dialog whose footer had
        /// been erased mid-repaint read as an idle prompt box — the 2026-08-11 flap.
        ///
        /// `nil` = inherit (herdr's behaviour, and what every ported rule still does).
        public var region: String?

        public init(
            all: [Self] = [],
            any: [Self] = [],
            not: [Self] = [],
            contains: [String] = [],
            regex: [String] = [],
            lineRegex: [String] = [],
            region: String? = nil,
        ) {
            self.all = all
            self.any = any
            self.not = not
            self.contains = contains
            self.regex = regex
            self.lineRegex = lineRegex
            self.region = region
        }
    }

    // MARK: Limits (herdr constants, exact)

    public static let maxRulesPerManifest = 128
    public static let maxGateDepth = 8
    public static let maxTotalGates = 512
    public static let maxMatchersPerGate = 32
    public static let maxTotalMatchers = 1024
    public static let maxMatcherChars = 512
    /// The running engine's own manifest-format version (herdr `MANIFEST_ENGINE_VERSION`).
    public static let engineVersion: UInt32 = 3
    /// `top_non_empty_lines` requires a manifest declaring at least this engine version.
    public static let topNonEmptyLinesEngineVersion: UInt32 = 3

    /// A gate naming its OWN region (``Gate/region``) is engine 3 as well — engine 2 silently
    /// ignores the key, and silently ignoring a VETO is how a rule fires on a screen it was
    /// written to skip. A manifest that uses it must say so.
    public static let gateRegionEngineVersion: UInt32 = 3

    // MARK: Parse

    public struct ValidationError: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// Parses + validates a manifest TOML document. Throws on ANY schema/limit violation.
    public static func parse(toml text: String) throws -> Self {
        let root = try TOMLSubsetParser.parse(text)
        let manifest = try decode(root: root)
        try manifest.validate()
        return manifest
    }

    private static func decode(root: [String: TOMLValue]) throws -> Self {
        let knownTopLevel: Set = ["id", "version", "min_engine_version", "updated_at", "aliases", "rules"]
        if let unknown = root.keys.first(where: { !knownTopLevel.contains($0) }) {
            throw ValidationError(message: "unknown field '\(unknown)'")
        }
        guard let id = root["id"]?.stringValue else {
            throw ValidationError(message: "missing manifest id")
        }
        let version = try root["version"].map { value -> String in
            guard let s = value.stringValue, isValidVersion(s) else {
                throw ValidationError(message: "invalid version")
            }
            return s
        }
        let minEngine = try root["min_engine_version"].map { value -> UInt32 in
            guard let n = value.integerValue, n >= 0, n <= Int64(UInt32.max) else {
                throw ValidationError(message: "invalid min_engine_version")
            }
            return UInt32(n)
        }
        if let updated = root["updated_at"], updated.stringValue == nil {
            throw ValidationError(message: "invalid updated_at")
        }
        let aliases = try root["aliases"].map { value -> [String] in
            guard let items = value.arrayValue else { throw ValidationError(message: "invalid aliases") }
            return try items.map {
                guard let s = $0.stringValue else { throw ValidationError(message: "invalid aliases") }
                return s
            }
        } ?? []
        let rules = try (root["rules"]?.arrayValue ?? []).map { value -> Rule in
            guard let table = value.tableValue else { throw ValidationError(message: "invalid rule") }
            return try decodeRule(table)
        }
        return Self(id: id, version: version, minEngineVersion: minEngine, aliases: aliases, rules: rules)
    }

    private static func decodeRule(_ table: [String: TOMLValue]) throws -> Rule {
        let known: Set = [
            "id", "state", "priority", "region",
            "visible_idle", "visible_blocker", "visible_working", "skip_state_update",
            "all", "any", "not", "contains", "regex", "line_regex",
        ]
        if let unknown = table.keys.first(where: { !known.contains($0) }) {
            throw ValidationError(message: "unknown rule field '\(unknown)'")
        }
        guard let id = table["id"]?.stringValue else {
            throw ValidationError(message: "rule missing id")
        }
        let state = try table["state"].map { value -> AgentScreenState in
            guard let s = value.stringValue, let parsed = AgentScreenState(rawValue: s) else {
                throw ValidationError(message: "invalid rule state")
            }
            return parsed
        }
        let priority = try table["priority"].map { value -> Int32 in
            guard let n = value.integerValue, n >= Int64(Int32.min), n <= Int64(Int32.max) else {
                throw ValidationError(message: "invalid priority")
            }
            return Int32(n)
        } ?? 0
        let region = try table["region"].map { value -> String in
            guard let s = value.stringValue else { throw ValidationError(message: "invalid region") }
            return s
        } ?? "whole_recent"
        return try Rule(
            id: id,
            state: state,
            priority: priority,
            region: region,
            visibleIdle: decodeBool(table["visible_idle"]),
            visibleBlocker: decodeBool(table["visible_blocker"]),
            visibleWorking: decodeBool(table["visible_working"]),
            skipStateUpdate: decodeBool(table["skip_state_update"]),
            // ⚠️ `allowRegion: false`: the rule's `region` key belongs to the RULE. Reading it
            // again here would stamp the root gate with an "override" identical to what it already
            // inherits — harmless in outcome, but it re-resolves the region text on every gate
            // evaluation and quietly makes every rule look like it uses the cross-region feature.
            gate: decodeGate(table, allowRegion: false),
        )
    }

    private static func decodeBool(_ value: TOMLValue?) throws -> Bool {
        guard let value else { return false }
        guard let b = value.booleanValue else { throw ValidationError(message: "expected boolean") }
        return b
    }

    /// The matcher-field keys are identical at the rule level and every nested gate level; only
    /// `region` differs in meaning, so the rule caller opts out of it (`allowRegion: false`).
    private static func decodeGate(_ table: [String: TOMLValue], allowRegion: Bool = true) throws -> Gate {
        try Gate(
            all: decodeGateList(table["all"]),
            any: decodeGateList(table["any"]),
            not: decodeGateList(table["not"]),
            contains: decodeStringList(table["contains"]),
            regex: decodeStringList(table["regex"]),
            lineRegex: decodeStringList(table["line_regex"]),
            region: allowRegion ? decodeGateRegion(table["region"]) : nil,
        )
    }

    private static func decodeGateRegion(_ value: TOMLValue?) throws -> String? {
        guard let value else { return nil }
        guard let spec = value.stringValue else { throw ValidationError(message: "invalid gate region") }
        return spec
    }

    private static func decodeGateList(_ value: TOMLValue?) throws -> [Gate] {
        guard let value else { return [] }
        guard let items = value.arrayValue else { throw ValidationError(message: "expected gate array") }
        return try items.map { item -> Gate in
            guard let table = item.tableValue else { throw ValidationError(message: "expected gate table") }
            let known: Set = ["all", "any", "not", "contains", "regex", "line_regex", "region"]
            if let unknown = table.keys.first(where: { !known.contains($0) }) {
                throw ValidationError(message: "unknown gate field '\(unknown)'")
            }
            return try decodeGate(table)
        }
    }

    private static func decodeStringList(_ value: TOMLValue?) throws -> [String] {
        guard let value else { return [] }
        guard let items = value.arrayValue else { throw ValidationError(message: "expected string array") }
        return try items.map { item -> String in
            guard let s = item.stringValue else { throw ValidationError(message: "expected string") }
            return s
        }
    }

    /// A dotted-numeric version: every `.`-separated segment non-empty, all ASCII digits,
    /// parseable as UInt64 (herdr `ManifestVersion::parse`).
    static func isValidVersion(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        for segment in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
            guard !segment.isEmpty, segment.allSatisfy(\.isNumber), UInt64(segment) != nil else {
                return false
            }
        }
        return true
    }

    // MARK: Validation (herdr validate_manifest, exact)

    func validate() throws {
        guard !rules.isEmpty else { throw ValidationError(message: "manifest has no rules") }
        guard rules.count <= Self.maxRulesPerManifest else {
            throw ValidationError(message: "too many rules")
        }
        var totalGates = 0
        var totalMatchers = 0
        for rule in rules {
            guard !rule.id.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ValidationError(message: "rule with empty id")
            }
            if rule.skipStateUpdate {
                guard rule.state == .unknown else {
                    throw ValidationError(message: "skip_state_update rule must declare state = \"unknown\"")
                }
                guard !rule.visibleIdle, !rule.visibleBlocker, !rule.visibleWorking else {
                    throw ValidationError(message: "skip_state_update rule must not set visible flags")
                }
            }
            let regionSpec = rule.region.trimmingCharacters(in: .whitespaces)
            guard ManifestRegion.parse(regionSpec) != nil else {
                throw ValidationError(message: "invalid region '\(regionSpec)'")
            }
            if regionSpec.hasPrefix("top_non_empty_lines("),
               let declared = minEngineVersion, declared < Self.topNonEmptyLinesEngineVersion
            {
                throw ValidationError(message: "top_non_empty_lines requires min_engine_version >= 3")
            }
            guard Self.gateHasPositiveMatcher(rule.gate) else {
                throw ValidationError(message: "rule '\(rule.id)' must contain a positive matcher")
            }
            try Self.validateGate(
                rule.gate,
                depth: 0,
                minEngine: minEngineVersion,
                totalGates: &totalGates,
                totalMatchers: &totalMatchers,
            )
        }
    }

    static func gateHasPositiveMatcher(_ gate: Gate) -> Bool {
        !gate.contains.isEmpty || !gate.regex.isEmpty || !gate.lineRegex.isEmpty
            || !gate.all.isEmpty || !gate.any.isEmpty
    }

    static func gateHasAnyMatcher(_ gate: Gate) -> Bool {
        gateHasPositiveMatcher(gate) || !gate.not.isEmpty
    }

    /// A gate that names its OWN region must name a real one — same strictness as a rule's, so a
    /// typo rejects the whole manifest rather than silently inheriting and quietly under-matching —
    /// and the manifest must declare an engine that HONOURS the key.
    private static func validateGateRegion(_ gate: Gate, minEngine: UInt32?) throws {
        guard let spec = gate.region?.trimmingCharacters(in: .whitespaces) else { return }
        guard ManifestRegion.parse(spec) != nil else {
            throw ValidationError(message: "invalid gate region '\(spec)'")
        }
        if let minEngine, minEngine < gateRegionEngineVersion {
            throw ValidationError(message: "gate region requires min_engine_version >= 3")
        }
        if spec.hasPrefix("top_non_empty_lines("),
           let minEngine, minEngine < topNonEmptyLinesEngineVersion
        {
            throw ValidationError(message: "top_non_empty_lines requires min_engine_version >= 3")
        }
    }

    private static func validateGate(
        _ gate: Gate,
        depth: Int,
        minEngine: UInt32?,
        totalGates: inout Int,
        totalMatchers: inout Int,
    ) throws {
        guard depth <= maxGateDepth else { throw ValidationError(message: "gate nesting too deep") }
        try validateGateRegion(gate, minEngine: minEngine)
        totalGates += 1
        guard totalGates <= maxTotalGates else { throw ValidationError(message: "too many gates") }
        let matcherCount = gate.contains.count + gate.regex.count + gate.lineRegex.count
        guard matcherCount <= maxMatchersPerGate else {
            throw ValidationError(message: "too many matchers in one gate")
        }
        totalMatchers += matcherCount
        guard totalMatchers <= maxTotalMatchers else { throw ValidationError(message: "too many matchers") }
        for matcher in gate.contains + gate.regex + gate.lineRegex {
            guard matcher.count <= maxMatcherChars else {
                throw ValidationError(message: "matcher too long")
            }
        }
        for pattern in gate.regex + gate.lineRegex {
            guard (try? NSRegularExpression(pattern: pattern)) != nil else {
                throw ValidationError(message: "invalid regex '\(pattern)'")
            }
        }
        for nested in gate.all + gate.any {
            guard gateHasPositiveMatcher(nested) else {
                throw ValidationError(message: "nested gate must contain a positive matcher")
            }
            try validateGate(
                nested,
                depth: depth + 1,
                minEngine: minEngine,
                totalGates: &totalGates,
                totalMatchers: &totalMatchers,
            )
        }
        for nested in gate.not {
            guard gateHasAnyMatcher(nested) else {
                throw ValidationError(message: "not-gate must contain a matcher")
            }
            try validateNotGate(
                nested,
                depth: depth + 1,
                minEngine: minEngine,
                totalGates: &totalGates,
                totalMatchers: &totalMatchers,
            )
        }
    }

    /// `not`-gates recurse separately: they may be composed purely of nested `not`s (no
    /// positive-matcher requirement), but can never be totally empty.
    private static func validateNotGate(
        _ gate: Gate,
        depth: Int,
        minEngine: UInt32?,
        totalGates: inout Int,
        totalMatchers: inout Int,
    ) throws {
        guard depth <= maxGateDepth else { throw ValidationError(message: "gate nesting too deep") }
        try validateGateRegion(gate, minEngine: minEngine)
        totalGates += 1
        guard totalGates <= maxTotalGates else { throw ValidationError(message: "too many gates") }
        let matcherCount = gate.contains.count + gate.regex.count + gate.lineRegex.count
        guard matcherCount <= maxMatchersPerGate else {
            throw ValidationError(message: "too many matchers in one gate")
        }
        totalMatchers += matcherCount
        guard totalMatchers <= maxTotalMatchers else { throw ValidationError(message: "too many matchers") }
        for matcher in gate.contains + gate.regex + gate.lineRegex {
            guard matcher.count <= maxMatcherChars else {
                throw ValidationError(message: "matcher too long")
            }
        }
        for pattern in gate.regex + gate.lineRegex {
            guard (try? NSRegularExpression(pattern: pattern)) != nil else {
                throw ValidationError(message: "invalid regex '\(pattern)'")
            }
        }
        for nested in gate.all + gate.any {
            guard gateHasPositiveMatcher(nested) else {
                throw ValidationError(message: "nested gate must contain a positive matcher")
            }
            try validateGate(
                nested,
                depth: depth + 1,
                minEngine: minEngine,
                totalGates: &totalGates,
                totalMatchers: &totalMatchers,
            )
        }
        for nested in gate.not {
            guard gateHasAnyMatcher(nested) else {
                throw ValidationError(message: "not-gate must contain a matcher")
            }
            try validateNotGate(
                nested,
                depth: depth + 1,
                minEngine: minEngine,
                totalGates: &totalGates,
                totalMatchers: &totalMatchers,
            )
        }
    }
}
