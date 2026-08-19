import CSlopDeskFFI
import Foundation

/// What of the workspace document survives a host restart, and in what shape on disk.
///
/// **This file is a BOUNDARY, not an implementation, which is why it lives in `Codec/` beside
/// ``WorkspaceStateCodec`` rather than in `State/` where the rule used to.** It was 129 lines of
/// Swift that were a near-verbatim second copy of `rust/slopdesk-wire`'s `document::state_file` —
/// the same version constant, the same persisted-field set, the same three-arm refusal, the same
/// base64 rows — and two answers to "may this cell touch the disk" do not conflict, they RENDER:
/// the wider one brings a pane back as `liveness: attached` with no process behind it, the narrower
/// one loses the arrangement the person made, and neither says anything. `docs/55` §6 is the shape;
/// the Swift original was deleted in the same change that opened the door.
///
/// **Nothing here decides anything.** No version check, no field filter, no repair — every branch
/// below is a discriminant coming back across a C boundary into the vocabulary a Swift `catch`
/// reads, which is the one thing that could not cross. What the module still owes its callers is the
/// signature they already had, so the three call sites and the tests did not move: that is what
/// makes "delete the original in the same change" a diff a reviewer can check.
///
/// The reasoning the rule carries — why JSON, why the filter, why an unknown kind is dropped rather
/// than migrated — lives once, in the crate. Restating it here is how the two copies got written the
/// first time.
public enum WorkspaceStateFile {
    // MARK: - Policy

    /// Whether one cell survives a restart.
    ///
    /// ASKED, not decided here, exactly as ``WorkspaceTopology/isTopology(_:)`` is. The rule reads a
    /// KIND and a FIELD and nothing else — a pane splits by field, its `title` surviving where its
    /// `liveness` must not, one byte apart under the same object id — so the crossing is two bytes
    /// and the answer is a `Bool`. The three wholly-persisted kinds, the pane split, the project's
    /// path-yes/git-summary-no line and the deliberate `false` for a kind from a newer build all
    /// live on the far side.
    public static func isPersisted(_ key: WorkspaceKey) -> Bool {
        slopdesk_ws_state_file_is_persisted(key.kind, key.field)
    }

    /// The state reduced to what belongs on disk.
    ///
    /// A loop over the caller's own cells rather than a crossing of the whole document, because the
    /// predicate reads neither the object id nor the value: handing a state over to have it handed
    /// back minus some rows would marshal every byte twice to ask about two. The loop is not a
    /// decision — every branch inside it is behind ``isPersisted(_:)``.
    public static func persisting(_ state: HostWorkspaceState) -> HostWorkspaceState {
        var out = HostWorkspaceState()
        for entry in state.sortedEntries where isPersisted(entry.key) {
            out.set(entry.key, entry.value)
        }
        return out
    }

    // MARK: - Codec

    /// The file's bytes. Cannot fail, which is why it no longer throws: the encoder it wrapped was a
    /// `JSONEncoder` whose `throws` this file spent years never taking.
    ///
    /// The cells cross in ``WorkspaceStateCodec/encodeSnapshot(_:)``'s flat `(entry, blob)` form —
    /// one pointer and one lifetime for hundreds of values — and what comes back is UTF-8 JSON with
    /// sorted keys and canonical entry order, so two saves of one value are byte-identical.
    ///
    /// Takes the state AS GIVEN. Filtering is ``persisting(_:)``'s job and the caller's call, which
    /// is what lets ``decode(_:)`` re-run the same filter inbound without either side being the one
    /// that quietly did it twice.
    public static func encode(_ state: HostWorkspaceState) -> Data {
        var blob = WsBlob()
        var flat = state.sortedEntries.map { blob.entry($0) }
        return blob.lend { bytes in
            flat.withUnsafeMutableBufferPointer { input in
                wsBytes { out, cap in
                    slopdesk_ws_state_file_encode(
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

    /// What a load can refuse with.
    ///
    /// Three arms because the caller's answer differs across them, and the crate's own enum has had
    /// three since it was written. The Swift copy had only TWO — "these bytes are not our file at
    /// all" reached ``HostWorkspaceStore`` as a raw `DecodingError` from Foundation, so the one
    /// refusal a hand-edited or truncated file most often produces was the one the taxonomy could
    /// not name. It can now.
    public enum FileError: Error, Equatable {
        /// The bytes are not the document this build writes — not JSON, not UTF-8, or JSON with no
        /// document in it. The caller mints a default and keeps the old file aside.
        case malformed
        /// The file is from a different shape of this store. Not migrated: the standing rule is that
        /// stale data degrades to the default rather than being carried forward.
        case versionMismatch(Int)
        /// A row this build cannot make sense of. One bad row fails the whole load ON PURPOSE — a
        /// partially-restored workspace is a workspace with holes in it, and the person would have
        /// to work out which half is real.
        case malformedRow
    }

    /// Reads a file back into a state, already re-filtered on the way IN.
    ///
    /// The inbound filter is the crate's, not a second pass here: the file is the one input a person
    /// can edit by hand, and a hand-set `liveness: attached` must not come back as a pane with no
    /// process behind it. What crosses back is an encoded SNAPSHOT — the document's own byte
    /// encoding, the one every client already decodes off a host's push — so no grammar exists here
    /// for anyone to keep in step.
    public static func decode(_ data: Data) throws -> HostWorkspaceState {
        var bytes = [UInt8](data)
        var status = UInt8.max
        // Untouched unless the refusal is the one that names a version — every `Int64` is a version a
        // hand edit can type, so no value could have meant "not about a version".
        var claimed = Int64.min

        let snapshot = bytes.withUnsafeMutableBufferPointer { input in
            withUnsafeMutablePointer(to: &status) { verdict in
                withUnsafeMutablePointer(to: &claimed) { version in
                    wsBytes { out, cap in
                        slopdesk_ws_state_file_decode(
                            input.baseAddress,
                            input.count,
                            verdict,
                            version,
                            out,
                            cap,
                        )
                    }
                }
            }
        }

        switch status {
        case Refusal.ok: break
        case Refusal.malformed: throw FileError.malformed
        case Refusal.versionMismatch: throw FileError.versionMismatch(Int(claimed))
        case Refusal.malformedRow: throw FileError.malformedRow
        // A byte this build has no case for is a refusal, not a crash: the door is compiled from the
        // same tree, so it cannot happen — and if it ever does, refusing is what keeps the caller on
        // the default document instead of a half-read one.
        default: throw FileError.malformed
        }

        // A load that succeeded and then handed back bytes the codec refuses is not a refusal on the
        // merits — it is this boundary having gone wrong, and the honest report for that is the same
        // one a file of nonsense gets.
        guard let state = try? WorkspaceStateCodec.decodeSnapshot(snapshot) else {
            throw FileError.malformed
        }
        return state
    }

    /// The crate's own refusal bytes, by arm order. Read from the door rather than written down: a
    /// transcribed copy that drifted on one arm would turn a corrupt row into a mint-the-default,
    /// and the old file would not be kept aside.
    private enum Refusal {
        static let ok = slopdesk_ws_state_file_status(0)
        static let malformed = slopdesk_ws_state_file_status(1)
        static let versionMismatch = slopdesk_ws_state_file_status(2)
        static let malformedRow = slopdesk_ws_state_file_status(3)
    }
}
