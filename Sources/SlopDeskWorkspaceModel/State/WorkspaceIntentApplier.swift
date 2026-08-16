import CSlopDeskFFI
import Foundation

/// Turns one client's request into a new topology, or into a refusal.
///
/// **Pure, and deliberately shared by both ends.** The host runs it to decide what the document
/// becomes; the client runs the SAME function to build its optimistic overlay. Two implementations
/// of "what does a split do" would drift, and the drift would look exactly like a sync bug — the
/// client showing one layout and the host publishing another, with no way to tell which is wrong.
///
/// **The decision is `slopdesk_wire::document::apply`** (docs/55). It was a Swift `switch` over 27
/// ops here until 2026-08-16, and moving it did not change what "both ends" means — it narrowed it:
/// the host and the client used to share a Swift function, and now every client on every platform
/// shares one compiled object. What is left on this side is the marshalling, which is the only part
/// that could not cross.
///
/// ## Why a topology crosses as the document's own bytes
/// A ``WorkspaceTopology`` is a split tree, and a tree does not flatten into a `#[repr(C)]` struct
/// without inventing a grammar for it. It does not have to: the topology already HAS a byte
/// encoding — the one every client decodes off the socket. So the document goes over as the flat
/// cells ``WorkspaceStateCodec/encodeSnapshot(_:)`` already builds, and the answer comes back as an
/// encoded snapshot read by ``WorkspaceStateCodec/decodeSnapshot(_:)``. Nothing here is a shape
/// anyone has to keep in step with anything.
public enum WorkspaceIntentApplier {
    /// Applies one intent.
    ///
    /// - Parameters:
    ///   - documentIsPristine: whether the document is still the untouched default. Only
    ///     ``WorkspaceIntentOp/adoptWorkspace`` reads it — a bootstrap that arrives after the host
    ///     has a real workspace is `rejectedStale`, and the loser keeps its tree rather than losing
    ///     it.
    ///   - projectKey: a pane's resolved By-Project key
    ///     (``TabOrderingEngine/paneProjectKey(_:projectKey:cwd:)`` over the caller's own cells).
    ///     Only the close ops read it, to keep focus inside the section the closed tab lived in.
    ///     Every caller that owns a document supplies it; the default puts every pane in one
    ///     section, which reduces the close rule to MRU-then-array-neighbour and is what a caller
    ///     with no document cells to read — a tree-op unit test — wants.
    public static func apply(
        op rawOp: UInt8,
        args: Data,
        to topology: WorkspaceTopology,
        documentIsPristine: Bool = false,
        projectKey: (PaneID) -> String? = { _ in nil },
    ) -> WorkspaceIntentOutcome {
        // ONE blob backs both span kinds. The crate resolves an entry's value and a pane's project
        // key against the same bytes, so a second buffer would be a second lifetime to get right for
        // no property — and the offsets are the part a boundary bug shows up in.
        var blob = WsBlob()
        var cells = topology.entries().map { blob.entry($0) }
        var keys = keyedPanes(of: topology, projectKey, into: &blob)

        // Minted HERE because the crate mints nothing: identity is a host fact on one path and a
        // client guess on the other, and a rule that invented UUIDs internally could not be run
        // twice on the same input and compared. The client's optimistic guess differing from the
        // host's is exactly what the pending patch layer exists to reconcile.
        let minted = (0..<slopdesk_ws_minted_ids_per_intent()).map { _ in SlopDeskWsUuid(UUID()) }
        var status = UInt8.max
        var payload = [UInt8](args)

        let answer = blob.lend { arena in
            cells.withUnsafeMutableBufferPointer { cell in
                keys.withUnsafeMutableBufferPointer { key in
                    minted.withUnsafeBufferPointer { pool in
                        payload.withUnsafeMutableBufferPointer { bytes in
                            withUnsafeMutablePointer(to: &status) { verdict in
                                wsBytes { out, cap in
                                    slopdesk_ws_apply_intent(
                                        rawOp,
                                        bytes.baseAddress,
                                        bytes.count,
                                        cell.baseAddress,
                                        cell.count,
                                        key.baseAddress,
                                        key.count,
                                        arena.baseAddress,
                                        arena.count,
                                        pool.baseAddress,
                                        pool.count,
                                        documentIsPristine,
                                        verdict,
                                        out,
                                        cap,
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }

        guard status == Verdict.applied else { return outcome(for: status) }
        // An applied intent that hands back bytes the codec refuses is not a refusal on the merits —
        // it is this boundary having gone wrong, and `rejectedInvalid` is the only answer that keeps
        // the caller's document as it was rather than replacing it with a half-read one.
        guard let state = try? WorkspaceStateCodec.decodeSnapshot(answer), let next = state.topology
        else { return .rejectedInvalid }
        return .applied(next)
    }

    /// The panes the close rule may ask a key for, paired with the caller's answer.
    ///
    /// Every pane the document names, live or on the reopen ring — the same union
    /// ``WorkspaceTopology`` prunes by. Over-supplying costs one span each; under-supplying would
    /// silently move a closed tab's successor into another project's section, which is the bug the
    /// key exists to prevent.
    private static func keyedPanes(
        of topology: WorkspaceTopology,
        _ projectKey: (PaneID) -> String?,
        into blob: inout WsBlob,
    ) -> [SlopDeskWsKeyedPane] {
        let panes = Set(topology.tree.sessions.flatMap(\.specs.keys))
            .union(topology.closedTabs.flatMap(\.specs.keys))
        return panes.compactMap { pane in
            guard let key = projectKey(pane) else { return nil }
            return blob.keyed(pane.raw, key)
        }
    }

    /// The crate's own status bytes, which are the WIRE's (``WorkspaceIntentStatus``) and therefore
    /// golden-pinned. Read from the crate rather than written down: a frozen number may live in one
    /// place, and that place is where the frames are built.
    private enum Verdict {
        static let applied = slopdesk_ws_intent_status(0)
        static let rejectedStale = slopdesk_ws_intent_status(1)
        static let rejectedInvalid = slopdesk_ws_intent_status(2)
        static let rejectedNotFound = slopdesk_ws_intent_status(3)
        static let unknownOp = slopdesk_ws_intent_status(4)
    }

    private static func outcome(for status: UInt8) -> WorkspaceIntentOutcome {
        switch status {
        case Verdict.applied: .rejectedInvalid // Unreachable: the caller checked. Never `.applied` without a tree.
        case Verdict.rejectedStale: .rejectedStale
        case Verdict.rejectedNotFound: .rejectedNotFound
        case Verdict.unknownOp: .unknownOp
        case Verdict.rejectedInvalid: .rejectedInvalid
        // A byte this build has no case for is a refusal, not a crash: the door is compiled from the
        // same tree, so it cannot happen — and if it ever does, refusing leaves the document intact.
        default: .rejectedInvalid
        }
    }
}

extension WsBlob {
    /// A pane's project key, appended to the blob the entries already span.
    mutating func keyed(_ pane: UUID, _ key: String) -> SlopDeskWsKeyedPane {
        SlopDeskWsKeyedPane(id: SlopDeskWsUuid(pane), key: span(key))
    }
}
