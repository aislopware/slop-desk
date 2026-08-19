import Foundation

// MARK: - DetachedPane (a pane living in its own OS window, outside every tab tree)

/// A pane the user detached into its OWN macOS window: it has left every tab's split tree but stays a
/// first-class member of its ``Session`` — its ``PaneSpec`` remains in the session's side table and the
/// store's reconcile keeps its live handle registered, so the PTY / video session survives the move (only
/// the VIEW remounts in the satellite window). Distinct from the retired in-app floating-card feature
/// (docs/DECISIONS.md 2026-07-03): this is OS-window detach, not an overlay layer.
public struct DetachedPane: Codable, Sendable, Equatable, Identifiable {
    /// The detached pane — also the spec/registry key.
    public let pane: PaneID
    /// The tab the pane detached FROM — the preferred reattach destination. `nil` / a since-closed tab
    /// falls back to the session's active tab.
    public var originTab: TabID?

    public var id: PaneID { pane }

    public init(pane: PaneID, originTab: TabID? = nil) {
        self.pane = pane
        self.originTab = originTab
    }
}

// MARK: - Session (the top of the tiled hierarchy)

/// A named, host-scoped group of ``Tab``s — the top of the new `Session → Tab → Pane` hierarchy that
/// replaces the retired infinite canvas (docs/42 §Decisions.1). A pure
/// `Identifiable`/`Codable`/`Equatable`/`Sendable` value with **no SwiftUI / transport import**.
///
/// A `Session` owns its tabs (``tabs``, ≥ 1 for a live session) and the per-session ``specs`` side
/// table (the **specs == leafIDs invariant**: `Set(specs.keys) == Set(leafIDs across every tab)`).
/// The tree is MIXED-KIND: a leaf's `PaneSpec.kind` decides its content (terminal / desktop / remote
/// window) — the full-desktop pivot, docs/DECISIONS.md 2026-07-14. It carries NO host association: which
/// host this client talks to is device-local, so the committed ``ConnectionTarget`` lives in
/// ``DevicePreferences`` keyed by `host:port` (docs/45 §7.3).
public struct Session: Identifiable, Sendable, Equatable {
    public let id: SessionID
    public var name: String
    /// The session's tabs, in tab-bar order. ≥ 1 for a live session.
    public var tabs: [Tab]
    /// The selected tab. Clamped to `tabs.indices` by ``normalizingActive()`` / the ops.
    public var activeTabIndex: Int
    /// Side table mapping each pane ``PaneID`` (tree leaf OR detached) to its ``PaneSpec`` (so a rename
    /// never churns a tree diff). Invariant: `Set(specs.keys) == leafIDSet() ∪ detachedIDSet()`.
    public var specs: [PaneID: PaneSpec]
    /// Panes detached into their own OS windows, in detach order. Each keeps its spec in ``specs`` and
    /// its live registry handle (the store's reconcile counts detached panes as desired), so detach ↔
    /// reattach never tears a session down. Additive v11 field — absent in older files (a missing or
    /// unreadable list reads as none, see `decodeArray` below), encoded only when non-empty
    /// so a detach-free workspace file stays byte-identical.
    public var detached: [DetachedPane]

    public init(
        id: SessionID = SessionID(),
        name: String,
        tabs: [Tab],
        activeTabIndex: Int = 0,
        specs: [PaneID: PaneSpec],
        detached: [DetachedPane] = [],
    ) {
        self.id = id
        self.name = name
        self.tabs = tabs
        self.activeTabIndex = activeTabIndex
        self.specs = specs
        self.detached = detached
    }
}

// MARK: - Deterministic Codable

/// A hand-written `Codable` so the ``Session/specs`` side table persists DETERMINISTICALLY. A Swift
/// `[PaneID: PaneSpec]` (a struct-keyed dictionary) would encode as a JSON array of alternating key/value
/// pairs in the dictionary's per-process hash-randomized iteration order — so two encodes of the same
/// value produce different bytes, and the `.sortedKeys`/`.prettyPrinted` persistence file would churn on
/// every save. Encoding the specs as an array of `{pane, spec}` entries SORTED by the pane's UUID string
/// makes the round-trip byte-stable and the file reviewable (W4 leans on this for clean persistence
/// diffs). Decode is order-independent (last-wins on a duplicate key, mirroring `Dictionary`).
extension Session: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case tabs
        case activeTabIndex
        case specs
        case detached
    }

    private struct SpecEntry: Codable {
        let pane: PaneID
        let spec: PaneSpec
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(SessionID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        tabs = try container.decode([Tab].self, forKey: .tabs)
        // Absent OR unreadable ⇒ `0`. There is NO Rust counterpart yet — `persist.rs` decodes nodes
        // and specs, not sessions — so this Swift is currently the only implementation of the
        // answer, and `persist.rs` will have to agree with it when it grows to the session/file
        // level: a `"activeTabIndex": "two"` is a session whose selection is unknown, not a session
        // that is gone.
        //
        // Decided on the merits rather than copied: this field is ALREADY tolerated out of range.
        // `normalizingActive()` clamps anything outside `tabs.indices` back to `0` and `activeTab`
        // falls through to `tabs.first`, so `-1` and `900` both cost the user exactly one click. A
        // value of the wrong type carries strictly LESS information than those, and the trap made it
        // cost strictly more — `decodeIfPresent` throws past its own `?? 0` on a present-but-refused
        // value, unwinding every session in the file into a `.corrupt` sidecar. Repairing it to the
        // same `0` the clamp already produces is the only answer consistent with the field's own
        // normalizer.
        activeTabIndex = (try? container.decode(Int.self, forKey: .activeTabIndex)) ?? 0
        var map: [PaneID: PaneSpec] = [:]
        for entry in try Self.decodeArray(SpecEntry.self, forKey: .specs, in: container) {
            map[entry.pane] = entry.spec
        }
        specs = map
        detached = try Self.decodeArray(DetachedPane.self, forKey: .detached, in: container)
        // A file written during the short-lived Stage era may carry `stagePanes`/`activeStagePane`
        // keys — ignored here; the orphaned specs are pruned by `normalizingSpecs()` (streamed-window
        // stage tabs were ephemeral viewing surfaces, so dropping them loses no terminal state).
    }

    /// A persisted list: a TOLERANT container wrapped around STRICT elements — the shape
    /// `SplitNode+Codable.swift`'s `decodeChildren` established, applied to the session's two lists.
    ///
    /// There is no Rust counterpart to either call yet (`persist.rs` stops at the spec and the
    /// node), so this Swift is currently the only implementation and is what `persist.rs` will have
    /// to agree with when it reaches the session/file level: **an unreadable list VALUE is no list;
    /// an unreadable ELEMENT is a fault.**
    ///
    /// Why the container is tolerant. `decodeIfPresent([…].self, …) ?? []` was the trap on both
    /// keys: `"specs": 5` or `"detached": {}` is present with a value the type refuses, so it THREW
    /// past the `?? []` written beside it, and the throw did not stop at the list — it unwound the
    /// session, the `TreeWorkspace`, and `WorkspacePersistence.load()` filed every session, tab and
    /// split the user had arranged away as `.corrupt`. There is nothing under a `5` to recover, so
    /// the tolerant read loses no pane the file still described.
    ///
    /// Why the elements are NOT tolerant, which is where the two keys differ and both still land the
    /// same way. This repair is asymmetric and worth naming rather than assuming:
    ///
    /// - `specs` is a SIDE table, not the pane list — the tabs' trees are. An empty `specs` costs
    ///   titles, kinds and video targets, and `normalizingSpecs()` re-seeds every leaf a default
    ///   `PaneSpec`, so the arrangement itself survives intact. But a `try?` per ELEMENT would turn
    ///   one malformed row into that same silent re-seed for one pane: a `.desktop` pane would come
    ///   back as a blank terminal and the load would report success. A pane that quietly changes
    ///   into a different pane is worse than a load that visibly refuses.
    /// - `detached` IS the only record of a pane living outside every tab tree, so an entry lost
    ///   here is a pane deleted — `normalizingSpecs()` prunes its now-orphan spec. That is exactly
    ///   why a malformed element must stay a fault: the only path that drops a detached pane is a
    ///   whole-list value that named no panes to begin with.
    private static func decodeArray<T: Decodable>(
        _ type: T.Type, forKey key: CodingKeys, in container: KeyedDecodingContainer<CodingKeys>,
    ) throws -> [T] {
        guard var unkeyed = try? container.nestedUnkeyedContainer(forKey: key) else { return [] }
        var decoded: [T] = []
        while !unkeyed.isAtEnd {
            try decoded.append(unkeyed.decode(type))
        }
        return decoded
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(tabs, forKey: .tabs)
        try container.encode(activeTabIndex, forKey: .activeTabIndex)
        // Sort by the pane's UUID string so the emitted order is stable across encodes.
        let entries = specs
            .map { SpecEntry(pane: $0.key, spec: $0.value) }
            .sorted { $0.pane.raw.uuidString < $1.pane.raw.uuidString }
        try container.encode(entries, forKey: .specs)
        // Only when non-empty — a detach-free session's persisted bytes stay identical to pre-feature files.
        if !detached.isEmpty {
            try container.encode(detached, forKey: .detached)
        }
    }
}

// MARK: - Construction

public extension Session {
    /// A fresh single-tab, single-leaf session — the building block for `newSession` and the default
    /// workspace. The lone leaf's id keys the spec side table so the invariant holds at birth.
    static func singlePane(name: String, spec: PaneSpec) -> Session {
        let paneID = PaneID()
        let tab = Tab(root: .leaf(paneID), activePane: paneID)
        return Session(name: name, tabs: [tab], activeTabIndex: 0, specs: [paneID: spec])
    }
}

// MARK: - Pure queries

public extension Session {
    /// Every ``PaneID`` across every tab, in tab order then pre-order DFS. Drives the workspace
    /// `allPaneIDs()` and the specs == leafIDs invariant.
    func allPaneIDs() -> [PaneID] {
        tabs.flatMap { $0.allPaneIDs() }
    }

    /// The set of leaf ids across every tab.
    func leafIDSet() -> Set<PaneID> {
        Set(allPaneIDs())
    }

    /// The set of pane ids detached into their own windows (see ``detached``).
    func detachedIDSet() -> Set<PaneID> {
        Set(detached.map(\.pane))
    }

    /// Whether `id` is detached into its own window in this session.
    func isDetached(_ id: PaneID) -> Bool {
        detached.contains { $0.pane == id }
    }

    /// The ``PaneSpec`` for pane `id` in this session — a tree leaf OR a detached pane (both are
    /// first-class members of the session's side table), or `nil` if this session does not own it.
    func spec(for id: PaneID) -> PaneSpec? {
        guard contains(id) || isDetached(id) else { return nil }
        return specs[id]
    }

    /// Whether `id` is a leaf anywhere in this session.
    func contains(_ id: PaneID) -> Bool {
        tabs.contains { $0.contains(id) }
    }

    /// The currently selected tab (clamped). `nil` only for a structurally empty session (never live).
    var activeTab: Tab? {
        guard tabs.indices.contains(activeTabIndex) else { return tabs.first }
        return tabs[activeTabIndex]
    }

    /// The index of the tab whose tree contains `id`, or `nil`.
    func tabIndex(containing id: PaneID) -> Int? {
        tabs.firstIndex { $0.contains(id) }
    }
}
