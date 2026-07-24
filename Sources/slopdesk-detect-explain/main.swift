// Differential-parity oracle for the ported herdr detect engine: mirrors
// `herdr agent explain --file PATH --agent LABEL --json` over SlopDesk's own
// `AgentManifestCatalog` so `scripts/herdr-differential.py` can diff the two engines'
// full evaluation traces (winner, per-rule matched flags, region bytes/previews) on
// arbitrary screen corpora. Dev/CI tool only — never shipped, never on a hot path.

import Foundation
import SlopDeskAgentDetect

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

var file: String?
var agentLabel: String?
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--file":
        guard !args.isEmpty else { fail("missing value for --file") }
        file = args.removeFirst()
    case "--agent":
        guard !args.isEmpty else { fail("missing value for --agent") }
        agentLabel = args.removeFirst()
    case "--json",
         "--format":
        if arg == "--format", !args.isEmpty { args.removeFirst() }
    default:
        fail("unknown option: \(arg)")
    }
}

guard let file, let agentLabel else {
    fail("usage: slopdesk-detect-explain --file PATH --agent LABEL")
}

// Strict UTF-8 read — herdr's `fs::read_to_string` errors on invalid UTF-8 too.
guard let data = FileManager.default.contents(atPath: file),
      let screen = String(data: data, encoding: .utf8)
else {
    fail("could not read \(file) as UTF-8")
}

let explain = AgentManifestCatalog.explain(agentLabel: agentLabel, screen: screen)

func json(_ value: String?) -> Any { value ?? NSNull() }

let evaluatedRules: [[String: Any]] = explain.evaluatedRules.map { rule in
    [
        "id": rule.id,
        "priority": Int(rule.priority),
        "region": rule.region,
        "state": rule.state.rawValue,
        "matched": rule.matched,
        "evidence": [
            "contains": rule.evidence.contains,
            "regex": rule.evidence.regex,
            "line_regex": rule.evidence.lineRegex,
            "all_count": rule.evidence.allCount,
            "any_count": rule.evidence.anyCount,
            "not_count": rule.evidence.notCount,
            "region_bytes": rule.evidence.regionBytes,
            "region_preview": rule.evidence.regionPreview,
        ] as [String: Any],
    ]
}

let matchedRule: Any = explain.matchedRule.map { rule -> [String: Any] in
    [
        "id": rule.id,
        "priority": Int(rule.priority),
        "region": rule.region,
        "state": rule.state.rawValue,
    ]
} ?? NSNull()

let output: [String: Any] = [
    "agent": json(explain.agent),
    "state": explain.state.rawValue,
    "manifest_source": json(explain.manifestSource),
    "manifest_version": json(explain.manifestVersion),
    "matched_rule": matchedRule,
    "visible_idle": explain.visibleIdle,
    "visible_blocker": explain.visibleBlocker,
    "visible_working": explain.visibleWorking,
    "skip_state_update": explain.skipStateUpdate,
    "skipped_update_reason": json(explain.skippedUpdateReason),
    "fallback_reason": json(explain.fallbackReason),
    "evaluated_rules": evaluatedRules,
]

let encoded = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
FileHandle.standardOutput.write(encoded)
FileHandle.standardOutput.write(Data("\n".utf8))
