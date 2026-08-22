//! The workspace document as a flat map of addressable cells (docs/45 §5.3).
//!
//! Flat rather than a nested tree on purpose: two clients dragging two different dividers write two
//! different keys and cannot clobber each other, and the last-writer-wins conflict rule (docs/45
//! §8.1) gets a natural granularity. The tree SHAPE rides as one `tab/layoutStructure` blob with
//! weights deliberately excluded — they are their own `splitNode/weight` entries.

use std::collections::BTreeMap;

use crate::message::RawUuid;

/// The object kinds addressable in the workspace document. The discriminant IS the `kindTag` byte
/// on the wire, so these numbers are frozen — a golden vector carries them.
///
/// A decoder must NOT reject an unknown tag, which is why [`WorkspaceKey`] stores a raw `u8` and
/// never this enum: length-prefixing makes forward tolerance free, and keeping the raw byte lets an
/// entry from a newer host round-trip verbatim instead of vanishing. This enum exists for the
/// PRODUCER side, where a kind is chosen rather than parsed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[repr(u8)]
pub enum WorkspaceObjectKind {
    /// The singleton root object, addressed by [`ROOT_OBJECT_ID`].
    Root = 0,
    /// One session — a window's worth of tabs.
    Session = 1,
    /// One tab, holding a layout structure.
    Tab = 2,
    /// One pane.
    Pane = 3,
    /// One divider, addressed by its split-node id.
    SplitNode = 4,
    /// One project, addressed by a UUID derived from its key.
    Project = 5,
}

impl WorkspaceObjectKind {
    /// Every kind this build mints, in wire order.
    pub const ALL: [Self; 6] = [
        Self::Root,
        Self::Session,
        Self::Tab,
        Self::Pane,
        Self::SplitNode,
        Self::Project,
    ];

    /// The kind for `byte`, or `None` for a tag from a newer host.
    ///
    /// A decoder does not call this — it keeps the raw byte. This is for a reader that wants to
    /// INTERPRET a kind it recognises, and `None` means "carry it, do not act on it".
    #[must_use]
    pub const fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::Root),
            1 => Some(Self::Session),
            2 => Some(Self::Tab),
            3 => Some(Self::Pane),
            4 => Some(Self::SplitNode),
            5 => Some(Self::Project),
            _ => None,
        }
    }

    /// The on-wire `kindTag` byte.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }
}

/// The all-zero UUID the singleton [`WorkspaceObjectKind::Root`] object is addressed by.
pub const ROOT_OBJECT_ID: RawUuid = [0; 16];

/// One addressable cell of the workspace document: `(kindTag, objectID, field)`.
///
/// Fixed 18 bytes on the wire — `[u8 kindTag][16B objectID][u8 field]` — with NO length prefix,
/// because every component is fixed-width. That is what lets a truncated frame be rejected by
/// arithmetic rather than by trial decoding.
///
/// The derived [`Ord`] is exactly the wire's emission order (ascending `kind`, then the objectID
/// BYTES, then `field`) because the fields are declared in that order and `[u8; 16]` compares
/// lexicographically. A snapshot's bytes are therefore deterministic and a diff never churns on map
/// iteration order — the same guarantee Swift's hand-written `Comparable` gave, obtained here from
/// the field order instead of from a loop that could drift out of step with the encoder.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct WorkspaceKey {
    /// The object kind's raw tag byte — raw, so an unknown kind survives a round trip.
    pub kind: u8,
    /// The object's identity.
    pub object_id: RawUuid,
    /// The field selector within the object.
    pub field: u8,
}

impl WorkspaceKey {
    /// The wire size of a key.
    pub const ENCODED_SIZE: usize = 18;

    /// A key from a raw kind tag.
    #[must_use]
    pub const fn new(kind: u8, object_id: RawUuid, field: u8) -> Self {
        Self {
            kind,
            object_id,
            field,
        }
    }

    /// A key from a kind this build knows.
    #[must_use]
    pub const fn of(kind: WorkspaceObjectKind, object_id: RawUuid, field: u8) -> Self {
        Self::new(kind.as_byte(), object_id, field)
    }

    /// A [`WorkspaceObjectKind::Root`] key — the singleton object, addressed by the all-zero UUID.
    #[must_use]
    pub const fn root(field: u8) -> Self {
        Self::of(WorkspaceObjectKind::Root, ROOT_OBJECT_ID, field)
    }
}

/// Where each of `keys` places in the wire's canonical order: `out[i]` is the index, into the
/// slice handed in, of the key that comes `i`-th.
///
/// [`HostWorkspaceState`] never needs this — its [`BTreeMap`] iterates in this order already — and
/// that is precisely why the function exists. A caller holding the document in an UNORDERED map
/// has to derive the order, and deriving it a second time is how the emission order becomes two
/// rules: one here, one wherever the second map lives. Two orders never conflict, they RE-EMIT,
/// and a diff that churns on the loser's iteration order is a frame nothing downstream can tell
/// from a real change.
///
/// A PERMUTATION rather than the sorted keys, because the caller already holds them: answering
/// with the keys would copy eighteen bytes per cell back over a boundary to say something four can.
///
/// The arrival index rides in the sort key rather than being looked up from it, so equal keys —
/// which a well-formed document does not have, since a map's keys are unique — keep the order they
/// came in, and no index is ever used to reach back into the slice.
#[must_use]
pub fn canonical_order(keys: &[WorkspaceKey]) -> Vec<u32> {
    let mut placed: Vec<(WorkspaceKey, u32)> = keys.iter().copied().zip(0_u32..).collect();
    placed.sort_unstable();
    placed.into_iter().map(|(_, index)| index).collect()
}

/// A key plus its value.
///
/// A zero-length `value` is a FIRST-CLASS value, not an absence: it is how a field is RETIRED
/// (docs/45 §5.3). `""` is already meaningful on this wire — an empty type-21 title is the agent
/// title-ownership retirement — so "missing key" and "empty value" must stay distinct.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct WorkspaceEntry {
    /// The cell this value belongs to.
    pub key: WorkspaceKey,
    /// The cell's bytes, opaque at this layer.
    pub value: Vec<u8>,
}

impl WorkspaceEntry {
    /// An entry from its parts.
    #[must_use]
    pub const fn new(key: WorkspaceKey, value: Vec<u8>) -> Self {
        Self { key, value }
    }
}

/// A set of INDEPENDENT property assignments plus a set of removals.
///
/// Independence is the whole correctness argument (docs/45 §5.5): because a diff ASSIGNS rather
/// than mutates, `apply(d, apply(d, s)) == apply(d, s)` holds by construction, so duplicate and
/// reordered frames are no-ops with zero extra machinery and there is no retransmit path anywhere.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct WorkspaceStateDiff {
    /// Cells to assign, in canonical key order.
    pub sets: Vec<WorkspaceEntry>,
    /// Cells to remove, in canonical key order.
    pub deletes: Vec<WorkspaceKey>,
}

impl WorkspaceStateDiff {
    /// A diff from its two halves.
    #[must_use]
    pub const fn new(sets: Vec<WorkspaceEntry>, deletes: Vec<WorkspaceKey>) -> Self {
        Self { sets, deletes }
    }

    /// Whether this diff carries nothing at all.
    #[must_use]
    pub const fn is_empty(&self) -> bool {
        self.sets.is_empty() && self.deletes.is_empty()
    }
}

/// The workspace document — the value the host owns and every client mirrors.
///
/// A [`BTreeMap`] rather than a hash map, and that is load-bearing rather than a taste call: the
/// wire's canonical order IS [`WorkspaceKey`]'s ordering, so iteration is already emission order
/// and there is no sort to keep in step with the encoder. Swift sorted a `Dictionary` at every
/// snapshot, diff and object query; here the ordering is an invariant of the container.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct HostWorkspaceState {
    entries: BTreeMap<WorkspaceKey, Vec<u8>>,
}

impl HostWorkspaceState {
    /// An empty document.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            entries: BTreeMap::new(),
        }
    }

    /// A document from a list of entries. A later entry for a key wins, matching Swift's
    /// `uniquingKeysWith: { _, last in last }` — which is also `BTreeMap`'s own `FromIterator`
    /// rule, so the uniquing is the container's rather than a loop that could drift from it.
    ///
    /// Collected rather than inserted one at a time: `BTreeMap` bulk-builds from an ALREADY-SORTED
    /// iterator, and the hot caller — [`crate::document::decode_snapshot`] — hands it a snapshot's
    /// entries, which arrive in canonical order by construction.
    #[must_use]
    pub fn from_entries(list: Vec<WorkspaceEntry>) -> Self {
        Self {
            entries: list.into_iter().map(|entry| (entry.key, entry.value)).collect(),
        }
    }

    /// Whether the document holds no cells.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// How many cells the document holds.
    #[must_use]
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// One cell's value, or `None` when the key is absent — which is NOT the same as a
    /// zero-length value.
    #[must_use]
    pub fn get(&self, key: &WorkspaceKey) -> Option<&[u8]> {
        self.entries.get(key).map(Vec::as_slice)
    }

    /// Every entry in the wire's canonical order.
    #[must_use]
    pub fn sorted_entries(&self) -> Vec<WorkspaceEntry> {
        self.entries
            .iter()
            .map(|(key, value)| WorkspaceEntry::new(*key, value.clone()))
            .collect()
    }

    /// Every key in the document, in canonical order.
    ///
    /// Keys alone rather than [`sorted_entries`](Self::sorted_entries) because the caller that
    /// wants them — a wholesale half-of-the-document rewrite — is deciding what to REAP, and
    /// cloning every value to answer a question about keys is the kind of copy a snapshot-sized
    /// document notices.
    #[must_use]
    pub fn keys(&self) -> Vec<WorkspaceKey> {
        self.entries.keys().copied().collect()
    }

    /// Every key belonging to one object, in canonical order.
    ///
    /// The delete granularity: a FIELD is retired by setting it to a zero-length value, an OBJECT
    /// is removed by deleting all of its keys.
    #[must_use]
    pub fn keys_of_object(&self, kind: u8, object_id: RawUuid) -> Vec<WorkspaceKey> {
        self.entries
            .keys()
            .filter(|key| key.kind == kind && key.object_id == object_id)
            .copied()
            .collect()
    }

    /// Assigns one cell.
    pub fn set(&mut self, key: WorkspaceKey, value: Vec<u8>) {
        self.entries.insert(key, value);
    }

    /// Assigns one cell, or REMOVES it when the value is `None`, reporting whether that changed
    /// anything.
    ///
    /// The one place a single field is removed rather than retired with a zero-length value, and it
    /// exists for exactly one caller: a liveness merge has to make a fact that STOPPED being true
    /// disappear, and a zero-length running command is not "no command" — it is an empty one, which
    /// this wire already gives a distinct meaning.
    pub fn set_or_clear(&mut self, key: WorkspaceKey, value: Option<Vec<u8>>) -> bool {
        match value {
            Some(value) => {
                if self.entries.get(&key) == Some(&value) {
                    return false;
                }
                self.entries.insert(key, value);
                true
            },
            None => self.entries.remove(&key).is_some(),
        }
    }

    /// Removes an OBJECT — every field under one `(kind, objectID)`.
    ///
    /// There is deliberately no "remove one field" mutator: a single field is retired with a
    /// zero-length value, and conflating the two would make "absent" and "empty" indistinguishable
    /// to a mirror.
    pub fn remove_object(&mut self, kind: u8, object_id: RawUuid) {
        self.entries
            .retain(|key, _| key.kind != kind || key.object_id != object_id);
    }

    /// The diff that carries `base` to `self`: every key whose value differs (or is new) as a SET,
    /// every key `base` holds and `self` does not as a DELETE.
    ///
    /// The host computes this against the state a subscriber last ACKED — never against the last
    /// state it SENT (docs/45 §5.5, mosh SSP). A lost frame therefore self-heals on the next tick,
    /// because the next diff is recomputed from the same acked base.
    #[must_use]
    pub fn diff_from(&self, base: &Self) -> WorkspaceStateDiff {
        let sets = self
            .entries
            .iter()
            .filter(|(key, value)| base.entries.get(*key) != Some(*value))
            .map(|(key, value)| WorkspaceEntry::new(*key, value.clone()))
            .collect();
        let deletes = base
            .entries
            .keys()
            .filter(|key| !self.entries.contains_key(*key))
            .copied()
            .collect();
        WorkspaceStateDiff::new(sets, deletes)
    }

    /// Applies a diff IN PLACE — the mirror's actual step, and the one with no copy in it.
    ///
    /// Sets land before deletes so a diff that both rewrites and removes keys of one object
    /// resolves to the removal — matching the encode order and making apply order-independent
    /// with respect to the two lists.
    ///
    /// Swift had only the value-returning [`Self::applying`], because a `Dictionary` is
    /// copy-on-write and `var next = self` costs nothing until it is touched. A `BTreeMap` has no
    /// such trick, so that copy is real — this is the form a mirror should call: `state.apply(&d)`
    /// rather than `state = state.applying(&d)`.
    pub fn apply(&mut self, diff: &WorkspaceStateDiff) {
        for entry in &diff.sets {
            self.entries.insert(entry.key, entry.value.clone());
        }
        for key in &diff.deletes {
            self.entries.remove(key);
        }
    }

    /// The document this one becomes after `diff`, leaving this one untouched.
    ///
    /// Prefer [`Self::apply`] where the old value is not needed — this one copies the whole map
    /// first.
    #[must_use]
    pub fn applying(&self, diff: &WorkspaceStateDiff) -> Self {
        let mut next = self.clone();
        next.apply(diff);
        next
    }
}

#[cfg(test)]
mod tests {
    use super::{
        HostWorkspaceState, ROOT_OBJECT_ID, WorkspaceEntry, WorkspaceKey, WorkspaceObjectKind,
        WorkspaceStateDiff, canonical_order,
    };

    fn uuid(byte: u8) -> [u8; 16] {
        [byte; 16]
    }

    fn entry(kind: u8, object: u8, field: u8, value: &str) -> WorkspaceEntry {
        WorkspaceEntry::new(
            WorkspaceKey::new(kind, uuid(object), field),
            value.as_bytes().to_vec(),
        )
    }

    #[test]
    fn every_object_kind_round_trips_through_its_tag_byte() {
        for (index, kind) in WorkspaceObjectKind::ALL.into_iter().enumerate() {
            assert_eq!(usize::from(kind.as_byte()), index);
            assert_eq!(WorkspaceObjectKind::from_byte(kind.as_byte()), Some(kind));
        }
        assert_eq!(WorkspaceObjectKind::from_byte(6), None);
    }

    #[test]
    fn keys_order_by_kind_then_object_bytes_then_field() {
        let mut keys = vec![
            WorkspaceKey::new(3, uuid(0xA1), 8),
            WorkspaceKey::new(3, uuid(0xA1), 3),
            WorkspaceKey::new(0, ROOT_OBJECT_ID, 2),
            WorkspaceKey::new(2, uuid(0xB2), 0),
            WorkspaceKey::new(3, uuid(0xA0), 99),
        ];
        keys.sort_unstable();
        assert_eq!(keys, vec![
            WorkspaceKey::new(0, ROOT_OBJECT_ID, 2),
            WorkspaceKey::new(2, uuid(0xB2), 0),
            WorkspaceKey::new(3, uuid(0xA0), 99),
            WorkspaceKey::new(3, uuid(0xA1), 3),
            WorkspaceKey::new(3, uuid(0xA1), 8),
        ]);
    }

    /// The permutation is the map's own order, asserted against the container rather than against a
    /// list written out by hand — a hand-written expectation is a third copy of the very rule this
    /// function exists so nobody writes twice.
    #[test]
    fn the_permutation_places_keys_exactly_where_the_map_would() {
        let keys = vec![
            WorkspaceKey::new(3, uuid(0xA1), 8),
            WorkspaceKey::new(3, uuid(0xA1), 3),
            WorkspaceKey::new(0, ROOT_OBJECT_ID, 2),
            WorkspaceKey::new(2, uuid(0xB2), 0),
            WorkspaceKey::new(3, uuid(0xA0), 99),
        ];
        let state = HostWorkspaceState::from_entries(
            keys.iter()
                .map(|key| WorkspaceEntry::new(*key, Vec::new()))
                .collect(),
        );
        let placed: Vec<WorkspaceKey> = canonical_order(&keys)
            .into_iter()
            .filter_map(|index| keys.get(index as usize).copied())
            .collect();
        let mapped: Vec<WorkspaceKey> = state
            .sorted_entries()
            .into_iter()
            .map(|entry| entry.key)
            .collect();
        assert_eq!(placed, mapped);
    }

    #[test]
    fn an_empty_list_has_an_empty_order() {
        assert_eq!(canonical_order(&[]), Vec::<u32>::new());
    }

    #[test]
    fn a_document_iterates_in_canonical_order_whatever_order_it_was_built_in() {
        let state = HostWorkspaceState::from_entries(vec![
            entry(3, 0xA1, 8, "vi ."),
            entry(0, 0x00, 2, "mac-studio"),
            entry(3, 0xA1, 3, ""),
            entry(2, 0xB2, 0, "slopdesk"),
        ]);
        let order: Vec<(u8, u8)> = state
            .sorted_entries()
            .iter()
            .map(|e| (e.key.kind, e.key.field))
            .collect();
        assert_eq!(order, vec![(0, 2), (2, 0), (3, 3), (3, 8)]);
    }

    #[test]
    fn a_zero_length_value_is_present_rather_than_absent() {
        let state = HostWorkspaceState::from_entries(vec![entry(3, 0xA1, 3, "")]);
        let key = WorkspaceKey::new(3, uuid(0xA1), 3);
        assert_eq!(state.get(&key), Some(&[][..]));
        assert_eq!(state.get(&WorkspaceKey::new(3, uuid(0xA1), 4)), None);
        assert!(!state.is_empty());
    }

    #[test]
    fn a_later_entry_for_one_key_wins() {
        let state =
            HostWorkspaceState::from_entries(vec![entry(3, 0xA1, 3, "first"), entry(3, 0xA1, 3, "last")]);
        assert_eq!(state.len(), 1);
        assert_eq!(
            state.get(&WorkspaceKey::new(3, uuid(0xA1), 3)),
            Some(&b"last"[..])
        );
    }

    #[test]
    fn a_diff_sets_what_changed_and_deletes_what_the_base_alone_holds() {
        let base = HostWorkspaceState::from_entries(vec![
            entry(3, 0xA1, 3, "main.go - NVIM"),
            entry(3, 0xA1, 99, "gone"),
        ]);
        let next = HostWorkspaceState::from_entries(vec![entry(3, 0xA1, 3, ""), entry(3, 0xA1, 8, "vi .")]);
        let diff = next.diff_from(&base);
        assert_eq!(diff.sets, vec![entry(3, 0xA1, 3, ""), entry(3, 0xA1, 8, "vi .")]);
        assert_eq!(diff.deletes, vec![WorkspaceKey::new(3, uuid(0xA1), 99)]);
    }

    #[test]
    fn a_diff_against_itself_is_empty() {
        let state = HostWorkspaceState::from_entries(vec![entry(3, 0xA1, 3, "x")]);
        assert!(state.diff_from(&state).is_empty());
        assert!(WorkspaceStateDiff::default().is_empty());
    }

    #[test]
    fn applying_a_diff_twice_lands_where_applying_it_once_did() {
        let base = HostWorkspaceState::from_entries(vec![
            entry(3, 0xA1, 3, "main.go - NVIM"),
            entry(3, 0xA1, 99, "gone"),
        ]);
        let next = HostWorkspaceState::from_entries(vec![entry(3, 0xA1, 3, ""), entry(3, 0xA1, 8, "vi .")]);
        let diff = next.diff_from(&base);
        let once = base.applying(&diff);
        assert_eq!(once, next);
        assert_eq!(once.applying(&diff), once);
        // The in-place form is the same function, so it must land in the same place — and applying
        // twice must land there too, which is the independence argument the whole diff rests on.
        let mut in_place = base;
        in_place.apply(&diff);
        assert_eq!(in_place, once);
        in_place.apply(&diff);
        assert_eq!(in_place, once, "a duplicated diff is a no-op by construction");
    }

    #[test]
    fn removing_an_object_takes_every_field_under_it_and_nothing_else() {
        let mut state = HostWorkspaceState::from_entries(vec![
            entry(3, 0xA1, 3, "a"),
            entry(3, 0xA1, 8, "b"),
            entry(3, 0xA2, 3, "c"),
            entry(2, 0xA1, 0, "d"),
        ]);
        assert_eq!(state.keys_of_object(3, uuid(0xA1)).len(), 2);
        state.remove_object(3, uuid(0xA1));
        assert_eq!(state.len(), 2);
        assert!(state.keys_of_object(3, uuid(0xA1)).is_empty());
        assert_eq!(state.get(&WorkspaceKey::new(3, uuid(0xA2), 3)), Some(&b"c"[..]));
        assert_eq!(state.get(&WorkspaceKey::new(2, uuid(0xA1), 0)), Some(&b"d"[..]));
    }

    #[test]
    fn a_root_key_is_the_zero_object_id() {
        assert_eq!(WorkspaceKey::root(2), WorkspaceKey::new(0, ROOT_OBJECT_ID, 2));
        assert_eq!(WorkspaceKey::ENCODED_SIZE, 18);
    }
}
