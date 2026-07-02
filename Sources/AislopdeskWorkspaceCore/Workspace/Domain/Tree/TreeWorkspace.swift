import Foundation

// MARK: - TreeWorkspace (the tree-rooted workspace container — transitional name)

/// The tree-rooted workspace container for the `Session → Tab → Pane` redesign (docs/42 §Domain model).
/// It holds `[Session]` + the active session + the client-state the live ``Workspace`` carries that still
/// applies (`layoutPresets`). A pure `Codable`/`Equatable`/`Sendable` value with no SwiftUI
/// or transport import.
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
    /// Named launch templates — carried from v9; repurposed to Session/Tab templates in a later item.
    public var layoutPresets: [LayoutPreset]
    /// Named **launch configurations** (docs/42 W14 #9): a title + a command (+ optional cwd / split) that
    /// SPAWN a terminal pane running that command (Warp launch-configurations parity). Distinct from
    /// ``layoutPresets`` (a saved geometry). Seeded
    /// with ``LaunchPreset/builtIns`` (Claude Code / htop / Git log) on a fresh workspace; a v10 file
    /// written before W14 has no `launchPresets` key, so the decode below tolerates its absence and the
    /// store re-seeds the built-ins (see ``seedingBuiltInLaunchPresetsIfEmpty()``).
    public var launchPresets: [LaunchPreset]
    /// Named **session templates / project profiles**: a layout + per-pane cwd/optional command that
    /// SPAWN a whole named session (distinct from ``launchPresets``, which open one tab in the current
    /// session). Seeded with ``SessionTemplate/builtIns`` on a fresh workspace; an existing v10 file
    /// written before this field has no `sessionTemplates` key, so the decode below tolerates its absence
    /// (`decodeIfPresent` ⇒ `[]`) and the store re-seeds the built-ins — NO schema bump, NO migration step
    /// (mirrors the ``launchPresets`` additive field exactly).
    public var sessionTemplates: [SessionTemplate]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        sessions: [Session],
        activeSessionID: SessionID?,
        layoutPresets: [LayoutPreset] = [],
        launchPresets: [LaunchPreset] = LaunchPreset.builtIns,
        sessionTemplates: [SessionTemplate] = SessionTemplate.builtIns,
    ) {
        self.schemaVersion = schemaVersion
        self.sessions = sessions
        self.activeSessionID = activeSessionID
        self.layoutPresets = layoutPresets
        self.launchPresets = launchPresets
        self.sessionTemplates = sessionTemplates
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sessions
        case activeSessionID
        case layoutPresets
        case launchPresets
        case sessionTemplates
    }

    /// Additive-tolerant decode (docs/42 W14): every existing key decodes normally; `launchPresets` is the
    /// only NEW key, so it is `decodeIfPresent` — a v10 file written before W14 (no `launchPresets`)
    /// decodes with an empty list, which the store then re-seeds with the built-ins. Never traps on the
    /// missing key (the persisted-data contract — a forward-compatible additive field must not brick load).
    /// A stale `snippets` key (feature removed 2026-07-03) is simply not in ``CodingKeys`` → decode-ignored.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        sessions = try c.decode([Session].self, forKey: .sessions)
        activeSessionID = try c.decodeIfPresent(SessionID.self, forKey: .activeSessionID)
        layoutPresets = try c.decodeIfPresent([LayoutPreset].self, forKey: .layoutPresets) ?? []
        launchPresets = try c.decodeIfPresent([LaunchPreset].self, forKey: .launchPresets) ?? []
        sessionTemplates = try c.decodeIfPresent([SessionTemplate].self, forKey: .sessionTemplates) ?? []
    }

    /// The schema version this redesigned shape writes (docs/42 §Domain model = 10; bumped to 11 for
    /// the additive Stage-1 persistence fields on ``PaneSpec`` — `resumeSessionID`,
    /// `resumeLastReceivedSeq`, `lastKnownCwd`, `lastKnownTitle`). The live v9 ``Workspace`` still
    /// owns its own `currentSchemaVersion = 9`; these coexist during the cutover.
    public static let currentSchemaVersion = 11
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
    /// order, then tab order, then pre-order tree). Drives the store's reconcile diff (`reconcile()`
    /// compares it as a `Set`; the order matters for cycling + the carousel).
    func allPaneIDs() -> [PaneID] {
        sessions.flatMap { $0.allPaneIDs() }
    }

    /// The active session's leaf ids — drives active-tab focus/visibility (reconcile keeps the full set).
    func activeSessionPaneIDs() -> [PaneID] {
        activeSession?.allPaneIDs() ?? []
    }

    /// The active tab's leaf ids — drives active-tab focus/visibility.
    func activeTabPaneIDs() -> [PaneID] {
        guard let session = activeSession, let tab = session.activeTab else { return [] }
        return tab.allPaneIDs()
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
    /// ids across all that session's tabs (`Set(specs.keys) == Set(leafIDs)`). A checkable property the
    /// ops preserve and the tests assert after every op. Pure.
    func isInvariantHeld() -> Bool {
        for session in sessions where Set(session.specs.keys) != session.leafIDSet() {
            return false
        }
        return true
    }
}

// MARK: - Normalizing repairs (applied on load — never crash on a hand-edited file)

public extension TreeWorkspace {
    /// Repairs the **specs == leafIDs invariant** against a corrupt / hand-edited file: drops orphan spec
    /// entries (a spec for a pane no longer in any tab) and re-seeds a default ``PaneSpec`` for a leaf
    /// whose spec went missing (so the store can always materialize it). Pure. (Validate-then-repair, the
    /// CLAUDE.md contract for untrusted persisted data — mirrors ``Workspace/normalizingGroups()``.)
    func normalizingSpecs() -> TreeWorkspace {
        var copy = self
        copy.sessions = sessions.map { session in
            var s = session
            let leafIDs = s.leafIDSet()
            // Drop orphan specs (no matching leaf).
            s.specs = s.specs.filter { leafIDs.contains($0.key) }
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

    /// Seeds ``LaunchPreset/builtIns`` (Claude Code / htop / Git log) when ``launchPresets`` is empty — the
    /// fresh-workspace and pre-W14-file case (a v10 file with no `launchPresets` key decodes to `[]`). A
    /// workspace the user has curated (≥ 1 preset, even after deleting some) is left untouched, so the
    /// re-seed never resurrects a built-in the user removed. Pure.
    func seedingBuiltInLaunchPresetsIfEmpty() -> TreeWorkspace {
        guard launchPresets.isEmpty else { return self }
        var copy = self
        copy.launchPresets = LaunchPreset.builtIns
        return copy
    }

    /// Seeds ``SessionTemplate/builtIns`` when ``sessionTemplates`` is empty — the fresh-workspace and
    /// pre-templates-file case (a v10 file with no `sessionTemplates` key decodes to `[]`). A workspace the
    /// user has curated (≥ 1 template, even after deleting some) is left untouched, so the re-seed never
    /// resurrects a built-in they removed. Mirrors ``seedingBuiltInLaunchPresetsIfEmpty()`` exactly. Pure.
    func seedingBuiltInSessionTemplatesIfEmpty() -> TreeWorkspace {
        guard sessionTemplates.isEmpty else { return self }
        var copy = self
        copy.sessionTemplates = SessionTemplate.builtIns
        return copy
    }

    /// Both repairs in the order `load()` applies them (specs first so the active-pane repair sees a
    /// consistent leaf set), plus the built-in launch-preset + session-template seeds for a fresh /
    /// pre-feature file. Pure.
    func normalized() -> TreeWorkspace {
        normalizingSpecs().normalizingActive()
            .seedingBuiltInLaunchPresetsIfEmpty()
            .seedingBuiltInSessionTemplatesIfEmpty()
    }
}
