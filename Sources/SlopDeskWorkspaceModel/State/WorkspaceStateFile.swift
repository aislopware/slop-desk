import Foundation

/// What of the workspace document survives a host restart, and in what shape on disk.
///
/// **JSON here is deliberate and is not a contradiction of the manual-binary rule — that rule is
/// about the WIRE.** This file is read once at start by the process that wrote it; determinism and
/// reviewability matter, latency does not.
///
/// The interesting half is not the encoding but the FILTER. Serializing the entry map wholesale
/// would restore `commandRunning = 1`, `agentState = working` and a `liveness` of `attached` for a
/// pane whose child exited weeks ago — a workspace of fake-live rows, busy dots spinning for nothing.
/// `DetachedSessionStore` is in-process, so no live process survives a restart and the document must
/// come back saying exactly that.
public enum WorkspaceStateFile {
    /// Bumped when the on-disk shape changes. It exists to force a decode-fail, not to migrate: the
    /// standing rule is that stale data degrades to the default rather than being carried forward,
    /// and the caller's answer to a failed decode is the default document plus the old file kept
    /// aside.
    public static let version = 1

    // MARK: - Policy

    /// The pane fields that survive a restart.
    ///
    /// Deliberately NOT the topology half: `cwd` and `projectKey` are liveness — the host re-derives
    /// them from a live shell — yet they persist, because a restored pane has no shell to ask and the
    /// By-Project sidebar would otherwise re-bucket visibly on the first live edge. They are the only
    /// two liveness fields that describe a PLACE rather than a running process, which is exactly why
    /// they are safe to restore and the rest are not.
    public static let persistedPaneFields: Set<UInt8> = Set(PaneLiveness.topologyFields())
        .union([WorkspacePaneField.cwd, WorkspacePaneField.projectKey])

    /// Whether one cell survives a restart.
    ///
    /// An unknown `kindTag` — a file written by a NEWER build — is dropped rather than carried. That
    /// is the no-migration directive, not an oversight: keeping bytes this build can neither read nor
    /// reap would leave ghost objects in the document with nothing able to remove them.
    public static func isPersisted(_ key: WorkspaceKey) -> Bool {
        switch WorkspaceObjectKind(rawValue: key.kind) {
        case .root,
             .session,
             .tab,
             .splitNode:
            true
        case .pane:
            persistedPaneFields.contains(key.field)
        case .project:
            // The path survives; the git summary does not. FSEvents re-derives it within a tick, and
            // a restored summary would describe a working tree that has moved on.
            key.field == WorkspaceProjectField.key
        case nil:
            false
        }
    }

    /// The state reduced to what belongs on disk.
    public static func persisting(_ state: HostWorkspaceState) -> HostWorkspaceState {
        var out = HostWorkspaceState()
        for entry in state.sortedEntries where isPersisted(entry.key) {
            out.set(entry.key, entry.value)
        }
        return out
    }

    // MARK: - Codec

    private struct Row: Codable {
        var kind: UInt8
        var id: String
        var field: UInt8
        /// Base64. A zero-length value encodes as `""` and stays distinct from an absent row — an
        /// empty value is how a field is RETIRED, and conflating the two would resurrect a title the
        /// agent gave up.
        var value: String
    }

    private struct Document: Codable {
        var version: Int
        var entries: [Row]
    }

    /// Sorted keys and canonical entry order, so two saves of one value are byte-identical and the
    /// file diffs cleanly. Pretty-printed for the same reason the client's workspace file is: a
    /// persistence file nobody can read is a persistence file nobody can debug.
    public static func encode(_ state: HostWorkspaceState) throws -> Data {
        let document = Document(
            version: version,
            entries: state.sortedEntries.map {
                Row(
                    kind: $0.key.kind,
                    id: $0.key.objectID.uuidString,
                    field: $0.key.field,
                    value: $0.value.base64EncodedString(),
                )
            },
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(document)
    }

    public enum FileError: Error, Equatable {
        /// The file is from a different shape of this store. Not migrated — the caller mints a
        /// default and keeps the old file aside.
        case versionMismatch(Int)
        /// A row this build cannot make sense of. One bad row fails the whole load ON PURPOSE: a
        /// partially-restored workspace is a workspace with holes in it, and the user would have to
        /// work out which half is real.
        case malformedRow
    }

    public static func decode(_ data: Data) throws -> HostWorkspaceState {
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version == version else { throw FileError.versionMismatch(document.version) }
        var state = HostWorkspaceState()
        for row in document.entries {
            guard let objectID = UUID(uuidString: row.id),
                  let value = Data(base64Encoded: row.value)
            else { throw FileError.malformedRow }
            let key = WorkspaceKey(kind: row.kind, objectID: objectID, field: row.field)
            // Re-filtered on the way IN as well as out. A hand-edited file could otherwise restore a
            // pane as `liveness: attached` with no process behind it, which is the exact render the
            // filter exists to prevent — and the file is the one input a user can edit by hand.
            guard isPersisted(key) else { continue }
            state.set(key, value)
        }
        return state
    }
}
