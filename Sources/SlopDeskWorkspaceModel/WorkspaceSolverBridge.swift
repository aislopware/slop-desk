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
    init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height)
    }

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

extension SlopDeskWsPoint {
    init(_ point: CGPoint) {
        self.init(x: point.x, y: point.y)
    }

    var point: CGPoint { CGPoint(x: x, y: y) }
}

extension PaneID {
    var ffi: SlopDeskWsUuid { SlopDeskWsUuid(raw) }
    init(ffi: SlopDeskWsUuid) { self.init(raw: ffi.uuid) }
}

extension TabID {
    var ffi: SlopDeskWsUuid { SlopDeskWsUuid(raw) }
    init(ffi: SlopDeskWsUuid) { self.init(raw: ffi.uuid) }
}

extension ResizeAnchor {
    /// The CASE index — the crate's enum order, pinned by `scripts/check-supervisor.sh`.
    var ffiByte: UInt8 {
        switch self {
        case .topLeft: 0
        case .top: 1
        case .topRight: 2
        case .left: 3
        case .right: 4
        case .bottomLeft: 5
        case .bottom: 6
        case .bottomRight: 7
        }
    }
}

extension FocusDirection {
    /// The CASE index — the crate's enum order, pinned by `scripts/check-supervisor.sh`.
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
func wsTransform(
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

/// Lends an optional string as the `(bytes, len, present)` triple the crate reads.
///
/// The `withUnsafeBytes` scope IS the safety contract — the pointer is live for exactly the call
/// inside it — so nothing else goes in the closure.
func withOptionalText<T>(
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
struct WsStrings {
    private(set) var bytes: [UInt8] = []

    static let absent = SlopDeskWsSpan(offset: 0, len: 0, present: false)

    mutating func span(_ text: String?) -> SlopDeskWsSpan {
        guard let text else { return Self.absent }
        let offset = bytes.count
        bytes.append(contentsOf: text.utf8)
        return SlopDeskWsSpan(offset: offset, len: bytes.count - offset, present: true)
    }
}

// MARK: - The split tree's walk

/// The pre-order walk a ``SplitNode`` crosses the boundary as, in both directions.
///
/// Not the persisted JSON, which both languages already agree on: these ops run on a gesture, and a
/// parse plus an allocation per frame is the regression `CLAUDE.md` says vetoes a port. One array,
/// one pass. ``decode(_:)`` is the exact inverse of ``walk(_:)`` — the existing tree tests compare
/// whole `SplitNode` values, so a lossy leg fails loudly rather than quietly rounding a divider.
enum WsTree {
    /// The tree flattened, each node carrying the share it holds WITHIN ITS PARENT — a `SplitNode`
    /// does not know its own share, its parent's ``WeightedChild`` slot does. The root's is ignored.
    static func walk(_ root: SplitNode) -> [SlopDeskWsTreeNode] {
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
