// MARK: - TreeWorkspace (the tree-rooted workspace container — transitional name)

/// The tree-rooted workspace container for the `Session → Tab → Pane` redesign (docs/42 §Domain model).
/// It holds `[Session]` + the active session and NOTHING device-local: the preset library, the latched
/// video modes and the per-host connection target live in ``DevicePreferences`` (docs/45 §7.3), because
/// the tree describes THE LAYOUT — which every attached client shares — and those describe one machine.
/// A pure `Codable`/`Equatable`/`Sendable` value with no SwiftUI or transport import.
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
public struct TreeWorkspace: Codable, Sendable, Equatable {
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

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sessions
        case activeSessionID
    }

    /// Hand-written decode so a key outside ``CodingKeys`` is decode-IGNORED rather than trapping. The
    /// tree is SHAPE; every device-local collection is read from ``DevicePreferences``, so a file
    /// carrying one is describing something this type does not own.
    ///
    /// This is tolerance for a hand-edited file, NOT a migration seam: a whole file written by a
    /// build that shaped the tree differently is caught by ``currentSchemaVersion`` and reset aside.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        sessions = try c.decode([Session].self, forKey: .sessions)
        activeSessionID = try c.decodeIfPresent(SessionID.self, forKey: .activeSessionID)
    }

    /// The schema version this shape writes. A file carrying any OTHER version is not migrated — the
    /// load path resets it aside (single-user, no backward compatibility). The retained-but-dead
    /// canvas ``Workspace`` owns its own `currentSchemaVersion = 9`.
    ///
    /// 12 is the shape whose device-local half lives in ``DevicePreferences``. The bump is what makes
    /// the no-migration rule TRUE rather than merely stated: the retired keys are outside
    /// ``CodingKeys``, so a file from the previous shape would otherwise decode "successfully" and the
    /// next autosave would rewrite it without the user's presets, templates and latched video modes —
    /// silently, with no `.corrupt` copy kept. A version this build does not speak resets aside
    /// instead, which keeps the old file recoverable.
    public static let currentSchemaVersion = 12
}

// MARK: - Construction

public extension TreeWorkspace {
    /// A fresh workspace: one session ("Local"), one tab, one leaf carrying `spec`. The
    /// fresh-launch / re-seed shape (mirrors ``Workspace/defaultWorkspace()`` for the new model).
    static func singlePane(spec: PaneSpec) -> TreeWorkspace {
        let session = Session.singlePane(name: "Local", spec: spec)
        return TreeWorkspace(sessions: [session], activeSessionID: session.id)
    }

    /// The default workspace: one "Local" session with a single terminal pane.
    static func defaultWorkspace() -> TreeWorkspace {
        singlePane(spec: PaneSpec(kind: .terminal, title: "Terminal"))
    }
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

public extension TreeWorkspace {
    /// Repairs the **specs == leafIDs invariant** against a corrupt / hand-edited file: drops orphan
    /// spec entries (a spec for a pane no longer in any tab — this is also what silently retires the
    /// Stage era's persisted stage-pane specs) and re-seeds a default ``PaneSpec`` for a leaf whose
    /// spec went missing (so the store can always materialize it). Pure. (Validate-then-repair, the
    /// CLAUDE.md contract for untrusted persisted data — mirrors ``Workspace/normalizingGroups()``.)
    func normalizingSpecs() -> TreeWorkspace {
        var copy = self
        copy.sessions = sessions.map { session in
            var s = session
            let leafIDs = s.leafIDSet()
            // Repair the detached list FIRST so the spec filter below sees a consistent membership:
            // an entry shadowed by a tree leaf is dropped (tree membership wins — a pane cannot be both
            // tiled and detached), as is a duplicate id or an entry with no spec to materialize from
            // (a spec-less detached record is unrecoverable garbage, unlike a tree leaf whose STRUCTURE
            // demands a re-seeded default).
            var seenDetached = Set<PaneID>()
            s.detached = s.detached.filter { entry in
                guard !leafIDs.contains(entry.pane), s.specs[entry.pane] != nil else { return false }
                return seenDetached.insert(entry.pane).inserted
            }
            let keepIDs = leafIDs.union(s.detachedIDSet())
            // Drop orphan specs (no matching leaf or detached pane).
            s.specs = s.specs.filter { keepIDs.contains($0.key) }
            // Re-seed a default spec for any leaf that lost its spec.
            for id in leafIDs where s.specs[id] == nil {
                s.specs[id] = PaneSpec(kind: .terminal, title: "Terminal")
            }
            return s
        }
        return copy
    }

    /// Repairs the active-selection invariants: the workspace always has ≥ 1 session; `activeSessionID`
    /// points at a real session; each session's `activeTabIndex` is clamped to `tabs.indices`; each tab's
    /// `activePane`/`zoomedPane` is dropped if it no longer names a leaf in that tab. Pure. (Mirrors
    /// ``Workspace/normalizingFocus()`` for the tree-rooted model.)
    func normalizingActive() -> TreeWorkspace {
        var copy = self
        // Re-seed an empty workspace.
        if copy.sessions.isEmpty {
            return .defaultWorkspace()
        }
        copy.sessions = copy.sessions.map { session in
            var s = session
            // A session must have ≥ 1 tab.
            if s.tabs.isEmpty {
                let paneID = PaneID()
                s.tabs = [Tab(root: .leaf(paneID), activePane: paneID)]
                s.specs[paneID] = PaneSpec(kind: .terminal, title: "Terminal")
            }
            // Clamp the active tab index.
            if !s.tabs.indices.contains(s.activeTabIndex) {
                s.activeTabIndex = 0
            }
            // Repair per-tab focus / zoom against the tab's leaf set.
            s.tabs = s.tabs.map { tab in
                var t = tab
                let treeLeafIDs = Set(t.root.allPaneIDs())
                if let active = t.activePane, !treeLeafIDs.contains(active) {
                    t.activePane = t.allPaneIDs().first
                } else if t.activePane == nil {
                    t.activePane = t.allPaneIDs().first
                }
                if let zoom = t.zoomedPane, !treeLeafIDs.contains(zoom) {
                    t.zoomedPane = nil
                }
                return t
            }
            return s
        }
        // Repair the active session pointer.
        if let id = copy.activeSessionID, !copy.sessions.contains(where: { $0.id == id }) {
            copy.activeSessionID = copy.sessions.first?.id
        } else if copy.activeSessionID == nil {
            copy.activeSessionID = copy.sessions.first?.id
        }
        return copy
    }

    /// The repairs in the order `load()` applies them: specs first, so the active-pane repair sees a
    /// consistent leaf set. Pure. Deliberately does NOT re-dock detached panes — `normalized()` runs after
    /// every close/cascade op, so folding ``redockingDetachedPanes()`` in here would instantly undo any
    /// detach. Re-dock is a LAUNCH-ONLY step (the store's restore path).
    func normalized() -> TreeWorkspace {
        normalizingSpecs().normalizingActive()
    }

    /// Re-docks every detached pane back into a tab — the LAUNCH-ONLY restore policy (v1): satellite
    /// windows do not restore across relaunch, but a quit/crash while detached must lose nothing, so the
    /// persisted detached panes fold back into their sessions (origin tab when alive, else a fresh tab —
    /// ``WorkspaceTreeOps/reattachPane(_:in:)``). The persisted SELECTION is preserved (each reattach
    /// focuses its pane; a launch restore must not let the last-detached pane steal the saved focus).
    /// Applied by the store AFTER `normalized()` and ONLY at restore time — never op-internally (see
    /// ``normalized()``).
    func redockingDetachedPanes() -> TreeWorkspace {
        // The remote desktop NEVER restores across relaunch (docs/DECISIONS.md 2026-07-22): a
        // persisted `.desktop` pane — detached (its window) or a stale tree leaf from an older
        // file — is dropped here, launch-only, instead of redocked (it must never land in a tab).
        var copy = droppingDesktopPanes()
        guard copy.sessions.contains(where: { !$0.detached.isEmpty }) else { return copy }
        // Snapshot the persisted selection; reattach mutates it per pane.
        let savedActiveSession = copy.activeSessionID
        let savedTabIndices = copy.sessions.map { ($0.id, $0.activeTabIndex) }
        for id in copy.detachedPaneIDs() {
            copy = WorkspaceTreeOps.reattachPane(id, in: copy)
        }
        // Restore the saved selection (appended tabs never shift existing indices).
        copy.activeSessionID = savedActiveSession
        for (sessionID, tabIndex) in savedTabIndices {
            if let sIdx = copy.sessions.firstIndex(where: { $0.id == sessionID }),
               copy.sessions[sIdx].tabs.indices.contains(tabIndex)
            {
                copy.sessions[sIdx].activeTabIndex = tabIndex
            }
        }
        return copy.normalizingActive()
    }

    /// LAUNCH-ONLY companion of ``redockingDetachedPanes()``: removes every `.desktop` pane — the
    /// detached entries (their satellite windows do not restore) AND any tree-resident leaves an
    /// older file may carry from the era when the desktop was a tab. Specs are dropped with them so
    /// reconcile never opens a stream for a pane no window will show. Pure.
    private func droppingDesktopPanes() -> TreeWorkspace {
        var copy = self
        for (sIdx, session) in copy.sessions.enumerated() {
            let desktopIDs = session.specs.filter { $0.value.kind == .desktop }.map(\.key)
            guard !desktopIDs.isEmpty else { continue }
            var repaired = session
            repaired.detached.removeAll { entry in desktopIDs.contains(entry.pane) }
            for id in desktopIDs {
                repaired.specs.removeValue(forKey: id)
            }
            copy.sessions[sIdx] = repaired
            for id in desktopIDs {
                copy = WorkspaceTreeOps.closePane(id, in: copy)
            }
        }
        return copy.normalized()
    }
}
