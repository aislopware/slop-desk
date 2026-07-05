import Foundation

// MARK: - Session (the top of the tiled hierarchy)

/// A named, host-scoped group of ``Tab``s — the top of the new `Session → Tab → Pane` hierarchy that
/// replaces the retired infinite canvas (docs/42 §Decisions.1). A pure
/// `Identifiable`/`Codable`/`Equatable`/`Sendable` value with **no SwiftUI / transport import**.
///
/// A `Session` owns its tabs (``tabs``, ≥ 1 for a live session) and the per-session ``specs`` side table
/// (the **specs == leafIDs invariant**: `Set(specs.keys) == Set(leafIDs across every tab)`). It also
/// models a per-session host (``connection``): the schema is multi-host capable now even though the MVP
/// shares the one app-global `AppConnection` (docs/42 Decisions.9 — model now, no later migration).
public struct Session: Identifiable, Sendable, Equatable {
    public let id: SessionID
    public var name: String
    /// The session's tabs, in tab-bar order. ≥ 1 for a live session.
    public var tabs: [Tab]
    /// The selected tab. Clamped to `tabs.indices` by ``normalizingActive()`` / the ops.
    public var activeTabIndex: Int
    /// Side table mapping each leaf ``PaneID`` to its ``PaneSpec`` (so a rename never churns a tree diff).
    /// Invariant: `Set(specs.keys) == Set(leafIDs)`.
    public var specs: [PaneID: PaneSpec]
    /// Per-session host association. MVP shares the one app-global connection (all sessions `nil` ⇒ the
    /// app target); modeled now so multi-host needs no later migration (docs/42 Decisions.9).
    public var connection: ConnectionTarget?

    public init(
        id: SessionID = SessionID(),
        name: String,
        tabs: [Tab],
        activeTabIndex: Int = 0,
        specs: [PaneID: PaneSpec],
        connection: ConnectionTarget? = nil,
    ) {
        self.id = id
        self.name = name
        self.tabs = tabs
        self.activeTabIndex = activeTabIndex
        self.specs = specs
        self.connection = connection
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
    private enum CodingKeys: String, CodingKey { case id, name, tabs, activeTabIndex, specs, connection }

    private struct SpecEntry: Codable {
        let pane: PaneID
        let spec: PaneSpec
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(SessionID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        tabs = try container.decode([Tab].self, forKey: .tabs)
        activeTabIndex = try container.decodeIfPresent(Int.self, forKey: .activeTabIndex) ?? 0
        let entries = try container.decodeIfPresent([SpecEntry].self, forKey: .specs) ?? []
        var map: [PaneID: PaneSpec] = [:]
        for entry in entries { map[entry.pane] = entry.spec }
        specs = map
        connection = try container.decodeIfPresent(ConnectionTarget.self, forKey: .connection)
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
        try container.encodeIfPresent(connection, forKey: .connection)
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

    /// The set of leaf ids (across every tab). The spec side table must equal this set.
    func leafIDSet() -> Set<PaneID> {
        Set(allPaneIDs())
    }

    /// The ``PaneSpec`` for leaf `id` in this session, or `nil` if it is not a leaf here.
    func spec(for id: PaneID) -> PaneSpec? {
        guard contains(id) else { return nil }
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
