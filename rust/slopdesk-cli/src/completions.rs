//! `slopdesk completions <shell>` — the completion scripts, generated from one list.
//!
//! Every renderer derives from [`SUBCOMMANDS`], so the Claude-only invariant — completions never
//! list `codex` or `opencode` — holds across all five shells by construction rather than by five
//! separate reviews.

/// A shell `slopdesk completions` can emit a script for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Shell {
    /// bash, via `complete -F`.
    Bash,
    /// zsh, via `compdef` + `_describe`.
    Zsh,
    /// fish, via one `complete -c` line per subcommand.
    Fish,
    /// elvish, via `edit:completion:arg-completer`.
    Elvish,
    /// PowerShell, via `Register-ArgumentCompleter -Native`.
    PowerShell,
}

impl Shell {
    /// Every shell, in the order `--help` lists them.
    pub const ALL: [Self; 5] = [Self::Bash, Self::Zsh, Self::Fish, Self::Elvish, Self::PowerShell];

    /// Parses a shell name as typed on the command line: case-insensitive, with `pwsh` aliasing
    /// `powershell`. `None` for an unknown shell, which the caller reports.
    #[must_use]
    pub fn parse(raw: &str) -> Option<Self> {
        match raw.to_lowercase().as_str() {
            "bash" => Some(Self::Bash),
            "zsh" => Some(Self::Zsh),
            "fish" => Some(Self::Fish),
            "elvish" => Some(Self::Elvish),
            "powershell" | "pwsh" => Some(Self::PowerShell),
            _ => None,
        }
    }

    /// The canonical name, which is what `parse` round-trips on.
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::Bash => "bash",
            Self::Zsh => "zsh",
            Self::Fish => "fish",
            Self::Elvish => "elvish",
            Self::PowerShell => "powershell",
        }
    }
}

/// The user-facing subcommand surface offered for completion.
///
/// CLAUDE-ONLY: the only per-agent forms are `watch:claude` and `state:claude`. `codex` and
/// `opencode` are deliberately absent, and a test holds them out.
pub const SUBCOMMANDS: [&str; 26] = [
    "open",
    "view",
    "edit",
    "config",
    "font",
    "keybind",
    "window",
    "windows",
    "tab",
    "tabs",
    "pane",
    "panes",
    "watch",
    "watch:claude",
    "jump",
    "learn",
    "ignore",
    "import",
    "export",
    "features",
    "completions",
    "version",
    "state:claude",
    "sidecars",
    "ipc",
    "help",
];

/// The completion script for `shell`, terminated by a trailing newline.
#[must_use]
pub fn script(shell: Shell) -> String {
    match shell {
        Shell::Bash => bash(),
        Shell::Zsh => zsh(),
        Shell::Fish => fish(),
        Shell::Elvish => elvish(),
        Shell::PowerShell => powershell(),
    }
}

/// The subcommands as one space-joined word list.
fn words() -> String {
    SUBCOMMANDS.join(" ")
}

fn bash() -> String {
    format!(
        "\
# slopdesk bash completion (install via Settings > Shell > Install CLI).
_slopdesk() {{
    local cur=\"${{COMP_WORDS[COMP_CWORD]}}\"
    local subcommands=\"{}\"
    COMPREPLY=( $(compgen -W \"${{subcommands}}\" -- \"${{cur}}\") )
}}
complete -F _slopdesk slopdesk
",
        words()
    )
}

fn zsh() -> String {
    format!(
        "\
#compdef slopdesk
# slopdesk zsh completion.
_slopdesk() {{
    local -a subcommands
    subcommands=({})
    _describe 'slopdesk subcommand' subcommands
}}
if [ \"$funcstack[1]\" = \"_slopdesk\" ]; then
    _slopdesk \"$@\"
else
    compdef _slopdesk slopdesk
fi
",
        words()
    )
}

fn fish() -> String {
    let mut out = String::from("# slopdesk fish completion.\ncomplete -c slopdesk -f\n");
    for sub in SUBCOMMANDS {
        out.push_str("complete -c slopdesk -n __fish_use_subcommand -a '");
        out.push_str(sub);
        out.push_str("'\n");
    }
    out
}

fn elvish() -> String {
    // Single-quote each candidate so a token containing `:` — `watch:claude` — is a plain string
    // rather than an elvish namespace reference.
    let quoted = SUBCOMMANDS
        .iter()
        .map(|sub| format!("'{sub}'"))
        .collect::<Vec<_>>()
        .join(" ");
    format!(
        "\
# slopdesk elvish completion.
set edit:completion:arg-completer[slopdesk] = {{|@words|
    put {quoted} | each {{|sub| edit:complex-candidate $sub }}
}}
"
    )
}

fn powershell() -> String {
    let quoted = SUBCOMMANDS
        .iter()
        .map(|sub| format!("'{sub}'"))
        .collect::<Vec<_>>()
        .join(",");
    format!(
        "\
# slopdesk PowerShell completion.
Register-ArgumentCompleter -Native -CommandName slopdesk -ScriptBlock {{
    param($wordToComplete, $commandAst, $cursorPosition)
    $subcommands = @({quoted})
    $subcommands | Where-Object {{ $_ -like \"$wordToComplete*\" }} | ForEach-Object {{
        [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    }}
}}
"
    )
}

#[cfg(test)]
mod tests {
    use super::{SUBCOMMANDS, Shell, script};

    #[test]
    fn every_shell_name_round_trips_and_pwsh_aliases_powershell() {
        for shell in Shell::ALL {
            assert_eq!(Shell::parse(shell.name()), Some(shell));
        }
        assert_eq!(Shell::parse("PWSH"), Some(Shell::PowerShell));
        assert_eq!(Shell::parse("PowerShell"), Some(Shell::PowerShell));
        assert_eq!(Shell::parse("BaSh"), Some(Shell::Bash));
        assert_eq!(Shell::parse("nushell"), None);
        assert_eq!(Shell::parse(""), None);
    }

    #[test]
    fn every_script_ends_in_exactly_one_newline_and_is_not_empty() {
        for shell in Shell::ALL {
            let text = script(shell);
            assert!(text.ends_with('\n'), "{}", shell.name());
            assert!(!text.ends_with("\n\n"), "{}", shell.name());
            assert!(text.len() > 40, "{}", shell.name());
        }
    }

    #[test]
    fn every_script_offers_every_subcommand() {
        for shell in Shell::ALL {
            let text = script(shell);
            for sub in SUBCOMMANDS {
                assert!(text.contains(sub), "{} is missing {sub}", shell.name());
            }
        }
    }

    #[test]
    fn no_script_ever_names_a_non_claude_agent() {
        for shell in Shell::ALL {
            let text = script(shell);
            for excluded in ["codex", "opencode", "watch:codex", "state:opencode"] {
                assert!(!text.contains(excluded), "{} names {excluded}", shell.name());
            }
        }
    }

    #[test]
    fn the_colon_bearing_tokens_are_quoted_where_the_shell_would_reinterpret_them() {
        // elvish would read a bare `watch:claude` as a namespace reference.
        assert!(script(Shell::Elvish).contains("'watch:claude'"));
        assert!(script(Shell::PowerShell).contains("'watch:claude'"));
        assert!(script(Shell::Fish).contains("-a 'watch:claude'"));
    }

    #[test]
    fn fish_emits_one_line_per_subcommand_plus_its_header_and_the_file_guard() {
        let text = script(Shell::Fish);
        assert_eq!(
            text.lines()
                .filter(|line| line.starts_with("complete -c"))
                .count(),
            SUBCOMMANDS.len() + 1
        );
    }

    #[test]
    fn the_subcommand_list_has_no_duplicates() {
        let mut sorted = SUBCOMMANDS;
        sorted.sort_unstable();
        let mut deduped = sorted.to_vec();
        deduped.dedup();
        assert_eq!(deduped.len(), SUBCOMMANDS.len());
    }
}
