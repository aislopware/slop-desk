/// The client-side observable store the read-only SwiftUI views render from.
///
/// It consumes the deserialised ``InspectorEvent`` stream (from ``InspectorClient``)
/// and projects it into render-ready collections: tool cards (timeline), the subagent
/// tree, the latest todo list, and the thinking-placeholder indicator. **All logic
/// lives here, none in the views** (the spec's "no business logic in views").
///
/// `@MainActor` + `@Observable` so SwiftUI tracks changes automatically. It is built
/// in the library target and compiles on macOS + iOS.
///
/// **The rules are not here.** The tree's shape, the empty-state gate and the five drop-oldest
/// ladders are `slopdesk_workspace::inspector_store`, reached through ``InspectorStoreRules`` — see
/// that file's header for what crosses and what deliberately does not. What is left is the
/// `@Observable` writes, the arrival-order bookkeeping, and the dictionary indices that keep an
/// upsert O(1).
import Foundation

@preconcurrency
@MainActor
@Observable
public final class InspectorViewModel {
    /// Tool cards in arrival order (timeline). Keyed lookup keeps pairing O(1).
    public private(set) var toolCards: [ToolCard] = []
    private var toolCardIndex: [String: Int] = [:]
    /// How many oldest main tool cards the drop-oldest cap has evicted — surfaced as a
    /// "N earlier steps hidden" banner so a long session does not silently lose the start of its timeline.
    /// Monotonic; reset in `consume()` so a fromSeq:0 replay rebuilds rather than doubles it.
    public private(set) var evictedToolCardCount = 0

    /// The latest todo list (replaced wholesale on each update).
    public private(set) var todos: [TodoItem] = []

    /// Subagent nodes by id (the tree is derived in ``subagentTree``).
    public private(set) var subagents: [String: SubagentNode] = [:]
    /// Tool cards owned by each subagent, in arrival order.
    public private(set) var subagentCards: [String: [ToolCard]] = [:]
    private var subagentCardIndex: [String: [String: Int]] = [:]

    /// Message timeline (user/assistant text for the main session).
    public private(set) var messages: [MessageEvent] = []

    /// The drop-oldest CEILINGS, read out of `slopdesk_workspace::inspector_store` rather than
    /// spelled here — the ladder and its batched retain marks are one rule, and half of it written
    /// down on this side is the drift the port removed. See ``InspectorStoreRules``.
    ///
    /// They exist as members because they are what the panel and its tests talk about; the number
    /// of entries an arrival actually evicts is ``InspectorStoreRules/overflow(_:count:)``, and no
    /// call site below does that subtraction itself.
    static let toolCardCap = InspectorStoreRules.cap(.toolCards)
    /// The per-agent card ceiling. Per agent, not across them.
    static let subagentCardCap = InspectorStoreRules.cap(.subagentCards)
    /// The message timeline's ceiling.
    static let messageCap = InspectorStoreRules.cap(.messages)
    /// The distinct-agent ceiling — the OUTER dimension, whose eviction takes an agent's node,
    /// cards and index TOGETHER so `subagentTree` never references an orphan.
    static let maxAgents = InspectorStoreRules.cap(.agents)
    /// Insertion order of distinct agentIDs (drives the drop-oldest agent-count cap above).
    private var subagentOrder: [String] = []

    /// The most recent thinking marker (drives the placeholder indicator).
    public private(set) var lastThinking: ThinkingMarker?
    /// Count of thinking blocks observed (so the UI can show "N thinking steps").
    public private(set) var thinkingCount = 0

    /// Session metadata (model / cwd) for the header.
    public private(set) var session: SessionInfo?

    /// Workflow state (defer/preview).
    public private(set) var workflow: WorkflowMarker.State = .idle

    /// Count of unrecognised lines (surfaced, not hidden) — the true monotonic total.
    public private(set) var unknownLineCount = 0

    /// The most recent unrecognised transcript lines (bounded ring, newest-last). Lets the UI turn
    /// the bare count into an inspectable disclosure instead of a dead-end alarm. Bounded
    /// (drop-oldest) so a malformed-feed flood cannot grow it without limit (cf. the daemon's builder
    /// unbounded-maps history).
    public private(set) var recentUnknownLines: [String] = []

    /// Number of oldest events the HOST replay log dropped (retention overflow) before the prefix this
    /// client subscribed from. `> 0` means the timeline starts mid-transcript; the UI
    /// can disclose "N earlier steps dropped" instead of presenting a truncated history as complete.
    public private(set) var droppedReplayEventCount = 0

    /// Liveness of the consumed inspector feed. Surfaced as a banner so frozen tool cards don't look
    /// live forever — on macOS there is no in-session auto-resume, so a feed that `.ended`
    /// or `.failed` stays stale until the next iOS pause/resume cycle.
    public enum FeedState: Sendable, Equatable { case live, ended, failed }
    public private(set) var feedState: FeedState = .live

    /// Whether anything user-visible has been folded into the timeline yet (drives the empty-state
    /// placeholder). **Excludes `messages`** (stored but never rendered today — including it would
    /// reintroduce a blank panel) and the always-present session header. Uses `subagentTree` (NOT the
    /// raw `subagents` dict): the tree drops empty-id + self-parent nodes, so a single malformed
    /// empty-id subagent must NOT suppress the placeholder while rendering nothing (the exact blank-void
    /// this gate exists to prevent — `subagentTree.isEmpty` ⟺ the subagent section renders nothing).
    public var hasRenderableActivity: Bool {
        InspectorStoreRules.hasRenderableActivity(
            hasToolCards: !toolCards.isEmpty,
            hasTodos: !todos.isEmpty,
            hasSubagentTree: !subagentTree.isEmpty,
            hasThinking: lastThinking != nil,
            unknownLineCount: unknownLineCount,
        )
    }

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
            if subagents[node.id] == nil { registerAgent(node.id) }
            subagents[node.id] = node
        case let .subagentToolCard(agentID, card):
            upsertSubagentCard(card, agentID: agentID)
        case let .thinking(marker):
            lastThinking = marker
            thinkingCount += 1
        case let .message(message):
            messages.append(message)
            let overflow = InspectorStoreRules.overflow(.messages, count: messages.count)
            if overflow > 0 { messages.removeFirst(overflow) }
        case let .sessionStarted(info):
            session = info
        case let .workflow(marker):
            workflow = marker.state
        case let .unknownLine(raw):
            unknownLineCount += 1
            recentUnknownLines.append(raw)
            let overflow = InspectorStoreRules.overflow(
                .unknownLines, count: recentUnknownLines.count,
            )
            if overflow > 0 { recentUnknownLines.removeFirst(overflow) }
        case let .historyTruncated(droppedCount):
            // Latest-wins (a re-replay re-sends the current drop count) — not accumulated.
            droppedReplayEventCount = droppedCount
        }
    }

    /// Consumes an event stream until it finishes (driven from a SwiftUI `.task`).
    public func consume(_ events: AsyncThrowingStream<InspectorEvent, Error>) async {
        feedState = .live // reset-on-entry: an iOS resume opens a fresh feed → live again
        // An iOS pause/resume reuses this SAME model and re-subscribes `fromSeq: 0`, so the host
        // replays its ENTIRE history into us again. Cards/subagents self-dedupe by id (upsert), but
        // these monotonic accumulators do NOT — without a reset, every resume DOUBLES the displayed
        // "N thinking steps" / "N unrecognised lines" and re-appends duplicate messages.
        // Clear them so a full replay REBUILDS, not inflates, them. (Safe only because the client
        // always subscribes fromSeq:0 — a future partial-resume path would need a seq watermark or
        // stable-key dedup here instead; see LivePaneSession.subscribeInspector.)
        thinkingCount = 0
        lastThinking = nil
        unknownLineCount = 0
        recentUnknownLines = []
        messages = []
        evictedToolCardCount = 0
        droppedReplayEventCount = 0 // latest-wins; reset so a re-replay rebuilds it
        do {
            for try await event in events {
                apply(event)
            }
            feedState = .ended // the host closed the feed cleanly (no live resubscribe on macOS)
        } catch {
            feedState = .failed
            // Read-only viewer: a transport error (e.g. a true framing desync,
            // InspectorChannel `frameTooLarge`) just ends the feed. There is no in-session
            // live resubscribe today. The feed resumes on the
            // next iOS pause/resume cycle, when LivePaneSession.resume → subscribeInspector
            // opens a fresh connection and subscribes(fromSeq: 0) from the host replay log.
        }
    }

    /// The subagent tree as roots + children, each level ordered by id, as
    /// `slopdesk_workspace::inspector_store` builds it. (Sort in-level — doc 16: subagent ordering
    /// is async; sort within a level, not globally.)
    ///
    /// **In practice this is flat today.** Nesting is keyed off ``SubagentNode/parentID``,
    /// and no documented Claude Code signal in the doc-16 corpus carries a cross-file
    /// parent link (the `SubagentStop` hook has no `parent_agent_id`; sidechain lines
    /// only carry intra-file `parentUuid`). So every node currently has `parentID == nil`
    /// and attaches directly under the main session — a single flat level. The nesting build
    /// is retained so that when a real parent-linkage source lands (e.g. correlating
    /// the parent session's `Task` `tool_use` id), it works without an API change;
    /// it is not a claim that nested data exists today.
    public var subagentTree: [SubagentTreeNode] {
        InspectorStoreRules.subagentTree(subagents, cards: subagentCards)
    }

    // MARK: - Card upsert

    private func upsertMainCard(_ card: ToolCard) {
        if let index = toolCardIndex[card.id] {
            toolCards[index] = card
        } else {
            toolCardIndex[card.id] = toolCards.count
            toolCards.append(card)
            let drop = InspectorStoreRules.overflow(.toolCards, count: toolCards.count)
            if drop > 0 {
                toolCards.removeFirst(drop)
                evictedToolCardCount += drop // track the truncation so the UI can disclose it
                // Every surviving card's index shifted down by `drop` — rebuild the lookup from the
                // surviving slice so a later upsert of a retained id still resolves in place.
                toolCardIndex = Dictionary(uniqueKeysWithValues: toolCards.enumerated().map { ($1.id, $0) })
            }
        }
    }

    /// Registers a newly-seen agentID in insertion order and, past `maxAgents`, evicts the oldest
    /// agents' node + cards + index TOGETHER (batched cap→retain) so `subagentTree` never references an
    /// orphan. Call EXACTLY when an agent is first created (the `subagents[id] == nil` branches).
    private func registerAgent(_ agentID: String) {
        subagentOrder.append(agentID)
        let drop = InspectorStoreRules.overflow(.agents, count: subagentOrder.count)
        guard drop > 0 else { return }
        for id in subagentOrder.prefix(drop) {
            subagents.removeValue(forKey: id)
            subagentCards.removeValue(forKey: id)
            subagentCardIndex.removeValue(forKey: id)
        }
        subagentOrder.removeFirst(drop)
    }

    private func upsertSubagentCard(_ card: ToolCard, agentID: String) {
        // Make sure the node exists even if the line arrived before the hook.
        if subagents[agentID] == nil {
            registerAgent(agentID)
            subagents[agentID] = SubagentNode(id: agentID, status: .running)
        }
        var cards = subagentCards[agentID] ?? []
        var index = subagentCardIndex[agentID] ?? [:]
        if let i = index[card.id] {
            cards[i] = card
        } else {
            index[card.id] = cards.count
            cards.append(card)
            let drop = InspectorStoreRules.overflow(.subagentCards, count: cards.count)
            if drop > 0 {
                cards.removeFirst(drop)
                index = Dictionary(uniqueKeysWithValues: cards.enumerated().map { ($1.id, $0) })
            }
        }
        subagentCards[agentID] = cards
        subagentCardIndex[agentID] = index
    }
}

/// A render-ready subagent tree node (node + its cards + children).
public struct SubagentTreeNode: Identifiable, Sendable, Equatable {
    public var node: SubagentNode
    public var cards: [ToolCard]
    public var children: [Self]

    public var id: String { node.id }

    public init(node: SubagentNode, cards: [ToolCard], children: [Self]) {
        self.node = node
        self.cards = cards
        self.children = children
    }
}

extension ToolCard: Identifiable {}
extension TodoItem: Identifiable {
    public var id: String { content }
}
