//! The document's scalar field codec: the bytes one `pane/*` or `session/*` value rides as.
//!
//! These are the leaves of the multiclient state protocol (docs/45). Everything here decodes bytes
//! that came off a socket, so every decoder is STRICT about width: a value of the wrong length is
//! `None`, never a lenient prefix read. That is the whole safety property — a mis-numbered field
//! must fail to decode rather than succeed into a plausible-looking value, because a plausible
//! `grid` of `(0, 0)` letterboxes a pane to nothing and a plausible `lastExitCode` reports a clean
//! exit for a process a signal killed.
//!
//! Every multi-byte scalar is BIG-ENDIAN, matching the rest of the wire. Signed values ride as
//! their unsigned bit pattern so there is no sign convention for either end to get wrong.

/// A UUID's sixteen bytes, in the UUID's own order.
///
/// This layer is about BYTES, so an identity is its bytes: the crate's own `PaneId`/`TabId` and the
/// caller's `UUID` both convert in one field copy, and neither has to be named here.
pub type RawUuid = [u8; 16];

/// The longest a string field may be. Longer values are clamped, not rejected: a 70 KiB title is a
/// misbehaving program, not a reason to drop the pane's whole record.
pub const MAX_STRING_BYTES: usize = 65_535;

/// A string field's bytes: strict UTF-8, clamped at a CHARACTER boundary so a truncated value is
/// still valid UTF-8 rather than a half-written scalar the far end cannot decode.
///
/// `max_bytes` is a parameter rather than the constant because the field's own limit is not always
/// the protocol's — a `renameTab` name is clamped tighter than a title, and the clamp belongs to
/// whoever knows the field.
#[must_use]
pub fn encode_string(text: &str, max_bytes: usize) -> Vec<u8> {
    if text.len() <= max_bytes {
        return text.as_bytes().to_vec();
    }
    // `floor_char_boundary` is unstable, so the boundary is found by walking back from the limit.
    // At most three steps: no UTF-8 scalar is longer than four bytes.
    let mut end = max_bytes;
    while end > 0 && !text.is_char_boundary(end) {
        end -= 1;
    }
    text.get(..end).unwrap_or_default().as_bytes().to_vec()
}

/// A string field's value, or `None` when the bytes are not valid UTF-8.
///
/// The caller drops the field rather than rendering replacement characters: a title with a `U+FFFD`
/// in it looks like the program's own output, and a dropped one visibly did not arrive.
#[must_use]
pub fn decode_string(bytes: &[u8]) -> Option<&str> {
    core::str::from_utf8(bytes).ok()
}

/// A one-byte field (`titleFresh`, `commandRunning`, `liveness`, `syncInputArmed`, `userRenamed`).
#[must_use]
pub const fn encode_u8(value: u8) -> [u8; 1] {
    [value]
}

/// `None` on any length but exactly one.
#[must_use]
pub fn decode_u8(bytes: &[u8]) -> Option<u8> {
    match bytes {
        [only] => Some(*only),
        _ => None,
    }
}

/// C-style bool discipline: any non-zero byte is true, which is the rule the rest of the codebase
/// uses for bytes that crossed a language or a network boundary.
#[must_use]
pub const fn encode_bool(value: bool) -> [u8; 1] {
    [value as u8]
}

/// `None` on any length but exactly one; otherwise non-zero is true.
#[must_use]
pub fn decode_bool(bytes: &[u8]) -> Option<bool> {
    decode_u8(bytes).map(|byte| byte != 0)
}

/// A two-byte pair — `agentState` is `[state][kind]`, `progress` is `[state][percent]`.
#[must_use]
pub const fn encode_u8_pair(first: u8, second: u8) -> [u8; 2] {
    [first, second]
}

/// `None` on any length but exactly two.
#[must_use]
pub fn decode_u8_pair(bytes: &[u8]) -> Option<(u8, u8)> {
    match bytes {
        [first, second] => Some((*first, *second)),
        _ => None,
    }
}

/// A `[u16 BE][u16 BE]` pair — `pane/grid` is `(cols, rows)`, in that order.
#[must_use]
pub const fn encode_u16_pair(first: u16, second: u16) -> [u8; 4] {
    let (a, b) = (first.to_be_bytes(), second.to_be_bytes());
    [a[0], a[1], b[0], b[1]]
}

/// `None` on any length but exactly four.
#[must_use]
pub fn decode_u16_pair(bytes: &[u8]) -> Option<(u16, u16)> {
    match bytes {
        [a, b, c, d] => Some((u16::from_be_bytes([*a, *b]), u16::from_be_bytes([*c, *d]))),
        _ => None,
    }
}

/// A `[u32 BE]` field.
#[must_use]
pub const fn encode_u32(value: u32) -> [u8; 4] {
    value.to_be_bytes()
}

/// `None` on any length but exactly four.
#[must_use]
pub fn decode_u32(bytes: &[u8]) -> Option<u32> {
    <[u8; 4]>::try_from(bytes).ok().map(u32::from_be_bytes)
}

/// `pane/lastExitCode`. Rides as the `u32` bit pattern so a negative code — a signal-killed child —
/// survives without a sign convention for either end to get wrong.
#[must_use]
pub const fn encode_i32(value: i32) -> [u8; 4] {
    encode_u32(value.cast_unsigned())
}

/// `None` on any length but exactly four.
#[must_use]
pub fn decode_i32(bytes: &[u8]) -> Option<i32> {
    decode_u32(bytes).map(u32::cast_signed)
}

/// A `[u64 BE]` field carrying a signed value — `pane/lastActivityMS`, milliseconds since the
/// epoch.
#[must_use]
pub const fn encode_i64(value: i64) -> [u8; 8] {
    value.cast_unsigned().to_be_bytes()
}

/// `None` on any length but exactly eight.
#[must_use]
pub fn decode_i64(bytes: &[u8]) -> Option<i64> {
    <[u8; 8]>::try_from(bytes)
        .ok()
        .map(|octets| u64::from_be_bytes(octets).cast_signed())
}

/// `None` on any length but exactly sixteen.
#[must_use]
pub fn decode_uuid(bytes: &[u8]) -> Option<RawUuid> {
    <RawUuid>::try_from(bytes).ok()
}

/// A `[u16 BE count][uuid…]` list — `root/sessionOrder`, `session/tabOrder`, `root/closedTabRing`.
///
/// A list longer than `u16::MAX` is truncated rather than refused: the count field cannot express
/// it, and answering a short list beats answering bytes that claim a length they do not carry.
#[must_use]
pub fn encode_uuid_list(ids: &[RawUuid]) -> Vec<u8> {
    let count = u16::try_from(ids.len()).unwrap_or(u16::MAX);
    let kept = usize::from(count);
    let mut out = Vec::with_capacity(2 + kept * 16);
    out.extend_from_slice(&count.to_be_bytes());
    for id in ids.iter().take(kept) {
        out.extend_from_slice(id);
    }
    out
}

/// The UUIDs a list carries, or `None` when the count and the bytes disagree.
///
/// The length is validated against what REMAINS before any capacity is reserved, so a hostile
/// `0xFFFF` costs one comparison rather than a megabyte of allocation.
#[must_use]
pub fn decode_uuid_list(bytes: &[u8]) -> Option<Vec<RawUuid>> {
    let (header, rest) = bytes.split_at_checked(2)?;
    let count = usize::from(u16::from_be_bytes([*header.first()?, *header.get(1)?]));
    if rest.len() != count.checked_mul(16)? {
        return None;
    }
    Some(rest.chunks_exact(16).filter_map(decode_uuid).collect())
}

#[cfg(test)]
mod tests {
    use super::{
        DetachedPane, Entry, Key, LayoutError, LayoutNode, MAX_STRING_BYTES, VideoTarget, decode_bool,
        decode_detached_panes, decode_diff, decode_i32, decode_i64, decode_layout, decode_snapshot,
        decode_string, decode_u8, decode_u16_pair, decode_u32, decode_uuid_list, decode_video_target,
        decode_weight, decode_weights, encode_detached_panes, encode_diff, encode_i32, encode_i64,
        encode_layout, encode_snapshot, encode_string, encode_u16_pair, encode_uuid_list,
        encode_video_target, encode_weight, encode_weights,
    };

    /// The strictness IS the safety property: a mis-numbered field must fail to decode rather than
    /// succeed into a plausible value. A lenient prefix read would turn a four-byte `grid` into a
    /// one-byte `liveness` that says "attached".
    #[test]
    fn a_wrong_width_is_a_drop_not_a_prefix_read() {
        assert_eq!(decode_u8(&[1, 2]), None, "two bytes are not a one-byte field");
        assert_eq!(decode_u8(&[]), None);
        assert_eq!(decode_bool(&[0, 0]), None);
        assert_eq!(decode_u32(&[0, 0, 0]), None, "three bytes are not a u32");
        assert_eq!(decode_u32(&[0, 0, 0, 0, 0]), None, "nor are five");
        assert_eq!(decode_u16_pair(&[1, 2]), None, "half a pair is not a pair");
    }

    /// A signal-killed child reports a negative code, and it has to survive the round trip — the
    /// bit pattern is what crosses precisely so neither end needs a sign convention.
    #[test]
    fn a_negative_exit_code_survives_as_its_bit_pattern() {
        assert_eq!(decode_i32(&encode_i32(-9)), Some(-9));
        assert_eq!(decode_i32(&encode_i32(i32::MIN)), Some(i32::MIN));
        assert_eq!(decode_i64(&encode_i64(-1)), Some(-1));
    }

    /// Big-endian, like the rest of the wire — asserted on the BYTES, because a round trip alone
    /// would pass just as happily on little-endian and only fail against a real client.
    #[test]
    fn the_pair_is_big_endian_on_the_wire() {
        assert_eq!(encode_u16_pair(0x0102, 0x0304), [1, 2, 3, 4]);
        assert_eq!(encode_i32(1), [0, 0, 0, 1]);
    }

    /// A truncated string must still be valid UTF-8. Cutting at the byte limit mid-scalar would
    /// produce bytes the far end drops entirely — losing the whole title to save three bytes.
    #[test]
    fn a_clamped_string_stops_at_a_character_boundary() {
        // 'é' is two bytes, so a run of them straddles an odd limit.
        let long: String = core::iter::repeat_n('é', MAX_STRING_BYTES).collect();
        let encoded = encode_string(&long, MAX_STRING_BYTES);
        assert!(encoded.len() <= MAX_STRING_BYTES);
        assert!(
            decode_string(&encoded).is_some(),
            "the clamp cut between scalars, not through one"
        );
    }

    /// A count the bytes cannot back is refused before anything is reserved, so a hostile header
    /// costs a comparison rather than an allocation.
    #[test]
    fn a_list_that_lies_about_its_length_is_refused() {
        assert_eq!(decode_uuid_list(&[0xFF, 0xFF]), None, "65535 ids, zero bytes");
        assert_eq!(decode_uuid_list(&[0]), None, "a truncated header");
        assert_eq!(decode_uuid_list(&[0, 1, 9, 9]), None, "one id, four bytes");
        let ids = [[1_u8; 16], [2_u8; 16]];
        assert_eq!(decode_uuid_list(&encode_uuid_list(&ids)), Some(ids.to_vec()));
    }

    /// A count the bytes cannot back must cost a COMPARISON, not an allocation. `0xFFFFFFFF`
    /// entries is the shape of the attack, and reserving for it before checking is the bug.
    #[test]
    fn a_snapshot_that_claims_more_than_it_carries_is_refused() {
        assert_eq!(
            decode_snapshot(&[0xFF, 0xFF, 0xFF, 0xFF]),
            None,
            "4 billion entries, no bytes"
        );
        assert_eq!(decode_snapshot(&[0, 0, 0, 1]), None, "one entry, no entry");
        assert_eq!(decode_snapshot(&[0, 0]), None, "a truncated count");
        assert_eq!(decode_snapshot(&[]), None);
    }

    /// A value length is bounded against what REMAINS, so a hostile length prefix cannot make the
    /// decoder read past its own buffer or reserve against a number the sender chose.
    #[test]
    fn a_value_longer_than_the_buffer_is_refused() {
        let mut bytes = vec![0, 0, 0, 1];
        bytes.push(3);
        bytes.extend_from_slice(&[7; 16]);
        bytes.push(9);
        bytes.extend_from_slice(&[0xFF, 0xFF, 0xFF, 0xFF]);
        assert_eq!(decode_snapshot(&bytes), None, "a value that claims 4 GiB");
    }

    /// Trailing bytes are a refusal rather than something to ignore: a snapshot that decoded to
    /// fewer entries than it carries would have the client ack a state it does not hold.
    #[test]
    fn trailing_bytes_are_a_refusal() {
        let entry = Entry {
            kind: 3,
            object: [7; 16],
            field: 9,
            value: &[1, 2],
        };
        let mut bytes = encode_snapshot(&[entry]);
        assert_eq!(decode_snapshot(&bytes), Some(vec![entry]), "the round trip holds");
        bytes.push(0);
        assert_eq!(
            decode_snapshot(&bytes),
            None,
            "and one byte more is not the same state"
        );
    }

    /// A zero-length value is FIRST CLASS — an empty type-21 title is this codebase's
    /// agent-title-retirement signal, so it must survive as "present and empty", never as absent.
    #[test]
    fn an_empty_value_is_not_an_absent_one() {
        let entry = Entry {
            kind: 3,
            object: [1; 16],
            field: 2,
            value: &[],
        };
        // The bytes are BOUND, not a temporary: the decoded entries borrow them, which is the whole
        // reason a value is a slice here rather than a copy.
        let bytes = encode_snapshot(&[entry]);
        let decoded = decode_snapshot(&bytes);
        assert_eq!(decoded, Some(vec![entry]), "present, and empty");
        assert!(
            decoded.is_some_and(|entries| entries.first().is_some_and(|e| e.value.is_empty())),
            "an empty value round-trips as a value, not as an absence"
        );
    }

    /// A diff round-trips both halves, and its delete count is bounded the same way the set count
    /// is.
    #[test]
    fn a_diff_carries_both_halves_and_bounds_both() {
        let sets = [Entry {
            kind: 1,
            object: [4; 16],
            field: 5,
            value: &[9],
        }];
        let deletes = [Key {
            kind: 2,
            object: [6; 16],
            field: 7,
        }];
        let bytes = encode_diff(&sets, &deletes);
        assert_eq!(decode_diff(&bytes), Some((sets.to_vec(), deletes.to_vec())));
        assert_eq!(
            decode_diff(&[0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF]),
            None,
            "no sets, then 4 billion deletes"
        );
    }

    /// The shapes a real document holds: a bare leaf, a flat split, and nesting. The walk is
    /// pre-order, so the round trip pins the ORDER as much as the contents.
    #[test]
    fn a_layout_survives_the_round_trip_at_every_shape() {
        let leaf = |byte: u8| {
            LayoutNode {
                kind: 0,
                id: [byte; 16],
                axis: 0,
                child_count: 0,
            }
        };
        let split = |byte: u8, axis: u8, n: u8| {
            LayoutNode {
                kind: 1,
                id: [byte; 16],
                axis,
                child_count: n,
            }
        };
        for walk in [vec![leaf(1)], vec![split(9, 1, 2), leaf(1), leaf(2)], vec![
            split(9, 0, 2),
            split(8, 1, 2),
            leaf(1),
            leaf(2),
            leaf(3),
        ]] {
            assert_eq!(decode_layout(&encode_layout(&walk)), Ok(walk.clone()), "{walk:?}");
        }
    }

    /// A split that claims children it does not carry, an unknown tag, and trailing bytes are all
    /// refusals. These bytes came off a socket; a partial tree is not a tree.
    #[test]
    fn a_malformed_layout_is_refused_rather_than_half_read() {
        // A split promising two children, carrying one.
        let mut short = vec![1];
        short.extend_from_slice(&[9; 16]);
        short.extend_from_slice(&[0, 2, 0]);
        short.extend_from_slice(&[1; 16]);
        assert_eq!(
            decode_layout(&short),
            Err(LayoutError::Malformed),
            "a split short one child"
        );

        let mut unknown = vec![7];
        unknown.extend_from_slice(&[1; 16]);
        assert_eq!(
            decode_layout(&unknown),
            Err(LayoutError::Malformed),
            "an unknown node tag"
        );

        let mut trailing = encode_layout(&[LayoutNode {
            kind: 0,
            id: [1; 16],
            axis: 0,
            child_count: 0,
        }]);
        trailing.push(0);
        assert_eq!(
            decode_layout(&trailing),
            Err(LayoutError::Malformed),
            "a whole tree, and then more bytes"
        );
        assert_eq!(decode_layout(&[]), Err(LayoutError::Malformed));
    }

    /// The recursion is gone, so depth is bounded by a counter rather than by the stack. A tree
    /// nested past the cap is refused — and, crucially, one nested a THOUSAND deep does not crash
    /// the process on the way to being refused.
    #[test]
    fn a_deeply_nested_layout_is_refused_without_a_stack_to_overflow() {
        let mut bytes = Vec::new();
        for depth in 0..1_000_u16 {
            bytes.push(1);
            bytes.extend_from_slice(&[u8::try_from(depth % 251).unwrap_or(0); 16]);
            bytes.extend_from_slice(&[0, 1]);
        }
        bytes.push(0);
        bytes.extend_from_slice(&[1; 16]);
        assert_eq!(
            decode_layout(&bytes),
            Err(LayoutError::DepthExceeded),
            "refused at the cap, not at the stack"
        );
    }

    /// The bit pattern is what crosses, so a weight survives EXACTLY — `CLAUDE.md` pins these, and
    /// a decimal round trip is the drift that rule forbids.
    #[test]
    fn a_weight_survives_bit_exactly() {
        for (is_fixed, value) in [(false, 1.0_f64), (true, 120.5), (false, 0.1 + 0.2)] {
            let decoded = decode_weight(&encode_weight(is_fixed, value));
            assert_eq!(decoded, Some((is_fixed, value)), "the bits, not the decimal");
        }
        assert_eq!(decode_weight(&[0, 1, 2]), None, "a truncated weight is a drop");
    }

    /// One split's weights ride as ONE value, so a divider drag cannot arrive half-applied. A count
    /// the bytes cannot back is refused.
    #[test]
    fn a_split_s_weights_are_one_value_or_none() {
        let weights = [(false, 1.0_f64), (true, 200.0)];
        assert_eq!(decode_weights(&encode_weights(&weights)), Some(weights.to_vec()));
        assert_eq!(decode_weights(&[3, 0]), None, "three weights, two bytes");
        assert_eq!(decode_weights(&[]), None);
    }

    /// The origin's absence and the origin's presence are different records, and the all-zero id is
    /// how the fixed-width pair spells the first. It must not survive the round trip as a real tab.
    #[test]
    fn a_detached_pane_with_no_origin_is_not_a_pane_docked_to_the_zero_tab() {
        let panes = vec![
            DetachedPane {
                pane: [1; 16],
                origin: Some([2; 16]),
            },
            DetachedPane {
                pane: [3; 16],
                origin: None,
            },
        ];
        let bytes = encode_detached_panes(&panes);
        assert_eq!(decode_detached_panes(&bytes), Some(panes));
    }

    /// A count is a promise about bytes that are not there yet. Sixty-five thousand panes claimed
    /// by a two-byte header must cost a comparison, not a reservation.
    #[test]
    fn a_detached_list_that_lies_about_its_count_is_refused() {
        assert_eq!(decode_detached_panes(&[0xFF, 0xFF]), None);
        assert_eq!(decode_detached_panes(&[0x00, 0x01, 0x07]), None);
        assert_eq!(decode_detached_panes(&[]), None);
    }

    /// Display `0` is the MAIN display, so the presence byte is the only thing separating "on the
    /// main screen" from "not on a screen at all".
    #[test]
    fn display_zero_is_a_display_and_not_an_absence() {
        let on_main = VideoTarget {
            window_id: 42,
            display_id: Some(0),
            title: "Terminal",
            app_name: "Ghostty",
        };
        let windowed = VideoTarget {
            display_id: None,
            ..on_main
        };
        assert_eq!(decode_video_target(&encode_video_target(&on_main)), Some(on_main));
        assert_eq!(
            decode_video_target(&encode_video_target(&windowed)),
            Some(windowed)
        );
        assert_ne!(encode_video_target(&on_main), encode_video_target(&windowed));
    }

    /// A length that overruns, a title that is not UTF-8, and bytes left over are all refusals —
    /// these came off a socket, and a lenient read would render a plausible window title.
    #[test]
    fn a_video_target_is_refused_rather_than_read_leniently() {
        let good = encode_video_target(&VideoTarget {
            window_id: 1,
            display_id: None,
            title: "a",
            app_name: "b",
        });
        let mut trailing = good.clone();
        trailing.push(0);
        assert_eq!(decode_video_target(&trailing), None, "a whole value, then more");

        let mut overrun = good.clone();
        // The title's length header, made larger than the bytes that follow it.
        if let Some(slot) = overrun.get_mut(9..11) {
            slot.copy_from_slice(&[0xFF, 0xFF]);
        }
        assert_eq!(decode_video_target(&overrun), None, "a length past the buffer");

        let mut invalid = good;
        if let Some(byte) = invalid.get_mut(11) {
            *byte = 0xFF;
        }
        assert_eq!(decode_video_target(&invalid), None, "a title that is not UTF-8");

        assert_eq!(decode_video_target(&[]), None);
    }
}

// MARK: The structural encoders

/// One document entry: a key and the bytes its value rides as.
///
/// The value is a SLICE of the buffer it was decoded from rather than a copy. A snapshot is
/// hundreds of entries and arrives on every attach, so the decode is one pass with no per-value
/// allocation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Entry<'a> {
    /// Which kind of object the key names — root, session, tab, pane.
    pub kind: u8,
    /// The object's identity.
    pub object: RawUuid,
    /// Which field of it.
    pub field: u8,
    /// The value's bytes.
    pub value: &'a [u8],
}

/// A key on its own, which is what a DELETE carries.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Key {
    /// Which kind of object the key names.
    pub kind: u8,
    /// The object's identity.
    pub object: RawUuid,
    /// Which field of it.
    pub field: u8,
}

/// A key's encoded width: `[kind][uuid][field]`.
pub const KEY_SIZE: usize = 1 + 16 + 1;

/// The cheapest an entry can be: a bare key and a zero length prefix.
const ENTRY_FLOOR: usize = KEY_SIZE + 4;

/// Upper bound on entries in one snapshot or diff.
///
/// Rejects an absurd count before it can drive an allocation. The real corpus is hundreds of
/// entries, not tens of thousands.
pub const MAX_ENTRY_COUNT: usize = 65_536;

/// A cursor over bytes that came off a socket. Every read is checked; nothing panics.
struct Reader<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl<'a> Reader<'a> {
    const fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, at: 0 }
    }

    const fn remaining(&self) -> usize {
        self.bytes.len().saturating_sub(self.at)
    }

    fn take(&mut self, count: usize) -> Option<&'a [u8]> {
        let end = self.at.checked_add(count)?;
        let slice = self.bytes.get(self.at..end)?;
        self.at = end;
        Some(slice)
    }

    fn u8(&mut self) -> Option<u8> {
        self.take(1).and_then(|slice| slice.first().copied())
    }

    fn u32(&mut self) -> Option<u32> {
        self.take(4).and_then(decode_u32)
    }

    fn uuid(&mut self) -> Option<RawUuid> {
        self.take(16).and_then(decode_uuid)
    }

    fn key(&mut self) -> Option<Key> {
        Some(Key {
            kind: self.u8()?,
            object: self.uuid()?,
            field: self.u8()?,
        })
    }

    fn entry(&mut self) -> Option<Entry<'a>> {
        let key = self.key()?;
        let length = usize::try_from(self.u32()?).ok()?;
        // Bound the length against the bytes ACTUALLY left before taking it — a hostile `u32::MAX`
        // must cost a comparison, not an allocation.
        if length > self.remaining() {
            return None;
        }
        Some(Entry {
            kind: key.kind,
            object: key.object,
            field: key.field,
            value: self.take(length)?,
        })
    }

    /// `count` entries, having first proven the buffer could plausibly hold them.
    fn entries(&mut self, count: u32) -> Option<Vec<Entry<'a>>> {
        let count = usize::try_from(count).ok()?;
        if count > MAX_ENTRY_COUNT || self.remaining() < count.checked_mul(ENTRY_FLOOR)? {
            return None;
        }
        let mut out = Vec::with_capacity(count);
        for _ in 0..count {
            out.push(self.entry()?);
        }
        Some(out)
    }

    fn keys(&mut self, count: u32) -> Option<Vec<Key>> {
        let count = usize::try_from(count).ok()?;
        if count > MAX_ENTRY_COUNT || self.remaining() < count.checked_mul(KEY_SIZE)? {
            return None;
        }
        let mut out = Vec::with_capacity(count);
        for _ in 0..count {
            out.push(self.key()?);
        }
        Some(out)
    }
}

/// A key's bytes: `[u8 kind][16B object][u8 field]`.
///
/// The addressing scheme is the DOCUMENT's, and both ends address the same cells — so it is stated
/// once here and appended from, rather than being a small loop each language writes for itself.
#[must_use]
pub const fn encode_key(key: Key) -> [u8; KEY_SIZE] {
    let [
        b0,
        b1,
        b2,
        b3,
        b4,
        b5,
        b6,
        b7,
        b8,
        b9,
        b10,
        b11,
        b12,
        b13,
        b14,
        b15,
    ] = key.object;
    [
        key.kind, b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15, key.field,
    ]
}

/// Appends a key's bytes.
fn put_key(key: Key, out: &mut Vec<u8>) {
    out.extend_from_slice(&encode_key(key));
}

/// Appends an entry's bytes: its key, a `[u32 BE]` length and the value.
fn put_entry(entry: Entry<'_>, out: &mut Vec<u8>) {
    put_key(
        Key {
            kind: entry.kind,
            object: entry.object,
            field: entry.field,
        },
        out,
    );
    out.extend_from_slice(&encode_u32(u32::try_from(entry.value.len()).unwrap_or(u32::MAX)));
    out.extend_from_slice(entry.value);
}

/// A snapshot: `[u32 entryCount][entry…]`.
#[must_use]
pub fn encode_snapshot(entries: &[Entry<'_>]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&encode_u32(u32::try_from(entries.len()).unwrap_or(u32::MAX)));
    for entry in entries {
        put_entry(*entry, &mut out);
    }
    out
}

/// The entries a snapshot carries, or `None` when the bytes are malformed.
///
/// Trailing bytes are a REFUSAL, not something to ignore: a snapshot that decoded to fewer entries
/// than it carries would have the client ack a state it does not hold.
#[must_use]
pub fn decode_snapshot(bytes: &[u8]) -> Option<Vec<Entry<'_>>> {
    let mut reader = Reader::new(bytes);
    let count = reader.u32()?;
    let entries = reader.entries(count)?;
    (reader.remaining() == 0).then_some(entries)
}

/// A diff: `[u32 setCount][entry…][u32 delCount][key…]`.
#[must_use]
pub fn encode_diff(sets: &[Entry<'_>], deletes: &[Key]) -> Vec<u8> {
    let mut out = encode_snapshot(sets);
    out.extend_from_slice(&encode_u32(u32::try_from(deletes.len()).unwrap_or(u32::MAX)));
    for key in deletes {
        put_key(*key, &mut out);
    }
    out
}

/// The sets and deletes a diff carries, or `None` when the bytes are malformed.
#[must_use]
pub fn decode_diff(bytes: &[u8]) -> Option<(Vec<Entry<'_>>, Vec<Key>)> {
    let mut reader = Reader::new(bytes);
    let set_count = reader.u32()?;
    let sets = reader.entries(set_count)?;
    let delete_count = reader.u32()?;
    let deletes = reader.keys(delete_count)?;
    (reader.remaining() == 0).then_some((sets, deletes))
}

// MARK: The layout structure

/// The tree's depth cap.
///
/// Twelve is far past any arrangement a person builds and far short of what would trouble a stack —
/// but see [`decode_layout`]: the cap here is a FORMAT rule, not the thing keeping the decoder
/// safe.
pub const MAX_LAYOUT_DEPTH: usize = 12;

/// One node of the layout structure, in a PRE-ORDER walk.
///
/// Flat rather than recursive, and that is the point. The Swift decoder this replaces recursed over
/// network input with a depth cap checked before descending — correct, but one forgotten check away
/// from a remote stack overflow. Walking a flat array with an explicit stack makes the overflow
/// structurally impossible instead of merely bounded, and the depth cap goes back to being what it
/// should be: a statement about documents, not a safety mechanism.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LayoutNode {
    /// `0` leaf, `1` split.
    pub kind: u8,
    /// The pane's or the split's identity.
    pub id: RawUuid,
    /// `0` horizontal, `1` vertical. Meaningless on a leaf.
    pub axis: u8,
    /// How many children a split has. The format makes this a `u8`, so the fan-out is bounded
    /// before any allocation rather than by a check somebody has to remember to write.
    pub child_count: u8,
}

/// The layout structure's bytes.
///
/// `[u8 kind][uuid]` for a leaf, `[u8 kind][uuid][u8 axis][u8 n]` for a split, each followed by its
/// children. Weights are deliberately EXCLUDED — they ride as their own per-split entry so a
/// divider drag and a re-arrangement do not clobber each other.
#[must_use]
pub fn encode_layout(walk: &[LayoutNode]) -> Vec<u8> {
    let mut out = Vec::new();
    for node in walk {
        out.push(node.kind);
        out.extend_from_slice(&node.id);
        if node.kind == 1 {
            out.push(node.axis);
            out.push(node.child_count);
        }
    }
    out
}

/// Why a layout structure was refused.
///
/// Depth is called out separately rather than folded into "malformed" because the two say different
/// things about the sender: a malformed tree is a bug or an attack, where a too-deep one is a
/// well-formed document this build declines to hold. A caller that cannot tell them apart cannot
/// report either honestly.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LayoutError {
    /// An unknown tag, a truncated node, a split claiming more children than it carries, or
    /// trailing bytes.
    Malformed,
    /// Nesting past [`MAX_LAYOUT_DEPTH`].
    DepthExceeded,
}

/// The walk a layout structure carries, or why it was refused.
///
/// Iterative: `pending` holds how many children each open split still owes, so the only memory this
/// grows is a `Vec` of counts bounded by the depth cap. There is no recursion to overflow.
///
/// # Errors
/// [`LayoutError`], which distinguishes a malformed tree from a merely too-deep one.
pub fn decode_layout(bytes: &[u8]) -> Result<Vec<LayoutNode>, LayoutError> {
    let mut reader = Reader::new(bytes);
    let mut walk = Vec::new();
    let mut pending: Vec<u8> = Vec::new();
    loop {
        if walk.len() > MAX_ENTRY_COUNT {
            return Err(LayoutError::Malformed);
        }
        let node = match reader.u8().ok_or(LayoutError::Malformed)? {
            0 => {
                LayoutNode {
                    kind: 0,
                    id: reader.uuid().ok_or(LayoutError::Malformed)?,
                    axis: 0,
                    child_count: 0,
                }
            },
            1 => {
                let id = reader.uuid().ok_or(LayoutError::Malformed)?;
                // C-style bool discipline: any non-zero is vertical, never a trap on an odd byte.
                let axis = u8::from(reader.u8().ok_or(LayoutError::Malformed)? != 0);
                let child_count = reader.u8().ok_or(LayoutError::Malformed)?;
                // One byte minimum per child — a bare leaf tag — bounded before anything is reserved.
                if usize::from(child_count) > reader.remaining() {
                    return Err(LayoutError::Malformed);
                }
                LayoutNode {
                    kind: 1,
                    id,
                    axis,
                    child_count,
                }
            },
            _ => return Err(LayoutError::Malformed),
        };
        walk.push(node);
        // The node fills one slot of its PARENT's frame, which is the frame currently open.
        if let Some(owed) = pending.last_mut() {
            *owed -= 1;
        }
        // A split then opens a frame of its own. A childless one is complete on arrival and opens
        // nothing, which is also what keeps the close-loop below from underflowing.
        if node.kind == 1 && node.child_count > 0 {
            if pending.len() >= MAX_LAYOUT_DEPTH {
                return Err(LayoutError::DepthExceeded);
            }
            pending.push(node.child_count);
        }
        // Close every frame this node completed. A leaf finishing a chain of 1-child splits closes
        // several at once.
        // A closed frame owes its own parent nothing more: the split took that slot when it was
        // read, so the pop alone is the completion.
        while pending.last() == Some(&0) {
            pending.pop();
        }
        if pending.is_empty() {
            break;
        }
    }
    if reader.remaining() == 0 {
        Ok(walk)
    } else {
        Err(LayoutError::Malformed)
    }
}

// MARK: The split weights

/// One weight.
///
/// `[u8 kind][u64 BE bits]`, where `kind` is `0` flex and `1` fixed.
///
/// The double rides as its raw BIT PATTERN, never a re-parsed decimal — `CLAUDE.md` pins these
/// bit-exactly, and a decimal round trip is exactly the drift that rule exists to forbid.
#[must_use]
pub fn encode_weight(is_fixed: bool, value: f64) -> [u8; 9] {
    let bits = value.to_bits().to_be_bytes();
    [
        u8::from(is_fixed),
        bits[0],
        bits[1],
        bits[2],
        bits[3],
        bits[4],
        bits[5],
        bits[6],
        bits[7],
    ]
}

/// A weight's `(is_fixed, value)`, or `None` on any length but exactly nine.
#[must_use]
pub fn decode_weight(bytes: &[u8]) -> Option<(bool, f64)> {
    let (kind, rest) = bytes.split_first()?;
    let bits = <[u8; 8]>::try_from(rest).ok()?;
    Some((*kind != 0, f64::from_bits(u64::from_be_bytes(bits))))
}

/// One split's child weights.
///
/// `[u8 childCount]([u8 kind][u64 BE bits])*`, in child order.
///
/// All of one split's weights in ONE value is what makes a divider drag atomic — the op it maps
/// onto moves a leading/trailing pair, so splitting the pair across two entries would let a diff
/// carry half a drag.
#[must_use]
pub fn encode_weights(weights: &[(bool, f64)]) -> Vec<u8> {
    let count = u8::try_from(weights.len()).unwrap_or(u8::MAX);
    let kept = usize::from(count);
    let mut out = Vec::with_capacity(1 + kept * 9);
    out.push(count);
    for (is_fixed, value) in weights.iter().take(kept) {
        out.extend_from_slice(&encode_weight(*is_fixed, *value));
    }
    out
}

/// The weights a value carries, or `None` when the count and the bytes disagree.
#[must_use]
pub fn decode_weights(bytes: &[u8]) -> Option<Vec<(bool, f64)>> {
    let (count, rest) = bytes.split_first()?;
    if rest.len() != usize::from(*count) * 9 {
        return None;
    }
    rest.chunks_exact(9).map(decode_weight).collect()
}

// MARK: - The two composite field values

/// The all-zero id, which the detached-pane record uses to mean "no remembered origin tab".
///
/// It is a sentinel HERE and only here, because the record is fixed-width and a pane always has an
/// id while its origin is genuinely optional. Everywhere the value crosses an API it becomes an
/// [`Option`] again, so no caller has to know the wire's spelling of absence.
const NO_ORIGIN: RawUuid = [0; 16];

/// A pane pulled out of its tab and floating, with the tab it came from if anyone still remembers.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DetachedPane {
    /// The pane itself.
    pub pane: RawUuid,
    /// The tab it was detached from, when that is still known.
    pub origin: Option<RawUuid>,
}

/// `session/detachedPanes`: `[u16 n]([16B pane][16B origin])*`.
///
/// The count is clamped to what a `u16` can say rather than truncating the field silently at some
/// other width, which is the same clamp every list in this module makes.
#[must_use]
pub fn encode_detached_panes(panes: &[DetachedPane]) -> Vec<u8> {
    let count = u16::try_from(panes.len()).unwrap_or(u16::MAX);
    let kept = usize::from(count);
    let mut out = Vec::with_capacity(2 + kept * 32);
    out.extend_from_slice(&count.to_be_bytes());
    for entry in panes.iter().take(kept) {
        out.extend_from_slice(&entry.pane);
        out.extend_from_slice(&entry.origin.unwrap_or(NO_ORIGIN));
    }
    out
}

/// The detached panes a value carries, or `None` when the count and the bytes disagree.
///
/// The count is checked against the bytes ACTUALLY remaining before a single pair is reserved, so a
/// record claiming sixty-five thousand panes costs one comparison rather than two megabytes.
#[must_use]
pub fn decode_detached_panes(bytes: &[u8]) -> Option<Vec<DetachedPane>> {
    let mut reader = Reader::new(bytes);
    let count = usize::from(u16::from_be_bytes([reader.u8()?, reader.u8()?]));
    if reader.remaining() != count.checked_mul(32)? {
        return None;
    }
    let mut out = Vec::with_capacity(count);
    for _ in 0..count {
        let pane = reader.uuid()?;
        let origin = reader.uuid()?;
        out.push(DetachedPane {
            pane,
            origin: (origin != NO_ORIGIN).then_some(origin),
        });
    }
    Some(out)
}

/// A pane's video source: a window, optionally on a named display, with the titles that were true
/// when it was captured.
///
/// The strings BORROW the buffer they were decoded from — a video target arrives with every pane
/// record, and copying two strings per pane to hand back an owned struct would be work the caller
/// then throws away.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VideoTarget<'a> {
    /// The window's id on the host.
    pub window_id: u32,
    /// The display it sits on, when the endpoint is display-shaped. `0` is a legitimate display id
    /// — the main one — so absence is an [`Option`] here and a presence BYTE on the wire, never
    /// a zero.
    pub display_id: Option<u32>,
    /// The window's title.
    pub title: &'a str,
    /// The owning application's name.
    pub app_name: &'a str,
}

/// `pane/videoTarget`: `[u32 window][u8 hasDisplay][u32 display][u16 len][title][u16 len][app]`.
#[must_use]
pub fn encode_video_target(target: &VideoTarget<'_>) -> Vec<u8> {
    let mut out = Vec::with_capacity(11 + target.title.len() + target.app_name.len() + 4);
    out.extend_from_slice(&encode_u32(target.window_id));
    out.push(u8::from(target.display_id.is_some()));
    out.extend_from_slice(&encode_u32(target.display_id.unwrap_or(0)));
    for text in [target.title, target.app_name] {
        let bytes = encode_string(text, MAX_STRING_BYTES);
        let length = u16::try_from(bytes.len()).unwrap_or(u16::MAX);
        out.extend_from_slice(&length.to_be_bytes());
        out.extend_from_slice(bytes.get(..usize::from(length)).unwrap_or(&bytes));
    }
    out
}

/// The video target a value carries, or `None` when a length overruns, a string is not UTF-8, or
/// bytes are left over.
#[must_use]
pub fn decode_video_target(bytes: &[u8]) -> Option<VideoTarget<'_>> {
    let mut reader = Reader::new(bytes);
    let window_id = reader.u32()?;
    let has_display = reader.u8()?;
    let display_id = reader.u32()?;
    let mut strings = [""; 2];
    for slot in &mut strings {
        let length = usize::from(u16::from_be_bytes([reader.u8()?, reader.u8()?]));
        *slot = decode_string(reader.take(length)?)?;
    }
    if reader.remaining() != 0 {
        return None;
    }
    let [title, app_name] = strings;
    Some(VideoTarget {
        window_id,
        // C-style bool discipline on a byte that crossed the network: anything non-zero is present.
        display_id: (has_display != 0).then_some(display_id),
        title,
        app_name,
    })
}
