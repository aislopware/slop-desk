import Foundation

// MARK: - LaunchPreset (a named "launch configuration" — Warp/Zellij parity)

/// A named **launch configuration** (docs/42 W14 #9, Warp "launch configurations" / Zellij `tab_template`
/// parity): a title plus the command to run, an optional working directory, and an optional split layout.
/// Applying one opens a terminal pane (or a tab of split panes) and runs the command(s) in it — the
/// "launch Claude / htop / git log into a fresh pane" power feature.
///
/// Distinct from ``LayoutPreset`` (a saved *canvas geometry* snapshot) and ``Snippet`` (a parameterized
/// macro typed into an EXISTING pane): a `LaunchPreset` is a *template that SPAWNS* panes. It is a pure
/// `Codable` value; the store's apply path turns it into pane specs + the keystrokes to send, computed by
/// the pure ``LaunchPresetEngine`` so the whole expansion is unit-testable with no view / no transport.
public struct LaunchPreset: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// The menu / palette label ("Claude Code", "htop", "Git log").
    public var name: String
    /// The command spawned in the (first / only) pane. Empty ⇒ a plain shell pane (no command sent).
    public var command: String
    /// Optional working directory: a leading `cd <dir>` is sent before the command. `nil`/empty ⇒ the
    /// shell's default cwd.
    public var workingDirectory: String?
    /// When set, the FIRST pane splits along this axis and a SECOND pane runs ``secondaryCommand`` — a
    /// two-pane template (e.g. editor + watch). `nil` ⇒ a single pane.
    public var split: SplitConfig?
    /// SF Symbol for the menu / palette row.
    public var symbol: String
    /// Marks a shipped default (Claude Code / htop / Git log) vs a user-created one — the settings UI may
    /// forbid deleting built-ins (or offer "reset to defaults").
    public var isBuiltIn: Bool

    /// The optional second pane of a two-pane template.
    public struct SplitConfig: Codable, Sendable, Equatable {
        /// `.horizontal` = side-by-side columns, `.vertical` = stacked rows (matches ``SplitAxis``).
        public var axis: SplitAxis
        /// The command run in the second pane (empty ⇒ a plain shell beside the first).
        public var secondaryCommand: String

        public init(axis: SplitAxis, secondaryCommand: String) {
            self.axis = axis
            self.secondaryCommand = secondaryCommand
        }
    }

    public init(
        id: UUID = UUID(),
        name: String,
        command: String,
        workingDirectory: String? = nil,
        split: SplitConfig? = nil,
        symbol: String = "terminal",
        isBuiltIn: Bool = false,
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.workingDirectory = workingDirectory
        self.split = split
        self.symbol = symbol
        self.isBuiltIn = isBuiltIn
    }
}

// MARK: - Built-in launch presets

public extension LaunchPreset {
    /// The shipped defaults seeded into a fresh workspace (the W14 brief's "a couple of sensible
    /// built-ins"): Claude Code, htop, Git log. Stable UUIDs so a re-seed / settings reset is idempotent
    /// (matching the same row instead of duplicating). The `claude` preset's curated env is applied by the
    /// session launch, not here (docs/42 §4.4 retired the daemon mode → env-per-session) — the preset only
    /// runs the command.
    static let builtIns: [LaunchPreset] = [
        LaunchPreset(
            id: builtInID("11111111-0000-4000-8000-000000000001"),
            name: "Claude Code", command: "claude",
            symbol: "sparkles", isBuiltIn: true,
        ),
        LaunchPreset(
            id: builtInID("11111111-0000-4000-8000-000000000002"),
            name: "htop", command: "htop",
            symbol: "chart.bar.xaxis", isBuiltIn: true,
        ),
        LaunchPreset(
            id: builtInID("11111111-0000-4000-8000-000000000003"),
            name: "Git log", command: "git log --oneline --graph --decorate -30",
            symbol: "arrow.triangle.branch", isBuiltIn: true,
        ),
    ]

    /// Parses a compile-time-constant built-in UUID literal; the `?? UUID()` is a never-taken safety net
    /// (the literals are valid) that keeps the seed force-unwrap-free (the untrusted-input contract / lint).
    private static func builtInID(_ string: String) -> UUID {
        UUID(uuidString: string) ?? UUID()
    }
}

// MARK: - LaunchPresetEngine (pure apply → pane spec + keystrokes)

/// The PURE expansion of a ``LaunchPreset`` into what the store needs to materialize it: the pane
/// spec(s) and the exact bytes to send into each pane once its handle is live. No store, no transport,
/// no view — so the expansion (cd-prefix, command, split → second pane) is fully unit-tested.
public enum LaunchPresetEngine {
    /// One pane the preset opens, with the bytes to type into it after it connects.
    public struct PaneLaunch: Equatable, Sendable {
        public let spec: PaneSpec
        /// The bytes to send once the pane's transport is live (a `cd …\n` + `command\n`), or empty for a
        /// plain shell pane. Computed via ``SendKeysParser`` semantics (literal text + `\n`).
        public let keystrokes: [UInt8]
        public init(spec: PaneSpec, keystrokes: [UInt8]) {
            self.spec = spec
            self.keystrokes = keystrokes
        }
    }

    /// The full plan for applying a preset: the panes to create (1 or 2), and — when there are two — the
    /// axis the first splits along. The store creates pane 0, then (if `splitAxis != nil`) splits it to
    /// create pane 1, and sends each pane's keystrokes after its handle materializes.
    public struct Plan: Equatable, Sendable {
        public let panes: [PaneLaunch]
        /// `nil` for a single-pane preset; otherwise the axis pane 0 splits to host pane 1.
        public let splitAxis: SplitAxis?
        public init(panes: [PaneLaunch], splitAxis: SplitAxis?) {
            self.panes = panes
            self.splitAxis = splitAxis
        }
    }

    /// Expands `preset` into a ``Plan``. The pane title is the preset name (so "Claude Code" labels the
    /// chrome); the command + optional `cd` become the keystrokes. A two-pane preset adds a second
    /// `.terminal` pane and the split axis.
    public static func plan(for preset: LaunchPreset) -> Plan {
        let primary = PaneLaunch(
            spec: PaneSpec(kind: .terminal, title: preset.name),
            keystrokes: keystrokes(command: preset.command, cwd: preset.workingDirectory),
        )
        guard let split = preset.split else {
            return Plan(panes: [primary], splitAxis: nil)
        }
        let secondary = PaneLaunch(
            // The second pane shares the preset's cwd (a split inherits the working directory).
            spec: PaneSpec(kind: .terminal, title: preset.name),
            keystrokes: keystrokes(command: split.secondaryCommand, cwd: preset.workingDirectory),
        )
        return Plan(panes: [primary, secondary], splitAxis: split.axis)
    }

    /// The bytes to type into a freshly-spawned pane: a `cd <cwd>\n` (only when a non-empty cwd is set)
    /// followed by `<command>\n` (only when a non-empty command is set). An empty command + empty cwd ⇒
    /// no bytes (a plain shell pane).
    ///
    /// SECURITY: the `cd <cwd>` line is emitted as LITERAL UTF-8 bytes (NOT through ``SendKeysParser``).
    /// The cwd is a filesystem PATH, never shell-control input — running it through `SendKeysParser`
    /// would interpret `<Enter>`/`<cr>`/`<nl>` tokens INSIDE the (single-quoted) path, injecting a raw
    /// 0x0D/0x0A that breaks out of the quoted `cd` line so the rest runs as a SEPARATE command (a cwd
    /// of `/tmp/proj<Enter>rm -rf x` would execute `rm`). The quoting only escapes literal quotes, not
    /// these tokens, so the path must bypass the token parser entirely. Only the `command` field —
    /// intended shell input — legitimately goes through ``SendKeysParser`` (so `<Enter>`-style tokens IN
    /// a command still resolve, consistent with snippets).
    public static func keystrokes(command: String, cwd: String?) -> [UInt8] {
        var out: [UInt8] = []
        if let cwd, !cwd.isEmpty {
            // Quote the path so a cwd with spaces survives, and emit the WHOLE `cd '<path>'` line as raw
            // UTF-8 — never via SendKeysParser, whose `<…>` tokens would inject newlines into the path.
            out += Array("cd \(shellQuoted(cwd))".utf8)
            out.append(0x0A) // newline
        }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            out += SendKeysParser.encode(command)
            out.append(0x0A)
        }
        return out
    }

    /// Single-quote a shell path, escaping embedded single quotes the POSIX way (`'\''`). Pure string op.
    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
