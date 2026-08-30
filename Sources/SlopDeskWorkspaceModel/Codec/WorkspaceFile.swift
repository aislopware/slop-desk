import CSlopDeskFFI
import Foundation

/// The client's `workspace.json`: the arrangement a launch restores, read and written by
/// `slopdesk_workspace::persist`.
///
/// **This file is a BOUNDARY, not an implementation**, for the reason ``WorkspaceStateFile`` is one:
/// the rule was written twice. `SplitNode+Codable.swift` plus the `Codable` conformances on
/// ``TreeWorkspace``, ``Session``, ``Tab`` and ``PaneSpec`` were a second decoder for the same file,
/// and the two had already stopped agreeing where a person could feel it. An unnamed split — a
/// `{"split": {...}}` object with no `id`, which is what a hand-edited or older file carries — was
/// named `?? SplitNodeID()` here: a FRESH uuid on every load. The crate DERIVES the name from the
/// divider's place in the tree, so two loads of one file agree. Divider drags are persisted as
/// `splitNode/<id>/weight`, so under the Swift decoder every drag a person had made was orphaned on
/// the next launch and every seam snapped back to the default, with nothing logged. `docs/55` §8's
/// `derived_split_id` row is what this closes; `SplitNodeDecodeRepairTests`'s
/// `testTheSameFileNamesTheSameDividersOnEveryLoad` is what holds it closed.
///
/// **Nothing here decides anything.** No version check, no repair, no tolerance rule — every branch
/// below is a discriminant coming back across a C boundary into the vocabulary a Swift `catch` reads,
/// which is the one thing that could not cross. The reasoning each repair carries — why an unreadable
/// `axis` is filled and an unreadable `specs` ELEMENT is a fault, why a spec-less leaf is re-seeded
/// and a spec-less detached entry dropped — lives once, in `persist.rs`. Restating it here is how the
/// two copies got written the first time.
public enum WorkspaceFile {
    /// How many panes one file may name before ``decode(_:)`` refuses it as ``FileError/tooManyPanes``.
    ///
    /// Asked for, never spelled here: an in-process cap crosses through a door, which is the rule
    /// `shared-number-asked-or-ratcheted` states and `WorkspaceTopology.closedTabRingCap` already
    /// follows. This one is a REFUSAL threshold, so two copies drifting would not read as a
    /// disagreement — this side would write a file it believes fits, the far side would refuse it,
    /// and the user would meet a workspace reset to the default with nothing saying why.
    public static let maxPanes = slopdesk_ws_workspace_file_max_panes()

    // MARK: - Codec

    /// The file's bytes for a workspace. Cannot fail, which is why it does not throw: the encoder it
    /// replaced was a `JSONEncoder` whose `throws` this path spent years never taking.
    ///
    /// The tree crosses as the DOCUMENT's own cells, exactly as ``WorkspaceIntentApplier`` and
    /// ``TreeWorkspace``'s repair pass send one: a `TreeWorkspace` is a split tree, and there is no
    /// `#[repr(C)]` flattening of one that is not a second grammar somebody has to keep in step with
    /// the first. What comes back is UTF-8 JSON with sorted keys and a trailing newline, so two saves
    /// of one arrangement are byte-identical and the file diffs cleanly.
    ///
    /// Only the TOPOLOGY half of the document is written — the file is the layout, and liveness has
    /// no business on a disk that outlives the process it describes. The two shapes the cells cannot
    /// spell (a session with no tab, a detached pane with no spec) cannot reach here either: they are
    /// what the load path REPAIRS, so a tree that came from one is already free of them.
    ///
    /// ``TreeWorkspace/schemaVersion`` rides beside the cells rather than in them, because the
    /// document has no cell for it — it is a property of this FILE and not of the shape, which is
    /// what ``WorkspaceTopologyOmissions`` says out loud. The value written is the TREE's, so a save
    /// cannot quietly re-stamp a workspace as the shape this build happens to read.
    public static func encode(_ tree: TreeWorkspace) -> Data {
        var blob = WsBlob()
        var cells = WorkspaceTopology(tree: tree).entries().map { blob.entry($0) }
        let version = Int64(tree.schemaVersion)
        return blob.lend { arena in
            cells.withUnsafeMutableBufferPointer { cell in
                wsBytes { out, cap in
                    slopdesk_ws_workspace_file_encode(
                        cell.baseAddress,
                        cell.count,
                        arena.baseAddress,
                        arena.count,
                        version,
                        out,
                        cap,
                    )
                }
            }
        }
    }

    /// What a load can refuse with.
    ///
    /// Three arms because the caller's answer differs across them, and because a `DecodingError` from
    /// Foundation — which is what the Swift decoder threw for all three — named none of them. The
    /// caller keeps the file aside and mints a default either way; what changes is what it can say.
    public enum FileError: Error, Equatable {
        /// The bytes are not the file this build writes — not JSON, not UTF-8, or JSON with no
        /// workspace in it.
        case malformed
        /// The file is from a different shape of this store. Not migrated: the standing rule is that
        /// stale data degrades to the default rather than being carried forward.
        case versionMismatch(Int)
        /// The file names more panes than a launch can materialize. Refused WHOLE rather than
        /// truncated: a workspace with an arbitrary half of its panes missing is one the person has
        /// to work out the shape of, and the file itself is kept.
        case tooManyPanes
    }

    /// Reads a file back into a workspace, already REPAIRED.
    ///
    /// The repair is the crate's and it runs before the answer crosses, which is forced rather than
    /// chosen: the document's cells cannot spell a session with no tab or a leaf with no spec, and a
    /// file can hold both. So the decode ends where a launch already ended — at
    /// ``TreeWorkspace/normalized()`` — and the shape the crossing cannot carry never reaches it.
    ///
    /// The identity pool is minted HERE because the crate holds no entropy on purpose, and its SIZE
    /// is asked of the file rather than guessed from the shape: the shape is exactly what a caller
    /// does not know before the parse, and a pool one short REPEATS an identity rather than failing —
    /// two panes sharing one is a pane that reattaches to a process it never opened. Only panes,
    /// tabs and sessions are minted; a divider's name is derived from the file, which is the whole
    /// point of this door.
    public static func decode(_ data: Data) throws -> TreeWorkspace {
        var bytes = [UInt8](data)
        let pool = (0..<mintedIDs(for: bytes)).map { _ in SlopDeskWsUuid(UUID()) }
        var status = UInt8.max
        // Untouched unless the refusal is the one that names a version — every `Int64` is a version a
        // hand edit can type, so no value could have meant "not about a version".
        var claimed = Int64.min

        let snapshot = bytes.withUnsafeMutableBufferPointer { input in
            pool.withUnsafeBufferPointer { ids in
                withUnsafeMutablePointer(to: &status) { verdict in
                    withUnsafeMutablePointer(to: &claimed) { version in
                        wsBytes { out, cap in
                            slopdesk_ws_workspace_file_decode(
                                input.baseAddress,
                                input.count,
                                ids.baseAddress,
                                ids.count,
                                verdict,
                                version,
                                out,
                                cap,
                            )
                        }
                    }
                }
            }
        }

        switch status {
        case Refusal.ok: break
        case Refusal.malformed: throw FileError.malformed
        case Refusal.versionMismatch: throw FileError.versionMismatch(Int(claimed))
        case Refusal.tooManyPanes: throw FileError.tooManyPanes
        // A byte this build has no case for is a refusal, not a crash: the door is compiled from the
        // same tree, so it cannot happen — and if it ever does, refusing is what keeps the caller on
        // the default workspace instead of a half-read one.
        default: throw FileError.malformed
        }

        // A load that succeeded and then handed back bytes the codec refuses is not a refusal on the
        // merits — it is this boundary having gone wrong, and the honest report for that is the same
        // one a file of nonsense gets.
        guard let state = try? WorkspaceStateCodec.decodeSnapshot(snapshot),
              var tree = state.topology?.tree
        else { throw FileError.malformed }
        // The document has no `schemaVersion` — it is a property of this FILE, not of the shape (see
        // ``WorkspaceTopologyOmissions``) — so it is restored here. The door already refused every
        // other version, so this is the one the file carried.
        tree.schemaVersion = TreeWorkspace.currentSchemaVersion
        return tree
    }

    /// Whether `data` is the THROWAWAY DEFAULT a `New Window` launch autosaves — one session named
    /// the crate's seed name, one tab, one terminal titled the crate's seed title, no video.
    ///
    /// Asked of the FILE rather than of a decoded tree, which is the whole reason it is a door: the
    /// alternative is decoding here and comparing the two seed names against
    /// ``TreeWorkspaceDefaults``, and a shape test written against those would keep answering `true`
    /// for a default the crate had stopped writing — `docs/55` §8's anti-pattern, one indirection
    /// removed.
    ///
    /// `false` is "not PROVABLY the default" and folds in undecodability: a corrupt file, a foreign
    /// `schemaVersion` and an over-large one all answer `false`, which is what makes
    /// ``WorkspacePersistence/snapshotPreviousSession()`` preserve one aside instead of skipping it.
    /// It is not a claim that the bytes hold a real session.
    public static func isDefaultShape(_ data: Data) -> Bool {
        Array(data).withUnsafeBufferPointer { input in
            slopdesk_ws_workspace_file_is_default_shape(input.baseAddress, input.count)
        }
    }

    /// How many identities a decode of these bytes can spend.
    private static func mintedIDs(for bytes: [UInt8]) -> Int {
        bytes.withUnsafeBufferPointer { input in
            slopdesk_ws_workspace_file_minted_ids(input.baseAddress, input.count)
        }
    }

    /// The crate's own refusal bytes, by arm order. Read from the door rather than written down: a
    /// transcribed copy that drifted on one arm would write over the file a person's whole
    /// arrangement is in instead of keeping it aside.
    private enum Refusal {
        static let ok = slopdesk_ws_workspace_file_status(0)
        static let malformed = slopdesk_ws_workspace_file_status(1)
        static let versionMismatch = slopdesk_ws_workspace_file_status(2)
        static let tooManyPanes = slopdesk_ws_workspace_file_status(3)
    }
}
