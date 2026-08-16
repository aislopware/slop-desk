import CSlopDeskFFI
import Foundation
import SlopDeskArena

// `slopdesk completions <shell>` — the Swift face of `rust/slopdesk-cli`'s `completions`. The
// scripts and the subcommand surface they are generated from are the crate's, so the Claude-only
// invariant (E20 exclusion §4: completions never list `codex`/`opencode`) holds for all five shells
// by construction, in one place.

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
            let bytes = Array(raw.utf8)
            var code: UInt32 = 0
            let known = bytes.withUnsafeBufferPointer { name in
                slopdesk_cli_shell(name.baseAddress, name.count, &code)
            }
            guard known, let shell = Self.of(code) else { return nil }
            self = shell
        }

        /// The code this shell crosses as.
        var code: UInt32 {
            switch self {
            case .bash: SLOPDESK_SHELL_BASH
            case .zsh: SLOPDESK_SHELL_ZSH
            case .fish: SLOPDESK_SHELL_FISH
            case .elvish: SLOPDESK_SHELL_ELVISH
            case .powershell: SLOPDESK_SHELL_POWERSHELL
            }
        }

        /// The shell a code names.
        static func of(_ code: UInt32) -> Self? {
            switch code {
            case SLOPDESK_SHELL_BASH: .bash
            case SLOPDESK_SHELL_ZSH: .zsh
            case SLOPDESK_SHELL_FISH: .fish
            case SLOPDESK_SHELL_ELVISH: .elvish
            case SLOPDESK_SHELL_POWERSHELL: .powershell
            default: nil
            }
        }
    }

    // MARK: - Subcommand surface (Claude-only)

    /// The user-facing subcommand surface offered for completion. CLAUDE-ONLY: the only per-agent
    /// forms are `watch:claude` / `state:claude`; `codex`/`opencode` are deliberately absent
    /// (E20 exclusion §4 — completions/help never list non-Claude agents).
    public static let subcommands: [String] = {
        let shape = slopdesk_cli_subcommands(nil, 0, nil, 0)
        let room = shape.count
        guard room > 0 else { return [] }
        var spans = [SlopDeskByteSpan](repeating: SlopDeskByteSpan(), count: shape.count)
        var arena = Data(count: shape.arena_len)
        spans.withUnsafeMutableBufferPointer { out in
            arena.withUnsafeMutableBytes { pool in
                _ = slopdesk_cli_subcommands(out.baseAddress, out.count, pool.baseAddress, pool.count)
            }
        }
        return spans.map { span in
            ArenaText.text(arena, offset: Int(span.offset), length: Int(span.length))
        }
    }()

    // MARK: - Entry point

    /// Returns the completion script for `shell`, terminated by a trailing newline.
    public static func completionScript(for shell: Shell) -> String {
        answer { out, cap in slopdesk_cli_completion_script(shell.code, out, cap) }
    }

    /// One lent-buffer answer: ask for the size, then ask again with the room.
    static func answer(_ ask: (UnsafeMutablePointer<UInt8>?, Int) -> Int) -> String {
        let needed = ask(nil, 0)
        guard needed > 0 else { return "" }
        var bytes = [UInt8](repeating: 0, count: needed)
        let written = bytes.withUnsafeMutableBufferPointer { out in ask(out.baseAddress, out.count) }
        guard written == needed else { return "" }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }
}
