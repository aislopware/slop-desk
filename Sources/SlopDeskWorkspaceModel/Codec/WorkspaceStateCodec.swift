import CSlopDeskFFI
import Foundation
import SlopDeskArena

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
    ///
    /// Exported by the crate rather than transcribed: it is a REFUSAL threshold, so two copies would
    /// be two ideas of what counts as an absurd document, and the smaller one would reject states the
    /// other happily sends.
    public static var maxEntryCount: Int { slopdesk_ws_max_entry_count() }

    // MARK: Key

    public static func encode(key: WorkspaceKey, into out: inout [UInt8]) {
        out.append(contentsOf: encode(key: key))
    }

    public static func encode(key: WorkspaceKey) -> Data {
        wsFixed(WorkspaceKey.encodedSize) { out, cap in
            slopdesk_ws_encode_key(key.kind, SlopDeskWsUuid(key.objectID), key.field, out, cap)
        }
    }

    // MARK: Snapshot and diff

    //
    // The parsing is `rust/slopdesk-workspace`'s `state_codec` (docs/55). This is the highest-risk
    // code in the document — a count and a length, both chosen by whoever is on the other end of the
    // socket — and every bound is checked against the bytes ACTUALLY remaining before any capacity is
    // reserved. A decoded value crosses back as a SPAN into the buffer that was handed in, never a
    // copy: a snapshot is hundreds of entries and arrives on every attach.

    /// A snapshot: `[u32 entryCount][entry…]`.
    public static func encodeSnapshot(_ state: HostWorkspaceState) -> Data {
        let entries = state.sortedEntries
        var blob = WsBlob()
        var flat = entries.map { blob.entry($0) }
        return blob.lend { bytes in
            flat.withUnsafeMutableBufferPointer { input in
                wsBytes { out, cap in
                    slopdesk_ws_encode_snapshot(
                        input.baseAddress,
                        input.count,
                        bytes.baseAddress,
                        bytes.count,
                        out,
                        cap,
                    )
                }
            }
        }
    }

    /// Throws ``WorkspaceCodecError/malformedBody`` on any bytes the crate refuses — including
    /// TRAILING ones, which are malformed on purpose: a snapshot decoding to fewer entries than it
    /// carries would have the client ack a state it does not hold.
    public static func decodeSnapshot(_ data: Data) throws -> HostWorkspaceState {
        var bytes = [UInt8](data)
        let entries: [WorkspaceEntry]? = bytes.withUnsafeMutableBufferPointer { input in
            var out = [SlopDeskWsEntry](repeating: SlopDeskWsEntry(), count: 256)
            var needed = out.withUnsafeMutableBufferPointer { buffer in
                slopdesk_ws_decode_snapshot(input.baseAddress, input.count, buffer.baseAddress, buffer.count)
            }
            if needed == Int(bitPattern: UInt.max) { return nil }
            if needed > out.count {
                out = [SlopDeskWsEntry](repeating: SlopDeskWsEntry(), count: needed)
                needed = out.withUnsafeMutableBufferPointer { buffer in
                    slopdesk_ws_decode_snapshot(input.baseAddress, input.count, buffer.baseAddress, buffer.count)
                }
            }
            guard needed <= out.count else { return nil }
            return out[0..<needed].map { $0.entry(in: input) }
        }
        guard let entries else { throw WorkspaceCodecError.malformedBody }
        return HostWorkspaceState(entries)
    }

    /// A diff: `[u32 setCount][entry…][u32 delCount][key…]`.
    public static func encodeDiff(_ diff: WorkspaceStateDiff) -> Data {
        var blob = WsBlob()
        var sets = diff.sets.map { blob.entry($0) }
        var deletes = diff.deletes.map { WsBlob.key($0) }
        return blob.lend { bytes in
            sets.withUnsafeMutableBufferPointer { setBuffer in
                deletes.withUnsafeMutableBufferPointer { deleteBuffer in
                    wsBytes { out, cap in
                        slopdesk_ws_encode_diff(
                            setBuffer.baseAddress,
                            setBuffer.count,
                            deleteBuffer.baseAddress,
                            deleteBuffer.count,
                            bytes.baseAddress,
                            bytes.count,
                            out,
                            cap,
                        )
                    }
                }
            }
        }
    }

    public static func decodeDiff(_ data: Data) throws -> WorkspaceStateDiff {
        var bytes = [UInt8](data)
        let diff: WorkspaceStateDiff? = bytes.withUnsafeMutableBufferPointer { input in
            var setsNeeded = 0
            var deletesNeeded = 0
            // One call sizes BOTH halves, so a diff that is mostly deletes never costs a retry for
            // the sets it barely has.
            guard slopdesk_ws_decode_diff(
                input.baseAddress, input.count, nil, 0, nil, 0, &setsNeeded, &deletesNeeded,
            ) else { return nil }
            var sets = [SlopDeskWsEntry](repeating: SlopDeskWsEntry(), count: max(1, setsNeeded))
            var deletes = [SlopDeskWsEntry](repeating: SlopDeskWsEntry(), count: max(1, deletesNeeded))
            let decoded = sets.withUnsafeMutableBufferPointer { setBuffer in
                deletes.withUnsafeMutableBufferPointer { deleteBuffer in
                    slopdesk_ws_decode_diff(
                        input.baseAddress,
                        input.count,
                        setBuffer.baseAddress,
                        setsNeeded,
                        deleteBuffer.baseAddress,
                        deletesNeeded,
                        &setsNeeded,
                        &deletesNeeded,
                    )
                }
            }
            guard decoded else { return nil }
            return WorkspaceStateDiff(
                sets: sets[0..<setsNeeded].map { $0.entry(in: input) },
                deletes: deletes[0..<deletesNeeded].map(\.workspaceKey),
            )
        }
        guard let diff else { throw WorkspaceCodecError.malformedBody }
        return diff
    }

    // MARK: layoutStructure — pre-order, self-describing, weights EXCLUDED

    //
    // The codec is `rust/slopdesk-workspace`'s `state_codec` (docs/55), and the decoder there is
    // ITERATIVE where this one recursed. A depth cap checked before descending is correct, but it is
    // one forgotten check away from a remote stack overflow on network input; walking a flat array
    // with an explicit frame stack makes the overflow structurally impossible, and the cap goes back
    // to being a statement about documents rather than the thing keeping the decoder safe.

    public static func encodeLayout(_ node: WorkspaceLayoutNode) -> Data {
        var walk: [SlopDeskWsLayoutNode] = []
        appendLayout(node, into: &walk)
        return walk.withUnsafeMutableBufferPointer { input in
            wsBytes { out, cap in
                slopdesk_ws_encode_layout(input.baseAddress, input.count, out, cap)
            }
        }
    }

    private static func appendLayout(_ node: WorkspaceLayoutNode, into walk: inout [SlopDeskWsLayoutNode]) {
        switch node {
        case let .leaf(paneID):
            walk.append(SlopDeskWsLayoutNode(kind: 0, axis: 0, child_count: 0, id: SlopDeskWsUuid(paneID.raw)))
        case let .split(id, axis, children):
            walk.append(SlopDeskWsLayoutNode(
                kind: 1,
                axis: axis == .horizontal ? 0 : 1,
                // A `u8` by the FORMAT, so the fan-out is bounded before any allocation.
                child_count: UInt8(truncatingIfNeeded: children.count),
                id: SlopDeskWsUuid(id.raw),
            ))
            for child in children { appendLayout(child, into: &walk) }
        }
    }

    /// Throws on any bytes the crate refuses: an unknown tag, a truncated node, a split claiming more
    /// children than it carries, or trailing bytes — and ``WorkspaceCodecError/depthExceeded`` for a
    /// well-formed tree nested past the cap, which is a different report because it is a document
    /// this build declines to hold rather than a bug or an attack. The crate says which; the depth is
    /// no longer a property of any stack, so nothing here has to count to find out.
    public static func decodeLayout(_ data: Data) throws -> WorkspaceLayoutNode {
        var bytes = [UInt8](data)
        var tooDeep = false
        let walk: [SlopDeskWsLayoutNode]? = bytes.withUnsafeMutableBufferPointer { input in
            var out = [SlopDeskWsLayoutNode](repeating: SlopDeskWsLayoutNode(), count: 64)
            var needed = out.withUnsafeMutableBufferPointer { buffer in
                slopdesk_ws_decode_layout(input.baseAddress, input.count, buffer.baseAddress, buffer.count, &tooDeep)
            }
            if needed == Int(bitPattern: UInt.max) { return nil }
            if needed > out.count {
                out = [SlopDeskWsLayoutNode](repeating: SlopDeskWsLayoutNode(), count: needed)
                needed = out.withUnsafeMutableBufferPointer { buffer in
                    slopdesk_ws_decode_layout(
                        input.baseAddress,
                        input.count,
                        buffer.baseAddress,
                        buffer.count,
                        &tooDeep,
                    )
                }
            }
            guard needed > 0, needed <= out.count else { return nil }
            return Array(out[0..<needed])
        }
        if tooDeep { throw WorkspaceCodecError.depthExceeded }
        guard let walk else { throw WorkspaceCodecError.malformedBody }
        var cursor = 0
        guard let node = buildLayout(walk, &cursor) else { throw WorkspaceCodecError.malformedBody }
        return node
    }

    /// Rebuilds the tree from the walk the crate validated. No depth cap here: the crate already
    /// refused anything past it, so this recursion is bounded by a tree it has proven is shallow.
    private static func buildLayout(_ walk: [SlopDeskWsLayoutNode], _ cursor: inout Int) -> WorkspaceLayoutNode? {
        guard cursor < walk.count else { return nil }
        let node = walk[cursor]
        cursor += 1
        guard node.kind == 1 else { return .leaf(PaneID(raw: node.id.uuid)) }
        var children: [WorkspaceLayoutNode] = []
        children.reserveCapacity(Int(node.child_count))
        for _ in 0..<node.child_count {
            guard let child = buildLayout(walk, &cursor) else { return nil }
            children.append(child)
        }
        return .split(
            id: SplitNodeID(raw: node.id.uuid),
            axis: node.axis == 0 ? .horizontal : .vertical,
            children: children,
        )
    }

    // MARK: Scalar field values

    /// One weight: `[u8 weightKind][u64 BE Double.bitPattern]`.
    ///
    /// The Double rides as its raw `bitPattern`, never a re-parsed decimal — the repo's bit-exact
    /// float rule, and the same discipline the golden generator's `bytesEwmaBits` uses.
    public static func encodeWeight(_ weight: SplitWeight) -> Data {
        encodeWeights([weight]).dropFirst().reduce(into: Data()) { $0.append($1) }
    }

    /// Throws on any length but exactly nine — a truncated weight is a drop, never a partial read.
    public static func decodeWeight(_ data: Data) throws -> SplitWeight {
        var framed = Data([1])
        framed.append(data)
        guard let only = decodeWeights(framed)?.first else { throw WorkspaceCodecError.malformedBody }
        return only
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
        var shares = weights.map(\.ffi)
        return shares.withUnsafeMutableBufferPointer { input in
            wsBytes { out, cap in
                slopdesk_ws_encode_weights(input.baseAddress, input.count, out, cap)
            }
        }
    }

    /// `nil` on a count the bytes cannot back.
    public static func decodeWeights(_ data: Data) -> [SplitWeight]? {
        var bytes = [UInt8](data)
        return bytes.withUnsafeMutableBufferPointer { input -> [SplitWeight]? in
            var out = [SlopDeskWsShare](repeating: SlopDeskWsShare(), count: 16)
            var needed = out.withUnsafeMutableBufferPointer { buffer in
                slopdesk_ws_decode_weights(input.baseAddress, input.count, buffer.baseAddress, buffer.count)
            }
            if needed == Int(bitPattern: UInt.max) { return nil }
            if needed > out.count {
                out = [SlopDeskWsShare](repeating: SlopDeskWsShare(), count: needed)
                needed = out.withUnsafeMutableBufferPointer { buffer in
                    slopdesk_ws_decode_weights(input.baseAddress, input.count, buffer.baseAddress, buffer.count)
                }
            }
            guard needed <= out.count else { return nil }
            return out[0..<needed].map { $0.is_fixed ? .fixed($0.value) : .flex($0.value) }
        }
    }

    // MARK: Identity field values

    /// A bare `UUID` field value — `root/activeSessionID`, `tab/sessionID`, `tab/activePaneID`.
    ///
    /// An ABSENT optional is an absent KEY, never the all-zero UUID: the zero UUID is the wire's
    /// "none" in the presence records, and letting it mean the same thing here would make "no active
    /// pane" and "the pane whose id happens to be zero" the same cell.
    public static func encodeUUID(_ id: UUID) -> Data {
        withUnsafeBytes(of: SlopDeskWsUuid(id).bytes) { Data($0) }
    }

    public static func decodeUUID(_ data: Data) -> UUID? {
        var bytes = [UInt8](data)
        var answer = SlopDeskWsUuid()
        let found = bytes.withUnsafeMutableBufferPointer { input in
            slopdesk_ws_decode_uuid(input.baseAddress, input.count, &answer)
        }
        return found ? answer.uuid : nil
    }

    /// `session/detachedPanes`: `[u16 n]([16B paneID][16B originTabID])*`.
    ///
    /// A detached pane with no remembered origin tab rides as the all-zero UUID — on the WIRE it is
    /// the sentinel, because a pane always has an id but its origin is genuinely optional and the
    /// pair is fixed-width. The crate translates it back to an `Optional` at the boundary, so this
    /// side never spells absence as an id.
    public static func encodeDetachedPanes(_ panes: [(pane: UUID, originTab: UUID?)]) -> Data {
        var entries = panes.map { entry in
            SlopDeskWsDetachedPane(
                pane: SlopDeskWsUuid(entry.pane),
                origin: SlopDeskWsUuid(entry.originTab ?? WorkspaceObjectKind.rootObjectID),
                has_origin: entry.originTab != nil,
            )
        }
        return entries.withUnsafeMutableBufferPointer { input in
            wsBytes { out, cap in
                slopdesk_ws_encode_detached_panes(input.baseAddress, input.count, out, cap)
            }
        }
    }

    public static func decodeDetachedPanes(_ data: Data) -> [(pane: UUID, originTab: UUID?)]? {
        var bytes = [UInt8](data)
        return bytes.withUnsafeMutableBufferPointer { input -> [(pane: UUID, originTab: UUID?)]? in
            var out = [SlopDeskWsDetachedPane](repeating: SlopDeskWsDetachedPane(), count: 32)
            var needed = out.withUnsafeMutableBufferPointer { buffer in
                slopdesk_ws_decode_detached_panes(input.baseAddress, input.count, buffer.baseAddress, buffer.count)
            }
            if needed == Int(bitPattern: UInt.max) { return nil }
            if needed > out.count {
                out = [SlopDeskWsDetachedPane](repeating: SlopDeskWsDetachedPane(), count: needed)
                needed = out.withUnsafeMutableBufferPointer { buffer in
                    slopdesk_ws_decode_detached_panes(
                        input.baseAddress,
                        input.count,
                        buffer.baseAddress,
                        buffer.count,
                    )
                }
            }
            guard needed <= out.count else { return nil }
            return out[0..<needed].map { ($0.pane.uuid, $0.has_origin ? $0.origin.uuid : nil) }
        }
    }

    /// `pane/videoTarget`: `[u32 windowID][u8 hasDisplay][u32 displayID][u16 titleLen][title][u16 appLen][app]`.
    ///
    /// `displayID` is optional in the model — a window-shaped endpoint has none — so it carries its
    /// own presence byte rather than overloading `0`, which is a legitimate display id (the main one).
    public static func encodeVideoTarget(_ endpoint: VideoEndpoint) -> Data {
        var strings = WsStrings()
        let title = strings.span(endpoint.title)
        let app = strings.span(endpoint.appName)
        var blob = strings.bytes
        return blob.withUnsafeMutableBufferPointer { text in
            wsBytes { out, cap in
                slopdesk_ws_encode_video_target(
                    endpoint.windowID,
                    endpoint.displayID ?? 0,
                    endpoint.displayID != nil,
                    text.baseAddress,
                    text.count,
                    title,
                    app,
                    out,
                    cap,
                )
            }
        }
    }

    /// The strings come back as SPANS into `data`'s own bytes, so nothing is copied twice — they are
    /// read inside the buffer's scope and only the `String`s outlive it.
    public static func decodeVideoTarget(_ data: Data) -> VideoEndpoint? {
        var bytes = [UInt8](data)
        return bytes.withUnsafeMutableBufferPointer { input -> VideoEndpoint? in
            var answer = SlopDeskWsVideoTarget()
            guard slopdesk_ws_decode_video_target(input.baseAddress, input.count, &answer) else { return nil }
            guard let title = input.text(answer.title), let app = input.text(answer.app_name) else { return nil }
            return VideoEndpoint(
                windowID: answer.window_id,
                title: title,
                appName: app,
                displayID: answer.has_display ? answer.display_id : nil,
            )
        }
    }

    /// The longest a string field may be, ASKED for — it is a wire property, and a near side that
    /// spelled it itself would either refuse a value the far end accepts or offer one it drops. A
    /// field with a tighter limit of its own (a `renameTab` name) still passes that instead.
    public static let maxStringBytes = Int(slopdesk_ws_max_string_bytes())

    /// A string field value: strict UTF-8, never lossy. Clamped at a Unicode SCALAR boundary so a
    /// truncated value stays valid UTF-8 (the type-35 idiom).
    ///
    /// This layer is `rust/slopdesk-workspace`'s `state_codec` (docs/55). It is the one part of the
    /// document worth crossing on its own terms: every decoder below reads bytes that came off a
    /// SOCKET, and the strictness — a wrong-width value is a drop, never a lenient prefix read — is a
    /// property that has to hold identically on both ends or a mis-numbered field decodes into
    /// something plausible on one of them.
    public static func encodeString(_ text: String, maxBytes: Int = maxStringBytes) -> Data {
        Data(wsTransform(text) { bytes, len, out, cap in
            slopdesk_ws_encode_string(bytes, len, maxBytes, out, cap)
        } ?? [])
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
        wsScalar(data, UInt8(0)) { bytes, len, out in slopdesk_ws_decode_u8(bytes, len, out) }
    }

    /// C-style bool discipline: any non-zero byte is `true`, matching the interop rule the rest of the
    /// codebase uses for bytes that crossed a language or network boundary.
    public static func encodeBool(_ value: Bool) -> Data { encodeU8(value ? 1 : 0) }

    /// Asked for rather than composed. This was `decodeU8(data).map { $0 != 0 }` — one line, and
    /// still the READING of every non-canonical byte a peer can send: a side that spelled it `== 1`
    /// would answer `false` where this one answers `true`, on bytes no decode would refuse.
    public static func decodeBool(_ data: Data) -> Bool? {
        wsScalar(data, false) { bytes, len, out in slopdesk_ws_decode_bool(bytes, len, out) }
    }

    /// A two-byte pair — `agentState` (`[state][kind]`) and `progress` (`[state][percent]`).
    public static func decodeU8Pair(_ data: Data) -> (UInt8, UInt8)? {
        wsPair(data, UInt8(0)) { bytes, len, a, b in slopdesk_ws_decode_u8_pair(bytes, len, a, b) }
    }

    /// A `[u16 BE][u16 BE]` pair — `pane/grid` is `(cols, rows)`, in that order.
    public static func decodeU16Pair(_ data: Data) -> (UInt16, UInt16)? {
        wsPair(data, UInt16(0)) { bytes, len, a, b in slopdesk_ws_decode_u16_pair(bytes, len, a, b) }
    }

    public static func encodeU32(_ value: UInt32) -> Data {
        wsFixed(4) { out, cap in slopdesk_ws_encode_u32(value, out, cap) }
    }

    public static func decodeU32(_ data: Data) -> UInt32? {
        wsScalar(data, UInt32(0)) { bytes, len, out in slopdesk_ws_decode_u32(bytes, len, out) }
    }

    /// `pane/lastExitCode`. Rides as the `UInt32` bit pattern so a negative code (a signal-killed
    /// child) survives without a sign convention to get wrong on either end.
    ///
    /// Its own door rather than `encodeU32(UInt32(bitPattern:))`: the bit pattern IS the convention,
    /// and composing it here put the encode half of one round trip in this language while
    /// ``decodeI32`` asked the crate for the other.
    public static func encodeI32(_ value: Int32) -> Data {
        wsFixed(4) { out, cap in slopdesk_ws_encode_i32(value, out, cap) }
    }

    public static func decodeI32(_ data: Data) -> Int32? {
        wsScalar(data, Int32(0)) { bytes, len, out in slopdesk_ws_decode_i32(bytes, len, out) }
    }

    public static func encodeI64(_ value: Int64) -> Data {
        wsFixed(8) { out, cap in slopdesk_ws_encode_i64(value, out, cap) }
    }

    public static func decodeI64(_ data: Data) -> Int64? {
        wsScalar(data, Int64(0)) { bytes, len, out in slopdesk_ws_decode_i64(bytes, len, out) }
    }

    /// A `[u16 BE count]` list of UUIDs — `root/sessionOrder`, `session/tabOrder`, `root/closedTabRing`.
    public static func encodeUUIDList(_ ids: [UUID]) -> Data {
        var encoded = ids.map { SlopDeskWsUuid($0) }
        return encoded.withUnsafeMutableBufferPointer { input in
            var out = [UInt8](repeating: 0, count: 2 + input.count * 16)
            let needed = out.withUnsafeMutableBufferPointer { buffer in
                slopdesk_ws_encode_uuid_list(input.baseAddress, input.count, buffer.baseAddress, buffer.count)
            }
            guard needed <= out.count else { return Data() }
            return Data(out[0..<needed])
        }
    }

    /// `nil` on a count the bytes cannot back — the length is validated against what REMAINS before
    /// any capacity is reserved, so a hostile `0xFFFF` costs nothing.
    public static func decodeUUIDList(_ data: Data) -> [UUID]? {
        var bytes = [UInt8](data)
        return bytes.withUnsafeMutableBufferPointer { input -> [UUID]? in
            var out = [SlopDeskWsUuid](repeating: SlopDeskWsUuid(), count: max(8, input.count / 16))
            var needed = out.withUnsafeMutableBufferPointer { buffer in
                slopdesk_ws_decode_uuid_list(input.baseAddress, input.count, buffer.baseAddress, buffer.count)
            }
            if needed == Int(bitPattern: UInt.max) { return nil }
            if needed > out.count {
                out = [SlopDeskWsUuid](repeating: SlopDeskWsUuid(), count: needed)
                needed = out.withUnsafeMutableBufferPointer { buffer in
                    slopdesk_ws_decode_uuid_list(input.baseAddress, input.count, buffer.baseAddress, buffer.count)
                }
            }
            guard needed <= out.count else { return nil }
            return out[0..<needed].map(\.uuid)
        }
    }

    // MARK: - Marshalling

    /// Reads a fixed-width field. Absence is the BOOL, never a sentinel value: `-1` is a real exit
    /// code and `0xFFFFFFFF` is its encoding, so no in-band answer could mean "not a value".
    private static func wsScalar<T>(
        _ data: Data,
        _ empty: T,
        _ call: (UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<T>?) -> Bool,
    ) -> T? {
        var bytes = [UInt8](data)
        var answer = empty
        let decoded = bytes.withUnsafeMutableBufferPointer { input in
            call(input.baseAddress, input.count, &answer)
        }
        return decoded ? answer : nil
    }

    /// The same for a two-value field.
    private static func wsPair<T>(
        _ data: Data,
        _ empty: T,
        _ call: (UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<T>?, UnsafeMutablePointer<T>?) -> Bool,
    ) -> (T, T)? {
        var bytes = [UInt8](data)
        var first = empty
        var second = empty
        let decoded = bytes.withUnsafeMutableBufferPointer { input in
            call(input.baseAddress, input.count, &first, &second)
        }
        return decoded ? (first, second) : nil
    }
}

// MARK: - The entry blob

/// Accumulates every entry's VALUE into one buffer, handing back spans into it.
///
/// One buffer means one pointer and one lifetime, where a span per value would mean a nested
/// `withUnsafeBytes` per entry — and a snapshot has hundreds. The crate bounds-checks every span, so
/// a caller that got the arithmetic wrong encodes an empty value rather than reading someone else's
/// memory.
struct WsBlob {
    private(set) var bytes: [UInt8] = []

    /// The entry, with its value appended to the blob.
    mutating func entry(_ entry: WorkspaceEntry) -> SlopDeskWsEntry {
        let offset = bytes.count
        bytes.append(contentsOf: entry.value)
        return SlopDeskWsEntry(
            kind: entry.key.kind,
            field: entry.key.field,
            object: SlopDeskWsUuid(entry.key.objectID),
            value: SlopDeskWsSpan(offset: offset, len: bytes.count - offset, present: true),
        )
    }

    /// Text appended to the blob, as the span that reads it back.
    ///
    /// The same buffer the entry values go into, deliberately: a door that resolves both against one
    /// blob has one lifetime to get right instead of two.
    mutating func span(_ text: String) -> SlopDeskWsSpan {
        let offset = bytes.count
        bytes.append(contentsOf: Array(text.utf8))
        return SlopDeskWsSpan(offset: offset, len: bytes.count - offset, present: true)
    }

    /// A DELETE: a key with no value, which is what an absent span says.
    static func key(_ key: WorkspaceKey) -> SlopDeskWsEntry {
        SlopDeskWsEntry(
            kind: key.kind,
            field: key.field,
            object: SlopDeskWsUuid(key.objectID),
            value: SlopDeskWsSpan(offset: 0, len: 0, present: false),
        )
    }

    /// Lends the blob for exactly one call. The scope IS the safety contract.
    mutating func lend<T>(_ body: (UnsafeMutableBufferPointer<UInt8>) -> T) -> T {
        bytes.withUnsafeMutableBufferPointer { body($0) }
    }
}

extension SlopDeskWsEntry {
    /// The key this entry carries.
    var workspaceKey: WorkspaceKey {
        WorkspaceKey(kind: kind, objectID: object.uuid, field: field)
    }

    /// The entry, its value read back out of the buffer the span points into.
    ///
    /// A span the buffer cannot back reads as an EMPTY value rather than trapping — the same bounds
    /// discipline the crate applies, restated on this side because the buffer is this side's.
    func entry(in buffer: UnsafeMutableBufferPointer<UInt8>) -> WorkspaceEntry {
        let end = value.offset + value.len
        guard value.present, end <= buffer.count else {
            return WorkspaceEntry(key: workspaceKey, value: Data())
        }
        return WorkspaceEntry(key: workspaceKey, value: Data(buffer[value.offset..<end]))
    }
}

/// Reads a variable-length byte answer with the retry docs/55 §4 describes.
func wsBytes(_ call: (UnsafeMutablePointer<UInt8>?, Int) -> Int) -> Data {
    var out = [UInt8](repeating: 0, count: 4096)
    var needed = out.withUnsafeMutableBufferPointer { call($0.baseAddress, $0.count) }
    if needed > out.count {
        out = [UInt8](repeating: 0, count: needed)
        needed = out.withUnsafeMutableBufferPointer { call($0.baseAddress, $0.count) }
    }
    guard needed <= out.count else { return Data() }
    return Data(out[0..<needed])
}

/// A span the crate answered, read back out of the buffer it points into.
///
/// The span is an OFFSET, so it is only meaningful inside the `withUnsafeMutableBufferPointer`
/// scope that produced it — and the bounds check here is what makes a boundary bug read as `nil`
/// rather than as somebody else's memory.
extension UnsafeMutableBufferPointer<UInt8> {
    func text(_ span: SlopDeskWsSpan) -> String? {
        guard span.present else { return nil }
        return ArenaText.optionalText(UnsafeRawBufferPointer(self), span.offset, span.len)
    }
}

/// A fixed-width answer from the crate. The width is known before the call, so there is no probe and
/// no retry — a short answer is a boundary bug and reads as empty rather than as a truncated field.
func wsFixed(_ width: Int, _ call: (UnsafeMutablePointer<UInt8>?, Int) -> Int) -> Data {
    var out = [UInt8](repeating: 0, count: width)
    let needed = out.withUnsafeMutableBufferPointer { call($0.baseAddress, $0.count) }
    guard needed == width else { return Data() }
    return Data(out)
}
