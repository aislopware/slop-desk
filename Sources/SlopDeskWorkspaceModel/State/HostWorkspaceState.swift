import CSlopDeskFFI
import Foundation

// MARK: - Object kinds

/// The object kinds addressable in the workspace document (docs/45 §5.3). The raw value IS the
/// `kindTag` byte on the wire, so these numbers are frozen once a golden vector exists.
///
/// A decoder must NOT reject an unknown tag: length-prefixing makes forward tolerance free, and that
/// is how a newer host talks to an older client in a protocol with no version negotiation. The codec
/// therefore never maps through this enum — it keeps the raw byte, so an entry from a newer host
/// round-trips verbatim instead of vanishing.
public enum WorkspaceObjectKind: UInt8, Sendable, CaseIterable {
    case root = 0
    case session = 1
    case tab = 2
    case pane = 3
    case splitNode = 4
    case project = 5

    /// The all-zero UUID the singleton ``root`` object is addressed by.
    public static let rootObjectID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}

// MARK: - Key

/// One addressable cell of the workspace document: `(kindTag, objectID, field)`.
///
/// Fixed 18 bytes on the wire — `[u8 kindTag][16B objectID][u8 field]` — with NO length prefix,
/// because every component is fixed-width. `Comparable` by exactly the wire's emission order
/// (ascending kindTag, then objectID BYTES, then field) so a snapshot's bytes are deterministic and
/// a diff never churns on Dictionary iteration order.
public struct WorkspaceKey: Hashable, Sendable, Comparable {
    public var kind: UInt8
    public var objectID: UUID
    public var field: UInt8

    public init(kind: UInt8, objectID: UUID, field: UInt8) {
        self.kind = kind
        self.objectID = objectID
        self.field = field
    }

    public init(_ kind: WorkspaceObjectKind, _ objectID: UUID, _ field: UInt8) {
        self.init(kind: kind.rawValue, objectID: objectID, field: field)
    }

    /// A ``WorkspaceObjectKind/root`` key — the singleton object, addressed by the all-zero UUID.
    public static func root(_ field: UInt8) -> Self {
        Self(.root, WorkspaceObjectKind.rootObjectID, field)
    }

    /// The wire size of a key. Fixed: this is what lets a truncated frame be rejected by arithmetic
    /// rather than by trial decoding.
    ///
    /// Asked for, because a reader holding a larger copy stops short of a trailing cell and one
    /// holding a smaller copy reads a key out of the next key's bytes — neither of which is an
    /// error the decoder can raise.
    public static let encodedSize = Int(slopdesk_ws_key_encoded_size())

    /// The objectID's 16 bytes in wire order.
    public var objectIDBytes: [UInt8] {
        let u = objectID.uuid
        return [
            u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
            u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15,
        ]
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
        let l = lhs.objectIDBytes, r = rhs.objectIDBytes
        for i in 0..<16 where l[i] != r[i] { return l[i] < r[i] }
        return lhs.field < rhs.field
    }
}

// MARK: - Entry

/// A key plus its value. A zero-length `value` is a FIRST-CLASS value, not an absence: it is how a
/// field is RETIRED (docs/45 §5.3). `""` is already meaningful on this wire — an empty type-21 title
/// is the agent title-ownership retirement — so "missing key" and "empty value" must stay distinct.
public struct WorkspaceEntry: Hashable, Sendable {
    public var key: WorkspaceKey
    public var value: Data

    public init(key: WorkspaceKey, value: Data) {
        self.key = key
        self.value = value
    }
}

// MARK: - Diff

/// A set of INDEPENDENT property assignments plus a set of removals.
///
/// Independence is the whole correctness argument (docs/45 §5.5): because a diff assigns rather than
/// mutates, `apply(d, apply(d, s)) == apply(d, s)` holds **by construction**, so duplicate and
/// reordered frames are no-ops with zero extra machinery and there is no retransmit path anywhere.
public struct WorkspaceStateDiff: Equatable, Sendable {
    public var sets: [WorkspaceEntry]
    public var deletes: [WorkspaceKey]

    public init(sets: [WorkspaceEntry] = [], deletes: [WorkspaceKey] = []) {
        self.sets = sets
        self.deletes = deletes
    }

    public var isEmpty: Bool { sets.isEmpty && deletes.isEmpty }
}

// MARK: - State

/// The workspace document as a FLAT entry map — the value the host owns and every client mirrors.
///
/// Flat rather than a nested tree on purpose: two clients dragging two different dividers write two
/// different keys and cannot clobber each other, and the last-writer-wins conflict rule (docs/45
/// §8.1) has a natural granularity. The tree SHAPE rides as one `tab/layoutStructure` blob with
/// weights deliberately excluded — they are their own `splitNode/weight` entries.
public struct HostWorkspaceState: Equatable, Sendable {
    public private(set) var entries: [WorkspaceKey: Data]

    public init(entries: [WorkspaceKey: Data] = [:]) {
        self.entries = entries
    }

    public init(_ list: [WorkspaceEntry]) {
        entries = Dictionary(list.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
    }

    public var isEmpty: Bool { entries.isEmpty }

    public subscript(key: WorkspaceKey) -> Data? {
        get { entries[key] }
        set { entries[key] = newValue }
    }

    /// Every entry in the wire's canonical order. Deterministic bytes are what make a golden vector
    /// stable and a diff free of dictionary-order churn.
    public var sortedEntries: [WorkspaceEntry] {
        entries.keys.sorted().map { WorkspaceEntry(key: $0, value: entries[$0] ?? Data()) }
    }

    /// Every key belonging to one object, in canonical order. The delete granularity: a field is
    /// retired by setting it to a zero-length value, an OBJECT is removed by deleting all of its keys.
    public func keys(ofKind kind: UInt8, objectID: UUID) -> [WorkspaceKey] {
        entries.keys.filter { $0.kind == kind && $0.objectID == objectID }.sorted()
    }

    // MARK: Mutation

    public mutating func set(_ key: WorkspaceKey, _ value: Data) {
        entries[key] = value
    }

    /// Removes an OBJECT — every field under one `(kind, objectID)`. There is deliberately no
    /// "remove one field" mutator: a single field is retired with a zero-length value, and conflating
    /// the two would make "absent" and "empty" indistinguishable to a mirror.
    public mutating func removeObject(kind: UInt8, objectID: UUID) {
        for key in keys(ofKind: kind, objectID: objectID) { entries.removeValue(forKey: key) }
    }

    // MARK: Diff / apply — the algebra

    /// The diff that carries `base` to `self`: every key whose value differs (or is new) as a SET,
    /// every key `base` holds and `self` does not as a DELETE.
    ///
    /// The host computes this against the state a subscriber last ACKED — never against the last
    /// state it SENT (docs/45 §5.5, mosh SSP). A lost frame therefore self-heals on the next tick,
    /// because the next diff is recomputed from the same acked base.
    public func diff(from base: Self) -> WorkspaceStateDiff {
        var sets: [WorkspaceEntry] = []
        for key in entries.keys.sorted() {
            let value = entries[key] ?? Data()
            if base.entries[key] != value { sets.append(WorkspaceEntry(key: key, value: value)) }
        }
        let deletes = base.entries.keys.filter { entries[$0] == nil }.sorted()
        return WorkspaceStateDiff(sets: sets, deletes: deletes)
    }

    /// Applies a diff. Sets land before deletes so a diff that both rewrites and removes keys of one
    /// object resolves to the removal — matching the encode order and making apply order-independent
    /// with respect to the two lists.
    public func applying(_ diff: WorkspaceStateDiff) -> Self {
        var next = self
        for entry in diff.sets { next.entries[entry.key] = entry.value }
        for key in diff.deletes { next.entries.removeValue(forKey: key) }
        return next
    }
}
