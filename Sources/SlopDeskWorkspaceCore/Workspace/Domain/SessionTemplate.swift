import Foundation

// MARK: - SessionTemplate (a named project profile — a layout + per-pane cwd/command)

/// A named **session template / project profile**: a predefined split ``layout`` of panes, each carrying
/// an optional working directory + startup command, that ``SessionTemplateEngine/makeSession(from:name:)``
/// expands into a fresh ``Session`` (one tab, the template's split tree) whose panes start in that cwd and
/// run their command once their PTY is live. The inverse — capturing the active session's geometry back into a
/// reusable template — is ``SessionTemplateEngine/captureTemplate(from:name:symbol:)``.
///
/// Distinct from a ``LaunchPreset`` (which opens ONE new TAB of ≤ 2 panes into the CURRENT session): a
/// `SessionTemplate` opens a whole NAMED SESSION with an n-ary split layout. It is a pure
/// `Codable`/`Equatable`/`Sendable`/`Identifiable` value (no SwiftUI / transport import) that persists on
/// the ``TreeWorkspace`` exactly like ``LaunchPreset`` — CLIENT-ONLY, no wire / schema-version change.
public struct SessionTemplate: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// The menu / palette label ("Editor + Terminal", "Claude + Terminal").
    public var name: String
    /// SF Symbol for the menu / palette row.
    public var symbol: String
    /// Marks a shipped default vs a user-captured one (the settings UI may forbid deleting built-ins).
    public var isBuiltIn: Bool
    /// The recursive split layout this template expands into (n-ary, validate-then-repaired on decode).
    public var layout: TemplateNode

    public init(
        id: UUID = UUID(),
        name: String,
        symbol: String = "rectangle.split.2x1",
        isBuiltIn: Bool = false,
        layout: TemplateNode,
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.isBuiltIn = isBuiltIn
        self.layout = layout
    }
}

// MARK: - TemplatePane (one leaf of a template — kind + title + cwd/command)

/// One leaf of a ``SessionTemplate``'s ``TemplateNode`` layout: the pane's ``kind`` + display ``title``
/// plus the optional working directory + startup command. The cwd is stamped on ``PaneSpec/lastKnownCwd``
/// for host-side PTY spawn; the command is typed once the PTY is live. A pure value.
public struct TemplatePane: Codable, Sendable, Equatable {
    public var kind: PaneKind
    public var title: String
    /// Optional working directory for host-side PTY spawn. `nil`/empty ⇒ the shell's default cwd.
    public var cwd: String?
    /// Optional startup command run in the pane. `nil`/empty ⇒ a plain shell pane (no command sent).
    public var command: String?

    public init(kind: PaneKind = .terminal, title: String, cwd: String? = nil, command: String? = nil) {
        self.kind = kind
        self.title = title
        self.cwd = cwd
        self.command = command
    }
}

// MARK: - TemplateNode (the recursive, n-ary template layout)

/// The recursive, **n-ary** layout of a ``SessionTemplate`` — the persisted blueprint
/// ``SessionTemplateEngine/makeSession(from:name:)`` turns into a live ``SplitNode`` tree (minting fresh
/// ``PaneID``s). It mirrors ``SplitNode`` but carries the per-pane launch intent (a ``TemplatePane``
/// instead of a bare id) and uses EQUAL flex weights (a template describes structure, not exact
/// divider positions).
///
/// **Validate-then-repair decode** (the untrusted-persisted-data contract, mirroring ``SplitNode``): a
/// `.split` with < 2 children collapses to its single child (or is dropped entirely when childless); a
/// layout nested past ``SplitNode/maxDepth`` is rejected (the over-deep tail collapses to its first
/// pane). Decode never traps on a hand-edited / hostile file.
public indirect enum TemplateNode: Codable, Sendable, Equatable {
    case pane(TemplatePane)
    case split(axis: SplitAxis, children: [Self])
}

// MARK: - TemplateNode pure queries

public extension TemplateNode {
    /// The number of leaf panes in the layout — a `.pane` is 1, a `.split` is the sum of its children.
    var paneCount: Int {
        switch self {
        case .pane:
            return 1
        case let .split(_, children):
            var count = 0
            for child in children { count += child.paneCount }
            return count
        }
    }

    /// The nesting depth: a `.pane` is 1; a `.split` is 1 + the deepest child (mirrors
    /// ``SplitNode/depth``). Used to enforce ``SplitNode/maxDepth``.
    var depth: Int {
        switch self {
        case .pane:
            return 1
        case let .split(_, children):
            var deepest = 0
            for child in children { deepest = max(deepest, child.depth) }
            return 1 + deepest
        }
    }
}

// MARK: - TemplateNode validate-then-repair Codable

/// A hand-written `Codable` that ENFORCES the layout invariants on decode (validate-then-repair, the
/// CLAUDE.md untrusted-persisted-data contract): a `.split` with < 2 children collapses to its lone child
/// (or is dropped when childless) and an over-deep layout is capped at ``SplitNode/maxDepth`` (the
/// over-deep tail collapses to its first pane). A degenerate / hostile file therefore decodes to a SOUND
/// layout instead of trapping. Encoding is straightforward (the stable on-disk shape `workspace.json`
/// stores).
extension TemplateNode {
    private enum Discriminator: String, Codable { case pane, split }
    private enum CodingKeys: String, CodingKey { case kind, pane, axis, children }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Discriminator.self, forKey: .kind)
        switch kind {
        case .pane:
            self = try .pane(container.decode(TemplatePane.self, forKey: .pane))
        case .split:
            let axis = try container.decode(SplitAxis.self, forKey: .axis)
            let rawChildren = try container.decode([TemplateNode].self, forKey: .children)
            // Validate-then-repair: a split needs ≥ 2 children — a 1-child split collapses into its child,
            // a 0-child split is a hard-corrupt node (no leaf at all) we replace with a default pane so the
            // decode is total (a session must have ≥ 1 leaf).
            if rawChildren.count >= 2 {
                self = .split(axis: axis, children: rawChildren)
            } else if let only = rawChildren.first {
                self = only
            } else {
                self = .pane(TemplatePane(title: "Terminal"))
            }
        }
        // Cap an over-deep layout (a hostile file nested past maxDepth) so the later SplitNode build can
        // never exceed the tree's own depth bound — collapse the over-deep node to its first leaf pane.
        if depth > SplitNode.maxDepth {
            self = .pane(firstPane())
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .pane(pane):
            try container.encode(Discriminator.pane, forKey: .kind)
            try container.encode(pane, forKey: .pane)
        case let .split(axis, children):
            try container.encode(Discriminator.split, forKey: .kind)
            try container.encode(axis, forKey: .axis)
            try container.encode(children, forKey: .children)
        }
    }

    /// The first leaf ``TemplatePane`` in DFS order (a `.pane` is itself; a `.split` recurses into its
    /// first child). Total — the decode guarantees every `.split` has ≥ 1 child, so this never falls
    /// through, but a synthesized default keeps it force-unwrap-free (the untrusted-input lint).
    func firstPane() -> TemplatePane {
        switch self {
        case let .pane(pane):
            pane
        case let .split(_, children):
            children.first?.firstPane() ?? TemplatePane(title: "Terminal")
        }
    }
}

// MARK: - Built-in session templates

public extension SessionTemplate {
    /// The shipped default templates seeded into a fresh workspace. Stable hardcoded UUIDs so a re-seed /
    /// settings reset is idempotent (matching the same row instead of duplicating). Built-in panes are
    /// `.terminal`, with no `cwd` (the user's shell default) — only #2's Git pane + #3's Claude pane carry
    /// a startup command.
    static let builtIns: [SessionTemplate] = [
        SessionTemplate(
            id: builtInID("22222222-0000-4000-8000-000000000001"),
            name: "Editor + Terminal", symbol: "rectangle.split.2x1", isBuiltIn: true,
            layout: .split(axis: .horizontal, children: [
                .pane(TemplatePane(title: "Editor")),
                .pane(TemplatePane(title: "Terminal")),
            ]),
        ),
        SessionTemplate(
            id: builtInID("22222222-0000-4000-8000-000000000002"),
            name: "Editor · Server · Git", symbol: "rectangle.split.3x1", isBuiltIn: true,
            layout: .split(axis: .horizontal, children: [
                .pane(TemplatePane(title: "Editor")),
                .split(axis: .vertical, children: [
                    .pane(TemplatePane(title: "Server")),
                    .pane(TemplatePane(title: "Git", command: "git status")),
                ]),
            ]),
        ),
        SessionTemplate(
            id: builtInID("22222222-0000-4000-8000-000000000003"),
            name: "Claude + Terminal", symbol: "sparkles", isBuiltIn: true,
            layout: .split(axis: .horizontal, children: [
                .pane(TemplatePane(title: "Claude", command: "claude")),
                .pane(TemplatePane(title: "Terminal")),
            ]),
        ),
    ]

    /// Parses a compile-time-constant built-in UUID literal; the `?? UUID()` is a never-taken safety net
    /// (the literals are valid) that keeps the seed force-unwrap-free (the untrusted-input contract / lint).
    private static func builtInID(_ string: String) -> UUID {
        UUID(uuidString: string) ?? UUID()
    }
}
