import Foundation

// MARK: - InteractiveCommandMatcher (pure shell-handoff recognizer)

/// Recognizes whether a shell command hands control off to an INTERACTIVE program (`ssh`, `tmux attach`,
/// `docker exec -it`, `su`, …) — the signal the recipe replay machine uses to PAUSE sequential replay after
/// such a command until the inner shell returns to a prompt (see ``RecipeReplayMachine``).
///
/// Pure + headless: it parses the command STRING only (no process spawn, no `which`, no I/O). It tokenizes,
/// skips leading shell `NAME=value` env-assignments (and a bare leading `env`), resolves the program word
/// (basename, so `/usr/bin/ssh` matches `ssh`), and matches it against a CONFIGURABLE rule set:
///
/// - a flat ``interactivePrograms`` set of always-interactive programs (`ssh`, `vim`, `less`, `top`, …), and
/// - ``subcommandRules`` for programs that are interactive only with a specific subcommand and/or a tty flag
///   (`tmux attach`, `docker exec -it`, `kubectl exec -it`, …).
///
/// It is **word-boundary aware** by construction — `echo ssh` and `git ssh-add` are NOT interactive because
/// the program word is `echo` / `git`, not `ssh`. Pipelines / sequences (`git log | less`, `cd x && ssh h`)
/// are split on shell separators and reported interactive if ANY segment is.
///
/// **Wire posture:** 100% client-side — nothing here touches the wire / golden corpus.
public struct InteractiveCommandMatcher: Sendable, Equatable {
    // MARK: Rule model

    /// A program that is interactive only under a condition: it must be invoked with one of ``subcommands``
    /// (the first non-flag argument, e.g. `attach` for `tmux`, `exec` for `docker`) and, when
    /// ``requiresInteractiveTTY`` is set, with an allocate-a-tty flag (`-it` / `-i -t` / `--interactive
    /// --tty`). An empty ``subcommands`` set means "no subcommand requirement".
    public struct SubcommandRule: Sendable, Equatable {
        public var program: String
        public var subcommands: Set<String>
        public var requiresInteractiveTTY: Bool

        public init(program: String, subcommands: Set<String> = [], requiresInteractiveTTY: Bool = false) {
            self.program = program
            self.subcommands = subcommands
            self.requiresInteractiveTTY = requiresInteractiveTTY
        }
    }

    /// Programs that hand off to an interactive session regardless of arguments.
    public var interactivePrograms: Set<String>
    /// Programs that are interactive only with a specific subcommand and/or a tty flag.
    public var subcommandRules: [SubcommandRule]

    public init(
        interactivePrograms: Set<String> = Self.defaultInteractivePrograms,
        subcommandRules: [SubcommandRule] = Self.defaultSubcommandRules,
    ) {
        self.interactivePrograms = interactivePrograms
        self.subcommandRules = subcommandRules
    }

    // MARK: Defaults

    /// The shared default matcher (the otty-parity interactive program set).
    public static let `default` = Self()

    /// Always-interactive programs: remote shells, pagers, editors, full-screen TUIs, `su`.
    public static let defaultInteractivePrograms: Set<String> = [
        // remote shells / file transfer that drop into an interactive session
        "ssh", "mosh", "telnet", "sftp", "ftp",
        // identity switch (su -, su user)
        "su",
        // editors
        "vim", "nvim", "vi", "nano", "emacs", "pico", "micro",
        // pagers
        "less", "more", "most",
        // full-screen monitors
        "top", "htop", "btop",
        // manual viewer (pager-backed)
        "man",
    ]

    /// Conditional rules: a program + the subcommand(s) and/or tty flag that make it interactive.
    public static let defaultSubcommandRules: [SubcommandRule] = [
        // tmux attaches to an existing session interactively (`tmux attach` / `tmux attach-session` / `tmux a`).
        SubcommandRule(program: "tmux", subcommands: ["attach", "attach-session", "a"]),
        // docker / podman: `attach` is interactive on its own; `exec`/`run`/`start` only with -it.
        SubcommandRule(program: "docker", subcommands: ["attach"]),
        SubcommandRule(program: "docker", subcommands: ["exec", "run", "start"], requiresInteractiveTTY: true),
        SubcommandRule(program: "podman", subcommands: ["attach"]),
        SubcommandRule(program: "podman", subcommands: ["exec", "run", "start"], requiresInteractiveTTY: true),
        // kubectl exec / attach into a pod with an allocated tty.
        SubcommandRule(program: "kubectl", subcommands: ["exec", "attach"], requiresInteractiveTTY: true),
    ]

    // MARK: Public API

    /// `true` when `command` hands off to an interactive program (so the replay machine should pause after
    /// it). Pipelines / sequences are split on shell separators and reported interactive if ANY segment is.
    public func isInteractive(_ command: String) -> Bool {
        let tokens = Self.tokenize(command)
        for segment in Self.splitSegments(tokens) where segmentIsInteractive(segment) {
            return true
        }
        return false
    }

    /// Convenience over the shared ``default`` matcher.
    public static func isInteractive(_ command: String) -> Bool {
        `default`.isInteractive(command)
    }

    // MARK: One pipeline segment

    /// Whether ONE pipeline segment's leading program is interactive: skip leading env-assignments (and a
    /// bare `env`), resolve the program basename, then check the flat set + the subcommand rules.
    private func segmentIsInteractive(_ tokens: [String]) -> Bool {
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            // Leading `NAME=value` env-assignments (and a bare `env` launcher) precede the real program word.
            if Self.isEnvAssignment(token) || token == "env" {
                index += 1
                continue
            }
            break
        }
        guard index < tokens.count else { return false }

        let program = Self.basename(tokens[index])
        let args = Array(tokens[index...].dropFirst())

        if interactivePrograms.contains(program) { return true }

        for rule in subcommandRules where rule.program == program {
            if !rule.subcommands.isEmpty {
                guard let subcommand = Self.firstNonFlagArg(args), rule.subcommands.contains(subcommand) else {
                    continue
                }
            }
            if rule.requiresInteractiveTTY, !Self.hasInteractiveTTYFlags(args) { continue }
            return true
        }
        return false
    }

    // MARK: Tokenization helpers

    /// Shell separators that break a command line into independently-launched segments.
    static let separators: Set<String> = ["|", "||", "&&", ";", "&", "|&"]

    /// Split a whitespace-tokenized command into pipeline / sequence segments on standalone separator tokens.
    static func splitSegments(_ tokens: [String]) -> [[String]] {
        var segments: [[String]] = []
        var current: [String] = []
        for token in tokens {
            if separators.contains(token) {
                if !current.isEmpty {
                    segments.append(current)
                    current = []
                }
            } else {
                current.append(token)
            }
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    /// A minimal shell-ish tokenizer: split on unquoted whitespace, honoring single + double quotes (so a
    /// quoted env value `FOO='a b'` stays one token). Unquoted separator characters (`|`, `&`, `;`) are
    /// emitted as their own tokens even when glued to a word (`build;` → `build` `;`) so a sequence without
    /// surrounding spaces still splits into segments. Quote characters are stripped; escaping is not modeled
    /// (good enough for recognizing the leading program word — this is a matcher, not a shell).
    static func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasToken = false
        var inSingle = false
        var inDouble = false
        func flushCurrent() {
            if hasToken {
                tokens.append(current)
                current = ""
                hasToken = false
            }
        }
        for ch in command {
            if inSingle {
                if ch == "'" { inSingle = false } else { current.append(ch) }
            } else if inDouble {
                if ch == "\"" { inDouble = false } else { current.append(ch) }
            } else if ch == "'" {
                inSingle = true
                hasToken = true
            } else if ch == "\"" {
                inDouble = true
                hasToken = true
            } else if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" {
                flushCurrent()
            } else if ch == "|" || ch == "&" || ch == ";" {
                // A separator char ends the current word and stands alone (multi-char operators such as
                // `&&` / `||` decompose into single-char separator tokens — all are in ``separators``).
                flushCurrent()
                tokens.append(String(ch))
            } else {
                current.append(ch)
                hasToken = true
            }
        }
        flushCurrent()
        return tokens
    }

    /// The program basename: the part after the last `/` (so `/usr/bin/ssh` resolves to `ssh`).
    static func basename(_ token: String) -> String {
        guard let slash = token.lastIndex(of: "/") else { return token }
        return String(token[token.index(after: slash)...])
    }

    /// Whether `token` is a leading shell env-assignment `NAME=value`, where `NAME` is an ASCII shell
    /// identifier (`[A-Za-z_][A-Za-z0-9_]*`). `--opt=x` and `=x` are NOT assignments.
    static func isEnvAssignment(_ token: String) -> Bool {
        guard let equals = token.firstIndex(of: "="), equals != token.startIndex else { return false }
        let name = token[token.startIndex..<equals]
        var first = true
        for ch in name {
            let okFirst = ch.isASCII && (ch.isLetter || ch == "_")
            let okRest = ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_")
            if first {
                guard okFirst else { return false }
                first = false
            } else {
                guard okRest else { return false }
            }
        }
        return true
    }

    /// The first argument that is not a `-`/`--` flag — the subcommand word (`attach`, `exec`, …).
    static func firstNonFlagArg(_ args: [String]) -> String? {
        args.first { !$0.hasPrefix("-") }
    }

    /// Whether the args carry BOTH an interactive (`-i` / `--interactive`) and a tty (`-t` / `--tty`) flag —
    /// the `docker exec -it` / `-i -t` allocate-a-terminal pattern. Combined short flags (`-it`, `-ti`,
    /// `-itd`) are decomposed character-by-character.
    static func hasInteractiveTTYFlags(_ args: [String]) -> Bool {
        var hasInteractive = false
        var hasTTY = false
        for arg in args where arg.hasPrefix("-") {
            if arg.hasPrefix("--") {
                if arg == "--interactive" { hasInteractive = true }
                if arg == "--tty" { hasTTY = true }
            } else {
                for ch in arg.dropFirst() {
                    if ch == "i" { hasInteractive = true }
                    if ch == "t" { hasTTY = true }
                }
            }
        }
        return hasInteractive && hasTTY
    }
}
