import Foundation

// MARK: - Ops

/// The topology changes a client may ASK for (docs/45 §5.4). The raw value is the `op` byte inside a
/// type-17 `intent` request, so these numbers are frozen once a golden vector carries one.
///
/// Every one maps onto a pure `WorkspaceTreeOps` static that already exists — that reuse is the whole
/// implementation lever, and it is why this layer is validation rather than logic.
public enum WorkspaceIntentOp: UInt8, Sendable, CaseIterable {
    /// The legacy one-shot: a client uploads its own tree to a host whose document is untouched.
    case adoptWorkspace = 0
    case renamePane = 1
    case renameTab = 2
    case renameSession = 3
    case closePane = 4
    case closeTab = 5
    case splitPane = 6
    case movePane = 7
    case reorderTabs = 8
    case focusTab = 9
    case focusPane = 10
    case setSyncInput = 11
    case spawnPane = 12
    case spawnTab = 13
    case setZoom = 14
    case detachPane = 15
    case reattachPane = 16
    /// The ONLY writer of `splitNode/weight`.
    case setDividerWeight = 17
    case newSession = 18
    case closeSession = 19
    case reopenClosedTab = 20
}

// MARK: - Outcome

/// What one intent did.
///
/// A model-local enum rather than the protocol's `WorkspaceIntentStatus` because this target has ZERO
/// package dependencies — that is the constraint that lets hostd import it at all. The host maps one
/// onto the other at the wire edge, which is the only place the two need to agree.
public enum WorkspaceIntentOutcome: Equatable, Sendable {
    /// The desired state now holds. Reported even when nothing CHANGED: focusing an already-focused
    /// pane is a satisfied request, and a state-transfer system has no business distinguishing them —
    /// that is also what makes a duplicated intent free.
    case applied(WorkspaceTopology)
    /// A bootstrap that arrived too late: the document has already been touched.
    case rejectedStale
    /// Well-formed but not allowed — a malformed payload, a proposed id already in use, a structure
    /// that would breach the depth cap or break the specs invariant.
    case rejectedInvalid
    /// A referenced pane / tab / session is not in the document.
    case rejectedNotFound
    case unknownOp

    public var topology: WorkspaceTopology? {
        guard case let .applied(topology) = self else { return nil }
        return topology
    }
}

// MARK: - Arguments

/// The per-op argument payloads, hand-rolled big-endian like everything else that crosses the wire.
///
/// `WorkspaceTreeOps` is exercised today only from the client's `@MainActor` store with trusted local
/// input. Running it inside a host actor exposes it to a network peer, so every payload here is
/// validate-then-drop: counts bounded before allocating, strings strict UTF-8 and capped, no field
/// force-unwrapped, and — the part the tree ops have never needed — every referenced id checked
/// against the document before the op runs.
public enum WorkspaceIntentArgs {
    /// Cap on a name a client may set. Long enough for any real title, short enough that a peer
    /// cannot make the host retain megabytes per rename.
    public static let maxNameBytes = 512
    /// Cap on a `reorderTabs` list. Real sessions have single-digit tab counts.
    public static let maxTabCount = 4096

    // MARK: Encode

    public static func encode(pane: PaneID) -> Data { WorkspaceStateCodec.encodeUUID(pane.raw) }
    public static func encode(tab: TabID) -> Data { WorkspaceStateCodec.encodeUUID(tab.raw) }
    public static func encode(session: SessionID) -> Data { WorkspaceStateCodec.encodeUUID(session.raw) }

    public static func encode(id: UUID, name: String) -> Data {
        var out = WorkspaceStateCodec.encodeUUID(id)
        out.append(encodeName(name))
        return out
    }

    public static func encode(id: UUID, flag: Bool) -> Data {
        var out = WorkspaceStateCodec.encodeUUID(id)
        out.append(flag ? 1 : 0)
        return out
    }

    /// `splitPane` / `spawnPane`: `[16B target][u8 axis][u8 before][16B newPane][u16 len][spawnCwd]`.
    ///
    /// The NEW pane's id is PROPOSED BY THE CLIENT, not minted by the host. docs/45 has the client
    /// learn it back from the resulting diff; proposing is strictly better and the reason is latency:
    /// an optimistic overlay cannot insert a leaf it has no id for, so a host-minted id makes every
    /// split wait a round trip before anything appears. It also makes a retried intent idempotent.
    /// The host still decides — a proposed id already in use is `rejectedInvalid`.
    public static func encode(
        target: UUID,
        axis: SplitAxis,
        before: Bool,
        newPane: PaneID,
        spawnCwd: String?,
    ) -> Data {
        var out = WorkspaceStateCodec.encodeUUID(target)
        out.append(axis == .horizontal ? 0 : 1)
        out.append(before ? 1 : 0)
        out.append(WorkspaceStateCodec.encodeUUID(newPane.raw))
        out.append(encodeName(spawnCwd ?? ""))
        return out
    }

    /// `movePane`: `[16B source][16B target][u8 axis][u8 before]`.
    public static func encode(source: PaneID, target: PaneID, axis: SplitAxis, before: Bool) -> Data {
        var out = WorkspaceStateCodec.encodeUUID(source.raw)
        out.append(WorkspaceStateCodec.encodeUUID(target.raw))
        out.append(axis == .horizontal ? 0 : 1)
        out.append(before ? 1 : 0)
        return out
    }

    /// `reorderTabs`: `[16B session][u16 n][16B tab]*`.
    public static func encode(session: SessionID, tabOrder: [TabID]) -> Data {
        var out = WorkspaceStateCodec.encodeUUID(session.raw)
        out.append(WorkspaceStateCodec.encodeUUIDList(tabOrder.map(\.raw)))
        return out
    }

    /// `spawnTab`: `[16B session][16B newPane][u8 position][u16 len][spawnCwd]`.
    public static func encode(
        session: SessionID,
        newPane: PaneID,
        position: NewTabPosition,
        spawnCwd: String?,
    ) -> Data {
        var out = WorkspaceStateCodec.encodeUUID(session.raw)
        out.append(WorkspaceStateCodec.encodeUUID(newPane.raw))
        out.append(positionByte(position))
        out.append(encodeName(spawnCwd ?? ""))
        return out
    }

    /// `newSession`: `[16B session][16B newPane][u16 len][name]`.
    public static func encode(newSession: SessionID, newPane: PaneID, name: String) -> Data {
        var out = WorkspaceStateCodec.encodeUUID(newSession.raw)
        out.append(WorkspaceStateCodec.encodeUUID(newPane.raw))
        out.append(encodeName(name))
        return out
    }

    /// `setDividerWeight`: `[16B split][u16 leadingIndex][u64 BE Double.bitPattern]`.
    ///
    /// The leading weight only — the op is sum-preserving, so naming the trailing one too would let a
    /// hostile pair sum to something the solver has to repair anyway.
    public static func encode(split: SplitNodeID, leadingIndex: Int, leadingWeight: Double) -> Data {
        var out = WorkspaceStateCodec.encodeUUID(split.raw)
        let index = UInt16(truncatingIfNeeded: max(0, leadingIndex))
        out.append(UInt8(truncatingIfNeeded: index >> 8))
        out.append(UInt8(truncatingIfNeeded: index))
        let bits = leadingWeight.bitPattern
        for shift in stride(from: 56, through: 0, by: -8) {
            out.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift)))
        }
        return out
    }

    private static func encodeName(_ name: String) -> Data {
        let bytes = WorkspaceStateCodec.encodeString(name, maxBytes: maxNameBytes)
        var out = Data([UInt8(truncatingIfNeeded: bytes.count >> 8), UInt8(truncatingIfNeeded: bytes.count)])
        out.append(bytes)
        return out
    }

    static func positionByte(_ position: NewTabPosition) -> UInt8 {
        switch position {
        case .auto: 0
        case .end: 1
        case .afterCurrent: 2
        }
    }

    static func position(for byte: UInt8) -> NewTabPosition {
        switch byte {
        case 1: .end
        case 2: .afterCurrent
        // An unknown byte from a newer client is `.auto` — the position the user's own preference
        // resolves, which is the least surprising place for a tab to land.
        default: .auto
        }
    }

    // MARK: Decode

    /// A bounds-checked cursor. Every read validates BEFORE it advances, so a truncated payload
    /// produces `nil` rather than a trap or an over-allocation.
    struct Reader {
        private let bytes: [UInt8]
        private var offset = 0

        init(_ data: Data) { bytes = [UInt8](data) }

        var remaining: Int { bytes.count - offset }
        var isAtEnd: Bool { remaining == 0 }

        mutating func u8() -> UInt8? {
            guard remaining >= 1 else { return nil }
            defer { offset += 1 }
            return bytes[offset]
        }

        /// C-style bool discipline on a byte that crossed the network: any non-zero is `true`.
        mutating func bool() -> Bool? {
            guard let byte = u8() else { return nil }
            return byte != 0
        }

        mutating func u16() -> Int? {
            guard let high = u8(), let low = u8() else { return nil }
            return Int((UInt16(high) << 8) | UInt16(low))
        }

        mutating func u64() -> UInt64? {
            var value: UInt64 = 0
            for _ in 0..<8 {
                guard let byte = u8() else { return nil }
                value = (value << 8) | UInt64(byte)
            }
            return value
        }

        mutating func uuid() -> UUID? {
            guard remaining >= 16 else { return nil }
            let slice = Data(bytes[offset..<offset + 16])
            offset += 16
            return WorkspaceStateCodec.decodeUUID(slice)
        }

        mutating func axis() -> SplitAxis? {
            guard let byte = u8() else { return nil }
            return byte == 0 ? .horizontal : .vertical
        }

        /// A length-prefixed string. Over-long is MALFORMED, never clamped: silently truncating a
        /// field a peer over-declared hides a framing bug behind a plausible value.
        mutating func name() -> String? {
            guard let length = u16(), length <= maxNameBytes, remaining >= length else { return nil }
            let slice = Data(bytes[offset..<offset + length])
            offset += length
            return WorkspaceStateCodec.decodeString(slice)
        }

        mutating func uuidList() -> [UUID]? {
            guard let count = u16(), count <= maxTabCount, remaining >= count * 16 else { return nil }
            var out: [UUID] = []
            out.reserveCapacity(count)
            for _ in 0..<count {
                guard let id = uuid() else { return nil }
                out.append(id)
            }
            return out
        }
    }
}
