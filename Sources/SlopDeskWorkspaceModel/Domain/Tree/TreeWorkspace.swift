import CSlopDeskFFI
import Foundation

// MARK: - TreeWorkspace (the tree-rooted workspace container — transitional name)

/// The tree-rooted workspace container for the `Session → Tab → Pane` redesign (docs/42 §Domain model).
/// It holds `[Session]` + the active session and NOTHING device-local: the preset library, the latched
/// video modes and the per-host connection target live in ``DevicePreferences`` (docs/45 §7.3), because
/// the tree describes THE LAYOUT — which every attached client shares — and those describe one machine.
/// A pure `Equatable`/`Sendable` value with no SwiftUI or transport import — and deliberately not
/// `Codable`: the file it is persisted to is read and written by `rust/slopdesk-workspace`, through
/// ``WorkspaceFile``.
///
/// **Transitional name (W2 is purely additive).** The plan's final type name for this is `Workspace`
/// (docs/42 §Domain model, `currentSchemaVersion = 11`), but the live ``Workspace`` (the v9 canvas value)
/// is still the persistence format and the store/views reference it. W2 must **not** rewrite or replace
/// it — the build must stay green and every existing test must still pass. So this container ships under
/// the transitional name `TreeWorkspace`; the store cutover (W4) promotes it to `Workspace` once the
/// canvas path is retired. Choosing a distinct name (vs. the plan's `Workspace`) is the one deliberate
/// deviation — it is exactly the additive-coexistence constraint the W2 brief mandates.
///
/// **Invariant — specs == leafIDs.** For every session, `Set(session.specs.keys)` equals the set of leaf
/// ids across all of that session's tabs. ``isInvariantHeld()`` checks it; the ops preserve it and
/// ``normalizingSpecs()`` repairs a corrupt file.
public struct TreeWorkspace: Sendable, Equatable {
    /// The persisted schema version for the tree-rooted shape (docs/42 §Domain model). 10 = this shape.
    public var schemaVersion: Int
    /// The sessions, in sidebar order. ≥ 1 (the workspace is never empty — see ``normalizingActive()``).
    public var sessions: [Session]
    /// The selected session, or `nil` only transiently before repair.
    public var activeSessionID: SessionID?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        sessions: [Session],
        activeSessionID: SessionID?,
    ) {
        self.schemaVersion = schemaVersion
        self.sessions = sessions
        self.activeSessionID = activeSessionID
    }

    /// The schema version this shape writes. A file carrying any OTHER version is not migrated — the
    /// load path resets it aside (single-user, no backward compatibility). The retained-but-dead
    /// canvas ``Workspace`` owns its own `currentSchemaVersion = 9`.
    ///
    /// 12 is the shape whose device-local half lives in ``DevicePreferences``. The bump is what makes
    /// the no-migration rule TRUE rather than merely stated: the retired keys are keys no decoder
    /// reads, so a file from the previous shape would otherwise load "successfully" and the next
    /// autosave would rewrite it without the user's presets, templates and latched video modes —
    /// silently, with no `.corrupt` copy kept. A version this build does not speak resets aside
    /// instead, which keeps the old file recoverable.
    ///
    /// ASKED for rather than spelled: `slopdesk_workspace` writes this number into every snapshot it
    /// encodes, so a second spelling here would be the two halves of one comparison, each free to
    /// move without the other.
    public static let currentSchemaVersion = Int(slopdesk_ws_schema_version())
}

// MARK: - Construction

public extension TreeWorkspace {
    /// A fresh workspace: one session ("Local"), one tab, one leaf carrying `spec`. The
    /// fresh-launch / re-seed shape (mirrors ``Workspace/defaultWorkspace()`` for the new model).
    static func singlePane(spec: PaneSpec) -> TreeWorkspace {
        let session = Session.singlePane(name: TreeWorkspaceDefaults.sessionName, spec: spec)
        return TreeWorkspace(sessions: [session], activeSessionID: session.id)
    }

    /// The default workspace: one "Local" session with a single terminal pane.
    static func defaultWorkspace() -> TreeWorkspace {
        singlePane(spec: PaneSpec(kind: .terminal, title: TreeWorkspaceDefaults.paneTitle))
    }
}

/// The two strings a re-seed writes, ASKED for rather than written down here.
///
/// The crate re-seeds too — a spec-less leaf, a session that lost its tabs, a workspace with nothing
/// in it — so a copy of either literal on this side is a second answer to "what is a fresh pane
/// called". It would not fail loudly: the pane would simply be titled one thing when a gesture made
/// it and another when a launch repaired it, and the shape test
/// (``WorkspacePersistence/isDefaultTreeShape(_:)``) that compares against a spelled-out `"Terminal"`
/// would pass on a default the crate had stopped producing. `docs/55` §8 names this exact
/// anti-pattern.
public enum TreeWorkspaceDefaults {
    /// The title a re-seeded pane takes.
    public static let paneTitle = wsString { out, cap in slopdesk_ws_default_pane_title(out, cap) }
    /// The name a fresh workspace's first session takes.
    public static let sessionName = wsString { out, cap in slopdesk_ws_default_session_name(out, cap) }
}

/// A §4-shaped door's answer as text. Empty when the crate answered nothing, which none of the
/// callers here can produce.
private func wsString(_ call: (UnsafeMutablePointer<UInt8>?, Int) -> Int) -> String {
    // Non-failable on purpose: what comes back is a `&'static str` the crate spelled, so it is UTF-8
    // by construction and a failable initialiser would only add an arm no answer can reach.
    // swiftlint:disable:next optional_data_string_conversion
    String(decoding: wsBytes(call), as: UTF8.self)
}

// MARK: - Facade the store consumes (docs/42 §"Facade the store consumes")

public extension TreeWorkspace {
    /// Every ``PaneID`` across every session → tab → split tree, in deterministic DFS order (session
    /// order, then tab order, then pre-order tree). Drives focus cycling + the store's reconcile diff.
    /// Deliberately EXCLUDES detached panes — tree membership drives focus/zoom/tab semantics; the
    /// store's reconcile unions in ``detachedPaneIDs()`` separately so detached handles stay live.
    func allPaneIDs() -> [PaneID] {
        sessions.flatMap { $0.allPaneIDs() }
    }

    /// Every pane detached into its own window, across every session in session order then detach order.
    /// The store's reconcile unions this with ``allPaneIDs()`` as the desired registry set.
    func detachedPaneIDs() -> [PaneID] {
        sessions.flatMap { $0.detached.map(\.pane) }
    }

    /// Whether `id` is detached into its own window in any session.
    func isDetached(_ id: PaneID) -> Bool {
        sessions.contains { $0.isDetached(id) }
    }

    /// The ``PaneSpec`` for `id`, searched across every session's side table (the owning session's spec).
    func spec(for id: PaneID) -> PaneSpec? {
        for session in sessions {
            if let spec = session.spec(for: id) { return spec }
        }
        return nil
    }

    /// The (session, tab) ids owning leaf `id`, or `nil` if absent.
    func tab(containing id: PaneID) -> (SessionID, TabID)? {
        for session in sessions {
            for tab in session.tabs where tab.contains(id) {
                return (session.id, tab.id)
            }
        }
        return nil
    }

    /// The selected session (the one `activeSessionID` names), or `nil` before repair.
    var activeSession: Session? {
        guard let id = activeSessionID else { return sessions.first }
        return sessions.first { $0.id == id } ?? sessions.first
    }

    /// The index of the active session in ``sessions``, or `nil`.
    var activeSessionIndex: Int? {
        guard let id = activeSessionID else { return sessions.isEmpty ? nil : 0 }
        return sessions.firstIndex { $0.id == id } ?? (sessions.isEmpty ? nil : 0)
    }

    /// Whether `id` is a leaf anywhere in the workspace.
    func contains(_ id: PaneID) -> Bool {
        sessions.contains { $0.contains(id) }
    }
}

// MARK: - Invariant check (specs == leafIDs)

public extension TreeWorkspace {
    /// The load-bearing invariant: for every session, the spec side table's keys equal the set of leaf
    /// ids across all of that session's tabs UNION its detached panes
    /// (`Set(specs.keys) == leafIDSet() ∪ detachedIDSet()`). A checkable property the ops preserve and
    /// the tests assert after every op. Pure.
    func isInvariantHeld() -> Bool {
        for session in sessions
            where Set(session.specs.keys) != session.leafIDSet().union(session.detachedIDSet())
        {
            return false
        }
        return true
    }
}

// MARK: - Normalizing repairs (applied on load — never crash on a hand-edited file)

/// Every repair below is `rust/slopdesk-workspace`'s, reached through `slopdesk_ws_normalize`.
///
/// **It was implemented twice until 2026-08-20, and the two copies did not shadow each other.** This
/// one fired on FILE LOAD (`WorkspacePersistence.loadTree`, the store's bootstrap and its launch
/// restore); the crate's fired on EVERY INTENT, through `tree_ops`. So launch-time repair and
/// gesture-time repair reached different trees for the same input, and a workspace that closed
/// cleanly came back subtly different after a relaunch. Four disagreements were live and none of
/// them logged anything (`docs/55` §8):
///
/// - which panes count as VIDEO. Here it was `spec.kind == .desktop`; there it is
///   `PaneKind::is_video`. The two select the same panes today because `PaneKind` has two cases, and
///   they stop agreeing the moment a third video-ish kind is added on one side — at which point a
///   persisted stream pane lands back in a tab and opens a channel for a window that will never
///   exist. It is now one predicate, `slopdesk_ws_pane_kind_is_video`, and a test walks the whole
///   kind vocabulary against it rather than naming the cases it knows.
/// - how such a pane is REMOVED. Here it was a `closePane` intent per id, which runs the whole close
///   cascade — refocus, tab drop, session drop, a re-seed when the last pane goes. There it is a
///   prune of the tree, with a tab that held nothing but streams dropped rather than re-seeded,
///   because a tab that only ever held one is not a place the person put anything.
/// - where a re-seeded IDENTITY comes from. See ``repaired(_:)``.
/// - which leaf a dangling focus falls back to: `allPaneIDs().first` against `first_leaf_id()`. Both
///   are the pre-order first leaf, so this pair AGREED — and agreeing by coincidence in two
///   languages is the state every row in that table was in the day before it stopped.
///
/// The public signatures are unchanged, so every existing caller and every existing test still
/// points at the same four names and now exercises the crate (`docs/55` §6).
public extension TreeWorkspace {
    /// Repairs the **specs == leafIDs invariant** against a corrupt / hand-edited file: drops orphan
    /// spec entries (a spec for a pane no longer in any tab — this is also what silently retires the
    /// Stage era's persisted stage-pane specs) and re-seeds a default ``PaneSpec`` for a leaf whose
    /// spec went missing (so the store can always materialize it). The detached list is repaired
    /// FIRST so the spec filter sees a consistent membership. Pure.
    func normalizingSpecs() -> TreeWorkspace {
        repaired(.specs)
    }

    /// Repairs the active-selection invariants: the workspace always has ≥ 1 session; `activeSessionID`
    /// points at a real session; each session has ≥ 1 tab; each `activeTabIndex` is clamped to
    /// `tabs.indices`; each tab's `activePane`/`zoomedPane` is dropped if it no longer names a leaf in
    /// that tab. Pure.
    func normalizingActive() -> TreeWorkspace {
        repaired(.active)
    }

    /// The repairs in the order `load()` applies them: specs first, so the active-pane repair sees a
    /// consistent leaf set. Pure. Deliberately does NOT re-dock detached panes — this runs after every
    /// close/cascade op, so folding ``redockingDetachedPanes()`` in here would instantly undo any
    /// detach. Re-dock is a LAUNCH-ONLY step (the store's restore path).
    func normalized() -> TreeWorkspace {
        repaired(.normalized)
    }

    /// Re-docks every detached pane back into a tab — the LAUNCH-ONLY restore policy (v1): satellite
    /// windows do not restore across relaunch, but a quit/crash while detached must lose nothing, so the
    /// persisted detached panes fold back into their sessions (origin tab when alive, else a fresh tab).
    /// The persisted SELECTION is preserved: each reattach focuses its pane, and a launch restore must
    /// not let the last-detached pane steal the saved focus.
    ///
    /// Every video pane goes first and is DROPPED rather than re-docked — the remote desktop never
    /// restores across a relaunch (docs/DECISIONS.md 2026-07-22), whether it is a satellite whose
    /// window is gone or a stale tree leaf from the era when the desktop was a tab. Its spec goes with
    /// it, so reconcile never opens a stream for a pane no window will show.
    ///
    /// Applied by the store AFTER `normalized()` and ONLY at restore time — never op-internally.
    func redockingDetachedPanes() -> TreeWorkspace {
        repaired(.launchRestore)
    }
}

// MARK: - The crossing

/// Which repair to ask the crate for.
///
/// The CASE ORDER is the byte, and it is the crate's — `slopdesk_workspace::tree_ops::RepairPass`.
/// `scripts/check-supervisor.sh` compares the two maps case-name against case-name, because a
/// reorder here would silently ask for a different repair: "specs only" and "the whole launch
/// restore" differ by whether a detached pane comes back, and both answer a perfectly valid tree.
///
/// It is `internal` and `CaseIterable` so the differential suite can WALK it against
/// ``slopdesk_ws_normalize_pass_count()`` rather than naming four cases. The gate above compares the
/// two byte MAPS, which catches a reorder or a renumber; it cannot see a pass the crate ADDS, since
/// a map Swift never grew still agrees with itself. The count is that missing half, and it is the
/// same argument the `PaneKind` walk makes one file over.
enum RepairPass: CaseIterable {
    case specs
    case active
    case normalized
    case launchRestore

    /// The CASE index — the crate's `RepairPass` order, pinned by `scripts/check-supervisor.sh`.
    var ffiByte: UInt8 {
        switch self {
        case .specs: 0
        case .active: 1
        case .normalized: 2
        case .launchRestore: 3
        }
    }
}

private extension TreeWorkspace {
    /// Asks the crate to run `pass`, and keeps the workspace as it was if the crossing answers
    /// nothing it can read.
    ///
    /// **The tree crosses as the DOCUMENT's own bytes**, exactly as ``WorkspaceIntentApplier`` sends
    /// one: a `TreeWorkspace` is a split tree, and there is no `#[repr(C)]` flattening of one that is
    /// not a second grammar somebody has to keep in step with the first. It does not need one — the
    /// topology already has a byte encoding, the one every client decodes off the socket. The launch
    /// restore is the one place a document-shaping decision runs outside an intent (there is no client
    /// to send one and no host to answer), and routing it through the same encoding anyway is what
    /// keeps the rule honest: a repair means here exactly what it means during a gesture, because it
    /// is the same code deciding. It runs once per launch, so the round trip costs nothing that
    /// matters.
    ///
    /// **The identity pool is minted HERE, and that is the decision rather than the default.** The
    /// crate holds no entropy on purpose (`slopdesk_workspace::identity`), so a repair that needs a
    /// fresh pane, tab or session takes an `IdSource`. The alternative was `persist.rs`'s
    /// `derived_split_id` — an id computed from the node's position and contents, so one file decoded
    /// twice names the same thing both times. That is right THERE and wrong here, for a reason that
    /// is about what the id JOINS to. A `SplitNodeID` names a divider group and joins to nothing
    /// outside the tree, so a persisted `splitNode/<id>/weight` cell only keeps pointing at its seam
    /// if the name is stable — deriving it is what makes a divider drag survive a relaunch. A re-seeded
    /// pane is the opposite case twice over: it is a pane the file did NOT contain, so no persisted
    /// cell is keyed by it and there is nothing for a stable name to keep pointing at; and a `PaneID`
    /// is the join to the live-session registry that owns a process, so a name derived from the file's
    /// own contents is a name two launches — or two clients reading one document — can both produce,
    /// and reconcile would then hand a fresh pane a process it did not open. Determinism where a test
    /// wants it is bought by the CALLER supplying a fixed pool, which is what the crate's own tests do,
    /// rather than by the rule inventing ids it cannot vary.
    ///
    /// A pool one short would REPEAT an identity rather than fail, so its size is asked for.
    func repaired(_ pass: RepairPass) -> TreeWorkspace {
        let seeded = withTheDocumentsBlindSpotsClosed()
        var blob = WsBlob()
        var cells = WorkspaceTopology(tree: seeded).entries().map { blob.entry($0) }
        let minted = (0..<slopdesk_ws_normalize_minted_ids(
            seeded.sessions.count,
            seeded.detachedPaneIDs().count,
        )).map { _ in SlopDeskWsUuid(UUID()) }

        let answer = blob.lend { arena in
            cells.withUnsafeMutableBufferPointer { cell in
                minted.withUnsafeBufferPointer { pool in
                    wsBytes { out, cap in
                        slopdesk_ws_normalize(
                            pass.ffiByte,
                            cell.baseAddress,
                            cell.count,
                            arena.baseAddress,
                            arena.count,
                            pool.baseAddress,
                            pool.count,
                            out,
                            cap,
                        )
                    }
                }
            }
        }

        // Bytes the codec refuses are not a repair that failed — they are this boundary having gone
        // wrong, and keeping the input is the only answer that does not replace a workspace with a
        // half-read one.
        guard let state = try? WorkspaceStateCodec.decodeSnapshot(answer),
              var next = state.topology?.tree
        else { return seeded }
        // The document has no `schemaVersion` — it is a property of the client's FILE, not of the
        // shape (see ``WorkspaceTopologyOmissions``) — so it is carried across rather than reset to
        // this build's, which would make a repair silently claim a version the value never had.
        next.schemaVersion = seeded.schemaVersion
        return next
    }

    /// The two repairs that could not cross, and the reason is the transport rather than the rule.
    ///
    /// ## One root cause, two symptoms
    /// The document is a PUSH format: it says what a workspace IS, and its ingest is written to
    /// refuse or fill rather than to preserve — which is right for a push and wrong for a repair,
    /// because a repair's whole input is the degenerate shape. Both cases below are absences the
    /// document simply cannot spell, so they are gone (or invented) before the door ever sees them.
    ///
    /// **A session with no usable tab is DROPPED.** `read_session` in `slopdesk-wire` and
    /// ``WorkspaceTopology/init(entries:)`` here say it in the same words on purpose: a host push
    /// naming a tabless session is describing nothing, and minting a tab for it would invent a
    /// workspace the host never published. A repair wants the opposite — the session still has a
    /// name and may still own detached panes worth keeping — which is why `normalizing_active`
    /// re-seeds it one. So the re-seed happens here, and it is deliberately the crate's re-seed: one
    /// fresh tab holding one fresh terminal, titled whatever ``TreeWorkspaceDefaults/paneTitle``
    /// says, focused on its only leaf. Nothing about it is decided here — the title is asked for,
    /// and the crate's own selection repair lands on the same focus.
    ///
    /// **A detached pane with no spec is INVENTED, which is the sharper of the two.** `read_spec` is
    /// total: no `pane/title` cell means the default title, not "no such pane". So a hand-edited
    /// file listing a satellite it never described would come back a real terminal satellite and
    /// open a window for a pane nobody asked for — where `normalizing_specs` drops it, precisely
    /// because an entry with nothing to materialize from is not a pane. The entry is dropped here so
    /// the door is never handed a shape whose absence it cannot see. Note what is NOT done here: a
    /// detached entry that shadows a live tree leaf, and a duplicate of a valid one, both cross
    /// fine — the ingest already resolves them the way the crate's rule does, and re-doing them on
    /// this side would be a second implementation of a rule that works.
    ///
    /// **Both are known duplicated decisions and are pinned as such** (`docs/55` §8): the
    /// differential suite holds each against the crate's own answer, and
    /// `scripts/check-supervisor.sh` fails if a third repair grows beside them. The change that
    /// DELETES this function is a whole-`TreeWorkspace` codec in `slopdesk_workspace::persist` — the
    /// file's own encoding, which loses nothing because losing nothing is what a persistence codec
    /// is for. `derived_split_id`'s `## Owed` note is already headed there.
    func withTheDocumentsBlindSpotsClosed() -> TreeWorkspace {
        let blind = sessions.contains { session in
            session.tabs.isEmpty || session.detached.contains { session.specs[$0.pane] == nil }
        }
        guard blind else { return self }
        var copy = self
        copy.sessions = sessions.map { session in
            var s = session
            if s.tabs.isEmpty {
                let pane = PaneID()
                s.tabs = [Tab(root: .leaf(pane), activePane: pane)]
                s.specs[pane] = PaneSpec(kind: .terminal, title: TreeWorkspaceDefaults.paneTitle)
            }
            s.detached = s.detached.filter { s.specs[$0.pane] != nil }
            return s
        }
        return copy
    }
}
