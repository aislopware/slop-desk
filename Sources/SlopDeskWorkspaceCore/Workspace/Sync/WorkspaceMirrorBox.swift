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

    // MARK: Reads (the UI's whole surface)

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
