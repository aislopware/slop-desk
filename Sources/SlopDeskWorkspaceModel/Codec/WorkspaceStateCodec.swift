import Foundation

// MARK: - Errors

/// Decode failures. Every one is a DROP, never a trap: this codec reads bytes a network peer sent.
public enum WorkspaceCodecError: Error, Equatable, Sendable {
    /// Truncated, over-long, or otherwise self-inconsistent framing.
    case malformedBody
    /// A `layoutStructure` nested past ``SplitNode/maxDepth``.
    case depthExceeded
}

// MARK: - Layout structure

/// The tab's pane-tree SHAPE, weights deliberately excluded.
///
/// Weights ride as their own `splitNode/weight` entries so two clients dragging two DIFFERENT
/// dividers write two different keys and cannot clobber each other (docs/45 §5.3). Putting them in
/// this blob would make every divider drag rewrite the whole structure.
public indirect enum WorkspaceLayoutNode: Equatable, Sendable {
    case leaf(PaneID)
    case split(id: SplitNodeID, axis: SplitAxis, children: [Self])
}

// MARK: - Reader

/// A bounds-checked cursor over untrusted bytes. Every read validates BEFORE it advances, so a
/// truncated frame produces `malformedBody` rather than a trap or an over-allocation.
private struct ByteReader {
    let bytes: [UInt8]
    var offset = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var remaining: Int { bytes.count - offset }

    mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw WorkspaceCodecError.malformedBody }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw WorkspaceCodecError.malformedBody }
        defer { offset += 4 }
        return (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }

    mutating func uuid() throws -> UUID {
        guard remaining >= 16 else { throw WorkspaceCodecError.malformedBody }
        defer { offset += 16 }
        let b = bytes
        let o = offset
        return UUID(uuid: (
            b[o], b[o + 1], b[o + 2], b[o + 3], b[o + 4], b[o + 5], b[o + 6], b[o + 7],
            b[o + 8], b[o + 9], b[o + 10], b[o + 11], b[o + 12], b[o + 13], b[o + 14], b[o + 15],
        ))
    }

    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw WorkspaceCodecError.malformedBody }
        defer { offset += count }
        return Data(bytes[offset..<offset + count])
    }
}

private extension [UInt8] {
    mutating func appendBE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func append(uuid: UUID) {
        let u = uuid.uuid
        append(contentsOf: [
            u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
            u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15,
        ])
    }
}

// MARK: - Codec

/// Manual big-endian binary codec for the workspace document (docs/45 §5.3). A caseless-enum
/// namespace, shaped like `MetadataCodec`: the wire ENVELOPE (types 17/37) lives in
/// `SlopDeskProtocol` carrying an opaque payload, and this — which needs the model types — encodes
/// what rides inside it.
///
/// Every decode is validate-then-drop: counts are checked against the bytes actually remaining
/// BEFORE any `reserveCapacity`, no field is force-unwrapped, and the recursion depth cap is checked
/// before descending rather than after.
public enum WorkspaceStateCodec {
    /// Upper bound on entries in one snapshot or diff. Rejects an absurd count before it can drive an
    /// allocation; the real corpus is hundreds of entries, not tens of thousands.
    public static let maxEntryCount = 65536

    // MARK: Key

    public static func encode(key: WorkspaceKey, into out: inout [UInt8]) {
        out.append(key.kind)
        out.append(uuid: key.objectID)
        out.append(key.field)
    }

    public static func encode(key: WorkspaceKey) -> Data {
        var out: [UInt8] = []
        out.reserveCapacity(WorkspaceKey.encodedSize)
        encode(key: key, into: &out)
        return Data(out)
    }

    private static func decodeKey(_ reader: inout ByteReader) throws -> WorkspaceKey {
        let kind = try reader.u8()
        let objectID = try reader.uuid()
        let field = try reader.u8()
        return WorkspaceKey(kind: kind, objectID: objectID, field: field)
    }

    // MARK: Entry

    public static func encode(entry: WorkspaceEntry, into out: inout [UInt8]) {
        encode(key: entry.key, into: &out)
        out.appendBE(UInt32(entry.value.count))
        out.append(contentsOf: entry.value)
    }

    private static func decodeEntry(_ reader: inout ByteReader) throws -> WorkspaceEntry {
        let key = try decodeKey(&reader)
        let length = try reader.u32()
        // Bound the length against the bytes ACTUALLY left before allocating — a hostile
        // `UInt32.max` must cost nothing.
        guard length <= UInt32(Int32.max), reader.remaining >= Int(length) else {
            throw WorkspaceCodecError.malformedBody
        }
        return try WorkspaceEntry(key: key, value: reader.take(Int(length)))
    }

    /// Decodes `count` entries, having first proven the buffer could plausibly hold them.
    ///
    /// An unknown `kindTag` or `field` is KEPT, not skipped. Length-prefixing makes forward
    /// tolerance free either way, but keeping is strictly stronger than the skip docs/45 §5.3
    /// proposed: a client that retains bytes it cannot yet interpret still round-trips them, so its
    /// `entries` stay byte-equal to the host's and its ack means what it says. Skipping would make an
    /// older client silently ack a state it does not hold.
    private static func decodeEntries(_ reader: inout ByteReader, count: UInt32) throws -> [WorkspaceEntry] {
        guard count <= UInt32(maxEntryCount) else { throw WorkspaceCodecError.malformedBody }
        // Cheapest possible entry is a bare key + a zero length prefix.
        let floor = WorkspaceKey.encodedSize + 4
        guard reader.remaining >= Int(count) * floor else { throw WorkspaceCodecError.malformedBody }
        var out: [WorkspaceEntry] = []
        out.reserveCapacity(Int(count))
        for _ in 0..<count { try out.append(decodeEntry(&reader)) }
        return out
    }

    // MARK: Snapshot — `[u32 entryCount][entry…]`

    public static func encodeSnapshot(_ state: HostWorkspaceState) -> Data {
        var out: [UInt8] = []
        let entries = state.sortedEntries
        out.appendBE(UInt32(entries.count))
        for entry in entries { encode(entry: entry, into: &out) }
        return Data(out)
    }

    public static func decodeSnapshot(_ data: Data) throws -> HostWorkspaceState {
        var reader = ByteReader(data)
        let count = try reader.u32()
        let entries = try decodeEntries(&reader, count: count)
        guard reader.remaining == 0 else { throw WorkspaceCodecError.malformedBody }
        return HostWorkspaceState(entries)
    }

    // MARK: Diff — `[u32 setCount][entry…][u32 delCount][key…]`

    public static func encodeDiff(_ diff: WorkspaceStateDiff) -> Data {
        var out: [UInt8] = []
        out.appendBE(UInt32(diff.sets.count))
        for entry in diff.sets { encode(entry: entry, into: &out) }
        out.appendBE(UInt32(diff.deletes.count))
        for key in diff.deletes { encode(key: key, into: &out) }
        return Data(out)
    }

    public static func decodeDiff(_ data: Data) throws -> WorkspaceStateDiff {
        var reader = ByteReader(data)
        let sets = try decodeEntries(&reader, count: reader.u32())
        let deleteCount = try reader.u32()
        guard deleteCount <= UInt32(maxEntryCount),
              reader.remaining >= Int(deleteCount) * WorkspaceKey.encodedSize
        else { throw WorkspaceCodecError.malformedBody }
        var deletes: [WorkspaceKey] = []
        deletes.reserveCapacity(Int(deleteCount))
        for _ in 0..<deleteCount { try deletes.append(decodeKey(&reader)) }
        guard reader.remaining == 0 else { throw WorkspaceCodecError.malformedBody }
        return WorkspaceStateDiff(sets: sets, deletes: deletes)
    }

    // MARK: layoutStructure — pre-order, self-describing, weights EXCLUDED

    public static func encodeLayout(_ node: WorkspaceLayoutNode) -> Data {
        var out: [UInt8] = []
        appendLayout(node, into: &out)
        return Data(out)
    }

    private static func appendLayout(_ node: WorkspaceLayoutNode, into out: inout [UInt8]) {
        switch node {
        case let .leaf(paneID):
            out.append(0)
            out.append(uuid: paneID.raw)
        case let .split(id, axis, children):
            out.append(1)
            out.append(uuid: id.raw)
            out.append(axis == .horizontal ? 0 : 1)
            // `childCount` is a u8 → fan-out is bounded at 255 by the FORMAT, before any allocation.
            out.append(UInt8(truncatingIfNeeded: children.count))
            for child in children { appendLayout(child, into: &out) }
        }
    }

    public static func decodeLayout(_ data: Data) throws -> WorkspaceLayoutNode {
        var reader = ByteReader(data)
        let node = try decodeLayoutNode(&reader, depth: 0)
        guard reader.remaining == 0 else { throw WorkspaceCodecError.malformedBody }
        return node
    }

    /// - Note: the depth cap is checked BEFORE descending, and it is the STACK-SAFETY mechanism here.
    ///   `SplitNode+Codable` can lean on `JSONDecoder`'s own nesting limit; a hand-rolled binary
    ///   decoder over network input has nothing underneath it, so an unbounded recursion would be a
    ///   remote stack overflow.
    private static func decodeLayoutNode(_ reader: inout ByteReader, depth: Int) throws -> WorkspaceLayoutNode {
        guard depth <= SplitNode.maxDepth else { throw WorkspaceCodecError.depthExceeded }
        switch try reader.u8() {
        case 0:
            return try .leaf(PaneID(raw: reader.uuid()))
        case 1:
            let id = try SplitNodeID(raw: reader.uuid())
            let axisByte = try reader.u8()
            // C-style bool discipline: any non-zero is `vertical`, never a trap on an unexpected byte.
            let axis: SplitAxis = axisByte == 0 ? .horizontal : .vertical
            let childCount = try Int(reader.u8())
            // One byte minimum per child (a bare leaf tag) — bound before reserving.
            guard reader.remaining >= childCount else { throw WorkspaceCodecError.malformedBody }
            var children: [WorkspaceLayoutNode] = []
            children.reserveCapacity(childCount)
            for _ in 0..<childCount {
                try children.append(decodeLayoutNode(&reader, depth: depth + 1))
            }
            return .split(id: id, axis: axis, children: children)
        default:
            throw WorkspaceCodecError.malformedBody
        }
    }

    // MARK: Scalar field values

    /// One weight: `[u8 weightKind][u64 BE Double.bitPattern]`.
    ///
    /// The Double rides as its raw `bitPattern`, never a re-parsed decimal — the repo's bit-exact
    /// float rule, and the same discipline the golden generator's `bytesEwmaBits` uses.
    public static func encodeWeight(_ weight: SplitWeight) -> Data {
        var out: [UInt8] = []
        appendWeight(weight, into: &out)
        return Data(out)
    }

    private static func appendWeight(_ weight: SplitWeight, into out: inout [UInt8]) {
        let bits: UInt64
        switch weight {
        case let .flex(value):
            out.append(0)
            bits = value.bitPattern
        case let .fixed(value):
            out.append(1)
            bits = value.bitPattern
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            out.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift)))
        }
    }

    public static func decodeWeight(_ data: Data) throws -> SplitWeight {
        var reader = ByteReader(data)
        let weight = try readWeight(&reader)
        guard reader.remaining == 0 else { throw WorkspaceCodecError.malformedBody }
        return weight
    }

    private static func readWeight(_ reader: inout ByteReader) throws -> SplitWeight {
        let kind = try reader.u8()
        guard reader.remaining >= 8 else { throw WorkspaceCodecError.malformedBody }
        var bits: UInt64 = 0
        for _ in 0..<8 { bits = try (bits << 8) | UInt64(reader.u8()) }
        let value = Double(bitPattern: bits)
        return kind == 0 ? .flex(value) : .fixed(value)
    }

    /// A `splitNode/weight` value: `[u8 childCount]([u8 weightKind][u64 BE bits])*` — ALL of one
    /// split's child weights, in child order.
    ///
    /// One entry per SPLIT rather than per child is what makes a divider drag atomic: the op the
    /// intent maps onto (`SplitNode.settingDividerWeight`) moves a leading/trailing PAIR, so
    /// splitting the pair across two cells would let a diff carry half a drag. Two clients dragging
    /// dividers in two DIFFERENT splits still write two different keys and cannot clobber each other,
    /// which is the conflict granularity docs/45 §5.3 is after.
    ///
    /// `childCount` is a `u8`, so the fan-out is bounded by the FORMAT — the same discipline
    /// `layoutStructure` uses, and it must stay in step with it.
    public static func encodeWeights(_ weights: [SplitWeight]) -> Data {
        var out: [UInt8] = []
        let count = min(weights.count, Int(UInt8.max))
        out.append(UInt8(truncatingIfNeeded: count))
        for weight in weights.prefix(count) { appendWeight(weight, into: &out) }
        return Data(out)
    }

    /// `nil` on any framing the bytes cannot back — a wrong-width value is a DROP, and the caller
    /// falls back to an even share rather than rendering a layout it half-understood.
    public static func decodeWeights(_ data: Data) -> [SplitWeight]? {
        var reader = ByteReader(data)
        guard let count = try? Int(reader.u8()) else { return nil }
        // Nine bytes per weight, checked before reserving: a declared 255 over an empty tail costs
        // nothing.
        guard reader.remaining == count * 9 else { return nil }
        var out: [SplitWeight] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            guard let weight = try? readWeight(&reader) else { return nil }
            out.append(weight)
        }
        return out
    }

    // MARK: Identity field values

    /// A bare `UUID` field value — `root/activeSessionID`, `tab/sessionID`, `tab/activePaneID`.
    ///
    /// An ABSENT optional is an absent KEY, never the all-zero UUID: the zero UUID is the wire's
    /// "none" in the presence records, and letting it mean the same thing here would make "no active
    /// pane" and "the pane whose id happens to be zero" the same cell.
    public static func encodeUUID(_ id: UUID) -> Data {
        var out: [UInt8] = []
        out.reserveCapacity(16)
        out.append(uuid: id)
        return Data(out)
    }

    public static func decodeUUID(_ data: Data) -> UUID? {
        guard data.count == 16 else { return nil }
        var reader = ByteReader(data)
        return try? reader.uuid()
    }

    /// `session/detachedPanes`: `[u16 n]([16B paneID][16B originTabID])*`.
    ///
    /// A detached pane with no remembered origin tab rides as the all-zero UUID — here it IS the
    /// sentinel, because a pane always has an id but its origin is genuinely optional and the pair is
    /// fixed-width.
    public static func encodeDetachedPanes(_ panes: [(pane: UUID, originTab: UUID?)]) -> Data {
        var out: [UInt8] = []
        let count = min(panes.count, Int(UInt16.max))
        out.append(UInt8(truncatingIfNeeded: count >> 8))
        out.append(UInt8(truncatingIfNeeded: count))
        for entry in panes.prefix(count) {
            out.append(uuid: entry.pane)
            out.append(uuid: entry.originTab ?? WorkspaceObjectKind.rootObjectID)
        }
        return Data(out)
    }

    public static func decodeDetachedPanes(_ data: Data) -> [(pane: UUID, originTab: UUID?)]? {
        var reader = ByteReader(data)
        guard reader.remaining >= 2, let high = try? reader.u8(), let low = try? reader.u8() else { return nil }
        let count = Int((UInt16(high) << 8) | UInt16(low))
        guard reader.remaining == count * 32 else { return nil }
        var out: [(pane: UUID, originTab: UUID?)] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            guard let pane = try? reader.uuid(), let origin = try? reader.uuid() else { return nil }
            out.append((pane, origin == WorkspaceObjectKind.rootObjectID ? nil : origin))
        }
        return out
    }

    /// `pane/videoTarget`: `[u32 windowID][u8 hasDisplay][u32 displayID][u16 titleLen][title][u16 appLen][app]`.
    ///
    /// `displayID` is optional in the model — a window-shaped endpoint has none — so it carries its
    /// own presence byte rather than overloading `0`, which is a legitimate display id (the main one).
    public static func encodeVideoTarget(_ endpoint: VideoEndpoint) -> Data {
        var out: [UInt8] = []
        out.appendBE(endpoint.windowID)
        out.append(endpoint.displayID == nil ? 0 : 1)
        out.appendBE(endpoint.displayID ?? 0)
        for text in [endpoint.title, endpoint.appName] {
            let bytes = encodeString(text)
            out.append(UInt8(truncatingIfNeeded: bytes.count >> 8))
            out.append(UInt8(truncatingIfNeeded: bytes.count))
            out.append(contentsOf: bytes)
        }
        return Data(out)
    }

    public static func decodeVideoTarget(_ data: Data) -> VideoEndpoint? {
        var reader = ByteReader(data)
        guard let windowID = try? reader.u32(),
              let hasDisplay = try? reader.u8(),
              let displayID = try? reader.u32()
        else { return nil }
        var strings: [String] = []
        for _ in 0..<2 {
            guard let high = try? reader.u8(), let low = try? reader.u8() else { return nil }
            let length = Int((UInt16(high) << 8) | UInt16(low))
            guard let bytes = try? reader.take(length), let text = decodeString(bytes) else { return nil }
            strings.append(text)
        }
        guard reader.remaining == 0 else { return nil }
        return VideoEndpoint(
            windowID: windowID,
            title: strings[0],
            appName: strings[1],
            // C-style bool discipline on a byte that crossed the network.
            displayID: hasDisplay != 0 ? displayID : nil,
        )
    }

    /// A string field value: strict UTF-8, never lossy. Clamped at a Unicode SCALAR boundary so a
    /// truncated value stays valid UTF-8 (the type-35 idiom).
    public static func encodeString(_ text: String, maxBytes: Int = 65535) -> Data {
        var out = text
        while out.utf8.count > maxBytes { out.unicodeScalars.removeLast() }
        return Data(out.utf8)
    }

    /// `nil` when the bytes are not valid UTF-8 — the caller drops the field rather than rendering
    /// replacement characters.
    public static func decodeString(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
    }

    // MARK: Fixed-width scalars

    /// A one-byte field (`titleFresh`, `commandRunning`, `liveness`, `syncInputArmed`, `userRenamed`).
    public static func encodeU8(_ value: UInt8) -> Data { Data([value]) }

    /// `nil` on any length but exactly 1 — a wrong-width value is a DROP, never a lenient prefix read.
    /// Strictness here is what stops a mis-numbered field from decoding into a plausible-looking value.
    public static func decodeU8(_ data: Data) -> UInt8? {
        data.count == 1 ? data[data.startIndex] : nil
    }

    /// C-style bool discipline: any non-zero byte is `true`, matching the interop rule the rest of the
    /// codebase uses for bytes that crossed a language or network boundary.
    public static func encodeBool(_ value: Bool) -> Data { encodeU8(value ? 1 : 0) }

    public static func decodeBool(_ data: Data) -> Bool? {
        guard let byte = decodeU8(data) else { return nil }
        return byte != 0
    }

    /// A two-byte pair — `agentState` (`[state][kind]`) and `progress` (`[state][percent]`).
    public static func encodeU8Pair(_ first: UInt8, _ second: UInt8) -> Data { Data([first, second]) }

    public static func decodeU8Pair(_ data: Data) -> (UInt8, UInt8)? {
        guard data.count == 2 else { return nil }
        let bytes = [UInt8](data)
        return (bytes[0], bytes[1])
    }

    /// A `[u16 BE][u16 BE]` pair — `pane/grid` is `(cols, rows)`, in that order.
    public static func encodeU16Pair(_ first: UInt16, _ second: UInt16) -> Data {
        Data([
            UInt8(truncatingIfNeeded: first >> 8), UInt8(truncatingIfNeeded: first),
            UInt8(truncatingIfNeeded: second >> 8), UInt8(truncatingIfNeeded: second),
        ])
    }

    public static func decodeU16Pair(_ data: Data) -> (UInt16, UInt16)? {
        guard data.count == 4 else { return nil }
        let b = [UInt8](data)
        return ((UInt16(b[0]) << 8) | UInt16(b[1]), (UInt16(b[2]) << 8) | UInt16(b[3]))
    }

    public static func encodeU32(_ value: UInt32) -> Data {
        var out: [UInt8] = []
        out.reserveCapacity(4)
        out.appendBE(value)
        return Data(out)
    }

    public static func decodeU32(_ data: Data) -> UInt32? {
        guard data.count == 4 else { return nil }
        let b = [UInt8](data)
        return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    }

    /// `pane/lastExitCode`. Rides as the `UInt32` bit pattern so a negative code (a signal-killed
    /// child) survives without a sign convention to get wrong on either end.
    public static func encodeI32(_ value: Int32) -> Data { encodeU32(UInt32(bitPattern: value)) }

    public static func decodeI32(_ data: Data) -> Int32? {
        guard let bits = decodeU32(data) else { return nil }
        return Int32(bitPattern: bits)
    }

    public static func encodeI64(_ value: Int64) -> Data {
        let bits = UInt64(bitPattern: value)
        var out: [UInt8] = []
        out.reserveCapacity(8)
        for shift in stride(from: 56, through: 0, by: -8) {
            out.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift)))
        }
        return Data(out)
    }

    public static func decodeI64(_ data: Data) -> Int64? {
        guard data.count == 8 else { return nil }
        var bits: UInt64 = 0
        for byte in data { bits = (bits << 8) | UInt64(byte) }
        return Int64(bitPattern: bits)
    }

    /// A `[u16 BE count]` list of UUIDs — `root/sessionOrder`, `session/tabOrder`, `root/closedTabRing`.
    public static func encodeUUIDList(_ ids: [UUID]) -> Data {
        var out: [UInt8] = []
        let count = UInt16(truncatingIfNeeded: min(ids.count, Int(UInt16.max)))
        out.append(UInt8(truncatingIfNeeded: count >> 8))
        out.append(UInt8(truncatingIfNeeded: count))
        for id in ids.prefix(Int(count)) { out.append(uuid: id) }
        return Data(out)
    }

    /// `nil` on a count the bytes cannot back — the length is validated against what REMAINS before
    /// any capacity is reserved, so a hostile `0xFFFF` costs nothing.
    public static func decodeUUIDList(_ data: Data) -> [UUID]? {
        var reader = ByteReader(data)
        guard reader.remaining >= 2 else { return nil }
        let high = try? reader.u8()
        let low = try? reader.u8()
        guard let high, let low else { return nil }
        let count = Int((UInt16(high) << 8) | UInt16(low))
        guard reader.remaining == count * 16 else { return nil }
        var out: [UUID] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            guard let id = try? reader.uuid() else { return nil }
            out.append(id)
        }
        return out
    }
}
