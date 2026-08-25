import CSlopDeskFFI
import Foundation
import SlopDeskProtocol
import SlopDeskWorkspaceModel

/// The Swift face of `slopdesk_wire::document::mirror` — this client's replica of the host-owned
/// workspace document (docs/45 §7.1), and the ONE instance both of its producers share.
///
/// The replica has two writers and they must write the SAME one: the workspace channel folds host
/// frames, and the store's per-pane control sinks write the fast path. The erasure rule — host truth
/// deletes the overlay entry for any key it supplies — is what keeps the two layers disjoint, and
/// two copies would mean the channel erasing an overlay nobody reads while the store's overlay
/// outlived host truth forever. That is the exact bug this whole document exists to end.
///
/// So: one box, handed to both. What is on this side is the observation (`onChange`), the two frame
/// kinds that are not the document's — the presence roster, which is never diffed and whose lifetime
/// is the CONNECTION, and an intent's verdict, whose status byte is the codec's — and nothing else.
@preconcurrency
@MainActor
public final class WorkspaceMirrorBox {
    /// The far side, which owns host truth, the overlay and the optimistic patches.
    ///
    /// `nonisolated(unsafe)` for `deinit` alone: every OTHER touch is on the main actor with the
    /// class, and by the time `deinit` runs the last reference is already gone, so the free races
    /// with nothing.
    private nonisolated(unsafe) let handle: OpaquePointer

    /// Fired after any change a view should repaint for. A callback rather than `@Observable` so
    /// this stays headless and testable without SwiftUI.
    public var onChange: (@MainActor () -> Void)?

    /// The last presence roster the host broadcast.
    ///
    /// Held here rather than behind the door because it is not a LAYER of the replica: presence is a
    /// full replace, never versioned and never diffed, and its lifetime is the connection rather
    /// than the document. See ``WorkspaceStore/paneViewers(for:)`` for the joins over it, which are
    /// Rust's.
    public private(set) var roster: WorkspacePresenceRoster?

    public init() {
        guard let opened = slopdesk_ws_mirror_new() else {
            preconditionFailure("the workspace mirror door would not open")
        }
        handle = opened
    }

    deinit { slopdesk_ws_mirror_free(handle) }

    /// How long an unanswered optimistic patch may stand.
    public static var pendingTimeout: TimeInterval { slopdesk_ws_mirror_pending_timeout() }

    // MARK: - Apply

    /// Folds one type-37 frame in. Returns what the caller must do about it.
    ///
    /// The two kinds routed HERE are the two that are not the document: a presence roster, whose
    /// decoder is this target's, and an intent result, whose status byte belongs to the codec. Every
    /// other kind — including one from a newer host — goes through the door, so the
    /// drop-what-you-cannot-read rule is stated once rather than in two languages.
    @discardableResult
    public func apply(
        kind: UInt8,
        epoch: UUID,
        baseStateNum: Int64,
        newStateNum: Int64,
        payload: Data,
    ) -> ApplyOutcome {
        if kind == WorkspaceEventKind.presence.rawValue {
            guard let decoded = try? WorkspacePresenceRoster.decode(payload) else { return .dropped }
            roster = decoded
            onChange?()
            return .presence
        }
        if kind == WorkspaceEventKind.intentResult.rawValue {
            guard let decoded = try? WorkspaceIntentResult.decode(payload) else { return .dropped }
            noteIntentResult(decoded)
            return .intentResult(decoded)
        }
        var stateNum: Int64 = 0
        let tag = withUUIDBytes(epoch) { epochBytes in
            payload.withUnsafeBytes { bytes in
                slopdesk_ws_mirror_apply(
                    handle, kind, epochBytes, baseStateNum, newStateNum,
                    bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count, &stateNum,
                )
            }
        }
        let outcome = ApplyOutcome(tag: tag, stateNum: stateNum)
        switch outcome {
        case .applied,
             .reset: onChange?()
        default: break
        }
        return outcome
    }

    /// Folds the host's verdict on one intent.
    ///
    /// Deliberately does NOT repaint: most results change nothing on screen — an accepted one only
    /// ARMS its patch — and a repaint per result would churn the whole UI on a burst of them. The
    /// caller repaints through ``notePendingChanged()`` where it matters.
    private func noteIntentResult(_ result: WorkspaceIntentResult) {
        let applied = result.status == WorkspaceIntentStatus.applied.rawValue
        withUUIDBytes(result.intentID) { intentBytes in
            _ = slopdesk_ws_mirror_note_intent_result(handle, intentBytes, applied)
        }
    }

    /// Forgets everything, host truth included. The workspace channel calls this when it stops:
    /// host truth is only meaningful against a live subscription, and a reconnect that kept it could
    /// apply a diff to a document the host has since replaced.
    public func reset() {
        slopdesk_ws_mirror_forget(handle)
        roster = nil
        onChange?()
    }

    // MARK: - Fast path

    /// Records a value pushed on a pane's own control channel. A no-op where host truth already
    /// holds the key.
    public func writeFastPath(_ key: WorkspaceKey, _ value: Data?) {
        let moved = withKeyBytes(key) { keyBytes in
            guard let value else {
                return slopdesk_ws_mirror_write_fast_path(handle, keyBytes, nil, 0, false)
            }
            return value.withUnsafeBytes { bytes in
                slopdesk_ws_mirror_write_fast_path(
                    handle, keyBytes,
                    bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count, true,
                )
            }
        }
        if moved { onChange?() }
    }

    public func writeFastPath(pane paneID: UUID, field: UInt8, string: String?) {
        writeFastPath(
            WorkspaceKey(.pane, paneID, field),
            string.map { WorkspaceStateCodec.encodeString($0) },
        )
    }

    public func writeFastPath(pane paneID: UUID, field: UInt8, bool: Bool) {
        writeFastPath(WorkspaceKey(.pane, paneID, field), WorkspaceStateCodec.encodeBool(bool))
    }

    /// Drops a pane's whole overlay — what a client does when that pane's channel closes.
    public func clearFastPath(pane paneID: UUID) {
        withUUIDBytes(paneID) { slopdesk_ws_mirror_clear_fast_path(handle, $0) }
        onChange?()
    }

    /// Whether the OVERLAY holds `key` — not the full chain.
    public func fastPathHolds(_ key: WorkspaceKey) -> Bool {
        withKeyBytes(key) { slopdesk_ws_mirror_fast_path_holds(handle, $0) }
    }

    /// Every pane with an overlay entry. Distinct from ``paneIDs``, which enumerates the DOCUMENT.
    public var fastPathPaneIDs: Set<UUID> {
        identities { slopdesk_ws_mirror_fast_path_pane_ids(handle, $0, $1) }
    }

    // MARK: - Optimistic intents

    /// Stages one intent optimistically and hands back what to put on the wire.
    ///
    /// The patch is computed by running the SAME applier the host will run against the topology as
    /// resolved, and diffing the two TOPOLOGY projections — all of it on the far side, which is the
    /// only place that applier lives.
    ///
    /// A no-op intent — a rename to the name already there — still stages and still goes out: what
    /// it costs is one empty patch, and what it buys is the host taking ownership of its document,
    /// which is a fact no cell on this side carries.
    ///
    /// - Returns: `nil` only when this client can already tell the host will refuse. The intent is
    ///   not sent at all — a request we know the answer to is a round trip and a rollback for
    ///   nothing.
    public func stageIntent(
        _ intentID: UUID = UUID(),
        op: WorkspaceIntentOp,
        args: Data,
        issuedAt: TimeInterval,
    ) -> WorkspaceIntent? {
        let count = slopdesk_ws_minted_ids_per_intent()
        var minted = [UInt8]()
        minted.reserveCapacity(count * 16)
        for _ in 0..<count {
            withUnsafeBytes(of: UUID().uuid) { minted.append(contentsOf: $0) }
        }
        let staged = withUUIDBytes(intentID) { intentBytes in
            args.withUnsafeBytes { argBytes in
                minted.withUnsafeBufferPointer { pool in
                    slopdesk_ws_mirror_stage_intent(
                        handle, intentBytes, op.rawValue,
                        argBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), argBytes.count,
                        pool.baseAddress, count, issuedAt,
                    )
                }
            }
        }
        guard staged else { return nil }
        onChange?()
        return WorkspaceIntent(intentID: intentID, op: op.rawValue, args: args)
    }

    /// Drops patches the host never answered. Driven by the caller's clock.
    public func expirePending(now: TimeInterval) {
        if slopdesk_ws_mirror_expire_pending(handle, now, Self.pendingTimeout) { onChange?() }
    }

    /// Drops one staged patch because the request never reached the host.
    public func dropPending(_ intentID: UUID) {
        let dropped = withUUIDBytes(intentID) { slopdesk_ws_mirror_drop_pending(handle, $0) }
        if dropped { onChange?() }
    }

    /// Repaints after an intent result was folded in — see ``apply(kind:epoch:baseStateNum:newStateNum:payload:)``
    /// for why that fold does not repaint on its own.
    public func notePendingChanged() { onChange?() }

    public var pendingIntentCount: Int { slopdesk_ws_mirror_pending_count(handle) }

    /// Whether `intentID`'s optimistic patch is still standing — the intent went out and the host
    /// has neither answered it nor superseded it.
    ///
    /// `false` for an id ``stageIntent(_:op:args:issuedAt:)`` refused, for one already answered, and
    /// after a ``reset()``. The caller is the launch dial hold, which has to
    /// know when the ONE proposal a client cannot predict the answer to has been decided.
    public func isPending(_ intentID: UUID) -> Bool {
        withUUIDBytes(intentID) { slopdesk_ws_mirror_is_pending(handle, $0) }
    }

    // MARK: - Reads (the UI's whole surface)

    /// The whole replica, read through the full precedence chain `pending` → host truth → overlay.
    ///
    /// Crosses as an encoded SNAPSHOT rather than a marshalled cell array: that encoding already
    /// exists, is golden-pinned, and this side already holds its decoder. Copies the document, so a
    /// caller that needs several answers resolves ONCE and reads the value — never per pane.
    public var resolved: HostWorkspaceState {
        decoded { slopdesk_ws_mirror_resolved(handle, $0, $1) }
    }

    /// HOST TRUTH alone — no overlay, no pending. The in-process document's adopt path, which is
    /// becoming authoritative and must not adopt this client's own guesses along with the seed.
    public var hostTruth: HostWorkspaceState {
        decoded { slopdesk_ws_mirror_host_truth(handle, $0, $1) }
    }

    /// The layout to render: host truth with this client's unanswered intents already applied.
    public var topology: WorkspaceTopology? { resolved.topology }

    /// The identity of the document actually held, or `nil` when none is — which ``knownEpoch``
    /// cannot say, since it answers a fresh UUID for "snapshot me".
    public var documentEpoch: UUID? {
        var bytes = [UInt8](repeating: 0, count: 16)
        let held = bytes.withUnsafeMutableBufferPointer { slopdesk_ws_mirror_epoch(handle, $0.baseAddress) }
        return held ? UUID(uuid: uuidTuple(bytes)) : nil
    }

    public var knownEpoch: UUID { documentEpoch ?? WireMessage.newSessionID }
    public var knownStateNum: Int64 { slopdesk_ws_mirror_known_state_num(handle) }

    /// The version of host truth as held, whatever the epoch says.
    public var stateNum: Int64 { slopdesk_ws_mirror_state_num(handle) }

    /// How many document frames have been folded. Back to zero after a ``reset()``, so a caller can
    /// tell a fold from every other reason ``onChange`` fires.
    public var documentFramesApplied: UInt64 { slopdesk_ws_mirror_frames_applied(handle) }

    /// Whether a HOST has spoken into this replica, as opposed to nothing having (`nil`) or the
    /// store having seeded the layout it restored from disk (``WorkspaceStore/seedEpoch``).
    ///
    /// The distinction ``documentFramesApplied`` cannot draw on its own: the seed is folded like any
    /// other frame, so the counter reads non-zero before a host has said anything at all.
    public var holdsHostDocument: Bool {
        guard let epoch = documentEpoch else { return false }
        return epoch != WireMessage.newSessionID
    }

    /// Every pane the DOCUMENT knows about. A pane with only overlay values is not one.
    public var paneIDs: Set<UUID> {
        identities { slopdesk_ws_mirror_pane_ids(handle, $0, $1) }
    }

    /// One cell's bytes, through the full precedence chain. `nil` for a cell no layer holds, and
    /// `Data()` for one holding a RETIRED value — a distinction that stays live all the way to the
    /// UI, which is why the door answers absence with its own sentinel rather than with zero bytes.
    public func value(for key: WorkspaceKey) -> Data? {
        withKeyBytes(key) { keyBytes in
            var out = [UInt8](repeating: 0, count: 256)
            let needed = out.withUnsafeMutableBufferPointer {
                slopdesk_ws_mirror_value(handle, keyBytes, $0.baseAddress, $0.count)
            }
            if needed == Int(bitPattern: UInt(SLOPDESK_WS_MIRROR_ABSENT)) { return nil }
            if needed == 0 { return Data() }
            if needed <= out.count { return Data(out.prefix(needed)) }
            out = [UInt8](repeating: 0, count: needed)
            let wrote = out.withUnsafeMutableBufferPointer {
                slopdesk_ws_mirror_value(handle, keyBytes, $0.baseAddress, $0.count)
            }
            return wrote == needed ? Data(out) : nil
        }
    }

    public func value(_ kind: WorkspaceObjectKind, _ objectID: UUID, _ field: UInt8) -> Data? {
        value(for: WorkspaceKey(kind, objectID, field))
    }

    /// A string field. A zero-length value decodes to `""` — RETIRED, which is distinct from absent
    /// and must stay so all the way to the UI.
    public func string(_ kind: WorkspaceObjectKind, _ objectID: UUID, _ field: UInt8) -> String? {
        value(kind, objectID, field).flatMap { WorkspaceStateCodec.decodeString($0) }
    }

    public func bool(_ kind: WorkspaceObjectKind, _ objectID: UUID, _ field: UInt8) -> Bool {
        value(kind, objectID, field).flatMap { WorkspaceStateCodec.decodeBool($0) } ?? false
    }

    public func u32(_ kind: WorkspaceObjectKind, _ objectID: UUID, _ field: UInt8) -> UInt32? {
        value(kind, objectID, field).flatMap { WorkspaceStateCodec.decodeU32($0) }
    }

    /// One pane's facts, read through the full precedence chain.
    ///
    /// - Returns: `nil` when the pane has no `liveness` field anywhere — it is not a pane this
    ///   replica knows.
    public func paneLiveness(_ paneID: UUID) -> PaneLiveness? {
        var state = HostWorkspaceState()
        for field in PaneLiveness.livenessFields() {
            let key = WorkspaceKey(.pane, paneID, field)
            if let held = value(for: key) { state[key] = held }
        }
        return PaneLiveness(paneID: paneID, entries: state)
    }

    /// One project's git summary blob, as pushed by the host's repo watcher.
    public func projectGitSummary(_ objectID: UUID) -> Data? {
        value(.project, objectID, WorkspaceProjectField.gitSummary)
    }

    // MARK: - Marshalling

    /// Runs `body` over a document the door answered as an encoded snapshot, growing the buffer once
    /// if the first ask did not fit.
    private func decoded(_ ask: (UnsafeMutablePointer<UInt8>?, Int) -> Int) -> HostWorkspaceState {
        var out = [UInt8](repeating: 0, count: 8192)
        var needed = out.withUnsafeMutableBufferPointer { ask($0.baseAddress, $0.count) }
        if needed == 0 { return HostWorkspaceState() }
        if needed > out.count {
            out = [UInt8](repeating: 0, count: needed)
            needed = out.withUnsafeMutableBufferPointer { ask($0.baseAddress, $0.count) }
            guard needed <= out.count else { return HostWorkspaceState() }
        }
        return (try? WorkspaceStateCodec.decodeSnapshot(Data(out.prefix(needed)))) ?? HostWorkspaceState()
    }

    /// Runs an identity-list door under §4's retry, as a set. The buffer is BYTES and the capacity
    /// is IDENTITIES, which is the door's own convention.
    private func identities(_ ask: (UnsafeMutablePointer<UInt8>?, Int) -> Int) -> Set<UUID> {
        var capacity = 64
        var out = [UInt8](repeating: 0, count: capacity * 16)
        var needed = out.withUnsafeMutableBufferPointer { ask($0.baseAddress, capacity) }
        if needed == 0 { return [] }
        if needed > capacity {
            capacity = needed
            out = [UInt8](repeating: 0, count: capacity * 16)
            needed = out.withUnsafeMutableBufferPointer { ask($0.baseAddress, capacity) }
            guard needed <= capacity else { return [] }
        }
        return Set((0..<needed).map { index in
            UUID(uuid: uuidTuple(Array(out[(index * 16)..<(index * 16 + 16)])))
        })
    }

    /// Lends a UUID's sixteen bytes for the length of one call.
    private func withUUIDBytes<T>(_ id: UUID, _ body: (UnsafePointer<UInt8>?) -> T) -> T {
        withUnsafeBytes(of: id.uuid) { body($0.baseAddress?.assumingMemoryBound(to: UInt8.self)) }
    }

    /// Lends a key's eighteen bytes — `[kind][16B objectID][field]` — for the length of one call.
    private func withKeyBytes<T>(_ key: WorkspaceKey, _ body: (UnsafePointer<UInt8>?) -> T) -> T {
        var bytes = [UInt8](repeating: 0, count: WorkspaceKey.encodedSize)
        bytes[0] = key.kind
        withUnsafeBytes(of: key.objectID.uuid) { raw in
            for (offset, byte) in raw.enumerated() { bytes[1 + offset] = byte }
        }
        bytes[17] = key.field
        return bytes.withUnsafeBufferPointer { body($0.baseAddress) }
    }

    /// Sixteen bytes as the tuple `UUID` is built from.
    private func uuidTuple(_ bytes: [UInt8]) -> uuid_t {
        (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
        )
    }
}

public extension WorkspaceMirrorBox {
    /// What a frame did. The client acts on this and nothing else.
    enum ApplyOutcome: Equatable, Sendable {
        /// Host truth moved. The argument is the `stateNum` the client must now ACK.
        case applied(Int64)
        /// A frame the replica had already superseded. Nothing changed, and deliberately NOT an
        /// error — duplicates and reorders are no-ops by construction (docs/45 §5.5).
        case ignored
        /// The frame cannot be based on what is held: wrong epoch, or a base this replica is not at.
        /// The client re-sends `subscribe`, which IS the resync verb.
        case needsResubscribe
        /// Undecodable, or a kind this build cannot interpret. Dropped — never fatal to the channel.
        case dropped
        /// The host declared a new document. Host truth is now empty and a snapshot follows.
        case reset
        /// ``WorkspaceMirrorBox/roster`` was replaced.
        case presence
        /// An intent was answered.
        case intentResult(WorkspaceIntentResult)

        init(tag: UInt8, stateNum: Int64) {
            switch tag {
            case UInt8(SLOPDESK_WS_MIRROR_APPLIED): self = .applied(stateNum)
            case UInt8(SLOPDESK_WS_MIRROR_IGNORED): self = .ignored
            case UInt8(SLOPDESK_WS_MIRROR_NEEDS_RESUBSCRIBE): self = .needsResubscribe
            case UInt8(SLOPDESK_WS_MIRROR_RESET): self = .reset
            default: self = .dropped
            }
        }
    }
}
