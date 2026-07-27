import Foundation
import SlopDeskProtocol
import SlopDeskWorkspaceModel

/// The client's replica of the host-owned workspace document (docs/45 §7.1).
///
/// Pure value type: no SwiftUI, no transport, no clock. Everything a client needs to decide is a
/// function of the frames it has applied, which is what makes convergence provable rather than
/// hoped-for.
///
/// **Two layers, read in precedence order `entries` → `fastPath`.**
///
/// - ``entries`` is host truth and is written ONLY by ``apply(kind:epoch:baseStateNum:newStateNum:payload:)``.
///   It therefore remains provably `apply(diffs, base)` — the entire convergence argument.
/// - ``fastPath`` is the low-latency overlay the existing per-pane control sinks (wire 21/26/27/32/
///   33/34/36) write. It is read only where `entries` has nothing, and any key a snapshot or diff
///   supplies is ERASED from it in the same step.
///
/// That erasure is the whole point. The pane channel and the workspace channel are two independent
/// producers of the same fact, and `enqueueControl` is newest-shed at 1024 — so the push path is
/// lossy *and* unordered relative to this one. Letting a fast-path write survive a document value
/// would freeze that disagreement forever, which is precisely the bug class this document exists to
/// end, reintroduced as an optimisation.
///
/// Phase 5 adds a third layer, `pending` (optimistic intent patches), ahead of `entries`. Every read
/// already funnels through ``value(for:)``, so it lands in one place.
public struct HostWorkspaceMirror: Sendable {
    /// What a frame did. The client acts on this and nothing else.
    public enum ApplyOutcome: Equatable, Sendable {
        /// Host truth moved. The argument is the `stateNum` the client must now ACK.
        case applied(Int64)
        /// A frame the mirror had already superseded. Nothing changed; deliberately NOT an error —
        /// duplicates and reorders are no-ops by construction (docs/45 §5.5).
        case ignored
        /// The frame cannot be based on what is held: wrong epoch, or a base this mirror is not at.
        /// The client re-sends `subscribe`, which IS the resync verb.
        case needsResubscribe
        /// Undecodable. Dropped — never fatal to the channel.
        case dropped
        /// The host declared a new document. Host truth is now empty and a snapshot follows.
        case reset
        /// ``roster`` was replaced.
        case presence
        /// An intent was answered.
        case intentResult(WorkspaceIntentResult)
    }

    /// The document identity this mirror is synced to. `nil` until the first snapshot.
    ///
    /// Minted per hostd start, so a restarted daemon counting its `stateNum` back up cannot have a
    /// delta of its accepted against a different document.
    public private(set) var epoch: UUID?

    /// The version of ``entries``. `0` means "I know nothing" — the sentinel `subscribe` sends, and
    /// the base every snapshot declares. Host `stateNum` starts at 1 for exactly that reason.
    public private(set) var stateNum: Int64 = 0

    /// Applied host truth. Kinds 0/1/4 ONLY.
    public private(set) var entries = HostWorkspaceState()

    /// The control-push overlay. Written by the client's own sinks, erased by host truth.
    public private(set) var fastPath: [WorkspaceKey: Data] = [:]

    /// The last presence roster the host broadcast. Not versioned and never diffed: presence is a
    /// full replace whose lifetime is the connection.
    public private(set) var roster: WorkspacePresenceRoster?

    public init() {}

    // MARK: - Subscribe parameters

    /// What `subscribe` should declare, so the host can answer with a diff instead of a snapshot.
    ///
    /// The pair is all-or-nothing: an epoch with no state is `stateNum 0`, which reads as "snapshot
    /// me". There is no way to ask for a diff against a document this mirror does not hold.
    public var knownEpoch: UUID { epoch ?? WireMessage.newSessionID }
    public var knownStateNum: Int64 { epoch == nil ? 0 : stateNum }

    // MARK: - Apply

    /// Folds one type-37 `workspaceEvent` into the mirror.
    ///
    /// Takes the decoded header fields rather than a message value so the mirror stays independent of
    /// the envelope — the same reason the host's session takes them apart before sending.
    public mutating func apply(
        kind: UInt8,
        epoch frameEpoch: UUID,
        baseStateNum: Int64,
        newStateNum: Int64,
        payload: Data,
    ) -> ApplyOutcome {
        switch WorkspaceEventKind(rawValue: kind) {
        case .snapshot:
            return applySnapshot(epoch: frameEpoch, stateNum: newStateNum, payload: payload)
        case .diff:
            return applyDiff(
                epoch: frameEpoch,
                base: baseStateNum,
                new: newStateNum,
                payload: payload,
            )
        case .reset:
            return applyReset(epoch: frameEpoch)
        case .presence:
            guard let decoded = try? WorkspacePresenceRoster.decode(payload) else { return .dropped }
            roster = decoded
            return .presence
        case .intentResult:
            guard let decoded = try? WorkspaceIntentResult.decode(payload) else { return .dropped }
            return .intentResult(decoded)
        case nil:
            // A kind from a newer host. Dropping one frame is the correct forward-tolerance: this
            // wire has no version negotiation, and a kind we cannot interpret is not a kind we can
            // safely guess at.
            return .dropped
        }
    }

    /// A snapshot is self-contained, so it is accepted whatever the mirror holds — including across
    /// an epoch change with no intervening reset, which is exactly the cold-connect case.
    private mutating func applySnapshot(epoch frameEpoch: UUID, stateNum new: Int64, payload: Data) -> ApplyOutcome {
        guard let decoded = try? WorkspaceStateCodec.decodeSnapshot(payload) else { return .dropped }
        entries = decoded
        epoch = frameEpoch
        stateNum = new
        retireFastPath(supplying: decoded.entries.keys)
        return .applied(new)
    }

    private mutating func applyDiff(epoch frameEpoch: UUID, base: Int64, new: Int64, payload: Data) -> ApplyOutcome {
        // Nothing to base on. A diff is only meaningful against a document we hold.
        guard let epoch, epoch == frameEpoch else { return .needsResubscribe }
        guard base == stateNum else {
            // Already past it — a duplicate or a reorder, which the assign-not-mutate rule makes a
            // no-op. Only a frame that reaches FORWARD from a base we are not at is unrecoverable.
            return new <= stateNum ? .ignored : .needsResubscribe
        }
        guard new > stateNum else { return .ignored }
        guard let diff = try? WorkspaceStateCodec.decodeDiff(payload) else { return .dropped }
        entries = entries.applying(diff)
        stateNum = new
        // A DELETE supplies a fact too — "this key is now absent" — so its fast-path value must go
        // as well, or a retired title would reappear from the overlay.
        retireFastPath(supplying: diff.sets.map(\.key))
        retireFastPath(supplying: diff.deletes)
        return .applied(new)
    }

    /// The host declared a different document. Host truth goes; the overlay stays.
    ///
    /// Keeping ``fastPath`` is deliberate: it is fed by the per-pane channels, whose lifetime is
    /// their own, and clearing it here would blank rows those channels are still painting. With
    /// `entries` empty the overlay simply becomes visible again — the same state the client is in
    /// before its first snapshot, and the same state it runs in with the flag off.
    private mutating func applyReset(epoch frameEpoch: UUID) -> ApplyOutcome {
        entries = HostWorkspaceState()
        epoch = frameEpoch
        stateNum = 0
        return .reset
    }

    private mutating func retireFastPath(supplying keys: some Sequence<WorkspaceKey>) {
        guard !fastPath.isEmpty else { return }
        for key in keys { fastPath.removeValue(forKey: key) }
    }

    // MARK: - Fast path

    /// Records a value pushed on a pane's own control channel.
    ///
    /// Ignored when host truth already holds the key: the document is authoritative, and a push that
    /// raced a diff must not win. Passing `nil` clears the overlay entry (a push that retires a fact).
    public mutating func writeFastPath(_ key: WorkspaceKey, _ value: Data?) {
        guard entries[key] == nil else { return }
        fastPath[key] = value
    }

    /// Drops every overlay entry for one pane — what a client does when a pane's channel closes.
    public mutating func clearFastPath(pane paneID: UUID) {
        fastPath = fastPath.filter { !($0.key.kind == WorkspaceObjectKind.pane.rawValue && $0.key.objectID == paneID) }
    }

    // MARK: - Read

    /// The single funnel every read goes through. Phase 5's `pending` layer slots in ahead of
    /// ``entries`` here and nowhere else.
    public func value(for key: WorkspaceKey) -> Data? {
        entries[key] ?? fastPath[key]
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

    // MARK: Pane projection

    /// Every pane the document knows about, in no particular order.
    ///
    /// Membership is the `liveness` field, which ``PaneLiveness/entries()`` always emits — a pane
    /// with only overlay values is NOT a document pane, and must not be enumerated as one.
    public var paneIDs: Set<UUID> {
        var ids = Set<UUID>()
        for key in entries.entries.keys
            where key.kind == WorkspaceObjectKind.pane.rawValue && key.field == WorkspacePaneField.liveness
        {
            ids.insert(key.objectID)
        }
        return ids
    }

    /// One pane's facts, read through the full precedence chain.
    ///
    /// - Returns: `nil` when the pane has no `liveness` field anywhere — it is not a pane this
    ///   mirror knows.
    public func paneLiveness(_ paneID: UUID) -> PaneLiveness? {
        var state = HostWorkspaceState()
        for field in PaneLiveness.livenessFields() {
            let key = WorkspaceKey(.pane, paneID, field)
            if let value = value(for: key) { state[key] = value }
        }
        return PaneLiveness(paneID: paneID, entries: state)
    }

    /// One project's git summary blob, as pushed by the host's repo watcher.
    public func projectGitSummary(_ objectID: UUID) -> Data? {
        value(.project, objectID, WorkspaceProjectField.gitSummary)
    }
}
