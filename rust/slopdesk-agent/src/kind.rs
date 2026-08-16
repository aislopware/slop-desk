//! Which coding agent is running — identity from a process name, nothing else.
//!
//! A 1:1 port of herdr's `Agent` / `parse_agent_label` / `lookup_agent` /
//! `is_generic_runtime_or_shell` / `path_basename`, by way of `AgentKind.swift`. The alias table is
//! upstream's, verbatim: a name this crate invented would identify an agent screend's manifests
//! have never heard of.

/// A coding agent the detection stack can recognise.
///
/// [`Omp`](Self::Omp) and [`Mastracode`](Self::Mastracode) are hook-authority-only upstream and
/// ship no screen manifest — see [`AgentKind::SCREEN_MANIFEST_AGENTS`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum AgentKind {
    /// The pi coding agent.
    Pi,
    /// Claude Code.
    Claude,
    /// The Codex CLI.
    Codex,
    /// The Gemini CLI.
    Gemini,
    /// Cursor's terminal agent.
    Cursor,
    /// The Devin CLI.
    Devin,
    /// Antigravity (`agy`).
    Antigravity,
    /// Cline.
    Cline,
    /// omp — hook-authority only, no screen manifest.
    Omp,
    /// mastracode — hook-authority only, no screen manifest.
    Mastracode,
    /// opencode.
    OpenCode,
    /// The Copilot CLI.
    GithubCopilot,
    /// Kimi.
    Kimi,
    /// Kiro.
    Kiro,
    /// The droid CLI.
    Droid,
    /// Amp.
    Amp,
    /// Grok.
    Grok,
    /// Hermes.
    Hermes,
    /// Kilo.
    Kilo,
    /// The Qoder CLI.
    QoderCli,
    /// maki.
    Maki,
}

impl AgentKind {
    /// Every agent, in herdr's declaration order.
    pub const ALL: [Self; 21] = [
        Self::Pi,
        Self::Claude,
        Self::Codex,
        Self::Gemini,
        Self::Cursor,
        Self::Devin,
        Self::Antigravity,
        Self::Cline,
        Self::Omp,
        Self::Mastracode,
        Self::OpenCode,
        Self::GithubCopilot,
        Self::Kimi,
        Self::Kiro,
        Self::Droid,
        Self::Amp,
        Self::Grok,
        Self::Hermes,
        Self::Kilo,
        Self::QoderCli,
        Self::Maki,
    ];

    /// The 19 agents with a bundled screen manifest (herdr `SCREEN_MANIFEST_AGENTS`).
    ///
    /// Spelled out rather than derived, because a `const` cannot filter an array — and the test
    /// `the_manifest_set_is_everything_but_the_two_hook_only_agents` is the ratchet that keeps the
    /// two in step.
    pub const SCREEN_MANIFEST_AGENTS: [Self; 19] = [
        Self::Pi,
        Self::Claude,
        Self::Codex,
        Self::Gemini,
        Self::Cursor,
        Self::Devin,
        Self::Antigravity,
        Self::Cline,
        Self::OpenCode,
        Self::GithubCopilot,
        Self::Kimi,
        Self::Kiro,
        Self::Droid,
        Self::Amp,
        Self::Grok,
        Self::Hermes,
        Self::Kilo,
        Self::QoderCli,
        Self::Maki,
    ];

    /// The canonical label (herdr `agent_label`) — the Swift enum's raw value.
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::Pi => "pi",
            Self::Claude => "claude",
            Self::Codex => "codex",
            Self::Gemini => "gemini",
            Self::Cursor => "cursor",
            Self::Devin => "devin",
            Self::Antigravity => "agy",
            Self::Cline => "cline",
            Self::Omp => "omp",
            Self::Mastracode => "mastracode",
            Self::OpenCode => "opencode",
            Self::GithubCopilot => "copilot",
            Self::Kimi => "kimi",
            Self::Kiro => "kiro",
            Self::Droid => "droid",
            Self::Amp => "amp",
            Self::Grok => "grok",
            Self::Hermes => "hermes",
            Self::Kilo => "kilo",
            Self::QoderCli => "qodercli",
            Self::Maki => "maki",
        }
    }

    /// Identifies an agent from a process or executable name.
    ///
    /// Trims, lowercases, strips one known executable suffix, then matches the alias table. `None`
    /// for shells and unknown programs — which is the answer that matters, since a false positive
    /// here paints an agent dot on a pane running `make`.
    #[must_use]
    pub fn identify(process_name: &str) -> Option<Self> {
        Self::lookup(&Self::normalized_lookup_name(process_name))
    }

    /// herdr `normalized_agent_lookup_name`: trim + lowercase + strip ONE known suffix.
    ///
    /// The trim is HORIZONTAL whitespace only, matching Swift's `CharacterSet.whitespaces` — a
    /// trailing newline is not padding on a process name, it is a name that came from somewhere it
    /// should not have.
    #[must_use]
    pub fn normalized_lookup_name(name: &str) -> String {
        let mut out = name.trim_matches(is_horizontal_whitespace).to_lowercase();
        for suffix in [".exe", ".cmd", ".bat", ".ps1", ".js"] {
            if out.ends_with(suffix) {
                out.truncate(out.len().saturating_sub(suffix.len()));
                break;
            }
        }
        out
    }

    /// herdr `lookup_agent` — the exact alias table, on an already-normalized name.
    fn lookup(name: &str) -> Option<Self> {
        match name {
            "pi" => Some(Self::Pi),
            "claude" | "claude-code" => Some(Self::Claude),
            "codex" => Some(Self::Codex),
            "gemini" => Some(Self::Gemini),
            "cursor" | "cursor-agent" => Some(Self::Cursor),
            "devin" | "devin-cli" | "devin cli" => Some(Self::Devin),
            "agy" | "antigravity" | "antigravity-cli" => Some(Self::Antigravity),
            "cline" => Some(Self::Cline),
            "omp" => Some(Self::Omp),
            "mastracode" | "mastra-code" | "mastra code" => Some(Self::Mastracode),
            "opencode" | "open-code" => Some(Self::OpenCode),
            "copilot" | "github-copilot" | "ghcs" => Some(Self::GithubCopilot),
            "kimi" | "kimi-code" | "kimi code" => Some(Self::Kimi),
            "kiro" | "kiro-cli" => Some(Self::Kiro),
            "droid" => Some(Self::Droid),
            "amp" | "amp-local" => Some(Self::Amp),
            "grok" | "grok-build" => Some(Self::Grok),
            "hermes" | "hermes-agent" => Some(Self::Hermes),
            "kilo" | "kilo-code" | "kilo code" => Some(Self::Kilo),
            "qodercli" | "qoderclicn" | "qoder" | "qodercn" => Some(Self::QoderCli),
            "maki" => Some(Self::Maki),
            _ => None,
        }
    }

    /// herdr `is_generic_runtime_or_shell`: a basename that HOSTS other programs and must never
    /// itself count as an agent.
    #[must_use]
    pub fn is_generic_runtime_or_shell(name: &str) -> bool {
        matches!(
            Self::normalized_lookup_name(path_basename(name)).as_str(),
            "sh" | "bash"
                | "zsh"
                | "fish"
                | "tmux"
                | "node"
                | "bun"
                | "python"
                | "python3"
                | "cmd"
                | "powershell"
                | "pwsh"
        )
    }
}

/// herdr `path_basename`: the last non-empty component, `/` or `\` separated.
///
/// Falls back to the whole input when there is no component at all (`""`, `"///"`), so this is
/// total on every string — including the ones that are not paths.
#[must_use]
pub fn path_basename(path: &str) -> &str {
    path.split(['/', '\\'])
        .rfind(|component| !component.is_empty())
        .unwrap_or(path)
}

/// Swift's `CharacterSet.whitespaces`: the Unicode space separators plus a tab, and NOT a newline.
const fn is_horizontal_whitespace(character: char) -> bool {
    character == '\u{9}'
        || (character.is_whitespace() && !matches!(character, '\n' | '\r' | '\u{b}' | '\u{c}' | '\u{85}'))
}

#[cfg(test)]
mod tests {
    use super::{AgentKind, path_basename};

    #[test]
    fn the_manifest_set_is_everything_but_the_two_hook_only_agents() {
        let derived: Vec<AgentKind> = AgentKind::ALL
            .into_iter()
            .filter(|agent| !matches!(agent, AgentKind::Omp | AgentKind::Mastracode))
            .collect();
        assert_eq!(derived, AgentKind::SCREEN_MANIFEST_AGENTS.to_vec());
    }

    #[test]
    fn every_label_round_trips_through_identification() {
        for agent in AgentKind::ALL {
            assert_eq!(
                AgentKind::identify(agent.label()),
                Some(agent),
                "{}",
                agent.label()
            );
        }
    }

    #[test]
    fn one_executable_suffix_is_stripped_and_only_one() {
        assert_eq!(AgentKind::identify("claude.exe"), Some(AgentKind::Claude));
        assert_eq!(AgentKind::identify("  CLAUDE.CMD  "), Some(AgentKind::Claude));
        assert_eq!(AgentKind::identify("cursor-agent.js"), Some(AgentKind::Cursor));
        // Two suffixes: only the outer one comes off, so what is left is not an agent.
        assert_eq!(AgentKind::identify("claude.js.exe"), None);
    }

    #[test]
    fn a_shell_or_runtime_is_never_an_agent() {
        for hosting in [
            "sh",
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
            "pwsh",
        ] {
            assert!(AgentKind::is_generic_runtime_or_shell(hosting), "{hosting}");
            assert_eq!(AgentKind::identify(hosting), None, "{hosting}");
        }
        assert!(AgentKind::is_generic_runtime_or_shell("/usr/local/bin/node"));
        assert!(!AgentKind::is_generic_runtime_or_shell("claude"));
    }

    #[test]
    fn a_basename_is_the_last_component_of_either_separator() {
        assert_eq!(path_basename("/usr/local/bin/claude"), "claude");
        assert_eq!(path_basename(r"C:\Program Files\claude.exe"), "claude.exe");
        assert_eq!(path_basename("claude"), "claude");
        assert_eq!(path_basename("///"), "///");
        assert_eq!(path_basename(""), "");
    }

    #[test]
    fn a_near_miss_names_nobody() {
        for stranger in ["", "claudefoo", "make", "vim", "cla", "claude-"] {
            assert_eq!(AgentKind::identify(stranger), None, "{stranger:?}");
        }
    }
}
