import Foundation

// `slopdesk completions <shell>` — prints a shell completion script. PURE string generation, no
// socket (a local op). Source-of-truth is the single `subcommands` list; every shell renderer
// derives from it, so the Claude-only invariant (E20 exclusion §4: completions never list
// `codex`/`opencode`) holds across all shells by construction.

public enum CLICompletions {
    // MARK: - Shell

    /// The shells `slopdesk completions` can emit. `init?(argument:)` parses the CLI token.
    public enum Shell: String, CaseIterable, Sendable {
        case bash
        case zsh
        case fish
        case elvish
        case powershell

        /// Parses a shell name as typed on the command line (case-insensitive; `pwsh` aliases
        /// `powershell`). Returns `nil` for an unknown shell (the caller reports the error).
        public init?(argument raw: String) {
            switch raw.lowercased() {
            case "bash": self = .bash
            case "zsh": self = .zsh
            case "fish": self = .fish
            case "elvish": self = .elvish
            case "powershell",
                 "pwsh": self = .powershell
            default: return nil
            }
        }
    }

    // MARK: - Subcommand surface (Claude-only)

    /// The user-facing subcommand surface offered for completion. CLAUDE-ONLY: the only per-agent
    /// forms are `watch:claude` / `state:claude`; `codex`/`opencode` are deliberately absent
    /// (E20 exclusion §4 — completions/help never list non-Claude agents).
    public static let subcommands: [String] = [
        "open", "view", "edit",
        "config", "font", "theme", "keybind",
        "window", "windows", "tab", "tabs", "pane", "panes",
        "watch", "watch:claude",
        "jump", "learn", "ignore",
        "import", "export", "features",
        "completions", "version",
        "state:claude", "ipc", "help",
    ]

    // MARK: - Entry point

    /// Returns the completion script for `shell`, terminated by a trailing newline.
    public static func completionScript(for shell: Shell) -> String {
        switch shell {
        case .bash: bashScript()
        case .zsh: zshScript()
        case .fish: fishScript()
        case .elvish: elvishScript()
        case .powershell: powershellScript()
        }
    }

    // MARK: - Per-shell renderers

    private static func bashScript() -> String {
        let words = subcommands.joined(separator: " ")
        return """
        # slopdesk bash completion (install via Settings > Shell > Install CLI).
        _slopdesk() {
            local cur="${COMP_WORDS[COMP_CWORD]}"
            local subcommands="\(words)"
            COMPREPLY=( $(compgen -W "${subcommands}" -- "${cur}") )
        }
        complete -F _slopdesk slopdesk
        """ + "\n"
    }

    private static func zshScript() -> String {
        let words = subcommands.joined(separator: " ")
        return """
        #compdef slopdesk
        # slopdesk zsh completion.
        _slopdesk() {
            local -a subcommands
            subcommands=(\(words))
            _describe 'slopdesk subcommand' subcommands
        }
        if [ "$funcstack[1]" = "_slopdesk" ]; then
            _slopdesk "$@"
        else
            compdef _slopdesk slopdesk
        fi
        """ + "\n"
    }

    private static func fishScript() -> String {
        var lines = [
            "# slopdesk fish completion.",
            "complete -c slopdesk -f",
        ]
        for sub in subcommands {
            lines.append("complete -c slopdesk -n __fish_use_subcommand -a '\(sub)'")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func elvishScript() -> String {
        // Single-quote each candidate so tokens containing `:` (e.g. `watch:claude`) are plain
        // strings, not elvish namespace references.
        let quoted = subcommands.map { "'\($0)'" }.joined(separator: " ")
        return """
        # slopdesk elvish completion.
        set edit:completion:arg-completer[slopdesk] = {|@words|
            put \(quoted) | each {|sub| edit:complex-candidate $sub }
        }
        """ + "\n"
    }

    private static func powershellScript() -> String {
        let quoted = subcommands.map { "'\($0)'" }.joined(separator: ",")
        return """
        # slopdesk PowerShell completion.
        Register-ArgumentCompleter -Native -CommandName slopdesk -ScriptBlock {
            param($wordToComplete, $commandAst, $cursorPosition)
            $subcommands = @(\(quoted))
            $subcommands | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
                [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
            }
        }
        """ + "\n"
    }
}
