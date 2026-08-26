import CoreGraphics
import CSlopDeskFFI
import Foundation

// The one place this module marshals for `rust/slopdesk-workspace` (docs/55).
//
// The document's VALUE TYPES stay here: `PaneSpec`, `SplitNode`, `Canvas` and their identities are
// what 262 files import and what SwiftUI diffs to decide what to redraw. What crossed is the half
// that DECIDES — where focus lands, what order the sidebar's sections come in, which tab survives a
// close — and this file is the only thing that knows those two halves are in different languages.
//
// `CGFloat` is `Double` on every slice this ships (docs/49: arm64 only), so a `CGRect` and a
// `SlopDeskWsRect` are the same four doubles in the same order. The conversions below are field
// copies, not reinterpretations: the compiler still owns the layout, and a slice where that stopped
// being true would fail to build rather than mis-read a pane's frame.

// MARK: - The flat shapes

extension SlopDeskWsUuid {
    /// A UUID's own byte order, which is what makes a sort by id agree across the boundary.
    init(_ uuid: UUID) {
        self.init(bytes: uuid.uuid)
    }

    var uuid: UUID { UUID(uuid: bytes) }
}

extension SlopDeskWsRect {
    package init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height)
    }

    package var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

extension SlopDeskWsPoint {
    init(_ point: CGPoint) {
        self.init(x: point.x, y: point.y)
    }

    var point: CGPoint { CGPoint(x: x, y: y) }
}

extension PaneID {
    package var ffi: SlopDeskWsUuid { SlopDeskWsUuid(raw) }
    package init(ffi: SlopDeskWsUuid) { self.init(raw: ffi.uuid) }
}

extension TabID {
    var ffi: SlopDeskWsUuid { SlopDeskWsUuid(raw) }
    init(ffi: SlopDeskWsUuid) { self.init(raw: ffi.uuid) }
}

extension SplitNodeID {
    var ffi: SlopDeskWsUuid { SlopDeskWsUuid(raw) }
    init(ffi: SlopDeskWsUuid) { self.init(raw: ffi.uuid) }
}

package extension PaneKind {
    /// The CASE index — the crate's `PaneKind` order, pinned by `rust/slopdesk-invariants`.
    ///
    /// The crate reads anything but `1` as a terminal, so a disagreement here degrades to the safe
    /// kind rather than opening a dead video pane. That is a floor, not a licence: the gate compares
    /// the two maps so the floor never has to catch anything.
    var ffiByte: UInt8 {
        switch self {
        case .terminal: 0
        case .desktop: 1
        }
    }
}

extension FocusDirection {
    /// The CASE index — the crate's enum order, pinned by `rust/slopdesk-invariants`.
    var ffiByte: UInt8 {
        switch self {
        case .left: 0
        case .right: 1
        case .up: 2
        case .down: 3
        case .next: 4
        case .previous: 5
        }
    }
}

// MARK: - Calling a solver

/// Runs a `(bytes, len, out, cap) -> needed` transform and returns the answer's bytes.
///
/// A first guess generous by an order of magnitude, and a retry that exists to be correct rather
/// than to be travelled (docs/55 §4). `nil` distinguishes "no answer" from "the empty answer",
/// which is the difference between an absent project key and a blank one.
package func wsTransform(
    _ text: String,
    _ call: (UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<UInt8>?, Int) -> Int,
) -> [UInt8]? {
    var bytes = Array(text.utf8)
    return bytes.withUnsafeMutableBufferPointer { input -> [UInt8]? in
        var out = [UInt8](repeating: 0, count: max(256, input.count + 32))
        var needed = out.withUnsafeMutableBufferPointer { buffer in
            call(input.baseAddress, input.count, buffer.baseAddress, buffer.count)
        }
        if needed > out.count {
            out = [UInt8](repeating: 0, count: needed)
            needed = out.withUnsafeMutableBufferPointer { buffer in
                call(input.baseAddress, input.count, buffer.baseAddress, buffer.count)
            }
        }
        guard needed > 0, needed <= out.count else { return nil }
        return Array(out[0..<needed])
    }
}

/// Runs an `(out, cap) -> needed` door that takes no input and returns the string it delivered.
///
/// The INDEXED-list sibling of ``wsTransform(_:_:)``: a catalog door already knows its answer and
/// only needs somewhere to put it, so what crosses is the size rather than a payload. `capacity` is
/// the caller's guess at what fits inline; over it the door reports its size and the reader asks
/// again, which is the retry docs/55 §4 exists to make correct rather than to be travelled.
///
/// `nil` for a zero length, which every door uses for "there is nothing here". A caller for whom
/// the empty string is a real answer coalesces it; one for whom it is not lets the `nil` through.
package func wsDelivered(
    capacity: Int,
    _ door: (UnsafeMutablePointer<UInt8>?, Int) -> Int,
) -> String? {
    var out = [UInt8](repeating: 0, count: capacity)
    var written = out.withUnsafeMutableBufferPointer { door($0.baseAddress, $0.count) }
    guard written > 0 else { return nil }
    if written > out.count {
        out = [UInt8](repeating: 0, count: written)
        written = out.withUnsafeMutableBufferPointer { door($0.baseAddress, $0.count) }
        guard written > 0, written <= out.count else { return nil }
    }
    return String(bytes: out.prefix(written), encoding: .utf8)
}

/// Lends an optional string as the `(bytes, len, present)` triple the crate reads.
///
/// The `withUnsafeBytes` scope IS the safety contract — the pointer is live for exactly the call
/// inside it — so nothing else goes in the closure.
package func withOptionalText<T>(
    _ text: String?,
    _ body: (UnsafePointer<UInt8>?, Int, Bool) -> T,
) -> T {
    guard var bytes = text.map({ Array($0.utf8) }) else { return body(nil, 0, false) }
    return bytes.withUnsafeMutableBufferPointer { buffer in
        body(buffer.baseAddress, buffer.count, true)
    }
}

/// Accumulates optional strings into ONE buffer, handing back spans into it.
///
/// One buffer means one pointer, one lifetime, one scope, where a span per string would mean a
/// nested `withUnsafeBytes` per element. The crate bounds-checks every span, so a caller that got
/// the arithmetic wrong reads as "no key" rather than reading someone else's memory.
package struct WsStrings {
    package private(set) var bytes: [UInt8] = []

    package static let absent = SlopDeskWsSpan(offset: 0, len: 0, present: false)

    package init() {}

    package mutating func span(_ text: String?) -> SlopDeskWsSpan {
        guard let text else { return Self.absent }
        let offset = bytes.count
        bytes.append(contentsOf: text.utf8)
        return SlopDeskWsSpan(offset: offset, len: bytes.count - offset, present: true)
    }
}

/// Reads a `(out, cap) -> needed` answer, with the retry docs/55 §4 describes.
///
/// `nil` is "no answer", which is not the empty answer: an absent project key and a blank one are
/// different facts about a pane, and so are a pane with no last command and one whose last command
/// was blank. A door whose empty answer is REAL — the at-root idle shell's yielded title — says so
/// where it is declared, and its caller maps `nil` to `""` there rather than here.
package func wsAnswer(_ call: (UnsafeMutablePointer<UInt8>?, Int) -> Int) -> String? {
    let bytes = wsAnswerBytes(call)
    guard !bytes.isEmpty else { return nil }
    return String(bytes: bytes, encoding: .utf8)
}

/// The same read for an answer that is not ONE string — two run together, or bytes with a shape.
///
/// Empty is the no-answer, which every door reading this way already spells `0`; a caller that
/// needs to tell a blank answer from an absent one takes the second size the door hands back.
package func wsAnswerBytes(_ call: (UnsafeMutablePointer<UInt8>?, Int) -> Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: 256)
    var needed = out.withUnsafeMutableBufferPointer { call($0.baseAddress, $0.count) }
    if needed > out.count {
        out = [UInt8](repeating: 0, count: needed)
        needed = out.withUnsafeMutableBufferPointer { call($0.baseAddress, $0.count) }
    }
    guard needed > 0, needed <= out.count else { return [] }
    return Array(out[0..<needed])
}

/// The `count` `[UInt32 big-endian length][UTF-8 bytes]` runs in a group delivery, padded with
/// empties if it came up short.
///
/// The one reader for the group-delivery idiom every catalogue door now uses: one crossing for a
/// set of strings that are always wanted together, because a door per string was measured too
/// expensive inside a SwiftUI body. Four faces had each written this loop out — the settings
/// catalogue, the settings layout, the rail rows and the link island — and four copies of a cursor
/// walk is four places for an off-by-one to live.
///
/// PADDING rather than trusting the length: a short delivery means the door and the reader disagree
/// about the layout, and the alternative is a silent off-by-one where every run after the gap wears
/// its neighbour's words.
///
/// The producers are all `slopdesk_workspace`, so these bytes are a Rust `String`'s or a `format!`
/// over two of them and cannot be invalid UTF-8. A failable decode would add a branch meaning "this
/// run has no text", which is a wrong answer rather than a cautious one.
package func wsRuns(_ blob: [UInt8], count: Int) -> [String] {
    var runs: [String] = []
    runs.reserveCapacity(count)
    var cursor = blob.startIndex
    while runs.count < count, blob.distance(from: cursor, to: blob.endIndex) >= 4 {
        var length = 0
        for offset in 0..<4 { length = length << 8 | Int(blob[cursor + offset]) }
        cursor += 4
        guard blob.distance(from: cursor, to: blob.endIndex) >= length else { break }
        // swiftlint:disable:next optional_data_string_conversion
        runs.append(String(decoding: blob[cursor..<(cursor + length)], as: UTF8.self))
        cursor += length
    }
    while runs.count < count { runs.append("") }
    return runs
}

/// The sidebar's draw order for a list of things that each belong to a project — where each one
/// lands, and in which section. `slopdesk_workspace::rail_list::plan`.
///
/// `tabRanks[i]` is where element `i`'s TAB sits in the display order, which is the within-section
/// order; a list that IS its own order passes its own indices. Every element comes back exactly
/// once, so a caller can rebuild its array from the answer without checking for a hole.
package func wsRailPlan(keys: [String?], tabRanks: [Int]) -> [(element: Int, section: Int)] {
    guard !keys.isEmpty else { return [] }
    var strings = WsStrings()
    var rows = keys.enumerated().map { index, key in
        SlopDeskWsRailPlanRow(
            project_key: strings.span(key),
            // A rank the caller did not supply is an element whose tab is not in the order at all,
            // which sorts last rather than first.
            tab_rank: tabRanks.indices.contains(index) ? tabRanks[index] : Int.max,
        )
    }
    var blob = strings.bytes
    var out = [SlopDeskWsRailPlacement](
        repeating: SlopDeskWsRailPlacement(row_index: 0, section: 0), count: keys.count,
    )
    let written = blob.withUnsafeMutableBufferPointer { text in
        rows.withUnsafeMutableBufferPointer { planned in
            out.withUnsafeMutableBufferPointer { placements in
                slopdesk_ws_rail_plan(
                    planned.baseAddress, planned.count, text.baseAddress, text.count,
                    placements.baseAddress, placements.count,
                )
            }
        }
    }
    guard written == keys.count else { return [] }
    return out.map { (element: $0.row_index, section: $0.section) }
}

// MARK: - The document's canonical order

/// Where each of `keys` places in the wire's emission order — `answer[i]` indexes the key that
/// comes `i`-th. `slopdesk_wire::document::state::canonical_order`.
///
/// The order is the far side's by construction: its document is a `BTreeMap` whose key order IS the
/// emission order. This side's document is a `Dictionary`, which has none, so it has to ask — and
/// asking is the point. The Swift copy was a hand-written `Comparable` that materialised a fresh
/// 16-byte `[UInt8]` per SIDE per comparison, so one `sortedEntries` over a 24-pane document ran
/// ~8,600 heap allocations to answer a question about eighteen bytes at a time.
///
/// Measured, `swiftc -O` against the shipped xcframework, two runs agreeing inside 4%, at 480 cells
/// (24 panes): the sort alone went **1,018 µs → 23 µs**, and `sortedEntries` end to end
/// **1,075 µs → 77 µs**. The crossing is one; what it deleted is the allocation, per `docs/55` §4c.
///
/// A short answer is refused whole rather than applied in part: a half-permuted document would
/// emit some cells twice and others never, which is worse than the arrival order this falls back to.
package func wsKeyOrder(_ keys: [WorkspaceKey]) -> [Int] {
    guard !keys.isEmpty else { return [] }
    var flat = keys.map { key in
        SlopDeskWsDocKey(kind: key.kind, field: key.field, object: SlopDeskWsUuid(key.objectID))
    }
    // The size is the arithmetic BOUND, not a guess — every key handed in places exactly once — so
    // the §4 retry is unreachable here rather than merely rare.
    var out = [UInt32](repeating: 0, count: keys.count)
    let written = flat.withUnsafeMutableBufferPointer { input in
        out.withUnsafeMutableBufferPointer { places in
            slopdesk_ws_key_order(input.baseAddress, input.count, places.baseAddress, places.count)
        }
    }
    guard written == keys.count else { return Array(keys.indices) }
    return out.map(Int.init)
}

// MARK: - The one ranking every search field asks

/// Where one candidate placed in a search field's list.
package struct WsRanked {
    /// Its index in the array the caller passed in.
    package let candidate: Int
    /// Which of its fields matched; 0 is the most important, and a lower tier always wins.
    package let tier: Int
    /// The fzf score within that tier.
    package let score: Int
    /// The scalar offsets the query matched, ascending — empty for every row but the ones that
    /// matched the tier the caller said it would underline.
    package let positions: [Int]
}

/// Every candidate that matches `query`, best first. `slopdesk_workspace::search_rank::rank`.
///
/// `fields` is ONE flat array holding `stride` fields per candidate in priority order — a search
/// field with one searchable string and one with three differ by that number, not by having two
/// rankings. `underlining` names the one tier the caller draws large; `nil` asks for no highlight
/// at all, which is the matcher's cheap path.
package func wsSearchRank(
    query: String,
    fields: [String?],
    stride: Int,
    underlining tier: Int?,
) -> [WsRanked] {
    let candidateCount = stride > 0 ? fields.count / stride : 0
    guard candidateCount > 0 else { return [] }
    var strings = WsStrings()
    var spans = fields.map { strings.span($0) }
    let inputs = SlopDeskWsSearchRankInputs(
        candidate_count: candidateCount,
        stride: stride,
        positions_wanted: tier != nil,
        positions_tier: tier ?? 0,
    )
    var blob = strings.bytes
    var needle = Array(query.utf8)
    var out = [SlopDeskWsSearchRanked](
        repeating: SlopDeskWsSearchRanked(
            candidate: 0, tier: 0, score: 0, position_offset: 0, position_count: 0,
        ),
        count: candidateCount,
    )
    // Both guesses are the arithmetic BOUND, not an estimate: no more rows can match than were
    // offered, and a match carries exactly one offset per query scalar. The retry below is docs/55
    // §4's, kept because a size the caller derived is still a size the caller could get wrong.
    var positions = [UInt32](
        repeating: 0, count: tier == nil ? 0 : candidateCount * query.unicodeScalars.count,
    )
    var needed = 0
    func ask() -> Int {
        blob.withUnsafeMutableBufferPointer { text in
            needle.withUnsafeMutableBufferPointer { typed in
                spans.withUnsafeMutableBufferPointer { held in
                    out.withUnsafeMutableBufferPointer { placed in
                        positions.withUnsafeMutableBufferPointer { runs in
                            slopdesk_ws_search_rank(
                                inputs, held.baseAddress, text.baseAddress, text.count,
                                typed.baseAddress, typed.count, placed.baseAddress, placed.count,
                                runs.baseAddress, runs.count, &needed,
                            )
                        }
                    }
                }
            }
        }
    }
    var matched = ask()
    if matched > out.count || needed > positions.count {
        out = [SlopDeskWsSearchRanked](
            repeating: SlopDeskWsSearchRanked(
                candidate: 0, tier: 0, score: 0, position_offset: 0, position_count: 0,
            ),
            count: matched,
        )
        positions = [UInt32](repeating: 0, count: needed)
        matched = ask()
    }
    guard matched <= out.count, needed <= positions.count else { return [] }
    return out.prefix(matched).map { row in
        let start = row.position_offset
        let end = start + row.position_count
        let run = end <= positions.count ? positions[start..<end] : positions[0..<0]
        return WsRanked(
            candidate: row.candidate, tier: row.tier, score: Int(row.score),
            positions: run.map(Int.init),
        )
    }
}

/// `elements` ordered by how well each one's searchable text answers `query`, misses dropped.
///
/// The shape four overlays used to spell out for themselves: score, drop the misses, order by score
/// with arrival breaking ties. A blank query is the list in its own order, which is a search field's
/// zero state. An element with nothing to be found by passes `""` — a real query cannot match it, a
/// blank one leaves it where it is, and neither needs a rule of its own.
package func wsSearchRanked<Element>(
    _ elements: [Element],
    query: String,
    searchText: (Element) -> String,
) -> [Element] {
    wsSearchRank(query: query, fields: elements.map(searchText), stride: 1, underlining: nil)
        .compactMap { placed in
            elements.indices.contains(placed.candidate) ? elements[placed.candidate] : nil
        }
}

/// The most rows a search field hands back, however many matched.
///
/// Asked for rather than transcribed: a copy that drifted would let one surface build rows the one
/// beside it capped away.
package var wsMaxSearchResults: Int { slopdesk_ws_max_search_results() }

// MARK: - The split tree's walk

/// The pre-order walk a ``SplitNode`` crosses the boundary as, in both directions.
///
/// Not the persisted JSON, which both languages already agree on: these ops run on a gesture, and a
/// parse plus an allocation per frame is the regression `CLAUDE.md` says vetoes a port. One array,
/// one pass. ``decode(_:)`` is the exact inverse of ``walk(_:)`` — the existing tree tests compare
/// whole `SplitNode` values, so a lossy leg fails loudly rather than quietly rounding a divider.
package enum WsTree {
    /// The tree flattened, each node carrying the share it holds WITHIN ITS PARENT — a `SplitNode`
    /// does not know its own share, its parent's ``WeightedChild`` slot does. The root's is ignored.
    package static func walk(_ root: SplitNode) -> [SlopDeskWsTreeNode] {
        var nodes: [SlopDeskWsTreeNode] = []
        append(root, weight: .flex(1), to: &nodes)
        return nodes
    }

    /// Rebuilds a tree from a walk, or `nil` if the walk is truncated or claims more children than it
    /// carries. Total over any array of nodes — a malformed walk is refused, never trapped on.
    static func decode(_ nodes: [SlopDeskWsTreeNode]) -> SplitNode? {
        var cursor = 0
        return build(nodes, &cursor)
    }

    /// Runs one tree-answering op with the retry docs/55 §4 describes. `nil` when the op did not
    /// apply — which the crate spells as `SIZE_MAX`, a different answer from a tree of zero nodes.
    static func op(
        _ root: SplitNode,
        _ call: (UnsafeMutableBufferPointer<SlopDeskWsTreeNode>, UnsafeMutablePointer<SlopDeskWsTreeNode>?, Int) -> Int,
    ) -> SplitNode? {
        var input = walk(root)
        return input.withUnsafeMutableBufferPointer { nodes -> SplitNode? in
            let empty = SlopDeskWsTreeNode()
            // A split adds at most one node and a removal never adds any, so the input's own length
            // plus a slot fits every op here without a second call.
            var out = [SlopDeskWsTreeNode](repeating: empty, count: nodes.count + 2)
            var needed = out.withUnsafeMutableBufferPointer { call(nodes, $0.baseAddress, $0.count) }
            if needed == Int(bitPattern: UInt.max) { return nil }
            if needed > out.count {
                out = [SlopDeskWsTreeNode](repeating: empty, count: needed)
                needed = out.withUnsafeMutableBufferPointer { call(nodes, $0.baseAddress, $0.count) }
            }
            guard needed <= out.count else { return nil }
            return decode(Array(out[0..<needed]))
        }
    }

    /// Reads a walk from a call that BUILDS one rather than transforming one, with the retry
    /// docs/55 §4 describes. Empty when the call did not apply, which decodes to `nil`.
    static func answer(_ call: (UnsafeMutablePointer<SlopDeskWsTreeNode>?, Int) -> Int) -> [SlopDeskWsTreeNode] {
        let empty = SlopDeskWsTreeNode()
        var out = [SlopDeskWsTreeNode](repeating: empty, count: 32)
        var needed = out.withUnsafeMutableBufferPointer { call($0.baseAddress, $0.count) }
        if needed == Int(bitPattern: UInt.max) { return [] }
        if needed > out.count {
            out = [SlopDeskWsTreeNode](repeating: empty, count: needed)
            needed = out.withUnsafeMutableBufferPointer { call($0.baseAddress, $0.count) }
        }
        guard needed > 0, needed <= out.count else { return [] }
        return Array(out[0..<needed])
    }

    // MARK: Marshalling

    private static func append(_ node: SplitNode, weight: SplitWeight, to nodes: inout [SlopDeskWsTreeNode]) {
        switch node {
        case let .leaf(id):
            nodes.append(SlopDeskWsTreeNode(
                kind: 0,
                id: id.ffi,
                axis: 0,
                weight_is_fixed: weight.isFixed,
                child_count: 0,
                weight: weight.magnitude,
            ))
        case let .split(id, axis, children):
            nodes.append(SlopDeskWsTreeNode(
                kind: 1,
                id: SlopDeskWsUuid(id.raw),
                axis: axis == .vertical ? 1 : 0,
                weight_is_fixed: weight.isFixed,
                child_count: UInt32(children.count),
                weight: weight.magnitude,
            ))
            for child in children {
                append(child.node, weight: child.weight, to: &nodes)
            }
        }
    }

    private static func build(_ nodes: [SlopDeskWsTreeNode], _ cursor: inout Int) -> SplitNode? {
        guard cursor < nodes.count else { return nil }
        let node = nodes[cursor]
        cursor += 1
        guard node.kind == 1 else { return .leaf(PaneID(ffi: node.id)) }
        var children: [WeightedChild] = []
        children.reserveCapacity(Int(node.child_count))
        for _ in 0..<node.child_count {
            // The child's own share is on the child's node, so it is read before recursing past it.
            guard cursor < nodes.count else { return nil }
            let share = nodes[cursor].share
            guard let subtree = build(nodes, &cursor) else { return nil }
            children.append(WeightedChild(weight: share, node: subtree))
        }
        return .split(
            id: SplitNodeID(raw: node.id.uuid),
            axis: node.axis == 1 ? .vertical : .horizontal,
            children: children,
        )
    }
}

extension SlopDeskWsTreeNode {
    /// The share this node holds within its parent.
    var share: SplitWeight { weight_is_fixed ? .fixed(weight) : .flex(weight) }
}
