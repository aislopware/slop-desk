import Foundation

/// The client-side observable store the read-only SwiftUI views render from.
///
/// It consumes the deserialised ``InspectorEvent`` stream (from ``InspectorClient``)
/// and projects it into render-ready collections: tool cards (timeline), the subagent
/// tree, the latest todo list, and the thinking-placeholder indicator. **All logic
/// lives here, none in the views** (the spec's "no business logic in views").
///
/// `@MainActor` + `@Observable` so SwiftUI tracks changes automatically. It is built
/// in the library target and compiles on macOS + iOS.
@MainActor
@Observable
public final class InspectorViewModel {
    /// Tool cards in arrival order (timeline). Keyed lookup keeps pairing O(1).
    public private(set) var toolCards: [ToolCard] = []
    private var toolCardIndex: [String: Int] = [:]

    /// The latest todo list (replaced wholesale on each update).
    public private(set) var todos: [TodoItem] = []

    /// Subagent nodes by id (the tree is derived in ``subagentTree``).
    public private(set) var subagents: [String: SubagentNode] = [:]
    /// Tool cards owned by each subagent, in arrival order.
    public private(set) var subagentCards: [String: [ToolCard]] = [:]
    private var subagentCardIndex: [String: [String: Int]] = [:]

    /// Message timeline (user/assistant text for the main session).
    public private(set) var messages: [MessageEvent] = []

    /// The most recent thinking marker (drives the placeholder indicator).
    public private(set) var lastThinking: ThinkingMarker?
    /// Count of thinking blocks observed (so the UI can show "N thinking steps").
    public private(set) var thinkingCount = 0

    /// Session metadata (model / cwd) for the header.
    public private(set) var session: SessionInfo?

    /// Workflow state (defer/preview).
    public private(set) var workflow: WorkflowMarker.State = .idle

    /// Count of unrecognised lines (surfaced, not hidden).
    public private(set) var unknownLineCount = 0

    public init() {}

    /// Folds one event into the store. Idempotent on tool-card id (a re-emitted card
    /// updates in place rather than appending a duplicate).
    public func apply(_ event: InspectorEvent) {
        switch event {
        case let .toolCard(card):
            upsertMainCard(card)
        case let .todosUpdated(items):
            todos = items
        case let .subagentUpdated(node):
            subagents[node.id] = node
        case let .subagentToolCard(agentID, card):
            upsertSubagentCard(card, agentID: agentID)
        case let .thinking(marker):
            lastThinking = marker
            thinkingCount += 1
        case let .message(message):
            messages.append(message)
        case let .sessionStarted(info):
            session = info
        case let .workflow(marker):
            workflow = marker.state
        case .unknownLine:
            unknownLineCount += 1
        }
    }

    /// Consumes an event stream until it finishes (driven from a SwiftUI `.task`).
    public func consume(_ events: AsyncThrowingStream<InspectorEvent, Error>) async {
        do {
            for try await event in events {
                apply(event)
            }
        } catch {
            // Read-only viewer: a transport error just ends the feed; the host glue
            // reconnects (subscribe(fromSeq:)) and a fresh stream resumes here.
        }
    }

    /// The subagent tree as roots + children, sorted by id for stable rendering. (Sort
    /// in-level — doc 16: subagent ordering is async; sort within a level, not globally.)
    ///
    /// **In practice this is flat today.** Nesting is keyed off ``SubagentNode/parentID``,
    /// and no documented Claude Code signal in the doc-16 corpus carries a cross-file
    /// parent link (the `SubagentStop` hook has no `parent_agent_id`; sidechain lines
    /// only carry intra-file `parentUuid`). So every node currently has `parentID == nil`
    /// and attaches directly under the main session — a single flat level. The recursive
    /// build is retained so that when a real parent-linkage source lands (e.g. correlating
    /// the parent session's `Task` `tool_use` id), nesting works without an API change;
    /// it is not a claim that nested data exists today.
    public var subagentTree: [SubagentTreeNode] {
        let all = Array(subagents.values)
        let byParent = Dictionary(grouping: all) { $0.parentID ?? "" }
        func build(parent: String) -> [SubagentTreeNode] {
            (byParent[parent] ?? [])
                .sorted { $0.id < $1.id }
                .map { node in
                    SubagentTreeNode(
                        node: node,
                        cards: subagentCards[node.id] ?? [],
                        children: build(parent: node.id)
                    )
                }
        }
        return build(parent: "")
    }

    // MARK: - Card upsert

    private func upsertMainCard(_ card: ToolCard) {
        if let index = toolCardIndex[card.id] {
            toolCards[index] = card
        } else {
            toolCardIndex[card.id] = toolCards.count
            toolCards.append(card)
        }
    }

    private func upsertSubagentCard(_ card: ToolCard, agentID: String) {
        // Make sure the node exists even if the line arrived before the hook.
        if subagents[agentID] == nil {
            subagents[agentID] = SubagentNode(id: agentID, status: .running)
        }
        var cards = subagentCards[agentID] ?? []
        var index = subagentCardIndex[agentID] ?? [:]
        if let i = index[card.id] {
            cards[i] = card
        } else {
            index[card.id] = cards.count
            cards.append(card)
        }
        subagentCards[agentID] = cards
        subagentCardIndex[agentID] = index
    }
}

/// A render-ready subagent tree node (node + its cards + children).
public struct SubagentTreeNode: Identifiable, Sendable, Equatable {
    public var node: SubagentNode
    public var cards: [ToolCard]
    public var children: [SubagentTreeNode]

    public var id: String { node.id }

    public init(node: SubagentNode, cards: [ToolCard], children: [SubagentTreeNode]) {
        self.node = node
        self.cards = cards
        self.children = children
    }
}

extension ToolCard: Identifiable {}
extension TodoItem: Identifiable {
    public var id: String { content }
}
