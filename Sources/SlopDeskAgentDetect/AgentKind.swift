import Foundation

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

    // MARK: Identification (herdr parse_agent_label / lookup_agent)

    /// Identifies an agent from a process/executable name. Trims, lowercases, strips one
    /// known suffix, then matches the alias table. `nil` for shells / unknown programs.
    public static func identify(processName: String) -> Self? {
        lookup(normalizedLookupName(processName))
    }

    /// herdr `normalized_agent_lookup_name`: trim + lowercase + strip ONE of the known
    /// executable suffixes.
    public static func normalizedLookupName(_ name: String) -> String {
        var out = name.trimmingCharacters(in: .whitespaces).lowercased()
        for suffix in [".exe", ".cmd", ".bat", ".ps1", ".js"] where out.hasSuffix(suffix) {
            out.removeLast(suffix.count)
            break
        }
        return out
    }

    /// herdr `lookup_agent` — the exact alias table.
    static func lookup(_ name: String) -> Self? {
        switch name {
        case "pi": .pi
        case "claude",
             "claude-code": .claude
        case "codex": .codex
        case "gemini": .gemini
        case "cursor",
             "cursor-agent": .cursor
        case "devin",
             "devin-cli",
             "devin cli": .devin
        case "agy",
             "antigravity",
             "antigravity-cli": .antigravity
        case "cline": .cline
        case "omp": .omp
        case "mastracode",
             "mastra-code",
             "mastra code": .mastracode
        case "opencode",
             "open-code": .openCode
        case "copilot",
             "github-copilot",
             "ghcs": .githubCopilot
        case "kimi",
             "kimi-code",
             "kimi code": .kimi
        case "kiro",
             "kiro-cli": .kiro
        case "droid": .droid
        case "amp",
             "amp-local": .amp
        case "grok",
             "grok-build": .grok
        case "hermes",
             "hermes-agent": .hermes
        case "kilo",
             "kilo-code",
             "kilo code": .kilo
        case "qodercli",
             "qoderclicn",
             "qoder",
             "qodercn": .qodercli
        case "maki": .maki
        default: nil
        }
    }

    /// herdr `is_generic_runtime_or_shell`: a basename that hosts other programs and must
    /// never itself count as an agent.
    public static func isGenericRuntimeOrShell(_ name: String) -> Bool {
        let base = normalizedLookupName(pathBasename(name))
        switch base {
        case "sh",
             "bash",
             "zsh",
             "fish",
             "tmux",
             "node",
             "bun",
             "python",
             "python3",
             "cmd",
             "powershell",
             "pwsh":
            return true
        default:
            return false
        }
    }

    /// herdr `path_basename`: last non-empty component, `/` or `\` separated.
    public static func pathBasename(_ path: String) -> String {
        let component = path
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last
            .map(String.init)
        return component ?? path
    }
}
