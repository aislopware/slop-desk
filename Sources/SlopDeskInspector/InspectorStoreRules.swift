// InspectorStoreRules — the Swift FACE of `slopdesk_workspace::inspector_store`.
//
// ``InspectorCodec`` is the face of the inspector's FRAME, whose every byte lives in
// `slopdesk-inspectord`. This is the face of the other half: the fold ``InspectorViewModel``
// applies to the events that frame delivered — which nesting the agents make, what counts as
// something to render, and how much of a long session the store keeps.
//
// ## What crosses, and what deliberately does not
//
// An agent id is a `String` the model's own map is keyed by, and the JOIN that resolves a parent id
// to an agent stays here, on the side that owns the values: a parent crosses as the POSITION of the
// agent it names, or as one of the crate's two refusals. The id BYTES do cross, and for exactly one
// reason — a level of the tree is ordered by them.
//
// ## The tree comes back FLAT and is re-nested here
//
// A nested answer would mean an allocation per node crossing the boundary, which `docs/55`'s cost
// table is unambiguous about. The door answers one `(position, parentSlot)` row per rendered agent,
// PARENTS BEFORE CHILDREN, and the rebuild below walks that list backwards: a parent's slot is
// always lower than its children's, so by the time a row is reached every child of it has already
// been folded into the bucket it will take. Reverse order delivers siblings back-to-front, so each
// bucket is reversed as it is consumed rather than being inserted into at the front — which is the
// difference between one pass and a quadratic one on a session with two thousand flat agents.
//
// ## What did NOT move
//
// The upserts. Which slot of a card list an arriving card replaces, and the index rebuilt over the
// survivors after an eviction, are dictionary bookkeeping over values this side owns. What crossed
// out of them is the only decision they held: HOW MANY to drop.

import CSlopDeskFFI
import Foundation

// MARK: - The vocabulary, and the byte it crosses as

/// One of the store's five bounded collections.
///
/// Every one grows with the length of a session, and the daemon already bounds its own analogues,
/// so the client was the unbounded end. Eviction is BATCHED — a ceiling and a lower retained mark —
/// so it stays amortized rather than paying a front-removal per arrival once the cap is reached.
public enum InspectorStoreRing {
    /// The main session's tool cards, in arrival order.
    case toolCards
    /// One subagent's tool cards. The ceiling is per agent, not across them.
    case subagentCards
    /// The user/assistant message timeline.
    case messages
    /// The distinct-agent count — the outer dimension, whose eviction takes an agent's node, its
    /// cards and its index together so the tree can never reference an orphan.
    case agents
    /// The most recent unrecognised transcript lines.
    case unknownLines

    /// The byte the crate names this ring by.
    var ffiByte: UInt8 {
        switch self {
        case .toolCards: UInt8(SLOPDESK_INSPECTOR_STORE_RING_TOOL_CARDS)
        case .subagentCards: UInt8(SLOPDESK_INSPECTOR_STORE_RING_SUBAGENT_CARDS)
        case .messages: UInt8(SLOPDESK_INSPECTOR_STORE_RING_MESSAGES)
        case .agents: UInt8(SLOPDESK_INSPECTOR_STORE_RING_AGENTS)
        case .unknownLines: UInt8(SLOPDESK_INSPECTOR_STORE_RING_UNKNOWN_LINES)
        }
    }
}

// MARK: - The face

/// Every decision the inspector's client-side store makes, as
/// `slopdesk_workspace::inspector_store` answers them.
public enum InspectorStoreRules {
    // MARK: The bounded collections

    /// The count above which `ring` evicts.
    public static func cap(_ ring: InspectorStoreRing) -> Int {
        slopdesk_inspector_store_cap(ring.ffiByte)
    }

    /// How many oldest entries an arrival at `count` evicts from `ring`. `0` until the ceiling is
    /// passed, which is every arrival on any session short of the cap.
    public static func overflow(_ ring: InspectorStoreRing, count: Int) -> Int {
        slopdesk_inspector_store_overflow(ring.ffiByte, Swift.max(0, count))
    }

    // MARK: The empty-state gate

    /// Whether anything user-visible has been folded in yet.
    ///
    /// `hasSubagentTree` is the TREE's emptiness, never the raw agent map's: the tree drops empty-id
    /// and unreachable agents, so a single malformed record must not suppress the placeholder while
    /// rendering nothing. Messages have no argument at all — they are stored and never drawn, and
    /// counting them would reintroduce the same blank panel from the other direction.
    public static func hasRenderableActivity(
        hasToolCards: Bool,
        hasTodos: Bool,
        hasSubagentTree: Bool,
        hasThinking: Bool,
        unknownLineCount: Int,
    ) -> Bool {
        slopdesk_inspector_store_has_activity(
            hasToolCards, hasTodos, hasSubagentTree, hasThinking,
            UInt64(clamping: unknownLineCount),
        )
    }

    // MARK: The tree

    /// The agent tree as roots + children, each level ordered by id.
    ///
    /// Sorted WITHIN a level rather than globally (doc 16): subagent arrival is asynchronous, so a
    /// global order would reshuffle siblings under unrelated parents every time a late one landed.
    /// Three kinds of record render nothing and each is a real shape in tolerant input — an empty
    /// id, a parent id that names no agent, and an agent that is its own ancestor.
    public static func subagentTree(
        _ subagents: [String: SubagentNode],
        cards: [String: [ToolCard]],
    ) -> [SubagentTreeNode] {
        let all = Array(subagents.values)
        guard !all.isEmpty else { return [] }
        // The identity table, minted here because the identities are this side's. `subagents` is
        // keyed by id, so this is one-to-one and a parent resolves to at most one position.
        var position: [String: Int] = [:]
        position.reserveCapacity(all.count)
        for (slot, node) in all.enumerated() { position[node.id] = slot }

        var ids: [UInt8] = []
        var entries: [SlopDeskInspectorStoreAgent] = []
        entries.reserveCapacity(all.count)
        for node in all {
            let bytes = Array(node.id.utf8)
            // CLAMPING rather than truncating: an offset past `UInt32.max` reads on the far side as
            // a span that does not fit the blob, which is the empty id — the node renders nowhere
            // instead of wearing a neighbour's name.
            let offset = UInt32(clamping: ids.count)
            ids.append(contentsOf: bytes)
            entries.append(SlopDeskInspectorStoreAgent(
                id_offset: offset,
                id_length: UInt32(clamping: bytes.count),
                parent: parentSlot(of: node, in: position),
            ))
        }

        // The answer is one row per RENDERED agent, so it can never be longer than the list it came
        // from: the buffer is the arithmetic bound rather than a guess, and the size-then-retry path
        // is never travelled.
        var out = [SlopDeskInspectorStoreSlot](
            repeating: SlopDeskInspectorStoreSlot(), count: all.count,
        )
        let needed = ids.withUnsafeBufferPointer { blob in
            entries.withUnsafeBufferPointer { records in
                out.withUnsafeMutableBufferPointer { room in
                    slopdesk_inspector_store_subagent_tree(
                        blob.baseAddress, blob.count,
                        records.baseAddress, records.count,
                        room.baseAddress, room.count,
                    )
                }
            }
        }
        guard needed <= out.count else { return [] }
        return nest(out.prefix(needed), over: all, cards: cards)
    }

    /// Which entry of the same list `node`'s parent is, or one of the crate's two refusals.
    ///
    /// A parent id that names no agent is DANGLING rather than a root. Promoting it would be the
    /// kinder-looking answer and the wrong one: it claims a top-level agent the transcript never
    /// said was one.
    private static func parentSlot(of node: SubagentNode, in table: [String: Int]) -> Int32 {
        guard let parent = node.parentID, !parent.isEmpty else {
            return Int32(SLOPDESK_INSPECTOR_STORE_ROOT)
        }
        guard let slot = table[parent] else { return Int32(SLOPDESK_INSPECTOR_STORE_DANGLING) }
        return Int32(clamping: slot)
    }

    /// The crate's flat pre-order answer, re-nested. Transcription only — every choice about which
    /// row goes where was made on the far side.
    private static func nest(
        _ answer: ArraySlice<SlopDeskInspectorStoreSlot>,
        over agents: [SubagentNode],
        cards: [String: [ToolCard]],
    ) -> [SubagentTreeNode] {
        var buckets = [[SubagentTreeNode]](repeating: [], count: answer.count)
        var roots: [SubagentTreeNode] = []
        // Backwards, because a parent's slot is always LOWER than its children's — so by the time a
        // row is reached, everything that hangs off it is already in its bucket. Siblings arrive
        // back-to-front, which is why each bucket is reversed as it is consumed.
        for slot in stride(from: answer.count - 1, through: 0, by: -1) {
            let record = answer[answer.startIndex + slot]
            let index = Int(record.position)
            guard agents.indices.contains(index) else { continue }
            let node = agents[index]
            let built = SubagentTreeNode(
                node: node,
                cards: cards[node.id] ?? [],
                children: Array(buckets[slot].reversed()),
            )
            let parent = Int(record.parent_slot)
            if buckets.indices.contains(parent) {
                buckets[parent].append(built)
            } else {
                roots.append(built)
            }
        }
        return Array(roots.reversed())
    }
}
