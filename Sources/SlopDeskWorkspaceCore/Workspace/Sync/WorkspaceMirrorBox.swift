import Foundation
import SlopDeskProtocol
import SlopDeskWorkspaceModel

/// Reference semantics over ``HostWorkspaceMirror`` — the ONE instance both producers share.
///
/// The mirror is a value type on purpose (its convergence is provable precisely because applying a
/// frame is a pure function). But its two writers live in different objects: the workspace channel
/// applies host frames, and the store's per-pane control sinks write the fast path. They must write
/// the SAME mirror, because the erasure rule — host truth deletes the overlay entry for any key it
/// supplies — is what keeps the two layers disjoint. Two copies would mean the channel erasing an
/// overlay nobody reads while the store's overlay outlived host truth forever, which is the exact
/// bug this whole document exists to end.
///
/// So: one box, handed to both.
@preconcurrency
@MainActor
public final class WorkspaceMirrorBox {
    public private(set) var mirror = HostWorkspaceMirror()

    /// Fired after any change a view should repaint for. A callback rather than `@Observable` so
    /// this stays headless and testable without SwiftUI.
    public var onChange: (@MainActor () -> Void)?

    public init() {}

    /// Folds one type-37 frame in. Returns what the caller must do about it.
    @discardableResult
    public func apply(
        kind: UInt8,
        epoch: UUID,
        baseStateNum: Int64,
        newStateNum: Int64,
        payload: Data,
    ) -> HostWorkspaceMirror.ApplyOutcome {
        let outcome = mirror.apply(
            kind: kind,
            epoch: epoch,
            baseStateNum: baseStateNum,
            newStateNum: newStateNum,
            payload: payload,
        )
        switch outcome {
        case .applied,
             .reset,
             .presence: onChange?()
        case .ignored,
             .dropped,
             .needsResubscribe,
             .intentResult: break
        }
        return outcome
    }

    /// Records a value pushed on a pane's own control channel. A no-op where host truth already
    /// holds the key.
    public func writeFastPath(_ key: WorkspaceKey, _ value: Data?) {
        let before = mirror.fastPath[key]
        mirror.writeFastPath(key, value)
        if mirror.fastPath[key] != before { onChange?() }
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
        mirror.clearFastPath(pane: paneID)
        onChange?()
    }

    /// Forgets everything, host truth included. The workspace channel calls this when it stops:
    /// `entries` is only meaningful against a live subscription, and a reconnect that kept it could
    /// apply a diff to a document the host has since replaced.
    public func reset() {
        mirror = HostWorkspaceMirror()
        onChange?()
    }

    // MARK: Optimistic intents

    /// Stages one intent optimistically and hands back what to put on the wire.
    ///
    /// The patch is computed by running the SAME ``WorkspaceIntentApplier`` the host will run, and
    /// diffing the result against what is on screen now. That is the whole reason the applier is pure
    /// and lives in the model target: two implementations of "what does a split do" would drift, and
    /// the drift would look exactly like a sync bug.
    ///
    /// - Returns: `nil` when this client can already tell the host will refuse. The intent is not
    ///   sent at all — a request we know the answer to is a round trip and a rollback for nothing.
    public func stageIntent(
        _ intentID: UUID = UUID(),
        op: WorkspaceIntentOp,
        args: Data,
        issuedAt: TimeInterval,
    ) -> WorkspaceIntent? {
        // Resolved ONCE: it is the input the applier decides from AND the cells the close ops read
        // their project keys out of, and building it per pane would be quadratic in a big workspace.
        let resolved = mirror.resolved
        guard let current = resolved.topology else { return nil }
        let outcome = WorkspaceIntentApplier.apply(
            op: op.rawValue, args: args, to: current,
            // A client cannot know whether the host's document is still untouched — `pristine` is a
            // fact about the host's own file, and there is no cell carrying it. So the bootstrap is
            // staged OPTIMISTICALLY and a `rejectedStale` snaps the patch away, which is exactly what
            // the pending layer is for. Refusing here instead would make ``WorkspaceIntentOp/adoptWorkspace``
            // unsendable by construction.
            documentIsPristine: true,
            projectKey: { resolved.projectKey(forPane: $0) },
        )
        guard let next = outcome.topology else { return nil }
        var projected = HostWorkspaceState()
        projected.write(topology: next)
        var base = HostWorkspaceState()
        base.write(topology: current)
        mirror.beginPending(intentID, diff: projected.diff(from: base), issuedAt: issuedAt)
        onChange?()
        return WorkspaceIntent(intentID: intentID, op: op.rawValue, args: args)
    }

    /// Drops patches the host never answered. Driven by the caller's clock.
    public func expirePending(now: TimeInterval) {
        if mirror.expirePending(now: now) { onChange?() }
    }

    /// Drops one staged patch because the request never reached the host.
    public func dropPending(_ intentID: UUID) {
        if mirror.dropPending(intentID) { onChange?() }
    }

    /// Repaints after ``HostWorkspaceMirror`` folded an intent result in.
    ///
    /// Separate from ``apply(kind:epoch:baseStateNum:newStateNum:payload:)``'s own repaint because
    /// most results change nothing on screen — an accepted one only ARMS its patch — and a repaint
    /// per result would churn the whole UI on a burst of accepted intents.
    public func notePendingChanged() { onChange?() }

    public var pendingIntentCount: Int { mirror.pending.count }

    /// Whether `intentID`'s optimistic patch is still standing — the intent went out and the host has
    /// neither answered it nor superseded it.
    ///
    /// `false` for an id that never staged anything (an intent whose diff was empty proposes nothing),
    /// for one already answered, and after a ``reset()``. The caller is the launch dial hold, which
    /// has to know when the ONE proposal a client cannot predict the answer to has been decided.
    public func isPending(_ intentID: UUID) -> Bool {
        mirror.pending.contains { $0.intentID == intentID }
    }

    // MARK: Reads (the UI's whole surface)

    /// The layout to render: host truth with this client's unanswered intents already applied.
    public var topology: WorkspaceTopology? { mirror.topology }

    public var knownEpoch: UUID { mirror.knownEpoch }
    public var knownStateNum: Int64 { mirror.knownStateNum }
    public var roster: WorkspacePresenceRoster? { mirror.roster }

    public func paneLiveness(_ paneID: UUID) -> PaneLiveness? { mirror.paneLiveness(paneID) }
    public var paneIDs: Set<UUID> { mirror.paneIDs }

    public func string(_ kind: WorkspaceObjectKind, _ objectID: UUID, _ field: UInt8) -> String? {
        mirror.string(kind, objectID, field)
    }

    public func bool(_ kind: WorkspaceObjectKind, _ objectID: UUID, _ field: UInt8) -> Bool {
        mirror.bool(kind, objectID, field)
    }

    public func u32(_ kind: WorkspaceObjectKind, _ objectID: UUID, _ field: UInt8) -> UInt32? {
        mirror.u32(kind, objectID, field)
    }

    public func projectGitSummary(_ objectID: UUID) -> Data? { mirror.projectGitSummary(objectID) }
}
