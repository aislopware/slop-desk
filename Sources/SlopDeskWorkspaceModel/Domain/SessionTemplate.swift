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
/// plus the optional working directory + startup command. The cwd is stamped on `pane/cwd`
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
/// one-child `.split` collapses into that child, a childless one becomes a plain terminal pane rather
/// than nothing at all, and a layout nested past ``SplitNode/maxDepth`` collapses to its first pane.
/// Decode never traps on a hand-edited / hostile file.
///
/// **REPAIRED, never rejected — and this comment said the opposite until 2026-08-20.** It described
/// the depth cap as a rejection and the childless split as a drop, which are two different rules
/// from the ones above: a rejection throws (and `WorkspacePersistence.load()` then loses the WHOLE
/// file to a `.corrupt` sidecar) and a drop leaves a layout with no leaf in it. Neither ever
/// happened here. It matters beyond tidiness because `slopdesk_workspace::templates`'s twin of this
/// decode says "repaired, never rejected" in its own doc comment, so the pair read as a
/// parser-versus-repairer disagreement — `docs/55` §8's whole thesis about which pairs go wrong —
/// when in fact the two agree case for case. Nothing but the words differed, and
/// `SessionTemplateRepairDifferentialTests` is now what says so rather than either comment.
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
/// CLAUDE.md untrusted-persisted-data contract): a one-child `.split` collapses to that child, a
/// childless one becomes a default terminal pane, and an over-deep layout is capped at
/// ``SplitNode/maxDepth`` (the over-deep tail collapses to its first pane). A degenerate / hostile file
/// therefore decodes to a SOUND layout instead of trapping. Encoding is straightforward (the stable
/// on-disk shape `workspace.json` stores).
///
/// **This rule exists in two languages and `SessionTemplateRepairDifferentialTests` is what holds them
/// together.** `slopdesk_workspace::templates::TemplateNode::repaired` is the other one, reached through
/// `slopdesk_ws_template_repair`; the suite drives both over every degenerate shape and asserts they
/// converge. Editing anything below is an obligation to read that suite, because the crate's copy will
/// not stop compiling when this one changes its mind — it will simply start answering a different tree
/// on the inputs nobody generates by hand.
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
    /// The shipped default templates seeded into a fresh workspace, as `slopdesk-workspace` ships them.
    ///
    /// Stable UUIDs so a re-seed / settings reset is idempotent (matching the same row instead of
    /// duplicating). Built-in panes are `.terminal`, with no `cwd` (the user's shell default) — only
    /// #2's Git pane and #3's Claude pane carry a startup command.
    ///
    /// ## Why this reads a door instead of listing three templates
    ///
    /// It listed them until 2026-08-22, and `templates::built_in_session_templates` listed the same
    /// three, and a differential test asserted the two lists were equal. That is the arrangement
    /// CLAUDE.md names outright — a cross-language mirror fixture — and the argument for it did not
    /// survive being read: what `Codable` forces to stay Swift is the TYPE, because a device-
    /// preferences file is made of it, and this is not a type. It is three rows of data, and the
    /// differential proved the crossing already yields them exactly.
    ///
    /// What a mirror costs here is specific. The ids are fixed precisely so a re-seed MATCHES a row
    /// rather than appending one; a fourth template added to one side only would hand every device a
    /// different set depending on which side seeded it, and one changed byte in sixteen would surface
    /// weeks later as a duplicated menu row with nothing in any log. `slopdesk-invariants` pins names
    /// and numbers it was told about, and nobody told it about these.
    ///
    /// `[]` is the crossing FAILING, never the crate declining to ship a table: the door writes a
    /// fixed list, so a `nil` means this file's reader disagrees with the crate's grammar, which is a
    /// build-time contract violation rather than a runtime condition. A client that seeds no built-ins
    /// still opens, still loads the user's own templates, and still lets them make one; aborting a
    /// remote-desktop session over a seed table would be the worse of the two answers. The tests in
    /// `SessionTemplateEngineTests` pin the three names and the three ids, so an empty answer is a
    /// red suite rather than a quiet shrug.
    static let builtIns: [SessionTemplate] = SessionTemplateCrossing.builtInTemplatesFromTheCrate() ?? []
}
