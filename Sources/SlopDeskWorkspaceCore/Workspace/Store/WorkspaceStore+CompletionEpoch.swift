import Foundation
import SlopDeskWorkspaceModel

// The unread-finish marker, as a COMPARISON rather than a latch (docs/45 §4.5).
//
// `paneUnseenDone` used to be the fact itself: a bit this client set on its own `.done` edge and
// held in memory. That made it unaskable — two clients disagreed, a relaunch forgot, and a client
// disconnected across the finish could never learn of it, because the host's own done→idle decay
// (seconds) had already taken the edge away by the time it returned.
//
// The host publishes a monotone counter instead (`pane/completionEpoch`) and holds ZERO per-client
// acknowledgement state. Each device compares it against its own `seenCompletionEpoch`. The Set
// survives as the PROJECTION every existing read already binds to; nothing writes it but
// ``WorkspaceStore/refreshUnseenDone(for:)``.

/// The persisted seen-map, scoped to the document epoch it was recorded under.
///
/// The scoping is not decoration. A host mints a fresh epoch on every start and its completion
/// counters restart from zero with it, so a map carried across a restart could hold a `seen` value
/// ABOVE the live counter — and that pane would never show an unread finish again. Tying the map to
/// the epoch makes a restart drop it, which costs one re-announced finish and cannot go silent.
public struct SeenCompletionEpochs: Codable, Equatable, Sendable {
    public var documentEpoch: UUID?
    public var seen: [UUID: UInt32]

    public init(documentEpoch: UUID? = nil, seen: [UUID: UInt32] = [:]) {
        self.documentEpoch = documentEpoch
        self.seen = seen
    }
}

/// The device-local persistence seam for ``SeenCompletionEpochs``, wired by the app to
/// ``PreferencesStore``. Left default (tests, previews, headless) the map is in-memory only.
public struct CompletionSeenSeam {
    public var load: (() -> SeenCompletionEpochs?)?
    public var save: ((SeenCompletionEpochs) -> Void)?

    public init() {}
}

public extension WorkspaceStore {
    // MARK: - The counter

    /// Pane `id`'s completion counter as this client currently knows it: the host's when the document
    /// supplies one, this client's own overlay otherwise, `0` when nothing has ever finished.
    func paneCompletionEpoch(_ id: PaneID) -> UInt32 {
        observeWorkspaceMirror()
        return workspaceMirror.u32(.pane, documentPaneID(id), WorkspacePaneField.completionEpoch) ?? 0
    }

    /// Bumps this client's OWN counter for `id` — what runs before a snapshot lands, and a no-op the
    /// moment host truth holds the key (``WorkspaceMirrorBox/writeFastPath(_:_:)`` refuses to write
    /// over `entries`).
    ///
    /// Which is the point: the client's guess and the host's truth are the same KIND of value in the
    /// same slot, so a document arriving changes where the number comes from, not what it means.
    func bumpOwnCompletionEpoch(for id: PaneID) {
        let next = paneCompletionEpoch(id) &+ 1
        workspaceMirror.writeFastPath(
            WorkspaceKey(.pane, documentPaneID(id), WorkspacePaneField.completionEpoch),
            WorkspaceStateCodec.encodeU32(next),
        )
    }

    // MARK: - Seen

    /// Records that this device has read pane `id`'s current finish.
    func markCompletionSeen(_ id: PaneID) {
        let key = documentPaneID(id)
        let epoch = paneCompletionEpoch(id)
        guard seenCompletionEpoch[key] != epoch else { return }
        seenCompletionEpoch[key] = epoch
        persistCompletionSeen()
    }

    /// Recomputes `id`'s entry in ``WorkspaceStore/paneUnseenDone``.
    ///
    /// A finish you are LOOKING at is a finish you have seen. That is the rule the old latch spelled
    /// as "do not set it while the pane is visible" — said here, at the comparison, instead of at
    /// every edge that can move either side of it. Said only at the edge it loses to ordering: with
    /// the document live, the host's counter and this client's own `.done` arrive on different paths
    /// and in no guaranteed order.
    ///
    /// The comparison itself is ``PaneFacts/unseenDone(epoch:seen:isVisible:)``; what is here is the
    /// three writes its verdict names.
    func refreshUnseenDone(for id: PaneID) {
        switch PaneFacts.unseenDone(
            epoch: paneCompletionEpoch(id),
            seen: seenCompletionEpoch[documentPaneID(id)],
            isVisible: isSourcePaneVisible(id),
        ) {
        case .clear: paneUnseenDone.remove(id)
        case .seenThenClear:
            markCompletionSeen(id)
            paneUnseenDone.remove(id)
        case .mark: paneUnseenDone.insert(id)
        }
    }

    /// Recomputes every live pane's marker — what a host frame calls, since a diff can move any
    /// pane's counter without any local edge firing at all.
    func refreshUnseenDoneForAllPanes() {
        for id in tree.allPaneIDs() { refreshUnseenDone(for: id) }
    }

    // MARK: - Persistence

    /// Seeds the seen-map from the device store. Called once the app has wired ``completionSeen``.
    func loadCompletionSeen() {
        guard let record = completionSeen.load?() else { return }
        seenCompletionEpochDocument = record.documentEpoch
        seenCompletionEpoch = record.seen
        reconcileSeenCompletionEpochDocument()
        refreshUnseenDoneForAllPanes()
    }

    /// Files the seen-map under the live document, emptying it first when that is a switch.
    ///
    /// The three UUIDs are compared HERE and nowhere else, because they are identities this side
    /// owns: a `nil` live epoch (no channel, or not yet subscribed) is not evidence of a different
    /// document, and neither is ``WorkspaceStore/seedEpoch``, which is what the store's own restored
    /// layout carries until a real host frame arrives. What that reading MEANS for the map is
    /// ``PaneFacts/seenDocument(_:hasStored:)``.
    internal func reconcileSeenCompletionEpochDocument() {
        let live: UUID? = workspaceMirror.documentEpoch
        let identity: PaneFacts.DocumentIdentity =
            switch live {
            case nil,
                 Self.seedEpoch: .unanswered
            case seenCompletionEpochDocument: .adopted
            default: .new
            }
        switch PaneFacts.seenDocument(identity, hasStored: seenCompletionEpochDocument != nil) {
        case .ignore: return
        case .clearAndAdopt: seenCompletionEpoch.removeAll()
        case .adopt: break
        }
        seenCompletionEpochDocument = live
        persistCompletionSeen()
    }

    internal func persistCompletionSeen() {
        completionSeen.save?(SeenCompletionEpochs(
            documentEpoch: seenCompletionEpochDocument, seen: seenCompletionEpoch,
        ))
    }

    /// Drops entries for panes this client no longer has. Called from the reconcile prune — the map is
    /// device-local, so an entry for a pane that is gone from the tree can never be read again.
    internal func pruneCompletionSeen(keeping leaves: Set<PaneID>) {
        guard !seenCompletionEpoch.isEmpty else { return }
        let live = Set(leaves.map { documentPaneID($0) })
        let kept = seenCompletionEpoch.filter { live.contains($0.key) }
        guard kept.count != seenCompletionEpoch.count else { return }
        seenCompletionEpoch = kept
        persistCompletionSeen()
    }
}
